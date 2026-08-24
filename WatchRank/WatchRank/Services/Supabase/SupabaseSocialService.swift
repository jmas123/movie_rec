//
//  SupabaseSocialService.swift
//  WatchRank
//
//  The social graph, against PostgREST.
//
//  **The client filters nothing that matters.** Every visibility rule here —
//  who can see a private library, what a block hides — is enforced by row-level
//  security in Postgres. What the client does is ask; what it gets back is
//  already filtered. A client-side check would be a second, weaker copy of the
//  policy that drifts.
//

import Foundation

// MARK: - SupabaseSocialService

final class SupabaseSocialService: SocialService, @unchecked Sendable {

    private let client: SupabaseClient
    private let configuration: SupabaseConfiguration

    init(client: SupabaseClient, configuration: SupabaseConfiguration) {
        self.client = client
        self.configuration = configuration
    }

    // MARK: Discovery

    func searchUsers(query: String, limit: Int) async throws -> [UserProfile] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        // PostgREST `or=` with `ilike`. The wildcard is escaped so a user
        // typing `%` searches for a percent sign rather than matching everyone.
        let escaped = needle
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: ",", with: "")

        return try await run {
            try await client.send(
                .init(
                    url: configuration.rest("profiles"),
                    query: [
                        URLQueryItem(name: "or",
                                     value: "(handle.ilike.*\(escaped)*,display_name.ilike.*\(escaped)*)"),
                        URLQueryItem(name: "select", value: "*"),
                        URLQueryItem(name: "order", value: "handle.asc"),
                    ],
                    range: 0...(max(0, limit - 1))
                )
            )
        }
    }

    func profile(handle: String) async throws -> UserProfile? {
        let rows: [UserProfile] = try await run {
            try await client.send(
                .init(
                    url: configuration.rest("profiles"),
                    query: [
                        URLQueryItem(name: "handle", value: "eq.\(Handle.normalize(handle))"),
                        URLQueryItem(name: "select", value: "*"),
                    ]
                )
            )
        }
        return rows.first
    }

    func relationship(with userID: UUID) async throws -> SocialRelationship {
        // One round trip: a Postgres function returns the edge and both counts
        // together, rather than the client making three requests and rendering
        // a half-populated button in between.
        let rows: [RelationshipRow] = try await run {
            try await client.send(
                .init(
                    method: "POST",
                    url: configuration.rpc("relationship"),
                    body: try SupabaseClient.encoder.encode(["target": userID])
                )
            )
        }
        guard let row = rows.first else { return .unknown }
        return SocialRelationship(
            state: row.state,
            counts: FollowCounts(followers: row.followerCount, following: row.followingCount),
            followsViewer: row.followsViewer
        )
    }

    // MARK: Edges

    func follow(_ userID: UUID) async throws -> FollowState {
        guard let viewer = await client.currentUserID else { throw SocialError.notConfigured }
        // Checked here for a clear message, and *also* by a check constraint in
        // the database — a client that forgets this must still fail.
        guard viewer != userID else { throw SocialError.cannotFollowSelf }

        let rows: [FollowEdge] = try await run {
            try await client.send(
                .init(
                    method: "POST",
                    url: configuration.rest("follows"),
                    query: [URLQueryItem(name: "on_conflict", value: "follower_id,followee_id")],
                    body: try SupabaseClient.encoder.encode(
                        NewFollow(followerID: viewer, followeeID: userID)
                    ),
                    headers: ["Prefer": "resolution=merge-duplicates,return=representation"]
                )
            )
        }
        // The *server* decides whether this is active or pending, because only
        // it knows whether the target is private.
        return rows.first?.state ?? .pending
    }

    func unfollow(_ userID: UUID) async throws {
        guard let viewer = await client.currentUserID else { throw SocialError.notConfigured }
        try await run {
            try await client.send(
                .init(
                    method: "DELETE",
                    url: configuration.rest("follows"),
                    query: [
                        URLQueryItem(name: "follower_id", value: "eq.\(viewer.uuidString.lowercased())"),
                        URLQueryItem(name: "followee_id", value: "eq.\(userID.uuidString.lowercased())"),
                    ],
                    headers: ["Prefer": "return=minimal"]
                )
            )
        }
    }

    func pendingRequests() async throws -> [UserProfile] {
        try await run {
            try await client.send(
                .init(
                    method: "POST",
                    url: configuration.rpc("pending_requests"),
                    body: Data("{}".utf8)
                )
            )
        }
    }

    func acceptRequest(from userID: UUID) async throws {
        try await setState(.active, follower: userID)
    }

    func rejectRequest(from userID: UUID) async throws {
        guard let viewer = await client.currentUserID else { throw SocialError.notConfigured }
        try await run {
            try await client.send(
                .init(
                    method: "DELETE",
                    url: configuration.rest("follows"),
                    query: [
                        URLQueryItem(name: "follower_id", value: "eq.\(userID.uuidString.lowercased())"),
                        URLQueryItem(name: "followee_id", value: "eq.\(viewer.uuidString.lowercased())"),
                    ],
                    headers: ["Prefer": "return=minimal"]
                )
            )
        }
    }

    private func setState(_ state: FollowState, follower: UUID) async throws {
        guard let viewer = await client.currentUserID else { throw SocialError.notConfigured }
        try await run {
            try await client.send(
                .init(
                    method: "PATCH",
                    url: configuration.rest("follows"),
                    query: [
                        URLQueryItem(name: "follower_id", value: "eq.\(follower.uuidString.lowercased())"),
                        URLQueryItem(name: "followee_id", value: "eq.\(viewer.uuidString.lowercased())"),
                    ],
                    body: try SupabaseClient.encoder.encode(["state": state.rawValue]),
                    headers: ["Prefer": "return=minimal"]
                )
            )
        }
    }

    // MARK: Lists

    func followers(of userID: UUID, limit: Int) async throws -> [UserProfile] {
        try await people(rpc: "followers_of", userID: userID, limit: limit)
    }

    func following(of userID: UUID, limit: Int) async throws -> [UserProfile] {
        try await people(rpc: "following_of", userID: userID, limit: limit)
    }

    private func people(rpc: String, userID: UUID, limit: Int) async throws -> [UserProfile] {
        try await run {
            try await client.send(
                .init(
                    method: "POST",
                    url: configuration.rpc(rpc),
                    body: try SupabaseClient.encoder.encode(["target": userID]),
                    range: 0...(max(0, limit - 1))
                )
            )
        }
    }

    // MARK: Blocking

    func block(_ userID: UUID) async throws {
        guard let viewer = await client.currentUserID else { throw SocialError.notConfigured }
        try await run {
            try await client.send(
                .init(
                    method: "POST",
                    url: configuration.rest("blocks"),
                    query: [URLQueryItem(name: "on_conflict", value: "blocker_id,blocked_id")],
                    body: try SupabaseClient.encoder.encode(
                        NewBlock(blockerID: viewer, blockedID: userID)
                    ),
                    headers: ["Prefer": "resolution=merge-duplicates,return=minimal"]
                )
            )
        }
    }

    func unblock(_ userID: UUID) async throws {
        guard let viewer = await client.currentUserID else { throw SocialError.notConfigured }
        try await run {
            try await client.send(
                .init(
                    method: "DELETE",
                    url: configuration.rest("blocks"),
                    query: [
                        URLQueryItem(name: "blocker_id", value: "eq.\(viewer.uuidString.lowercased())"),
                        URLQueryItem(name: "blocked_id", value: "eq.\(userID.uuidString.lowercased())"),
                    ],
                    headers: ["Prefer": "return=minimal"]
                )
            )
        }
    }

    // MARK: Plumbing

    /// Translates transport errors once, so every method above reads as the
    /// operation it performs.
    @discardableResult
    private func run<Value>(_ work: () async throws -> Value) async throws -> Value {
        do {
            return try await work()
        } catch SupabaseError.forbidden {
            // An RLS denial here means "you cannot see that", which for a
            // blocked or private account is indistinguishable from absence —
            // and must stay that way.
            throw SocialError.notFound
        } catch SupabaseError.conflict(let message) {
            throw SocialError.underlying(message ?? "That did not work.")
        } catch SupabaseError.notConfigured {
            throw SocialError.notConfigured
        } catch let error as SupabaseError {
            throw SocialError.underlying(error.description)
        }
    }

    // MARK: Payloads

    private struct NewFollow: Encodable {
        let followerID: UUID
        let followeeID: UUID
        enum CodingKeys: String, CodingKey {
            case followerID = "follower_id"
            case followeeID = "followee_id"
        }
    }

    private struct NewBlock: Encodable {
        let blockerID: UUID
        let blockedID: UUID
        enum CodingKeys: String, CodingKey {
            case blockerID = "blocker_id"
            case blockedID = "blocked_id"
        }
    }

    private struct RelationshipRow: Decodable {
        let state: FollowState
        let followerCount: Int
        let followingCount: Int
        let followsViewer: Bool

        enum CodingKeys: String, CodingKey {
            case state
            case followerCount = "follower_count"
            case followingCount = "following_count"
            case followsViewer = "follows_viewer"
        }
    }
}
