//
//  ProfileCache.swift
//  Binged
//
//  The last profile the server handed us, kept so a launch with no signal is
//  not mistaken for a sign-out.
//
//  `SessionViewModel` needs a `UserProfile` to be in its `signedIn` state, and
//  the only source of one is a network call. So an offline launch used to land
//  on `signedOut` even though the Keychain still held a perfectly good session:
//  the credential was there, the identity to show alongside it was not. To the
//  user that is indistinguishable from being signed out, and it is the shape
//  most "my session expired" reports actually have.
//
//  This is a *cache*, never an authority. It says who was signed in last, not
//  whether anyone is signed in now — `AuthService.hasStoredSession` answers
//  that, and the two are always consulted together.
//

import Foundation

// MARK: - ProfileCache

/// The seam. The app persists; tests keep it in memory.
protocol ProfileCache: AnyObject, Sendable {
    func load() -> UserProfile?
    func save(_ profile: UserProfile)
    func clear()
}

// MARK: - UserDefaultsProfileCache

/// `UserDefaults`, deliberately — unlike the session tokens next door, a
/// profile is not a credential. It is the user's own handle and display name,
/// which the app already draws on half its screens.
final class UserDefaultsProfileCache: ProfileCache, @unchecked Sendable {

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "binged.session.profile") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> UserProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(UserProfile.self, from: data)
    }

    func save(_ profile: UserProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

// MARK: - InMemoryProfileCache

/// For tests and previews.
final class InMemoryProfileCache: ProfileCache, @unchecked Sendable {

    private let lock = NSLock()
    private var profile: UserProfile?

    init(profile: UserProfile? = nil) { self.profile = profile }

    func load() -> UserProfile? {
        lock.lock(); defer { lock.unlock() }
        return profile
    }

    func save(_ newProfile: UserProfile) {
        lock.lock(); defer { lock.unlock() }
        profile = newProfile
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        profile = nil
    }
}
