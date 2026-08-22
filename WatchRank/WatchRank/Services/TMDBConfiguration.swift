//
//  TMDBConfiguration.swift
//  WatchRank
//
//  Where the TMDB credential comes from, and what happens when it is absent.
//
//  The token is injected at build time: `Config/Secrets.xcconfig` (gitignored)
//  defines `TMDB_READ_TOKEN`, `Config/Base.xcconfig` maps it into the generated
//  Info.plist, and this type reads it back at runtime. A checkout without the
//  secrets file still builds — `Base.xcconfig` includes it optionally — and
//  simply has no token, which is a supported state rather than a broken one:
//  the app falls back to `MockMediaService` and stays fully usable offline.
//
//  See `Config/Secrets.xcconfig.example` for the file to create.
//

import Foundation

// MARK: - TMDBConfiguration

struct TMDBConfiguration: Equatable {

    /// TMDB v4 read access token, sent as `Authorization: Bearer …`.
    ///
    /// The v4 token is used rather than the v3 `api_key` query parameter so the
    /// credential never appears in a URL — URLs end up in logs, in crash
    /// reports, and in `URLSession` metrics, and a query-string secret leaks
    /// into all three.
    let readToken: String

    // MARK: Info.plist key

    /// Must match the key in `Config/Info.plist`, which `Base.xcconfig` fills
    /// from `TMDB_READ_TOKEN`.
    static let infoPlistKey = "TMDBReadToken"

    /// The value `Base.xcconfig` produces when no secrets file is present.
    /// Treated as absent rather than as a token, so a misconfigured build
    /// fails the same way a deliberately unconfigured one does.
    static let unsetPlaceholder = "$(TMDB_READ_TOKEN)"

    // MARK: Loading

    /// Reads the token from the app bundle. Returns `nil` — never throws, never
    /// traps — when the app was built without one.
    ///
    /// A missing credential is a routine state during development, so it must
    /// not be a force-unwrap or a `fatalError`; `WatchRankApp` reads `nil` as
    /// "use the bundled catalog".
    static func fromBundle(_ bundle: Bundle = .main) -> TMDBConfiguration? {
        guard let raw = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            return nil
        }
        return make(token: raw)
    }

    /// Split out from `fromBundle` so tests can exercise the validation rules
    /// without building a bundle.
    static func make(token raw: String) -> TMDBConfiguration? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != unsetPlaceholder else { return nil }
        return TMDBConfiguration(readToken: trimmed)
    }
}

// MARK: - Endpoints

/// URL construction for the TMDB v3 REST API. Kept separate from the service so
/// the URL shapes can be asserted directly in tests without a network stub.
enum TMDBEndpoint {

    static let baseURL = URL(string: "https://api.themoviedb.org/3")

