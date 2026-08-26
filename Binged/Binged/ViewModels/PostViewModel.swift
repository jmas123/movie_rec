//
//  PostViewModel.swift
//  Binged
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

    /// The comment being edited, and the text of that edit.
    ///
    /// Held by id rather than by value: the array is the source of truth and a
    /// stored copy would go stale the moment anything else in the thread
    /// changed.
    private(set) var editingID: UUID?
    var editDraft: String = ""

    @ObservationIgnored private let service: FeedService
    @ObservationIgnored private let social: SocialService?
    @ObservationIgnored private let viewerID: UUID?

    /// Set when the viewer blocks someone from this screen, so the view can
    /// leave — the thread it is showing is content from a person they just
    /// asked never to see again.
    private(set) var didBlock = false

    static let pageSize = 100

    /// - Parameter social: optional so a build with no social configuration —
    ///   and every existing test — still constructs one. Blocking is simply
    ///   unavailable without it, which the view reflects by not offering it.
    init(post: FeedPost, service: FeedService, viewerID: UUID?, social: SocialService? = nil) {
        self.post = post
        self.service = service
        self.social = social
        self.viewerID = viewerID
    }

    /// Whether the block controls have anything to call.
    var canBlock: Bool { social != nil }

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

    var remainingEditCharacters: Int {
        PostComment.maximumLength - editDraft.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    /// Whether the viewer may delete this comment.
    ///
    /// Advisory only. The policy decides — this just avoids showing a control
    /// that would fail.
    func canDelete(_ comment: PostComment) -> Bool {
        guard let viewerID, !comment.isDeleted else { return false }
        return comment.authorID == viewerID || post.authorID == viewerID
    }

    /// Whether the viewer may rewrite this comment.
    ///
    /// **Strictly narrower than `canDelete`**, and the difference is the point:
    /// a post's owner may hide a comment on their own post but may never change
    /// its words, because that would let them put a sentence in somebody else's
    /// mouth under that person's name. `app.guard_comment_update` enforces it;
    /// this mirrors the rule so the control is not offered where it would fail.
    func canEdit(_ comment: PostComment) -> Bool {
        guard let viewerID, !comment.isDeleted else { return false }
        return comment.authorID == viewerID
    }

    /// The comment currently open in the editor, if any.
    var editingComment: PostComment? {
        guard let editingID else { return nil }
        return comments.first { $0.id == editingID }
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            comments = try await service.comments(on: post.id, limit: Self.pageSize)
        } catch {
            lastError = ErrorMessage.text(for: error)
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
            lastError = ErrorMessage.text(for: error)
        }
    }

    // MARK: Editing

    func beginEditing(_ comment: PostComment) {
        guard canEdit(comment) else { return }
        editingID = comment.id
        editDraft = comment.body
    }

    func cancelEditing() {
        editingID = nil
        editDraft = ""
    }

    var editProblem: PostComment.Problem? {
        editDraft.isEmpty ? nil : PostComment.validate(editDraft)
    }

    /// Whether Save should be offered.
    ///
    /// Unchanged text is not saveable: sending it would stamp `edited_at` on a
    /// comment nobody edited, which is precisely the marker other people rely
    /// on to mean something.
    var canSaveEdit: Bool {
        guard let comment = editingComment, PostComment.validate(editDraft) == nil else {
            return false
        }
        return editDraft.trimmingCharacters(in: .whitespacesAndNewlines) != comment.body
    }

    func saveEdit() async {
        guard canSaveEdit, let comment = editingComment else { return }
        let body = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await service.editComment(comment.id, body: body)
            if let index = comments.firstIndex(where: { $0.id == comment.id }) {
                comments[index] = comment.edited(body: body, at: .now)
            }
            cancelEditing()
        } catch {
            // The editor stays open with the text intact — the user's words are
            // the one thing a failure here must not cost them.
            lastError = ErrorMessage.text(for: error)
        }
    }

    func delete(_ comment: PostComment) async {
        do {
            try await service.deleteComment(comment.id)
            if let index = comments.firstIndex(where: { $0.id == comment.id }) {
                comments[index] = comment.deleted()
            }
            // A deleted comment cannot stay open in the editor: `canEdit` is
            // false for it, so Save would silently do nothing and the sheet
            // would be a dead end.
            if editingID == comment.id { cancelEditing() }
            post = post.withCommentCount(max(0, post.commentCount - 1))
        } catch {
            lastError = ErrorMessage.text(for: error)
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
            lastError = ErrorMessage.text(for: error)
        }
    }

    /// Blocks a person — the post's author, or whoever wrote a comment.
    ///
    /// Reporting asks someone to look; blocking is the one that takes effect
    /// immediately, so both have to be offered wherever a person's words are on
    /// screen. On success the view dismisses rather than redrawing a thread the
    /// viewer has just cut themselves off from.
    func block(_ userID: UUID) async {
        guard let social else { return }
        do {
            try await social.block(userID)
            didBlock = true
        } catch {
            lastError = ErrorMessage.text(for: error)
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
            createdAt: createdAt, deletedAt: .now, editedAt: editedAt,
            authorHandle: authorHandle, authorDisplayName: authorDisplayName,
            authorAvatarURL: authorAvatarURL
        )
    }
}
