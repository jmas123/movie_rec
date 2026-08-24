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

    init(post: FeedPost, service: FeedService, viewerID: UUID?, social: SocialService? = nil) {
        _viewModel = State(initialValue: PostViewModel(
            post: post, service: service, viewerID: viewerID, social: social
        ))
    }

    /// Who is about to be blocked, and under what name to ask about it.
    private struct BlockCandidate: Identifiable {
        let id: UUID
        let name: String
    }

    var body: some View {
        List {
            Section {
                FeedPostCard(post: viewModel.post) {
                    Task { await viewModel.toggleReaction() }
                }
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
            }
            Text(comment.displayBody)
                .font(.callout)
                .foregroundStyle(comment.isDeleted ? .secondary : .primary)
                .italic(comment.isDeleted)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(comment.authorName): \(comment.displayBody)")
    }
}

// MARK: - ReportSheet

struct ReportSheet: View {

    let target: ReportTarget
    let onSubmit: (ReportReason, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .spam
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Why are you reporting this?") {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Anything else? (optional)") {
                    TextField("Details", text: $note, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    Text("Reports are reviewed within 24 hours. You can also block "
                         + "this person so you stop seeing their content immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        onSubmit(reason, note.isEmpty ? nil : note)
                        dismiss()
                    }
                }
            }
        }
    }
}
