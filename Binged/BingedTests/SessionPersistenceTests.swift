//
//  SessionPersistenceTests.swift
//  BingedTests
//
//  Staying signed in.
//
//  Every case here is one a user reads as "my session expired": the app was
//  opened on a bad connection, or a refresh went out while the server was
//  unwell, and the account was gone afterwards. None of them involved an
//  expired credential — the client threw the session away on the strength of a
//  network failure, which is the one thing that says nothing about a token.
//
//  So the rule these tests hold: **only the server may end a session.** A 401
//  from the token endpoint ends it. A timeout, a 500, a 502 from a proxy, an
//  unparseable body — none of them do.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Refresh failures

@Suite("Session survives a bad network")
struct SessionSurvivalTests {

    private var restURL: URL { makeSupabaseConfiguration().rest("profiles") }

    @Test("A refresh that never reaches the server keeps the session")
    func transportFailureKeepsSession() async {
        // Offline, DNS, captive portal, timeout. The refresh token is fine; the
        // network is not. Clearing the Keychain here signed people out for
        // opening the app in a lift.
        let client = makeSupabaseClient(session: makeSession(expiresIn: -10)) { request in
            request.url?.path.contains("/auth/v1/token") == true
                ? .transportFailure
                : .ok(SupabaseFixtures.emptyArray)
        }

        await #expect(throws: (any Error).self) {
            let _: [String] = try await client.send(.init(url: restURL))
        }
        #expect(await client.isSignedIn, "a network failure ended the session")
        #expect(await client.currentSession?.refreshToken == "refresh-1")
    }

    @Test("A server error during refresh keeps the session")
    func serverErrorKeepsSession() async {
        // 500, 502, 429 — Supabase having a minute. A token is not spent
        // because the auth server could not answer for it.
        for status in [429, 500, 502, 503] {
            let client = makeSupabaseClient(session: makeSession(expiresIn: -10)) { request in
                request.url?.path.contains("/auth/v1/token") == true
                    ? .status(status, Data(#"{"message":"upstream"}"#.utf8))
                    : .ok(SupabaseFixtures.emptyArray)
            }

            await #expect(throws: (any Error).self) {
                let _: [String] = try await client.send(.init(url: restURL))
            }
            #expect(await client.isSignedIn, "\(status) ended the session")
        }
    }

    @Test("A refresh failure reports itself, not an expired session")
    func failureIsNotReportedAsUnauthorized() async {
        // The wording matters: `unauthorized` reaches the user as "your session
        // has expired. Sign in again." — an instruction to do the one thing
        // that is neither necessary nor possible while offline.
        let client = makeSupabaseClient(session: makeSession(expiresIn: -10)) { _ in
            .transportFailure
        }

        do {
            let _: [String] = try await client.send(.init(url: restURL))
            Issue.record("expected a failure")
        } catch SupabaseError.unauthorized {
            Issue.record("a transport failure surfaced as an expired session")
        } catch {
            #expect(error is SupabaseError)
        }
    }

    @Test("A rejected refresh token still ends the session")
    func rejectedRefreshTokenSignsOut() async {
        // The other half of the rule. GoTrue answers a spent or revoked refresh
        // token with 400 `invalid_grant` or 401, and that is authoritative.
        for status in [400, 401] {
            let client = makeSupabaseClient(session: makeSession(expiresIn: -10)) { _ in
                .status(status, SupabaseFixtures.unauthorized)
            }

            await #expect(throws: SupabaseError.unauthorized) {
                let _: [String] = try await client.send(.init(url: restURL))
            }
            #expect(await client.isSignedIn == false, "\(status) left a dead session in place")
        }
    }

    @Test("A failed refresh can be retried on the next request")
    func refreshRetriesAfterAFailure() async throws {
        // The point of keeping the session: the very next attempt works. The
        // single-flight guard must not latch a failure either.
        let counter = CallCounter()
        let offline = OnceOffline()

        let client = makeSupabaseClient(session: makeSession(expiresIn: -10)) { request in
            counter.record(request)
            guard request.url?.path.contains("/auth/v1/token") == true else {
                return .ok(SupabaseFixtures.emptyArray)
            }
            return offline.take() ? .transportFailure : .ok(SupabaseFixtures.tokenResponse())
        }

        await #expect(throws: (any Error).self) {
            let _: [String] = try await client.send(.init(url: restURL))
        }
        let rows: [String] = try await client.send(.init(url: restURL))

        #expect(rows.isEmpty)
        #expect(counter.count("/auth/v1/token") == 2)
        #expect(await client.currentSession?.accessToken == "access-2")
    }
}

