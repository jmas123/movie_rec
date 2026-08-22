//
//  TMDBDTOs.swift
//  WatchRank
//
//  Mirrors of the TMDB API's JSON shapes, plus the mapping from those shapes
//  to `MediaItem`. They are `Codable` rather than merely `Decodable` because
//  `CatalogCache` writes them back out to disk: the cache stores the API's
//  shape, and mapping to `MediaItem` happens on every read — a `@Model` must be
//  minted fresh per call, so caching mapped items would be wrong anyway.
//
//  Nothing outside `Services/` sees these types: the API's vocabulary stops at
//  this boundary, and the rest of the app only ever sees `MediaItem`.
//
//  TMDB's movie and TV payloads are similar enough to look interchangeable and
//  different enough to break code that assumes they are. The differences that
//  actually bite are called out at each site below.
//

import Foundation

// MARK: - Title payload

/// One title as it appears in `/search/multi`, `/discover/movie`, and
/// `/discover/tv`. The three endpoints return the same object shape; only
/// `mediaType` differs, and only `/search/multi` populates it.
struct TMDBTitleDTO: Codable {

    let id: Int

    /// Present on `/search/multi` results ("movie", "tv", "person"), absent on
    /// `/discover/*` where the endpoint itself already fixes the type.
    let mediaType: String?

    /// Movies carry `title`; TV carries `name`. Exactly one is populated, so
    /// both are optional here and resolved in `resolvedTitle`.
    let title: String?
    let name: String?

    /// Movies carry `release_date`; TV carries `first_air_date`. Both can be
    /// present-but-empty (`""`) for announced-but-undated titles — an empty
    /// string is not the same as a missing key, and both must survive decode.
    let releaseDate: String?
    let firstAirDate: String?

    let overview: String?
    let posterPath: String?
    let genreIds: [Int]?

    /// Popularity is not stored on `MediaItem` — it is TMDB's opinion, not the
    /// user's, and the whole point of this app is that the user's ranking is
    /// the only opinion that counts. It is decoded solely so the candidate
    /// pool builder can order pages deterministically.
    let popularity: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case mediaType = "media_type"
        case title
        case name
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case overview
        case posterPath = "poster_path"
        case genreIds = "genre_ids"
        case popularity
    }

    // MARK: Derived

    var resolvedTitle: String? {
        let candidate = title ?? name
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate
    }

    /// `nil` for a `person` result or an unrecognised `media_type`, which is
    /// how those get filtered out without a special case at the call site.
    var resolvedType: MediaType? {
        switch mediaType {
        case "movie": return .movie
        case "tv":    return .tvShow
        default:      return nil
        }
    }

    /// TMDB dates are `YYYY-MM-DD`, but the field is routinely `""` for
    /// unreleased titles and occasionally malformed. `Self.unknownYear` (0)
    /// records "no release date" without forcing `MediaItem.year` optional
    /// across the whole app for a case this rare.
    var resolvedYear: Int {
        let raw = releaseDate ?? firstAirDate ?? ""
        guard raw.count >= 4, let year = Int(raw.prefix(4)) else { return Self.unknownYear }
        return year
    }

    static let unknownYear = 0

    // MARK: Mapping

    /// Builds a detached `MediaItem`.
    ///
    /// - Parameters:
    ///   - fallbackType: used when the payload carries no `media_type`, i.e.
    ///     for `/discover/*` responses where the endpoint fixes the type.
    ///   - vocabulary: resolves TMDB genre ids to canonical genre names.
    /// - Returns: `nil` when the payload cannot make a usable item — a person
    ///   result, or a title with no name. Dropping is deliberate: a half-mapped
    ///   `MediaItem` would flow into the library and the ranking buckets.
    func makeMediaItem(
        fallbackType: MediaType? = nil,
        vocabulary: TMDBGenreVocabulary
    ) -> MediaItem? {
        guard let type = resolvedType ?? fallbackType else { return nil }
        guard let resolvedTitle else { return nil }

        return MediaItem(
            externalId: TMDBIdentifier.externalId(type: type, tmdbId: id),
            title: resolvedTitle,
            year: resolvedYear,
            type: type,
            overview: overview ?? "",
            posterURL: TMDBImage.posterURL(path: posterPath),
            genres: vocabulary.canonicalGenres(ids: genreIds ?? [], type: type)
        )
    }
}

