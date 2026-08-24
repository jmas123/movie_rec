//
//  TestSupport.swift
//  BingedTests
//
//  Shared fixtures, stub services, and assertion helpers for the unit suite.
//
//  Before this file existed, `ceilLog2` had four copies, `makeLibrary` three,
//  and `seedLikedBucket` two that had already drifted apart. Everything here is
//  deliberately `internal` rather than `private` so the suites share one
//  definition — if a helper needs to change, it changes once.
//
//  The container/context split matters: `makeContainer()` returns the unit of
//  *persistence*, while a `ModelContext` is disposable. Tests that need to
//  prove a write actually reached the store build a second library over a fresh
//  context on the same container — see `PersistenceTests`.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - SwiftData fixtures

/// A fresh in-memory container. One per test — never shared, so tests can run
/// concurrently without seeing each other's items.
@MainActor
func makeContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: MediaItem.self, PendingPublish.self, configurations: config)
}

@MainActor
func makeContext() throws -> ModelContext {
    ModelContext(try makeContainer())
}

/// A library view model over a **new** `ModelContext` on an existing container.
/// Two libraries built this way share a store but no in-memory identity, which
/// is exactly what a round-trip assertion needs.
@MainActor
func makeLibrary(in container: ModelContainer) -> MediaLibraryViewModel {
    MediaLibraryViewModel(modelContext: ModelContext(container))
}

@MainActor
func makeLibrary() throws -> MediaLibraryViewModel {
    makeLibrary(in: try makeContainer())
}

// MARK: - Item fixtures

func makeItem(
    _ title: String,
    type: MediaType = .movie,
    year: Int = 2024,
    externalId: String? = nil
) -> MediaItem {
    MediaItem(externalId: externalId, title: title, year: year, type: type)
}

// MARK: - Math

/// `ceil(log2(n))` for `n >= 1` — the comparison bound the ranking spec
/// promises. Mirrors the private copy in `MediaLibraryViewModel` on purpose:
/// the test must state the expected bound independently of the implementation
/// it is checking, otherwise a bug in the bound would agree with itself.
func ceilLog2(_ n: Int) -> Int {
    precondition(n >= 1, "log2 undefined for n < 1")
    var value = n - 1
    var bits = 0
    while value > 0 {
        value >>= 1
        bits += 1
    }
    return bits
}

// MARK: - Session driving

/// Walks a comparison session to completion, always preferring the item already
/// in the bucket, which sinks the new item to the bottom. Returns the number of
/// comparisons answered.
@MainActor
@discardableResult
func driveSessionPreferringExisting(vm: MediaLibraryViewModel) -> Int {
    var steps = 0
    while let pair = vm.pendingComparison {
        vm.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
        steps += 1
    }
    return steps
}

/// Walks a comparison session to completion, always preferring the new item,
/// which floats it to the top of the bucket.
@MainActor
@discardableResult
func driveSessionPreferringNew(vm: MediaLibraryViewModel) -> Int {
    var steps = 0
    while let pair = vm.pendingComparison {
        vm.applyComparisonChoice(winner: pair.newItem, loser: pair.existingItem)
        steps += 1
    }
    return steps
}

/// Answers at most `limit` comparisons, then stops — leaving the session live
/// if it hasn't resolved. Used to reach the partially-answered states the real
/// UI can produce when a user dismisses the Compare sheet halfway through.
@MainActor
@discardableResult
func driveSession(vm: MediaLibraryViewModel, steps limit: Int) -> Int {
    var steps = 0
    while steps < limit, let pair = vm.pendingComparison {
        vm.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
        steps += 1
    }
    return steps
}

// MARK: - Bucket seeding

