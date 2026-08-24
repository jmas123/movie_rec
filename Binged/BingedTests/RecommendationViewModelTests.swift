//
//  RecommendationViewModelTests.swift
//  BingedTests
//
//  The layer between the pure engine and the screen: exclusions, cold start,
//  ranking, diversity, the profile cache, and the two-stage rerank.
//
//  In-memory `ModelContainer` throughout, and a stub pool — nothing here
//  touches the network.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - Helpers

@MainActor
private func makeViewModel(
    library: MediaLibraryViewModel,
    source: CandidateSource,
    featureSource: FeatureSource? = nil
) -> RecommendationViewModel {
    RecommendationViewModel(
        library: library,
        poolBuilder: CandidatePoolBuilder(source: source, cache: makeDisabledCache()),
        featureSource: featureSource
    )
}

/// A pool of `count` crime films, optionally carrying genres.
@MainActor
private func makeCrimeSource(
    count: Int = 40,
    genres: [String: [String]] = [:]
) -> StubCandidateSource {
    let component = Mood.crime.queryComponents(for: .movie, vocabulary: makeFullGenreVocabulary())[0]
    let ids = (0..<count).map { "tmdb:movie:\(9000 + $0)" }
    return StubCandidateSource(
        pages: [component.identity: stride(from: 0, to: ids.count, by: 20).map {
            Array(ids[$0..<min($0 + 20, ids.count)])
        }],
        genres: genres
    )
}

/// Counts feature fetches and answers with a fixed key set.
private final class CountingFeatureSource: FeatureSource, @unchecked Sendable {
    private let keys: [String]
    private let lock = NSLock()
    private var _calls = 0

    init(keys: [String]) { self.keys = keys }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func features(type: MediaType, tmdbId: Int) async -> TMDBMediaService.ExtractedFeatures? {
        lock.lock(); _calls += 1; lock.unlock()
        return TMDBMediaService.ExtractedFeatures(keys: keys, voteAverage: nil)
    }
}

// MARK: - Cold start

@Suite("RecommendationViewModel — cold start")
@MainActor
struct RecommendationColdStartTests {

    @Test("An empty library asks for rankings rather than guessing")
    func emptyLibraryNeedsRankings() async throws {
        let vm = makeViewModel(library: try makeLibrary(), source: makeCrimeSource())
        let result = await vm.recommendations(type: .movie, mood: .crime)

        guard case .needsMoreRankings(let have, let need, let type) = result else {
            Issue.record("expected .needsMoreRankings, got \(result)")
            return
        }
        #expect(have == 0)
        #expect(need == RecommendationViewModel.minimumLibraryForRecommendations)
        #expect(type == nil)
        #expect(result.recommendations.isEmpty)
    }

    @Test("A library just under the floor still asks")
    func justUnderTheFloor() async throws {
        let library = try makeRankedLibrary(movies: 9, shows: 0)
        let vm = makeViewModel(library: library, source: makeCrimeSource())

        guard case .needsMoreRankings(let have, _, _) = await vm.recommendations(type: .movie, mood: .crime) else {
            Issue.record("expected .needsMoreRankings")
            return
        }
        #expect(have == 9)
    }

    @Test("A big film library still cannot speak for television")
    func perTypeFloorIsSeparate() async throws {
        // The baselines are per-type, so forty films say nothing about TV. The
        // binding constraint is the one the UI should name.
        let library = try makeRankedLibrary(movies: 20, shows: 1)
        let vm = makeViewModel(library: library, source: makeCrimeSource())

        guard case .needsMoreRankings(let have, let need, let type) =
                await vm.recommendations(type: .tvShow, mood: .crime) else {
            Issue.record("expected .needsMoreRankings for television")
            return
        }
        #expect(have == 1)
        #expect(need == RecommendationViewModel.minimumPerTypeForRecommendations)
        #expect(type == .tvShow)

        // And film, which clears both floors, is unaffected.
        #expect(await vm.recommendations(type: .movie, mood: .crime).isReady)
    }
}

// MARK: - Exclusions

@Suite("RecommendationViewModel — exclusions")
@MainActor
struct RecommendationExclusionTests {

