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
//  The handle is deliberately **not** editable here — with one exception.
//  Changing an established handle is a rename across every post, comment and
//  mention that already names it, and the server has a uniqueness constraint to
//  arbitrate; that is its own feature with its own confirmation, not a text
//  field on a settings form.
//
//  **The exception is a handle that was never set.** An account created while
//  email confirmation is switched on has no session at sign-up, so the chosen
//  handle cannot be claimed then; `PendingHandleStore` parks it and the first
//  sign-in claims it. If that claim lost a race — somebody else took the name
//  in between — the account is left wearing `app.handle_new_user()`'s
//  placeholder, and with no field here that would be permanent. Setting a name
//  for the first time is not a rename: nothing yet refers to the placeholder,
//  so none of the reasons above apply.
//

import SwiftUI

// MARK: - EditProfileView

struct EditProfileView: View {

    @Environment(SessionViewModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var bio = ""
    @State private var handle = ""
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
                Text(needsHandle
                     ? "Shown on your posts and profile."
                     : "Shown on your posts and profile. Your handle "
                       + "\(session.profile.map { "@\($0.handle)" } ?? "") doesn't change.")
            }

            if needsHandle {
                handleSection
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

            // A failed save was previously silent: `updateProfile` routes its
            // error into `session.lastError`, `save()` reads it to decide
            // whether to dismiss, and no view ever showed it. That is survivable
            // for a bio; for a handle it is not, because "taken" is the one
            // outcome the user has to act on.
            if let error = session.lastError {
                Section {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Private account", isOn: $isPrivate)
            } header: {
                Text("Privacy")
            } footer: {
                // Said plainly, because two consequences are not obvious.
                // Going private does not retract what followers already have —
                // and this one toggle is the whole of who can see the ranking,
                // since the separate publish opt-in was removed. A user looking
                // for a "share my ranking" switch is looking for this one.
                Text(isPrivate
                     ? "New followers have to be approved by you, and only "
                       + "approved followers can see your ranking. People who "
                       + "already follow you keep their access."
                     : "Anyone on Binged can follow you and see your ranking, "
                       + "your posts and your comments.")
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
            // Seeded empty, never with the placeholder: prefilling a field with
            // `u5f3a2b9c…` invites someone to save it and make it permanent.
            handle = ""
            hasLoaded = true
        }
    }

    // MARK: Handle

    /// True only while the profile still wears the handle the trigger gave it.
    /// Derived per user id rather than pattern-matched — see `Handle.placeholder`.
    private var needsHandle: Bool {
        guard let profile = session.profile else { return false }
        return Handle.isPlaceholder(profile.handle, for: profile.id)
    }

    @ViewBuilder
    private var handleSection: some View {
        Section {
            HStack(spacing: 2) {
                Text("@").foregroundStyle(.secondary)
                TextField("handle", text: $handle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
            }
            if let problem = handleProblem {
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Handle")
        } footer: {
            // Said plainly rather than blamed on the server: the user did pick
            // a handle, and being told to pick again with no explanation reads
            // as the app losing it — which, until this existed, it had.
            Text("Your account doesn't have a handle yet. The one you chose when "
                 + "you signed up couldn't be saved, so pick one now. "
                 + "Letters, numbers and underscores, \(Handle.minimumLength)–"
                 + "\(Handle.maximumLength) characters.")
        }
    }

    /// Nil while the field is empty, so the form does not scold somebody who
    /// has not started typing.
    private var handleProblem: Handle.Problem? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Handle.validate(trimmed)
    }

    // MARK: Behaviour

    private var remainingBio: Int {
        Self.maximumBioLength - bio.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    private var canSave: Bool {
        guard session.profile != nil, remainingBio >= 0, !isSaving else { return false }
        // A profile with no handle must leave this screen with one — saving a
        // display name while the handle stays a placeholder is the state this
        // section exists to end, and offering Save would look like it worked.
        if needsHandle { return Handle.isValid(handle) }
        return true
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
        if needsHandle, Handle.isValid(handle) {
            // The unique index is the arbiter, not the field: `updateProfile`
            // turns a 409 into `handleTaken`, which lands in `session.lastError`
            // and keeps the sheet open so the name can be changed.
            profile.handle = Handle.normalize(handle)
        }

        session.clearError()
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