/// Seeds `sentiment` with `count` fully-ranked items, each driven to the bottom
/// so the resulting order is deterministic. Returns them in insertion order.
@MainActor
@discardableResult
func seedBucket(
    vm: MediaLibraryViewModel,
    sentiment: Sentiment,
    count: Int,
    titlePrefix: String = "Seed",
    type: MediaType = .movie
) -> [MediaItem] {
    var seeded: [MediaItem] = []
    for i in 0..<count {
        let item = makeItem("\(titlePrefix) \(i)", type: type)
        vm.markWatched(item, sentiment: sentiment)
        driveSessionPreferringExisting(vm: vm)
        vm.finalizeRanking(for: item)
        seeded.append(item)
    }
    return seeded
}

@MainActor
@discardableResult
func seedLikedBucket(vm: MediaLibraryViewModel, count: Int) -> [MediaItem] {
    seedBucket(vm: vm, sentiment: .liked, count: count)
}

// MARK: - Observation

/// Records whether an observation fired. A reference box so the `@Sendable`
/// `onChange` closure can write to it.
final class ChangeFlag: @unchecked Sendable {
    private(set) var fired = false
    func mark() { fired = true }
}

// MARK: - Bucket invariants

/// Asserts every invariant the ranking spec promises about a finished bucket:
/// ranks contiguous from 0, scores strictly inside the sentiment's range,
/// monotonically decreasing, and numerically equal to what
/// `RankingEngine.recomputeScores` produces for a bucket of this size.
///
/// The engine is the oracle rather than hardcoded constants, so a deliberate
/// change to the scoring formula updates every call site at once — but the
/// *count* is asserted independently, which is what catches a stale bucket
/// still scored for the wrong N.
@MainActor
func expectBucketWellFormed(
    _ bucket: [MediaItem],
    sentiment: Sentiment,
    count expectedCount: Int? = nil,
    _ label: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if let expectedCount {
        #expect(
            bucket.count == expectedCount,
            label ?? "bucket size", sourceLocation: sourceLocation
        )
    }

    let range = sentiment.scoreRange

    // Replay the engine onto a throwaway parallel array of the same size.
    let oracle = (0..<bucket.count).map { makeItem("Oracle \($0)") }
    RankingEngine().recomputeScores(in: oracle, range: range)

    for (i, item) in bucket.enumerated() {
        #expect(
            item.rankInBucket == i,
            label ?? "rankInBucket must be contiguous from 0",
            sourceLocation: sourceLocation
        )

        guard let score = item.score else {
            Issue.record(
                label ?? "item \(i) (\(item.title)) has no score",
                sourceLocation: sourceLocation
            )
            continue
        }

        #expect(
            score > range.lowerBound && score < range.upperBound,
            label ?? "score \(score) escaped \(sentiment) range \(range)",
            sourceLocation: sourceLocation
        )
        #expect(
            abs(score - (oracle[i].score ?? .nan)) < 0.0001,
            label ?? "score \(score) does not match the engine's value for N = \(bucket.count)",
            sourceLocation: sourceLocation
        )
        if i > 0 {
            #expect(
                score < (bucket[i - 1].score ?? .infinity),
                label ?? "scores must decrease down the bucket",
                sourceLocation: sourceLocation
            )
        }
    }
}

// MARK: - Stub services

/// A fresh, detached duplicate. Every stub below mints these rather than
/// vending its fixture array directly: a `@Model` can belong to exactly one
/// `ModelContext`, so a real service *must* hand back new instances on every
/// call, and a stub that shares them lets a test pass in a way the app never
/// could. The contract suite catches exactly this.
extension MediaItem {
    func detachedCopy() -> MediaItem {
        MediaItem(
            externalId: externalId,
            title: title,
            year: year,
            type: type,
            overview: overview,
            posterURL: posterURL,
            genres: genres,
            features: features,
            tmdbVoteAverage: tmdbVoteAverage
        )
    }
}


/// Synchronous, case-insensitive title-substring search over a fixed list.
struct StubMediaService: MediaService {
    let items: [MediaItem]

    init(items: [MediaItem] = StubMediaService.defaultItems()) {
        self.items = items
    }

