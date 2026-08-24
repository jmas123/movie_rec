//
//  AuthServiceTests.swift
//  BingedTests
//
//  Accounts, handles, and the rule that matters most in Part III: **the app is
//  whole without any of this.**
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - Handles

@Suite("Handle")
struct HandleTests {

    @Test("Handles are case-insensitive and stored lowercase")
    func normalization() {
        #expect(Handle.normalize("  JudeE  ") == "judee")
        #expect(Handle.normalize("ALLCAPS") == "allcaps")
    }

    @Test("Length and character rules")
    func validation() {
        #expect(Handle.validate("ab") == .tooShort)
        #expect(Handle.validate(String(repeating: "a", count: Handle.maximumLength + 1)) == .tooLong)
        // The limit is the database's, not a preference: profiles_handle_format
        // is `^[a-z0-9_]{3,20}$`.
        #expect(Handle.maximumLength == 20)
        #expect(Handle.validate(String(repeating: "a", count: Handle.maximumLength)) == nil)
        #expect(Handle.validate("has space") == .invalidCharacters)
        #expect(Handle.validate("has-dash") == .invalidCharacters)
        #expect(Handle.validate("emoji😀") == .invalidCharacters)
        #expect(Handle.validate("good_one1") == nil)
    }

    @Test("Reserved handles cannot be claimed")
    func reservedHandles() {
        // These would collide with routes or let someone impersonate the app.
        #expect(Handle.validate("admin") == .reserved)
        #expect(Handle.validate("Binged") == .reserved)
        // The former product name stays reserved for as long as the database
        // reserves it. Freeing it would let someone claim the handle the app
        // used to answer to, which is an impersonation surface rather than a
        // tidiness question — and the constraint that actually enforces it is in an
        // applied migration that cannot be edited.
        #expect(Handle.validate("watchrank") == .reserved)
        #expect(Handle.validate("settings") == .reserved)
    }

    @Test("Every problem has copy a user could act on")
    func problemsHaveMessages() {
        for problem in [Handle.Problem.tooShort, .tooLong, .invalidCharacters, .reserved] {
            #expect(!problem.message.isEmpty)
        }
    }
}

// MARK: - Auth service contract

/// Run against every implementation, so the mock cannot be more permissive than
/// the real thing — which would make every test above it meaningless.
@Suite("AuthService contract")
struct AuthServiceContractTests {

    @Test("Sign up claims a handle and signs the user in")
    func signUpSucceeds() async throws {
        let service = MockAuthService()
        let profile = try await service.signUp(
            email: "a@b.test", password: "longenough", handle: "Newcomer"
        )

        #expect(profile.handle == "newcomer", "handle should be normalised")
        #expect(try await service.currentProfile()?.id == profile.id)
    }

    @Test("A taken handle is refused")
    func takenHandle() async {
        let service = MockAuthService(existingHandles: ["taken"])

        await #expect(throws: AuthError.handleTaken("taken")) {
            _ = try await service.signUp(email: "a@b.test", password: "longenough", handle: "TAKEN")
        }
        #expect(await service.isHandleAvailable("taken") == false)
        #expect(await service.isHandleAvailable("free") == true)
    }

    @Test("An invalid handle never reaches the server")
    func invalidHandleRejectedLocally() async {
        let service = MockAuthService()
        await #expect(throws: AuthError.invalidHandle(.tooShort)) {
            _ = try await service.signUp(email: "a@b.test", password: "longenough", handle: "ab")
        }
    }

    @Test("Short passwords are refused")
    func weakPassword() async {
        let service = MockAuthService()
        await #expect(throws: AuthError.weakPassword) {
            _ = try await service.signUp(email: "a@b.test", password: "short", handle: "valid_one")
        }
    }

    @Test("A duplicate email is refused")
    func duplicateEmail() async throws {
        let service = MockAuthService()
        _ = try await service.signUp(email: "a@b.test", password: "longenough", handle: "first")

        await #expect(throws: AuthError.emailInUse) {
            _ = try await service.signUp(email: "a@b.test", password: "longenough", handle: "second")
        }
    }

    @Test("Sign in requires the right password, and sign out clears the session")
    func signInAndOut() async throws {
        let service = MockAuthService()
        _ = try await service.signUp(email: "a@b.test", password: "longenough", handle: "someone")
        await service.signOut()
        #expect(try await service.currentProfile() == nil)

        await #expect(throws: AuthError.invalidCredentials) {
            _ = try await service.signIn(email: "a@b.test", password: "wrong")
        }

        let profile = try await service.signIn(email: "a@b.test", password: "longenough")
        #expect(profile.handle == "someone")
    }

    @Test("An availability probe never blocks an invalid handle from being reported")
    func availabilityRejectsInvalid() async {
        let service = MockAuthService()
        #expect(await service.isHandleAvailable("no") == false)
        #expect(await service.isHandleAvailable("has space") == false)
    }
}

