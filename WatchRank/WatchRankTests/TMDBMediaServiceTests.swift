//
//  TMDBMediaServiceTests.swift
//  WatchRankTests
//
//  Covers the live catalog against recorded payloads. See `TMDBTestSupport`
//  for the fake network — nothing here reaches the internet.
//
//  The tests are grouped by the thing that can go wrong rather than by method,
//  because the interesting failures are cross-cutting: a person result leaking
//  into the library, a TV show decoding as an untitled movie, two spellings of
//  one genre halving the evidence behind it, a 401 masked by stale cache.
//

import Foundation
import Testing
@testable import WatchRank

// MARK: - Contract

@Suite("TMDBMediaService — MediaService contract")
@MainActor
struct TMDBMediaServiceContractTests {

    /// The shared contract every `MediaService` must satisfy. It exists in
    /// `TestSupport` precisely so the TMDB swap-in could be held to the same
    /// bar as the bundled service rather than merely compiling against the
    /// same signatures.
    @Test("Satisfies the shared MediaService contract")
    func satisfiesContract() async throws {
        let service = makeTMDBService()
        try await verifyMediaServiceContract(
            service,
            matchingQuery: "inception",
            knownExternalId: "tmdb:movie:27205"
        )
    }
}

// MARK: - Decoding

@Suite("TMDBMediaService — decoding")
@MainActor
struct TMDBDecodingTests {

    @Test("Person results never become MediaItems")
    func personResultsDropped() async throws {
        let results = try await makeTMDBService().search(query: "inception")

        // The fixture contains Leonardo DiCaprio as a person result. A person
        // mapped to a MediaItem would be addable to Want to Watch and rankable
        // against actual films.
        #expect(!results.contains { $0.title.contains("DiCaprio") })
        #expect(results.allSatisfy { $0.type == .movie || $0.type == .tvShow })
    }

    @Test("Movies read title/release_date, TV reads name/first_air_date")
    func typeSpecificFieldsResolve() async throws {
        let results = try await makeTMDBService().search(query: "inception")

        let movie = results.first { $0.externalId == "tmdb:movie:27205" }
        #expect(movie?.title == "Inception")
        #expect(movie?.year == 2010)
        #expect(movie?.type == .movie)

        // Decoded from `name` and `first_air_date`, not `title`/`release_date`.
        // Reading only the movie keys would yield a nil title and drop the show.
        let show = results.first { $0.externalId == "tmdb:tv:1396" }
        #expect(show?.title == "Breaking Bad")
        #expect(show?.year == 2008)
        #expect(show?.type == .tvShow)
    }

    @Test("An empty release date yields the unknown-year sentinel, not a crash or a drop")
    func emptyReleaseDateSurvives() async throws {
        let results = try await makeTMDBService().search(query: "inception")

        // TMDB ships announced-but-undated titles with `"release_date": ""`.
        // The title is real and must survive; only its year is unknown.
        let undated = results.first { $0.title == "Untitled Sequel" }
        #expect(undated != nil)
        #expect(undated?.year == TMDBTitleDTO.unknownYear)
    }

    @Test("Poster paths become absolute URLs, and a null path stays nil")
    func posterPathsResolve() async throws {
        let results = try await makeTMDBService().search(query: "inception")

        let movie = results.first { $0.externalId == "tmdb:movie:27205" }
        #expect(movie?.posterURL == "https://image.tmdb.org/t/p/w500/inception.jpg")

        let undated = results.first { $0.title == "Untitled Sequel" }
        #expect(undated?.posterURL == nil)
    }

    @Test("Catalog results carry no user state")
    func resultsAreInert() async throws {
        for item in try await makeTMDBService().search(query: "inception") {
            #expect(item.watchedStatus == .untracked)
            #expect(item.sentiment == nil)
            #expect(item.score == nil)
            #expect(item.rankInBucket == nil)
            #expect(item.modelContext == nil)
        }
    }
}

// MARK: - Identifiers

