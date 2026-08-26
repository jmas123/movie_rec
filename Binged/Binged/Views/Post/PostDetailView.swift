//
//  PostDetailView.swift
//  Binged
//
//  A post and its thread.
//
//  Flat, not nested. One reply level is a schema change and a substantially
//  larger UI, and threaded conversation is not what a feed of rankings needs
//  first.
//

import SwiftUI

// MARK: - PostDetailView

struct PostDetailView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: PostViewModel
    @State private var reportTarget: ReportTarget?
    @State private var blockCandidate: BlockCandidate?

    /// Where a tapped title goes. Supplied by the stack that owns the routing,
    /// like `FeedView`'s — this screen registers no destinations of its own.
    private let onOpenTitle: ((TitleReference) -> Void)?

    init(
        post: FeedPost,
        service: FeedService,
        viewerID: UUID?,
        social: SocialService? = nil,
        onOpenTitle: ((TitleReference) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: PostViewModel(
            post: post, service: service, viewerID: viewerID, social: social
        ))
        self.onOpenTitle = onOpenTitle
    }

    /// Who is about to be blocked, and under what name to ask about it.
    private struct BlockCandidate: Identifiable {
        let id: UUID
        let name: String
    }

    var body: some View {
        List {
            Section {
                FeedPostCard(
                    post: viewModel.post,
                    onReact: { Task { await viewModel.toggleReaction() } },
                    // Reachable from here too: somebody who opened the thread
                    // to read the argument is the reader most likely to want
                    // the film itself.
                    onOpenTitle: onOpenTitle.map { open in
                        { open(viewModel.post.payload.reference) }
                    }
                )
            }

            Section("Comments") {
                if viewModel.comments.isEmpty && !viewModel.isLoading {
                    Text("No comments yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.comments) { comment in
                    CommentRow(comment: comment)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if viewModel.canDelete(comment) {
                                Button(role: .destructive) {
                                    Task { await viewModel.delete(comment) }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                            // Narrower than Delete on purpose: a post's owner
                            // may hide a comment on their own post but never
                            // rewrite its words under its author's name.
                            if viewModel.canEdit(comment) {
                                Button {
                                    viewModel.beginEditing(comment)
                                } label: { Label("Edit", systemImage: "pencil") }
                                .tint(.blue)
                            }
                            // Reporting is reachable wherever content appears,
                            // not only from Settings.
                            Button {
                                reportTarget = .comment(comment.id)
                            } label: { Label("Report", systemImage: "flag") }
                            .tint(.orange)

                            // Blocking the person, not just flagging the words.
                            // Reporting waits on a human; this takes effect now.
                            if viewModel.canBlock, !viewModel.canDelete(comment) {
                                Button {
                                    blockCandidate = .init(
                                        id: comment.authorID, name: comment.authorName
                                    )
                                } label: { Label("Block", systemImage: "hand.raised") }
                                .tint(.red)
                            }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("Post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Report post", systemImage: "flag") {
                        reportTarget = .post(viewModel.post.id)
                    }
                    if viewModel.canBlock {
                        Button(role: .destructive) {
                            blockCandidate = .init(
                                id: viewModel.post.authorID, name: viewModel.post.authorName
                            )
                        } label: {
                            Label("Block \(viewModel.post.authorName)", systemImage: "hand.raised")
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Post actions")
            }
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target) { reason, note in
                Task { await viewModel.report(target, reason: reason, note: note) }
            }
        }
        .sheet(isPresented: editorPrompt) {
            CommentEditor(viewModel: viewModel)
        }
        .alert(item: $blockCandidate) { candidate in
            Alert(
                title: Text("Block \(candidate.name)?"),
                message: Text("You will not see them again, and they will not see "
                              + "you. Any follow between you is removed."),
                primaryButton: .destructive(Text("Block")) {
                    Task { await viewModel.block(candidate.id) }
                },
                secondaryButton: .cancel()
            )
        }
        // Previously set in four places and read in none: a failed comment,
        // delete, report or rate-limit rejection was silent.
        .alert("Something went wrong", isPresented: errorPrompt) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.lastError ?? "")
        }
        // The thread belongs to someone the viewer just blocked; staying on it
        // would be the app arguing with the button they pressed.
        .onChange(of: viewModel.didBlock) { _, blocked in
            if blocked { dismiss() }
        }
        .task { await viewModel.load() }
    }

    private var errorPrompt: Binding<Bool> {
        Binding(get: { viewModel.lastError != nil }, set: { if !$0 { viewModel.clearError() } })
    }

    /// Driven by `editingID` rather than by a local `@State`, so the one place
    /// that knows whether an edit is in flight is the view model. Dismissing by
    /// swipe therefore clears the draft too, instead of leaving a hidden edit
    /// open behind the sheet.
    private var editorPrompt: Binding<Bool> {
        Binding(
            get: { viewModel.editingComment != nil },
            set: { if !$0 { viewModel.cancelEditing() } }
        )
    }

    // MARK: Composer

    private var composer: some View {
        @Bindable var viewModel = viewModel

        return VStack(spacing: Spacing.xs) {
            if let problem = viewModel.draftProblem {
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Spacing.sm) {
                TextField("Add a comment", text: $viewModel.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)

                // Only shown when it is close to mattering; a counter that is
                // always on screen is noise.
                if viewModel.remainingCharacters < 100 {
                    Text("\(viewModel.remainingCharacters)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(viewModel.remainingCharacters < 0 ? .red : .secondary)
                }

                Button {
                    Task { await viewModel.send() }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .disabled(!viewModel.canSend)
                .accessibilityLabel("Send comment")
            }
        }
        .padding(Spacing.md)
        .background(.bar)
    }
}

// MARK: - CommentRow

struct CommentRow: View {

    let comment: PostComment

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(comment.authorName).font(.caption.weight(.semibold))
                Text(comment.createdAt, format: .relative(presentation: .numeric))
                    .font(.caption2).foregroundStyle(.secondary)
                // Visible, because an edit that leaves no trace lets a comment
                // somebody already read, replied to or reported quietly become
                // a different comment.
                if comment.isEdited {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(comment.displayBody)
                .font(.callout)
                .foregroundStyle(comment.isDeleted ? .secondary : .primary)
                .italic(comment.isDeleted)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        // The marker has to reach VoiceOver too, or it is a disclosure only
        // sighted readers get.
        .accessibilityLabel(
            "\(comment.authorName): \(comment.displayBody)\(comment.isEdited ? ", edited" : "")"
        )
    }
}
