//
//  SupabaseClientTests.swift
//  BingedTests
//
//  The retry and refresh rules. These are the parts that fail in ways a user
//  notices — a sign-out loop, or a session dropped on the busiest screen — and
//  they are all concurrency, so they need testing rather than reasoning about.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Configuration

@Suite("SupabaseConfiguration")
struct SupabaseConfigurationTests {

    @Test("An unconfigured build is a supported state, not a broken one")
    func missingCredentialsAreNil() {
        #expect(SupabaseConfiguration.make(url: "", anonKey: "") == nil)
        #expect(SupabaseConfiguration.make(
            url: SupabaseConfiguration.unsetURLPlaceholder, anonKey: "key") == nil)
        #expect(SupabaseConfiguration.make(
            url: "https://x.supabase.co", anonKey: SupabaseConfiguration.unsetKeyPlaceholder) == nil)
    }

    @Test("A half-configured build fails like an unconfigured one")
    func partialConfigurationIsRejected() {
        // Sending the literal string "$(SUPABASE_URL)" to a server is worse than
        // reporting the app unconfigured.
        #expect(SupabaseConfiguration.make(url: "https://x.supabase.co", anonKey: "") == nil)
        #expect(SupabaseConfiguration.make(url: "not a url", anonKey: "key") == nil)
        #expect(SupabaseConfiguration.make(url: "ftp://x.co", anonKey: "key") == nil)
        // What an unescaped `//` in Secrets.xcconfig actually produces: a valid
        // URL with an https scheme and no host at all.
        #expect(SupabaseConfiguration.make(url: "https:", anonKey: "key") == nil)
    }

    @Test("Endpoints are built under the right prefixes")
    func endpointShapes() {
        let configuration = makeSupabaseConfiguration()
        #expect(configuration.rest("profiles").path == "/rest/v1/profiles")
        #expect(configuration.auth("token").path == "/auth/v1/token")
        #expect(configuration.rpc("feed").path == "/rest/v1/rpc/feed")
    }
}

// MARK: - Errors

@Suite("SupabaseClient — status mapping")
struct SupabaseStatusTests {

    @Test("403 is not 401, and must never sign the user out")
    func forbiddenIsDistinct() async {
        // An RLS denial is the expected outcome of asking for a row you cannot
        // see. Treating it as a dead session would sign a user out for browsing
        // a profile they do not follow.
        let client = makeSupabaseClient { _ in .status(403, SupabaseFixtures.forbidden) }

        await #expect(throws: SupabaseError.forbidden) {
            _ = try await client.send(.init(url: makeSupabaseConfiguration().rest("profiles")))
        }
        #expect(await client.isSignedIn, "a 403 ended the session")
        #expect(SupabaseError.forbidden.shouldSignOut == false)
    }

    @Test("409 carries the server's message so a taken handle can be named")
    func conflictKeepsItsMessage() async {
        let client = makeSupabaseClient { _ in .status(409, SupabaseFixtures.conflict) }

        do {
            _ = try await client.send(.init(method: "POST", url: makeSupabaseConfiguration().rest("profiles")))
            Issue.record("expected a conflict")
        } catch SupabaseError.conflict(let message) {
            #expect(message?.contains("unique constraint") == true)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("An unconfigured client refuses before touching the network")
    func unconfiguredShortCircuits() async {
        let counter = CallCounter()
        let urlSession = StubURLProtocol.makeSession { request in
            counter.record(request)
            return .ok(Data("{}".utf8))
        }
        let client = SupabaseClient(configuration: nil, session: urlSession,
                                    tokens: InMemoryTokenStore())

        await #expect(throws: SupabaseError.notConfigured) {
            _ = try await client.send(.init(url: URL(string: "https://x.test/rest/v1/p")!))
        }
        #expect(counter.total == 0)
    }
}

// MARK: - Refresh

@Suite("SupabaseClient — token refresh")
struct SupabaseRefreshTests {

    private var restURL: URL { makeSupabaseConfiguration().rest("profiles") }

