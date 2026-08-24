//
//  MockAuthService.swift
//  WatchRank
//
//  Accounts without a server. What the test suite runs against, and what a
//  preview uses.
//
//  It enforces the same rules the real one does — handle validation, taken
//  handles, password length — so a test that passes here is testing the app's
//  behaviour rather than the stub's leniency.
//

import Foundation

// MARK: - MockAuthService

final class MockAuthService: AuthService, @unchecked Sendable {

    private let lock = NSLock()
    private var profiles: [String: UserProfile] = [:]      // handle -> profile
    private var passwords: [String: String] = [:]          // email -> password
    private var emails: [String: UUID] = [:]               // email -> user id
    private var signedIn: UserProfile?

    /// - Parameters:
    ///   - existingHandles: handles that exist before anyone signs up, so
    ///     "taken" can be exercised.
    ///   - signedInAs: a profile the service starts already signed in as, so a
    ///     fixture can come up past the sign-in screen. There is no password
    ///     for it — signing out and back in is not possible, which is the
    ///     honest shape of a session restored from a token rather than typed.
    init(existingHandles: [String] = [], signedInAs profile: UserProfile? = nil) {
        for handle in existingHandles {
            let normalized = Handle.normalize(handle)
            profiles[normalized] = UserProfile(
                id: UUID(), handle: normalized, displayName: nil, bio: nil,
                avatarURL: nil, isPrivate: false, createdAt: .now
            )
        }
        if let profile {
            profiles[Handle.normalize(profile.handle)] = profile
            signedIn = profile
        }
    }

    func signUp(email: String, password: String, handle: String) async throws -> UserProfile {
        if let problem = Handle.validate(handle) { throw AuthError.invalidHandle(problem) }
        guard password.count >= AuthError.minimumPasswordLength else { throw AuthError.weakPassword }

        let normalized = Handle.normalize(handle)

        lock.lock()
        defer { lock.unlock() }

        guard emails[email] == nil else { throw AuthError.emailInUse }
        guard profiles[normalized] == nil else { throw AuthError.handleTaken(normalized) }

        let profile = UserProfile(
            id: UUID(), handle: normalized, displayName: nil, bio: nil,
            avatarURL: nil, isPrivate: false, createdAt: .now
        )
        profiles[normalized] = profile
        emails[email] = profile.id
        passwords[email] = password
        signedIn = profile
        return profile
    }

    func signIn(email: String, password: String) async throws -> UserProfile {
        lock.lock()
        defer { lock.unlock() }

        guard let stored = passwords[email], stored == password,
              let id = emails[email],
              let profile = profiles.values.first(where: { $0.id == id })
        else { throw AuthError.invalidCredentials }

        signedIn = profile
        return profile
    }

    func signOut() async {
        lock.lock(); signedIn = nil; lock.unlock()
    }

    func currentProfile() async throws -> UserProfile? {
        lock.lock(); defer { lock.unlock() }
        return signedIn
    }

    func isHandleAvailable(_ handle: String) async -> Bool {
        guard Handle.isValid(handle) else { return false }
        lock.lock(); defer { lock.unlock() }
        return profiles[Handle.normalize(handle)] == nil
    }

    func deleteAccount() async throws {
        lock.lock()
        defer { lock.unlock() }
        guard let profile = signedIn else { throw AuthError.invalidCredentials }
        profiles[profile.handle] = nil
        if let email = emails.first(where: { $0.value == profile.id })?.key {
            emails[email] = nil
            passwords[email] = nil
        }
        signedIn = nil
    }

    func updateProfile(_ profile: UserProfile) async throws -> UserProfile {
        let normalized = Handle.normalize(profile.handle)
        lock.lock()
        defer { lock.unlock() }

        if let existing = profiles[normalized], existing.id != profile.id {
            throw AuthError.handleTaken(normalized)
        }
        // Drop the old handle key if it changed, so the name is released.
        if let current = signedIn, current.handle != normalized {
            profiles[current.handle] = nil
        }
        var updated = profile
        updated.handle = normalized
        profiles[normalized] = updated
        signedIn = updated
        return updated
    }
}
