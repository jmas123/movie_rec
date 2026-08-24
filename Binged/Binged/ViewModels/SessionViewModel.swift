//
//  SessionViewModel.swift
//  Binged
//
//  Who is signed in, if anyone.
//
//  Deliberately small and deliberately *optional* to everything else. The app
//  is fully usable signed out — search, mark watched, compare, rank, Profile,
//  Discover — and this view model gates the social surfaces only. If ranking a
//  film ever needs a session, Part III's third invariant is broken.
//

import Foundation
import Observation

// MARK: - SessionViewModel

@MainActor
@Observable
final class SessionViewModel {

    // MARK: State

    enum State: Equatable {
        /// No account, or signed out. The default, and a complete state.
        case signedOut
        case signingIn
        case signedIn(UserProfile)
        /// The build carries no Supabase credentials. Distinct from `signedOut`:
        /// there is nothing to sign in *to*, so the UI must offer explanation
        /// rather than a form that cannot work.
        case unavailable
    }

    private(set) var state: State
    private(set) var lastError: String?

    @ObservationIgnored private let service: AuthService?

    // MARK: Init

    init(service: AuthService?) {
        self.service = service
        state = service == nil ? .unavailable : .signedOut
    }

    // MARK: Derived

    var profile: UserProfile? {
        if case .signedIn(let profile) = state { return profile }
        return nil
    }

    var isSignedIn: Bool { profile != nil }

    /// Whether the social surfaces should appear at all.
    var isAvailable: Bool { state != .unavailable }

    var isBusy: Bool { state == .signingIn }

    // MARK: Restore

    /// Picks up an existing session at launch.
    ///
    /// Failure is silent and lands on `signedOut`: a expired token at launch is
    /// routine, and greeting someone with an error before they have done
    /// anything is not useful.
    func restore() async {
        guard let service else { return }
        do {
            if let profile = try await service.currentProfile() {
                state = .signedIn(profile)
            } else {
                state = .signedOut
            }
        } catch {
            state = .signedOut
        }
    }

    // MARK: Actions

    func signUp(email: String, password: String, handle: String) async {
        await run { try await $0.signUp(email: email, password: password, handle: handle) }
    }

    func signIn(email: String, password: String) async {
        await run { try await $0.signIn(email: email, password: password) }
    }

    func updateProfile(_ profile: UserProfile) async {
        await run { try await $0.updateProfile(profile) }
    }

    /// Asks for a reset email. Reports success even for an address with no
    /// account — see `AuthService.sendPasswordReset`.
    ///
    /// - Returns: whether the request was accepted, so the form can show a
    ///   confirmation rather than guessing.
    @discardableResult
    func sendPasswordReset(email: String) async -> Bool {
        guard let service else { return false }
        lastError = nil
        do {
            try await service.sendPasswordReset(email: email)
            return true
        } catch {
            lastError = ErrorMessage.text(for: error)
            return false
        }
    }

    func signOut() async {
        guard let service else { return }
        await service.signOut()
        state = .signedOut
        lastError = nil
    }

    func isHandleAvailable(_ handle: String) async -> Bool {
        guard let service else { return false }
        return await service.isHandleAvailable(handle)
    }

    /// Deletes the account. The local library is untouched — see
    /// `AuthService.deleteAccount`.
    func deleteAccount() async {
        guard let service else { return }
        lastError = nil
        do {
            try await service.deleteAccount()
            state = .signedOut
        } catch let error as AuthError {
            lastError = error.description
        } catch {
            lastError = ErrorMessage.text(for: error)
        }
    }

    func clearError() { lastError = nil }

    // MARK: Plumbing

    private func run(_ work: (AuthService) async throws -> UserProfile) async {
        guard let service else {
            state = .unavailable
            return
        }
        lastError = nil
        let previous = state
        state = .signingIn
        do {
            state = .signedIn(try await work(service))
        } catch let error as AuthError {
            lastError = error.description
            state = previous == .signingIn ? .signedOut : previous
        } catch {
            lastError = ErrorMessage.text(for: error)
            state = previous == .signingIn ? .signedOut : previous
        }
    }
}
