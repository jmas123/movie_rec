//
//  ExternalIDMigrationTests.swift
//  WatchRankTests
//
//  The migration exists to stop one specific, silent failure: a library built
//  against the bundled catalog no longer recognising its own titles once search
//  starts returning TMDB ids. The tests are written around that failure rather
//  than around the method's signature.
//

import Foundation
import SwiftData
import Testing
@testable import WatchRank

// MARK: - Stub resolver

/// Resolves a fixed table of IMDb ids, and records what it was asked.
///
/// Keyed by `(imdbID, type)` so a test can prove the migration constrains a
/// lookup to the media type it expects — resolving a film's id into a series is
/// the mistake that would merge two unrelated library entries.
final class StubIMDbResolver: IMDbResolver, @unchecked Sendable {

    private let lock = NSLock()
    private let table: [String: (type: MediaType, tmdbId: Int)]
    private var _lookups: [String] = []

    /// When true, every lookup fails — the offline case.
    private let alwaysFails: Bool

    init(table: [String: (type: MediaType, tmdbId: Int)] = [:], alwaysFails: Bool = false) {
        self.table = table
        self.alwaysFails = alwaysFails
    }

    var lookups: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _lookups
    }

    func resolveIMDbID(_ imdbID: String, expecting type: MediaType) async -> Int? {
        lock.lock()
        _lookups.append(imdbID)
        lock.unlock()

        guard !alwaysFails, let entry = table[imdbID], entry.type == type else { return nil }
        return entry.tmdbId
    }
}

// MARK: - ExternalID

@Suite("ExternalID")
struct ExternalIDTests {

    @Test("Both historical forms of an IMDb id canonicalise to one value")
    func bothFormsCollapse() {
        // The whole point: a stored bare id and a freshly minted namespaced one
        // are the same title and must never read as two.
        #expect(ExternalID.canonical("tt1375666") == ExternalID.canonical("imdb:tt1375666"))
        #expect(ExternalID.canonical("tt1375666") == "imdb:tt1375666")
    }

    @Test("TMDB ids pass through untouched")
    func tmdbIdsUnchanged() {
        #expect(ExternalID.canonical("tmdb:movie:27205") == "tmdb:movie:27205")
        #expect(ExternalID.imdbID(from: "tmdb:movie:27205") == nil)
    }

    @Test(
        "Only genuine IMDb ids are recognised",
        arguments: ["tt", "ttabc", "27205", "", "imdb:", "imdb:27205", "tmdb:movie:1"]
    )
    func rejectsNonIMDbIds(_ id: String) {
        // Shape is checked, not just the prefix — otherwise a TMDB id could be
        // rewritten into a nonsense IMDb one.
        #expect(ExternalID.imdbID(from: id) == nil)
    }

    @Test("Extracts the bare id from either form")
    func extractsBareID() {
        #expect(ExternalID.imdbID(from: "tt0111161") == "tt0111161")
        #expect(ExternalID.imdbID(from: "imdb:tt0111161") == "tt0111161")
    }
}

// MARK: - Migration

@Suite("ExternalIDMigration")
@MainActor
struct ExternalIDMigrationTests {

    private func makeStoredItem(
        _ title: String,
        externalId: String,
        type: MediaType = .movie,
        in library: MediaLibraryViewModel
    ) -> MediaItem {
        let item = MediaItem(externalId: externalId, title: title, year: 2010, type: type)
        library.addToWantToWatch(item)
        return item
    }

