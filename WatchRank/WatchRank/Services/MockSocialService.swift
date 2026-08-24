//
//  MockSocialService.swift
//  WatchRank
//
//  The social graph in memory.
//
//  Enforces the rules the server enforces — self-follow, blocking, private
//  accounts producing `pending` — so a test passing here is testing the app
//  rather than the stub's leniency.
//

import Foundation

// MARK: - MockSocialService

final class MockSocialService: SocialService, @unchecked Sendable {

    private let lock = NSLock()
    private var people: [UUID: UserProfile] = [:]
    private var edges: [String: FollowState] = [:]      // "follower->followee"
    /// Blocks are stored one-directionally and read both ways: a block must be
    /// mutually invisible, and neither side should be able to tell who did it.
    private var blocks: Set<String> = []

    private let viewerID: UUID

    init(viewer: UUID = UUID(), people: [UserProfile] = []) {
        self.viewerID = viewer
        for person in people { self.people[person.id] = person }
    }

    func add(_ profile: UserProfile) {
        lock.lock(); people[profile.id] = profile; lock.unlock()
    }

    /// Writes an edge directly, without going through `follow`.
    ///
    /// `follow` is `async` and only ever acts as the *viewer*, so neither a
    /// synchronous fixture nor an edge between two other people can be built
    /// with it. This is the seam for both.
    func seedFollow(_ followerID: UUID, follows followeeID: UUID, state: FollowState = .active) {
        lock.lock(); edges[Self.key(followerID, followeeID)] = state; lock.unlock()
    }

    private static func key(_ from: UUID, _ to: UUID) -> String {
        "\(from.uuidString)->\(to.uuidString)"
    }

    private func isBlockedLocked(_ a: UUID, _ b: UUID) -> Bool {
        blocks.contains(Self.key(a, b)) || blocks.contains(Self.key(b, a))
    }

    // MARK: Discovery

    func searchUsers(query: String, limit: Int) async throws -> [UserProfile] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }

        return people.values
            .filter { !isBlockedLocked(viewerID, $0.id) }
            .filter {
                $0.handle.contains(needle)
                    || ($0.displayName?.lowercased().contains(needle) ?? false)
            }
            // Deterministic: a search that reshuffles between keystrokes is
            // unusable, and dictionary order is not an order.
            .sorted { $0.handle < $1.handle }
            .prefix(limit)
            .map { $0 }
    }

    func profile(handle: String) async throws -> UserProfile? {
        let normalized = Handle.normalize(handle)
        lock.lock()
        defer { lock.unlock() }
        guard let person = people.values.first(where: { $0.handle == normalized }) else {
            return nil
        }
        // A blocked account is indistinguishable from one that does not exist.
        guard !isBlockedLocked(viewerID, person.id) else { throw SocialError.notFound }
        return person
    }

    func relationship(with userID: UUID) async throws -> SocialRelationship {
        lock.lock()
        defer { lock.unlock() }

        if isBlockedLocked(viewerID, userID) {
            return SocialRelationship(state: .blocked, counts: .zero, followsViewer: false)
        }
        let outbound = edges[Self.key(viewerID, userID)] ?? .none
        let inbound = edges[Self.key(userID, viewerID)] ?? .none

        let followers = edges.filter { $0.key.hasSuffix("->\(userID.uuidString)") && $0.value == .active }.count
        let following = edges.filter { $0.key.hasPrefix("\(userID.uuidString)->") && $0.value == .active }.count

        return SocialRelationship(
            state: outbound,
            counts: FollowCounts(followers: followers, following: following),
            followsViewer: inbound == .active
        )
    }

    // MARK: Edges

    func follow(_ userID: UUID) async throws -> FollowState {
        guard userID != viewerID else { throw SocialError.cannotFollowSelf }

        lock.lock()
        defer { lock.unlock() }

        guard !isBlockedLocked(viewerID, userID) else { throw SocialError.blocked }
        guard let target = people[userID] else { throw SocialError.notFound }

        let state: FollowState = target.isPrivate ? .pending : .active
        edges[Self.key(viewerID, userID)] = state
        return state
    }

    func unfollow(_ userID: UUID) async throws {
        lock.lock(); edges[Self.key(viewerID, userID)] = nil; lock.unlock()
    }

    func pendingRequests() async throws -> [UserProfile] {
        lock.lock()
        defer { lock.unlock() }
        return people.values
            .filter { edges[Self.key($0.id, viewerID)] == .pending }
            .sorted { $0.handle < $1.handle }
    }

    func acceptRequest(from userID: UUID) async throws {
        lock.lock()
        defer { lock.unlock() }
        guard edges[Self.key(userID, viewerID)] == .pending else { throw SocialError.notFound }
        edges[Self.key(userID, viewerID)] = .active
    }

    func rejectRequest(from userID: UUID) async throws {
        lock.lock(); edges[Self.key(userID, viewerID)] = nil; lock.unlock()
    }

    // MARK: Lists

    func followers(of userID: UUID, limit: Int) async throws -> [UserProfile] {
        lock.lock()
        defer { lock.unlock() }
        return people.values
            .filter { edges[Self.key($0.id, userID)] == .active }
            .filter { !isBlockedLocked(viewerID, $0.id) }
            .sorted { $0.handle < $1.handle }
            .prefix(limit).map { $0 }
    }

    func following(of userID: UUID, limit: Int) async throws -> [UserProfile] {
        lock.lock()
        defer { lock.unlock() }
        return people.values
            .filter { edges[Self.key(userID, $0.id)] == .active }
            .filter { !isBlockedLocked(viewerID, $0.id) }
            .sorted { $0.handle < $1.handle }
            .prefix(limit).map { $0 }
    }

    // MARK: Blocking

    func block(_ userID: UUID) async throws {
        lock.lock()
        defer { lock.unlock() }
        blocks.insert(Self.key(viewerID, userID))
        // A block severs both edges. Leaving them would keep the blocked
        // person's activity arriving in a feed built from follow rows.
        edges[Self.key(viewerID, userID)] = nil
        edges[Self.key(userID, viewerID)] = nil
    }

    func unblock(_ userID: UUID) async throws {
        lock.lock()
        blocks.remove(Self.key(viewerID, userID))
        lock.unlock()
    }
}
