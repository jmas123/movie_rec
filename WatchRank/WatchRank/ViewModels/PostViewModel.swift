//
//  PostViewModel.swift
//  WatchRank
//
//  One post and its thread.
//

import Foundation
import Observation

// MARK: - PostViewModel

@MainActor
@Observable
final class PostViewModel {

    private(set) var post: FeedPost
    private(set) var comments: [PostComment] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// The composer's text. Validated as it changes so the user finds out while
    /// typing rather than after tapping send.
    var draft: String = ""

    @ObservationIgnored private let service: FeedService
    @ObservationIgnored private let viewerID: UUID?

    static let pageSize = 100

    init(post: FeedPost, service: FeedService, viewerID: UUID?) {
        self.post = post
        self.service = service
        self.viewerID = viewerID
    }

    // MARK: Derived

    var draftProblem: PostComment.Problem? {
        draft.isEmpty ? nil : PostComment.validate(draft)
    }

    var canSend: Bool {
        viewerID != nil && PostComment.validate(draft) == nil
    }

    var remainingCharacters: Int {
        PostComment.maximumLength - draft.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    /// Whether the viewer may delete this comment.
    ///
    /// Advisory only. The policy decides — this just avoids showing a control
    /// that would fail.
    func canDelete(_ comment: PostComment) -> Bool {
        guard let viewerID, !comment.isDeleted else { return false }
        return comment.authorID == viewerID || post.authorID == viewerID
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            comments = try await service.comments(on: post.id, limit: Self.pageSize)
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: Commenting

    func send() async {
        guard canSend else { return }
        let body = draft
        draft = ""

        do {
            let comment = try await service.addComment(to: post.id, body: body)
            comments.append(comment)
            // The count is trigger-maintained on the server; this keeps the
            // visible number honest until the next fetch without ever writing
            // it back.
            post = post.withCommentCount(post.commentCount + 1)
        } catch {
            draft = body      // give the text back rather than losing it
            lastError = (error as? SocialError)?.description ?? String(describing: error)
        }
    }

    func delete(_ comment: PostComment) async {
        do {
            try await service.deleteComment(comment.id)
            if let index = comments.firstIndex(where: { $0.id == comment.id }) {
                comments[index] = comment.deleted()
            }
            post = post.withCommentCount(max(0, post.commentCount - 1))
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: Reactions

    func toggleReaction() async {
        let original = post
        post = post.togglingReaction()
        do {
            if original.viewerHasReacted {
                try await service.unreact(to: original.id)
            } else {
                try await service.react(to: original.id)
            }
        } catch {
            post = original
        }
    }

    // MARK: Safety

    func report(_ target: ReportTarget, reason: ReportReason, note: String? = nil) async {
        do {
            try await service.report(target, reason: reason, note: note)
        } catch {
            lastError = String(describing: error)
        }
    }

    func clearError() { lastError = nil }
}

// MARK: - Helpers

extension FeedPost {
    func withCommentCount(_ count: Int) -> FeedPost {
        FeedPost(
            id: id, authorID: authorID, kind: kind, createdAt: createdAt,
            authorHandle: authorHandle, authorDisplayName: authorDisplayName,
            authorAvatarURL: authorAvatarURL, payload: payload,
            commentCount: count, reactionCount: reactionCount,
            viewerHasReacted: viewerHasReacted
        )
    }
}

extension PostComment {
    func deleted() -> PostComment {
        PostComment(
            id: id, postID: postID, authorID: authorID, body: body,
            createdAt: createdAt, deletedAt: .now,
            authorHandle: authorHandle, authorDisplayName: authorDisplayName,
            authorAvatarURL: authorAvatarURL
        )
    }
}