    @Test("A 401 refreshes once and retries once")
    func refreshThenRetry() async throws {
        let counter = CallCounter()
        let expired = makeSession(access: "expired")

        let client = makeSupabaseClient(session: expired) { request in
            counter.record(request)
            if request.url?.path.contains("/auth/v1/token") == true {
                return .ok(SupabaseFixtures.tokenResponse())
            }
            // The first data call fails; anything after the refresh succeeds.
            return counter.count("/rest/v1/") <= 1
                ? .status(401, SupabaseFixtures.unauthorized)
                : .ok(SupabaseFixtures.emptyArray)
        }

        let rows: [String] = try await client.send(.init(url: restURL))
        #expect(rows.isEmpty)
        #expect(counter.count("/auth/v1/token") == 1)
        #expect(counter.count("/rest/v1/") == 2, "expected one failure and one retry")
        #expect(await client.currentSession?.accessToken == "access-2")
    }

    @Test("A second 401 after refreshing signs out rather than looping")
    func doesNotLoop() async {
        // An unbounded retry against a rejected credential is how a client
        // hammers an auth server and locks the user out of retrying later.
        let counter = CallCounter()
        let client = makeSupabaseClient { request in
            counter.record(request)
            if request.url?.path.contains("/auth/v1/token") == true {
                return .ok(SupabaseFixtures.tokenResponse())
            }
            return .status(401, SupabaseFixtures.unauthorized)
        }

        await #expect(throws: SupabaseError.unauthorized) {
            _ = try await client.send(.init(url: restURL))
        }
        #expect(counter.count("/auth/v1/token") == 1)
        #expect(counter.count("/rest/v1/") == 2)
        #expect(await client.isSignedIn == false, "a dead session was kept")
    }

    @Test("Ten concurrent 401s produce exactly one refresh")
    func concurrentRefreshIsSingleFlight() async throws {
        // The case this actor exists for. A feed screen fires several requests
        // at once, and Supabase rotates refresh tokens — so N refreshes would
        // invalidate N-1 of them and sign the user out on the busiest screen.
        let counter = CallCounter()
        let client = makeSupabaseClient { request in
            counter.record(request)
            if request.url?.path.contains("/auth/v1/token") == true {
                return .ok(SupabaseFixtures.tokenResponse())
            }
            // Every request fails until a refresh has completed.
            return counter.count("/auth/v1/token") == 0
                ? .status(401, SupabaseFixtures.unauthorized)
                : .ok(SupabaseFixtures.emptyArray)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let _: [String] = try await client.send(.init(url: self.restURL))
                }
            }
            try await group.waitForAll()
        }

        #expect(counter.count("/auth/v1/token") == 1,
                "\(counter.count("/auth/v1/token")) refreshes for ten concurrent 401s")
    }

    @Test("A failed refresh clears the session")
    func failedRefreshSignsOut() async {
        let client = makeSupabaseClient { request in
            request.url?.path.contains("/auth/v1/token") == true
                ? .status(401, SupabaseFixtures.unauthorized)
                : .status(401, SupabaseFixtures.unauthorized)
        }

        await #expect(throws: SupabaseError.unauthorized) {
            _ = try await client.send(.init(url: restURL))
        }
        #expect(await client.isSignedIn == false)
    }

    @Test("An anonymous request never tries to refresh")
    func anonymousRequestsDoNotRefresh() async {
        // Sign-in and sign-up mint a session; carrying the old one into them, or
        // trying to refresh a session that does not exist yet, is nonsense.
        let counter = CallCounter()
        let client = makeSupabaseClient(session: nil) { request in
            counter.record(request)
            return .status(401, SupabaseFixtures.unauthorized)
        }

        await #expect(throws: SupabaseError.unauthorized) {
            _ = try await client.send(.init(url: makeSupabaseConfiguration().auth("token"),
                                            anonymous: true))
        }
        #expect(counter.count("/auth/v1/token") == 1, "an anonymous 401 triggered a refresh")
    }
}

// MARK: - Headers

@Suite("SupabaseClient — headers and encoding")
struct SupabaseHeaderTests {