    @Test("A watched title never appears, even when it would rank first")
    func watchedTitlesAreExcluded() async throws {
        let container = try makeContainer()
        let library = try makeRankedLibrary(movies: 12, shows: 4, container: container)

        // Rank one pool title top-of-Liked, so it would otherwise lead the list.
        let context = ModelContext(container)
        context.insert(MediaItem(
            externalId: "tmdb:movie:9000",
            title: "Already Seen", year: 2015, type: .movie,
            genres: ["Drama"], features: [Feature.genre("Drama").key],
            watchedStatus: .watched, sentiment: .liked, score: 9.9
        ))
        try context.save()

        let fresh = makeLibrary(in: container)
        let vm = makeViewModel(library: fresh, source: makeCrimeSource())
        let result = await vm.recommendations(type: .movie, mood: .crime)

        let ids = result.recommendations.map(\.id)
        #expect(!ids.contains("tmdb:movie:9000"))
        #expect(!ids.isEmpty)
    }

    @Test("A queued title is kept and flagged, not dropped")
    func queuedTitlesAreFlagged() async throws {
        // The user asked for titles they have not seen. A queued title is
        // unseen — hiding it would silently shrink the list for the users most
        // engaged with the app.
        let container = try makeContainer()
        _ = try makeRankedLibrary(movies: 12, shows: 4, container: container)

        let context = ModelContext(container)
        context.insert(MediaItem(
            externalId: "tmdb:movie:9001",
            title: "On The List", year: 2015, type: .movie,
            watchedStatus: .wantToWatch
        ))
        try context.save()

        let vm = makeViewModel(library: makeLibrary(in: container), source: makeCrimeSource())
        let result = await vm.recommendations(type: .movie, mood: .crime, limit: 40)

        let queued = result.recommendations.first { $0.id == "tmdb:movie:9001" }
        #expect(queued != nil)
        #expect(queued?.isQueued == true)

        let others = result.recommendations.filter { $0.id != "tmdb:movie:9001" }
        #expect(others.allSatisfy { !$0.isQueued } == true)
    }

    @Test("An empty pool reports itself rather than looking like a thin mood")
    func emptyPoolIsDistinguishable() async throws {
        let library = try makeRankedLibrary()
        let vm = makeViewModel(
            library: library,
            source: StubCandidateSource(pages: [:])
        )

        guard case .noCandidates(let poolIsEmpty) = await vm.recommendations(type: .movie, mood: .crime) else {
            Issue.record("expected .noCandidates")
            return
        }
        #expect(poolIsEmpty)
    }
}

// MARK: - Ranking

@Suite("RecommendationViewModel — ranking")
@MainActor
struct RecommendationRankingTests {

    @Test("Ranking scales the taste lift, never the raw predicted value")
    func rankingUsesLiftNotValue() {
        // The bug this guards is invisible today — `moodWeight` is binary, so
        // `value * weight` and `lift * weight` induce the same order — and
        // becomes live the moment moods are graded. Hence a direct test of the
        // formula rather than of the list it produces.
        let baseline = 6.045

        let strongTasteWeakMood = RecommendationViewModel.rankingScore(
            value: baseline + 0.70, baseline: baseline, moodWeight: 0.9
        )
        let weakTasteStrongMood = RecommendationViewModel.rankingScore(
            value: baseline + 0.20, baseline: baseline, moodWeight: 1.0
        )

        #expect(strongTasteWeakMood > weakTasteStrongMood)

        // What the discarded formula would have done: a tenth of mood relevance
        // beating three and a half times the taste fit.
        #expect((baseline + 0.70) * 0.9 < (baseline + 0.20) * 1.0)
    }

    @Test("Two identical requests return identical order")
    func requestsAreDeterministic() async throws {
        // No `Set` iteration may leak into output — the list must not reshuffle
        // between renders.
        let library = try makeRankedLibrary()
        let vm = makeViewModel(library: library, source: makeCrimeSource())

        let first = await vm.recommendations(type: .movie, mood: .crime)
        let second = await vm.recommendations(type: .movie, mood: .crime)

        #expect(first.recommendations.map(\.id) == second.recommendations.map(\.id))
        #expect(!first.recommendations.isEmpty)
    }