    /// The three-title catalog most search tests expect: two share the prefix
    /// "In", so a partial query can be checked for narrowing behaviour.
    static func defaultItems() -> [MediaItem] {
        [
            MediaItem(externalId: "1", title: "Inception", year: 2010, type: .movie),
            MediaItem(externalId: "2", title: "Interstellar", year: 2014, type: .movie),
            MediaItem(externalId: "3", title: "Breaking Bad", year: 2008, type: .tvShow),
        ]
    }

    func search(query: String) async throws -> [MediaItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return items.filter { $0.title.lowercased().contains(needle) }.map { $0.detachedCopy() }
    }

    func fetch(id: String) async throws -> MediaItem? {
        items.first { $0.externalId == id }?.detachedCopy()
    }
}

/// Always throws — used to drive the error phase.
struct ThrowingMediaService: MediaService {
    struct Failure: Error {}

    func search(query: String) async throws -> [MediaItem] {
        throw Failure()
    }

    func fetch(id: String) async throws -> MediaItem? {
        throw Failure()
    }
}

/// Sleeps before answering, so a test can interleave a newer query.
struct SlowMediaService: MediaService {
    let items: [MediaItem]
    let delay: Duration

    init(items: [MediaItem] = StubMediaService.defaultItems(), delay: Duration) {
        self.items = items
        self.delay = delay
    }

    func search(query: String) async throws -> [MediaItem] {
        try await Task.sleep(for: delay)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return items.filter { $0.title.lowercased().contains(needle) }.map { $0.detachedCopy() }
    }

    func fetch(id: String) async throws -> MediaItem? {
        items.first { $0.externalId == id }?.detachedCopy()
    }
}

/// Throws `CancellationError` rather than a domain error. `SearchViewModel`
/// reads that as "a newer search took over", so it must leave the visible
/// results alone rather than clearing them or showing an error.
///
/// With the default empty `cancelling`, every query is cancelled. Give it a
/// substring to cancel only some queries and answer the rest normally.
struct CancellingMediaService: MediaService {
    let items: [MediaItem]
    let cancelling: String

    init(items: [MediaItem] = StubMediaService.defaultItems(), cancelling: String = "") {
        self.items = items
        self.cancelling = cancelling
    }

    func search(query: String) async throws -> [MediaItem] {
        if cancelling.isEmpty || query.localizedCaseInsensitiveContains(cancelling) {
            throw CancellationError()
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return items.filter { $0.title.lowercased().contains(needle) }.map { $0.detachedCopy() }
    }

    func fetch(id: String) async throws -> MediaItem? {
        items.first { $0.externalId == id }?.detachedCopy()
    }
}

/// Fails only for queries containing `failing`, so a test can drive the error
/// phase and then recover from it on the next keystroke.
struct SelectivelyFailingMediaService: MediaService {
    struct Failure: Error {}

    let items: [MediaItem]
    let failing: String

    init(items: [MediaItem] = StubMediaService.defaultItems(), failing: String) {
        self.items = items
        self.failing = failing
    }

    func search(query: String) async throws -> [MediaItem] {
        if query.localizedCaseInsensitiveContains(failing) { throw Failure() }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return items.filter { $0.title.lowercased().contains(needle) }.map { $0.detachedCopy() }
    }

    func fetch(id: String) async throws -> MediaItem? {
        items.first { $0.externalId == id }?.detachedCopy()
    }
}

/// Records every query it is asked for. `search` is nonisolated, so it can run
/// off the main actor — hence the lock rather than a bare `var`.
final class CountingMediaService: MediaService, @unchecked Sendable {
    private let lock = NSLock()
    private var _queries: [String] = []
    private let items: [MediaItem]
    private let delay: Duration

    init(items: [MediaItem] = StubMediaService.defaultItems(), delay: Duration = .zero) {
        self.items = items
        self.delay = delay
    }

    var queries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _queries
    }

    var callCount: Int { queries.count }

    func search(query: String) async throws -> [MediaItem] {
        lock.lock()
        _queries.append(query)
        lock.unlock()

        if delay > .zero { try await Task.sleep(for: delay) }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return items.filter { $0.title.lowercased().contains(needle) }.map { $0.detachedCopy() }
    }