    @Test("A legacy library dedupes against TMDB search after migrating")
    func migratedLibraryDedupesAgainstTMDB() async throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)

        // A library as it existed before the live catalog.
        let stored = makeStoredItem("Inception", externalId: "tt1375666", in: library)

        let resolver = StubIMDbResolver(table: ["tt1375666": (.movie, 27205)])
        let migrated = await ExternalIDMigration(
            resolver: resolver,
            modelContext: container.mainContext
        ).run(items: library.allItems)

        #expect(migrated == 1)
        #expect(stored.externalId == "tmdb:movie:27205")

        // The failure this whole phase exists to prevent: a fresh TMDB search
        // result for the same film must resolve to the item already stored, not
        // to a second copy the user can rank against the first.
        let fromSearch = MediaItem(
            externalId: "tmdb:movie:27205",
            title: "Inception",
            year: 2010,
            type: .movie
        )
        #expect(library.canonicalItem(for: fromSearch) === stored)
    }

    @Test("Running twice changes nothing the second time")
    func isIdempotent() async throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)
        _ = makeStoredItem("Inception", externalId: "tt1375666", in: library)

        let resolver = StubIMDbResolver(table: ["tt1375666": (.movie, 27205)])
        let migration = ExternalIDMigration(resolver: resolver, modelContext: container.mainContext)

        #expect(await migration.run(items: library.allItems) == 1)

        // The second run must not rewrite, not re-save, and not look anything
        // up — a migrated id no longer matches the work filter at all.
        #expect(await migration.run(items: library.allItems) == 0)
        #expect(resolver.lookups == ["tt1375666"])
    }

    @Test("An unresolvable id is namespaced, not lost, and is retried later")
    func unresolvedIdsSurviveAndRetry() async throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)
        let stored = makeStoredItem("Obscure Film", externalId: "tt9999999", in: library)

        // First launch: no network.
        let offline = StubIMDbResolver(alwaysFails: true)
        _ = await ExternalIDMigration(resolver: offline, modelContext: container.mainContext)
            .run(items: library.allItems)

        // Namespaced rather than left bare, and emphatically not cleared — the
        // item still works, it simply will not match TMDB results yet.
        #expect(stored.externalId == "imdb:tt9999999")
        #expect(stored.title == "Obscure Film")

        // A later launch with the network back must pick it up. Stranding it
        // would mean one offline launch permanently orphaned the title.
        let online = StubIMDbResolver(table: ["tt9999999": (.movie, 4242)])
        #expect(await ExternalIDMigration(
            resolver: online,
            modelContext: container.mainContext
        ).run(items: library.allItems) == 1)
        #expect(stored.externalId == "tmdb:movie:4242")
    }

    @Test("A film never resolves into a series with the same IMDb id")
    func typeMismatchDoesNotResolve() async throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)
        let film = makeStoredItem("Fargo", externalId: "tt0116282", type: .movie, in: library)

        // TMDB knows this id only as a series. Accepting it would merge the
        // film the user ranked with an unrelated show.
        let resolver = StubIMDbResolver(table: ["tt0116282": (.tvShow, 60622)])
        _ = await ExternalIDMigration(resolver: resolver, modelContext: container.mainContext)
            .run(items: library.allItems)

        #expect(film.externalId == "imdb:tt0116282")
    }

    @Test("Items already on TMDB ids are left alone and cost no lookup")
    func tmdbItemsAreSkipped() async throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)
        let item = makeStoredItem("Inception", externalId: "tmdb:movie:27205", in: library)

        let resolver = StubIMDbResolver()
        #expect(await ExternalIDMigration(
            resolver: resolver,
            modelContext: container.mainContext
        ).run(items: library.allItems) == 0)

        #expect(item.externalId == "tmdb:movie:27205")
        #expect(resolver.lookups.isEmpty)
    }

    @Test("Items with no external id are untouched")
    func itemsWithoutIdsAreUntouched() async throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)
        let handmade = makeStoredItem("Home Video", externalId: "", in: library)
        handmade.externalId = nil

        let resolver = StubIMDbResolver()
        #expect(await ExternalIDMigration(
            resolver: resolver,
            modelContext: container.mainContext
        ).run(items: library.allItems) == 0)
        #expect(handmade.externalId == nil)
    }

    @Test("Migrated ids survive a relaunch")
    func migrationPersists() async throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)
        let stored = makeStoredItem("Inception", externalId: "tt1375666", in: library)
        let id = stored.id

        let resolver = StubIMDbResolver(table: ["tt1375666": (.movie, 27205)])
        _ = await ExternalIDMigration(resolver: resolver, modelContext: container.mainContext)
            .run(items: library.allItems)

        // Read through a fresh context: a migration that only mutated objects
        // in memory would pass every assertion above and still lose the work.
        let refetched = try refetch(stored, in: container)
        #expect(refetched?.id == id)
        #expect(refetched?.externalId == "tmdb:movie:27205")
    }

    @Test("A ranked item keeps its score and bucket through migration")
    func rankingSurvivesMigration() async throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)

        let item = MediaItem(externalId: "tt1375666", title: "Inception", year: 2010, type: .movie)
        library.markWatched(item, sentiment: .liked)
        driveSessionPreferringExisting(vm: library)
        library.finalizeRanking(for: item)

        let scoreBefore = item.score
        let rankBefore = item.rankInBucket

        let resolver = StubIMDbResolver(table: ["tt1375666": (.movie, 27205)])
        _ = await ExternalIDMigration(resolver: resolver, modelContext: container.mainContext)
            .run(items: library.allItems)

        // The migration touches identity, nothing else. A rewrite that reset
        // ranking state would silently undo the user's comparisons.
        #expect(item.score == scoreBefore)
        #expect(item.rankInBucket == rankBefore)
        #expect(item.sentiment == .liked)
        expectNoStrandedItems(library)
    }
}