@Suite("TMDB identifiers")
struct TMDBIdentifierTests {

    @Test("A movie id and a TV id with the same number are different items")
    func idsAreNamespacedByType() {
        let movie = TMDBIdentifier.externalId(type: .movie, tmdbId: 1396)
        let show = TMDBIdentifier.externalId(type: .tvShow, tmdbId: 1396)

        // MediaLibraryViewModel.canonicalItem dedupes on externalId alone. If
        // these collided, marking the film watched would find the series and
        // the comparison flow could pit a title against itself.
        #expect(movie != show)
    }

    @Test("Round-trips through parse")
    func roundTrips() {
        for type in MediaType.allCases {
            let id = TMDBIdentifier.externalId(type: type, tmdbId: 42)
            let parsed = TMDBIdentifier.parse(id)
            #expect(parsed?.type == type)
            #expect(parsed?.tmdbId == 42)
        }
    }

    @Test(
        "Ids this app did not mint do not parse",
        arguments: ["tt1375666", "27205", "tmdb:27205", "tmdb:film:27205", "", "tmdb:movie:abc"]
    )
    func rejectsForeignIds(_ id: String) {
        // "tmdb:27205" is included deliberately: it is the un-namespaced form
        // an earlier draft of the roadmap specified, and it must not parse.
        #expect(TMDBIdentifier.parse(id) == nil)
    }

    @Test("A legacy IMDb id resolves to nil without hitting the network")
    func legacyIdIsAMissNotAnError() async throws {
        let log = RequestLog()
        let service = await makeTMDBService(log: log)

        let found = try await service.fetch(id: "tt1375666")

        #expect(found == nil)
        #expect(log.count == 0, "an unparseable id must not cost a request")
    }
}

// MARK: - External id resolution

@Suite("TMDBMediaService — IMDb resolution")
@MainActor
struct TMDBFindTests {

    @Test("Resolves a film and a series through the real service path")
    func resolvesKnownIds() async {
        let service = makeTMDBService()

        #expect(await service.resolveIMDbID("tt1375666", expecting: .movie) == 27205)
        #expect(await service.resolveIMDbID("tt0903747", expecting: .tvShow) == 1396)
    }

    @Test("A lookup is constrained to the expected media type")
    func respectsExpectedType() async {
        let service = makeTMDBService()

        // The ids above resolve, but only into their own type's array. Reading
        // whichever array happened to be non-empty would let the migration turn
        // a ranked film into an unrelated series.
        #expect(await service.resolveIMDbID("tt1375666", expecting: .tvShow) == nil)
        #expect(await service.resolveIMDbID("tt0903747", expecting: .movie) == nil)
    }

    @Test("An id TMDB does not know resolves to nil, not an error")
    func unknownIdIsNil() async {
        #expect(await makeTMDBService().resolveIMDbID("tt0000001", expecting: .movie) == nil)
    }

    @Test("A failed lookup is nil, so the migration simply retries next launch")
    func failureIsNil() async {
        let service = makeTMDBService(cache: makeDisabledCache()) { _ in .transportFailure }
        #expect(await service.resolveIMDbID("tt1375666", expecting: .movie) == nil)
    }

    @Test("Resolutions are cached, so a retry costs no request")
    func resolutionsAreCached() async {
        let log = RequestLog()
        let service = makeTMDBService(log: log)

        _ = await service.resolveIMDbID("tt1375666", expecting: .movie)
        _ = await service.resolveIMDbID("tt1375666", expecting: .movie)

        // The migration runs on every launch, so an uncached /find would mean a
        // request per legacy title per launch, forever.
        #expect(log.count(containing: "/find/") == 1)
    }
}

// MARK: - Genre vocabulary

@Suite("TMDB genre vocabulary")
struct TMDBGenreVocabularyTests {

    @Test("Film's Science Fiction and the app's Sci-Fi are one feature")
    func scienceFictionIsNormalized() {
        #expect(TMDBGenreVocabulary.canonical("Science Fiction") == ["Sci-Fi"])
    }

