//
//  PublishConsent.swift
//  Binged
//
//  Whether this account has agreed to publish its ranking.
//
//  **Signing in is not consent.** Somebody who creates an account to follow a
//  friend has said nothing about the two hundred titles already on their phone,
//  and uploading them because a session now exists would be taking something
//  they never offered. So the outbox accrues from the first ranking and drains
//  for nobody until this says yes.
//
//  **Keyed by user id, not by device.** A second account on the same phone is a
//  different person making a different decision — a shared handset would
//  otherwise inherit whatever the previous account chose, which is exactly the
//  case where getting it wrong publishes somebody's library to strangers.
//
//  Stored in `UserDefaults` rather than the keychain: this is a preference, not
//  a credential. The server is the authority on what is actually published, and
//  a wiped answer means the app asks again — which is the safe direction to
//  fail in.
//

import Foundation

// MARK: - PublishConsent

/// `@unchecked` because `UserDefaults` is not marked `Sendable` even though it
/// is documented as thread-safe. The alternative — dropping the conformance —
/// would push the problem into every closure that captures the store.
struct PublishConsent: @unchecked Sendable {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Keys

    private static let prefix = "publishConsent."

    private func key(for userID: UUID) -> String { Self.prefix + userID.uuidString }

    // MARK: Reading

    /// `true` granted, `false` refused, `nil` never asked.
    ///
    /// The three cases are distinct and the third is not a `false`: never-asked
    /// means the app owes the user a question, and refused means it does not.
    /// Collapsing them would either re-ask somebody who already said no, or
    /// treat silence as an answer.
    func decision(for userID: UUID) -> Bool? {
        defaults.object(forKey: key(for: userID)) as? Bool
    }

    func isGranted(for userID: UUID) -> Bool { decision(for: userID) == true }

    // MARK: Writing

    func record(_ granted: Bool, for userID: UUID) {
        defaults.set(granted, forKey: key(for: userID))
    }

    /// Forgets the answer, so the next sign-in asks again. What account
    /// deletion owes: the account is gone, and its answer should not outlive it
    /// for whoever signs in next.
    func forget(for userID: UUID) {
        defaults.removeObject(forKey: key(for: userID))
    }

    // MARK: Testing

    /// A store backed by a throwaway suite, so a test never reads or writes the
    /// user's real preferences.
    static func inMemory(granted: Bool? = nil, for userID: UUID = UUID()) -> PublishConsent {
        let suite = UserDefaults(suiteName: "PublishConsent.test.\(UUID().uuidString)")
            ?? .standard
        let store = PublishConsent(defaults: suite)
        if let granted { store.record(granted, for: userID) }
        return store
    }
}