    @Test("Ties break by title, then by id, so the order is total")
    func tiesBreakDeterministically() async throws {
        // Every pool title here is identical to the engine — same genres, same
        // era — so every prediction ties and only the tie-break orders them.
        let library = try makeRankedLibrary()
        let vm = makeViewModel(library: library, source: makeCrimeSource(count: 20))
        let result = await vm.recommendations(type: .movie, mood: .crime, limit: 20)

        let titles = result.recommendations.map(\.item.title)
        #expect(titles == titles.sorted())
    }

    @Test("Lift is reported relative to the type baseline")
    func liftIsRelativeToBaseline() async throws {
        let library = try makeRankedLibrary()
        let vm = makeViewModel(library: library, source: makeCrimeSource())
        let result = await vm.recommendations(type: .movie, mood: .crime)

        let profile = RecommendationEngine().buildProfile(from: library.allWatched)
        let baseline = profile.baseline(for: .movie)

        for recommendation in result.recommendations {
            #expect(abs(recommendation.lift - (recommendation.predicted.value - baseline)) < 0.0001)
        }
    }
}

// MARK: - Diversity

@Suite("RecommendationViewModel — diversity")
@MainActor
struct RecommendationDiversityTests {

    @Test("No single genre may dominate the returned list")
    func genreCapHolds() async throws {
        // A user who rates crime highly would otherwise get twenty crime
        // titles: technically their best twenty, and useless to browse.
        // Drama-heavy but with enough breadth that the cap is *reachable*:
        // with a limit of 20 and a cap of 8, two genres could only ever fill
        // 16 slots, so a two-genre pool tests backfill rather than the cap.
        var genres: [String: [String]] = [:]
        let others = ["Comedy", "Action", "Horror"]
        for index in 0..<40 {
            genres["tmdb:movie:\(9000 + index)"] = index < 25
                ? ["Drama"]
                : [others[(index - 25) % others.count]]
        }

        let library = try makeRankedLibrary()
        let vm = makeViewModel(library: library, source: makeCrimeSource(genres: genres))
        let result = await vm.recommendations(type: .movie, mood: .crime, limit: 20)

        let dramas = result.recommendations.filter { $0.item.genres.contains("Drama") }.count
        let cap = Int((20.0 * RecommendationViewModel.genreCap).rounded(.up))

        #expect(result.recommendations.count == 20)
        #expect(dramas <= cap, "\(dramas) dramas exceeds the cap of \(cap)")
        #expect(dramas < 25, "the cap did nothing")
    }

    @Test("A full list beats a strict cap when the pool is too narrow to give both")
    func backfillYieldsTheCapRatherThanTheList() async throws {
        // With one genre available, a limit of 20 and a cap of 8, the two goals
        // are arithmetically incompatible. The cap is the one that gives: eight
        // rows on a browsing screen is a worse outcome than a concentrated
        // twenty, and the deferred candidates are the next-best ones anyway.
        var genres: [String: [String]] = [:]
        for index in 0..<40 { genres["tmdb:movie:\(9000 + index)"] = ["Drama"] }

        let library = try makeRankedLibrary()
        let vm = makeViewModel(library: library, source: makeCrimeSource(genres: genres))
        let result = await vm.recommendations(type: .movie, mood: .crime, limit: 20)

        #expect(result.recommendations.count == 20)
        let dramas = result.recommendations.filter { $0.item.genres.contains("Drama") }.count
        #expect(dramas == 20)
    }

    @Test("Untagged candidates are never held back by the cap")
    func candidatesWithoutGenresAreUnconstrained() async throws {
        // A pool title with no genres cannot push any genre over its cap, and
        // must not be treated as though it belonged to a phantom one.
        let library = try makeRankedLibrary()
        let vm = makeViewModel(library: library, source: makeCrimeSource(count: 30))
        let result = await vm.recommendations(type: .movie, mood: .crime, limit: 20)

        #expect(result.recommendations.count == 20)
    }

