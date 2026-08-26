//
//  UserSearchStateFailureTests.swift
//  BingedTests
//
//  What the follow button does when the relationship read *fails*.
//
//  Sibling to the `UserSearchStateTests` suite in `FollowIdempotencyTests`,
//  which covers the states that are read successfully — already following,
//  request pending. This file covers the case that has no state at all.
//
//  Reported from a device on 2026-08-26: searching for an account showed the row
//  correctly with Follow greyed out and unresponsive, permanently, on both
//  people-search surfaces.
//
//  `UserRow` renders `.disabled(!isStateKnown).opacity(isStateKnown ? 1 : 0.4)`
//  and `isStateKnown` is `states[id] != nil`, so a button that never un-greys
//  means the state was never written. `seedStates` swallowed the error with
//  `try?` and returned, which is indistinguishable from a read that has not
//  finished — except that it never will.
//
//  The withholding itself is right, and the suite above proves why: offering
//  Follow before the state is known is how a pending request gets sent twice.
//  What was missing is the difference between *not yet* and *never*.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Stubs

private func person(_ handle: String) -> UserProfile {
    UserProfile(
        id: UUID(), handle: handle, displayName: handle.capitalized, bio: nil,
        avatarURL: nil, isPrivate: false, createdAt: .now
    )
}

/// Counts searches, so a test can prove a no-op query assignment did not
/// silently restart one.
private final class CountingSocialService: SocialService, @unchecked Sendable {

    let people: [UserProfile]
    private let lock = NSLock()
    private var _searches = 0

    var searches: Int {
        lock.lock(); defer { lock.unlock() }
        return _searches
    }

    init(people: [UserProfile]) { self.people = people }

    func searchUsers(query: String, limit: Int) async throws -> [UserProfile] {
        lock.lock(); _searches += 1; lock.unlock()
        return people
    }

    func followStates(for userIDs: [UUID]) async throws -> [UUID: FollowState] {
        // A real network read is not instant, and the bug lives in the window
        // between results landing and states landing. Without a suspension here
        // the race cannot be expressed at all.
        try await Task.sleep(for: .milliseconds(120))
        return [:]
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

/// Finds people but cannot read relationships — a build where search works and
/// the follows query does not.
private final class HalfBrokenSocialService: SocialService, @unchecked Sendable {

    let people: [UserProfile]

    init(people: [UserProfile]) { self.people = people }

    func searchUsers(query: String, limit: Int) async throws -> [UserProfile] { people }

    func followStates(for userIDs: [UUID]) async throws -> [UUID: FollowState] {
        throw SocialError.underlying("Could not reach the server.")
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
@Suite("People search — a failed follow-state read")
struct UserSearchStateFailureTests {

    /// Polls rather than sleeping a fixed interval: results land before states
    /// do by design, so the thing to wait for is the state itself.
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

    /// The reported bug, as an assertion. Without the fix this times out with
    /// `isStateKnown` still false — a button disabled for good.
    @Test("A failed read leaves the button usable rather than inert")
    func failedReadDoesNotStrandTheButton() async {
        let jude = person("jude123")
        let viewModel = UserSearchViewModel(service: HalfBrokenSocialService(people: [jude]))

        await search(viewModel, for: "jude123", until: jude)

        // Search itself worked, so the row is on screen.
        #expect(viewModel.phase == .results)
        #expect(viewModel.results.count == 1)

        #expect(
            viewModel.isStateKnown(for: jude),
            "a failed read must not leave Follow permanently disabled"
        )
        #expect(viewModel.state(for: jude) == .none, "and it must offer the only action it can")
    }

    /// A dead control is bad; one that says nothing is worse — the user cannot
    /// tell a broken read from an app that has decided they may not follow this
    /// person.
    @Test("A failed read is recorded rather than swallowed")
    func failedReadIsRecorded() async {
        let jude = person("jude123")
        let viewModel = UserSearchViewModel(service: HalfBrokenSocialService(people: [jude]))

        await search(viewModel, for: "jude123", until: jude)

        #expect(viewModel.stateReadFailed)
    }

    /// Why offering the button after a failed read is safe: `follow` is
    /// idempotent server-side and returns the resulting state, so the first tap
    /// self-corrects whatever the client assumed.
    @Test("Following after a failed read records the server's answer")
    func followAfterFailedReadUsesServerTruth() async {
        let jude = person("jude123")
        let viewModel = UserSearchViewModel(service: HalfBrokenSocialService(people: [jude]))

        await search(viewModel, for: "jude123", until: jude)
        await viewModel.toggleFollow(jude)

        #expect(viewModel.state(for: jude) == .active)
    }

    /// The root cause of the device report.
    ///
    /// `didSet` fires on every assignment, so a `.searchable` binding writing
    /// the same string back used to cancel the in-flight task and re-arm the
    /// debounce. Because `seedStates` runs after `results` is published inside
    /// that task, the write-back killed the follow-state read before it stored
    /// anything — and every restart re-entered the same window, so the button
    /// never un-greyed.
    @Test("Re-assigning the same query does not restart the search")
    func noOpQueryAssignmentIsIgnored() async {
        let jude = person("jude123")
        let service = CountingSocialService(people: [jude])
        let viewModel = UserSearchViewModel(service: service)

        viewModel.query = "jude123"
        // The write-back SwiftUI can perform while the first search is still in
        // flight. Same value, so it must change nothing.
        try? await Task.sleep(for: UserSearchViewModel.debounce + .milliseconds(40))
        viewModel.query = "jude123"

        for _ in 0..<100 {
            if viewModel.isStateKnown(for: jude) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(service.searches == 1, "a no-op assignment must not re-run the search")
        #expect(
            viewModel.isStateKnown(for: jude),
            "the follow-state read must survive a redundant query write"
        )
    }

    /// The success path must not have been broken on the way past: a genuine
    /// "no edge" answer still has to enable the button and clear the flag.
    @Test("A successful read still seeds no-edge as Follow")
    func successfulReadStillWorks() async {
        let jude = person("jude123")
        let service = MockSocialService(viewer: UUID(), people: [jude])
        let viewModel = UserSearchViewModel(service: service)

        await search(viewModel, for: "jude123", until: jude)

        #expect(viewModel.isStateKnown(for: jude))
        #expect(viewModel.state(for: jude) == .none)
        #expect(!viewModel.stateReadFailed)
    }
}