// MARK: - Proactive refresh

@Suite("Expiry is anticipated, not discovered")
struct ProactiveRefreshTests {

    private var restURL: URL { makeSupabaseConfiguration().rest("profiles") }

    @Test("An expired access token is refreshed before the request goes out")
    func expiredTokenRefreshesFirst() async throws {
        let counter = CallCounter()
        var bearers: [String] = []

        let client = makeSupabaseClient(session: makeSession(access: "stale", expiresIn: -10)) { request in
            counter.record(request)
            if request.url?.path.contains("/auth/v1/token") == true {
                return .ok(SupabaseFixtures.tokenResponse())
            }
            bearers.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return .ok(SupabaseFixtures.emptyArray)
        }

        let _: [String] = try await client.send(.init(url: restURL))

        #expect(counter.count("/auth/v1/token") == 1)
        #expect(counter.count("/rest/v1/") == 1, "the doomed request was sent anyway")
        #expect(bearers == ["Bearer access-2"])
    }

    @Test("A live token is not refreshed")
    func liveTokenIsLeftAlone() async throws {
        let counter = CallCounter()
        let client = makeSupabaseClient(session: makeSession(expiresIn: 3600)) { request in
            counter.record(request)
            return .ok(SupabaseFixtures.emptyArray)
        }

        let _: [String] = try await client.send(.init(url: restURL))
        #expect(counter.count("/auth/v1/token") == 0)
    }

    @Test("A signed-out client does not try to refresh")
    func signedOutDoesNotRefresh() async throws {
        // No session at all is a normal state — public reads run on the anon
        // key. There is nothing to refresh and nothing to sign out of.
        let counter = CallCounter()
        let client = makeSupabaseClient(session: nil) { request in
            counter.record(request)
            return .ok(SupabaseFixtures.emptyArray)
        }

        let _: [String] = try await client.send(.init(url: restURL))
        #expect(counter.count("/auth/v1/token") == 0)
    }
}

// MARK: - Restore

@Suite("Restore at launch")
@MainActor
struct SessionRestoreTests {

    private func makeProfile(handle: String = "jude") -> UserProfile {
        UserProfile(id: UUID(), handle: handle, displayName: "Jude", bio: nil,
                    avatarURL: nil, isPrivate: false, createdAt: .now)
    }

    @Test("An unreachable server does not sign anyone out")
    func offlineLaunchStaysSignedIn() async {
        // The report this whole file exists for: open the app with no signal,
        // find yourself signed out, sign in again, and conclude that sessions
        // keep expiring. The credential was in the Keychain the entire time.
        let profile = makeProfile()
        let cache = InMemoryProfileCache(profile: profile)
        let session = SessionViewModel(
            service: StubAuthService(hasSession: true, result: .failure(SupabaseError.transport("offline"))),
            profiles: cache
        )

        await session.restore()

        #expect(session.isSignedIn)
        #expect(session.profile?.handle == "jude")
        #expect(session.isProfileStale, "a cached profile must be marked for refresh")
    }

    @Test("No credential means signed out, whatever the cache remembers")
    func clearedCredentialSignsOut() async {
        // The client clears the Keychain when the server rejects the refresh
        // token. A stale cached profile must not paper over that: it would show
        // a signed-in shell where every request 401s.
        let cache = InMemoryProfileCache(profile: makeProfile())
        let session = SessionViewModel(
            service: StubAuthService(hasSession: false, result: .failure(SupabaseError.unauthorized)),
            profiles: cache
        )

        await session.restore()

        #expect(session.isSignedIn == false)
        #expect(cache.load() == nil, "the cached profile outlived the session")
    }