    @Test("A limit of zero returns nothing rather than crashing")
    func zeroLimitIsSafe() async throws {
        let library = try makeRankedLibrary()
        let vm = makeViewModel(library: library, source: makeCrimeSource())
        let result = await vm.recommendations(type: .movie, mood: .crime, limit: 0)

        #expect(result.recommendations.isEmpty)
    }
}

// MARK: - Profile caching

@Suite("RecommendationViewModel — profile caching")
@MainActor
struct RecommendationProfileCacheTests {

    @Test("The profile is built once per request, not once per candidate")
    func profileIsBuiltOncePerRequest() async throws {
        // Over 1200 candidates this is the difference between an instant screen
        // and a visible hang.
        let library = try makeRankedLibrary()
        let vm = makeViewModel(library: library, source: makeCrimeSource())

        _ = await vm.recommendations(type: .movie, mood: .crime)
        #expect(vm.profileRebuilds == 1)
    }

    @Test("Switching moods reuses the profile")
    func moodSwitchDoesNotRebuild() async throws {
        let library = try makeRankedLibrary()
        let source = makeFullStubSource()
        let vm = makeViewModel(library: library, source: source)

        _ = await vm.recommendations(type: .movie, mood: .crime)
        _ = await vm.recommendations(type: .movie, mood: .horror)
        _ = await vm.recommendations(type: .tvShow, mood: .dark)

        #expect(vm.profileRebuilds == 1)
    }

    @Test("Ranking something new invalidates the profile")
    func revisionChangeRebuilds() async throws {
        let container = try makeContainer()
        let library = try makeRankedLibrary(container: container)
        let vm = makeViewModel(library: library, source: makeCrimeSource())

        _ = await vm.recommendations(type: .movie, mood: .crime)
        #expect(vm.profileRebuilds == 1)

        // Any persisted mutation bumps `revision`.
        library.addToWantToWatch(
            MediaItem(externalId: "tmdb:movie:new", title: "New", year: 2024, type: .movie)
        )
        _ = await vm.recommendations(type: .movie, mood: .crime)

        #expect(vm.profileRebuilds == 2)
    }
}

// MARK: - Two-stage rerank

@Suite("RecommendationViewModel — retrieve then rerank")
@MainActor
struct RecommendationRerankTests {

    @Test("Stage two fetches only the head of the list, never the whole pool")
    func rerankIsBounded() async throws {
        // Enriching every candidate would be one request per pool title. The
        // whole point of two stages is that it is not.
        let library = try makeRankedLibrary()
        let features = CountingFeatureSource(keys: [Feature.genre("Drama").key])
        let vm = makeViewModel(
            library: library,
            source: makeCrimeSource(count: 200),
            featureSource: features
        )

        _ = await vm.recommendations(type: .movie, mood: .crime)

        #expect(features.calls <= RecommendationViewModel.rerankDepth)
        #expect(features.calls > 0)
    }

    @Test("Without a feature source the stage-one ranking stands")
    func rerankIsOptional() async throws {
        // Offline, or against the mock, genres and era are still real signal.
        // Discover degrades to a coarser list rather than to an empty one.
        let library = try makeRankedLibrary()
        let vm = makeViewModel(library: library, source: makeCrimeSource(), featureSource: nil)
        let result = await vm.recommendations(type: .movie, mood: .crime)

        #expect(result.isReady)
        #expect(!result.recommendations.isEmpty)
    }

    @Test("A failed feature fetch keeps the candidate at its stage-one score")
    func rerankFailureIsNotFatal() async throws {
        // Losing a candidate because TMDB was slow is worse than ranking it on
        // genres alone.
        final class FailingFeatureSource: FeatureSource, @unchecked Sendable {
            func features(type: MediaType, tmdbId: Int) async -> TMDBMediaService.ExtractedFeatures? { nil }
        }

        let library = try makeRankedLibrary()
        let plain = makeViewModel(library: library, source: makeCrimeSource())
        let failing = makeViewModel(
            library: library, source: makeCrimeSource(), featureSource: FailingFeatureSource()
        )

        let baseline = await plain.recommendations(type: .movie, mood: .crime)
        let degraded = await failing.recommendations(type: .movie, mood: .crime)

        #expect(baseline.recommendations.map(\.id) == degraded.recommendations.map(\.id))
        #expect(!degraded.recommendations.isEmpty)
    }

