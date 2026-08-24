//
//  FeedService.swift
//  WatchRank
//
//  Reading the feed, and emitting posts into it.
//

import Foundation

// MARK: - FeedService

protocol FeedService: Sendable {

    /// One page of the signed-in user's feed, newest first.
    ///
    /// - Parameter before: keyset cursor. `nil` fetches the newest page.
    func feed(before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost]

    /// Posts by one author, for their profile.
    func posts(by userID: UUID, before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost]

    /// Emits one post. Called once per user action, never once per changed row.
    func createPost(kind: FeedPost.Kind, payload: FeedPost.Payload) async throws

    func react(to postID: UUID) async throws
    func unreact(to postID: UUID) async throws

    // MARK: Comments

    func comments(on postID: UUID, limit: Int) async throws -> [PostComment]

    @discardableResult
    func addComment(to postID: UUID, body: String) async throws -> PostComment

    /// Soft delete. Your own comment, or any comment on your own post — the
    /// policy decides which, not the client.
    func deleteComment(_ commentID: UUID) async throws

    // MARK: Safety

    /// Reporting has to exist wherever content appears, not only in Settings.
    func report(_ target: ReportTarget, reason: ReportReason, note: String?) async throws
}

// MARK: - SupabaseFeedService

final class SupabaseFeedService: FeedService, @unchecked Sendable {

    private let client: SupabaseClient
    private let configuration: SupabaseConfiguration

    init(client: SupabaseClient, configuration: SupabaseConfiguration) {
        self.client = client
        self.configuration = configuration
    }

    func feed(before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] {
        // A Postgres function rather than a PostgREST filter, so the feed
        // arrives in **one** request with author fields and counts already
        // joined. A client-side join would be one query per row.
        var body: [String: String] = ["page_size": String(limit)]
        if let cursor {
            body["before_created_at"] = ISO8601DateFormatter().string(from: cursor.createdAt)
            body["before_id"] = cursor.id.uuidString
        }
        return try await client.send(
            .init(
                method: "POST",
                url: configuration.rpc("feed_page"),
                body: try SupabaseClient.encoder.encode(body)
            )
        )
    }

    func posts(by userID: UUID, before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] {
        var body: [String: String] = ["target": userID.uuidString, "page_size": String(limit)]
        if let cursor {
            body["before_created_at"] = ISO8601DateFormatter().string(from: cursor.createdAt)
            body["before_id"] = cursor.id.uuidString
        }
        return try await client.send(
            .init(
                method: "POST",
                url: configuration.rpc("author_posts"),
                body: try SupabaseClient.encoder.encode(body)
            )
        )
    }

    func createPost(kind: FeedPost.Kind, payload: FeedPost.Payload) async throws {
        guard let author = await client.currentUserID else { return }
        try await client.send(
            .init(
                method: "POST",
                url: configuration.rest("posts"),
                body: try SupabaseClient.encoder.encode(
                    NewPost(author: author, kind: kind, payload: payload)
                ),
                headers: ["Prefer": "return=minimal"]
            )
        )
    }

    func react(to postID: UUID) async throws {
        guard let user = await client.currentUserID else { return }
        // The primary key `(post_id, user_id)` does the deduplication. Reacting
        // twice is one reaction because the database says so, not because the
        // client remembered to check.
        try await client.send(
            .init(
                method: "POST",
                url: configuration.rest("reactions"),
                query: [URLQueryItem(name: "on_conflict", value: "post_id,user_id")],
                body: try SupabaseClient.encoder.encode(
                    NewReaction(postID: postID, userID: user)
                ),
                headers: ["Prefer": "resolution=ignore-duplicates,return=minimal"]
            )
        )
    }

    func unreact(to postID: UUID) async throws {
        guard let user = await client.currentUserID else { return }
        try await client.send(
            .init(
                method: "DELETE",
                url: configuration.rest("reactions"),
                query: [
                    URLQueryItem(name: "post_id", value: "eq.\(postID.uuidString.lowercased())"),
                    URLQueryItem(name: "user_id", value: "eq.\(user.uuidString.lowercased())"),
                ],
                headers: ["Prefer": "return=minimal"]
            )
        )
    }

    /// A row of `posts`.
    ///
    /// The author column is `user_id`, matching every other table — `author_id`
    /// exists only in the *rendered* feed row, where the RPC aliases it. And
    /// `media_type` / `external_id` are real NOT NULL columns beside the
    /// denormalised payload, because `posts_feed_idx` and the ranked-item
    /// lookups are built on them; the payload alone would not do.
    private struct NewPost: Encodable {
        let userID: UUID
        let kind: FeedPost.Kind
        let mediaType: MediaType
        let externalID: String
        let payload: FeedPost.Payload

        init(author: UUID, kind: FeedPost.Kind, payload: FeedPost.Payload) {
            userID = author
            self.kind = kind
            mediaType = payload.mediaType
            externalID = payload.externalId
            self.payload = payload
        }

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case kind
            case mediaType = "media_type"
            case externalID = "external_id"
            case payload
        }
    }

    func comments(on postID: UUID, limit: Int) async throws -> [PostComment] {
        // An RPC so the author fields arrive joined: a comment list that
        // fetched a profile per row would be an N+1 on the busiest screen.
        try await client.send(
            .init(
                method: "POST",
                url: configuration.rpc("post_comments"),
                body: try SupabaseClient.encoder.encode(
                    ["post": postID.uuidString, "page_size": String(limit)]
                )
            )
        )
    }

    @discardableResult
    func addComment(to postID: UUID, body: String) async throws -> PostComment {
        guard let author = await client.currentUserID else { throw SupabaseError.unauthorized }
        let rows: [PostComment] = try await client.send(
            .init(
                method: "POST",
                url: configuration.rest("comments"),
                body: try SupabaseClient.encoder.encode(
                    NewComment(postID: postID, authorID: author, body: body)
                ),
                headers: ["Prefer": "return=representation"]
            )
        )
        guard let comment = rows.first else { throw SupabaseError.decoding("No comment returned") }
        return comment
    }

    func deleteComment(_ commentID: UUID) async throws {
        // Soft: the row keeps its place so the thread does not lose its shape
        // and the counts stay consistent.
        try await client.send(
            .init(
                method: "PATCH",
                url: configuration.rest("comments"),
                query: [URLQueryItem(name: "id", value: "eq.\(commentID.uuidString.lowercased())")],
                body: try SupabaseClient.encoder.encode(["deleted_at": Date()]),
                headers: ["Prefer": "return=minimal"]
            )
        )
    }

    func report(_ target: ReportTarget, reason: ReportReason, note: String?) async throws {
        guard let reporter = await client.currentUserID else { throw SupabaseError.unauthorized }
        var payload: [String: String] = [
            "reporter_id": reporter.uuidString,
            "reason": reason.rawValue,
            target.column: target.id.uuidString,
        ]
        if let note, !note.isEmpty { payload["note"] = note }

        try await client.send(
            .init(
                method: "POST",
                url: configuration.rest("reports"),
                body: try SupabaseClient.encoder.encode(payload),
                headers: ["Prefer": "return=minimal"]
            )
        )
    }

    private struct NewComment: Encodable {
        let postID: UUID
        let authorID: UUID
        let body: String
        enum CodingKeys: String, CodingKey {
            case postID = "post_id"
            case authorID = "author_id"
            case body
        }
    }

    private struct NewReaction: Encodable {
        let postID: UUID
        let userID: UUID
        enum CodingKeys: String, CodingKey {
            case postID = "post_id"
            case userID = "user_id"
        }
    }
}
