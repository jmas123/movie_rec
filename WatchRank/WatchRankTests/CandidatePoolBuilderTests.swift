//
//  CandidatePoolBuilderTests.swift
//  WatchRankTests
//
//  Paging, deduplication, stopping rules and the TTL, against an in-memory
//  `CandidateSource`.
//
//  A stub rather than the `URLProtocol` fixture path: what is being tested here
//  is when the builder stops asking and what it keeps, and routing that through
//  a fake HTTP layer would mostly be testing the fake.
//  `TMDBMediaServiceTests` covers the wire format.
//

import Foundation
import Testing
@testable import WatchRank

@Suite("CandidatePoolBuilder")
struct CandidatePoolBuilderTests {

    private let vocabulary = makeFullGenreVocabulary()

    // MARK: - Coverage

    @Test("Every mood and type is populated from a full source")
    func fullSweepPopulatesEveryMood() async {
        let source = makeFullStubSource()
        let builder = CandidatePoolBuilder(source: source, cache: makeDisabledCache())
        let pool = await builder.build()

        for mood in Mood.allCases {
            for type in MediaType.allCases {
                let count = pool.count(mood: mood, type: type)
                #expect(count >= 30, "\(mood.rawValue)/\(type.rawValue) yielded \(count)")
            }
        }
        #expect(pool.truncated.isEmpty)
    }

    @Test("Paging stops once the target is met")
    func pagingStopsAtTarget() async {
        let source = makeFullStubSource(pagesPerComponent: 10, perPage: 20)
        let builder = CandidatePoolBuilder(
            source: source, cache: makeDisabledCache(), target: 45, maxPages: 10
        )
        _ = await builder.build(moods: [.crime], types: [.movie])

        // 45 wanted at 20 per page: three pages, never the ten available.
        #expect(source.requests.count == 3)
    }

    @Test("A component that runs dry stops rather than paging to the cap")
    func exhaustedComponentStops() async {
        let source = makeFullStubSource(pagesPerComponent: 1, perPage: 10)
        let builder = CandidatePoolBuilder(
            source: source, cache: makeDisabledCache(), target: 45, maxPages: 5
        )
        _ = await builder.build(moods: [.crime], types: [.movie])

        // Page 1 returns 10, page 2 returns nothing and ends it. Reaching the
        // cap would mean five calls.
        #expect(source.requests.count == 2)
    }

    // MARK: - Deduplication

    @Test("A title in two moods is stored once and listed twice")
    func overlappingMoodsShareStorage() async {
        // `crime` and `comedy` both rest on a single genre component, so giving
        // them the same titles models the real overlap case.
        let shared = (0..<20).map { "tmdb:movie:\($0)" }
        let crime = Mood.crime.queryComponents(for: .movie, vocabulary: vocabulary)[0]
        let comedy = Mood.comedy.queryComponents(for: .movie, vocabulary: vocabulary)[0]

        let source = StubCandidateSource(pages: [
            crime.identity: [shared],
            comedy.identity: [shared],
        ], vocabulary: vocabulary)

        let builder = CandidatePoolBuilder(source: source, cache: makeDisabledCache())
        let pool = await builder.build(moods: [.crime, .comedy], types: [.movie])

        #expect(pool.titles.count == 20)
        #expect(pool.count(mood: .crime, type: .movie) == 20)
        #expect(pool.count(mood: .comedy, type: .movie) == 20)

        // Overlap costs storage, never coverage — the whole basis for making
        // pool size an output rather than a target.
        let listed = pool.count(mood: .crime, type: .movie) + pool.count(mood: .comedy, type: .movie)
        #expect(listed == 40)
        #expect(pool.titles.count < listed)
    }

    @Test("A title repeated within one mood's components is listed once")
    func withinMoodDuplicatesCollapse() async {
        // `epic`/movie has both a genre and a keyword component; a title
        // matching both must not appear twice in its own membership list.
        let components = Mood.epic.queryComponents(for: .movie, vocabulary: vocabulary)
        #expect(components.count == 2)

        let overlapping = (0..<10).map { "tmdb:movie:\($0)" }
        let source = StubCandidateSource(pages: [
            components[0].identity: [overlapping],
            components[1].identity: [overlapping],
        ], vocabulary: vocabulary)

        let builder = CandidatePoolBuilder(source: source, cache: makeDisabledCache())
        let pool = await builder.build(moods: [.epic], types: [.movie])

        let ids = pool.membership[CandidatePool.key(mood: .epic, type: .movie)] ?? []
        #expect(ids.count == 10)
        #expect(Set(ids).count == ids.count)
    }

