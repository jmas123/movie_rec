//
//  PendingHandleStore.swift
//  Binged
//
//  Remembers the handle somebody chose at sign-up when there was no session to
//  claim it with.
//
//  **The hole this fills.** `app.handle_new_user()` creates the profile row the
//  moment the `auth.users` row exists, with a generated placeholder handle,
//  because `profiles.handle` is NOT NULL and unique and cannot wait for the
//  client. The chosen handle is written over that placeholder by a PATCH — and
//  a PATCH needs a session. With email confirmation switched on, sign-up
//  returns no session, so the account is created and the handle the user picked
//  is simply dropped on the floor. They confirm by email, sign in, and are
//  `@u5f3a2b9c1d4e6f70a12` forever, since the handle is not editable.
//
//  Holding it here until the first sign-in closes that. It is deliberately not
//  a queue: only the most recent unconfirmed sign-up is kept, because that is
//  the only one the person in front of the device is waiting on, and an
//  unbounded list of email addresses in `UserDefaults` is not something to
//  accumulate for a convenience.
//
//  **On storage.** `UserDefaults` is a required-reason API and is already
//  declared in `PrivacyInfo.xcprivacy` under CA92.1 — accessible only to the
//  app itself. Adding a key under an already-declared reason needs no manifest
//  change. The record is cleared as soon as
//  it is used or superseded, so the address does not linger past the sign-in
//  it exists to serve.
//

import Foundation

// MARK: - PendingHandleStore

/// The seam, so a test does not have to reach into `UserDefaults`.
protocol PendingHandleStore: Sendable {
    /// Records that `handle` was chosen for `email` but could not be claimed.
    func record(handle: String, for email: String)
    /// The handle awaiting claim for `email`, if that is the pending sign-up.
    func pendingHandle(for email: String) -> String?
    /// Forgets the record — after a successful claim, or after one that failed
    /// in a way retrying will not fix.
    func clear()
}

// MARK: - UserDefaultsPendingHandleStore

final class UserDefaultsPendingHandleStore: PendingHandleStore, @unchecked Sendable {

    private let defaults: UserDefaults
    private let lock = NSLock()

    /// One key holding one record. See the note above on why this is not a list.
    private static let key = "com.binged.pendingHandleClaim"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(handle: String, for email: String) {
        let record = Record(email: Self.normalize(email), handle: Handle.normalize(handle))
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func pendingHandle(for email: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.email == Self.normalize(email)
        else { return nil }
        return record.handle
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.key)
    }

    /// Email comparison is case- and whitespace-insensitive: the address typed
    /// at sign-up and the one typed at sign-in are the same account whatever
    /// the shift key was doing.
    private static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct Record: Codable {
        let email: String
        let handle: String
    }
}

// MARK: - MockPendingHandleStore

final class MockPendingHandleStore: PendingHandleStore, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: (email: String, handle: String)?

    init(email: String? = nil, handle: String? = nil) {
        if let email, let handle {
            stored = (email.lowercased(), Handle.normalize(handle))
        }
    }

    /// What the store holds, for a test that wants to assert it was cleared.
    var current: (email: String, handle: String)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(handle: String, for email: String) {
        lock.lock()
        defer { lock.unlock() }
        stored = (email.lowercased(), Handle.normalize(handle))
    }

    func pendingHandle(for email: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let stored, stored.email == email.lowercased() else { return nil }
        return stored.handle
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}
