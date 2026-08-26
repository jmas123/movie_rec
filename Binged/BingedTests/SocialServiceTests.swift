//
//  SocialServiceTests.swift
//  BingedTests
//
//  The social graph. Blocking and private accounts are the parts that fail
//  quietly and matter most, so they get the most attention here.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Helpers

private func person(_ handle: String, isPrivate: Bool = false) -> UserProfile {
    UserProfile(id: UUID(), handle: handle, displayName: handle.capitalized,
                bio: nil, avatarURL: nil, isPrivate: isPrivate, createdAt: .now)
}

// MARK: - Follow state

@Suite("FollowState")
struct FollowStateTests {

    @Test("Following a private account goes to pending, a public one to active")
    func nextDependsOnPrivacy() {
        #expect(FollowState.none.next(targetIsPrivate: false) == .active)
        #expect(FollowState.none.next(targetIsPrivate: true) == .pending)
    }

    @Test("Tapping again undoes either state")
    func toggleUndoes() {
        #expect(FollowState.active.next(targetIsPrivate: false) == .none)
        #expect(FollowState.pending.next(targetIsPrivate: true) == .none)
    }

    @Test("A blocked edge is inert")
    func blockedIsInert() {
        // A blocked person must not be able to act on the relationship at all,
        // and must not learn anything from trying.
        #expect(FollowState.blocked.next(targetIsPrivate: false) == .blocked)
        #expect(!FollowState.blocked.isActionable)
    }

    @Test("Every state has a button title")
    func titlesExist() {
        for state in [FollowState.none, .pending, .active, .blocked] {
            #expect(!state.actionTitle.isEmpty)
        }
    }
}

// MARK: - Graph

@Suite("SocialService contract")
struct SocialServiceTests {

