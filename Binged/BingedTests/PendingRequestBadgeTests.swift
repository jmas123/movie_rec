//
//  PendingRequestBadgeTests.swift
//  BingedTests
//
//  The count on the people icon — the app's only announcement that somebody
//  has asked to follow a private account.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Doubles

/// Counts calls and can fail on demand. `MockSocialService` models the graph
/// from the viewer's side and gives no way to seed an *inbound* pending edge,
/// which is exactly what a badge counts.
private final class CountingSocial: SocialService, @unchecked Sendable {

    var waiting: [UserProfile] = []
    var failure: Error?
    private(set) var requestedLimits: [Int] = []

    func pendingRequests() async throws -> [UserProfile] {
        if let failure { throw failure }
        return waiting
    }

    func pendingRequestCount(limit: Int) async throws -> Int {
        requestedLimits.append(limit)
        if let failure { throw failure }
        return min(waiting.count, limit)
    }

    // Unused by the badge.
    func searchUsers(query: String, limit: Int) async throws -> [UserProfile] { [] }
    func profile(handle: String) async throws -> UserProfile? { nil }
    func relationship(with userID: UUID) async throws -> SocialRelationship { .unknown }
    func follow(_ userID: UUID) async throws -> FollowState { .active }
    func unfollow(_ userID: UUID) async throws {}
    func acceptRequest(from userID: UUID) async throws {}
    func rejectRequest(from userID: UUID) async throws {}
    func followers(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
    func following(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
    func block(_ userID: UUID) async throws {}
    func unblock(_ userID: UUID) async throws {}
    func blockedAccounts() async throws -> [UserProfile] { [] }
}

/// A conformer that does *not* implement the count, so the protocol default is
/// the thing under test.
private final class ListOnlySocial: SocialService, @unchecked Sendable {

    var waiting: [UserProfile] = []

    func pendingRequests() async throws -> [UserProfile] { waiting }

    func searchUsers(query: String, limit: Int) async throws -> [UserProfile] { [] }
    func profile(handle: String) async throws -> UserProfile? { nil }
    func relationship(with userID: UUID) async throws -> SocialRelationship { .unknown }
    func follow(_ userID: UUID) async throws -> FollowState { .active }
    func unfollow(_ userID: UUID) async throws {}
    func acceptRequest(from userID: UUID) async throws {}
    func rejectRequest(from userID: UUID) async throws {}
    func followers(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
    func following(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
    func block(_ userID: UUID) async throws {}
    func unblock(_ userID: UUID) async throws {}
    func blockedAccounts() async throws -> [UserProfile] { [] }
}

private func people(_ count: Int) -> [UserProfile] {
    (0..<count).map {
        UserProfile(id: UUID(), handle: "person\($0)", displayName: nil, bio: nil,
                    avatarURL: nil, isPrivate: false, createdAt: .now)
    }
}

// MARK: - Counting

@Suite("The follow-request badge")
@MainActor
struct PendingRequestBadgeTests {

    @Test("It counts what is waiting")
    func counts() async {
        let service = CountingSocial()
        service.waiting = people(3)

        let badge = PendingRequestBadge()
        await badge.refresh(using: service, isSignedIn: true)

        #expect(badge.count == 3)
        #expect(badge.text == "3")
    }

    @Test("Nothing waiting shows no bubble at all")
    func silentWhenEmpty() async {
        let badge = PendingRequestBadge()
        await badge.refresh(using: CountingSocial(), isSignedIn: true)

        #expect(badge.count == 0)
        #expect(badge.text == nil, "an empty badge is a permanent alarm about no news")
    }

    @Test("Past the cap it says so rather than inventing precision")
    func caps() async {
        let service = CountingSocial()
        service.waiting = people(50)

        let badge = PendingRequestBadge()
        await badge.refresh(using: service, isSignedIn: true)

        #expect(badge.text == "9+")
        #expect(badge.count == PendingRequestBadge.displayCap + 1,
                "the fetch must be bounded by what the badge can display")
    }

    @Test("The fetch asks for no more than the badge can show")
    func boundedFetch() async {
        // A private account with a thousand waiting requests must not send a
        // thousand profiles to render one bubble.
        let service = CountingSocial()
        service.waiting = people(1_000)

        let badge = PendingRequestBadge()
        await badge.refresh(using: service, isSignedIn: true)

        #expect(service.requestedLimits == [PendingRequestBadge.displayCap + 1])
    }

    @Test("Signed out, there is no inbox and no badge")
    func signedOut() async {
        let service = CountingSocial()
        service.waiting = people(4)

        let badge = PendingRequestBadge()
        await badge.refresh(using: service, isSignedIn: true)
        #expect(badge.count == 4)

        // Signing out must drop it: the badge points at a screen that can no
        // longer load.
        await badge.refresh(using: service, isSignedIn: false)
        #expect(badge.count == 0)
        #expect(service.requestedLimits.count == 1, "it asked the server while signed out")
    }

    @Test("With no social service there is nothing to count")
    func noService() async {
        let badge = PendingRequestBadge()
        await badge.refresh(using: nil, isSignedIn: true)
        #expect(badge.count == 0)
    }

    @Test("A failed refresh keeps the last count instead of reporting zero")
    func failureKeepsTheCount() async {
        // The smaller lie. Dropping to zero because a request timed out tells
        // the user nobody is waiting, which is the one thing the badge exists
        // to contradict.
        let service = CountingSocial()
        service.waiting = people(2)

        let badge = PendingRequestBadge()
        await badge.refresh(using: service, isSignedIn: true)
        #expect(badge.count == 2)

        service.failure = SocialError.underlying("offline")
        await badge.refresh(using: service, isSignedIn: true)
        #expect(badge.count == 2)
    }

    @Test("An answered queue empties the badge")
    func emptiesWhenAnswered() async {
        let service = CountingSocial()
        service.waiting = people(2)

        let badge = PendingRequestBadge()
        await badge.refresh(using: service, isSignedIn: true)

        service.waiting = []
        await badge.refresh(using: service, isSignedIn: true)
        #expect(badge.text == nil)
    }
}

// MARK: - Protocol default

@Suite("Counting without a dedicated endpoint")
struct PendingRequestCountDefaultTests {

    @Test("A service that only lists still reports a count")
    func defaultCountsTheList() async throws {
        let service = ListOnlySocial()
        service.waiting = people(3)
        #expect(try await service.pendingRequestCount(limit: 10) == 3)
    }

    @Test("The mock graph counts inbound requests, not outbound ones")
    func mockGraph() async throws {
        // Guards the shape of the fixture the previews and the UI passes use:
        // a request *the viewer sent* must never appear in the viewer's inbox.
        let viewer = UUID()
        let requester = UserProfile(
            id: UUID(), handle: "sam", displayName: "Sam", bio: nil,
            avatarURL: nil, isPrivate: true, createdAt: .now
        )
        let me = UserProfile(
            id: viewer, handle: "you", displayName: "You", bio: nil,
            avatarURL: nil, isPrivate: true, createdAt: .now
        )
        let graph = MockSocialService(viewer: viewer, people: [me, requester])

        // The viewer asks to follow a private account: outbound, not inbound.
        #expect(try await graph.follow(requester.id) == .pending)
        #expect(try await graph.pendingRequestCount(limit: 10) == 0)
    }
}