// MARK: - Detail payload

/// `/movie/{id}` and `/tv/{id}`. Differs from the search/discover shape in one
/// way that matters: genres arrive as full objects rather than bare ids, so a
/// detail fetch does not need the genre vocabulary to have been loaded.
struct TMDBDetailDTO: Codable {

    let id: Int
    let title: String?
    let name: String?
    let releaseDate: String?
    let firstAirDate: String?
    let overview: String?
    let posterPath: String?
    let genres: [TMDBGenreDTO]?

    // MARK: Scalar metadata
    //
    // Cheap fields that ride along with the detail response. None of them cost
    // an extra request, which is the whole argument for `append_to_response`:
    // one call per watched title carries genres, keywords, credits, and all of
    // these together.

    /// Movies only, in minutes.
    let runtime: Int?

    /// TV only. An array because a show can have several typical lengths; the
    /// first entry is the representative one.
    let episodeRunTime: [Int]?

    let originalLanguage: String?
    let voteAverage: Double?

    /// Movies only. `nil` for a standalone film, which is most of them.
    let belongsToCollection: TMDBCollectionDTO?

    /// TV only.
    let networks: [TMDBNetworkDTO]?

    /// TV only. The showrunner(s). Used instead of a per-episode director
    /// credit, since episode directors vary week to week but the creator does
    /// not — a "favourite director" claim built from episode credits would be
    /// noise.
    let createdBy: [TMDBPersonDTO]?

    // MARK: Appended sub-responses

    /// From `append_to_response=credits` (movies).
    let credits: TMDBCreditsDTO?

    /// From `append_to_response=aggregate_credits` (TV). Rolls roles up across
    /// episodes with `total_episode_count`, which is the only sane basis for a
    /// TV cast credit — plain `/tv/{id}/credits` returns a snapshot that
    /// misrepresents who is actually in the show.
    let aggregateCredits: TMDBCreditsDTO?