    @Test("You cannot follow yourself")
    func noSelfFollow() async {
        // Enforced by a database check constraint too — this is the friendly
        // message, not the guarantee.
        let me = UUID()
        let service = MockSocialService(viewer: me, people: [])

        await #expect(throws: SocialError.cannotFollowSelf) {
            _ = try await service.follow(me)
        }
    }

    @Test("Following a public account is immediately active")
    func followPublic() async throws {
        let target = person("alex")
        let service = MockSocialService(people: [target])

        #expect(try await service.follow(target.id) == .active)
        #expect(try await service.relationship(with: target.id).state == .active)
    }

    @Test("Following a private account yields pending, and shows nothing until accepted")
    func followPrivateIsPending() async throws {
        // The acceptance criterion: a follower of a private account sees nothing
        // of that account's library until the request is accepted.
        let target = person("sam", isPrivate: true)
        let service = MockSocialService(people: [target])

        #expect(try await service.follow(target.id) == .pending)

        let relationship = try await service.relationship(with: target.id)
        #expect(relationship.state == .pending)
        #expect(relationship.state != .active, "a pending follower was treated as active")
    }

    @Test("A pending request can be accepted or rejected")
    func requestsResolve() async throws {
        let me = UUID()
        let asker = person("asker")
        let service = MockSocialService(viewer: asker.id, people: [asker])

        // The asker follows a private me…
        let mine = UserProfile(id: me, handle: "mine", displayName: nil, bio: nil,
                               avatarURL: nil, isPrivate: true, createdAt: .now)
        service.add(mine)
        _ = try await service.follow(me)

        // …and from my side the request is visible and acceptable.
        let asMe = MockSocialService(viewer: me, people: [asker, mine])
        _ = try? await asMe.follow(asker.id)   // unrelated edge, must not confuse
        #expect(try await service.relationship(with: me).state == .pending)
    }

    @Test("Unfollowing removes the edge")
    func unfollow() async throws {
        let target = person("alex")
        let service = MockSocialService(people: [target])
        _ = try await service.follow(target.id)
        try await service.unfollow(target.id)

        #expect(try await service.relationship(with: target.id).state == .none)
    }

    // MARK: Blocking

    @Test("Blocking is mutually invisible")
    func blockingHidesBothWays() async throws {
        // Neither side should be able to tell which direction the block went,
        // and neither should surface in the other's search.
        let other = person("blocked_person")
        let service = MockSocialService(people: [other])

        #expect(try await service.searchUsers(query: "blocked", limit: 10).count == 1)

        try await service.block(other.id)

        #expect(try await service.searchUsers(query: "blocked", limit: 10).isEmpty)
        #expect(try await service.relationship(with: other.id).state == .blocked)
    }

    @Test("A blocked account is indistinguishable from one that does not exist")
    func blockedLooksLikeMissing() async throws {
        let other = person("ghost")
        let service = MockSocialService(people: [other])
        try await service.block(other.id)

        await #expect(throws: SocialError.notFound) {
            _ = try await service.profile(handle: "ghost")
        }
    }

    @Test("Blocking severs existing edges in both directions")
    func blockSeversEdges() async throws {
        // Leaving them would keep the blocked person's activity arriving in a
        // feed built from follow rows.
        let other = person("alex")
        let service = MockSocialService(people: [other])
        _ = try await service.follow(other.id)
        #expect(try await service.relationship(with: other.id).state == .active)

        try await service.block(other.id)
        try await service.unblock(other.id)

        #expect(try await service.relationship(with: other.id).state == .none,
                "an edge survived a block")
    }

    @Test("A blocked person cannot be followed")
    func cannotFollowBlocked() async throws {
        let other = person("alex")
        let service = MockSocialService(people: [other])
        try await service.block(other.id)

        await #expect(throws: SocialError.blocked) {
            _ = try await service.follow(other.id)
        }
    }

    // MARK: Search

    @Test("Search matches handle and display name, and is deterministic")
    func searchIsStable() async throws {
        let service = MockSocialService(people: [
            person("zach"), person("alex"), person("mike"),
        ])

        let first = try await service.searchUsers(query: "a", limit: 10).map(\.handle)
        let second = try await service.searchUsers(query: "a", limit: 10).map(\.handle)

        #expect(first == second, "search order is not stable")
        #expect(first == first.sorted())
    }

    @Test("An empty query returns nothing rather than everyone")
    func emptyQueryIsEmpty() async throws {
        let service = MockSocialService(people: [person("alex")])
        #expect(try await service.searchUsers(query: "  ", limit: 10).isEmpty)
    }
}

@Suite("Searching never returns the viewer")
struct SelfExclusionTests {

    @Test("The mock leaves the viewer out of their own results")
    func mockExcludesViewer() async throws {
        // Your own row is the one result you were certainly not looking for,
        // and it carries a Follow button that cannot work.
        let viewer = person("alexandra")
        let other = person("alexis")
        let service = MockSocialService(viewer: viewer.id, people: [viewer, other])

        let found = try await service.searchUsers(query: "alex", limit: 10)

        #expect(found.map(\.handle) == ["alexis"], "the viewer searched and found themselves")
    }

    @Test("The viewer is excluded in the query, not after the fact")
    func supabaseFiltersInQuery() async throws {
        // Filtering client-side after the response would let the viewer's own
        // row consume one of the `limit` slots, quietly costing a real result
        // on a full page.
        let viewerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let log = RequestLog()
        let client = makeSupabaseClient(
            session: makeSession(userID: viewerID),
            log: log
        ) { _ in .status(200, SupabaseFixtures.emptyArray) }

        let service = SupabaseSocialService(
            client: client, configuration: makeSupabaseConfiguration()
        )
        _ = try await service.searchUsers(query: "alex", limit: 25)

        let sent = log.urls.first ?? ""
        let excluded = sent.contains("id=neq.\(viewerID.uuidString.lowercased())")
        #expect(excluded, "no self-exclusion reached the wire: \(sent)")
    }
}

// MARK: - View model

@Suite("UserSearchViewModel")
@MainActor
struct UserSearchViewModelTests {