// MARK: - Session view model

@Suite("SessionViewModel")
@MainActor
struct SessionViewModelTests {

    @Test("A build with no auth service reports itself unavailable")
    func unavailableWithoutService() async {
        // Distinct from signed out: there is nothing to sign in *to*, so the UI
        // must explain rather than offer a form that cannot work.
        let session = SessionViewModel(service: nil)

        #expect(session.state == .unavailable)
        #expect(!session.isAvailable)
        #expect(!session.isSignedIn)

        await session.signIn(email: "a@b.test", password: "longenough")
        #expect(session.state == .unavailable, "an unavailable build tried to sign in")
    }

    @Test("Sign up moves to signed in and exposes the profile")
    func signUpFlow() async {
        let session = SessionViewModel(service: MockAuthService())
        await session.signUp(email: "a@b.test", password: "longenough", handle: "newbie")

        #expect(session.isSignedIn)
        #expect(session.profile?.handle == "newbie")
        #expect(session.lastError == nil)
    }

    @Test("A failure surfaces a message and leaves the user signed out")
    func failureIsRecoverable() async {
        let session = SessionViewModel(service: MockAuthService(existingHandles: ["taken"]))
        await session.signUp(email: "a@b.test", password: "longenough", handle: "taken")

        #expect(!session.isSignedIn)
        #expect(session.state == .signedOut, "a failed sign-up left the UI stuck")
        #expect(session.lastError?.contains("taken") == true)

        session.clearError()
        #expect(session.lastError == nil)
    }

    @Test("Sign out returns to signed out and clears any error")
    func signOutResets() async {
        let session = SessionViewModel(service: MockAuthService())
        await session.signUp(email: "a@b.test", password: "longenough", handle: "someone")
        await session.signOut()

        #expect(session.state == .signedOut)
        #expect(session.profile == nil)
    }

    @Test("Restoring at launch with no session lands signed out, not in an error")
    func restoreIsQuiet() async {
        // An expired token at launch is routine. Greeting someone with an error
        // before they have done anything is not useful.
        let session = SessionViewModel(service: MockAuthService())
        await session.restore()

        #expect(session.state == .signedOut)
        #expect(session.lastError == nil)
    }
}

// MARK: - The invariant

@Suite("The app is whole signed out")
@MainActor
struct SignedOutInvariantTests {

    @Test("Ranking a film end to end needs no session at all")
    func rankingNeedsNoAccount() throws {
        // Part III's third invariant, asserted rather than assumed. If this
        // fails, the social layer has reached somewhere it must never reach.
        let library = try makeLibrary()
        let session = SessionViewModel(service: nil)
        #expect(!session.isSignedIn)

        let first = MediaItem(title: "First", year: 2020, type: .movie)
        library.markWatched(first, sentiment: .liked)
        library.finalizeRanking(for: first)

        let second = MediaItem(title: "Second", year: 2021, type: .movie)
        library.markWatched(second, sentiment: .liked)
        driveSessionPreferringNew(vm: library)
        library.finalizeRanking(for: second)

        let bucket = library.bucket(for: .liked, type: .movie)
        #expect(bucket.count == 2)
        #expect(bucket.first?.title == "Second")
        #expect(bucket.allSatisfy { $0.score != nil })
    }

    @Test("Recommendations need no session either")
    func discoverNeedsNoAccount() async throws {
        let library = try makeRankedLibrary(movies: 20, shows: 6)
        let builder = CandidatePoolBuilder(source: makeFullStubSource(), cache: makeDisabledCache())
        await builder.refresh()
        let vm = RecommendationViewModel(library: library, poolBuilder: builder)

        let result = await vm.recommendations(type: .movie, mood: .crime)
        #expect(result.isReady)
    }

    @Test("Taste analysis needs no session either")
    func tasteNeedsNoAccount() throws {
        let library = try makeRankedLibrary(movies: 20, shows: 6)
        let watched = library.allWatched
        let analysis = TasteAnalysis(
            profile: RecommendationEngine().buildProfile(from: watched), watched: watched
        )
        #expect(analysis.hasEnoughLibrary)
    }
}