    func fetch(id: String) async throws -> MediaItem? {
        items.first { $0.externalId == id }?.detachedCopy()
    }
}

// MARK: - MediaService contract

/// The behaviour every `MediaService` must exhibit, regardless of whether it is
/// backed by a bundled JSON file or a network API.
///
/// This exists because CLAUDE.md commits to swapping in a TMDB-backed service
/// behind this protocol. Today the only implementation is tested as a concrete
/// class, so nothing guards the contract itself; a TMDB class could satisfy the
/// signatures and still break every caller. Run this against any new conformer
/// and the interesting failures show up before the UI does.
///
/// - Parameters:
///   - service: the implementation under test.
///   - matchingQuery: a query the implementation is known to match at least once.
///   - knownExternalId: an id `fetch(id:)` is known to resolve.
func verifyMediaServiceContract(
    _ service: MediaService,
    matchingQuery: String,
    knownExternalId: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    // 1. Blank queries are answered locally, never sent onward.
    for blank in ["", "   ", "\n\t"] {
        let hits = try await service.search(query: blank)
        #expect(
            hits.isEmpty,
            "a blank query must return no results, got \(hits.count)",
            sourceLocation: sourceLocation
        )
    }

    // 2. Matching is case-insensitive.
    let lower = try await service.search(query: matchingQuery.lowercased())
    let upper = try await service.search(query: matchingQuery.uppercased())
    #expect(!lower.isEmpty, "expected \(matchingQuery) to match", sourceLocation: sourceLocation)
    #expect(
        lower.map(\.externalId) == upper.map(\.externalId),
        "search must be case-insensitive",
        sourceLocation: sourceLocation
    )

    // 3. Results are detached. A `@Model` belongs to exactly one context, so a
    //    service that handed back an inserted object would make the item
    //    unusable by whichever library tried to adopt it.
    for item in lower {
        #expect(
            item.modelContext == nil,
            "\(item.title) arrived already attached to a ModelContext",
            sourceLocation: sourceLocation
        )
        #expect(
            item.watchedStatus == .untracked,
            "a catalog result must not carry watched state",
            sourceLocation: sourceLocation
        )
        #expect(item.score == nil, "a catalog result must not carry a score", sourceLocation: sourceLocation)
    }

    // 4. Each call mints fresh instances — callers mutate what they receive.
    let again = try await service.search(query: matchingQuery)
    if let first = lower.first, let repeated = again.first {
        #expect(first !== repeated, "each search must mint fresh instances", sourceLocation: sourceLocation)
        #expect(first.externalId == repeated.externalId, sourceLocation: sourceLocation)
    }

    // 5. fetch(id:) resolves a known id and reports an unknown one as nil
    //    rather than throwing.
    let found = try await service.fetch(id: knownExternalId)
    #expect(found?.externalId == knownExternalId, sourceLocation: sourceLocation)

    let missing = try await service.fetch(id: "definitely-not-a-real-id")
    #expect(missing == nil, "an unknown id must be nil, not an error", sourceLocation: sourceLocation)
}

// MARK: - App-wide invariants

/// The invariant the whole ranking feature rests on: an item the user can see
/// on the Ranking screen is either not watched, or watched **and** scored.
///
/// A watched item with a `nil` score is not a cosmetic problem — it sorts to
/// the bottom of its bucket via `rankInBucket ?? .max`, renders with no score
/// badge, and is silently healed by the next insertion, so it disappears before
/// anyone can report it.
@MainActor
func expectNoStrandedItems(
    _ library: MediaLibraryViewModel,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for item in library.allWatched {
        #expect(
            item.sentiment != nil,
            "\(item.title) is watched but has no sentiment",
            sourceLocation: sourceLocation
        )
        #expect(
            item.score != nil,
            "\(item.title) is watched but has no score — stranded mid-session",
            sourceLocation: sourceLocation
        )
        #expect(
            item.rankInBucket != nil,
            "\(item.title) is watched but has no rank",
            sourceLocation: sourceLocation
        )
    }
}