    @Test("Television's combined genres split into the film concepts they cover")
    func combinedTVGenresSplit() {
        #expect(TMDBGenreVocabulary.canonical("Sci-Fi & Fantasy") == ["Sci-Fi", "Fantasy"])
        #expect(TMDBGenreVocabulary.canonical("Action & Adventure") == ["Action", "Adventure"])
    }

    @Test("Unknown genres pass through rather than being dropped")
    func unknownGenresSurvive() {
        // A genre TMDB adds later should degrade to "one more feature", not to
        // a decode failure or a silent loss.
        #expect(TMDBGenreVocabulary.canonical("Telenovela") == ["Telenovela"])
    }

    @Test("A film and a series both tagged sci-fi land on the same feature name")
    @MainActor
    func vocabularyUnifiesAcrossTypes() async throws {
        let service = makeTMDBService()

        // Movie 27205 is tagged 878 = "Science Fiction" on the film list.
        let movie = try await service.fetch(id: "tmdb:movie:27205")
        #expect(movie?.genres.contains("Sci-Fi") == true)
        #expect(movie?.genres.contains("Science Fiction") == false)

        // Series 1399 is tagged 10765 = "Sci-Fi & Fantasy" on the TV list.
        let shows = try await service.popularTitles(type: .tvShow, page: 1)
        let got = shows.first { $0.title == "Game of Thrones" }
        #expect(got?.genres.contains("Sci-Fi") == true)
        #expect(got?.genres.contains("Fantasy") == true)

        // This is the assertion that matters: had the two spellings survived,
        // the taste profile would treat them as unrelated features and halve
        // the evidence behind each.
        #expect(got?.genres.contains("Sci-Fi & Fantasy") == false)
    }

    @Test("Genres are deduplicated when two TMDB genres map to one canonical name")
    func canonicalGenresDeduplicate() {
        let vocabulary = TMDBGenreVocabulary(
            movie: [TMDBGenreDTO(id: 878, name: "Science Fiction")],
            tv: [TMDBGenreDTO(id: 10765, name: "Sci-Fi & Fantasy")]
        )
        let resolved = vocabulary.canonicalGenres(names: ["Science Fiction", "Sci-Fi & Fantasy"])
        #expect(resolved == ["Sci-Fi", "Fantasy"], "Sci-Fi must appear once, not twice")
    }
}

// MARK: - Feature extraction

@Suite("TMDB feature extraction")
@MainActor
struct TMDBFeatureTests {

    /// Parses the extracted keys so assertions read in terms of families rather
    /// than string matching.
    private func features(_ keys: [String], _ family: Feature.Family) -> [Feature] {
        keys.features(in: family)
    }

    @Test("A film yields every family it has metadata for")
    func filmFeatures() async throws {
        let extracted = try #require(await makeTMDBService().features(type: .movie, tmdbId: 27205))
        let keys = extracted.keys

        #expect(features(keys, .genre).map(\.displayName).sorted() == ["Action", "Sci-Fi"])
        #expect(features(keys, .keyword).map(\.displayName).sorted() == ["dream", "dystopia", "heist"])
        #expect(features(keys, .era).first?.displayName == "2010s")
        #expect(features(keys, .runtime).first?.displayName == "long")   // 148 minutes
        #expect(features(keys, .lang).first?.displayName == "en")
        #expect(features(keys, .director).first?.displayName == "Christopher Nolan")
        #expect(features(keys, .composer).first?.displayName == "Hans Zimmer")
        #expect(features(keys, .franchise).first?.displayName == "The Nolan Collection")
        #expect(extracted.voteAverage == 8.4)
    }

    @Test("Cast is capped at three, in billing order")
    func castIsCappedAndOrdered() async throws {
        let extracted = try #require(await makeTMDBService().features(type: .movie, tmdbId: 27205))
        let cast = features(extracted.keys, .cast)

        // The fixture has four billed actors; the fourth must be dropped rather
        // than stored, or a TV aggregate_credits payload would put hundreds of
        // people into a single MediaItem.
        #expect(cast.count == 3)
        #expect(cast.map(\.displayName) == ["Leonardo DiCaprio", "Joseph Gordon-Levitt", "Elliot Page"])
    }