    @Test("Signed out, the anon key is both apikey and bearer")
    func anonymousHeaders() async throws {
        // This is what lets an RLS policy written against `anon` serve public
        // reads with no session at all.
        var seen: URLRequest?
        let urlSession = StubURLProtocol.makeSession { request in
            seen = request
            return .ok(SupabaseFixtures.emptyArray)
        }
        let client = SupabaseClient(configuration: makeSupabaseConfiguration(),
                                    session: urlSession, tokens: InMemoryTokenStore())

        let _: [String] = try await client.send(.init(url: makeSupabaseConfiguration().rest("profiles")))

        #expect(seen?.value(forHTTPHeaderField: "apikey") == "anon-test-key")
        #expect(seen?.value(forHTTPHeaderField: "Authorization") == "Bearer anon-test-key")
    }

    @Test("Signed in, the bearer is the user's access token")
    func authenticatedHeaders() async throws {
        var seen: URLRequest?
        let urlSession = StubURLProtocol.makeSession { request in
            seen = request
            return .ok(SupabaseFixtures.emptyArray)
        }
        let client = SupabaseClient(
            configuration: makeSupabaseConfiguration(), session: urlSession,
            tokens: InMemoryTokenStore(session: makeSession(access: "user-token"))
        )

        let _: [String] = try await client.send(.init(url: makeSupabaseConfiguration().rest("profiles")))

        #expect(seen?.value(forHTTPHeaderField: "apikey") == "anon-test-key")
        #expect(seen?.value(forHTTPHeaderField: "Authorization") == "Bearer user-token")
    }

    @Test("Range is sent for pagination")
    func rangeHeader() async throws {
        var seen: URLRequest?
        let urlSession = StubURLProtocol.makeSession { request in
            seen = request
            return .ok(SupabaseFixtures.emptyArray)
        }
        let client = SupabaseClient(configuration: makeSupabaseConfiguration(),
                                    session: urlSession, tokens: InMemoryTokenStore())

        let _: [String] = try await client.send(
            .init(url: makeSupabaseConfiguration().rest("posts"), range: 0...19)
        )
        #expect(seen?.value(forHTTPHeaderField: "Range") == "0-19")
    }

    @Test("Timestamps decode with and without fractional seconds")
    func dateStrategyHandlesBothShapes() throws {
        // Postgres `timestamptz` comes back both ways depending on the value,
        // and a decoder that handles one of them fails on real data.
        struct Row: Decodable { let at: Date }

        let withFraction = Data(#"{"at":"2026-08-21T12:34:56.789Z"}"#.utf8)
        let without = Data(#"{"at":"2026-08-21T12:34:56Z"}"#.utf8)

        let a = try SupabaseClient.decoder.decode(Row.self, from: withFraction)
        let b = try SupabaseClient.decoder.decode(Row.self, from: without)

        #expect(abs(a.at.timeIntervalSince(b.at) - 0.789) < 0.01)
    }
}

// MARK: - Token store

@Suite("Token store")
struct TokenStoreTests {

    @Test("A session round-trips and can be cleared")
    func inMemoryRoundTrip() {
        let store = InMemoryTokenStore()
        #expect(store.load() == nil)

        let session = makeSession()
        store.save(session)
        #expect(store.load() == session)

        store.clear()
        #expect(store.load() == nil)
    }

    @Test("Expiry is judged early, with leeway")
    func expiryHasLeeway() {
        // A token that dies in flight is a 401 the user did not need to see.
        #expect(makeSession(expiresIn: 3600).isExpired() == false)
        #expect(makeSession(expiresIn: 30).isExpired() == true, "should expire within the leeway")
        #expect(makeSession(expiresIn: -10).isExpired() == true)
    }

    @Test("The Keychain store survives a fresh instance")
    func keychainRoundTrip() {
        // Uses a unique service so it cannot collide with anything else on the
        // machine, and cleans up after itself.
        let service = "com.watchrank.tests.\(UUID().uuidString)"
        let store = KeychainTokenStore(service: service)
        defer { store.clear() }

        let session = makeSession(access: "kept")
        store.save(session)

        // A *different* instance, which is what a relaunch looks like.
        let reopened = KeychainTokenStore(service: service)
        #expect(reopened.load()?.accessToken == "kept")

        reopened.clear()
        #expect(KeychainTokenStore(service: service).load() == nil)
    }
}
