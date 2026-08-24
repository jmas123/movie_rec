//
//  SyncEngineTests.swift
//  BingedTests
//
//  The outbox and its drain.
//
//  The criterion that matters most: **a publish payload always contains every
//  item in the affected bucket.** Publishing only the touched item is the
//  vacated-bucket bug with a network in the middle — every score in a bucket is
//  a quantile over its size, so the survivors would be left on the server
//  holding scores computed for the old N.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - Transport stub

private final class RecordingTransport: PublishTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var published: [PublishPayload] = []
    private(set) var deleted: [(MediaType, Sentiment)] = []
    private(set) var visibility: Bool?
    var failure: Error?

    func publish(_ payload: PublishPayload, userID: UUID) async throws {
        if let failure { throw failure }
        lock.lock(); published.append(payload); lock.unlock()
    }

    func setPublished(_ isPublished: Bool, userID: UUID) async throws {
        if let failure { throw failure }
        lock.lock(); visibility = isPublished; lock.unlock()
    }

    func deleteBucket(mediaType: MediaType, sentiment: Sentiment, userID: UUID) async throws {
        if let failure { throw failure }
        lock.lock(); deleted.append((mediaType, sentiment)); lock.unlock()
    }
}

private struct AlwaysFails: Error {}

/// A consented engine, which is what most of these tests are about: the gate
/// itself is covered in `PublishGatingTests`, and repeating it here would make
/// every publish test also a consent test.
@MainActor
private func makeEngine(
    library: MediaLibraryViewModel,
    transport: RecordingTransport,
    userID: UUID? = UUID()
) -> SyncEngine {
    SyncEngine(
        library: library,
        transport: transport,
        consent: .inMemory(granted: true, for: userID ?? UUID()),
        currentUserID: { userID }
    )
}

/// Ranks `title` into `sentiment`, driving any comparison to completion.
@MainActor
private func rank(
    _ title: String, _ library: MediaLibraryViewModel,
    sentiment: Sentiment = .liked, type: MediaType = .movie, id: String? = nil
) -> MediaItem {
    let item = MediaItem(
        externalId: id ?? "tmdb:\(type == .movie ? "movie" : "tv"):\(abs(title.hashValue % 100000))",
        title: title, year: 2020, type: type
    )
    library.markWatched(item, sentiment: sentiment)
    driveSessionPreferringExisting(vm: library)
    library.finalizeRanking(for: item)
    return item
}

// MARK: - Outbox

@Suite("Outbox")
@MainActor
struct OutboxTests {

    @Test("Ranking a title marks its bucket as owing a publish")
    func rankingEnqueues() throws {
        let library = try makeLibrary()
        _ = rank("First", library)

        let pending = library.pendingPublishes
        #expect(pending.count == 1)
        #expect(pending.first?.mediaType == .movie)
        #expect(pending.first?.sentiment == .liked)
    }

    @Test("Five titles in one bucket coalesce to one row")
    func enqueuesCoalesce() throws {
        // The queue must not grow with how fast the user ranks — only with how
        // many buckets they touch.
        let library = try makeLibrary()
        for index in 0..<5 { _ = rank("T\(index)", library) }

        #expect(library.pendingPublishes.count == 1)
    }

    @Test("Each bucket gets its own row")
    func bucketsAreSeparate() throws {
        let library = try makeLibrary()
        _ = rank("Film", library, sentiment: .liked, type: .movie)
        _ = rank("Show", library, sentiment: .liked, type: .tvShow)
        _ = rank("Meh", library, sentiment: .fine, type: .movie)

        #expect(library.pendingPublishes.count == 3)
    }

    @Test("Reordering enqueues, because every score in the bucket changed")
    func reorderEnqueues() throws {
        let library = try makeLibrary()
        _ = rank("A", library)
        _ = rank("B", library)
        for pending in library.pendingPublishes { library.clearPendingPublish(pending) }
        #expect(library.pendingPublishes.isEmpty)

        library.reorder(in: .liked, type: .movie, from: IndexSet(integer: 0), to: 2)
        #expect(library.pendingPublishes.count == 1)
    }

    @Test("A title leaving a bucket enqueues the bucket it left")
    func vacatingEnqueuesTheOldBucket() throws {
        // The vacated-bucket rule, one layer out: the survivors' scores were all
        // recomputed, so the server's copy of that bucket is now stale.
        let library = try makeLibrary()
        let item = rank("Leaving", library, sentiment: .liked)
        _ = rank("Staying", library, sentiment: .liked)
        for pending in library.pendingPublishes { library.clearPendingPublish(pending) }

        library.addToWantToWatch(item)

        let keys = library.pendingPublishes.map(\.key)
        #expect(keys.contains(PendingPublish.key(mediaType: .movie, sentiment: .liked)))
    }

    @Test("The outbox survives a relaunch")
    func outboxPersists() throws {
        // Killing the app mid-publish must lose nothing, which is the whole
        // reason this is a persisted model rather than an in-memory queue.
        let container = try makeContainer()
        let library = makeLibrary(in: container)
        _ = rank("Queued", library)

        let reopened = makeLibrary(in: container)
        #expect(reopened.pendingPublishes.count == 1)
    }
}

// MARK: - Payloads

@Suite("Publish payloads")
@MainActor
struct PublishPayloadTests {

