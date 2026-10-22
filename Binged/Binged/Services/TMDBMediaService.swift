//
//  TMDBMediaService.swift
//  Binged
//
//  The live catalog. Conforms to `MediaService`, so nothing outside this file
//  learns that the app stopped reading a bundled JSON and started talking to a
//  web API — `SearchViewModel`, `HomeView`, and the rest are untouched.
//
//  Three behaviours are worth knowing before reading the code:
//
//  1. **Every request goes through the cache.** A fresh cached response short-
//     circuits the network entirely; a network failure falls back to a stale
//     one. That single rule is what makes the app usable on a plane, and it is
//     implemented once in `get(_:cacheKey:)` rather than per endpoint.
//
//  2. **The genre vocabulary is loaded lazily, once.** Genre ids are fetched
//     from TMDB rather than hardcoded, so mapping a search result needs the
//     tables in hand. They are cached with the same TTL as everything else.
//
//  3. **Failures degrade rather than propagate where they can.** A missing
//     genre table costs a result its genres; it does not fail the search.
//

import Foundation

// MARK: - TMDBMediaService

final class TMDBMediaService: MediaService, CandidateSource, @unchecked Sendable {

    // MARK: Dependencies

    private let configuration: TMDBConfiguration
    private let session: URLSession
    private let cache: CatalogCache

    /// Loaded on first use and reused.
    ///
    /// Guarded by a lock rather than left bare: `FeatureProvider` fans requests
    /// out across a task group, so this really is touched from several threads.
    /// The lock is never held across an `await` — it guards the two accessors
    /// below and nothing else, which is what keeps that guarantee checkable.
    private let vocabularyLock = NSLock()
    private var _vocabulary: TMDBGenreVocabulary?

    /// Requests currently on the wire, keyed by URL.
    ///
    /// Two callers wanting the same URL share one round trip instead of racing.
    /// Building a cold candidate pool is the case that needs it: moods overlap,
    /// so the same `/discover` page is asked for by several components within
    /// milliseconds, and without coalescing every one of them is a separate
    /// request against a rate-limited API.
    private let inFlightLock = NSLock()
    private var inFlight: [String: Task<Data, Error>] = [:]

    private var cachedVocabulary: TMDBGenreVocabulary? {
        vocabularyLock.lock()
        defer { vocabularyLock.unlock() }
        return _vocabulary
    }

    private func rememberVocabulary(_ vocabulary: TMDBGenreVocabulary) {
        vocabularyLock.lock()
        defer { vocabularyLock.unlock() }
        _vocabulary = vocabulary
    }

    // MARK: Init

    init(
        configuration: TMDBConfiguration,
        session: URLSession = .shared,
        cache: CatalogCache = CatalogCache()
    ) {
        self.configuration = configuration
        self.session = session
        self.cache = cache
    }

    // MARK: - MediaService

    func search(query: String) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Answered locally. A blank query is not a request for "everything" —
        // sending it would spend a round trip to be told nothing.
        guard !trimmed.isEmpty else { return [] }

        guard let url = TMDBEndpoint.searchMulti(query: trimmed) else {
            throw TMDBError.malformedURL
        }

        let page: TMDBPageDTO = try await get(url, cacheKey: CatalogCacheKey.search(trimmed))
        let vocabulary = await loadVocabulary()