    @Test("A title with no external id cannot join the pool")
    func titlesWithoutIdentityAreDropped() async {
        // Identity is the whole basis of dedupe, so an anonymous title would
        // silently accumulate copies.
        final class AnonymousSource: CandidateSource, @unchecked Sendable {
            func discover(type: MediaType, component: MoodQueryComponent, page: Int) async throws -> [MediaItem] {
                page == 1 ? [MediaItem(title: "Anonymous", year: 2020, type: type)] : []
            }
            func genreVocabulary() async -> TMDBGenreVocabulary { makeFullGenreVocabulary() }
        }

        let builder = CandidatePoolBuilder(source: AnonymousSource(), cache: makeDisabledCache())
        let pool = await builder.build(moods: [.crime], types: [.movie])

        #expect(pool.titles.isEmpty)
        #expect(pool.count(mood: .crime, type: .movie) == 0)
    }

    // MARK: - Exclusions

    @Test("Exclusions make the builder page deeper, not return less")
    func exclusionsDrivePaging() async {
        let source = makeFullStubSource(pagesPerComponent: 10, perPage: 20)
        let crime = Mood.crime.queryComponents(for: .movie, vocabulary: vocabulary)[0]

        // Everything on the first two pages is already watched.
        let watched = Set((0..<2).flatMap { page in
            (0..<20).map { "tmdb:movie:\(crime.identity)-\(page)-\($0)" }
        })

        let plain = CandidatePoolBuilder(source: source, cache: makeDisabledCache(), target: 45, maxPages: 10)
        let before = await plain.build(moods: [.crime], types: [.movie])
        let baselineRequests = source.requests.count

        let deeper = makeFullStubSource(pagesPerComponent: 10, perPage: 20)
        let builder = CandidatePoolBuilder(source: deeper, cache: makeDisabledCache(), target: 45, maxPages: 10)
        let after = await builder.build(moods: [.crime], types: [.movie], excluding: watched)

        #expect(deeper.requests.count > baselineRequests)
        #expect(after.count(mood: .crime, type: .movie) > before.count(mood: .crime, type: .movie))

        // A mood is only full if it is full of things the user can still watch.
        let eligible = after.candidates(mood: .crime, type: .movie)
            .filter { !watched.contains($0.externalId) }
        #expect(eligible.count >= 45)
    }

    // MARK: - Truncation

    @Test("Hitting the page cap while still short is recorded, never silent")
    func truncationIsReported() async {
        let source = makeFullStubSource(pagesPerComponent: 10, perPage: 5)
        let builder = CandidatePoolBuilder(
            source: source, cache: makeDisabledCache(), target: 45, maxPages: 2
        )
        let pool = await builder.build(moods: [.crime], types: [.movie])

        // 2 pages of 5 is 10, well short of 45. A silent cap would read as
        // "covered everything" when it did not.
        #expect(pool.count(mood: .crime, type: .movie) == 10)
        #expect(!pool.truncated.isEmpty)
        #expect(pool.truncated.contains { $0.hasPrefix("crime|movie") })
    }

    @Test("A component that stops because the mood is already full is not truncation")
    func satisfiedMoodIsNotTruncated() async {
        let source = makeFullStubSource(pagesPerComponent: 10, perPage: 50)
        let builder = CandidatePoolBuilder(
            source: source, cache: makeDisabledCache(), target: 45, maxPages: 2
        )
        let pool = await builder.build(moods: [.crime], types: [.movie])

        #expect(pool.count(mood: .crime, type: .movie) >= 45)
        #expect(pool.truncated.isEmpty)
    }

    // MARK: - Persistence and TTL