    @Test("A reachable server is believed over the cache")
    func serverWins() async {
        let cache = InMemoryProfileCache(profile: makeProfile(handle: "old"))
        let service = StubAuthService(hasSession: true, result: .success(makeProfile(handle: "new")))
        let session = SessionViewModel(service: service, profiles: cache)

        await session.restore()

        #expect(session.profile?.handle == "new")
        #expect(session.isProfileStale == false)
        #expect(cache.load()?.handle == "new", "the cache was not refreshed")
    }

    @Test("An authoritative nil signs out and clears the cache")
    func nilProfileSignsOut() async {
        let cache = InMemoryProfileCache(profile: makeProfile())
        let session = SessionViewModel(
            service: StubAuthService(hasSession: false, result: .success(nil)),
            profiles: cache
        )

        await session.restore()

        #expect(session.isSignedIn == false)
        #expect(cache.load() == nil)
    }

    @Test("A stale profile is refreshed when the network comes back")
    func staleProfileRefreshes() async {
        let service = StubAuthService(hasSession: true, result: .failure(SupabaseError.transport("offline")))
        let session = SessionViewModel(service: service, profiles: InMemoryProfileCache(profile: makeProfile(handle: "cached")))

        await session.restore()
        #expect(session.isProfileStale)

        service.result = .success(makeProfile(handle: "fresh"))
        await session.refreshProfileIfStale()

        #expect(session.profile?.handle == "fresh")
        #expect(session.isProfileStale == false)
    }

    @Test("A refresh that fails again leaves the session alone")
    func failedRefreshKeepsTheCachedProfile() async {
        let service = StubAuthService(hasSession: true, result: .failure(SupabaseError.transport("offline")))
        let session = SessionViewModel(service: service, profiles: InMemoryProfileCache(profile: makeProfile(handle: "cached")))

        await session.restore()
        await session.refreshProfileIfStale()

        #expect(session.profile?.handle == "cached")
        #expect(session.isProfileStale, "still stale, so a later trigger tries again")
    }

    @Test("Signing out clears the cached profile")
    func signOutClearsCache() async {
        // Otherwise the next offline launch restores the person who signed out.
        let cache = InMemoryProfileCache()
        let auth = MockAuthService()
        let session = SessionViewModel(service: auth, profiles: cache)

        await session.signUp(email: "a@b.test", password: "password1", handle: "jude")
        #expect(cache.load()?.handle == "jude", "a signed-in profile was not cached")

        await session.signOut()

        #expect(session.isSignedIn == false)
        #expect(cache.load() == nil)
    }
}

// MARK: - Support

/// An `AuthService` whose `currentProfile()` answer a test controls, so the
/// three cases that matter — a profile, an authoritative nil, and a failure —
/// can each be produced on demand.
private final class StubAuthService: AuthService, @unchecked Sendable {

    var hasSession: Bool
    var result: Result<UserProfile?, Error>

    init(hasSession: Bool, result: Result<UserProfile?, Error>) {
        self.hasSession = hasSession
        self.result = result
    }

    var hasStoredSession: Bool { get async { hasSession } }

    func currentProfile() async throws -> UserProfile? { try result.get() }

    func signOut() async {
        hasSession = false
        result = .success(nil)
    }

    func signUp(email: String, password: String, handle: String) async throws -> UserProfile {
        throw AuthError.notConfigured
    }
    func signIn(email: String, password: String) async throws -> UserProfile {
        throw AuthError.notConfigured
    }
    func isHandleAvailable(_ handle: String) async -> Bool { false }
    func updateProfile(_ profile: UserProfile) async throws -> UserProfile {
        throw AuthError.notConfigured
    }
    func sendPasswordReset(email: String) async throws {}
    func deleteAccount() async throws { throw AuthError.notConfigured }
}

/// One-shot switch: the first caller is offline, everyone after is not.
private final class OnceOffline: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
