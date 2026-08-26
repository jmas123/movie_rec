//
//  ProfileRefreshTests.swift
//  BingedTests
//
//  Coming back to a profile you were already reading.
//
//  `UserProfileView` drives `load` from `.task`, and `.task` is cancelled when
//  a view disappears and restarted when it reappears — which is precisely what
//  a push and a pop are. So every trip out to the follower list, the following
//  list, or a title on the ranking came back through `load`.
//
//  It used to reset to `.loading` unconditionally, so the return trip replaced
//  a fully rendered profile with a spinner and re-fetched three requests worth
//  of data the screen already had. Worse, a *failed* re-fetch — one timeout, one
//  cancellation — replaced the profile the user had been reading with an error
//  screen, having discarded a perfectly good one to do it.
//
//  Refreshing on return is still right: following somebody from their following
//  list changes the counts on the screen underneath. These pin the difference
//  between refreshing a page and demolishing it.
//

import Foundation
import Testing

@testable import Binged

// MARK: - Doubles

/// A ranking service that can be told to fail, so a *second* load can go wrong
/// while the first one went right. `MockRankingFeedService` has no failure
/// seam, and adding one there would change a fixture the whole social suite
/// shares.
private final class FlakyRankings: RankingFeedService, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RankedItem] = []
    private var failure: Error?
    private(set) var calls = 0

    func set(_ items: [RankedItem]) {
        lock.lock(); self.items = items; lock.unlock()
    }

    func failNext(with error: Error) {
        lock.lock(); failure = error; lock.unlock()
    }

    func rankedItems(userID: UUID, offset: Int, limit: Int) async throws -> [RankedItem] {
        lock.lock()
        calls += 1
        let thrown = failure
        let current = items
        lock.unlock()

        if let thrown { throw thrown }
        guard offset < current.count else { return [] }
        return Array(current[offset..<min(offset + limit, current.count)])
    }

    func watchers(externalID: String, mediaType: MediaType, limit: Int) async throws -> [TitleWatcher] {
        []
    }
}

private struct Timeout: Error {}

// MARK: - Tests

@MainActor
@Suite("Profile refresh")
struct ProfileRefreshTests {

    private static let viewer = UUID()

    private func subject(isPrivate: Bool = false) -> UserProfile {
        UserProfile(
            id: UUID(), handle: "alex", displayName: "Alex", bio: nil,
            avatarURL: nil, isPrivate: isPrivate, createdAt: nil
        )
    }

    private func rankedItems(_ count: Int) -> [RankedItem] {
        (0..<count).map { index in
            RankedItem(
                externalId: "tmdb:movie:\(index)", mediaType: .movie, sentiment: .liked,
                title: "Film \(index)", year: 2020, score: 9.0 - Double(index),
                rankInBucket: index, bucketSize: count
            )
        }
    }

    private func makeViewModel(
        _ person: UserProfile, rankings: FlakyRankings
    ) -> UserProfileViewModel {
        let social = MockSocialService(viewer: Self.viewer, people: [person])
        return UserProfileViewModel(social: social, rankings: rankings)
    }

    // MARK: The bug

    @Test("Coming back to a profile whose refresh fails keeps the profile")
    func failedRefreshKeepsContent() async throws {
        let person = subject()
        let rankings = FlakyRankings()
        rankings.set(rankedItems(6))
        let viewModel = makeViewModel(person, rankings: rankings)

        await viewModel.load(handle: person.handle)
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.items.count == 6)

        // The pop back, with the network having gone away in the meantime.
        rankings.failNext(with: Timeout())
        await viewModel.load(handle: person.handle)

        #expect(viewModel.phase == .loaded)
        #expect(viewModel.items.count == 6)
        // Reported, not swallowed — but as an alert over a working screen.
        #expect(viewModel.lastError != nil)
    }

    @Test("A cancelled return trip leaves no error behind")
    func cancellationIsNotAnError() async throws {
        let person = subject()
        let rankings = FlakyRankings()
        rankings.set(rankedItems(3))
        let viewModel = makeViewModel(person, rankings: rankings)

        await viewModel.load(handle: person.handle)
        rankings.failNext(with: CancellationError())
        await viewModel.load(handle: person.handle)

        // Navigating away is not a failure to report at the user.
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.lastError == nil)
        #expect(viewModel.items.count == 3)
    }

    @Test("A refresh does pick up what changed")
    func refreshUpdatesContent() async throws {
        // The reason the re-fetch is kept at all: following somebody from their
        // following list changes what this screen should say.
        let person = subject()
        let rankings = FlakyRankings()
        rankings.set(rankedItems(2))
        let viewModel = makeViewModel(person, rankings: rankings)

        await viewModel.load(handle: person.handle)
        #expect(viewModel.items.count == 2)

        rankings.set(rankedItems(5))
        await viewModel.load(handle: person.handle)

        #expect(viewModel.items.count == 5)
        #expect(viewModel.phase == .loaded)
    }

    // MARK: First load is unchanged

    @Test("A first load that fails is still an error screen")
    func firstLoadFailureIsAnError() async throws {
        // Nothing to preserve, so the error is the only thing worth showing.
        let person = subject()
        let rankings = FlakyRankings()
        rankings.failNext(with: Timeout())
        let viewModel = makeViewModel(person, rankings: rankings)

        await viewModel.load(handle: person.handle)

        #expect(viewModel.phase != .loaded)
        if case .error = viewModel.phase {} else {
            Issue.record("expected an error phase, got \(viewModel.phase)")
        }
    }

    @Test("A first load cancelled mid-flight stays loading rather than erroring")
    func firstLoadCancellationStaysLoading() async throws {
        let person = subject()
        let rankings = FlakyRankings()
        rankings.failNext(with: CancellationError())
        let viewModel = makeViewModel(person, rankings: rankings)

        await viewModel.load(handle: person.handle)

        // The view reappears and asks again; an error state here would have
        // outlived the navigation that caused it.
        #expect(viewModel.phase == .loading)
        #expect(viewModel.lastError == nil)
    }

    @Test("An unknown handle is still not found, refresh or not")
    func unknownHandleIsNotFound() async throws {
        let rankings = FlakyRankings()
        let social = MockSocialService(viewer: Self.viewer, people: [])
        let viewModel = UserProfileViewModel(social: social, rankings: rankings)

        await viewModel.load(handle: "nobody")

        #expect(viewModel.phase == .notFound)
    }
}