        // `makeMediaItem` returns nil for person results and for titles with no
        // name, so `compactMap` is doing the filtering the API cannot.
        return page.results.compactMap { $0.makeMediaItem(vocabulary: vocabulary) }
    }

    func fetch(id: String) async throws -> MediaItem? {
        // An id this service did not mint — a legacy IMDb id, or junk — is a
        // miss, not an error. The contract says an unknown id is `nil`.
        guard let parsed = TMDBIdentifier.parse(id) else { return nil }

        guard let url = TMDBEndpoint.detail(type: parsed.type, tmdbId: parsed.tmdbId) else {
            throw TMDBError.malformedURL
        }

        let key = CatalogCacheKey.detail(type: parsed.type, tmdbId: parsed.tmdbId)
        do {
            let detail: TMDBDetailDTO = try await get(url, cacheKey: key)
            return detail.makeMediaItem(type: parsed.type, vocabulary: await loadVocabulary())
        } catch TMDBError.http(status: 404) {
            // TMDB's way of saying "no such title", which is the same answer
            // the protocol asks for as `nil`.
            return nil
        }
    }

    func popularTitles(type: MediaType, page: Int) async throws -> [MediaItem] {
        guard page >= 1 else { return [] }

        guard let url = TMDBEndpoint.discover(type: type, page: page) else {
            throw TMDBError.malformedURL
        }

        let key = CatalogCacheKey.popular(type: type, page: page)
        let dto: TMDBPageDTO = try await get(url, cacheKey: key)
        let vocabulary = await loadVocabulary()

        // `/discover/*` omits `media_type` — the endpoint already fixes it.
        return dto.results.compactMap {
            $0.makeMediaItem(fallbackType: type, vocabulary: vocabulary)
        }
    }

    /// The detail-screen payload, in one round trip.
    ///
    /// Failure is swallowed by contract (`MediaService.titleDetails`): the
    /// screen this feeds already has everything it needs to be useful, so an
    /// unreachable TMDB costs it a cast strip rather than an error banner. The
    /// cache still applies underneath, which is what makes reopening a title
    /// offline show the same page it showed online.
    func titleDetails(id: String, region: String) async -> TitleDetails? {
        guard let parsed = TMDBIdentifier.parse(id) else { return nil }
        guard let url = TMDBEndpoint.detailForDisplay(
            type: parsed.type, tmdbId: parsed.tmdbId
        ) else { return nil }

        let key = CatalogCacheKey.display(type: parsed.type, tmdbId: parsed.tmdbId)
        guard let dto: TMDBDetailDTO = try? await get(url, cacheKey: key) else { return nil }

        let details = dto.makeTitleDetails(type: parsed.type, region: region)
        return details.isEmpty ? nil : details
    }

    /// Everything a cast member has been in, most prominent first.
    ///
    /// Sorted by TMDB's popularity rather than by date: an actor's list is
    /// long, mostly obscure, and the first screenful decides whether the page
    /// is useful. Popularity is the catalog's opinion and never touches a
    /// ranking — it orders a list of candidates here, exactly as it does for
    /// the recommendation pool.
    ///
    /// Capped, because a working actor has hundreds of credits and every one of
    /// them becomes an id in a request to the server. The cap is applied after
    /// the sort, so what is dropped is the tail nobody scrolls to.
    func personCredits(id: String) async -> [MediaItem] {
        guard let tmdbId = Int(id), tmdbId > 0 else { return [] }
        guard let url = TMDBEndpoint.personCredits(personId: tmdbId) else { return [] }

        let key = CatalogCacheKey.personCredits(tmdbId: tmdbId)
        guard let dto: TMDBPersonCreditsDTO = try? await get(url, cacheKey: key) else { return [] }

        let vocabulary = await loadVocabulary()
        let credits = (dto.cast ?? [])
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            .compactMap { $0.makeMediaItem(vocabulary: vocabulary) }

        // TMDB lists a title once per role, so an actor who played twins — or a
        // recurring guest across two shows of the same name — appears twice.
        // Deduped on `externalId` because that is the key everything downstream
        // joins on: two rows for one film would ask the server about it twice
        // and draw it twice.
        var seen = Set<String>()
        return credits.filter { item in
            guard let externalId = item.externalId else { return false }
            return seen.insert(externalId).inserted
        }
        .prefix(Self.creditsCap)
        .map { $0 }
    }

    /// How many of a person's credits to carry.
    ///
    /// Past the length of any real filmography worth showing, and comfortably
    /// inside the 300 the RPC slices its array at — the cap that matters is the
    /// server's, and this one exists so the client never discovers it.
    static let creditsCap = 120

    // MARK: - Candidate pool

    /// One page of one mood component.
    ///
    /// Cached per component rather than per mood, so two moods drawing on the
    /// same basis share the entry instead of fetching the page twice.
    func discover(
        type: MediaType,
        component: MoodQueryComponent,
        page: Int
    ) async throws -> [MediaItem] {
        guard page >= 1, !component.isEmpty else { return [] }

        guard let url = TMDBEndpoint.discover(type: type, component: component, page: page) else {
            throw TMDBError.malformedURL
        }

        let key = CatalogCacheKey.pool(type: type, component: component, page: page)
        let dto: TMDBPageDTO = try await get(url, cacheKey: key)
        let vocabulary = await loadVocabulary()

        return dto.results.compactMap {
            $0.makeMediaItem(fallbackType: type, vocabulary: vocabulary)
        }
    }

    /// Exposed for the pool builder, which needs genre *names* resolved back to
    /// ids. Everything else on this type consumes the vocabulary internally.
    func genreVocabulary() async -> TMDBGenreVocabulary {
        await loadVocabulary()
    }

    /// Refreshes a keyword id from its name.
    ///
    /// `Mood` ships with measured ids, so this never gates a cold start — it is
    /// drift correction. Returns `nil` on any failure, meaning "keep the id you
    /// have", the same contract `resolveIMDbID` uses.
    func resolveKeywordId(_ name: String) async -> Int? {
        guard let url = TMDBEndpoint.searchKeyword(name) else { return nil }

        let key = CatalogCacheKey.keyword(name)
        guard let dto: TMDBKeywordSearchDTO = try? await get(url, cacheKey: key) else { return nil }

        // TMDB's keyword search is fuzzy: "romance" returns "romance novel"
        // above "romance" often enough to matter, so an exact match wins over
        // the first result.
        let exact = dto.results.first { $0.name.lowercased() == name.lowercased() }
        return (exact ?? dto.results.first)?.id
    }

    // MARK: - Features

    /// The full namespaced feature set for one title, in a single round trip.
    ///
    /// Separate from the `MediaService` protocol on purpose: features are a
    /// recommendation concern, not a catalog-browsing one, and the protocol is
    /// the surface every screen already depends on.
    ///
    /// Returns `nil` rather than throwing when the fetch fails. A title with no
    /// features and a title whose features could not be loaded are the same
    /// thing to the predictor — an absence of evidence — and failing the caller
    /// would let one unreachable request block a whole profile rebuild.
    func features(type: MediaType, tmdbId: Int) async -> ExtractedFeatures? {
        guard let url = TMDBEndpoint.detailWithFeatures(type: type, tmdbId: tmdbId) else {
            return nil
        }

        let key = CatalogCacheKey.features(type: type, tmdbId: tmdbId)
        guard let dto: TMDBDetailDTO = try? await get(url, cacheKey: key) else { return nil }

        let vocabulary = await loadVocabulary()
        return ExtractedFeatures(
            keys: dto.features(type: type, vocabulary: vocabulary).keys,
            voteAverage: dto.voteAverage,
            voteCount: dto.voteCount,
            posterURL: TMDBImage.posterURL(path: dto.posterPath)
        )
    }

    /// What one feature fetch yields. A plain struct rather than a tuple so it
    /// can cross a task boundary in `FeatureProvider`.
    struct ExtractedFeatures: Sendable {
        let keys: [String]
        let voteAverage: Double?
        let voteCount: Int?

        init(
            keys: [String],
            voteAverage: Double?,
            voteCount: Int? = nil,
            posterURL: String? = nil
        ) {
            self.keys = keys
            self.voteAverage = voteAverage
            self.voteCount = voteCount
            self.posterURL = posterURL
        }

        /// Carried because this request already pays for it. A library built
        /// before artwork was displayed — or before the live catalogue existed
        /// at all — holds rows with a nil `posterURL` and nothing ever filled
        /// them in, so every one of those titles drew a gradient for good.
        var posterURL: String?
    }

    // MARK: - External id resolution

    /// Resolves an IMDb id to TMDB's id for the same title.
    ///
    /// `type` is required rather than inferred: `/find` returns separate arrays
    /// per media type, and picking whichever is non-empty would let a film
    /// resolve to a series. Returns `nil` when the id is unknown to TMDB or the
    /// lookup fails — both mean "leave this item's id alone", and the migration
    /// simply tries again on a later launch.
    func resolveIMDbID(_ imdbID: String, expecting type: MediaType) async -> Int? {
        guard let url = TMDBEndpoint.find(imdbID: imdbID) else { return nil }

        let key = CatalogCacheKey.find(imdbID: imdbID)
        guard let dto: TMDBFindDTO = try? await get(url, cacheKey: key) else { return nil }
        return dto.firstID(for: type)
    }

    // MARK: - Genre vocabulary

    /// The movie and TV genre tables, fetched once and cached.
    ///
    /// Returns `.empty` if they cannot be loaded, which costs results their
    /// genres but leaves search working. Failing the whole request instead
    /// would mean a hiccup on a secondary endpoint takes down the primary one.
    private func loadVocabulary() async -> TMDBGenreVocabulary {
        if let cachedVocabulary { return cachedVocabulary }

        if let hit = cache.load(CatalogCacheKey.genreVocabulary, as: CachedVocabulary.self),
           !hit.isStale {
            let loaded = TMDBGenreVocabulary(movie: hit.value.movie, tv: hit.value.tv)
            rememberVocabulary(loaded)
            return loaded
        }

        async let movie = fetchGenres(type: .movie)
        async let tv = fetchGenres(type: .tvShow)
        let (movieGenres, tvGenres) = await (movie, tv)

        guard !movieGenres.isEmpty || !tvGenres.isEmpty else {
            // Nothing fetched. Fall back to a stale table if one exists rather
            // than dropping genres from every result for the whole session.
            if let hit = cache.load(CatalogCacheKey.genreVocabulary, as: CachedVocabulary.self) {
                let stale = TMDBGenreVocabulary(movie: hit.value.movie, tv: hit.value.tv)
                rememberVocabulary(stale)
                return stale
            }
            return .empty
        }

        cache.store(CachedVocabulary(movie: movieGenres, tv: tvGenres),
                    for: CatalogCacheKey.genreVocabulary)

        let loaded = TMDBGenreVocabulary(movie: movieGenres, tv: tvGenres)
        rememberVocabulary(loaded)
        return loaded
    }

    private func fetchGenres(type: MediaType) async -> [TMDBGenreDTO] {
        guard let url = TMDBEndpoint.genreList(type: type) else { return [] }
        guard let dto: TMDBGenreListDTO = try? await get(url, cacheKey: nil) else { return [] }
        return dto.genres
    }

    /// Both tables in one cache entry — they are fetched together and are
    /// useless apart, so storing them separately would only create a state
    /// where one is fresh and the other is not.
    private struct CachedVocabulary: Codable {
        let movie: [TMDBGenreDTO]
        let tv: [TMDBGenreDTO]
    }

    // MARK: - Transport

    /// One request, with the cache rules applied.
    ///
    /// Order matters and encodes the offline behaviour:
    ///   1. fresh cache  → return it, no network at all
    ///   2. network      → return it, and refresh the cache
    ///   3. stale cache  → return it, because a week-old answer beats none
    ///   4. otherwise    → throw
    ///
    /// Step 3 catches only transport failures. An HTTP error means TMDB
    /// answered — a 401 will not become valid by being retried from cache, and
    /// masking it with stale data would hide a broken token indefinitely.
    private func get<Value: Codable>(_ url: URL, cacheKey: String?) async throws -> Value {
        if let cacheKey, let hit = cache.load(cacheKey, as: Value.self), !hit.isStale {
            return hit.value
        }

        do {
            let value: Value = try await perform(url)
            if let cacheKey { cache.store(value, for: cacheKey) }
            return value
        } catch let error as TMDBError {
            throw error
        } catch {
            // Transport failure: offline, DNS, timeout, cancelled.
            if let cacheKey, let hit = cache.load(cacheKey, as: Value.self) {
                return hit.value
            }
            throw error
        }
    }

    private func perform<Value: Decodable>(_ url: URL) async throws -> Value {
        let data = try await coalescedData(for: url)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw TMDBError.decoding(String(describing: error))
        }
    }

    /// One round trip per URL, however many callers want it.
    ///
    /// The check and the insert happen under one lock so two callers arriving
    /// together cannot both miss and both fetch. The lock is never held across
    /// an `await`: creating a `Task` starts it without suspending here.
    private func coalescedData(for url: URL) async throws -> Data {
        let key = url.absoluteString

        let (task, isOwner): (Task<Data, Error>, Bool) = {
            inFlightLock.lock()
            defer { inFlightLock.unlock() }
            if let existing = inFlight[key] { return (existing, false) }
            let fresh = Task<Data, Error> { try await self.fetch(url) }
            inFlight[key] = fresh
            return (fresh, true)
        }()

        defer {
            if isOwner {
                inFlightLock.lock()
                inFlight[key] = nil
                inFlightLock.unlock()
            }
        }
        return try await task.value
    }

    /// The actual request. No retry loop on purpose: a failed call falls back to
    /// a stale cache entry, and retrying a rate-limited or failing endpoint in a
    /// loop is how a client turns one outage into several.
    private func fetch(_ url: URL) async throws -> Data {
        // `url` is always canonical TMDB. The configuration decides where the
        // request actually goes and which credential authorises it — see
        // `TMDBConfiguration.request(for:)`. Both change together or neither
        // does, which is what stops a build sending TMDB's token to the proxy
        // or the anon key to TMDB.
        guard let request = configuration.request(for: url) else {
            throw TMDBError.malformedURL
        }

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TMDBError.http(status: http.statusCode)
        }
        return data
    }
}