    /// Builds `path` under the API base with `queryItems` appended.
    /// Returns `nil` rather than force-unwrapping a malformed URL.
    static func url(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard let baseURL else { return nil }
        let full = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: full, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    static func searchMulti(query: String, page: Int = 1) -> URL? {
        url(path: "search/multi", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "include_adult", value: "false"),
        ])
    }

    static func detail(type: MediaType, tmdbId: Int) -> URL? {
        url(path: "\(TMDBIdentifier.segment(for: type))/\(tmdbId)")
    }

    /// A detail request with credits and keywords appended, so extracting the
    /// full feature set for one title costs a single round trip rather than
    /// three.
    ///
    /// Television needs `aggregate_credits` rather than `credits`: the latter
    /// is an episode-level snapshot, while the former rolls roles up across the
    /// run with `total_episode_count` — the only figure that says who is
    /// actually in a show.
    static func detailWithFeatures(type: MediaType, tmdbId: Int) -> URL? {
        let credits = type == .movie ? "credits" : "aggregate_credits"
        return url(
            path: "\(TMDBIdentifier.segment(for: type))/\(tmdbId)",
            queryItems: [URLQueryItem(name: "append_to_response", value: "\(credits),keywords")]
        )
    }

    /// Resolves an external id — here always an IMDb id — to TMDB's own.
    /// The response splits results by media type, which is what lets the
    /// migration insist a film resolves to a film.
    static func find(imdbID: String) -> URL? {
        url(path: "find/\(imdbID)", queryItems: [
            URLQueryItem(name: "external_source", value: "imdb_id"),
        ])
    }

    static func genreList(type: MediaType) -> URL? {
        url(path: "genre/\(TMDBIdentifier.segment(for: type))/list")
    }

    /// A page of popular titles.
    ///
    /// `vote_count.gte` matters more than it looks: sorting by popularity with
    /// no vote floor surfaces newly-added junk entries with a handful of votes
    /// and a high transient popularity score. The floor differs by type because
    /// television accumulates far fewer votes than film.
    static func discover(type: MediaType, page: Int) -> URL? {
        discover(type: type, page: page, extra: [])
    }

    /// A page of one component of a mood.
    ///
    /// Takes a single component rather than a whole mood because TMDB AND-s
    /// different `/discover` parameters: `with_genres` and `with_keywords`
    /// together mean "genre AND keyword", never "OR". A mood spanning both
    /// bases is two calls whose results are unioned by the caller — see
    /// `MoodQueryComponent`.
    static func discover(type: MediaType, component: MoodQueryComponent, page: Int) -> URL? {
        guard !component.isEmpty else { return nil }

        // `|` is OR within a parameter; `,` would be AND. Percent-encoding is
        // applied by URLComponents, so the raw pipe is correct here.
        let value = component.ids.map(String.init).joined(separator: "|")
        let name: String
        switch component.basis {
        case .genres:   name = "with_genres"
        case .keywords: name = "with_keywords"
        }

        return discover(
            type: type,
            page: page,
            voteFloor: component.minimumVotes,
            extra: [URLQueryItem(name: name, value: value)]
        )
    }

    private static func discover(
        type: MediaType,
        page: Int,
        voteFloor: Int? = nil,
        extra: [URLQueryItem]
    ) -> URL? {
        let floor = voteFloor ?? defaultVoteFloor(for: type)
        return url(path: "discover/\(TMDBIdentifier.segment(for: type))", queryItems: [
            URLQueryItem(name: "sort_by", value: "popularity.desc"),
            URLQueryItem(name: "vote_count.gte", value: String(floor)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "include_adult", value: "false"),
        ] + extra)
    }

    static func defaultVoteFloor(for type: MediaType) -> Int {
        type == .movie ? 300 : 100
    }

    /// Resolves a keyword name to TMDB's id.
    ///
    /// Not on the app's cold-start path: `Mood` carries measured ids already,
    /// so this exists to *refresh* and verify them rather than to bootstrap
    /// them. A failure here costs nothing at runtime.
    static func searchKeyword(_ name: String) -> URL? {
        url(path: "search/keyword", queryItems: [
            URLQueryItem(name: "query", value: name),
        ])
    }
}

// MARK: - Errors

enum TMDBError: Error, Equatable, CustomStringConvertible {

    /// The app was built without a token. Distinct from a network failure: no
    /// amount of retrying fixes it, and the UI should say so.
    case missingCredentials

    /// A URL could not be built — a programming error, surfaced rather than
    /// force-unwrapped.
    case malformedURL

    /// TMDB answered with a non-2xx status. 401 means the token is wrong,
    /// 404 means the title does not exist, 429 means rate limited.
    case http(status: Int)

    /// The response body did not match the expected shape.
    case decoding(String)

    var description: String {
        switch self {
        case .missingCredentials:
            return "No TMDB token. Create Config/Secrets.xcconfig from the .example file."
        case .malformedURL:
            return "TMDB: could not build a request URL."
        case .http(let status):
            switch status {
            case 401: return "TMDB rejected the token (401). Check TMDB_READ_TOKEN."
            case 429: return "TMDB rate limit reached (429)."
            default:  return "TMDB returned HTTP \(status)."
            }
        case .decoding(let detail):
            return "TMDB response could not be decoded: \(detail)"
        }
    }

    /// Whether retrying could plausibly succeed. Drives whether the UI offers
    /// a retry affordance or just explains the situation.
    var isRetryable: Bool {
        switch self {
        case .missingCredentials, .malformedURL, .decoding:
            return false
        case .http(let status):
            return status == 429 || (500...599).contains(status)
        }
    }
}