// MARK: - Round-trip reads

/// Fetches every stored item through a **fresh** `ModelContext`, so the result
/// reflects what actually reached the store rather than what happens to be
/// alive in the writing context's memory.
@MainActor
func fetchAll(in container: ModelContainer) throws -> [MediaItem] {
    try ModelContext(container).fetch(FetchDescriptor<MediaItem>())
}

/// Refetches one item by its stable `id` through a fresh context.
@MainActor
func refetch(_ item: MediaItem, in container: ModelContainer) throws -> MediaItem? {
    let wanted = item.id
    return try fetchAll(in: container).first { $0.id == wanted }
}

// MARK: - Prediction fixtures

/// A watched, scored item with an explicit feature array.
///
/// Features are passed explicitly rather than derived, because
/// `RecommendationEngine.featureKeys(for:)` falls back to deriving `genre:` and
/// `era:` keys from `genres`/`year` when the array is empty — useful in
/// production, and a source of surprise features in a fixture that meant to
/// control exactly what the profile sees.
func makeScored(
    _ title: String,
    score: Double,
    type: MediaType = .movie,
    features: [String] = [],
    sentiment: Sentiment = .liked,
    genres: [String] = [],
    year: Int = 2024
) -> MediaItem {
    MediaItem(
        title: title,
        year: year,
        type: type,
        genres: genres,
        features: features,
        watchedStatus: .watched,
        sentiment: sentiment,
        score: score
    )
}

/// The scores `RankingEngine.recomputeScores` produces for a bucket of `count`
/// items, highest first. Stated independently of the engine so a fixture built
/// on it does not agree with a bug in it.
func bucketScores(count: Int, range: ClosedRange<Double>) -> [Double] {
    let span = range.upperBound - range.lowerBound
    return (0..<count).map { index in
        range.upperBound - ((Double(index) + 0.5) / Double(count)) * span
    }
}

/// The 20 liked / 12 fine / 8 disliked film library the Phase 13 plan works
/// through, where the top `horrorCount` liked entries carry `genre:Horror` and
/// every other item carries an inert filler genre.
///
/// Its arithmetic is pinned in the plan: `globalMean == baseline == 6.045`,
/// the horror residual sum is `26.52`, and the shrunk effect is `26.52 / 11`.
func makePlanFixtureLibrary(horrorCount: Int = 8) -> [MediaItem] {
    var items: [MediaItem] = []

    func add(_ scores: [Double], _ sentiment: Sentiment, taggedFirst: Int) {
        for (index, score) in scores.enumerated() {
            let feature = index < taggedFirst
                ? Feature.genre("Horror").key
                : Feature.genre("Filler").key
            items.append(
                makeScored(
                    "\(sentiment.rawValue)-\(index)",
                    score: score,
                    features: [feature],
                    sentiment: sentiment
                )
            )
        }
    }

    add(bucketScores(count: 20, range: Sentiment.liked.scoreRange), .liked, taggedFirst: horrorCount)
    add(bucketScores(count: 12, range: Sentiment.fine.scoreRange), .fine, taggedFirst: 0)
    add(bucketScores(count: 8, range: Sentiment.disliked.scoreRange), .disliked, taggedFirst: 0)

    return items
}

// MARK: - Mood fixtures

