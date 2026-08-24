//
//  AuthService.swift
//  Binged
//
//  The seam between the app and whoever is holding the accounts.
//
//  A protocol for the same reason `MediaService` is one: the app must be fully
//  usable and fully testable without a server. `MockAuthService` is what the
//  suite runs against, and an unconfigured build gets no auth service at all
//  rather than one that fails on every call.
//

import Foundation

// MARK: - AuthService

protocol AuthService: Sendable {

    /// Creates an account and returns the profile it belongs to.
    ///
    /// The handle is claimed as part of sign-up rather than after it: an account
    /// with no handle is a state every later screen would have to handle, and
    /// there is no reason to create it.
    func signUp(email: String, password: String, handle: String) async throws -> UserProfile

    func signIn(email: String, password: String) async throws -> UserProfile

    /// Clears the local session. Deliberately does not fail on a network error —
    /// a user asking to sign out must always succeed locally.
    func signOut() async

    /// The signed-in user's profile, or `nil` when signed out.
    func currentProfile() async throws -> UserProfile?

    /// Best-effort availability check for instant feedback. The unique
    /// constraint is the real arbiter — see `Handle`.
    func isHandleAvailable(_ handle: String) async -> Bool

    func updateProfile(_ profile: UserProfile) async throws -> UserProfile

    /// Sends a password-reset email.
    ///
    /// Returns normally whether or not the address has an account. Reporting
    /// "no such user" would turn this form into an oracle for which emails are
    /// registered, which is exactly the enumeration Supabase's own endpoint
    /// declines to provide.
    func sendPasswordReset(email: String) async throws

    /// Permanently deletes the account and every server row belonging to it.
    ///
    /// **A button, not an email address** — App Store guideline 5.1.1(v). And
    /// deliberately *only* the server: the local library is the user's own data
    /// and survives, usable signed out. Wiping it would be a second, unasked-for
    /// deletion of something they never published.
    func deleteAccount() async throws
}

// MARK: - AuthError

enum AuthError: Error, Equatable, CustomStringConvertible {
    case handleTaken(String)
    case invalidHandle(Handle.Problem)
    case invalidCredentials
    case emailInUse
    case weakPassword
    case notConfigured

    /// The project requires email confirmation, so sign-up produced an account
    /// but no session. Not a failure — the user has to go and click a link.
    case emailConfirmationRequired

    case underlying(String)

    var description: String {
        switch self {
        case .handleTaken(let handle):    return "@\(handle) is already taken."
        case .invalidHandle(let problem): return problem.message
        case .invalidCredentials:         return "That email and password do not match."
        case .emailInUse:                 return "There is already an account with that email."
        case .weakPassword:               return "Passwords need at least 8 characters."
        case .notConfigured:              return "Accounts are not available in this build."
        case .emailConfirmationRequired:
            return "Check your email to confirm your account, then sign in."
        case .underlying(let message):    return message
        }
    }

    static let minimumPasswordLength = 8
}
