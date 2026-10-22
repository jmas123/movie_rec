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

    /// True when `state` is `signedIn` on a *cached* profile because the
    /// server could not be reached. The session is real; the details on screen
    /// may be a launch or two old, so `refreshProfileIfStale` is worth calling
    /// when the app comes back to the foreground or the network returns.
    private(set) var isProfileStale = false

    @ObservationIgnored private let service: AuthService?
    @ObservationIgnored private let profiles: ProfileCache?

    // MARK: Init

    /// - Parameter profiles: where the last known profile is kept, so a launch
    ///   with no signal can stay signed in. `nil` disables that — which is what
    ///   most tests want, and what a build with no accounts gets anyway.
    init(service: AuthService?, profiles: ProfileCache? = nil) {
        self.service = service
        self.profiles = profiles
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
    /// Failure is silent: greeting someone with an error before they have done
    /// anything is not useful. What failure must *not* be is a sign-out.
    ///
    /// **A thrown error is not evidence of an expired session.** This used to
    /// land on `signedOut` for any failure at all, which meant a launch on a
    /// train, behind a captive portal, or during a five-second Supabase blip
    /// presented as "you are signed out" — with the credential sitting intact
    /// in the Keychain the whole time. Signing in again worked, which is
    /// exactly why it reads as a session that keeps expiring.
    ///
    /// So the two questions are asked separately: *is there still a
    /// credential* (`hasStoredSession`, local and offline-safe) and *who does
    /// it belong to* (`currentProfile`, a network call). Only the first may end
    /// a session. When it says yes and the second could not answer, the cached
    /// profile carries the UI until it can.
    func restore() async {
        guard let service else { return }
        do {
            if let profile = try await service.currentProfile() {
                adopt(profile)
            } else {
                // An authoritative "nobody is signed in".
                signedOutLocally()
            }
        } catch {
            guard await service.hasStoredSession, let cached = profiles?.load() else {
                // The credential is gone — the client cleared it because the
                // server rejected it — or there was never one to keep.
                signedOutLocally()
                return
            }
            state = .signedIn(cached)
            isProfileStale = true
        }
    }

    /// Re-fetches a profile that `restore()` had to take from the cache.
    ///
    /// Cheap and safe to call on every foreground and every return of the
    /// network: it does nothing unless a stale profile is actually on screen,
    /// and a failure leaves the session exactly where it was.
    func refreshProfileIfStale() async {
        guard isProfileStale, let service, isSignedIn else { return }
        guard let profile = try? await service.currentProfile() else { return }
        adopt(profile)
    }

    /// Records a profile the server has just confirmed.
    private func adopt(_ profile: UserProfile) {
        state = .signedIn(profile)
        isProfileStale = false
        profiles?.save(profile)
    }

    /// Ends the session locally, cache included, so a later offline launch
    /// cannot resurrect a profile nobody is signed in as.
    private func signedOutLocally() {
        state = .signedOut
        isProfileStale = false
        profiles?.clear()
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
        signedOutLocally()
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
            signedOutLocally()
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
            adopt(try await work(service))
        } catch let error as AuthError {
            lastError = error.description
            state = previous == .signingIn ? .signedOut : previous
        } catch {
            lastError = ErrorMessage.text(for: error)
            state = previous == .signingIn ? .signedOut : previous
        }
    }
}
