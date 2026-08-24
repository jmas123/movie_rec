//
//  PublishGatingTests.swift
//  BingedTests
//
//  What consent gates, and what it deliberately does not.
//
//  The criterion that matters here: **consent decides an audience, not a
//  network.** A signed-in user's ranking reaches their own account whatever
//  they answer — that is what makes signing in on a second device restore it —
//  and the answer reaches the server as a call, never as a column on the rows
//  the client writes. A test that let a refusal stop the sync would be pinning
//  the bug this design inverted: the people most careful about their privacy
//  ending up as the only ones with no backup.
//
//  Uniformity is the database's job, not the client's: `update (is_published)`
//  is revoked from `authenticated`, and a trigger makes a new row inherit its
//  bucket's answer. So these tests assert what the client *asks for* — the
//  whole bucket, and the standing answer re-stated after every drain that
//  created rows. `SupabasePublishTransportTests` covers the wire shape.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - Stubs

private final class CountingTransport: PublishTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var published: [PublishPayload] = []
    private(set) var deleted: [(MediaType, Sentiment)] = []
    /// The last visibility flip asked for, or `nil` if none was.
    private(set) var visibility: Bool?
    var failure: Error?
    /// Fails only the visibility flip, so a test can hold the sync working
    /// while the audience change does not.
    var visibilityFailure: Error?

    var publishedTitles: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(published.flatMap { $0.items.map(\.title) })
    }

    func publish(_ payload: PublishPayload, userID: UUID) async throws {
        if let failure { throw failure }
        lock.lock(); published.append(payload); lock.unlock()
    }

    func deleteBucket(mediaType: MediaType, sentiment: Sentiment, userID: UUID) async throws {
        if let failure { throw failure }
        lock.lock(); deleted.append((mediaType, sentiment)); lock.unlock()
    }

    func setPublished(_ isPublished: Bool, userID: UUID) async throws {
        if let failure = visibilityFailure ?? failure { throw failure }
        lock.lock(); visibility = isPublished; lock.unlock()
    }

    /// Clears the record of the last flip, so a test can assert that a *later*
    /// step asked for one rather than reading an earlier answer.
    func forgetVisibility() {
        lock.lock(); visibility = nil; lock.unlock()
    }
}

private struct Offline: Error {}

