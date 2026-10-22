//
//  WatchlistSyncTests.swift
//  BingedTests
//
//  The watchlist is a bucket, and it reaches the account like any other.
//
//  **What this pins, and why it needed pinning.** Every other piece of the queue
//  round trip was already built — `ranked_items` has a `ranked_or_queued`
//  constraint so a three-null row is legal, `RemoteRankedItem.sentiment` is
//  optional and documented as "nil for a want-to-watch entry", the restore path
//  maps a null sentiment straight to `.wantToWatch`, and `PART-IV-SYNC.md` §7
//  says queued titles sync. Only the *outbox* could not name a bucket without a
//  sentiment, so `markDirty` returned early, nothing was ever enqueued, nothing
//  was ever written, and nothing was ever read back. The suite was green
//  throughout: no test asked whether queueing a title owed the server anything.
//
//  So these are all behavioural, and the interesting ones are the transitions.
//  A title that moves between the queue and a bucket owes a publish to *both*,
//  and the one that is easy to miss is the debt owed by the bucket being left.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - Stubs

private final class RecordingTransport: PublishTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var published: [PublishPayload] = []
    private(set) var deleted: [(MediaType, Sentiment?)] = []

    func publish(_ payload: PublishPayload, userID: UUID) async throws {
        lock.lock(); published.append(payload); lock.unlock()
    }

    func deleteBucket(mediaType: MediaType, sentiment: Sentiment?, userID: UUID) async throws {
        lock.lock(); deleted.append((mediaType, sentiment)); lock.unlock()
    }

    /// Forgets what has been deleted so far, so a test can assert that a
    /// *later* step asked for a delete rather than reading an earlier one.
    func forgetDeletes() {
        lock.lock(); deleted.removeAll(); lock.unlock()
    }

    /// The payload for the queue of `type`, if one was sent.
    func queuePayload(_ type: MediaType = .movie) -> PublishPayload? {
        lock.lock(); defer { lock.unlock() }
        return published.last { $0.sentiment == nil && $0.mediaType == type }
    }
}

@MainActor
private func makeEngine(
    _ library: MediaLibraryViewModel, _ transport: RecordingTransport
) -> SyncEngine {
    let userID = UUID()
    return SyncEngine(library: library, transport: transport, currentUserID: { userID })
}

@MainActor
private func queue(_ title: String, _ library: MediaLibraryViewModel) -> MediaItem {
    let item = MediaItem(
        externalId: "tmdb:movie:\(abs(title.hashValue % 100000))",
        title: title, year: 2020, type: .movie
    )
    library.addToWantToWatch(item)
    return item
}

// MARK: - The outbox can name the queue

@Suite("The queue is a publishable bucket")
@MainActor
struct WatchlistOutboxTests {

    @Test("The queue marker cannot collide with a sentiment")
    func markerIsReserved() {
        let raws = Sentiment.allCases.map(\.rawValue)
        #expect(!raws.contains(PendingPublish.queueMarker))
    }

    @Test("Queueing a title enqueues the queue bucket")
    func queueingEnqueues() throws {
        let library = try makeLibrary()
        queue("Sinners", library)

        let keys = library.pendingPublishes.map(\.key)
        #expect(keys.contains(PendingPublish.key(mediaType: .movie, sentiment: nil)))
    }

    @Test("A queue outbox row reads back as the queue, not as a corrupt row")
    func rowRoundTrips() throws {
        let library = try makeLibrary()
        queue("Sinners", library)

        let pending = try #require(library.pendingPublishes.first)
        // The distinction the drain depends on: `sentiment` is nil for the queue
        // *and* for an unparseable row, and one of those gets discarded.
        #expect(pending.sentiment == nil)
        #expect(pending.bucket == .queue)
    }

    @Test("The payload carries every queued title of that type, with no ranking")
    func payloadIsTheWholeQueue() throws {
        let library = try makeLibrary()
        queue("Sinners", library)
        queue("Nosferatu", library)

        let payload = library.publishPayload(mediaType: .movie, sentiment: nil)

        #expect(payload.sentiment == nil)
        #expect(payload.items.count == 2)
        let sentiments = payload.items.map(\.sentiment)
        #expect(sentiments.allSatisfy { $0 == nil })
        let scores = payload.items.map(\.score)
        #expect(scores.allSatisfy { $0 == nil })
        let ranks = payload.items.map(\.rankInBucket)
        #expect(ranks.allSatisfy { $0 == nil })
    }

