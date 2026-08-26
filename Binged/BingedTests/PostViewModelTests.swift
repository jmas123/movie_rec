//
//  PostViewModelTests.swift
//  BingedTests
//
//  Comments, reactions, and the safety rails user-generated content needs from
//  the first commit rather than the last phase.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Helpers

private func samplePost(author: UUID = UUID(), comments: Int = 0) -> FeedPost {
    FeedPost(
        id: UUID(), authorID: author, kind: .ranked, createdAt: .now,
        authorHandle: "alex", authorDisplayName: "Alex", authorAvatarURL: nil,
        payload: .init(externalId: "tmdb:movie:1", title: "Dune", year: 2024,
                       mediaType: .movie, sentiment: .liked, rankInBucket: 0,
                       bucketSize: 8, reviewExcerpt: nil),
        commentCount: comments, reactionCount: 0, viewerHasReacted: false
    )
}

// MARK: - Validation

@Suite("PostComment")
struct PostCommentTests {

    @Test("Empty and whitespace-only comments are refused")
    func emptyIsInvalid() {
        #expect(PostComment.validate("") == .empty)
        #expect(PostComment.validate("   \n ") == .empty)
        #expect(PostComment.validate("ok") == nil)
    }

    @Test("The length limit mirrors the database constraint")
    func lengthLimit() {
        // The constraint is the real limit; this exists so the user finds out
        // while typing rather than after tapping send.
        let atLimit = String(repeating: "a", count: PostComment.maximumLength)
        #expect(PostComment.validate(atLimit) == nil)
        #expect(PostComment.validate(atLimit + "bc") == .tooLong(2))
    }

    @Test("A deleted comment keeps its place and loses its content")
    func softDelete() {
        // A comment that vanished entirely would leave the thread misshapen and
        // the counts wrong.
        let comment = PostComment(
            id: UUID(), postID: UUID(), authorID: UUID(), body: "secret",
            createdAt: .now, deletedAt: .now, editedAt: nil,
            authorHandle: "a", authorDisplayName: nil, authorAvatarURL: nil
        )
        #expect(comment.isDeleted)
        #expect(comment.displayBody == "Comment deleted")
        #expect(!comment.displayBody.contains("secret"))
    }
}

// MARK: - View model

@Suite("PostViewModel")
@MainActor
struct PostViewModelTests {

    @Test("Sending a comment adds it and moves the count")
    func sendComment() async {
        let viewer = UUID()
        let post = samplePost()
        let service = MockFeedService(viewer: viewer, posts: [post])
        let viewModel = PostViewModel(post: post, service: service, viewerID: viewer)

        viewModel.draft = "Great pick"
        await viewModel.send()

        #expect(viewModel.comments.count == 1)
        #expect(viewModel.comments.first?.body == "Great pick")
        #expect(viewModel.post.commentCount == 1)
        #expect(viewModel.draft.isEmpty)
    }

    @Test("A failed send gives the text back rather than losing it")
    func failedSendKeepsDraft() async {
        // Losing a typed comment to a network blip is a small betrayal that
        // users remember.
        final class FailingFeed: FeedService, @unchecked Sendable {
            func feed(before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] { [] }
            func posts(by userID: UUID, before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] { [] }
            func createPost(kind: FeedPost.Kind, payload: FeedPost.Payload) async throws {}
            func react(to postID: UUID) async throws {}
            func unreact(to postID: UUID) async throws {}
            func comments(on postID: UUID, limit: Int) async throws -> [PostComment] { [] }
            func addComment(to postID: UUID, body: String) async throws -> PostComment {
                throw SocialError.underlying("offline")
            }
            func editComment(_ commentID: UUID, body: String) async throws {}
            func deleteComment(_ commentID: UUID) async throws {}
            func report(_ target: ReportTarget, reason: ReportReason, note: String?) async throws {}
        }

        let viewModel = PostViewModel(post: samplePost(), service: FailingFeed(), viewerID: UUID())
        viewModel.draft = "Typed this out"
        await viewModel.send()

        #expect(viewModel.draft == "Typed this out")
        #expect(viewModel.lastError != nil)
    }

    @Test("An invalid draft cannot be sent")
    func invalidDraftBlocked() {
        let viewModel = PostViewModel(post: samplePost(), service: MockFeedService(), viewerID: UUID())
        viewModel.draft = ""
        #expect(!viewModel.canSend)

        viewModel.draft = String(repeating: "a", count: PostComment.maximumLength + 1)
        #expect(!viewModel.canSend)
        #expect(viewModel.draftProblem != nil)
        #expect(viewModel.remainingCharacters < 0)
    }

