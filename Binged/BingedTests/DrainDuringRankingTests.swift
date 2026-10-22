//
//  DrainDuringRankingTests.swift
//  BingedTests
//
//  The one thing that holds a drain back other than being signed out.
//
//  A bucket mid-comparison is not a bucket to publish: `markWatched` assigns a
//  provisional midpoint the user has not agreed to yet, and `finalizeRanking`
//  saves again the moment the session closes. Sending the intermediate state
//  would put a position on the server that the user is still deciding, and then
//  correct it a few taps later — visible to a follower as a ranking that moved
//  on its own.
//
//  Kept when `PublishGatingTests` was deleted with the consent flow it tested.
//  Nothing else in the suite exercises this gate: `MediaLibraryViewModelTests`
//  asserts that `isRankingInProgress` is *set*, not that the drain respects it.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - Stubs

private final class CountingTransport: PublishTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var published: [PublishPayload] = []
    private(set) var deleted: [(MediaType, Sentiment?)] = []

    func publish(_ payload: PublishPayload, userID: UUID) async throws {
        lock.lock(); published.append(payload); lock.unlock()
    }

    func deleteBucket(mediaType: MediaType, sentiment: Sentiment?, userID: UUID) async throws {
        lock.lock(); deleted.append((mediaType, sentiment)); lock.unlock()
    }
}

/// Ranks one title to completion.
@MainActor
@discardableResult
private func rank(
    _ title: String, _ library: MediaLibraryViewModel, sentiment: Sentiment = .liked
) -> MediaItem {
    let item = MediaItem(
        externalId: "tmdb:movie:\(abs(title.hashValue % 100000))",
        title: title, year: 2020, type: .movie
    )
    library.markWatched(item, sentiment: sentiment)
    driveSessionPreferringExisting(vm: library)
    library.finalizeRanking(for: item)
    return item
}

// MARK: - A ranking in progress

@Suite("Draining around a comparison session")
@MainActor
struct DrainDuringRankingTests {

    @Test("A bucket mid-comparison is not sent")
    func midComparisonIsNotSent() async throws {
        let library = try makeLibrary()
        // Two settled titles, so the third opens a real comparison session.
        rank("Dune", library)
        rank("Arrival", library)

        let userID = UUID()
        let transport = CountingTransport()
        let engine = SyncEngine(
            library: library, transport: transport, currentUserID: { userID }
        )
        await engine.drain()
        let settled = transport.published.count

        let pending = MediaItem(
            externalId: "tmdb:movie:999", title: "Sicario", year: 2015, type: .movie
        )
        library.markWatched(pending, sentiment: .liked)
        #expect(library.isRankingInProgress, "expected an open comparison session")

        let drained = await engine.drain()

        #expect(drained == 0)
        #expect(transport.published.count == settled, "a half-ranked bucket was sent")
    }

    @Test("Finishing the comparison lets the same bucket through")
    func finalizingReleasesTheBucket() async throws {
        let library = try makeLibrary()
        rank("Dune", library)
        rank("Arrival", library)

        let userID = UUID()
        let transport = CountingTransport()
        let engine = SyncEngine(
            library: library, transport: transport, currentUserID: { userID }
        )
        await engine.drain()

        let pending = MediaItem(
            externalId: "tmdb:movie:999", title: "Sicario", year: 2015, type: .movie
        )
        library.markWatched(pending, sentiment: .liked)
        await engine.drain()

        driveSessionPreferringExisting(vm: library)
        library.finalizeRanking(for: pending)
        #expect(!library.isRankingInProgress)

        let drained = await engine.drain()

        #expect(drained == 1)
        let lastPayload = try #require(transport.published.last)
        let titles = lastPayload.items.map(\.title)
        #expect(titles.contains("Sicario"))
        #expect(titles.count == 3, "the payload is the whole bucket")
    }
}
