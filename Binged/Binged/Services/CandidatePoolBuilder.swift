//
//  CandidatePoolBuilder.swift
//  Binged
//
//  Builds and caches the set of unwatched titles Discover recommends out of.
//
//  Why a local pool at all, when Phase 12 made the catalog live: prediction is
//  not search. Ranking recommendations means scoring *every* candidate against
//  the taste profile and sorting — a full pass over the candidate set. There is
//  no TMDB endpoint for "score these against my local model", and re-fetching a
//  thousand titles on every mood tap would be slow and rude to the API. This is
//  the set that pass runs over, cached so the pass is instant and so Discover
//  works with the network off.
//
//  Two things this deliberately does not do:
//
//  - **It does not size itself to a target.** The old plan said "reach ~1200
//    distinct titles", which measures the wrong thing. Because pages are fetched
//    *per mood component*, per-mood coverage is guaranteed by construction and
//    query overlap costs storage rather than coverage. The pool's size is
//    whatever the deduplicated union comes to — measured at ~1600 across both
//    types, which is where the old budget landed anyway.
//
//  - **It does not touch SwiftData.** The pool is disposable cache; the store
//    holds the user's library. Mixing them would make eviction a data-loss risk,
//    which is the same reasoning that kept `CatalogCache` out of the store.
//

import Foundation

// MARK: - PooledTitle

/// One title as the pool holds it: a plain `Codable` value, never a `@Model`.
struct PooledTitle: Codable, Sendable, Hashable {

    let externalId: String
    let title: String
    let year: Int
    let type: MediaType
    let overview: String
    let posterURL: String?
    let genres: [String]
    let tmdbVoteAverage: Double?
    let tmdbVoteCount: Int?

    init?(_ item: MediaItem) {
        // Identity is the whole basis of deduplication, so a title without one
        // cannot join the pool. Phase 12a made these unambiguous
        // (`tmdb:movie:27205`), which is what lets a film and a series with the
        // same TMDB id coexist.
        guard let externalId = item.externalId else { return nil }
        self.externalId = externalId
        self.title = item.title
        self.year = item.year
        self.type = item.type
        self.overview = item.overview
        self.posterURL = item.posterURL
        self.genres = item.genres
        self.tmdbVoteAverage = item.tmdbVoteAverage
        self.tmdbVoteCount = item.tmdbVoteCount
    }

    /// A detached `MediaItem` for the engine and the UI. Not inserted into any
    /// context — the caller decides if and when, exactly as `MediaService` does.
    func makeMediaItem() -> MediaItem {
        MediaItem(
            externalId: externalId,
            title: title,
            year: year,
            type: type,
            overview: overview,
            posterURL: posterURL,
            genres: genres,
            tmdbVoteAverage: tmdbVoteAverage,
            tmdbVoteCount: tmdbVoteCount
        )
    }
}

// MARK: - CandidatePool

struct CandidatePool: Codable, Sendable {

    /// Every distinct title, keyed by `externalId`.
    var titles: [String: PooledTitle]

    /// `"mood|type" -> [externalId]`, in popularity order.
    ///
    /// Membership as id lists rather than as copies is what makes overlap cost
    /// storage instead of coverage: a title in four moods is stored once and
    /// listed four times.
    var membership: [String: [String]]

    var builtAt: Date

    /// Components that hit the page cap, so a bounded sweep is visible rather
    /// than reading as complete coverage. A silent cap is a lie of omission.
    var truncated: [String]

    static let empty = CandidatePool(titles: [:], membership: [:], builtAt: .distantPast, truncated: [])

    static func key(mood: Mood, type: MediaType) -> String {
        "\(mood.rawValue)|\(type.rawValue)"
    }

    func candidates(mood: Mood, type: MediaType) -> [PooledTitle] {
        (membership[Self.key(mood: mood, type: type)] ?? []).compactMap { titles[$0] }
    }

    func count(mood: Mood, type: MediaType) -> Int {
        membership[Self.key(mood: mood, type: type)]?.count ?? 0
    }

    var isEmpty: Bool { titles.isEmpty }

    func isStale(ttl: TimeInterval, now: Date = .now) -> Bool {
        now.timeIntervalSince(builtAt) > ttl
    }
}

// MARK: - CandidatePoolBuilder