    @Test("A series reads the three TV-shaped fields correctly")
    func seriesFeatures() async throws {
        let extracted = try #require(await makeTMDBService().features(type: .tvShow, tmdbId: 1396))
        let keys = extracted.keys

        // Keywords nest under `results` for TV, not `keywords`.
        #expect(features(keys, .keyword).map(\.displayName).sorted() == ["drug dealer", "neo-noir"])

        // The director is the creator, not an episode director. Vince Gilligan
        // appears in the crew list too, but created_by is the authoritative one.
        #expect(features(keys, .director).map(\.displayName) == ["Vince Gilligan"])

        // Crew entries carry a `jobs` array rather than a `job` string, so a
        // decoder written only against the film shape finds no composer here.
        #expect(features(keys, .composer).first?.displayName == "Dave Porter")

        #expect(features(keys, .network).first?.displayName == "AMC")
        #expect(features(keys, .runtime).first?.displayName == "episode")   // 47 minutes
        #expect(features(keys, .era).first?.displayName == "2000s")
    }

    @Test("TV cast is ranked by episode count, not by list order")
    func tvCastRankedByEpisodeCount() async throws {
        let extracted = try #require(await makeTMDBService().features(type: .tvShow, tmdbId: 1396))
        let cast = features(extracted.keys, .cast)

        // Lavell Crawford is fourth in the payload with 9 episodes and must not
        // displace a series regular. TV has no billing order that means
        // anything across a run, so episode count stands in for prominence.
        #expect(cast.count == 3)
        #expect(!cast.contains { $0.displayName == "Lavell Crawford" })
    }

    @Test("A title with almost no metadata still yields a valid, shorter array")
    func sparseMetadataIsNotAnError() async throws {
        let extracted = try #require(await makeTMDBService().features(type: .movie, tmdbId: 31111))

        // No credits, keywords, runtime, language, or collection — the normal
        // state for older and obscure titles. What exists must still come out.
        #expect(features(extracted.keys, .era).first?.displayName == "1950s")
        #expect(features(extracted.keys, .cast).isEmpty)
        #expect(features(extracted.keys, .keyword).isEmpty)
        #expect(features(extracted.keys, .runtime).isEmpty)
        #expect(extracted.voteAverage == nil)
    }

    @Test("A failing feature fetch is an absence of evidence, not an error")
    func featureFailureIsNil() async {
        let service = makeTMDBService(cache: makeDisabledCache()) { _ in .transportFailure }

        // Throwing here would let one unreachable request fail a whole profile
        // rebuild; the predictor cannot tell "none" from "unknown" anyway.
        #expect(await service.features(type: .movie, tmdbId: 27205) == nil)
    }

    @Test("A plain detail fetch cannot satisfy a feature fetch from cache")
    func detailAndFeatureCachesAreSeparate() async throws {
        let cache = makeTemporaryCache()
        let service = makeTMDBService(cache: cache)

        // Warm the cache with the plain detail response, which has no credits.
        _ = try await service.fetch(id: "tmdb:movie:27205")

        // Sharing a cache key would serve that credit-free payload here and
        // yield a title with silently no cast or director.
        let extracted = try #require(await service.features(type: .movie, tmdbId: 27205))
        #expect(!features(extracted.keys, .cast).isEmpty)
        #expect(features(extracted.keys, .director).first?.displayName == "Christopher Nolan")
    }
}

// MARK: - Feature keys

@Suite("Feature")
struct FeatureTests {