    @Test("Enrichment changes the score it was fetched for")
    func rerankActuallyRescores() async throws {
        // A pool candidate arrives with no features at all, so without stage two
        // every prediction is exactly the type baseline. If enrichment did not
        // rescore, the numbers here would be identical.
        let library = try makeRankedLibrary()
        let enriching = CountingFeatureSource(keys: [
            Feature.genre("Drama").key,
            Feature.keyword(id: 1, name: "tense").key,
        ])

        let plain = makeViewModel(library: library, source: makeCrimeSource())
        let reranked = makeViewModel(
            library: library, source: makeCrimeSource(), featureSource: enriching
        )

        let before = await plain.recommendations(type: .movie, mood: .crime)
        let after = await reranked.recommendations(type: .movie, mood: .crime)

        let beforeTop = try #require(before.recommendations.first)
        let afterTop = try #require(after.recommendations.first)

        #expect(beforeTop.predicted.value != afterTop.predicted.value)
        #expect(afterTop.predicted.familiesPresent.contains(.genre))
    }
}

// MARK: - Single-title prediction

@Suite("RecommendationViewModel — one title")
@MainActor
struct TitlePredictionTests {

    /// A pool with varied genres, warmed so a reference distribution exists.
    private func warmedViewModel(
        library: MediaLibraryViewModel,
        featureSource: FeatureSource? = nil
    ) async -> RecommendationViewModel {
        var genres: [String: [String]] = [:]
        let spread = ["Drama", "Comedy", "Horror"]
        for index in 0..<30 {
            genres["tmdb:movie:\(9000 + index)"] = [spread[index % spread.count]]
        }
        let builder = CandidatePoolBuilder(
            source: makeCrimeSource(count: 30, genres: genres),
            cache: makeDisabledCache()
        )
        await builder.refresh()
        return RecommendationViewModel(
            library: library, poolBuilder: builder, featureSource: featureSource
        )
    }

    private func unwatched(_ genres: [String] = ["Drama"]) -> MediaItem {
        MediaItem(
            externalId: "tmdb:movie:5555", title: "Unseen", year: 2016,
            type: .movie, genres: genres
        )
    }

    @Test("An unwatched title gets a prediction")
    func unwatchedTitlesArePredicted() async throws {
        let library = try makeRankedLibrary(movies: 20, shows: 6)
        let vm = await warmedViewModel(library: library)

        let prediction = try #require(await vm.prediction(for: unwatched()))
        #expect(prediction.predicted.value >= 0 && prediction.predicted.value <= 10)
        #expect(prediction.predicted.value.isFinite)
    }

    @Test("A watched title never gets one")
    func watchedTitlesAreSkipped() async throws {
        // It already has a real score the user earned. Showing a guess beside
        // it is the exact confusion the whole predicted/earned split avoids.
        let library = try makeRankedLibrary(movies: 20, shows: 6)
        let vm = await warmedViewModel(library: library)

        let watched = MediaItem(
            externalId: "tmdb:movie:5556", title: "Seen", year: 2016, type: .movie,
            watchedStatus: .watched, sentiment: .liked, score: 8.1
        )
        #expect(await vm.prediction(for: watched) == nil)
    }

    @Test("A library below the cold-start floor predicts nothing at all")
    func coldStartSuppressesPrediction() async throws {
        let library = try makeRankedLibrary(movies: 4, shows: 0)
        let vm = await warmedViewModel(library: library)

        #expect(await vm.prediction(for: unwatched()) == nil)
    }

    @Test("A film library does not license a prediction about television")
    func perTypeFloorAppliesToOneTitle() async throws {
        let library = try makeRankedLibrary(movies: 20, shows: 1)
        let vm = await warmedViewModel(library: library)

        let show = MediaItem(
            externalId: "tmdb:tv:777", title: "Some Show", year: 2016, type: .tvShow
        )
        #expect(await vm.prediction(for: show) == nil)
        #expect(await vm.prediction(for: unwatched()) != nil)
    }



