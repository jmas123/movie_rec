//
//  CommentEditingTests.swift
//  BingedTests
//
//  Editing a comment, and the two rules that make it safe to allow.
//
//  `GAP-AUDIT.md` §2 #14 listed comment editing as written-in-the-database and
//  absent-from-the-app: `app.guard_comment_update` has always carried a rule
//  about who may change a body, which only means something once somebody can.
//
//  The rules worth testing are not "does the text change". They are:
//
//  1. **Only the author.** `canDelete` is deliberately wider than `canEdit` —
//     a post's owner may hide a comment on their own post. If `canEdit` were
//     equally wide, the owner could put a sentence in somebody else's mouth
//     under that person's name and handle.
//  2. **An edit leaves a mark.** A comment other people have read, replied to
//     or reported must not be able to become a different comment silently.
//     `edited_at` is what a moderator looking at a reported id has to go on.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Helpers

private func post(by author: UUID) -> FeedPost {
    FeedPost(
        id: UUID(), authorID: author, kind: .ranked, createdAt: .now,
        authorHandle: "alex", authorDisplayName: "Alex", authorAvatarURL: nil,
        payload: .init(externalId: "tmdb:movie:1", title: "Dune", year: 2024,
                       mediaType: .movie, sentiment: .liked, rankInBucket: 0,
                       bucketSize: 8, reviewExcerpt: nil),
        commentCount: 0, reactionCount: 0, viewerHasReacted: false
    )
}

private func comment(
    on postID: UUID,
    by author: UUID,
    body: String = "Original",
    deleted: Bool = false
) -> PostComment {
    PostComment(
        id: UUID(), postID: postID, authorID: author, body: body,
        createdAt: .now, deletedAt: deleted ? .now : nil, editedAt: nil,
        authorHandle: "someone", authorDisplayName: nil, authorAvatarURL: nil
    )
}

// MARK: - Permission

@MainActor
@Suite("Comment editing — who may")
struct CommentEditPermissionTests {

    @Test("The author may edit their own comment")
    func authorMayEdit() async {
        let viewer = UUID()
        let target = post(by: UUID())
        let service = MockFeedService(viewer: viewer)
        let mine = comment(on: target.id, by: viewer)
        service.seedComment(mine)

        let vm = PostViewModel(post: target, service: service, viewerID: viewer)
        await vm.load()

        #expect(vm.canEdit(mine))
    }

    /// The asymmetry is the whole point of having two predicates.
    @Test("A post's owner may delete a comment on it but may not rewrite it")
    func ownerMayDeleteButNotEdit() async {
        let viewer = UUID()
        let stranger = UUID()
        let mine = post(by: viewer)                       // viewer owns the post
        let service = MockFeedService(viewer: viewer)
        let theirs = comment(on: mine.id, by: stranger)   // somebody else's words
        service.seedComment(theirs)

        let vm = PostViewModel(post: mine, service: service, viewerID: viewer)
        await vm.load()

        #expect(vm.canDelete(theirs), "the owner may hide it")
        #expect(!vm.canEdit(theirs), "the owner may not put words in their mouth")
    }

    @Test("A signed-out viewer may not edit anything")
    func signedOutMayNotEdit() async {
        let author = UUID()
        let target = post(by: author)
        let service = MockFeedService(viewer: author)
        let existing = comment(on: target.id, by: author)
        service.seedComment(existing)

        let vm = PostViewModel(post: target, service: service, viewerID: nil)
        await vm.load()

        #expect(!vm.canEdit(existing))
    }

    @Test("A deleted comment cannot be edited back into existence")
    func deletedIsNotEditable() async {
        let viewer = UUID()
        let target = post(by: UUID())
        let service = MockFeedService(viewer: viewer)
        let gone = comment(on: target.id, by: viewer, deleted: true)
        service.seedComment(gone)

        let vm = PostViewModel(post: target, service: service, viewerID: viewer)
        await vm.load()

        #expect(!vm.canEdit(gone))
    }

    /// The service must refuse it too. The view hiding a control is a courtesy;
    /// the rule has to hold when the control is not what made the call.
    @Test("The service refuses an edit from somebody who is not the author")
    func serviceRefusesNonAuthor() async throws {
        let viewer = UUID()
        let target = post(by: viewer)
        let service = MockFeedService(viewer: viewer)
        let theirs = comment(on: target.id, by: UUID())
        service.seedComment(theirs)

        await #expect(throws: (any Error).self) {
            try await service.editComment(theirs.id, body: "Rewritten")
        }

        let after = try await service.comments(on: target.id, limit: 10)
        #expect(after.first?.body == "Original")
    }
}

// MARK: - Behaviour

@MainActor
@Suite("Comment editing — what happens")
struct CommentEditBehaviourTests {