    @Test("A payload carries the whole bucket, not just the touched item")
    func payloadIsTheWholeBucket() throws {
        // The acceptance criterion. Sending one row would leave every survivor
        // on the server holding a score computed for the old bucket size.
        let library = try makeLibrary()
        for index in 0..<4 { _ = rank("T\(index)", library) }

        let payload = library.publishPayload(mediaType: .movie, sentiment: .liked)
        #expect(payload.items.count == 4)
        #expect(Set(payload.items.map(\.rankInBucket)) == [0, 1, 2, 3])
    }

    @Test("Every row carries the bucket size, so a viewer can apply rule 6")
    func bucketSizeTravels() throws {
        let library = try makeLibrary()
        for index in 0..<3 { _ = rank("T\(index)", library) }

        let payload = library.publishPayload(mediaType: .movie, sentiment: .liked)
        #expect(payload.items.allSatisfy { $0.bucketSize == 3 })
    }

    @Test("A title with no external id is counted, never silently dropped")
    func unpublishableItemsAreCounted() throws {
        let library = try makeLibrary()
        _ = rank("Has an id", library, id: "tmdb:movie:1")

        // A bundled-catalog title, or an id migration that never resolved.
        let anonymous = MediaItem(title: "No id", year: 2020, type: .movie)
        library.markWatched(anonymous, sentiment: .liked)
        driveSessionPreferringExisting(vm: library)
        library.finalizeRanking(for: anonymous)

        let payload = library.publishPayload(mediaType: .movie, sentiment: .liked)
        #expect(payload.items.count == 1)
        #expect(payload.unpublishableCount == 1)
    }

    @Test("An emptied bucket is a delete, not an empty upsert")
    func emptiedBucketIsFlagged() throws {
        // Leaving the rows behind would keep an un-watched title visible to
        // followers.
        let library = try makeLibrary()
        let only = rank("Alone", library)
        library.addToWantToWatch(only)

        let payload = library.publishPayload(mediaType: .movie, sentiment: .liked)
        #expect(payload.isEmptying)
        #expect(payload.items.isEmpty)
    }
}

// MARK: - Draining

@Suite("SyncEngine")
@MainActor
struct SyncEngineTests {

    @Test("Draining publishes each dirty bucket once and clears the queue")
    func drainPublishesAndClears() async throws {
        let library = try makeLibrary()
        _ = rank("Film", library, type: .movie)
        _ = rank("Show", library, type: .tvShow)

        let transport = RecordingTransport()
        let drained = await makeEngine(library: library, transport: transport).drain()

        #expect(drained == 2)
        #expect(transport.published.count == 2)
        #expect(library.pendingPublishes.isEmpty)
    }

    @Test("Signed out, nothing publishes and the debt is kept")
    func signedOutKeepsTheQueue() async throws {
        // The outbox accrues until there is somebody to publish for.
        let library = try makeLibrary()
        _ = rank("Waiting", library)

        let transport = RecordingTransport()
        let drained = await makeEngine(library: library, transport: transport, userID: nil).drain()

        #expect(drained == 0)
        #expect(transport.published.isEmpty)
        #expect(library.pendingPublishes.count == 1, "the debt was lost while signed out")
    }

    @Test("A failed publish keeps the row and never touches local state")
    func failureIsNonDestructive() async throws {
        // The ranking is the user's; the server holds a copy. A network problem
        // must never cost them a score.
        let library = try makeLibrary()
        _ = rank("A", library)
        _ = rank("B", library)
        let before = library.bucket(for: .liked, type: .movie).map(\.score)

        let transport = RecordingTransport()
        transport.failure = AlwaysFails()
        let drained = await makeEngine(library: library, transport: transport).drain()

        #expect(drained == 0)
        #expect(library.pendingPublishes.count == 1)
        #expect(library.pendingPublishes.first?.attempts == 1)
        #expect(library.bucket(for: .liked, type: .movie).map(\.score) == before)
    }

    @Test("Draining twice is a no-op the second time")
    func drainIsIdempotent() async throws {
        let library = try makeLibrary()
        _ = rank("Once", library)

        let transport = RecordingTransport()
        let engine = makeEngine(library: library, transport: transport)

        #expect(await engine.drain() == 1)
        #expect(await engine.drain() == 0)
        #expect(transport.published.count == 1)
    }

    @Test("An emptied bucket drains as a delete")
    func emptiedBucketDeletes() async throws {
        let library = try makeLibrary()
        let only = rank("Alone", library)
        library.addToWantToWatch(only)

        let transport = RecordingTransport()
        await makeEngine(library: library, transport: transport).drain()

        #expect(transport.deleted.contains { $0.0 == .movie && $0.1 == .liked })
        #expect(transport.published.isEmpty)
    }

    @Test("Unpublishable titles are reported rather than hidden")
    func unpublishableAreSurfaced() throws {
        let library = try makeLibrary()
        let anonymous = MediaItem(title: "No id", year: 2020, type: .movie)
        library.markWatched(anonymous, sentiment: .liked)
        library.finalizeRanking(for: anonymous)

        let engine = makeEngine(library: library, transport: RecordingTransport())
        #expect(engine.unpublishableCount == 1)
    }

    @Test("Ranking never waits on the network")
    func rankingIsLocalLatency() throws {
        // Part III's second invariant. The comparison flow resolves against the
        // store alone; publishing is a separate, later, failable thing.
        let library = try makeLibrary()
        let transport = RecordingTransport()
        transport.failure = AlwaysFails()
        _ = makeEngine(library: library, transport: transport)

        let item = rank("Ranked while offline", library)

        #expect(item.score != nil)
        #expect(library.bucket(for: .liked, type: .movie).count == 1)
        #expect(transport.published.isEmpty, "ranking published synchronously")
    }
}
