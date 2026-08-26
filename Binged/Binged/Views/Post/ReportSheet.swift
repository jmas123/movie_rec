//
//  ReportSheet.swift
//  Binged
//
//  The form behind every Report action in the app.
//
//  Lived inside `PostDetailView.swift` until 2026-08-25, against the project's
//  one-primary-type-per-file rule, and `GAP-AUDIT.md` §5 recorded it as such.
//  The placement was not merely untidy: `ReportSheet` is presented from the
//  feed row's context menu, the post thread, a comment, and the profile actions
//  menu — four surfaces, none of which is a post detail — so the file it lived
//  in named the one caller it had when it was written and has misdescribed it
//  ever since. Guideline 1.2 turns on this sheet being reachable, which makes
//  "where does Report live?" a question worth answering from the file tree.
//
//  It stays deliberately dumb: it collects a reason and an optional note and
//  hands them back. Submitting is the caller's job, because who to report and
//  what service to tell differs per surface.
//

import SwiftUI

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