    private func loadedViewModel() async -> (PostViewModel, MockFeedService, PostComment) {
        let viewer = UUID()
        let target = post(by: UUID())
        let service = MockFeedService(viewer: viewer)
        let mine = comment(on: target.id, by: viewer)
        service.seedComment(mine)
        let vm = PostViewModel(post: target, service: service, viewerID: viewer)
        await vm.load()
        return (vm, service, mine)
    }

    @Test("Saving rewrites the body and marks the comment edited")
    func saveRewritesAndMarks() async throws {
        let (vm, service, mine) = await loadedViewModel()

        vm.beginEditing(mine)
        #expect(vm.editDraft == "Original", "the editor opens on the existing text")

        vm.editDraft = "Rewritten"
        #expect(vm.canSaveEdit)
        await vm.saveEdit()

        #expect(vm.lastError == nil)
        #expect(vm.comments.first?.body == "Rewritten")
        #expect(vm.comments.first?.isEdited == true)
        // The local copy must not be the only thing that changed.
        let stored = try await service.comments(on: mine.postID, limit: 10)
        #expect(stored.first?.body == "Rewritten")
        #expect(stored.first?.editedAt != nil)
    }

    @Test("Saving closes the editor")
    func saveClosesTheEditor() async {
        let (vm, _, mine) = await loadedViewModel()
        vm.beginEditing(mine)
        vm.editDraft = "Rewritten"
        await vm.saveEdit()
        #expect(vm.editingComment == nil)
        #expect(vm.editDraft.isEmpty)
    }

    /// Otherwise the marker stops meaning anything: a comment could be stamped
    /// "edited" by opening the editor and pressing Save.
    @Test("Unchanged text is not saveable")
    func unchangedTextIsNotSaveable() async {
        let (vm, _, mine) = await loadedViewModel()

        vm.beginEditing(mine)
        #expect(!vm.canSaveEdit, "nothing has changed yet")

        vm.editDraft = "  Original  "
        #expect(!vm.canSaveEdit, "whitespace is not a change")

        vm.editDraft = "Original."
        #expect(vm.canSaveEdit)
    }

    @Test("An invalid edit is refused before it is sent")
    func invalidEditIsRefused() async {
        let (vm, _, mine) = await loadedViewModel()
        vm.beginEditing(mine)

        vm.editDraft = "   "
        #expect(vm.editProblem == .empty)
        #expect(!vm.canSaveEdit)

        vm.editDraft = String(repeating: "a", count: PostComment.maximumLength + 3)
        #expect(vm.editProblem == .tooLong(3))
        #expect(!vm.canSaveEdit)
    }

    @Test("Cancelling leaves the comment alone")
    func cancelDiscards() async {
        let (vm, _, mine) = await loadedViewModel()
        vm.beginEditing(mine)
        vm.editDraft = "Rewritten"
        vm.cancelEditing()

        #expect(vm.editingComment == nil)
        #expect(vm.comments.first?.body == "Original")
        #expect(vm.comments.first?.isEdited == false)
    }

    /// The sheet is driven by `editingComment`, so an editor left open on a
    /// deleted comment would be a dead end: `canEdit` is false for it and Save
    /// would silently do nothing.
    @Test("Deleting the comment being edited closes the editor")
    func deleteClosesTheEditor() async {
        let (vm, _, mine) = await loadedViewModel()
        vm.beginEditing(mine)
        vm.editDraft = "Rewritten"

        await vm.delete(mine)

        #expect(vm.editingComment == nil)
        #expect(vm.comments.first?.isDeleted == true)
    }

    @Test("beginEditing does nothing for a comment the viewer may not edit")
    func beginEditingIsGated() async {
        let viewer = UUID()
        let mine = post(by: viewer)
        let service = MockFeedService(viewer: viewer)
        let theirs = comment(on: mine.id, by: UUID())
        service.seedComment(theirs)
        let vm = PostViewModel(post: mine, service: service, viewerID: viewer)
        await vm.load()

        vm.beginEditing(theirs)
        #expect(vm.editingComment == nil)
    }
}

// MARK: - The marker

@Suite("The edited marker")
struct EditedMarkerTests {

    @Test("A never-edited comment is not marked")
    func neverEdited() {
        let c = comment(on: UUID(), by: UUID())
        #expect(!c.isEdited)
    }

    /// Two disclaimers on one empty row reads as noise, and the body is gone
    /// either way.
    @Test("A deleted comment is not also marked edited")
    func deletedBeatsEdited() {
        let c = comment(on: UUID(), by: UUID(), deleted: true).edited(body: "x", at: .now)
        #expect(c.isDeleted)
        #expect(!c.isEdited)
    }

    @Test("edited(body:at:) changes only the body and the marker")
    func editedPreservesIdentity() {
        let original = comment(on: UUID(), by: UUID())
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = original.edited(body: "New", at: stamp)

        #expect(updated.id == original.id)
        #expect(updated.postID == original.postID)
        #expect(updated.authorID == original.authorID)
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.authorHandle == original.authorHandle)
        #expect(updated.body == "New")
        #expect(updated.editedAt == stamp)
    }
}
