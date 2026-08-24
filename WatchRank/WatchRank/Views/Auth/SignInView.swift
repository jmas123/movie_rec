//
//  SignInView.swift
//  WatchRank
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

            if let error = session.lastError {
                Section {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
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

                switch handleStatus {
                case .checking:  ProgressView().controlSize(.small)
                case .available: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .taken:     Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                default:         EmptyView()
                }
            }

            if case .invalid(let message) = handleStatus {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if handleStatus == .taken {
                Text("That handle is taken.").font(.caption).foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Behaviour

    private var canSubmit: Bool {
        guard !email.isEmpty, password.count >= AuthError.minimumPasswordLength else { return false }
        guard mode == .signUp else { return true }
        // A `.taken` result does not block submission: the availability probe is
        // advisory and the server's unique constraint is the real arbiter, so a
        // stale "taken" must not lock someone out of a handle that just freed up.
        if case .invalid = handleStatus { return false }
        return Handle.isValid(handle)
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