/// The real TMDB genre vocabulary, as the two `/genre/*/list` endpoints return
/// it — complete rather than trimmed, because a mood test's whole job is to
/// notice that television has no Thriller, Horror or Romance.
func makeFullGenreVocabulary() -> TMDBGenreVocabulary {
    TMDBGenreVocabulary(
        movie: [
            .init(id: 28, name: "Action"), .init(id: 12, name: "Adventure"),
            .init(id: 16, name: "Animation"), .init(id: 35, name: "Comedy"),
            .init(id: 80, name: "Crime"), .init(id: 99, name: "Documentary"),
            .init(id: 18, name: "Drama"), .init(id: 10751, name: "Family"),
            .init(id: 14, name: "Fantasy"), .init(id: 36, name: "History"),
            .init(id: 27, name: "Horror"), .init(id: 10402, name: "Music"),
            .init(id: 9648, name: "Mystery"), .init(id: 10749, name: "Romance"),
            .init(id: 878, name: "Science Fiction"), .init(id: 10770, name: "TV Movie"),
            .init(id: 53, name: "Thriller"), .init(id: 10752, name: "War"),
            .init(id: 37, name: "Western"),
        ],
        tv: [
            .init(id: 10759, name: "Action & Adventure"), .init(id: 16, name: "Animation"),
            .init(id: 35, name: "Comedy"), .init(id: 80, name: "Crime"),
            .init(id: 99, name: "Documentary"), .init(id: 18, name: "Drama"),
            .init(id: 10751, name: "Family"), .init(id: 10762, name: "Kids"),
            .init(id: 9648, name: "Mystery"), .init(id: 10763, name: "News"),
            .init(id: 10764, name: "Reality"), .init(id: 10765, name: "Sci-Fi & Fantasy"),
            .init(id: 10766, name: "Soap"), .init(id: 10767, name: "Talk"),
            .init(id: 10768, name: "War & Politics"), .init(id: 37, name: "Western"),
        ]
    )
}

/// An in-memory `CandidateSource` that answers from generated titles.
///
/// A stub rather than the `URLProtocol` fixture path on purpose: the builder's
/// logic is paging, deduplication and stopping rules, and testing those through
/// a fake HTTP layer would be testing the fake. `TMDBMediaServiceTests` covers
/// the wire format separately.
final class StubCandidateSource: CandidateSource, @unchecked Sendable {

    /// `component.identity` -> pages of externalIds, in order.
    private let pages: [String: [[String]]]
    private let vocabulary: TMDBGenreVocabulary
    private let genres: [String: [String]]
    private let lock = NSLock()
    private var _requests: [String] = []

    init(
        pages: [String: [[String]]],
        vocabulary: TMDBGenreVocabulary = makeFullGenreVocabulary(),
        genres: [String: [String]] = [:]
    ) {
        self.pages = pages
        self.vocabulary = vocabulary
        self.genres = genres
    }

    /// Every `identity:page` asked for, in order. Lets a test assert that the
    /// builder stopped paging rather than only that it returned the right size.
    var requests: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func discover(type: MediaType, component: MoodQueryComponent, page: Int) async throws -> [MediaItem] {
        lock.lock()
        _requests.append("\(component.identity):\(page)")
        lock.unlock()

        guard let all = pages[component.identity], page >= 1, page <= all.count else { return [] }

        // Ids must be namespaced by type, as Phase 12a made real ones. Without
        // that, the movie pass and the TV pass hand back the *same* ids — and
        // since the pool keys on `externalId`, the second silently overwrites
        // the first and a whole type vanishes from the pool.
        //
        // Two id styles are accepted, because tests use both: an already
        // namespaced id is filtered to its own type, and a bare one is
        // namespaced here.
        let prefix = type == .movie ? "tmdb:movie:" : "tmdb:tv:"
        return all[page - 1]
            .filter { !$0.hasPrefix("tmdb:") || $0.hasPrefix(prefix) }
            .map { raw -> MediaItem in
                let id = raw.hasPrefix("tmdb:") ? raw : prefix + raw
                return MediaItem(externalId: id, title: id, year: 2020, type: type,
                                 genres: genres[raw] ?? genres[id] ?? [])
            }
    }

    func genreVocabulary() async -> TMDBGenreVocabulary { vocabulary }

    func resolveKeywordId(_ name: String) async -> Int? { nil }
}