    @Test("The pool survives a round trip through the cache")
    func poolRoundTrips() async {
        let cache = makeTemporaryCache()
        let source = makeFullStubSource()

        let first = CandidatePoolBuilder(source: source, cache: cache)
        let built = await first.build()

        // A second builder over a fresh source that would answer nothing: the
        // pool must come from disk, not from the network.
        let empty = StubCandidateSource(pages: [:], vocabulary: vocabulary)
        let second = CandidatePoolBuilder(source: empty, cache: cache)
        let loaded = await second.pool()

        #expect(loaded.titles.count == built.titles.count)
        #expect(loaded.count(mood: .horror, type: .tvShow) == built.count(mood: .horror, type: .tvShow))
        #expect(empty.requests.isEmpty, "a cached pool must not re-fetch")
    }

    @Test("A stale pool is served rather than awaited")
    func stalePoolIsServedImmediately() async {
        // Never block a mood tap on a rebuild: a week-old list of popular
        // titles is a fine answer, and a spinner is not.
        let cache = makeTemporaryCache(ttl: 0)
        let source = makeFullStubSource()
        await CandidatePoolBuilder(source: source, cache: cache).build()

        let slow = makeFullStubSource()
        let builder = CandidatePoolBuilder(source: slow, cache: cache, ttl: 0)
        let served = await builder.pool()

        #expect(!served.isEmpty)
        #expect(served.isStale(ttl: 0))
    }

    @Test("Staleness is computed from the build time")
    func stalenessIsTimeBased() {
        let fresh = CandidatePool(titles: [:], membership: [:], builtAt: .now, truncated: [])
        #expect(!fresh.isStale(ttl: 60))

        let old = CandidatePool(
            titles: [:], membership: [:],
            builtAt: Date(timeIntervalSinceNow: -120), truncated: []
        )
        #expect(old.isStale(ttl: 60))
        #expect(CandidatePool.empty.isStale(ttl: CatalogCache.defaultTTL))
    }

    // MARK: - Degenerate inputs

    @Test("A source with nothing to offer yields an empty pool, not a crash")
    func emptySourceIsSafe() async {
        let builder = CandidatePoolBuilder(
            source: StubCandidateSource(pages: [:], vocabulary: vocabulary),
            cache: makeDisabledCache()
        )
        let pool = await builder.build()

        #expect(pool.isEmpty)
        #expect(pool.candidates(mood: .crime, type: .movie).isEmpty)
        #expect(pool.count(mood: .crime, type: .movie) == 0)
    }

    @Test("Without a genre vocabulary, keyword moods still work")
    func missingVocabularyDegradesRatherThanEmpties() async {
        // A vocabulary outage costs every genre component. Television's moods
        // are mostly keyword-based, so Discover degrades rather than empties —
        // and that asymmetry is worth pinning.
        let source = makeFullStubSource(vocabulary: .empty)
        let builder = CandidatePoolBuilder(source: source, cache: makeDisabledCache())
        let pool = await builder.build(types: [.tvShow])

        #expect(pool.count(mood: .horror, type: .tvShow) > 0)
        #expect(pool.count(mood: .romance, type: .tvShow) > 0)
        // `comedy`/tv is genre-only, so it is the one that goes quiet.
        #expect(pool.count(mood: .comedy, type: .tvShow) == 0)
    }

    @Test("Concurrent refreshes coalesce onto one sweep")
    func concurrentRefreshesCoalesce() async {
        let source = makeFullStubSource()
        let builder = CandidatePoolBuilder(source: source, cache: makeDisabledCache())

        async let a = builder.refresh()
        async let b = builder.refresh()
        let (first, second) = await (a, b)

        #expect(first.titles.count == second.titles.count)
        #expect(!first.isEmpty)
    }
}

// MARK: - Wire format

@Suite("TMDBMediaService — mood discovery")
struct TMDBMoodDiscoveryTests {

    @Test("A genre component OR-s its ids into with_genres")
    func genreComponentBuildsORQuery() throws {
        let component = MoodQueryComponent(
            basis: .genres(ids: [80, 53], names: ["Crime", "Thriller"]), minimumVotes: nil
        )
        let url = try #require(TMDBEndpoint.discover(type: .movie, component: component, page: 1))
        let query = try #require(url.query)

        // `|` is OR within a parameter; `,` would be AND and would ask for
        // titles that are both at once.
        #expect(query.contains("with_genres=80%7C53") || query.contains("with_genres=80|53"))
        #expect(!query.contains("with_keywords"))
        #expect(query.contains("vote_count.gte=300"))
    }

