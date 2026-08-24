//
//  TMDBTestSupport.swift
//  BingedTests
//
//  A fake network for `TMDBMediaService`, plus the recorded TMDB payloads the
//  tests run against.
//
//  No test in this suite may touch the real network. A suite that did would
//  fail on a plane, fail in CI without a token, fail when TMDB has an incident,
//  and fail differently depending on what happens to be popular this week —
//  four failure modes that have nothing to do with the code under test.
//
//  `StubURLProtocol` keys its handlers by a per-session header rather than
//  parking one in a global. Swift Testing runs tests in parallel inside a single
//  process, so a shared mutable handler would have tests answering each other's
//  requests — an intermittent failure that looks like a caching bug.
//

import Foundation
import Testing
@testable import Binged

// MARK: - StubURLProtocol

final class StubURLProtocol: URLProtocol {

    /// What a stub does with one request: answer it, or fail it the way the
    /// transport would.
    typealias Handler = @Sendable (URLRequest) -> Response

    enum Response {
        case ok(Data)
        case status(Int, Data)

        /// A transport-level failure — offline, DNS, timeout. Distinct from an
        /// HTTP status, and the service treats the two very differently: only
        /// this one falls back to stale cache.
        case transportFailure
    }

    // MARK: Registry

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static let handlerHeader = "X-Binged-Stub"

