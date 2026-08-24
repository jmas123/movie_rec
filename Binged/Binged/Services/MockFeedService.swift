//
//  MockFeedService.swift
//  Binged
//
//  The feed in memory. Enforces what the server enforces — comment length,
//  reaction deduplication, soft delete — so a passing test is testing the app
//  rather than the stub's leniency.
//

import Foundation

// MARK: - MockFeedService

final class MockFeedService: FeedService, @unchecked Sendable {

    private let lock = NSLock()
    private var posts: [FeedPost] = []
    private var comments: [UUID: [PostComment]] = [:]
    /// `postID -> reacting user ids`. A `Set` is the stub's version of the
    /// `(post_id, user_id)` primary key that does the real deduplication.
    private var reactions: [UUID: Set<UUID>] = [:]
    private(set) var reports: [(target: ReportTarget, reason: ReportReason)] = []

    private let viewerID: UUID

    init(viewer: UUID = UUID(), posts: [FeedPost] = []) {
        self.viewerID = viewer
        self.posts = posts
    }

    func seed(_ post: FeedPost) {
        lock.lock(); posts.append(post); lock.unlock()
    }

    /// A comment by somebody other than the viewer.
    ///
    /// `addComment` always writes as the viewer, which is right for the app and
    /// useless for building a thread that looks like a conversation.
    func seedComment(_ comment: PostComment) {
        lock.lock(); comments[comment.postID, default: []].append(comment); lock.unlock()
    }

    /// A reaction by somebody other than the viewer, so a seeded count is not
    /// forced to be 0 or 1.
    func seedReaction(on postID: UUID, by userID: UUID) {
        lock.lock(); reactions[postID, default: []].insert(userID); lock.unlock()
    }

    // MARK: Reading

    func feed(before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] {
        lock.lock()
        defer { lock.unlock() }

        let ordered = posts.sorted {
            $0.createdAt != $1.createdAt
                ? $0.createdAt > $1.createdAt
                : $0.id.uuidString > $1.id.uuidString
        }
        let start = cursor.flatMap { cursor in
            ordered.firstIndex { $0.id == cursor.id }.map { $0 + 1 }
        } ?? 0
        guard start < ordered.count else { return [] }
        return Array(ordered[start..<min(start + limit, ordered.count)]).map(hydrate)
    }

    func posts(by userID: UUID, before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] {
        try await feed(before: cursor, limit: limit).filter { $0.authorID == userID }
    }

    private func hydrate(_ post: FeedPost) -> FeedPost {
        let reacting = reactions[post.id] ?? []
        return FeedPost(
            id: post.id, authorID: post.authorID, kind: post.kind, createdAt: post.createdAt,
            authorHandle: post.authorHandle, authorDisplayName: post.authorDisplayName,
            authorAvatarURL: post.authorAvatarURL, payload: post.payload,
            commentCount: (comments[post.id] ?? []).filter { !$0.isDeleted }.count,
            reactionCount: reacting.count,
            viewerHasReacted: reacting.contains(viewerID)
        )
    }

    // MARK: Writing

    func createPost(kind: FeedPost.Kind, payload: FeedPost.Payload) async throws {
        lock.lock()
        posts.append(FeedPost(
            id: UUID(), authorID: viewerID, kind: kind, createdAt: .now,
            authorHandle: "viewer", authorDisplayName: nil, authorAvatarURL: nil,
            payload: payload, commentCount: 0, reactionCount: 0, viewerHasReacted: false
        ))
        lock.unlock()
    }

    func react(to postID: UUID) async throws {
        lock.lock(); reactions[postID, default: []].insert(viewerID); lock.unlock()
    }

    func unreact(to postID: UUID) async throws {
        lock.lock(); reactions[postID]?.remove(viewerID); lock.unlock()
    }

    // MARK: Comments

    func comments(on postID: UUID, limit: Int) async throws -> [PostComment] {
        lock.lock()
        defer { lock.unlock() }
        return (comments[postID] ?? [])
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(limit).map { $0 }
    }

    @discardableResult
    func addComment(to postID: UUID, body: String) async throws -> PostComment {
        if let problem = PostComment.validate(body) {
            throw SocialError.underlying(problem.message)
        }
        let comment = PostComment(
            id: UUID(), postID: postID, authorID: viewerID,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: .now, deletedAt: nil,
            authorHandle: "viewer", authorDisplayName: nil, authorAvatarURL: nil
        )
        lock.lock(); comments[postID, default: []].append(comment); lock.unlock()
        return comment
    }

    func deleteComment(_ commentID: UUID) async throws {
        lock.lock()
        defer { lock.unlock() }
        for (postID, list) in comments {
            guard let index = list.firstIndex(where: { $0.id == commentID }) else { continue }
            let old = list[index]
            comments[postID]?[index] = PostComment(
                id: old.id, postID: old.postID, authorID: old.authorID, body: old.body,
                createdAt: old.createdAt, deletedAt: .now,
                authorHandle: old.authorHandle, authorDisplayName: old.authorDisplayName,
                authorAvatarURL: old.authorAvatarURL
            )
            return
        }
    }

    func report(_ target: ReportTarget, reason: ReportReason, note: String?) async throws {
        lock.lock(); reports.append((target, reason)); lock.unlock()
    }
}
