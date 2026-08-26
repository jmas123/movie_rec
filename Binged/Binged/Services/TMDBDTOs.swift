//
//  TMDBDTOs.swift
//  Binged
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
    let voteAverage: Double?
    let voteCount: Int?

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
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
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
            genres: vocabulary.canonicalGenres(ids: genreIds ?? [], type: type),
            tmdbVoteAverage: voteAverage,
            tmdbVoteCount: voteCount
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

    // MARK: Display-only metadata
    //
    // Nothing below feeds the predictor — these are the facts the detail
    // screen shows and nothing persists. They ride along on the same request
    // rather than costing one of their own.

    /// The marketing one-liner. Empty string as often as absent, which is why
    /// `makeTitleDetails` normalises both to `nil`.
    let tagline: String?

    /// 16:9 still. Distinct from `posterPath` and much wider, so it needs its
    /// own image size — see `TMDBImage.backdropURL`.
    let backdropPath: String?

    /// How many votes `voteAverage` is over.
    let voteCount: Int?

    /// "Released", "Returning Series", "Ended", "Post Production".
    let status: String?

    /// TV only.
    let numberOfSeasons: Int?
    let numberOfEpisodes: Int?

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

    /// From `append_to_response=watch/providers`. The key really does contain a
    /// slash — it is a sub-path, not a name — which is why `CodingKeys` spells
    /// it out rather than relying on any conversion strategy.
    let watchProviders: TMDBWatchProvidersDTO?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, genres, runtime, networks, credits, keywords
        case tagline, status
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case episodeRunTime = "episode_run_time"
        case originalLanguage = "original_language"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case numberOfSeasons = "number_of_seasons"
        case numberOfEpisodes = "number_of_episodes"
        case belongsToCollection = "belongs_to_collection"
        case createdBy = "created_by"
        case aggregateCredits = "aggregate_credits"
        case watchProviders = "watch/providers"
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
            tmdbVoteAverage: voteAverage,
            tmdbVoteCount: voteCount
        )
    }

    // MARK: Display mapping

    /// Builds the screen-facing view of this payload.
    ///
    /// Separate from `makeMediaItem` because the two have different lifetimes:
    /// a `MediaItem` is persisted and synced, while this is refetched whenever
    /// the screen is opened. Sharing one mapping would mean every field added
    /// for display became a column somebody had to migrate.
    ///
    /// - Parameter region: ISO 3166-1 country code for the watch-provider
    ///   lookup. Availability is per country, so passing the wrong one is worse
    ///   than passing none: it would confidently list services the user cannot
    ///   subscribe to.
    func makeTitleDetails(type: MediaType, region: String) -> TitleDetails {
        let providers = watchProviders?.results?[region]

        return TitleDetails(
            tagline: nonEmpty(tagline),
            runtimeMinutes: representativeRuntime.flatMap { $0 > 0 ? $0 : nil },
            backdropURL: TMDBImage.backdropURL(path: backdropPath),
            voteAverage: (voteAverage ?? 0) > 0 ? voteAverage : nil,
            voteCount: voteCount,
            status: nonEmpty(status),
            originalLanguage: nonEmpty(originalLanguage),
            seasonCount: type == .tvShow ? numberOfSeasons : nil,
            episodeCount: type == .tvShow ? numberOfEpisodes : nil,
            releaseDateText: nonEmpty(releaseDate ?? firstAirDate),
            directors: directorCredits(type: type),
            cast: castCredits(type: type),
            streamingProviders: (providers?.includedWithSubscription ?? []).map {
                TitleDetails.Provider(
                    id: String($0.providerId),
                    name: $0.providerName,
                    logoURL: TMDBImage.logoURL(path: $0.logoPath)
                )
            },
            providerLink: nonEmpty(providers?.link)
        )
    }

    /// Names to show above the cast. Reuses the same film-versus-television
    /// rule as `directorFeatures` — the creator for a series, the director for
    /// a film — so the screen and the predictor never disagree about who made
    /// something.
    private func directorCredits(type: MediaType) -> [TitleDetails.Person] {
        if type == .tvShow {
            return (createdBy ?? []).map {
                TitleDetails.Person(id: String($0.id), name: $0.name, role: "Creator")
            }
        }
        return (activeCredits?.crew ?? [])
            .filter { $0.holdsJob("Director") }
            .compactMap { crew in
                crew.name.map {
                    TitleDetails.Person(
                        id: String(crew.id),
                        name: $0,
                        role: "Director",
                        imageURL: TMDBImage.profileURL(path: crew.profilePath)
                    )
                }
            }
    }

    /// Top-billed cast for display.
    ///
    /// A wider cap than `castCap`: three names is the right amount of *signal*
    /// for the predictor and a thin-looking row on a screen the user opened to
    /// read about a film. The two numbers answer different questions, so they
    /// are allowed to differ.
    private func castCredits(type: MediaType) -> [TitleDetails.Person] {
        let cast = activeCredits?.cast ?? []
        let ranked = type == .movie
            ? cast.sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            : cast.sorted { ($0.totalEpisodeCount ?? 0) > ($1.totalEpisodeCount ?? 0) }

        return ranked.prefix(Self.displayCastCap).compactMap { member in
            member.name.map {
                TitleDetails.Person(
                    id: String(member.id),
                    name: $0,
                    role: member.displayCharacter,
                    imageURL: TMDBImage.profileURL(path: member.profilePath)
                )
            }
        }
    }

    /// How many cast members the detail screen shows. Ten fills a horizontal
    /// strip on the widest phone without asking the user to scroll past
    /// uncredited extras.
    static let displayCastCap = 10

    /// TMDB returns `""` about as often as it omits a key, and an empty string
    /// renders as an empty line rather than as nothing.
    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    /// Who they played. Film only: `aggregate_credits` rolls a performer's
    /// parts into `roles` instead, since a soap actor can play three.
    let character: String?

    /// Television only, from `aggregate_credits`.
    let roles: [TMDBRoleDTO]?

    /// Headshot. Absent for a great many credited people, which is why the
    /// cast strip draws initials rather than leaving a hole.
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, order, character, roles
        case totalEpisodeCount = "total_episode_count"
        case profilePath = "profile_path"
    }

    /// The character to print, whichever endpoint this came from. Prefers the
    /// most-seen role for television, since a series lead with 60 episodes and
    /// a one-scene cameo are both entries in `roles`.
    var displayCharacter: String? {
        if let character, !character.isEmpty { return character }
        let best = (roles ?? [])
            .filter { !($0.character ?? "").isEmpty }
            .max { ($0.episodeCount ?? 0) < ($1.episodeCount ?? 0) }
        return best?.character
    }
}