    /// A `URLSession` whose requests route to `handler` and nowhere else.
    /// `ephemeral` so URLSession's own cache never masks a cache bug in
    /// `CatalogCache` — the layer actually under test.
    static func makeSession(handler: @escaping Handler) -> URLSession {
        let key = UUID().uuidString

        lock.lock()
        handlers[key] = handler
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [handlerHeader: key]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private static func handler(for request: URLRequest) -> Handler? {
        guard let key = request.value(forHTTPHeaderField: handlerHeader) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return handlers[key]
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        handler(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch handler(request) {
        case .ok(let data):
            respond(url: url, status: 200, data: data)
        case .status(let code, let data):
            respond(url: url, status: code, data: data)
        case .transportFailure:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    override func stopLoading() {}

    private func respond(url: URL, status: Int, data: Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Request recording

/// Counts what the service actually asked for, so a test can assert that a
/// cache hit meant *no request was made* rather than merely that the answer
/// looked right. A cache that silently re-fetches every time still returns
/// correct data.
final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []

    private var _urls: [String] = []

    func record(_ request: URLRequest) {
        guard let url = request.url else { return }
        lock.lock()
        _paths.append(url.path)
        _urls.append(url.absoluteString)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _paths
    }

    var count: Int { paths.count }

    func count(containing fragment: String) -> Int {
        paths.filter { $0.contains(fragment) }.count
    }

    /// Full URLs including the query.
    ///
    /// `paths` alone cannot tell two `/discover/movie` requests apart, and the
    /// whole difference between a mood's genre component and its keyword
    /// component lives in the query string.
    var urls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _urls
    }

    func count(inQuery fragment: String) -> Int {
        urls.filter { $0.contains(fragment) }.count
    }
}

// MARK: - Service assembly

/// Builds a service wired to `TMDBFixtures.defaultHandler`, with a cache in a
/// throwaway directory unique to this test.
///
/// Each test gets its own cache directory: `CatalogCache` writes to
/// Application Support by default, and tests sharing that would leak state into
/// each other and into the simulator's real app data.
@MainActor
func makeTMDBService(
    log: RequestLog? = nil,
    cache: CatalogCache = makeTemporaryCache(),
    handler: @escaping StubURLProtocol.Handler = TMDBFixtures.defaultHandler
) -> TMDBMediaService {
    let session = StubURLProtocol.makeSession { request in
        log?.record(request)
        return handler(request)
    }
    return TMDBMediaService(
        configuration: TMDBConfiguration(readToken: "test-token"),
        session: session,
        cache: cache
    )
}

/// A cache rooted in a unique temp directory. Left on disk after the test — the
/// OS reclaims the temp directory, and keeping it makes a failure inspectable.
func makeTemporaryCache(ttl: TimeInterval = CatalogCache.defaultTTL) -> CatalogCache {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BingedTests-\(UUID().uuidString)", isDirectory: true)
    return CatalogCache(directory: directory, ttl: ttl)
}

/// A cache that never persists, for tests that want every call to reach the
/// stub network.
func makeDisabledCache() -> CatalogCache {
    CatalogCache(directory: nil)
}

// MARK: - Fixtures

/// Recorded TMDB payloads, trimmed to the fields the app decodes.
///
/// These are hand-reduced rather than verbatim captures: a real `/search/multi`
/// response carries thirty fields per result, and the twenty-five the app
/// ignores would only make the interesting ones harder to find. Every field the
/// decoder reads is present, including the ones that are awkward on purpose —
/// the empty `release_date`, the person result, the TV payload that uses `name`
/// where the movie one uses `title`.
enum TMDBFixtures {

    // MARK: Routing

    /// Routes by URL path, the way the real API does.
    static let defaultHandler: StubURLProtocol.Handler = { request in
        guard let url = request.url else { return .transportFailure }
        let path = url.path
        let query = url.query ?? ""

        if path.hasSuffix("/genre/movie/list") { return .ok(Data(movieGenreList.utf8)) }
        if path.hasSuffix("/genre/tv/list")    { return .ok(Data(tvGenreList.utf8)) }

        if path.hasSuffix("/search/multi") {
            return .ok(Data(searchMulti.utf8))
        }

        // /find/{imdb_id}: known ids resolve, everything else comes back with
        // every array present and empty — which is what TMDB actually does, and
        // is not the same as a 404.
        if path.contains("/find/") {
            if path.hasSuffix("/find/tt1375666") { return .ok(Data(findMovie.utf8)) }
            if path.hasSuffix("/find/tt0903747") { return .ok(Data(findTV.utf8)) }
            return .ok(Data(findEmpty.utf8))
        }

        // The feature fetch hits the same path as a plain detail fetch and is
        // told apart only by append_to_response — exactly the collision the
        // separate `features:` cache key exists to prevent.
        let wantsFeatures = query.contains("append_to_response")

        if path.hasSuffix("/movie/27205") {
            return .ok(Data((wantsFeatures ? movieDetailWithFeatures : movieDetail).utf8))
        }
        if path.hasSuffix("/tv/1396") {
            return .ok(Data((wantsFeatures ? tvDetailWithFeatures : tvDetail).utf8))
        }
        // A title TMDB knows nothing else about: no credits, no keywords, no
        // runtime, no collection. Sparse metadata is the normal case.
        if path.hasSuffix("/movie/31111") {
            return .ok(Data(sparseMovieDetail.utf8))
        }

        // Anything else under /movie/ or /tv/ is a title that does not exist.
        if path.contains("/movie/") || path.contains("/tv/") {
            return .status(404, Data(notFound.utf8))
        }

        if path.hasSuffix("/discover/movie") {
            // Page 1 has results, later pages are empty — so a paging test can
            // reach the end of the catalog the way the real API ends it.
            let body = query.contains("page=1") ? discoverMovies : emptyPage
            return .ok(Data(body.utf8))
        }
        if path.hasSuffix("/discover/tv") {
            let body = query.contains("page=1") ? discoverTV : emptyPage
            return .ok(Data(body.utf8))
        }

        return .status(404, Data(notFound.utf8))
    }

    // MARK: Genre tables

    /// Trimmed to the entries the tests exercise, including the three that
    /// normalization has to reconcile between the two vocabularies.
    static let movieGenreList = """
    {"genres":[
      {"id":18,"name":"Drama"},
      {"id":80,"name":"Crime"},
      {"id":878,"name":"Science Fiction"},
      {"id":28,"name":"Action"},
      {"id":12,"name":"Adventure"},
      {"id":14,"name":"Fantasy"},
      {"id":53,"name":"Thriller"},
      {"id":27,"name":"Horror"}
    ]}
    """

    static let tvGenreList = """
    {"genres":[
      {"id":18,"name":"Drama"},
      {"id":80,"name":"Crime"},
      {"id":10765,"name":"Sci-Fi & Fantasy"},
      {"id":10759,"name":"Action & Adventure"},
      {"id":10768,"name":"War & Politics"},
      {"id":10762,"name":"Kids"}
    ]}
    """

    // MARK: Search

    /// Deliberately mixed: a movie, a TV show, and a person. The person result
    /// is the one that must never reach a `MediaItem`.
    static let searchMulti = """
    {"page":1,"total_pages":1,"results":[
      {"id":27205,"media_type":"movie","title":"Inception","release_date":"2010-07-15",
       "overview":"A thief who steals corporate secrets through dream-sharing technology.",
       "poster_path":"/inception.jpg","genre_ids":[28,878,12],"popularity":82.4},
      {"id":1396,"media_type":"tv","name":"Breaking Bad","first_air_date":"2008-01-20",
       "overview":"A chemistry teacher turns to manufacturing methamphetamine.",
       "poster_path":"/bb.jpg","genre_ids":[18,80],"popularity":310.1},
      {"id":6193,"media_type":"person","name":"Leonardo DiCaprio",
       "profile_path":"/leo.jpg","popularity":45.2},
      {"id":99999,"media_type":"movie","title":"Untitled Sequel","release_date":"",
       "overview":"Announced but undated.","poster_path":null,"genre_ids":[18],"popularity":1.0}
    ]}
    """

    // MARK: Detail

    static let movieDetail = """
    {"id":27205,"title":"Inception","release_date":"2010-07-15",
     "overview":"A thief who steals corporate secrets through dream-sharing technology.",
     "poster_path":"/inception.jpg",
     "genres":[{"id":28,"name":"Action"},{"id":878,"name":"Science Fiction"}]}
    """

    static let tvDetail = """
    {"id":1396,"name":"Breaking Bad","first_air_date":"2008-01-20",
     "overview":"A chemistry teacher turns to manufacturing methamphetamine.",
     "poster_path":"/bb.jpg",
     "genres":[{"id":18,"name":"Drama"},{"id":80,"name":"Crime"}]}
    """

    // MARK: Find (external id resolution)

    /// Verified against the live API 2026-08-21: the response always carries all
    /// five arrays, and the type-specific one is what makes a constrained
    /// lookup possible.
    static let findMovie = """
    {"movie_results":[{"id":27205,"title":"Inception","release_date":"2010-07-15",
      "overview":"","poster_path":"/inception.jpg","genre_ids":[28,878]}],
     "person_results":[],"tv_results":[],"tv_episode_results":[],"tv_season_results":[]}
    """

    static let findTV = """
    {"movie_results":[],"person_results":[],
     "tv_results":[{"id":1396,"name":"Breaking Bad","first_air_date":"2008-01-20",
      "overview":"","poster_path":"/bb.jpg","genre_ids":[18,80]}],
     "tv_episode_results":[],"tv_season_results":[]}
    """

    static let findEmpty = """
    {"movie_results":[],"person_results":[],"tv_results":[],
     "tv_episode_results":[],"tv_season_results":[]}
    """

    // MARK: Detail with appended credits and keywords

    /// A film detail response with `append_to_response=credits,keywords`.
    /// Film credits carry one `job` per crew entry and bill cast by `order`.
    static let movieDetailWithFeatures = """
    {"id":27205,"title":"Inception","release_date":"2010-07-15",
     "overview":"A thief who steals corporate secrets through dream-sharing technology.",
     "poster_path":"/inception.jpg","runtime":148,"original_language":"en",
     "vote_average":8.4,
     "genres":[{"id":28,"name":"Action"},{"id":878,"name":"Science Fiction"}],
     "belongs_to_collection":{"id":86311,"name":"The Nolan Collection"},
     "keywords":{"keywords":[
       {"id":4565,"name":"dystopia"},{"id":9826,"name":"heist"},{"id":3358,"name":"dream"}
     ]},
     "credits":{
       "cast":[
         {"id":6193,"name":"Leonardo DiCaprio","order":0},
         {"id":24045,"name":"Joseph Gordon-Levitt","order":1},
         {"id":27578,"name":"Elliot Page","order":2},
         {"id":2524,"name":"Tom Hardy","order":3}
       ],
       "crew":[
         {"id":525,"name":"Christopher Nolan","job":"Director"},
         {"id":947,"name":"Hans Zimmer","job":"Original Music Composer"},
         {"id":525,"name":"Christopher Nolan","job":"Writer"}
       ]
     }}
    """

    /// A television detail response with `append_to_response=aggregate_credits,keywords`.
    ///
    /// Three shapes differ from film and each would silently yield nothing if
    /// the decoder assumed the film form: keywords nest under `results`, crew
    /// entries carry a `jobs` array instead of a `job` string, and cast is
    /// ranked by `total_episode_count` because TV has no meaningful billing
    /// order. The director comes from `created_by`, not the crew list.
    static let tvDetailWithFeatures = """
    {"id":1396,"name":"Breaking Bad","first_air_date":"2008-01-20",
     "overview":"A chemistry teacher turns to manufacturing methamphetamine.",
     "poster_path":"/bb.jpg","episode_run_time":[47],"original_language":"en",
     "vote_average":8.9,
     "genres":[{"id":18,"name":"Drama"},{"id":80,"name":"Crime"}],
     "networks":[{"id":174,"name":"AMC"},{"id":213,"name":"Netflix"}],
     "created_by":[{"id":66633,"name":"Vince Gilligan"}],
     "keywords":{"results":[
       {"id":1701,"name":"drug dealer"},{"id":10714,"name":"neo-noir"}
     ]},
     "aggregate_credits":{
       "cast":[
         {"id":17419,"name":"Bryan Cranston","total_episode_count":62},
         {"id":84497,"name":"Aaron Paul","total_episode_count":62},
         {"id":134531,"name":"Anna Gunn","total_episode_count":62},
         {"id":1213786,"name":"Lavell Crawford","total_episode_count":9}
       ],
       "crew":[
         {"id":66633,"name":"Vince Gilligan",
          "jobs":[{"job":"Executive Producer"},{"job":"Director"}],
          "total_episode_count":5},
         {"id":1216306,"name":"Dave Porter",
          "jobs":[{"job":"Original Music Composer"}],"total_episode_count":62}
       ]
     }}
    """

    /// Everything optional, absent. A title like this must still yield a valid
    /// — merely shorter — feature array.
    static let sparseMovieDetail = """
    {"id":31111,"title":"Forgotten Reel","release_date":"1953-04-02",
     "overview":"","poster_path":null,"genres":[]}
    """

    // MARK: Discover

    static let discoverMovies = """
    {"page":1,"total_pages":2,"results":[
      {"id":27205,"title":"Inception","release_date":"2010-07-15","overview":"",
       "poster_path":"/inception.jpg","genre_ids":[28,878],"popularity":82.4},
      {"id":155,"title":"The Dark Knight","release_date":"2008-07-16","overview":"",
       "poster_path":"/tdk.jpg","genre_ids":[18,80,28],"popularity":95.1}
    ]}
    """

    static let discoverTV = """
    {"page":1,"total_pages":2,"results":[
      {"id":1396,"name":"Breaking Bad","first_air_date":"2008-01-20","overview":"",
       "poster_path":"/bb.jpg","genre_ids":[18,80],"popularity":310.1},
      {"id":1399,"name":"Game of Thrones","first_air_date":"2011-04-17","overview":"",
       "poster_path":"/got.jpg","genre_ids":[10765,10759],"popularity":220.7}
    ]}
    """

    static let emptyPage = """
    {"page":9,"total_pages":2,"results":[]}
    """

    static let notFound = """
    {"success":false,"status_code":34,"status_message":"The resource you requested could not be found."}
    """
}
