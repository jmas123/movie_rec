//
//  FollowIdempotencyTests.swift
//  BingedTests
//
//  Tapping Follow twice.
//
//  The bug these are written against reported itself as **"No such account."**
//  on a screen displaying that very account, which is why it survived: the
//  message named the wrong thing entirely.
//
//  The chain. `follow` upserted with `Prefer: resolution=merge-duplicates`,
//  which PostgREST compiles to `INSERT … ON CONFLICT DO UPDATE`. An UPDATE on
//  `follows` is governed by `follows_update`, whose `USING (followee_id =
//  auth.uid())` exists to stop a follower approving their own request — so the
//  second follow, by the follower, was refused by the single policy that makes
//  private accounts mean anything. Postgres raised 42501, PostgREST returned
//  403, `run` mapped `.forbidden` to `SocialError.notFound`, and `notFound`
//  prints "No such account."
//
//  Reproduced against a real Postgres before it was fixed: the first follow
//  returned 201, the second 403, on public and private accounts alike.
//
//  It read as private-only because of the second bug below — people search
//  seeded every row's button to `.none`, so a *pending* request presented
//  itself as un-sent, and a pending request is exactly the thing a user taps
//  again to check whether it went through.
//

import Foundation
import Testing

@testable import Binged

@Suite("Follow is idempotent")
struct FollowIdempotencyTests {

    private static let viewer = UUID()

    private func person(_ handle: String, isPrivate: Bool) -> UserProfile {
        UserProfile(
            id: UUID(), handle: handle, displayName: handle.capitalized, bio: nil,
            avatarURL: nil, isPrivate: isPrivate, createdAt: nil
        )
    }

    @Test("Following a private account twice stays pending and does not throw")
    func secondFollowOfPrivateAccount() async throws {
        let target = person("boo", isPrivate: true)
        let service = MockSocialService(viewer: Self.viewer, people: [target])

        #expect(try await service.follow(target.id) == .pending)
        // The tap that used to produce "No such account."
        #expect(try await service.follow(target.id) == .pending)
    }

    @Test("Following a public account twice stays active")
    func secondFollowOfPublicAccount() async throws {
        let target = person("cal", isPrivate: false)
        let service = MockSocialService(viewer: Self.viewer, people: [target])

        #expect(try await service.follow(target.id) == .active)
        #expect(try await service.follow(target.id) == .active)
    }

    @Test("A second follow never un-accepts a request the followee approved")
    func acceptedRequestSurvivesASecondTap() async throws {
        // The sharp edge in making the mock idempotent: recomputing the state
        // from `isPrivate` would send an accepted follow back to pending, which
        // the real service — doing nothing on conflict — cannot do.
        let target = person("boo", isPrivate: true)
        let service = MockSocialService(viewer: Self.viewer, people: [target])

        _ = try await service.follow(target.id)
        // The followee approves. Seeded directly, because `acceptRequest` acts
        // as the *followee* and the viewer here is the follower.
        service.seedFollow(Self.viewer, follows: target.id, state: .active)
        #expect(try await service.relationship(with: target.id).state == .active)

        #expect(try await service.follow(target.id) == .active)
    }

    @Test("Unfollowing clears the edge, so a later follow starts over")
    func unfollowResets() async throws {
        let target = person("boo", isPrivate: true)
        let service = MockSocialService(viewer: Self.viewer, people: [target])

        _ = try await service.follow(target.id)
        try await service.unfollow(target.id)
        #expect(try await service.relationship(with: target.id).state == .none)

        #expect(try await service.follow(target.id) == .pending)
    }

    // MARK: - Batch states

    @Test("Follow states come back for the accounts that have an edge, and only those")
    func batchStates() async throws {
        let followed = person("cal", isPrivate: false)
        let requested = person("boo", isPrivate: true)
        let stranger = person("dee", isPrivate: false)
        let service = MockSocialService(
            viewer: Self.viewer, people: [followed, requested, stranger]
        )
        _ = try await service.follow(followed.id)
        _ = try await service.follow(requested.id)

        let states = try await service.followStates(
            for: [followed.id, requested.id, stranger.id]
        )

        #expect(states[followed.id] == .active)
        #expect(states[requested.id] == .pending)
        // Absent, or `.none` — either is honest. What it must never be is a
        // state that invites the user to re-send something already sent.
        #expect(states[stranger.id] ?? .none == FollowState.none)
    }
}

// MARK: - The button that lied

@MainActor
@Suite("People search follow state")
struct UserSearchStateTests {

    private static let viewer = UUID()

    private func person(_ handle: String, isPrivate: Bool = false) -> UserProfile {
        UserProfile(
            id: UUID(), handle: handle, displayName: handle.capitalized, bio: nil,
            avatarURL: nil, isPrivate: isPrivate, createdAt: nil
        )
    }

    /// The view model debounces, and results land *before* their follow states
    /// do — so waiting on `.results` is not enough. Waits for the state itself,
    /// which is the thing under test.
    private func search(
        _ viewModel: UserSearchViewModel,
        for needle: String,
        until person: UserProfile
    ) async {
        viewModel.query = needle
        for _ in 0..<100 {
            if viewModel.isStateKnown(for: person) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("A pending request shows as Requested, not as Follow")
    func pendingRequestIsNotOfferedAgain() async throws {
        let target = person("boo", isPrivate: true)
        let service = MockSocialService(viewer: Self.viewer, people: [target])
        _ = try await service.follow(target.id)

        let viewModel = UserSearchViewModel(service: service)
        await search(viewModel, for: "boo", until: target)

        // Was `.none` — "Follow" — which is what sent the user back into the
        // request they had already made.
        #expect(viewModel.state(for: target) == .pending)
        #expect(viewModel.state(for: target).actionTitle == "Requested")
    }

    @Test("Someone already followed shows as Following")
    func followedShowsAsFollowing() async throws {
        let target = person("cal")
        let service = MockSocialService(viewer: Self.viewer, people: [target])
        _ = try await service.follow(target.id)

        let viewModel = UserSearchViewModel(service: service)
        await search(viewModel, for: "cal", until: target)

        #expect(viewModel.state(for: target) == .active)
    }

    @Test("A stranger still shows as Follow")
    func strangerShowsAsFollow() async throws {
        let target = person("dee")
        let service = MockSocialService(viewer: Self.viewer, people: [target])

        let viewModel = UserSearchViewModel(service: service)
        await search(viewModel, for: "dee", until: target)

        #expect(viewModel.state(for: target) == .none)
        #expect(viewModel.state(for: target).actionTitle == "Follow")
    }

    @Test("The button is inert until the relationship has actually been read")
    func buttonWaitsForTheAnswer() async throws {
        // The window the second bug lived in: results are on screen and the
        // states are not back yet. `state(for:)` has to answer something, and
        // what it answers must not be actionable.
        let target = person("boo", isPrivate: true)
        let service = MockSocialService(viewer: Self.viewer, people: [target])
        _ = try await service.follow(target.id)

        let viewModel = UserSearchViewModel(service: service)
        #expect(!viewModel.isStateKnown(for: target))
        #expect(viewModel.state(for: target) == .none)

        await search(viewModel, for: "boo", until: target)
        #expect(viewModel.isStateKnown(for: target))
    }
}