@MainActor
private func makeEngine(
    library: MediaLibraryViewModel,
    transport: CountingTransport,
    userID: UUID?,
    consent: PublishConsent
) -> SyncEngine {
    SyncEngine(
        library: library, transport: transport, consent: consent, currentUserID: { userID }
    )
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

// MARK: - Syncing is not gated

@Suite("Syncing happens regardless of consent")
@MainActor
struct UnconditionalSyncTests {

    @Test("An unanswered account still syncs, privately")
    func unansweredSyncsPrivately() async throws {
        let library = try makeLibrary()
        rank("Dune", library)

        let transport = CountingTransport()
        let engine = makeEngine(
            library: library, transport: transport, userID: UUID(), consent: .inMemory()
        )

        #expect(engine.consentDecision == nil)
        #expect(engine.needsConsentDecision)
        #expect(!engine.isVisibleToOthers)

        let drained = await engine.drain()

        #expect(drained == 1)
        #expect(transport.publishedTitles == ["Dune"])
        // Never asks for visibility it was not given. A new bucket inherits
        // `false` from the trigger, so silence here is what keeps it private.
        #expect(transport.visibility == nil, "an unanswered library must not be published")
        #expect(library.pendingPublishes.isEmpty)
    }

    @Test("A refusal syncs too — it only decides who can see it")
    func refusalStillSyncs() async throws {
        let library = try makeLibrary()
        rank("Dune", library)

        let transport = CountingTransport()
        let engine = makeEngine(
            library: library, transport: transport, userID: UUID(), consent: .inMemory()
        )

        try await engine.record(consent: false)

        #expect(engine.consentDecision == false)
        #expect(!engine.isVisibleToOthers)
        #expect(transport.publishedTitles == ["Dune"], "refusing must not cost the backup")
        #expect(transport.visibility == false, "existing rows are hidden too")
        #expect(library.pendingPublishes.isEmpty)
    }

    @Test("Signed out, nothing syncs and the debt is kept")
    func signedOutKeepsTheDebt() async throws {
        let library = try makeLibrary()
        rank("Dune", library)

        let transport = CountingTransport()
        let engine = makeEngine(
            library: library, transport: transport, userID: nil, consent: .inMemory()
        )

        let drained = await engine.drain()

        #expect(drained == 0)
        #expect(transport.published.isEmpty)
        #expect(library.pendingPublishes.count == 1, "the debt was lost")
        #expect(!engine.needsConsentDecision, "nobody to ask")
        #expect(!engine.isVisibleToOthers)
    }

    @Test("A failed sync keeps the debt and never touches local state")
    func failedSyncKeepsDebt() async throws {
        let library = try makeLibrary()
        let item = rank("Dune", library)
        let scoreBefore = item.score

        let transport = CountingTransport()
        transport.failure = Offline()
        let engine = makeEngine(
            library: library, transport: transport, userID: UUID(), consent: .inMemory()
        )

        let drained = await engine.drain()

        #expect(drained == 0)
        #expect(library.pendingPublishes.count == 1)
        #expect(item.score == scoreBefore)
    }
}

// MARK: - Consent decides visibility

@Suite("Consent decides the audience")
@MainActor
struct ConsentVisibilityTests {

    @Test("Granting flips what is already up and marks what goes next")
    func grantingFlipsAndMarks() async throws {
        let library = try makeLibrary()
        rank("Dune", library)
        rank("Arrival", library)

        let transport = CountingTransport()
        let engine = makeEngine(
            library: library, transport: transport, userID: UUID(), consent: .inMemory()
        )
        await engine.drain()
        let privateSends = transport.published.count

        try await engine.record(consent: true)

        #expect(engine.isVisibleToOthers)
        #expect(transport.visibility == true, "rows published before the answer must be flipped")

        // Anything ranked afterwards goes up and is published again, because a
        // brand-new bucket has no sibling rows to inherit from and would
        // otherwise land private under a standing yes.
        transport.forgetVisibility()
        rank("Sicario", library, sentiment: .fine)
        await engine.drain()
        #expect(transport.published.count > privateSends)
        #expect(transport.visibility == true, "a new bucket must adopt the standing answer")
    }

    @Test("A publish sends the whole bucket, which is what makes uniformity possible")
    func bucketIsAllOrNothing() async throws {
        let library = try makeLibrary()
        rank("Dune", library)
        rank("Arrival", library)
        rank("Sicario", library)

        let userID = UUID()
        let transport = CountingTransport()
        let engine = makeEngine(
            library: library, transport: transport, userID: userID,
            consent: .inMemory(granted: true, for: userID)
        )
        await engine.drain()

        let bucket = try #require(transport.published.last)
        #expect(bucket.items.count == 3, "the payload is the whole bucket")
        // The flag itself is the database's: the column is revoked from the
        // client, and the trigger gives a new row whatever its bucket already
        // decided. What the client must not do is publish a partial bucket.
        #expect(transport.visibility == true)
    }

    @Test("The answer is remembered for the account that gave it")
    func answerIsPerAccount() async throws {
        let library = try makeLibrary()
        rank("Dune", library)

        let alice = UUID()
        let bob = UUID()
        let store = PublishConsent.inMemory()
        var signedIn = alice

        let engine = SyncEngine(
            library: library, transport: CountingTransport(), consent: store,
            currentUserID: { signedIn }
        )

        try await engine.record(consent: true)
        #expect(engine.consentDecision == true)

        // A second account on the same device inherits nothing.
        signedIn = bob
        engine.refreshConsent()
        #expect(engine.consentDecision == nil)
        #expect(engine.needsConsentDecision)

        // And the first account's answer survives their return.
        signedIn = alice
        engine.refreshConsent()
        #expect(engine.consentDecision == true)
    }

    @Test("Deleting the account forgets the answer, so the next sign-in is asked")
    func deletionForgetsTheAnswer() async throws {
        let library = try makeLibrary()
        rank("Dune", library)

        let userID = UUID()
        let store = PublishConsent.inMemory()
        let engine = makeEngine(
            library: library, transport: CountingTransport(), userID: userID, consent: store
        )

        try await engine.record(consent: true)
        engine.forgetConsent()

        #expect(engine.consentDecision == nil)
        #expect(store.decision(for: userID) == nil)
    }

    @Test("An empty library is not asked a question about nothing")
    func emptyLibraryIsNotAsked() throws {
        let library = try makeLibrary()
        let engine = makeEngine(
            library: library, transport: CountingTransport(),
            userID: UUID(), consent: .inMemory()
        )
        #expect(!engine.needsConsentDecision)
    }
}

// MARK: - Withdrawing

@Suite("Withdrawing visibility")
@MainActor
struct WithdrawVisibilityTests {

    @Test("Hiding keeps every row — it is not a delete")
    func hidingKeepsRows() async throws {
        let library = try makeLibrary()
        rank("Dune", library)

        let userID = UUID()
        let transport = CountingTransport()
        let engine = makeEngine(
            library: library, transport: transport, userID: userID,
            consent: .inMemory(granted: true, for: userID)
        )
        await engine.drain()

        try await engine.record(consent: false)

        #expect(transport.visibility == false)
        // The backup is the point. Deleting rows to answer a question about
        // other people's access would take something nobody asked to lose.
        #expect(transport.deleted.isEmpty, "withdrawing consent must not delete rows")
    }

    @Test("A failed flip is reported, and the local answer still stands")
    func failedFlipIsReported() async throws {
        let library = try makeLibrary()
        rank("Dune", library)

        let userID = UUID()
        let transport = CountingTransport()
        transport.visibilityFailure = Offline()
        let engine = makeEngine(
            library: library, transport: transport, userID: userID,
            consent: .inMemory(granted: true, for: userID)
        )

        await #expect(throws: Offline.self) {
            try await engine.record(consent: false)
        }

        // Saved locally even though the server was not reached, so the next
        // drain sends the right flag and the UI can offer a retry.
        #expect(engine.consentDecision == false)
        #expect(transport.visibility == nil)
    }

    @Test("The retry re-sends the standing answer")
    func retryResendsTheAnswer() async throws {
        let library = try makeLibrary()
        rank("Dune", library)

        let userID = UUID()
        let transport = CountingTransport()
        transport.visibilityFailure = Offline()
        let engine = makeEngine(
            library: library, transport: transport, userID: userID,
            consent: .inMemory(granted: true, for: userID)
        )
        try? await engine.record(consent: false)

        transport.visibilityFailure = nil
        try await engine.reapplyVisibility()

        #expect(transport.visibility == false)
    }
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
        let engine = makeEngine(
            library: library, transport: transport, userID: userID,
            consent: .inMemory(granted: true, for: userID)
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
        let engine = makeEngine(
            library: library, transport: transport, userID: userID,
            consent: .inMemory(granted: true, for: userID)
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
