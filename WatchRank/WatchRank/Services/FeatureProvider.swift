//
//  FeatureProvider.swift
//  WatchRank
//
//  Backfills the namespaced feature set onto the user's watched items.
//
//  Features are fetched for the **library only**, never for the whole candidate
//  pool. The asymmetry is deliberate and worth stating, because it looks like an
//  omission: the taste profile is built from what the user has ranked, so that
//  is the only set whose features carry evidence. Candidates need features too,
//  but they arrive with the pool page (roadmap Phase 14) rather than costing one
//  request per title here — a thousand extra round trips to enrich titles the
//  user may never see is not a trade worth making.
//
//  One request per watched title is affordable, and it is genuinely one:
//  `append_to_response` folds credits and keywords into the detail call, so a
//  title costs a single round trip rather than three. Results are cached, and a
//  title is only ever fetched once.
//

import Foundation
import SwiftData

// MARK: - FeatureSource

/// The one thing `FeatureProvider` needs from a catalog. Narrower than
/// `MediaService` on purpose — it keeps the provider testable against a stub
/// that does not implement search, and it keeps feature extraction out of the
/// protocol every screen depends on.
protocol FeatureSource: Sendable {
    func features(type: MediaType, tmdbId: Int) async -> TMDBMediaService.ExtractedFeatures?
}

extension TMDBMediaService: FeatureSource {}

// MARK: - FeatureProvider

@MainActor
final class FeatureProvider {

    private let source: FeatureSource
    private let modelContext: ModelContext

    /// How many titles may be in flight at once. TMDB tolerates far more, but
    /// there is nothing to gain: this runs in the background behind a screen the
    /// user is already using, and a narrow window keeps it from competing with
    /// the requests they are actually waiting on.
    private let concurrency: Int

    init(source: FeatureSource, modelContext: ModelContext, concurrency: Int = 4) {
        self.source = source
        self.modelContext = modelContext
        self.concurrency = max(1, concurrency)
    }

    // MARK: - Backfill

    /// Fetches and stores features for every item in `items` that does not have
    /// them yet, and returns how many were enriched.
    ///
    /// Skips items whose `externalId` this app did not mint from TMDB — legacy
    /// IMDb-style ids from the bundled catalog have no TMDB id to look up until
    /// roadmap Phase 12a migrates them. Skipping is correct rather than lossy:
    /// those items keep their genres and simply contribute no feature evidence.
    @discardableResult
    func backfill(items: [MediaItem], limit: Int = 200) async -> Int {
        // Resolve the work list up front. `MediaItem` is a SwiftData model and
        // must not cross a task boundary, so what goes into the task group is a
        // plain `(id, type, tmdbId)` triple and what comes back is plain
        // strings; the models are only ever touched here, on the main actor.
        let pending: [Request] = items.compactMap { item in
            guard item.features.isEmpty,
                  let externalId = item.externalId,
                  let parsed = TMDBIdentifier.parse(externalId) else { return nil }
            return Request(itemID: item.id, type: parsed.type, tmdbId: parsed.tmdbId)
        }
        .prefix(limit)
        .map { $0 }

        guard !pending.isEmpty else { return 0 }

        let fetched = await fetchAll(pending)
        guard !fetched.isEmpty else { return 0 }

        var enriched = 0
        var touched: [MediaItem] = []
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for result in fetched {
            guard let item = byID[result.itemID], !result.keys.isEmpty else { continue }
            item.features = result.keys
            // Only fill the vote average — never overwrite a value already
            // present with a nil from a partial response.
            if let voteAverage = result.voteAverage {
                item.tmdbVoteAverage = voteAverage
            }
            touched.append(item)
            enriched += 1
        }

        if enriched > 0, touched.saveOwningContexts() == 0 {
            // One save for the whole batch — saving per item would multiply
            // SwiftData writes by the size of the library for no benefit — and
            // through the items' own contexts, since saving `modelContext`
            // writes nothing when it is not the context that owns them. The
            // injected context is the fallback for detached items.
            try? modelContext.save()
        }
        return enriched
    }

    // MARK: - Fetching

    private func fetchAll(_ requests: [Request]) async -> [Result] {
        var results: [Result] = []
        results.reserveCapacity(requests.count)

        // A sliding window rather than one group over everything: with a large
        // library, spawning a child task per title would queue hundreds of
        // requests the moment the app launches.
        var index = 0
        while index < requests.count {
            let end = min(index + concurrency, requests.count)
            let batch = requests[index..<end]

            await withTaskGroup(of: Result?.self) { group in
                for request in batch {
                    let source = self.source
                    group.addTask {
                        guard let extracted = await source.features(
                            type: request.type,
                            tmdbId: request.tmdbId
                        ) else { return nil }
                        return Result(
                            itemID: request.itemID,
                            keys: extracted.keys,
                            voteAverage: extracted.voteAverage
                        )
                    }
                }
                for await result in group {
                    if let result { results.append(result) }
                }
            }
            index = end
        }
        return results
    }

    /// The Sendable slice of a `MediaItem` that a background fetch needs.
    private struct Request: Sendable {
        let itemID: UUID
        let type: MediaType
        let tmdbId: Int
    }

    private struct Result: Sendable {
        let itemID: UUID
        let keys: [String]
        let voteAverage: Double?
    }
}