    @Test("Every family round-trips through the stored key form")
    func allFamiliesRoundTrip() throws {
        let samples: [Feature] = [
            .genre("Horror"),
            .keyword(id: 1721, name: "neo-noir"),
            .language("ja"),
            .director(id: 525, name: "Christopher Nolan"),
            .composer(id: 947, name: "Hans Zimmer"),
            .castMember(id: 6193, name: "Leonardo DiCaprio"),
            .franchise(id: 86311, name: "The Avengers"),
            .network(id: 213, name: "Netflix"),
            try #require(Feature.era(year: 2014)),
            try #require(Feature.runtime(minutes: 180)),
        ]

        // Every family must survive a write to disk and a read back, or a
        // stored library silently loses feature evidence on relaunch.
        #expect(samples.count == Feature.Family.allCases.count)
        for feature in samples {
            #expect(Feature(key: feature.key) == feature, "\(feature.key) did not round-trip")
        }
    }

    @Test("A display name containing punctuation survives parsing")
    func punctuationInNamesSurvives() {
        // Collection names really do contain colons, and the key format uses a
        // colon as its family separator — so the split has to be first-only.
        let feature = Feature.franchise(id: 87359, name: "Mission: Impossible Collection")
        #expect(Feature(key: feature.key)?.displayName == "Mission: Impossible Collection")
    }

    @Test(
        "An unrecognised or malformed key is dropped, not crashed on",
        arguments: ["", "nofamily", "unknown:thing", "genre:", ":Horror", "keyword:|name", "keyword:12|"]
    )
    func badKeysAreDropped(_ key: String) {
        // These come off disk, so a key written by a newer build must degrade
        // to one less feature rather than to a crash on launch.
        #expect(Feature(key: key) == nil)
    }

    @Test("Identity is the id, not the display name")
    func identityIsTheId() {
        // Two different people really are credited as "Chris Evans".
        let one = Feature.castMember(id: 16828, name: "Chris Evans")
        let other = Feature.castMember(id: 12111, name: "Chris Evans")
        #expect(one != other)
        #expect(one.key != other.key)
    }

    @Test("An undated title contributes no era")
    func unknownYearHasNoEra() {
        // Otherwise every undated title would pile onto a nonsense "0s" feature
        // and appear to share something real.
        #expect(Feature.era(year: TMDBTitleDTO.unknownYear) == nil)
    }

    @Test("A missing runtime contributes no band")
    func missingRuntimeHasNoBand() {
        #expect(Feature.runtime(minutes: nil) == nil)
        #expect(Feature.runtime(minutes: 0) == nil)
    }

    @Test("Keys deduplicate while preserving order")
    func keysDeduplicate() {
        let features: [Feature] = [.genre("Drama"), .genre("Crime"), .genre("Drama")]
        #expect(features.keys == ["genre:Drama", "genre:Crime"])
    }
}

// MARK: - Errors and offline behaviour

@Suite("TMDBMediaService — failure handling")
@MainActor
struct TMDBFailureTests {

    @Test("A 404 on a detail fetch is nil, not a thrown error")
    func notFoundIsNil() async throws {
        let found = try await makeTMDBService().fetch(id: "tmdb:movie:999999")
        #expect(found == nil)
    }