    @Test("Reading one title never builds the pool")
    func detailTapDoesNotSweep() async throws {
        let library = try makeRankedLibrary(movies: 20, shows: 6)
        let source = makeFullStubSource()
        let vm = RecommendationViewModel(
            library: library,
            poolBuilder: CandidatePoolBuilder(source: source, cache: makeDisabledCache())
        )

        _ = await vm.prediction(for: unwatched())
        #expect(source.requests.isEmpty, "a detail tap paid for a full pool sweep")
    }

    @Test("Enrichment is used when a feature source is available")
    func predictionEnrichesTheTitle() async throws {
        // One fetch for one title, while the user is looking at it — the
        // difference between resting on two genres and resting on keywords,
        // cast and a director.
        let library = try makeRankedLibrary(movies: 20, shows: 6)
        let features = CountingFeatureSource(keys: [
            Feature.genre("Drama").key,
            Feature.director(id: 5, name: "Someone").key,
        ])
        let vm = await warmedViewModel(library: library, featureSource: features)

        let prediction = try #require(await vm.prediction(for: unwatched()))
        #expect(prediction.isEnriched)
        #expect(features.calls == 1)
        #expect(prediction.predicted.familiesPresent.contains(.director))
    }

    @Test("A title with no TMDB id still predicts, unenriched")
    func unenrichableTitlesDegrade() async throws {
        let library = try makeRankedLibrary(movies: 20, shows: 6)
        let features = CountingFeatureSource(keys: [Feature.genre("Drama").key])
        let vm = await warmedViewModel(library: library, featureSource: features)

        let legacy = MediaItem(
            externalId: "imdb:tt1375666", title: "Legacy", year: 2010,
            type: .movie, genres: ["Drama"]
        )
        let prediction = try #require(await vm.prediction(for: legacy))

        #expect(!prediction.isEnriched)
        #expect(features.calls == 0)
        #expect(prediction.predicted.familiesPresent.contains(.genre))
    }

    @Test("Lift tracks the raw estimate so the band is stable under calibration")
    func liftIgnoresCalibration() async throws {
        let library = try makeRankedLibrary(movies: 20, shows: 6)
        let vm = await warmedViewModel(library: library)

        let prediction = try #require(await vm.prediction(for: unwatched()))
        let profile = RecommendationEngine().buildProfile(from: library.allWatched)

        #expect(abs(prediction.lift
                    - (prediction.predicted.value - profile.baseline(for: .movie))) < 0.0001)
    }
}

// MARK: - Dismissal

@Suite("RecommendationViewModel — dismissal")
@MainActor
struct RecommendationDismissalTests {

    @Test("A dismissed title never reappears, under any mood")
    func dismissedTitlesAreExcludedEverywhere() async throws {
        let container = try makeContainer()
        let library = try makeRankedLibrary(movies: 20, shows: 6, container: container)

        let source = makeFullStubSource()
        let builder = CandidatePoolBuilder(source: source, cache: makeDisabledCache())
        let vm = RecommendationViewModel(library: library, poolBuilder: builder)

        // Take a title the recommender currently offers, and refuse it.
        let before = await vm.recommendations(type: .movie, mood: .crime, limit: 40)
        let victim = try #require(before.recommendations.first?.item)
        let victimID = try #require(victim.externalId)

        library.dismiss(victim)

        for mood in Mood.allCases {
            let after = await vm.recommendations(type: .movie, mood: mood, limit: 40)
            #expect(!after.recommendations.contains { $0.id == victimID },
                    "dismissed title came back under \(mood.rawValue)")
        }
    }

    @Test("Dismissal does not touch the ranking buckets")
    func dismissalIsNotAnOpinion() throws {
        // The user has not seen it. It must never acquire a sentiment, a score,
        // or a bucket position — a filter, not a rating.
        let library = try makeRankedLibrary()
        let before = library.allWatched.count

        let item = MediaItem(externalId: "tmdb:movie:404", title: "Refused", year: 2020, type: .movie)
        library.dismiss(item)

        #expect(library.allWatched.count == before)
        #expect(item.score == nil)
        #expect(item.sentiment == nil)
    }
}