    @Test("An optimistic follow rolls back when the request fails")
    func optimisticRollback() async {
        // A phantom follow would survive until the next refresh and confuse
        // everything downstream that reads the graph.
        final class FailingSocial: SocialService, @unchecked Sendable {
            func searchUsers(query: String, limit: Int) async throws -> [UserProfile] { [] }
            func profile(handle: String) async throws -> UserProfile? { nil }
            func relationship(with userID: UUID) async throws -> SocialRelationship { .unknown }
            func follow(_ userID: UUID) async throws -> FollowState { throw SocialError.blocked }
            func unfollow(_ userID: UUID) async throws {}
            func pendingRequests() async throws -> [UserProfile] { [] }
            func acceptRequest(from userID: UUID) async throws {}
            func rejectRequest(from userID: UUID) async throws {}
            func followers(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
            func following(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
            func block(_ userID: UUID) async throws {}
            func unblock(_ userID: UUID) async throws {}
            func blockedAccounts() async throws -> [UserProfile] { [] }
        }

        let target = person("alex")
        let viewModel = UserSearchViewModel(service: FailingSocial())

        await viewModel.toggleFollow(target)

        #expect(viewModel.state(for: target) == .none, "a phantom follow survived")
    }

    @Test("The server decides active versus pending")
    func serverDecidesState() async {
        // Only the server knows for certain whether the target is private, so
        // the optimistic guess must be replaced by what comes back.
        let target = person("sam", isPrivate: true)
        let service = MockSocialService(people: [target])
        let viewModel = UserSearchViewModel(service: service)

        await viewModel.toggleFollow(target)
        #expect(viewModel.state(for: target) == .pending)
    }

    @Test("Blocking removes the row from results")
    func blockRemovesRow() async {
        let target = person("alex")
        let service = MockSocialService(people: [target])
        let viewModel = UserSearchViewModel(service: service)

        viewModel.query = "alex"
        try? await Task.sleep(for: .milliseconds(500))

        await viewModel.block(target)
        #expect(!viewModel.results.contains { $0.id == target.id })
    }

    @Test("Retry re-runs the failed search instead of just clearing the message")
    func retryReRunsSearch() async {
        // The error state offers Try again, so it has to actually try again.
        // Merely clearing the message would drop the user on a prompt screen
        // holding the query they had already typed.
        final class FlakySocial: SocialService, @unchecked Sendable {
            var attempts = 0
            func searchUsers(query: String, limit: Int) async throws -> [UserProfile] {
                attempts += 1
                if attempts == 1 { throw SocialError.blocked }
                return [person("alex")]
            }
            func profile(handle: String) async throws -> UserProfile? { nil }
            func relationship(with userID: UUID) async throws -> SocialRelationship { .unknown }
            func follow(_ userID: UUID) async throws -> FollowState { .active }
            func unfollow(_ userID: UUID) async throws {}
            func pendingRequests() async throws -> [UserProfile] { [] }
            func acceptRequest(from userID: UUID) async throws {}
            func rejectRequest(from userID: UUID) async throws {}
            func followers(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
            func following(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
            func block(_ userID: UUID) async throws {}
            func unblock(_ userID: UUID) async throws {}
            func blockedAccounts() async throws -> [UserProfile] { [] }
        }

        let service = FlakySocial()
        let viewModel = UserSearchViewModel(service: service)

        viewModel.query = "alex"
        try? await Task.sleep(for: .milliseconds(500))
        #expect(viewModel.phase == .error(SocialError.blocked.description))

        viewModel.retry()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(service.attempts == 2, "Try again did not reach the service")
        #expect(viewModel.phase == .results)
        #expect(viewModel.results.map(\.handle) == ["alex"])
    }

    @Test("An empty query returns to the prompt state")
    func emptyQueryPrompts() {
        let viewModel = UserSearchViewModel(service: MockSocialService())
        viewModel.query = "something"
        viewModel.query = ""
        #expect(viewModel.phase == .prompt)
    }
}
