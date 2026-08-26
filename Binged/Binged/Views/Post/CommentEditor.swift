//
//  CommentEditor.swift
//  Binged
//
//  Rewriting a comment you already posted.
//
//  Closes the last mechanical item in `GAP-AUDIT.md` §2 #14: the database has
//  permitted this since the first migration — `app.guard_comment_update`
//  contains a rule about who may change a body, which only means anything if
//  somebody can — and there was no service method and no UI, so the policy
//  guarded a door with no handle.
//
//  **Why a sheet rather than an inline field.** The row it edits is inside a
//  `List` that also carries swipe actions, and an inline editor competing with
//  a swipe gesture is a bad trade on a screen where the destructive action is
//  one swipe away. A sheet also gives the character counter and the validation
//  message somewhere to sit without the thread reflowing under the keyboard.
//

import SwiftUI

// MARK: - CommentEditor

struct CommentEditor: View {

    @Bindable var viewModel: PostViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Comment", text: $viewModel.editDraft, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($isFocused)
                    if let problem = viewModel.editProblem {
                        Text(problem.message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    // Stated before the fact, not discovered after it. Someone
                    // rewriting a comment on a thread other people have already
                    // replied to should know the change is disclosed.
                    Text("Edited comments are marked as edited.")
                }

                if viewModel.remainingEditCharacters < 100 {
                    Section {
                        Text("\(viewModel.remainingEditCharacters) characters left")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(
                                viewModel.remainingEditCharacters < 0 ? .red : .secondary
                            )
                    }
                }
            }
            .navigationTitle("Edit Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Explicitly cancels rather than only dismissing, so the
                    // draft cannot survive behind a closed sheet.
                    Button("Cancel") {
                        viewModel.cancelEditing()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await viewModel.saveEdit() } }
                        .disabled(!viewModel.canSaveEdit)
                }
            }
            .onAppear { isFocused = true }
        }
    }
}