/// One part a performer played across a run. Television only.
struct TMDBRoleDTO: Codable {
    let character: String?
    let episodeCount: Int?

    enum CodingKeys: String, CodingKey {
        case character
        case episodeCount = "episode_count"
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

    /// Headshot, same caveat as the cast's.
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, job, jobs
        case totalEpisodeCount = "total_episode_count"
        case profilePath = "profile_path"
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

// MARK: - Watch providers

/// `append_to_response=watch/providers`.
///
/// TMDB licenses this from JustWatch, which imposes two rules the shape makes
/// unavoidable: availability is **per region**, and the data may not be shown
/// without a link back to the JustWatch page TMDB supplies as `link`. Both are
/// why `TitleDetails` carries `providerLink` rather than only a list of names.
struct TMDBWatchProvidersDTO: Codable {

    /// Keyed by ISO 3166-1 country code. A title carries entries only for
    /// regions it is available in, so a miss is "not streaming here" rather
    /// than an error.
    let results: [String: TMDBRegionProvidersDTO]?
}

struct TMDBRegionProvidersDTO: Codable {

    /// The JustWatch page for this title and region.
    let link: String?

    /// Included with a subscription. Kept apart from `rent`/`buy` on purpose —
    /// see `TitleDetails.streamingProviders`.
    let flatrate: [TMDBProviderDTO]?

    /// Free with ads, and free outright. Folded in with `flatrate` for display
    /// because both answer "yes, tonight, at no extra cost".
    let ads: [TMDBProviderDTO]?
    let free: [TMDBProviderDTO]?

    /// Decoded but deliberately not displayed.
    let rent: [TMDBProviderDTO]?
    let buy: [TMDBProviderDTO]?

    /// Subscription-equivalent options, deduplicated by provider id and in
    /// TMDB's own display order.
    var includedWithSubscription: [TMDBProviderDTO] {
        var seen: Set<Int> = []
        return ((flatrate ?? []) + (free ?? []) + (ads ?? []))
            .filter { seen.insert($0.providerId).inserted }
            .sorted { ($0.displayPriority ?? .max) < ($1.displayPriority ?? .max) }
    }
}

struct TMDBProviderDTO: Codable {
    let providerId: Int
    let providerName: String
    let logoPath: String?

    /// TMDB's own ordering hint — roughly "how likely is this the one you
    /// meant". Used so Netflix outranks a regional reseller.
    let displayPriority: Int?

    enum CodingKeys: String, CodingKey {
        case providerId = "provider_id"
        case providerName = "provider_name"
        case logoPath = "logo_path"
        case displayPriority = "display_priority"
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

    /// Backdrops are shown full-bleed across the screen, so they need a wider
    /// source than a poster tile; profile shots and provider logos are drawn
    /// small and would waste bandwidth at any larger size.
    static let backdropSize = "w780"
    static let profileSize = "w185"
    static let logoSize = "w92"

    static func posterURL(path: String?) -> String? {
        url(path: path, size: posterSize)
    }

    static func backdropURL(path: String?) -> String? {
        url(path: path, size: backdropSize)
    }

    static func profileURL(path: String?) -> String? {
        url(path: path, size: profileSize)
    }

    static func logoURL(path: String?) -> String? {
        url(path: path, size: logoSize)
    }

    private static func url(path: String?, size: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return "https://image.tmdb.org/t/p/\(size)\(path)"
    }

    /// The inverse: recovers TMDB's `/abc.jpg` from a URL this type built.
    ///
    /// Needed because `MediaItem` stores the rendered URL while `ranked_items`
    /// stores a `poster_path`. Round-tripping the *path* rather than the URL
    /// keeps the column honest and survives a change of image host or size —
    /// a stored `w500` URL would pin every synced row to today's choice.
    ///
    /// Returns `nil` for anything it did not build, so a hand-set or
    /// already-relative value is passed through untouched by the caller rather
    /// than mangled.
    static func posterPath(fromURL url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        guard url.hasPrefix("https://image.tmdb.org/t/p/") else {
            // Already a path, or something we do not recognise.
            return url.hasPrefix("/") ? url : nil
        }
        let file = (url as NSString).lastPathComponent
        return file.isEmpty ? nil : "/" + file
    }
}
