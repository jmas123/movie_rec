//
//  TMDBTransportTests.swift
//  BingedTests
//
//  Which host a catalog request reaches, and which credential authorises it.
//
//  These exist because the failure they guard is silent and serious: sending
//  TMDB's bearer token to the proxy, or the Supabase anon key to TMDB. Both
//  produce a 401 rather than a crash, which in a client that falls back to
//  cache looks exactly like "the network is having a bad day".
//
//  Roadmap Phase 35.
//

import Foundation
import Testing

@testable import Binged

@Suite("TMDB transport")
struct TMDBTransportTests {

    private static let proxy = URL(string: "https://ref.supabase.co/functions/v1/tmdb-proxy")!
    private static let anonKey = "anon-key-abc"

    private func direct(_ token: String = "tmdb-token") -> TMDBConfiguration {
        TMDBConfiguration(transport: .direct(readToken: token))
    }

    private func proxied() -> TMDBConfiguration {
        TMDBConfiguration(transport: .proxy(baseURL: Self.proxy, anonKey: Self.anonKey))
    }

    // MARK: - Direct

    @Test("Direct requests go to TMDB and carry the TMDB token")
    func directKeepsTheCanonicalURL() throws {
        let canonical = try #require(TMDBEndpoint.searchMulti(query: "dune"))
        let request = try #require(direct().request(for: canonical))

        #expect(request.url == canonical)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tmdb-token")
        // No `apikey`: that header means something to Supabase and nothing to
        // TMDB, and sending it would leak which backend the app also talks to.
        #expect(request.value(forHTTPHeaderField: "apikey") == nil)
    }

    // MARK: - Proxy

    @Test("Proxied requests never reach TMDB's host")
    func proxyRewritesTheHost() throws {
        let canonical = try #require(TMDBEndpoint.searchMulti(query: "dune"))
        let request = try #require(proxied().request(for: canonical))
        let url = try #require(request.url)

        #expect(url.host == "ref.supabase.co")
        // The whole point of Phase 35: the credential does not leave the server.
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.anonKey)")
        #expect(request.value(forHTTPHeaderField: "apikey") == Self.anonKey)
    }

    @Test("A proxied request never carries the TMDB token")
    func proxyCarriesNoTMDBCredential() throws {
        let canonical = try #require(TMDBEndpoint.detail(type: .movie, tmdbId: 27205))
        let request = try #require(proxied().request(for: canonical))
        let headers = request.allHTTPHeaderFields ?? [:]

        let leaks = headers.values.contains { $0.contains("tmdb-token") }
        #expect(!leaks)
        #expect(proxied().readToken == nil)
        #expect(proxied().carriesPublicCredentialOnly)
        #expect(!direct().carriesPublicCredentialOnly)
    }

    @Test("The query string survives proxying")
    func proxyPreservesQueryItems() throws {
        // Losing the query would turn a search into a request for everything
        // TMDB has — a failure that returns 200 and looks like bad relevance.
        let canonical = try #require(TMDBEndpoint.searchMulti(query: "dune"))
        let request = try #require(proxied().request(for: canonical))
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)

        #expect(items.contains(URLQueryItem(name: "query", value: "dune")))
        #expect(items.contains(URLQueryItem(name: "include_adult", value: "false")))
    }

    @Test("TMDB's /3 prefix is stripped, and the endpoint path is kept")
    func proxyStripsTheAPIVersionPrefix() throws {
        // The function treats everything after its own name as the TMDB path
        // and adds `/3` itself. Leaving ours on would produce `/3/3/…`.
        let canonical = try #require(TMDBEndpoint.detail(type: .movie, tmdbId: 27205))
        let url = try #require(TMDBConfiguration.proxying(canonical, through: Self.proxy))

        #expect(url.path == "/functions/v1/tmdb-proxy/movie/27205")
        #expect(!url.path.contains("/3/"))
    }

    @Test("Every allow-listed endpoint maps to a path the proxy will accept")
    func allEndpointsMapOntoTheAllowList() throws {
        // The proxy's allow-list is a set of regexes over the path. An endpoint
        // that maps to something outside it 403s at runtime and nowhere else —
        // `find/tt…` and `discover/…` are the two the UI never exercises
        // directly, so they are the ones most likely to break unnoticed.
        let cases: [(String, URL?)] = [
            ("search/multi",        TMDBEndpoint.searchMulti(query: "x")),
            ("search/keyword",      TMDBEndpoint.searchKeyword("noir")),
            ("discover/movie",      TMDBEndpoint.discover(type: .movie, page: 1)),
            ("discover/tv",         TMDBEndpoint.discover(type: .tvShow, page: 1)),
            ("movie/27205",         TMDBEndpoint.detail(type: .movie, tmdbId: 27205)),
            ("tv/1396",             TMDBEndpoint.detail(type: .tvShow, tmdbId: 1396)),
            ("genre/movie/list",    TMDBEndpoint.genreList(type: .movie)),
            ("genre/tv/list",       TMDBEndpoint.genreList(type: .tvShow)),
            ("find/tt0111161",      TMDBEndpoint.find(imdbID: "tt0111161")),
        ]

        for (expected, canonical) in cases {
            let url = try #require(canonical, "no URL for \(expected)")
            let proxiedURL = try #require(TMDBConfiguration.proxying(url, through: Self.proxy))
            let suffix = "/functions/v1/tmdb-proxy/" + expected
            #expect(proxiedURL.path == suffix, "\(expected) mapped to \(proxiedURL.path)")
        }
    }

    // MARK: - Resolution

    @Test("The proxy wins when both are configured")
    func resolvePrefersTheProxy() throws {
        let supabase = try #require(
            SupabaseConfiguration.make(url: "https://ref.supabase.co", anonKey: Self.anonKey)
        )
        // A build that *can* avoid shipping the credential should.
        let resolved = try #require(
            TMDBConfiguration.resolve(from: .main, supabase: supabase)
        )
        #expect(resolved.carriesPublicCredentialOnly)
    }

    @Test("With no Supabase, resolution falls back to the bundled token")
    func resolveFallsBackToDirect() {
        // Deliberately not asserting a concrete value. Whether `.main` carries a
        // token depends on whether this checkout has `Config/Secrets.xcconfig`,
        // and an assertion that passes on CI and fails on a developer's machine
        // is worse than no assertion.
        //
        // The invariant that holds either way: with no Supabase, `resolve` must
        // agree exactly with `fromBundle` — it adds a preference, never a
        // different answer.
        let resolved = TMDBConfiguration.resolve(from: .main, supabase: nil)
        #expect(resolved == TMDBConfiguration.fromBundle(.main))

        // And whatever it found, it is never the public-credential transport:
        // there is no proxy to reach.
        #expect(resolved?.carriesPublicCredentialOnly != true)
    }

    @Test("An empty function name is refused rather than addressing the root")
    func emptyFunctionNameIsRejected() throws {
        let supabase = try #require(
            SupabaseConfiguration.make(url: "https://ref.supabase.co", anonKey: Self.anonKey)
        )
        #expect(supabase.functionURL(named: "") == nil)
        #expect(supabase.functionURL(named: "   ") == nil)
        #expect(
            supabase.functionURL(named: "tmdb-proxy")?.absoluteString
                == "https://ref.supabase.co/functions/v1/tmdb-proxy"
        )
    }
}
