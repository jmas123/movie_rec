//
//  HandleClaimTests.swift
//  BingedTests
//
//  The handle that survives email confirmation.
//
//  `GAP-AUDIT.md` §2 #14 item 1: `profiles.handle` is NOT NULL and unique, so
//  `app.handle_new_user()` writes a generated placeholder the instant the
//  account row exists, and the chosen handle is a later PATCH — which needs a
//  session. With email confirmation switched on, sign-up returns no session, so
//  the handle a user picked was simply discarded and they arrived permanently
//  named `u5f3a2b9c1d4e6f70a12`, since handles are otherwise not editable.
//

import Foundation
import Testing
@testable import Binged

// MARK: - The placeholder

@Suite("Handle placeholders")
struct HandlePlaceholderTests {

    /// Mirrors `app.handle_new_user()`:
    /// `'u' || substr(replace(new.id::text, '-', ''), 1, 19)`.
    @Test("The placeholder matches the trigger's construction exactly")
    func matchesTheTrigger() throws {
        let id = try #require(UUID(uuidString: "5F3A2B9C-1D4E-6F70-A123-456789ABCDEF"))
        #expect(Handle.placeholder(for: id) == "u5f3a2b9c1d4e6f70a12")
    }

    /// It has to pass the app's own validator, or the escape hatch in
    /// `EditProfileView` would be offered against a handle the form rejects.
    @Test("The placeholder is a valid handle, exactly at the length limit")
    func placeholderIsValid() {
        let handle = Handle.placeholder(for: UUID())
        #expect(handle.count == Handle.maximumLength)
        #expect(Handle.isValid(handle))
    }

    /// The reason `isPlaceholder` takes a user id instead of matching a shape:
    /// `u` + 19 hex characters is a handle a person could legitimately claim,
    /// and a regex would offer to overwrite it.
    @Test("A placeholder-shaped handle belonging to somebody else is not a placeholder")
    func noFalsePositives() throws {
        let mine = try #require(UUID(uuidString: "5F3A2B9C-1D4E-6F70-A123-456789ABCDEF"))
        let theirs = UUID()

        #expect(Handle.isPlaceholder(Handle.placeholder(for: mine), for: mine))
        #expect(!Handle.isPlaceholder(Handle.placeholder(for: mine), for: theirs))
        #expect(!Handle.isPlaceholder("u1234567890123456789", for: mine))
    }

    @Test("A real handle is never mistaken for a placeholder")
    func realHandlesAreNot() {
        let id = UUID()
        #expect(!Handle.isPlaceholder("alex", for: id))
        #expect(!Handle.isPlaceholder("cinephile_99", for: id))
    }

    @Test("Comparison is case-insensitive, like handles themselves")
    func normalizes() {
        let id = UUID()
        #expect(Handle.isPlaceholder(Handle.placeholder(for: id).uppercased(), for: id))
    }
}

// MARK: - The store

@Suite("PendingHandleStore")
struct PendingHandleStoreTests {

    /// A real `UserDefaults` suite rather than the mock, because the point of
    /// this type is that the handle survives the app being closed while the
    /// user goes to their inbox.
    private func makeStore() throws -> (UserDefaultsPendingHandleStore, UserDefaults, String) {
        let name = "PendingHandleStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (UserDefaultsPendingHandleStore(defaults: defaults), defaults, name)
    }

    @Test("A parked handle comes back for the address it was parked under")
    func roundTrip() throws {
        let (store, defaults, name) = try makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        store.record(handle: "cinephile", for: "sam@example.com")
        #expect(store.pendingHandle(for: "sam@example.com") == "cinephile")
    }

    /// Otherwise a second sign-up on the same device could claim the first
    /// person's handle onto the second person's account.
    @Test("A parked handle is not returned for a different address")
    func keyedByAddress() throws {
        let (store, defaults, name) = try makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        store.record(handle: "cinephile", for: "sam@example.com")
        #expect(store.pendingHandle(for: "alex@example.com") == nil)
    }

    @Test("Address matching ignores case and surrounding whitespace")
    func addressNormalization() throws {
        let (store, defaults, name) = try makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        store.record(handle: "Cinephile", for: "  Sam@Example.com ")
        #expect(store.pendingHandle(for: "sam@example.com") == "cinephile")
    }

    /// One record, not a queue — the only sign-up anyone is waiting on is the
    /// most recent, and an unbounded list of email addresses in `UserDefaults`
    /// is not worth accumulating for a convenience.
    @Test("A second sign-up replaces the first rather than queueing behind it")
    func onlyTheLatest() throws {
        let (store, defaults, name) = try makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        store.record(handle: "first", for: "one@example.com")
        store.record(handle: "second", for: "two@example.com")

        #expect(store.pendingHandle(for: "one@example.com") == nil)
        #expect(store.pendingHandle(for: "two@example.com") == "second")
    }

    @Test("Clearing forgets the record")
    func clears() throws {
        let (store, defaults, name) = try makeStore()
        defer { defaults.removePersistentDomain(forName: name) }

        store.record(handle: "cinephile", for: "sam@example.com")
        store.clear()
        #expect(store.pendingHandle(for: "sam@example.com") == nil)
    }

    @Test("A store with nothing in it returns nothing")
    func emptyStore() throws {
        let (store, defaults, name) = try makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(store.pendingHandle(for: "sam@example.com") == nil)
    }

    @Test("The record survives a new store over the same defaults")
    func survivesRelaunch() throws {
        let name = "PendingHandleStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        UserDefaultsPendingHandleStore(defaults: defaults)
            .record(handle: "cinephile", for: "sam@example.com")

        // A different instance, as after a relaunch: the user closed the app,
        // went to their inbox, clicked the link and came back.
        let reopened = UserDefaultsPendingHandleStore(defaults: defaults)
        #expect(reopened.pendingHandle(for: "sam@example.com") == "cinephile")
    }
}