    @Test("A keyword component uses with_keywords and never with_genres")
    func keywordComponentBuildsKeywordQuery() throws {
        let component = MoodQueryComponent(
            basis: .keywords(ids: [4379, 10854], names: ["time travel", "time loop"]), minimumVotes: nil
        )
        let url = try #require(TMDBEndpoint.discover(type: .tvShow, component: component, page: 2))
        let query = try #require(url.query)

        #expect(query.contains("with_keywords="))
        #expect(!query.contains("with_genres"))
        #expect(query.contains("page=2"))
        #expect(query.contains("vote_count.gte=100"))
    }

    @Test("A mood override lowers only its own vote floor")
    func voteFloorIsOverridable() throws {
        let component = MoodQueryComponent(
            basis: .keywords(ids: [1], names: ["rare"]), minimumVotes: 25
        )
        let url = try #require(TMDBEndpoint.discover(type: .movie, component: component, page: 1))
        #expect(try #require(url.query).contains("vote_count.gte=25"))

        // The plain popularity sweep keeps the type default.
        let plain = try #require(TMDBEndpoint.discover(type: .movie, page: 1))
        #expect(try #require(plain.query).contains("vote_count.gte=300"))
    }

    @Test("An empty component builds no URL at all")
    func emptyComponentIsRejected() {
        let component = MoodQueryComponent(basis: .genres(ids: [], names: []), minimumVotes: nil)
        #expect(TMDBEndpoint.discover(type: .movie, component: component, page: 1) == nil)
    }

    @MainActor
    @Test("Two components of one mood are cached separately")
    func componentsDoNotShareACacheEntry() async throws {
        let log = RequestLog()
        let service = makeTMDBService(log: log, cache: makeTemporaryCache())

        let genres = MoodQueryComponent(basis: .genres(ids: [12], names: ["Adventure"]), minimumVotes: nil)
        let keywords = MoodQueryComponent(basis: .keywords(ids: [234213], names: ["sword and sorcery"]), minimumVotes: nil)

        _ = try await service.discover(type: .movie, component: genres, page: 1)
        _ = try await service.discover(type: .movie, component: keywords, page: 1)

        // Sharing a key would let the genre response satisfy the keyword
        // request — the same collision the separate `features:` key prevents.
        #expect(log.count(inQuery: "with_genres") == 1)
        #expect(log.count(inQuery: "with_keywords") == 1)

        // And a repeat is served from cache.
        _ = try await service.discover(type: .movie, component: genres, page: 1)
        #expect(log.count(inQuery: "with_genres") == 1)
    }

    @MainActor
    @Test("Keyword resolution prefers an exact match over the first result")
    func keywordResolutionPrefersExactMatch() async {
        let service = makeTMDBService(cache: makeDisabledCache()) { request in
            guard let url = request.url else { return .transportFailure }
            if url.path.hasSuffix("/search/keyword") {
                // TMDB's search is fuzzy: "romance" really does return
                // "romance novel" above "romance" often enough to matter.
                return .ok(Data("""
                {"results":[{"id":1,"name":"romance novel"},{"id":9840,"name":"romance"}]}
                """.utf8))
            }
            return .status(404, Data(TMDBFixtures.notFound.utf8))
        }

        #expect(await service.resolveKeywordId("romance") == 9840)
    }

    @MainActor
    @Test("A failed keyword lookup leaves the shipped id alone")
    func keywordResolutionFailsSoftly() async {
        let service = makeTMDBService(cache: makeDisabledCache()) { _ in .transportFailure }
        #expect(await service.resolveKeywordId("neo-noir") == nil)
    }
}

// MARK: - Network manners

@Suite("TMDBMediaService — network manners")
struct TMDBNetworkMannersTests {

