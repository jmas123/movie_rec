//
//  SupabaseSocialService.swift
//  Binged
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

        var query = [
            URLQueryItem(name: "or",
                         value: "(handle.ilike.*\(escaped)*,display_name.ilike.*\(escaped)*)"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "handle.asc"),
        ]

        // Never return the viewer to themselves. Their own row is the one
        // result they were certainly not looking for, and it arrives carrying a
        // Follow button that cannot work: `follows_no_self` is a check
        // constraint, so tapping it spends a round trip to be told
        // `cannotFollowSelf`. Filtered in the query rather than after the fact
        // so it does not eat one of the `limit` rows.
        //
        // This is a courtesy, not a boundary — a client that dropped it would
        // see nothing it is not already allowed to see, which is why it is a
        // filter here and not a policy in Postgres.
        if let viewerID = await client.currentUserID {
            query.append(URLQueryItem(name: "id", value: "neq.\(viewerID.uuidString.lowercased())"))
        }

        return try await run {
            try await client.send(
                .init(
                    url: configuration.rest("profiles"),
                    query: query,
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

        // **`ignore-duplicates`, not `merge-duplicates`.**
        //
        // Both are upserts, but they compile to different statements and only
        // one of them is legal here. `merge-duplicates` is `ON CONFLICT DO
        // UPDATE`, and an UPDATE on `follows` is governed by `follows_update`:
        //
        //     using (followee_id = auth.uid())
        //
        // — deliberately the *followee's* row to change, because that policy is
        // what stops a follower approving their own request. So the second
        // follow of the same account, by the person doing the following, was
        // refused by the one rule that makes private accounts mean anything:
        //
        //     42501  new row violates row-level security policy
        //            (USING expression) for table "follows"
        //
        // which `run` translates to `.forbidden` → `SocialError.notFound` →
        // **"No such account."** on a screen showing that very account.
        //
        // `ignore-duplicates` is `ON CONFLICT DO NOTHING`: it never takes the
        // UPDATE path, so it never consults that policy. The cost is that a
        // conflict returns no representation, which is what `existingState`
        // below is for — and re-reading is more honest anyway, since the state
        // of a row this request did *not* write is not this request's to guess.
        let rows: [FollowEdge] = try await run {
            try await client.send(
                .init(
                    method: "POST",
                    url: configuration.rest("follows"),
                    query: [URLQueryItem(name: "on_conflict", value: "follower_id,followee_id")],
                    body: try SupabaseClient.encoder.encode(
                        NewFollow(followerID: viewer, followeeID: userID)
                    ),
                    headers: ["Prefer": "resolution=ignore-duplicates,return=representation"]
                )
            )
        }

        // Inserted: the *server* decided active or pending, because only it
        // knows whether the target is private.
        if let state = rows.first?.state { return state }

        // Already following, or already asked. Idempotent by design — tapping
        // Follow twice is not an error, it is the same request arriving twice.
        return try await existingState(viewer: viewer, target: userID) ?? .pending
    }

    /// The stored state of one edge, or `nil` if there is no such row.
    ///
    /// Only reached when an insert was ignored, so it costs a round trip
    /// exactly in the case where the first one did no work.
    private func existingState(viewer: UUID, target: UUID) async throws -> FollowState? {
        let rows: [FollowEdge] = try await run {
            try await client.send(
                .init(
                    method: "GET",
                    url: configuration.rest("follows"),
                    query: [
                        URLQueryItem(name: "select", value: "*"),
                        URLQueryItem(name: "follower_id", value: "eq.\(viewer.uuidString.lowercased())"),
                        URLQueryItem(name: "followee_id", value: "eq.\(target.uuidString.lowercased())"),
                    ]
                )
            )
        }
        return rows.first?.state
    }

    /// Every edge the viewer has toward `userIDs`, in one request.
    ///
    /// Exists because the alternative is one `relationship` call per row, and
    /// the screen that needs this renders twenty-five rows at a time.
    func followStates(for userIDs: [UUID]) async throws -> [UUID: FollowState] {
        guard let viewer = await client.currentUserID, !userIDs.isEmpty else { return [:] }

        let list = userIDs.map { $0.uuidString.lowercased() }.joined(separator: ",")
        let rows: [FollowEdge] = try await run {
            try await client.send(
                .init(
                    method: "GET",
                    url: configuration.rest("follows"),
                    query: [
                        URLQueryItem(name: "select", value: "*"),
                        URLQueryItem(name: "follower_id", value: "eq.\(viewer.uuidString.lowercased())"),
                        URLQueryItem(name: "followee_id", value: "in.(\(list))"),
                    ]
                )
            )
        }
        // Absent rows are `.none` by omission — the caller fills the gaps, so a
        // blocked edge this query cannot see does not become a false `.none`
        // here.
        return Dictionary(rows.map { ($0.followeeID, $0.state) }, uniquingKeysWith: { first, _ in first })
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

    /// The same RPC, asked for a bounded page.
    ///
    /// A private account with a thousand waiting requests must not send a
    /// thousand profiles to render a badge that tops out at "9+".
    func pendingRequestCount(limit: Int) async throws -> Int {
        let rows: [UserProfile] = try await run {
            try await client.send(
                .init(
                    method: "POST",
                    url: configuration.rpc("pending_requests"),
                    body: Data("{}".utf8),
                    range: 0...(max(0, limit - 1))
                )
            )
        }
        return rows.count
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

    func blockedAccounts() async throws -> [UserProfile] {
        try await run {
            try await client.send(
                .init(
                    method: "POST",
                    url: configuration.rpc("blocked_accounts"),
                    body: Data("{}".utf8)
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
