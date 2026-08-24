//
//  FollowRequestsViewModelTests.swift
//  BingedTests
//
//  The inbox that makes `isPrivate` a door rather than a wall.
//
//  Before this existed, `pendingRequests` / `acceptRequest` / `rejectRequest`
//  were implemented, tested at the service layer, and called by nothing — a
//  private account could collect requests it had no way to answer.
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

/// A controllable inbox. `MockSocialService` models the graph from the
/// viewer's side and gives no way to seed an *inbound* pending edge, which is
/// exactly the state this screen exists for.
private class StubSocialService: SocialService, @unchecked Sendable {
    var waiting: [UserProfile]
    private(set) var accepted: [UUID] = []
    private(set) var rejected: [UUID] = []

    init(waiting: [UserProfile] = []) { self.waiting = waiting }

    func searchUsers(query: String, limit: Int) async throws -> [UserProfile] { [] }
    func profile(handle: String) async throws -> UserProfile? { nil }
    func relationship(with userID: UUID) async throws -> SocialRelationship { .unknown }
    func follow(_ userID: UUID) async throws -> FollowState { .none }
    func unfollow(_ userID: UUID) async throws {}
    func pendingRequests() async throws -> [UserProfile] { waiting }
    func followers(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
    func following(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
    func block(_ userID: UUID) async throws {}
    func unblock(_ userID: UUID) async throws {}
    func blockedAccounts() async throws -> [UserProfile] { [] }

    func acceptRequest(from userID: UUID) async throws { accepted.append(userID) }
    func rejectRequest(from userID: UUID) async throws { rejected.append(userID) }
}

/// Every answer fails. Proves a refusal is reported and the row survives.
private final class RefusingSocialService: StubSocialService, @unchecked Sendable {
    override func acceptRequest(from userID: UUID) async throws {
        throw SupabaseError.transport("offline")
    }
    override func rejectRequest(from userID: UUID) async throws {
        throw SupabaseError.transport("offline")
    }
}

// MARK: - Tests

@Suite("Follow requests")
@MainActor
struct FollowRequestsViewModelTests {

    @Test("An empty queue is empty, not an error")
    func emptyQueue() async {
        let viewModel = FollowRequestsViewModel(service: MockSocialService())
        await viewModel.load()
        #expect(viewModel.phase == .empty)
    }

    @Test("A build with no server reports empty rather than spinning forever")
    func noService() async {
        let viewModel = FollowRequestsViewModel(service: nil)
        await viewModel.load()
        // `.loading` here would be a spinner nothing ever resolves.
        #expect(viewModel.phase == .empty)
    }

    @Test("Accepting removes the request from the queue and tells the server")
    func acceptRemoves() async {
        let sam = person("sam")
        let alex = person("alex")
        let service = StubSocialService(waiting: [sam, alex])
        let viewModel = FollowRequestsViewModel(service: service)
        await viewModel.load()
        #expect(viewModel.phase == .requests)

        await viewModel.accept(sam)

        #expect(service.accepted == [sam.id])
        #expect(!viewModel.requests.contains { $0.id == sam.id })
        // The other request is untouched.
        #expect(viewModel.requests.map(\.id) == [alex.id])
        #expect(viewModel.lastError == nil)
    }

    @Test("A failed answer keeps the request and says what happened")
    func failedAnswerKeepsRow() async {
        let sam = person("sam")
        let viewModel = FollowRequestsViewModel(
            service: RefusingSocialService(waiting: [sam])
        )
        await viewModel.load()
        #expect(viewModel.phase == .requests)

        await viewModel.accept(sam)

        // An approval is a permission. Removing the row on failure would tell
        // the user they had let someone in when they had not.
        #expect(viewModel.requests.count == 1)
        #expect(viewModel.lastError == "Could not reach the server.")
    }

    @Test("Answering the last request empties the queue")
    func lastRequestEmpties() async {
        let sam = person("sam")
        let service = StubSocialService(waiting: [sam])
        let viewModel = FollowRequestsViewModel(service: service)
        await viewModel.load()

        await viewModel.reject(sam)

        #expect(service.rejected == [sam.id])
        #expect(viewModel.phase == .empty)
    }
}
