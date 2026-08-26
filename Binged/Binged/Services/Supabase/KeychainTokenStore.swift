//
//  KeychainTokenStore.swift
//  Binged
//
//  Where the session lives between launches.
//
//  The Keychain, never `UserDefaults`: a refresh token is a long-lived bearer
//  credential, and `UserDefaults` is a plist in the app container that any
//  backup, sync, or file-level compromise reads in the clear.
//

import Foundation
import Security

// MARK: - SupabaseSession

struct SupabaseSession: Codable, Equatable, Sendable {

    let accessToken: String
    let refreshToken: String
    /// Absolute expiry of the access token.
    let expiresAt: Date
    let userID: UUID

    /// Treated as expired slightly early, so a request is not sent with a token
    /// that dies in flight.
    func isExpired(now: Date = .now, leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}

// MARK: - TokenStore

/// The seam. Tests use an in-memory store; the app uses the Keychain.
protocol TokenStore: AnyObject, Sendable {
    func load() -> SupabaseSession?
    func save(_ session: SupabaseSession)
    func clear()
}

// MARK: - KeychainTokenStore

final class KeychainTokenStore: TokenStore, @unchecked Sendable {

    private let service: String
    private let account: String
    private let lock = NSLock()

    /// The default service was `com.watchrank.supabase` until 2026-08-26 — the
    /// brand two renames ago, and the same stale identifier the bundle id
    /// carried. Changing it orphans any token stored under the old name, so the
    /// next launch reads no session and the user signs in again. That is free
    /// today and would not have been after a TestFlight build: the same edit
    /// against shipped installs signs every tester out with no explanation.
    init(service: String = "com.trybinged.supabase", account: String = "session") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> SupabaseSession? {
        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }

        return try? JSONDecoder().decode(SupabaseSession.self, from: data)
    }

    func save(_ session: SupabaseSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }

        lock.lock()
        defer { lock.unlock() }

        // Delete-then-add rather than update: `SecItemUpdate` fails when nothing
        // is there, and branching on that is more code than simply replacing.
        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = data
        // Never synced to iCloud, and unreadable while the device is locked.
        // A social session is not worth a background-refresh convenience.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - InMemoryTokenStore

/// For tests and previews. Also what a signed-out build uses, so no code path
/// has to branch on "is there a Keychain".
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: SupabaseSession?

    init(session: SupabaseSession? = nil) { self.session = session }

    func load() -> SupabaseSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    func save(_ newSession: SupabaseSession) {
        lock.lock(); defer { lock.unlock() }
        session = newSession
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        session = nil
    }
}
