//
//  UserSearchStateRefreshTests.swift
//  BingedTests
//
//  The follow button on a search row, after the *other* screen changed the answer.
//
//  Reported on 2026-08-27: follow somebody on their profile, tap back, and the
//  row that pushed the profile still says "Follow".
//
//  Both screens are right on their own. `UserProfileView` owns a
//  `UserProfileViewModel` and reads the relationship when it loads;
//  `UserSearchViewModel` owns a `states` dictionary and — before this — seeded
//  it once, reading only the people it had no answer for. Nothing carried the
//  follow from one to the other, and the search list had no reason to look
//  again, so the seeded `.none` outlived the fact it described.
//
//  These tests drive the two view models over a *shared* `MockSocialService`,
//  which is what makes them the round trip rather than two isolated units: the
//  profile's follow writes an edge, and the search list has to see it.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Fixtures

private func person(_ handle: String, isPrivate: Bool = false) -> UserProfile {
    UserProfile(
        id: UUID(), handle: handle, displayName: handle.capitalized, bio: nil,
        avatarURL: nil, isPrivate: isPrivate, createdAt: .now
    )
}

/// Reads relationships fine until told to stop, so a test can fail *only* the
/// refresh and see what the screen keeps.
private final class FlakyStateService: SocialService, @unchecked Sendable {

    let people: [UserProfile]
    private let lock = NSLock()
    private var _states: [UUID: FollowState] = [:]
    private var _failing = false

    init(people: [UserProfile]) { self.people = people }

    func set(_ state: FollowState, for id: UUID) {
        lock.lock(); _states[id] = state; lock.unlock()
    }

    func startFailing() { lock.lock(); _failing = true; lock.unlock() }

    func searchUsers(query: String, limit: Int) async throws -> [UserProfile] { people }

    func followStates(for userIDs: [UUID]) async throws -> [UUID: FollowState] {
        lock.lock()
        defer { lock.unlock() }
        if _failing { throw SocialError.underlying("Could not reach the server.") }
        return _states.filter { userIDs.contains($0.key) }
    }

    func profile(handle: String) async throws -> UserProfile? { nil }
    func relationship(with userID: UUID) async throws -> SocialRelationship { .unknown }
    func follow(_ userID: UUID) async throws -> FollowState { .active }
    func unfollow(_ userID: UUID) async throws {}
    func pendingRequests() async throws -> [UserProfile] { [] }
    func pendingRequestCount(limit: Int) async throws -> Int { 0 }
    func acceptRequest(from userID: UUID) async throws {}
    func rejectRequest(from userID: UUID) async throws {}
    func followers(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
    func following(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
    func block(_ userID: UUID) async throws {}
    func unblock(_ userID: UUID) async throws {}
    func blockedAccounts() async throws -> [UserProfile] { [] }
}

// MARK: - Tests

@MainActor
@Suite("People search — the follow state after a trip to the profile")
struct UserSearchStateRefreshTests {

    /// Results land before their states do, by design. Waiting on the state is
    /// the only reliable thing to wait for.
    private func search(
        _ viewModel: UserSearchViewModel,
        for needle: String,
        until subject: UserProfile
    ) async {
        viewModel.query = needle
        for _ in 0..<100 {
            if viewModel.isStateKnown(for: subject) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The reported bug, end to end and across both view models.
    @Test("Following from the profile updates the row that pushed it")
    func followOnProfileShowsOnTheSearchRow() async {
        let alex = person("alex")
        let social = MockSocialService(people: [alex])
        let search = UserSearchViewModel(service: social)

        await self.search(search, for: "alex", until: alex)
        #expect(search.state(for: alex) == FollowState.none)

        // Tapping the row pushes the profile, which builds its own view model.
        let profile = UserProfileViewModel(social: social, rankings: MockRankingFeedService())
        await profile.load(handle: "alex")
        await profile.toggleFollow()
        #expect(profile.relationship.state == .active)

        // Pop. `UserSearchResults` runs this from `.task` as the list reappears.
        await search.refreshStates()

        #expect(search.state(for: alex) == .active)
        #expect(search.isStateKnown(for: alex))
    }

    /// The same trip in reverse: unfollowing must not leave "Following" behind.
    @Test("Unfollowing from the profile updates the row too")
    func unfollowOnProfileShowsOnTheSearchRow() async {
        let alex = person("alex")
        let social = MockSocialService(people: [alex])
        let search = UserSearchViewModel(service: social)

        _ = try? await social.follow(alex.id)
        await self.search(search, for: "alex", until: alex)
        #expect(search.state(for: alex) == .active)

        let profile = UserProfileViewModel(social: social, rankings: MockRankingFeedService())
        await profile.load(handle: "alex")
        await profile.toggleFollow()

        await search.refreshStates()

        #expect(search.state(for: alex) == FollowState.none)
    }

    /// A private account answers `pending`, and the row must say so rather than
    /// inviting the request to be sent again.
    @Test("A request sent from the profile comes back as pending")
    func pendingRequestShowsOnTheSearchRow() async {
        let sam = person("sam", isPrivate: true)
        let social = MockSocialService(people: [sam])
        let search = UserSearchViewModel(service: social)

        await self.search(search, for: "sam", until: sam)

        let profile = UserProfileViewModel(social: social, rankings: MockRankingFeedService())
        await profile.load(handle: "sam")
        await profile.toggleFollow()

        await search.refreshStates()

        #expect(search.state(for: sam) == .pending)
    }

    /// A refresh is a re-read of something already on screen, so a failed one
    /// has nothing to add. Falling back to `.none` here would do what the bug
    /// does — put "Follow" on a row for somebody the viewer follows — only with
    /// a network error as the excuse.
    @Test("A failed refresh keeps the state already on screen")
    func failedRefreshKeepsWhatIsKnown() async {
        let alex = person("alex")
        let service = FlakyStateService(people: [alex])
        service.set(.active, for: alex.id)
        let search = UserSearchViewModel(service: service)

        await self.search(search, for: "alex", until: alex)
        #expect(search.state(for: alex) == .active)

        service.startFailing()
        await search.refreshStates()

        #expect(search.state(for: alex) == .active)
        #expect(search.isStateKnown(for: alex))
        #expect(search.stateReadFailed)
    }

    /// Nothing on screen, nothing to re-read.
    @Test("A refresh with no results makes no request")
    func refreshWithoutResultsIsANoOp() async {
        let search = UserSearchViewModel(service: MockSocialService())
        await search.refreshStates()
        #expect(search.states.isEmpty)
    }
}