    @Test("Signed out, commenting is not offered")
    func signedOutCannotComment() {
        let viewModel = PostViewModel(post: samplePost(), service: MockFeedService(), viewerID: nil)
        viewModel.draft = "Hello"
        #expect(!viewModel.canSend)
    }

    @Test("Reacting twice is one reaction")
    func reactionsDeduplicate() async {
        // The `(post_id, user_id)` primary key does this on the server; the mock
        // uses a Set for the same reason. The client never counts.
        let viewer = UUID()
        let post = samplePost()
        let service = MockFeedService(viewer: viewer, posts: [post])

        try? await service.react(to: post.id)
        try? await service.react(to: post.id)

        let page = try? await service.feed(before: nil, limit: 10)
        #expect(page?.first?.reactionCount == 1)
    }

    @Test("An optimistic reaction rolls back on failure")
    func reactionRollsBack() async {
        final class FailingReactions: FeedService, @unchecked Sendable {
            func feed(before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] { [] }
            func posts(by userID: UUID, before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] { [] }
            func createPost(kind: FeedPost.Kind, payload: FeedPost.Payload) async throws {}
            func react(to postID: UUID) async throws { throw SocialError.blocked }
            func unreact(to postID: UUID) async throws { throw SocialError.blocked }
            func comments(on postID: UUID, limit: Int) async throws -> [PostComment] { [] }
            func addComment(to postID: UUID, body: String) async throws -> PostComment {
                throw SocialError.blocked
            }
            func editComment(_ commentID: UUID, body: String) async throws {}
            func deleteComment(_ commentID: UUID) async throws {}
            func report(_ target: ReportTarget, reason: ReportReason, note: String?) async throws {}
        }

        let post = samplePost()
        let viewModel = PostViewModel(post: post, service: FailingReactions(), viewerID: UUID())
        await viewModel.toggleReaction()

        #expect(viewModel.post.viewerHasReacted == post.viewerHasReacted)
        #expect(viewModel.post.reactionCount == post.reactionCount)
    }

    @Test("Deleting a comment soft-deletes it and lowers the count")
    func deleteComment() async {
        let viewer = UUID()
        let post = samplePost(author: viewer)
        let service = MockFeedService(viewer: viewer, posts: [post])
        let viewModel = PostViewModel(post: post, service: service, viewerID: viewer)

        viewModel.draft = "Mistake"
        await viewModel.send()
        let comment = viewModel.comments[0]

        await viewModel.delete(comment)

        #expect(viewModel.comments[0].isDeleted)
        #expect(viewModel.comments.count == 1, "the row should keep its place")
        #expect(viewModel.post.commentCount == 0)
    }

    @Test("You may delete your own comment, or any comment on your own post")
    func deletePermissions() async {
        // Advisory only — the policy decides. This avoids offering a control
        // that would fail.
        let me = UUID()
        let stranger = UUID()

        let myPost = samplePost(author: me)
        let onMyPost = PostComment(
            id: UUID(), postID: myPost.id, authorID: stranger, body: "hi",
            createdAt: .now, deletedAt: nil, editedAt: nil, authorHandle: "s",
            authorDisplayName: nil, authorAvatarURL: nil
        )
        let mine = PostViewModel(post: myPost, service: MockFeedService(), viewerID: me)
        #expect(mine.canDelete(onMyPost), "an author cannot moderate their own post")

        let theirPost = samplePost(author: stranger)
        let theirs = PostViewModel(post: theirPost, service: MockFeedService(), viewerID: me)
        #expect(!theirs.canDelete(onMyPost), "a stranger's comment was deletable")
    }

    @Test("Reporting works from the comment surface, not just Settings")
    func reportingIsReachable() async {
        let service = MockFeedService()
        let post = samplePost()
        let viewModel = PostViewModel(post: post, service: service, viewerID: UUID())

        await viewModel.report(.post(post.id), reason: .spam)
        await viewModel.report(.comment(UUID()), reason: .harassment, note: "details")

        #expect(service.reports.count == 2)
        #expect(service.reports.map(\.reason) == [.spam, .harassment])
    }

    @Test("Every report reason has actionable copy")
    func reasonsHaveTitles() {
        #expect(ReportReason.allCases.count >= 5)
        for reason in ReportReason.allCases {
            #expect(!reason.title.isEmpty)
        }
    }

    @Test("Report targets map to the right column")
    func reportTargetColumns() {
        #expect(ReportTarget.post(UUID()).column == "post_id")
        #expect(ReportTarget.comment(UUID()).column == "comment_id")
        #expect(ReportTarget.profile(UUID()).column == "profile_id")
    }
}
