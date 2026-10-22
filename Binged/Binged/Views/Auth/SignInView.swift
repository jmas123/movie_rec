//
//  SignInView.swift
//  Binged
//
//  Sign in, sign up, and the explanation for a build that can do neither.
//

import SwiftUI

// MARK: - SignInView

struct SignInView: View {

    @Environment(SessionViewModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var handle = ""
    @State private var handleStatus: HandleStatus = .idle
    @State private var checkTask: Task<Void, Never>?

    /// Guideline 3.1.2 / 1.2: an app with user-generated content must have the
    /// user agree to terms before an account exists. Deliberately not
    /// persisted — it is a precondition of *this* sign-up, not a setting, and
    /// resetting it when the form is dismissed is the honest behaviour.
    @State private var acceptedTerms = false

    /// Set once a reset email has been requested, so the form can confirm it
    /// without claiming the address exists.
    @State private var resetRequested = false

    enum Mode: String, CaseIterable, Identifiable {
        case signIn, signUp
        var id: String { rawValue }
        var title: String { self == .signIn ? "Sign In" : "Create Account" }
    }

    enum HandleStatus: Equatable {
        case idle, checking, available, taken, invalid(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.isAvailable {
                    form
                } else {
                    unavailable
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: session.isSignedIn) { _, signedIn in
                if signedIn { dismiss() }
            }
        }
    }

    // MARK: Unavailable

    private var unavailable: some View {
        EmptyStateView(
            systemImage: "person.crop.circle.badge.questionmark",
            message: "This build has no account server configured, so the social "
                   + "features are off. Everything else works as normal."
        )
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                TextField("Email", text: $email)
                    .onChange(of: email) { _, _ in resetRequested = false }
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textContentType(mode == .signUp ? .newPassword : .password)

                if mode == .signUp {
                    handleField
                }
            } footer: {
                if mode == .signUp {
                    Text("Passwords need at least \(AuthError.minimumPasswordLength) characters. "
                         + "Your handle is how people find you and cannot be changed often.")
                }
            }

            if mode == .signIn {
                Section {
                    Button("Forgot password?") { Task { await requestReset() } }
                        .font(.callout)
                        .disabled(email.isEmpty || session.isBusy)
                } footer: {
                    if resetRequested {
                        // Deliberately not "we sent you an email" — that would
                        // confirm the address has an account to anyone typing
                        // guesses into the field.
                        Text("If there's an account for \(email), a reset link is "
                             + "on its way.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Enter your email above first.")
                    }
                }
            }

            if let error = session.lastError {
                Section {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            if mode == .signUp {
                termsSection
            }

            Section {
                Button(mode.title) { Task { await submit() } }
                    .disabled(!canSubmit || session.isBusy)
            }
        }
        .disabled(session.isBusy)
    }

    private var handleField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("@").foregroundStyle(.secondary)
                TextField("handle", text: $handle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: handle) { _, new in scheduleCheck(new) }

                // The status was conveyed by a spinner, a green tick or a red
                // cross and nothing else — three states a screen reader user
                // could not tell apart, on the one field that decides whether
                // the form can be submitted.
                Group {
                    switch handleStatus {
                    case .checking:  ProgressView().controlSize(.small)
                    case .available: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .taken:     Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    default:         EmptyView()
                    }
                }
                .accessibilityLabel(handleStatusDescription)
            }

            if case .invalid(let message) = handleStatus {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if handleStatus == .taken {
                Text("That handle is taken.").font(.caption).foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Spoken form of `handleStatus`. Empty for the idle case, so VoiceOver
    /// says nothing rather than announcing an absence.
    private var handleStatusDescription: String {
        switch handleStatus {
        case .idle:                 return ""
        case .checking:             return "Checking whether that handle is free"
        case .available:            return "Handle available"
        case .taken:                return "Handle already taken"
        case .invalid(let message): return message
        }
    }

    /// Terms and privacy, with the links inline rather than buried in Settings
    /// — agreeing to something you cannot read from where you are agreeing is
    /// not agreement.
    private var termsSection: some View {
        Section {
            Toggle(isOn: $acceptedTerms) {
                Text("I agree to the Terms of Use and Privacy Policy.")
                    .font(.callout)
            }
            .accessibilityHint("Required to create an account")

            HStack(spacing: Spacing.md) {
                if let terms = SupportLinks.termsOfUse {
                    Link("Terms of Use", destination: terms)
                }
                if let privacy = SupportLinks.privacyPolicy {
                    Link("Privacy Policy", destination: privacy)
                }
            }
            .font(.footnote)
        } footer: {
            // Account sync is unconditional once signed in, which means signing
            // up *is* the moment the user agrees to it. There is no switch for
            // it afterwards, so this is the only place the app can honestly say
            // what having an account does — one plain sentence at the point of
            // decision, not a clause in a policy nobody opens.
            //
            // **The second sentence is load-bearing and was added when the
            // publish opt-in was removed.** A new account is public
            // (`profiles.is_private` defaults to false), so this is now the
            // only moment before the fact at which the app can say that other
            // people will be able to read the ranking. Saying it here is what
            // makes the default defensible; deleting it would leave a silent
            // publication.
            //
            // Deliberately a footer and not part of the toggle's label: the
            // toggle is the Terms gate (Guideline 3.1.2), it is load-bearing on
            // its own, and folding a second claim into it would make agreeing to
            // one mean agreeing to both. See `docs/PART-IV-SYNC.md` §5.
            Text("Your rankings are saved to your account, so they follow you "
                 + "between devices. New accounts are public — anyone on Binged "
                 + "can see your ranking, and you can make yours private at any "
                 + "time in Settings.")
        }
    }

    // MARK: Behaviour

    private var canSubmit: Bool {
        guard !email.isEmpty, password.count >= AuthError.minimumPasswordLength else { return false }
        guard mode == .signUp else { return true }
        guard acceptedTerms else { return false }
        // A `.taken` result does not block submission: the availability probe is
        // advisory and the server's unique constraint is the real arbiter, so a
        // stale "taken" must not lock someone out of a handle that just freed up.
        if case .invalid = handleStatus { return false }
        return Handle.isValid(handle)
    }

    private func requestReset() async {
        resetRequested = await session.sendPasswordReset(email: email)
    }

    private func submit() async {
        switch mode {
        case .signIn:
            await session.signIn(email: email, password: password)
        case .signUp:
            await session.signUp(email: email, password: password, handle: handle)
        }
    }

    /// Debounced, and cancelled on every keystroke — otherwise typing a handle
    /// fires one request per character.
    private func scheduleCheck(_ raw: String) {
        checkTask?.cancel()
        if let problem = Handle.validate(raw) {
            handleStatus = raw.isEmpty ? .idle : .invalid(problem.message)
            return
        }
        handleStatus = .checking
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let available = await session.isHandleAvailable(raw)
            guard !Task.isCancelled else { return }
            handleStatus = available ? .available : .taken
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Sign in") {
    SignInView().environment(SessionViewModel(service: MockAuthService(existingHandles: ["taken"])))
}

#Preview("Unavailable") {
    SignInView().environment(SessionViewModel(service: nil))
}
#endif