    @MainActor
    @Test("Concurrent identical requests share one round trip")
    func requestsCoalesce() async throws {
        // Building a cold pool asks for overlapping pages within milliseconds.
        // Without coalescing every caller is a separate request against a
        // rate-limited API.
        let log = RequestLog()
        let service = makeTMDBService(log: log, cache: makeDisabledCache()) { request in
            guard request.url?.path.hasSuffix("/discover/movie") == true else {
                return .status(404, Data(TMDBFixtures.notFound.utf8))
            }
            return .ok(Data(TMDBFixtures.discoverMovies.utf8))
        }

        let component = MoodQueryComponent(
            basis: .genres(ids: [80], names: ["Crime"]), minimumVotes: nil
        )

        async let a = service.discover(type: .movie, component: component, page: 1)
        async let b = service.discover(type: .movie, component: component, page: 1)
        async let c = service.discover(type: .movie, component: component, page: 1)
        let results = try await [a, b, c]

        #expect(results.allSatisfy { !$0.isEmpty } == true)
        #expect(log.count(inQuery: "with_genres") == 1,
                "\(log.count(inQuery: "with_genres")) round trips for one URL")
    }

    @MainActor
    @Test("Different URLs are not coalesced together")
    func distinctRequestsAreNotMerged() async throws {
        let log = RequestLog()
        let service = makeTMDBService(log: log, cache: makeDisabledCache())

        let crime = MoodQueryComponent(basis: .genres(ids: [80], names: ["Crime"]), minimumVotes: nil)
        let horror = MoodQueryComponent(basis: .genres(ids: [27], names: ["Horror"]), minimumVotes: nil)

        _ = try await service.discover(type: .movie, component: crime, page: 1)
        _ = try await service.discover(type: .movie, component: horror, page: 1)

        #expect(log.count(inQuery: "with_genres=80") == 1)
        #expect(log.count(inQuery: "with_genres=27") == 1)
    }

    @MainActor
    @Test("A failure is not retried in a loop")
    func failuresDoNotStorm() async {
        // Retrying a rate-limited or failing endpoint is how a client turns one
        // outage into several. A failed call falls back to cache instead.
        let log = RequestLog()
        let service = makeTMDBService(log: log, cache: makeDisabledCache()) { _ in
            .status(500, Data("{}".utf8))
        }

        _ = try? await service.popularTitles(type: .movie, page: 1)
        #expect(log.count == 1, "\(log.count) attempts for one failing request")
    }

    @MainActor
    @Test("A warm pool is not rebuilt on launch")
    func warmPoolIsNotRefetched() async {
        // The pool has a weekly TTL. Re-paging it on every launch would be ~150
        // requests for data that has not changed.
        let cache = makeTemporaryCache()
        let first = makeFullStubSource()
        await CandidatePoolBuilder(source: first, cache: cache).refresh()
        #expect(first.requests.count > 0)

        let second = makeFullStubSource()
        _ = await CandidatePoolBuilder(source: second, cache: cache).pool()
        #expect(second.requests.isEmpty, "a warm pool was rebuilt")
    }
}

// MARK: - Scale

@Suite("Discover — scale")
@MainActor
struct DiscoverScaleTests {

    @Test("A full-pool request completes in a sane time")
    func fullPoolRequestIsFast() async throws {
        // Not a hard timing gate — those are flaky in CI. A very loose ceiling,
        // so a genuine order-of-magnitude regression (a profile rebuilt per
        // candidate, say) fails rather than merely feeling slow.
        let library = try makeRankedLibrary(movies: 60, shows: 40)
        let source = makeFullStubSource(pagesPerComponent: 5, perPage: 20)
        let builder = CandidatePoolBuilder(source: source, cache: makeDisabledCache())
        await builder.refresh()

        let vm = RecommendationViewModel(library: library, poolBuilder: builder)
        _ = await vm.recommendations(type: .movie, mood: .crime)

        let start = Date()
        for mood in Mood.allCases {
            _ = await vm.recommendations(type: .movie, mood: mood)
        }
        let elapsed = Date().timeIntervalSince(start)

        #expect(vm.profileRebuilds == 1, "the profile was rebuilt per request")
        #expect(elapsed < 5.0, "ten mood requests took \(elapsed)s")
    }
}