    /// From `append_to_response=keywords`.
    let keywords: TMDBKeywordsDTO?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, genres, runtime, networks, credits, keywords
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
        case episodeRunTime = "episode_run_time"
        case originalLanguage = "original_language"
        case voteAverage = "vote_average"
        case belongsToCollection = "belongs_to_collection"
        case createdBy = "created_by"
        case aggregateCredits = "aggregate_credits"
    }

    func makeMediaItem(type: MediaType, vocabulary: TMDBGenreVocabulary) -> MediaItem? {
        let candidate = title ?? name
        guard let candidate, !candidate.isEmpty else { return nil }

        let raw = releaseDate ?? firstAirDate ?? ""
        let year = raw.count >= 4 ? (Int(raw.prefix(4)) ?? TMDBTitleDTO.unknownYear)
                                  : TMDBTitleDTO.unknownYear

        return MediaItem(
            externalId: TMDBIdentifier.externalId(type: type, tmdbId: id),
            title: candidate,
            year: year,
            type: type,
            overview: overview ?? "",
            posterURL: TMDBImage.posterURL(path: posterPath),
            genres: vocabulary.canonicalGenres(names: (genres ?? []).map(\.name)),
            features: features(type: type, vocabulary: vocabulary).keys,
            tmdbVoteAverage: voteAverage
        )
    }

    // MARK: Feature extraction

    /// Flattens the whole payload into the namespaced key space the predictor
    /// learns over.
    ///
    /// Every family is optional and independent: a title with no collection, no
    /// credits, and no keywords yields a shorter array, never an error. Sparse
    /// metadata is the normal case — obscure and older titles routinely have
    /// almost none of this — so absence is modelled as "fewer features", which
    /// is exactly what the confidence term in Phase 13 is for.
    func features(type: MediaType, vocabulary: TMDBGenreVocabulary) -> [Feature] {
        var out: [Feature] = []

        // Genres, normalized through the same vocabulary the catalog uses, so
        // a film's "Science Fiction" and a series' "Sci-Fi & Fantasy" land on
        // one feature rather than two.
        out += vocabulary.canonicalGenres(names: (genres ?? []).map(\.name)).map(Feature.genre)

        // Keywords, capped. TMDB returns up to a few dozen for well-tagged
        // titles; past the first several they get very specific ("bare-knuckle
        // boxing") and would swamp the denser families in the Step 3 mean.
        out += (keywords?.allKeywords.prefix(Self.keywordCap) ?? []).map {
            Feature.keyword(id: $0.id, name: $0.name)
        }

        if let era = Feature.era(year: resolvedYear(type: type)) { out.append(era) }
        if let runtime = Feature.runtime(minutes: representativeRuntime) { out.append(runtime) }
        if let language = originalLanguage, !language.isEmpty {
            out.append(Feature.language(language))
        }

        out += directorFeatures(type: type)
        out += composerFeatures(type: type)
        out += castFeatures(type: type)

        if type == .movie, let collection = belongsToCollection {
            out.append(Feature.franchise(id: collection.id, name: collection.name))
        }
        if type == .tvShow, let network = networks?.first {
            out.append(Feature.network(id: network.id, name: network.name))
        }

        return out
    }

    /// Top-billed cast to keep. Three is enough to capture "the film's leads"
    /// without storing the hundreds of people a TV `aggregate_credits` payload
    /// runs to.
    static let castCap = 3
    static let keywordCap = 10

    private var activeCredits: TMDBCreditsDTO? { credits ?? aggregateCredits }

    private var representativeRuntime: Int? {
        runtime ?? episodeRunTime?.first
    }

    private func resolvedYear(type: MediaType) -> Int {
        let raw = releaseDate ?? firstAirDate ?? ""
        guard raw.count >= 4, let year = Int(raw.prefix(4)) else {
            return TMDBTitleDTO.unknownYear
        }
        return year
    }

    private func directorFeatures(type: MediaType) -> [Feature] {
        // Television credits the creator, not the episode director.
        if type == .tvShow {
            if let creators = createdBy, !creators.isEmpty {
                return creators.map { Feature.director(id: $0.id, name: $0.name) }
            }
            return []
        }
        return (activeCredits?.crew ?? [])
            .filter { $0.holdsJob("Director") }
            .compactMap { crew in crew.name.map { Feature.director(id: crew.id, name: $0) } }
    }

    private func composerFeatures(type: MediaType) -> [Feature] {
        (activeCredits?.crew ?? [])
            .filter { $0.holdsJob("Original Music Composer") }
            .compactMap { crew in crew.name.map { Feature.composer(id: crew.id, name: $0) } }
    }

    private func castFeatures(type: MediaType) -> [Feature] {
        let cast = activeCredits?.cast ?? []

        // Film bills its cast in `order`; TV has no billing order that means
        // anything across a run, so episode count stands in for prominence.
        let ranked = type == .movie
            ? cast.sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            : cast.sorted { ($0.totalEpisodeCount ?? 0) > ($1.totalEpisodeCount ?? 0) }

        return ranked.prefix(Self.castCap).compactMap { member in
            member.name.map { Feature.castMember(id: member.id, name: $0) }
        }
    }
}

// MARK: - Supporting payloads

struct TMDBGenreDTO: Codable {
    let id: Int
    let name: String
}

/// `/genre/movie/list` and `/genre/tv/list`.
struct TMDBGenreListDTO: Codable {
    let genres: [TMDBGenreDTO]
}

/// A page of `/search/multi`, `/discover/movie`, or `/discover/tv`.
struct TMDBPageDTO: Codable {
    let page: Int?
    let results: [TMDBTitleDTO]
    let totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
    }
}

struct TMDBKeywordDTO: Codable {
    let id: Int
    let name: String
}

struct TMDBCollectionDTO: Codable {
    let id: Int
    let name: String
}

struct TMDBNetworkDTO: Codable {
    let id: Int
    let name: String
}

struct TMDBPersonDTO: Codable {
    let id: Int
    let name: String
}

/// Serves both `credits` (film) and `aggregate_credits` (television). The two
/// have the same top-level shape and differ only inside the entries.
struct TMDBCreditsDTO: Codable {
    let cast: [TMDBCastDTO]?
    let crew: [TMDBCrewDTO]?
}

struct TMDBCastDTO: Codable {
    let id: Int
    let name: String?