    @Test("A 401 surfaces as an error rather than an empty result list")
    func unauthorizedThrows() async {
        let service = makeTMDBService(cache: makeDisabledCache()) { _ in
            .status(401, Data(#"{"status_message":"Invalid API key"}"#.utf8))
        }

        // An empty list here would read to the user as "no results for that
        // search" and hide a broken token indefinitely.
        await #expect(throws: TMDBError.self) {
            _ = try await service.search(query: "inception")
        }
    }

    @Test("A fresh cache hit costs no request at all")
    func freshCacheSkipsTheNetwork() async throws {
        let log = RequestLog()
        let cache = makeTemporaryCache()
        let service = makeTMDBService(log: log, cache: cache)

        _ = try await service.search(query: "inception")
        let afterFirst = log.count(containing: "search/multi")

        _ = try await service.search(query: "inception")
        let afterSecond = log.count(containing: "search/multi")

        #expect(afterFirst == 1)
        #expect(afterSecond == 1, "the second search must be served from cache")
    }

    @Test("Offline falls back to stale cache")
    func offlineServesStaleCache() async throws {
        let cache = makeTemporaryCache(ttl: 0)   // everything is stale immediately

        // Warm the cache while the network works.
        let online = makeTMDBService(cache: cache)
        let warmed = try await online.search(query: "inception")
        #expect(!warmed.isEmpty)

        // Same cache, network now unreachable.
        let offline = makeTMDBService(cache: cache) { _ in .transportFailure }
        let results = try await offline.search(query: "inception")

        // A week-old answer beats an empty screen — this is the whole reason
        // CatalogCache reports staleness rather than enforcing it.
        #expect(results.contains { $0.title == "Inception" })
    }

    @Test("Offline with a cold cache reports the failure")
    func offlineWithoutCacheThrows() async {
        let service = makeTMDBService(cache: makeTemporaryCache()) { _ in .transportFailure }

        await #expect(throws: (any Error).self) {
            _ = try await service.search(query: "inception")
        }
    }

    @Test("An HTTP error is never masked by stale cache")
    func httpErrorsBypassStaleFallback() async throws {
        let cache = makeTemporaryCache(ttl: 0)

        let online = makeTMDBService(cache: cache)
        _ = try await online.search(query: "inception")

        // The token has been revoked. Serving stale results would hide that
        // forever; only transport failures are allowed to fall back.
        let broken = makeTMDBService(cache: cache) { _ in
            .status(401, Data(#"{"status_message":"Invalid API key"}"#.utf8))
        }
        await #expect(throws: TMDBError.self) {
            _ = try await broken.search(query: "inception")
        }
    }
}

// MARK: - Catalog paging

@Suite("TMDBMediaService — popular titles")
@MainActor
struct TMDBPopularTitlesTests {

    @Test("Discover results take their type from the endpoint, not the payload")
    func discoverResultsGetTheirTypeFromTheEndpoint() async throws {
        let service = makeTMDBService()

        // `/discover/*` omits `media_type`; the endpoint already fixes it. A
        // mapper that relied on the payload alone would drop every result.
        let movies = try await service.popularTitles(type: .movie, page: 1)
        #expect(!movies.isEmpty)
        #expect(movies.allSatisfy { $0.type == .movie })

        let shows = try await service.popularTitles(type: .tvShow, page: 1)
        #expect(!shows.isEmpty)
        #expect(shows.allSatisfy { $0.type == .tvShow })
    }

    @Test("Running off the end of the catalog is empty, not an error")
    func pastTheLastPageIsEmpty() async throws {
        let results = try await makeTMDBService().popularTitles(type: .movie, page: 9)
        #expect(results.isEmpty)
    }

    @Test("A non-positive page is answered locally")
    func nonPositivePageCostsNothing() async throws {
        let log = RequestLog()
        let service = makeTMDBService(log: log)

        #expect(try await service.popularTitles(type: .movie, page: 0).isEmpty)
        #expect(log.count == 0)
    }
}

// MARK: - Configuration

@Suite("TMDBConfiguration")
struct TMDBConfigurationTests {

    @Test(
        "A build without a usable token has no configuration",
        arguments: ["", "   ", "\n", TMDBConfiguration.unsetPlaceholder]
    )
    func unusableTokensYieldNil(_ raw: String) {
        // Each of these is a real state: no secrets file at all, a file with an
        // empty value, and an unsubstituted build setting. All three must read
        // as "unconfigured" so the app falls back to the bundled catalog rather
        // than sending a nonsense Authorization header to TMDB.
        #expect(TMDBConfiguration.make(token: raw) == nil)
    }

    @Test("A real token is accepted and trimmed")
    func realTokenIsAccepted() {
        let configuration = TMDBConfiguration.make(token: "  eyJhbGciOiJIUzI1NiJ9.abc  ")
        #expect(configuration?.readToken == "eyJhbGciOiJIUzI1NiJ9.abc")
    }
}