/// Fills every component of every mood with `count` distinct titles per page,
/// so a builder test can exercise the full sweep without hand-writing pages.
func makeFullStubSource(
    pagesPerComponent: Int = 5,
    perPage: Int = 20,
    vocabulary: TMDBGenreVocabulary = makeFullGenreVocabulary()
) -> StubCandidateSource {
    var pages: [String: [[String]]] = [:]
    for type in MediaType.allCases {
        for mood in Mood.allCases {
            for component in mood.queryComponents(for: type, vocabulary: vocabulary) {
                guard pages[component.identity] == nil else { continue }
                // Bare ids: the stub namespaces them per type at request time,
                // so one page table serves both without collisions.
                pages[component.identity] = (0..<pagesPerComponent).map { page in
                    (0..<perPage).map { "\(component.identity)-\(page)-\($0)" }
                }
            }
        }
    }
    return StubCandidateSource(pages: pages, vocabulary: vocabulary)
}

// MARK: - Recommendation fixtures

/// A library seeded with ranked items, written straight into the store.
///
/// Bypasses `markWatched` deliberately: that opens a comparison session per
/// item, and these fixtures care about the *resulting* library rather than
/// about the flow that produces one. `CompareViewModelTests` covers the flow.
///
/// Items are spread across all three sentiments and three genres, which matters
/// more than it looks. A library where every item shares one genre in one
/// bucket is **degenerate for the predictor**: that genre's residuals sum to
/// exactly zero by construction, so its effect is zero and a test asserting
/// that some feature moves a prediction can never pass. Varying the fixture is
/// what makes feature effects non-trivial.
@MainActor
func makeRankedLibrary(
    movies: Int = 12,
    shows: Int = 6,
    container: ModelContainer? = nil
) throws -> MediaLibraryViewModel {
    let container = try container ?? makeContainer()
    let context = ModelContext(container)

    // Cycled, so any count produces a spread rather than a single bucket.
    let plan: [(sentiment: Sentiment, genre: String)] = [
        (.liked, "Drama"), (.liked, "Drama"), (.fine, "Comedy"), (.disliked, "Horror"),
    ]

    func seed(_ count: Int, _ type: MediaType, _ base: Int) {
        var buckets: [Sentiment: [(index: Int, genre: String)]] = [:]
        for index in 0..<count {
            let slot = plan[index % plan.count]
            buckets[slot.sentiment, default: []].append((index, slot.genre))
        }

        for (sentiment, members) in buckets {
            let scores = bucketScores(count: members.count, range: sentiment.scoreRange)
            for (position, member) in members.enumerated() {
                let item = MediaItem(
                    externalId: "tmdb:\(type == .movie ? "movie" : "tv"):\(base + member.index)",
                    title: "\(type == .movie ? "film" : "show") \(member.index)",
                    year: 2015,
                    type: type,
                    genres: [member.genre],
                    features: [Feature.genre(member.genre).key],
                    watchedStatus: .watched,
                    sentiment: sentiment,
                    score: scores[position]
                )
                context.insert(item)
            }
        }
    }

    seed(movies, .movie, 1000)
    seed(shows, .tvShow, 2000)
    try context.save()

    return makeLibrary(in: container)
}


/// `makeFullStubSource` with genres attached, for diagnostics that need
/// candidates to predict differently.
@MainActor
func makeFullStubSourceWithGenres(
    genres: [String: [String]],
    pagesPerComponent: Int = 5,
    perPage: Int = 20,
    vocabulary: TMDBGenreVocabulary = makeFullGenreVocabulary()
) -> StubCandidateSource {
    var pages: [String: [[String]]] = [:]
    for type in MediaType.allCases {
        for mood in Mood.allCases {
            for component in mood.queryComponents(for: type, vocabulary: vocabulary) {
                guard pages[component.identity] == nil else { continue }
                pages[component.identity] = (0..<pagesPerComponent).map { page in
                    (0..<perPage).map { "\(component.identity)-\(page)-\($0)" }
                }
            }
        }
    }
    return StubCandidateSource(pages: pages, vocabulary: vocabulary, genres: genres)
}