    /// Billing position. Film only — lower is more prominent.
    let order: Int?

    /// Episodes appeared in. Television only, from `aggregate_credits`.
    let totalEpisodeCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, order
        case totalEpisodeCount = "total_episode_count"
    }
}

struct TMDBCrewDTO: Codable {
    let id: Int
    let name: String?

    /// Film: one entry per job, so a person appears once per role they held.
    let job: String?

    /// Television: roles are rolled up, so one entry carries several jobs.
    let jobs: [TMDBJobDTO]?

    let totalEpisodeCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, job, jobs
        case totalEpisodeCount = "total_episode_count"
    }

    /// Checks both shapes, so a caller does not have to know which endpoint
    /// the payload came from.
    func holdsJob(_ wanted: String) -> Bool {
        if job == wanted { return true }
        return jobs?.contains { $0.job == wanted } ?? false
    }
}

struct TMDBJobDTO: Codable {
    let job: String?
}

/// The keyword endpoints for movies and TV return the **same data under
/// different keys**: `/movie/{id}/keywords` puts them in `keywords`, while
/// `/tv/{id}/keywords` puts them in `results`. Decoding both here means the
/// caller does not have to know which endpoint it hit.
/// `/search/keyword`. Distinct from `TMDBKeywordsDTO`, which is the `keywords`
/// block appended to a detail response — same element shape, different envelope.
struct TMDBKeywordSearchDTO: Codable {
    let results: [TMDBKeywordDTO]
}

struct TMDBKeywordsDTO: Codable {
    let keywords: [TMDBKeywordDTO]?
    let results: [TMDBKeywordDTO]?

    var allKeywords: [TMDBKeywordDTO] { keywords ?? results ?? [] }
}

/// `/find/{external_id}`. Results are split into one array per media type, so
/// a lookup can be constrained to the type the caller actually expects — an
/// IMDb id for a film and a series of the same name are different records, and
/// resolving one into the other would silently merge two library entries.
struct TMDBFindDTO: Codable {
    let movieResults: [TMDBTitleDTO]?
    let tvResults: [TMDBTitleDTO]?

    enum CodingKeys: String, CodingKey {
        case movieResults = "movie_results"
        case tvResults = "tv_results"
    }

    func firstID(for type: MediaType) -> Int? {
        switch type {
        case .movie:  return movieResults?.first?.id
        case .tvShow: return tvResults?.first?.id
        }
    }
}

// MARK: - Identifiers

/// TMDB ids are only unique **within** a media type: movie 1396 and TV 1396
/// are unrelated titles. `MediaLibraryViewModel.canonicalItem(for:)` dedupes
/// the user's library on `externalId` alone, so an id that omitted the type
/// would let a film silently collide with a series — the library would treat
/// them as one item and the comparison flow could pit a title against itself.
enum TMDBIdentifier {

    static func externalId(type: MediaType, tmdbId: Int) -> String {
        "tmdb:\(segment(for: type)):\(tmdbId)"
    }

    /// Parses an id produced by `externalId(type:tmdbId:)`. Returns `nil` for
    /// anything else — including the legacy IMDb-style ids (`tt1375666`) that
    /// predate the live catalog, which roadmap Phase 12a migrates.
    static func parse(_ externalId: String) -> (type: MediaType, tmdbId: Int)? {
        let parts = externalId.split(separator: ":")
        guard parts.count == 3, parts[0] == "tmdb", let id = Int(parts[2]) else { return nil }
        switch parts[1] {
        case "movie": return (.movie, id)
        case "tv":    return (.tvShow, id)
        default:      return nil
        }
    }

    /// TMDB's own path segment for a type — `tv`, not `tvShow`. Kept here so
    /// the URL builder and the identifier format cannot drift apart.
    static func segment(for type: MediaType) -> String {
        switch type {
        case .movie:  return "movie"
        case .tvShow: return "tv"
        }
    }
}

// MARK: - Images

enum TMDBImage {

    /// `w500` is the smallest size that still looks sharp on a 3x poster card;
    /// `original` would be several megabytes per title for no visible gain.
    static let posterSize = "w500"

    static func posterURL(path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return "https://image.tmdb.org/t/p/\(posterSize)\(path)"
    }
}
