//
//  AccountControlsTests.swift
//  BingedTests
//
//  The account controls that existed as service methods with no caller:
//  editing a profile, going private, resetting a password, and undoing a block.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Helpers

private func person(_ handle: String, isPrivate: Bool = false) -> UserProfile {
    UserProfile(
        id: UUID(), handle: handle, displayName: handle.capitalized, bio: nil,
        avatarURL: nil, isPrivate: isPrivate, createdAt: .now
    )
}

// MARK: - Profile editing

@Suite("Profile editing")
@MainActor
struct ProfileEditingTests {

    @Test("Going private is persisted, so the request inbox can ever fill")
    func privacyTogglePersists() async throws {
        // `isPrivate` had a column, a policy and no control. Without this the
        // follow-request queue is a screen that can only ever be empty.
        let service = MockAuthService()
        let session = SessionViewModel(service: service)
        _ = await session.signUp(email: "a@b.co", password: "password123", handle: "alex")
        var profile = try #require(session.profile)
        #expect(!profile.isPrivate)

        profile.isPrivate = true
        await session.updateProfile(profile)

        #expect(session.profile?.isPrivate == true)
        #expect(session.lastError == nil)
    }

    @Test("A display name round-trips, and clearing it falls back to the handle")
    func displayNameRoundTrips() async throws {
        let service = MockAuthService()
        let session = SessionViewModel(service: service)
        _ = await session.signUp(email: "a@b.co", password: "password123", handle: "alex")
        var profile = try #require(session.profile)

        profile.displayName = "Alex Doe"
        await session.updateProfile(profile)
        #expect(session.profile?.name == "Alex Doe")

        // nil, not "" — `UserProfile.name` only falls back on nil.
        profile = try #require(session.profile)
        profile.displayName = nil
        await session.updateProfile(profile)
        #expect(session.profile?.name == "@alex")
    }
}

// MARK: - Password reset

@Suite("Password reset")
@MainActor
struct PasswordResetTests {

    @Test("A reset request is sent for the address given")
    func resetIsSent() async {
        let service = MockAuthService()
        let session = SessionViewModel(service: service)

        let accepted = await session.sendPasswordReset(email: "someone@example.com")

        #expect(accepted)
        #expect(service.passwordResetsSent == ["someone@example.com"])
        #expect(session.lastError == nil)
    }

    @Test("An unknown address is accepted rather than denied")
    func unknownAddressDoesNotLeak() async {
        // Reporting "no such user" would make this form an oracle for which
        // emails are registered.
        let service = MockAuthService(existingHandles: [])
        let session = SessionViewModel(service: service)

        let accepted = await session.sendPasswordReset(email: "nobody@example.com")

        #expect(accepted)
        #expect(session.lastError == nil)
    }

    @Test("A build with no server cannot pretend it sent anything")
    func noServiceReportsFailure() async {
        let session = SessionViewModel(service: nil)
        let accepted = await session.sendPasswordReset(email: "a@b.co")
        #expect(!accepted)
    }
}

// MARK: - Unblocking

@Suite("Unblocking")
@MainActor
struct UnblockingTests {

    @Test("A blocked account is listed, so the block can be undone")
    func blockedAccountsAreListed() async throws {
        // Before `blockedAccounts()` existed this was impossible: blocking is
        // mutual invisibility, so `profiles_select` hides a blocked profile
        // from the blocker too and a client-side join returns bare ids.
        let sam = person("sam")
        let service = MockSocialService(people: [sam])

        try await service.block(sam.id)
        let blocked = try await service.blockedAccounts()

        #expect(blocked.map(\.id) == [sam.id])
    }

    @Test("Unblocking removes them from the list")
    func unblockRemoves() async throws {
        let sam = person("sam")
        let service = MockSocialService(people: [sam])
        try await service.block(sam.id)

        try await service.unblock(sam.id)

        let blocked = try await service.blockedAccounts()
        #expect(blocked.isEmpty)
    }

    @Test("Nobody blocked is an empty list, not an error")
    func nobodyBlocked() async throws {
        let service = MockSocialService(people: [person("sam")])
        let blocked = try await service.blockedAccounts()
        #expect(blocked.isEmpty)
    }
}
