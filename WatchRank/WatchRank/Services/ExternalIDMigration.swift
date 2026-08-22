//
//  ExternalIDMigration.swift
//  WatchRank
//
//  Rewrites the library's catalog ids from IMDb to TMDB, so a library built
//  before the live catalog keeps deduping against it afterwards.
//
//  Why this is not optional. `MediaLibraryViewModel.canonicalItem(for:)`
//  identifies an item solely by `externalId`. Before Phase 12 those came from
//  the bundled catalog and looked like `tt1375666`; TMDB search now returns
//  `tmdb:movie:27205`. Without a migration the two never match, so a user who
//  ranked Inception last week sees it as untracked in search, can mark it
//  watched a second time, and can be handed Inception-versus-Inception in the
//  comparison modal — a coin flip the ranking system then treats as a real
//  preference.
//
//  Running on every launch is intentional. The first attempt may happen with no
//  network, and an item that could not be resolved then should be resolved
//  later rather than stranded forever. Re-running is cheap: resolved items no
//  longer match the work filter, and `/find` responses are cached.
//

import Foundation
import SwiftData

// MARK: - ExternalID

/// The two id vocabularies the app has used, and the conversions between them.
///
/// Bare `tt…` ids are the historical form written by `MockMediaService` before
/// the live catalog existed. They still appear in stored libraries, so every
/// comparison has to canonicalise first — a stored `tt1375666` and a freshly
/// minted `imdb:tt1375666` are the same title and must not read as two.
enum ExternalID {

    static let imdbPrefix = "imdb:"

    /// The namespaced form of an IMDb id.
    static func imdb(_ imdbID: String) -> String { imdbPrefix + imdbID }

    /// Extracts the bare IMDb id from either form, or `nil` if this is not an
    /// IMDb id at all.
    static func imdbID(from externalId: String) -> String? {
        let bare = externalId.hasPrefix(imdbPrefix)
            ? String(externalId.dropFirst(imdbPrefix.count))
            : externalId
        // IMDb ids are "tt" followed by digits. Checking the shape rather than
        // just the prefix keeps a TMDB id from ever being mistaken for one.
        guard bare.hasPrefix("tt"), bare.count > 2,
              bare.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return bare
    }

    /// The canonical stored form of any id.
    ///
    /// Used on both sides of every identity comparison, so the historical bare
    /// form and the namespaced form collapse to one value. TMDB ids and
    /// anything unrecognised pass through untouched.
    static func canonical(_ externalId: String) -> String {
        guard let imdbID = imdbID(from: externalId) else { return externalId }
        return imdb(imdbID)
    }
}

// MARK: - IMDbResolver

/// The one thing the migration needs from the catalog. Narrow on purpose: it
/// keeps the migration testable without a search implementation, and it takes
/// the media type so a film can never resolve to a series of the same name.
protocol IMDbResolver: Sendable {
    func resolveIMDbID(_ imdbID: String, expecting type: MediaType) async -> Int?
}

extension TMDBMediaService: IMDbResolver {}

// MARK: - ExternalIDMigration

@MainActor
final class ExternalIDMigration {

    private let resolver: IMDbResolver
    private let modelContext: ModelContext
    private let concurrency: Int

    init(resolver: IMDbResolver, modelContext: ModelContext, concurrency: Int = 4) {
        self.resolver = resolver
        self.modelContext = modelContext
        self.concurrency = max(1, concurrency)
    }

    // MARK: - Running

    /// Rewrites what it can and returns how many ids changed.
    ///
    /// Two kinds of change happen here, and only the first needs the network:
    ///
    /// 1. **Resolution** — an IMDb id becomes a TMDB id, so the item dedupes
    ///    against live search results.
    /// 2. **Namespacing** — a bare `tt…` id that could not be resolved becomes
    ///    `imdb:tt…`, so its source is explicit. This happens offline and is
    ///    lossless; the item keeps working exactly as before, it simply will
    ///    not match TMDB results until a later run resolves it.
    @discardableResult
    func run(items: [MediaItem], limit: Int = 500) async -> Int {
        let pending: [Request] = items.compactMap { item in
            guard let externalId = item.externalId,
                  let imdbID = ExternalID.imdbID(from: externalId) else { return nil }
            return Request(itemID: item.id, imdbID: imdbID, type: item.type)
        }
        .prefix(limit)
        .map { $0 }

        guard !pending.isEmpty else { return 0 }

        let resolved = await resolveAll(pending)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var changed = 0
        var touched: [MediaItem] = []
        for result in resolved {
            guard let item = byID[result.itemID] else { continue }

            let newID: String
            if let tmdbId = result.tmdbId {
                newID = TMDBIdentifier.externalId(type: result.type, tmdbId: tmdbId)
            } else {
                newID = ExternalID.imdb(result.imdbID)
            }

            // Comparing before writing is what makes a second run a no-op
            // rather than a no-op-shaped write that still bumps the store.
            if item.externalId != newID {
                item.externalId = newID
                touched.append(item)
                changed += 1
            }
        }

        if changed > 0, touched.saveOwningContexts() == 0 {
            // Saved through the items' own contexts, because saving
            // `modelContext` writes nothing whenever the caller's context is
            // not the one that owns these objects — see `saveOwningContexts`.
            // The injected context is the fallback for detached items.
            try? modelContext.save()
        }
        return changed
    }

    // MARK: - Resolution

    private func resolveAll(_ requests: [Request]) async -> [Result] {
        var results: [Result] = []
        results.reserveCapacity(requests.count)

        var index = 0
        while index < requests.count {
            let end = min(index + concurrency, requests.count)
            let batch = requests[index..<end]

            await withTaskGroup(of: Result.self) { group in
                for request in batch {
                    let resolver = self.resolver
                    group.addTask {
                        let tmdbId = await resolver.resolveIMDbID(
                            request.imdbID,
                            expecting: request.type
                        )
                        return Result(
                            itemID: request.itemID,
                            imdbID: request.imdbID,
                            type: request.type,
                            tmdbId: tmdbId
                        )
                    }
                }
                for await result in group {
                    results.append(result)
                }
            }
            index = end
        }
        return results
    }

    /// The Sendable slice of a `MediaItem` a background lookup needs.
    private struct Request: Sendable {
        let itemID: UUID
        let imdbID: String
        let type: MediaType
    }

    private struct Result: Sendable {
        let itemID: UUID
        let imdbID: String
        let type: MediaType
        let tmdbId: Int?
    }
}
