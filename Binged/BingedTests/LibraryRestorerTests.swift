//
//  LibraryRestorerTests.swift
//  BingedTests
//
//  `LibraryMergeTests` covers what the merge *decides*. This covers what the
//  restorer *does* with a decision, and the one case that matters more than the
//  rest: an unreachable account must not read as an empty one.
//

import Foundation
import Testing

@testable import Binged

@MainActor
@Suite("LibraryRestorer")
struct LibraryRestorerTests {

    private static let userID = UUID()
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private enum Boom: Error { case offline }

    private func remote(
        _ externalId: String,
        title: String = "Restored",
        type: MediaType = .movie,
        sentiment: Sentiment? = .liked,
        rank: Int? = 0,
        updatedAt: Date = epoch
    ) -> RemoteRankedItem {
        .init(
            externalId: externalId,
            mediaType: type,
            sentiment: sentiment,
            title: title,
            year: 2020,
            rankInBucket: rank,
            updatedAt: updatedAt
        )
    }

    private func makeRestorer(
        library: MediaLibraryViewModel,
        service: MockLibraryRestoreService,
        signedIn: Bool = true
    ) -> LibraryRestorer {
        LibraryRestorer(
            library: library,
            service: service,
            currentUserID: { signedIn ? Self.userID : nil }
        )
    }

    // MARK: - Restoring

    @Test("A fresh device receives the account's library")
    func freshDeviceIsPopulated() async throws {
        let library = try makeLibrary()
        let service = MockLibraryRestoreService()
        service.set([remote("tmdb:movie:1"), remote("tmdb:tv:2", type: .tvShow)], for: Self.userID)

        let restorer = makeRestorer(library: library, service: service)
        let restored = await restorer.restore()

        #expect(restored == 2)
        #expect(library.allItems.count == 2)
    }

    @Test("A restored title carries the server's decision time, not the moment it arrived")
    func restoredItemKeepsItsDecisionTime() async throws {
        let library = try makeLibrary()
        let service = MockLibraryRestoreService()
        service.set([remote("tmdb:movie:1", updatedAt: Self.epoch)], for: Self.userID)

        let restorer = makeRestorer(library: library, service: service)
        await restorer.restore()

        let item = try #require(library.allItems.first)
        // Seeding `lastRankedAt` with `.now` would let a restored row win a
        // later conflict merely by having arrived recently.
        #expect(item.lastRankedAt == Self.epoch)
    }

    @Test("Restoring twice for the same account is a no-op")
    func restoreIsOncePerAccount() async throws {
        let library = try makeLibrary()
        let service = MockLibraryRestoreService()
        service.set([remote("tmdb:movie:1")], for: Self.userID)

        let restorer = makeRestorer(library: library, service: service)
        let first = await restorer.restore()
        let second = await restorer.restore()
        #expect(first == 1)
        #expect(second == 0)
        #expect(library.allItems.count == 1)
    }

    @Test("Signed out, a restore does nothing at all")
    func signedOutRestoreIsInert() async throws {
        let library = try makeLibrary()
        let service = MockLibraryRestoreService()
        service.set([remote("tmdb:movie:1")], for: Self.userID)

        let restorer = makeRestorer(library: library, service: service, signedIn: false)

        let restored = await restorer.restore()
        #expect(restored == 0)
        #expect(library.allItems.isEmpty)
    }

    // MARK: - Failure

    @Test("An unreachable account is not treated as an empty one")
    func failureLeavesTheLibraryUntouched() async throws {
        let library = try makeLibrary()
        let film = makeItem("Local Only", type: .movie)
        film.externalId = "tmdb:movie:99"
        library.markWatched(film, sentiment: .liked)
        library.finalizeRanking(for: film)

        let service = MockLibraryRestoreService()
        service.setFailure(Boom.offline)

        let restorer = makeRestorer(library: library, service: service)
        let restored = await restorer.restore()

        // The failure that would be worst: silently reading "unreachable" as
        // "your account is empty", then pushing this device over the top of it.
        #expect(restored == 0)
        #expect(restorer.lastError != nil)
        #expect(library.allItems.count == 1)
        #expect(film.sentiment == .liked)
    }

    @Test("A failed restore is retried, not remembered as done")
    func failureDoesNotMarkTheAccountRestored() async throws {
        let library = try makeLibrary()
        let service = MockLibraryRestoreService()
        service.setFailure(Boom.offline)

        let restorer = makeRestorer(library: library, service: service)
        let whileOffline = await restorer.restore()
        #expect(whileOffline == 0)

        // Network comes back.
        service.setFailure(nil)
        service.set([remote("tmdb:movie:1")], for: Self.userID)

        let afterRecovery = await restorer.restore()
        #expect(afterRecovery == 1)
        #expect(restorer.lastError == nil)
    }

    // MARK: - Merging into a populated device

    @Test("A device that already has a library keeps it and gains the account's")
    func mergeKeepsBothSides() async throws {
        let library = try makeLibrary()
        let film = makeItem("On Device", type: .movie)
        film.externalId = "tmdb:movie:1"
        library.markWatched(film, sentiment: .liked)
        library.finalizeRanking(for: film)

        let service = MockLibraryRestoreService()
        service.set([remote("tmdb:movie:2", title: "On Account")], for: Self.userID)

        let restorer = makeRestorer(library: library, service: service)
        let restored = await restorer.restore()
        #expect(restored == 1)

        let titles = Set(library.allItems.map(\.title))
        #expect(titles == ["On Device", "On Account"])
    }

    @Test("A merged bucket is rescored, so nobody holds a score computed for the old N")
    func mergedBucketIsRecomputed() async throws {
        let library = try makeLibrary()
        let film = makeItem("On Device", type: .movie)
        film.externalId = "tmdb:movie:1"
        library.markWatched(film, sentiment: .liked)
        library.finalizeRanking(for: film)

        let service = MockLibraryRestoreService()
        service.set(
            [remote("tmdb:movie:2", title: "On Account", sentiment: .liked, rank: 1)],
            for: Self.userID
        )

        let restorer = makeRestorer(library: library, service: service)
        await restorer.restore()

        let bucket = library.bucket(for: .liked, type: .movie)
        #expect(bucket.count == 2)

        // Every score is inside the band and distinct — what a recompute over
        // the new N produces, and what a skipped recompute would not.
        let scores = bucket.compactMap(\.score)
        #expect(scores.count == 2)
        let inBand = scores.allSatisfy { Sentiment.liked.scoreRange.contains($0) }
        #expect(inBand)
        #expect(Set(scores).count == 2)
    }

    @Test("A merge leaves the affected bucket owing the server a publish")
    func mergeMarksBucketsDirty() async throws {
        let library = try makeLibrary()
        let service = MockLibraryRestoreService()
        service.set([remote("tmdb:movie:1")], for: Self.userID)

        let restorer = makeRestorer(library: library, service: service)
        await restorer.restore()

        // Restore-then-drain: the drain that follows must have something to
        // send, or the union never reaches the account.
        #expect(!library.pendingPublishes.isEmpty)
    }
}