    @Test("A queued title with no external id is counted, never silently dropped")
    func unpublishableQueuedTitleIsCounted() throws {
        let library = try makeLibrary()
        let orphan = MediaItem(externalId: nil, title: "Home Video", year: 1998, type: .movie)
        library.addToWantToWatch(orphan)

        let payload = library.publishPayload(mediaType: .movie, sentiment: nil)

        #expect(payload.items.isEmpty)
        #expect(payload.unpublishableCount == 1)
    }
}

// MARK: - Transitions

@Suite("Moving in and out of the queue")
@MainActor
struct WatchlistTransitionTests {

    @Test("Draining sends the queue to the server")
    func drainPublishesTheQueue() async throws {
        let library = try makeLibrary()
        let transport = RecordingTransport()
        let engine = makeEngine(library, transport)
        queue("Sinners", library)

        let drained = await engine.drain()

        #expect(drained == 1)
        let payload = try #require(transport.queuePayload())
        #expect(payload.items.map(\.title) == ["Sinners"])
    }

    @Test("Ranking a queued title publishes the bucket AND the emptied queue")
    func rankingLeavesTheQueue() async throws {
        let library = try makeLibrary()
        let transport = RecordingTransport()
        let engine = makeEngine(library, transport)

        let item = queue("Sinners", library)
        await engine.drain()

        _ = library.markWatched(item, sentiment: .liked)
        driveSessionPreferringExisting(vm: library)
        library.finalizeRanking(for: item)
        await engine.drain()

        // The queue is now empty, so its debt is a delete rather than an upsert
        // — and without it the title stays on the watchlist of every other
        // device the account has signed in on.
        let queueDelete = transport.deleted.contains { $0.0 == .movie && $0.1 == nil }
        #expect(queueDelete, "the emptied queue was never sent")

        let ranked = transport.published.last { $0.sentiment == .liked }
        #expect(ranked?.items.map(\.title) == ["Sinners"])
    }

    @Test("Re-queueing a ranked title sends explicit nulls, not an omission")
    func requeueingClearsTheRanking() async throws {
        let library = try makeLibrary()
        let transport = RecordingTransport()
        let engine = makeEngine(library, transport)

        let item = MediaItem(
            externalId: "tmdb:movie:1", title: "Dune", year: 2021, type: .movie
        )
        _ = library.markWatched(item, sentiment: .liked)
        driveSessionPreferringExisting(vm: library)
        library.finalizeRanking(for: item)
        await engine.drain()

        library.addToWantToWatch(item)
        await engine.drain()

        let payload = try #require(transport.queuePayload())
        let row = try #require(payload.items.first)
        #expect(row.title == "Dune")
        // Not merely absent from the payload: present and null. An upsert that
        // omits the column leaves the server's old ranking in place.
        #expect(row.sentiment == nil)
        #expect(row.score == nil)
        #expect(row.rankInBucket == nil)
    }

    @Test("Removing a queued title owes the queue a publish")
    func removingLeavesTheQueue() async throws {
        let library = try makeLibrary()
        let transport = RecordingTransport()
        let engine = makeEngine(library, transport)

        let item = queue("Sinners", library)
        await engine.drain()
        transport.forgetDeletes()

        library.remove(item)
        await engine.drain()

        let queueDelete = transport.deleted.contains { $0.0 == .movie && $0.1 == nil }
        #expect(queueDelete, "a removed queue entry stayed on the account")
    }

    @Test("Each media type has its own queue")
    func queuesAreSeparatedByType() throws {
        let library = try makeLibrary()
        queue("Sinners", library)
        let show = MediaItem(
            externalId: "tmdb:tv:1396", title: "Breaking Bad", year: 2008, type: .tvShow
        )
        library.addToWantToWatch(show)

        let films = library.publishPayload(mediaType: .movie, sentiment: nil)
        let shows = library.publishPayload(mediaType: .tvShow, sentiment: nil)

        #expect(films.items.map(\.title) == ["Sinners"])
        #expect(shows.items.map(\.title) == ["Breaking Bad"])
    }
}
