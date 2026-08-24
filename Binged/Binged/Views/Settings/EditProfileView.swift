//
//  EditProfileView.swift
//  Binged
//
//  Your own profile, as other people see it.
//
//  **Two gaps close here.** `AuthService.updateProfile` was implemented, routed
//  through `SessionViewModel.updateProfile`, and called by no view — so a
//  display name and bio could be stored and never edited. And `isPrivate` had
//  no control anywhere: the column existed, RLS enforced it, `follow` returned
//  `.pending` against it, and a user could never switch it on. That made the
//  follow-request inbox unreachable in practice — a queue that could only ever
//  be empty.
//
//  The handle is deliberately **not** editable here. Changing it is a rename
//  across every post, comment and mention that already names it, and the
//  server has a uniqueness constraint to arbitrate — that is its own feature
//  with its own confirmation, not a text field on a settings form.
//

import SwiftUI

// MARK: - EditProfileView

struct EditProfileView: View {

    @Environment(SessionViewModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var bio = ""
    @State private var isPrivate = false
    @State private var isSaving = false
    /// Seeded once. Re-seeding on every render would fight the keyboard.
    @State private var hasLoaded = false

    /// Mirrors the database's check constraint on `profiles.bio`.
    static let maximumBioLength = 300

    var body: some View {
        Form {
            Section {
                TextField("Display name", text: $displayName)
                    .textInputAutocapitalization(.words)
            } header: {
                Text("Name")
            } footer: {
                Text("Shown on your posts and profile. Your handle "
                     + "\(session.profile.map { "@\($0.handle)" } ?? "") doesn't change.")
            }

            Section {
                TextField("Bio", text: $bio, axis: .vertical)
                    .lineLimit(3...6)
                if remainingBio < 60 {
                    Text("\(remainingBio)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(remainingBio < 0 ? .red : .secondary)
                }
            } header: {
                Text("Bio")
            }

            Section {
                Toggle("Private account", isOn: $isPrivate)
            } header: {
                Text("Privacy")
            } footer: {
                // Said plainly, because the consequence is not obvious: going
                // private does not retract what followers already have.
                Text(isPrivate
                     ? "New followers have to be approved by you. People who "
                       + "already follow you keep their access."
                     : "Anyone can follow you and see what you publish.")
            }
        }
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!canSave)
            }
        }
        .task {
            guard !hasLoaded, let profile = session.profile else { return }
            displayName = profile.displayName ?? ""
            bio = profile.bio ?? ""
            isPrivate = profile.isPrivate
            hasLoaded = true
        }
    }

    // MARK: Behaviour

    private var remainingBio: Int {
        Self.maximumBioLength - bio.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private var canSave: Bool {
        session.profile != nil && remainingBio >= 0 && !isSaving
    }

    private func save() async {
        guard var profile = session.profile else { return }
        isSaving = true
        defer { isSaving = false }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty means "unset", not an empty string: the display name falls back
        // to the handle through `UserProfile.name`, and that only works on nil.
        profile.displayName = trimmedName.isEmpty ? nil : trimmedName
        profile.bio = trimmedBio.isEmpty ? nil : trimmedBio
        profile.isPrivate = isPrivate

        await session.updateProfile(profile)
        if session.lastError == nil { dismiss() }
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    NavigationStack {
        EditProfileView()
            .environment(SessionViewModel(service: MockAuthService()))
    }
}
#endif