actor CandidatePoolBuilder {

    private let source: CandidateSource
    private let cache: CatalogCache
    private let ttl: TimeInterval

    /// How many titles to gather per `(mood, type)`.
    ///
    /// The acceptance bar is 30 *eligible* candidates. This targets 45 for
    /// headroom: the pool is rebuilt weekly and the user keeps watching things
    /// during the week, so a pool that exactly clears 30 on build day is under
    /// it by Wednesday.
    private let target: Int

    /// Hard stop per component, so a mood that can never clear its bar cannot
    /// page forever. Every truncation is recorded on the pool.
    private let maxPages: Int

    private var refreshTask: Task<CandidatePool, Never>?
    private var cached: CandidatePool?

    init(
        source: CandidateSource,
        cache: CatalogCache = CatalogCache(),
        ttl: TimeInterval = CatalogCache.defaultTTL,
        target: Int = 45,
        maxPages: Int = 5
    ) {
        self.source = source
        self.cache = cache
        self.ttl = ttl
        self.target = max(1, target)
        self.maxPages = max(1, maxPages)
    }

    // MARK: - Serving

    /// The pool, served immediately from memory or disk when one exists.
    ///
    /// A stale pool is returned *and* a refresh is started behind it. Never
    /// block a mood tap on a rebuild: a week-old list of popular titles is a
    /// fine answer, and a spinner is not.
    func pool(excluding excluded: Set<String> = []) async -> CandidatePool {
        if let ready = loadedPool() {
            if ready.isStale(ttl: ttl) {
                startRefresh(excluding: excluded)
            }
            return ready
        }
        // Cold: nothing to serve, so this one call does wait.
        return await refresh(excluding: excluded)
    }

    /// Whatever pool already exists, without ever building one.
    ///
    /// For callers that want the pool if it is there and nothing if it is not —
    /// a detail screen must not pay for a full sweep (every mood × every type ×
    /// every component) because the user tapped a search result.
    func cachedPool() -> CandidatePool? {
        loadedPool()
    }

    /// Rebuilds now, coalescing concurrent callers onto one sweep.
    @discardableResult
    func refresh(excluding excluded: Set<String> = []) async -> CandidatePool {
        if let running = refreshTask {
            return await running.value
        }
        let task = Task { await build(excluding: excluded) }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    private func startRefresh(excluding excluded: Set<String>) {
        guard refreshTask == nil else { return }
        let task = Task { await build(excluding: excluded) }
        refreshTask = task
        Task {
            _ = await task.value
            await clearRefreshTask()
        }
    }

    private func clearRefreshTask() { refreshTask = nil }

    private func loadedPool() -> CandidatePool? {
        if let cached, !cached.isEmpty { return cached }
        guard let hit = cache.load(CatalogCacheKey.candidatePool, as: CandidatePool.self),
              !hit.value.isEmpty else { return nil }
        cached = hit.value
        return hit.value
    }

    // MARK: - Building

    /// Pages every `(mood, type)` until it clears `target`, and returns the
    /// deduplicated union.
    ///
    /// - Parameter excluded: `externalId`s the user has already dealt with.
    ///   Passed in rather than looked up, because a disposable cache has no
    ///   business reading the user's library — but paging *toward* an eligible
    ///   count rather than a raw one is what stops a mood from being technically
    ///   full and practically empty.
    func build(
        moods: [Mood] = Mood.allCases,
        types: [MediaType] = MediaType.allCases,
        excluding excluded: Set<String> = []
    ) async -> CandidatePool {
        let vocabulary = await source.genreVocabulary()

        var titles: [String: PooledTitle] = [:]
        var membership: [String: [String]] = [:]
        var truncated: [String] = []

        for type in types {
            for mood in moods {
                let components = mood.queryComponents(for: type, vocabulary: vocabulary)
                var ordered: [String] = []
                var seen: Set<String> = []

                for component in components {
                    // Each component earns its own quota. Sharing one counter
                    // let a broad genre component fill the mood before a later
                    // keyword component was queried at all — e.g. Adventure
                    // could silently erase "quest" from Epic.
                    var eligible = 0
                    var page = 1
                    var exhausted = false

                    while eligible < target, page <= maxPages {
                        let batch = (try? await source.discover(
                            type: type, component: component, page: page
                        )) ?? []

                        if batch.isEmpty {
                            exhausted = true
                            break
                        }

                        for item in batch {
                            // Type must match what was asked for. `/discover/movie`
                            // never returns a series, so this should be
                            // unreachable — but titles are keyed by `externalId`
                            // across both type passes, so a mismatched item would
                            // silently overwrite the right one and vanish from
                            // its own type's reference distribution.
                            guard item.type == type,
                                  let pooled = PooledTitle(item),
                                  seen.insert(pooled.externalId).inserted else { continue }
                            titles[pooled.externalId] = pooled
                            ordered.append(pooled.externalId)
                            if !excluded.contains(pooled.externalId) { eligible += 1 }
                        }
                        page += 1
                    }

                    // Only a cap we hit while still short is worth recording. A
                    // component that stopped because the mood was already full
                    // was not truncated in any sense the caller cares about.
                    if !exhausted, page > maxPages, eligible < target {
                        truncated.append("\(mood.rawValue)|\(type.rawValue)|\(component.identity)")
                    }
                }

                membership[CandidatePool.key(mood: mood, type: type)] = ordered
            }
        }

        let pool = CandidatePool(
            titles: titles,
            membership: membership,
            builtAt: .now,
            truncated: truncated
        )

        cache.store(pool, for: CatalogCacheKey.candidatePool)
        cached = pool
        return pool
    }
}
