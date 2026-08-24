//
//  RecommendationViewModel.swift
//  WatchRank
//
//  The layer between the pure engine and the Discover screen: assemble
//  candidates, drop what the user has dealt with, apply the mood, rank, and
//  hand back a display-ready list.
//
//  The shape that matters here is **retrieve then rerank**, and it is not an
//  optimisation — without it the screen is broken. `/discover` returns genre
//  ids and a date and nothing else: no keywords, no credits, no runtime. So
//  every pool candidate arrives with `features == []`, and a single-pass design
//  would score all ~1200 of them at exactly the type baseline and rank them
//  alphabetically by tie-break, while every acceptance criterion still passed.
//
//    Stage 1 — score the whole pool on what costs nothing: `genre:` derived
//              from `genres` and `era:` from `year`, via
//              `RecommendationEngine.featureKeys(for:)`. Keep the top slice.
//    Stage 2 — fetch full features for that slice only, rescore, and return.
//
//  Stage 2 is best-effort. With no feature source, or offline, the stage-1
//  ranking stands: genres and era are real signal, so Discover degrades to a
//  coarser list rather than to an empty one.
//

import Foundation
import Observation

// MARK: - RecommendationViewModel

@MainActor
@Observable
final class RecommendationViewModel {

    // MARK: - Thresholds

    /// Watched titles needed overall before the app will predict anything.
    static let minimumLibraryForRecommendations = 10

    /// Watched titles needed *of the requested type*. The baselines are
    /// per-type, so a library of forty films says nothing about television.
    static let minimumPerTypeForRecommendations = 3

    /// How many stage-1 survivors are worth a metadata fetch.
    ///
    /// Sized against the returned `limit` rather than the pool: reranking
    /// exists to reorder the head of the list, and a title that placed 200th on
    /// genre alone is not going to reach the top twenty on keywords.
    static let rerankDepth = 60

    /// The share of the returned list any one genre may occupy.
    static let genreCap = 0.4

    // MARK: - Dependencies

    @ObservationIgnored private let library: MediaLibraryViewModel
    @ObservationIgnored private let poolBuilder: CandidatePoolBuilder
    @ObservationIgnored private let engine: RecommendationEngine
    @ObservationIgnored private let featureSource: FeatureSource?

    // MARK: - Observable state

    private(set) var isLoading = false

    /// How many times a `TasteProfile` has actually been built.
    ///
    /// A diagnostic, not a test hook: roadmap Phase 18 budgets profile build +
    /// rank + diversity over the full pool at under 100 ms, and the single
    /// worst way to blow that is rebuilding the profile per candidate. This
    /// makes the difference observable instead of inferred.
    private(set) var profileRebuilds = 0

    /// How many times the rating calibration has been fitted. Same purpose as
    /// `profileRebuilds`: fitting is O(library) profile builds, so doing it per
    /// request rather than per library change is the expensive mistake.
    private(set) var calibrationFits = 0

    // MARK: - Cached profile

    @ObservationIgnored private var cachedProfile: TasteProfile?
    @ObservationIgnored private var cachedProfileRevision: Int?

    @ObservationIgnored private var cachedCalibration: RatingCalibration?
    @ObservationIgnored private var cachedCalibrationRevision: Int?

    // MARK: - Init

    init(
        library: MediaLibraryViewModel,
        poolBuilder: CandidatePoolBuilder,
        engine: RecommendationEngine = RecommendationEngine(),
        featureSource: FeatureSource? = nil
    ) {
        self.library = library
        self.poolBuilder = poolBuilder
        self.engine = engine
        self.featureSource = featureSource
    }

    // MARK: - Requests

    func recommendations(
        type: MediaType,
        mood: Mood,
        limit: Int = 20
    ) async -> RecommendationResult {
        isLoading = true
        defer { isLoading = false }

        let watched = library.allWatched
        let watchedOfType = watched.filter { $0.type == type }

        // Cold start, checked before any work: below the floor there is no
        // honest answer, and a confidently wrong list costs more trust than an
        // empty state does.
        if watched.count < Self.minimumLibraryForRecommendations {
            return .needsMoreRankings(
                have: watched.count,
                need: Self.minimumLibraryForRecommendations,
                type: nil
            )
        }
        if watchedOfType.count < Self.minimumPerTypeForRecommendations {
            return .needsMoreRankings(
                have: watchedOfType.count,
                need: Self.minimumPerTypeForRecommendations,
                type: type
            )
        }

        let excluded = excludedExternalIds()
        let queued = queuedExternalIds()

        let pool = await poolBuilder.pool(excluding: excluded)
        // Both sides canonicalised. Comparing a raw pool id against a
        // canonicalised library id is the exact mismatch Phase 12a exists to
        // prevent, and it fails the quiet way: a title the user has already
        // ranked reappears as a recommendation.
        let candidates = pool.candidates(mood: mood, type: type)
            .filter { !excluded.contains(ExternalID.canonical($0.externalId)) }

        guard !candidates.isEmpty else {
            return .noCandidates(poolIsEmpty: pool.isEmpty)
        }

        let profile = profile(for: watched)
        let baseline = profile.baseline(for: type)

        // Stage 1 — the whole mood pool, on features that cost no network call.
        let stageOne = candidates
            .map { pooled -> Scored in
                let features = CandidateFeatures(pooled.makeMediaItem())
                return Scored(pooled: pooled, features: features,
                              predicted: engine.predict(features, using: profile))
            }
            .sorted { sortsBefore($0, $1, mood: mood, baseline: baseline) }

        // Stage 2 — enrich only the head, then rescore it.
        let head = Array(stageOne.prefix(Self.rerankDepth))
        let enriched = await rerank(head, using: profile)
        let reranked = enriched
            .sorted { sortsBefore($0, $1, mood: mood, baseline: baseline) }

        let diversified = applyGenreCap(to: reranked, limit: limit)

        // Map onto the user's own scale.
        //
        // A per-user affine transform learned from leave-one-out error, so a
        // candidate's displayed rating depends only on what the model thinks of
        // *it* — never on which other candidates it happened to be listed
        // beside. The batch is irrelevant here, and that is the point: the
        // previous percentile map handed the top of every mood's list the
        // user's maximum score by arithmetic.
        let calibration = calibration(for: watched)
        let calibrated = diversified.map { $0.predicted.withDisplayValue(
            calibration.apply($0.predicted.value)
        ) }

        return .ready(zip(diversified, calibrated).map { scored, predicted in
            Recommendation(
                item: scored.pooled.makeMediaItem(),
                predicted: predicted,
                moodWeight: mood.relevance(isPoolMember: true),
                isQueued: queued.contains(ExternalID.canonical(scored.pooled.externalId)),
                lift: predicted.value - baseline
            )
        })
    }

    // MARK: - One title

    /// What the user would probably score a title they have not watched.
    ///
    /// `nil` when there is nothing honest to say: a watched title already has a
    /// real score, and a library below the cold-start floor cannot support a
    /// guess about anything.
    ///
    /// Unlike the Discover path this **enriches first and asks questions
    /// later** — one detail fetch for one title, while the user is sitting on
    /// the screen looking at it. Discover cannot afford that per candidate;
    /// here it is the difference between a prediction resting on two genres and
    /// one resting on keywords, cast and a director.
    func prediction(for item: MediaItem) async -> TitlePrediction? {
        guard item.watchedStatus != .watched else { return nil }

        let watched = library.allWatched
        guard watched.count >= Self.minimumLibraryForRecommendations,
              watched.filter({ $0.type == item.type }).count >= Self.minimumPerTypeForRecommendations
        else { return nil }

        let profile = profile(for: watched)

        var features = CandidateFeatures(item)
        var isEnriched = false
        if let enriched = await enrichedFeatures(for: item) {
            features = enriched
            isEnriched = true
        }

        let raw = engine.predict(features, using: profile)
        let calibrated = raw.withDisplayValue(calibration(for: watched).apply(raw.value))

        return TitlePrediction(
            predicted: calibrated,
            // Lift tracks the *raw* estimate: calibration is a display
            // transform, and letting it move the lift would make the
            // qualitative band depend on how confident the app happens to be,
            // which is the other axis entirely.
            lift: raw.value - profile.baseline(for: item.type),
            isEnriched: isEnriched
        )
    }

    private func enrichedFeatures(for item: MediaItem) async -> CandidateFeatures? {
        guard let featureSource,
              let externalId = item.externalId,
              let parsed = TMDBIdentifier.parse(externalId),
              let fetched = await featureSource.features(type: parsed.type, tmdbId: parsed.tmdbId),
              !fetched.keys.isEmpty
        else { return nil }

        return CandidateFeatures(id: item.id, type: item.type, keys: fetched.keys)
    }

    // MARK: - Profile

    /// Built once per request and reused across every candidate, cached against
    /// the library's `revision` so switching moods does not rebuild it.
    ///
    /// Building per candidate would be O(library × pool) — over 1200 candidates
    /// that is the difference between an instant screen and a visible hang.
    private func profile(for watched: [MediaItem]) -> TasteProfile {
        if let cachedProfile, cachedProfileRevision == library.revision {
            return cachedProfile
        }
        let built = engine.buildProfile(from: watched)
        cachedProfile = built
        cachedProfileRevision = library.revision
        profileRebuilds += 1
        return built
    }

    // MARK: - Calibration

    /// The user's learned rating calibration, rebuilt only when the library
    /// changes.
    ///
    /// Fitting costs one profile build per watched item, so this is cheap for a
    /// realistic library and pointless to repeat per request. `.identity` until
    /// there are enough matched pairs to learn from — which is the correct
    /// mapping in the absence of evidence, not a placeholder.
    func calibration(for watched: [MediaItem]) -> RatingCalibration {
        if let cachedCalibration, cachedCalibrationRevision == library.revision {
            return cachedCalibration
        }
        let fitted = engine.calibration(for: watched)
        cachedCalibration = fitted
        cachedCalibrationRevision = library.revision
        calibrationFits += 1
        return fitted
    }

    // MARK: - Exclusions

    /// Titles the user has already dealt with.
    ///
    /// Watched or dismissed. `.wantToWatch` is deliberately *kept* — the user
    /// asked for unwatched titles and a queued one is unwatched — and flagged
    /// on the `Recommendation` instead.
    private func excludedExternalIds() -> Set<String> {
        Set(library.allItems
            .filter { $0.watchedStatus == .watched || $0.dismissed }
            .compactMap(\.externalId)
            .map(ExternalID.canonical))
    }

    private func queuedExternalIds() -> Set<String> {
        Set(library.allItems
            .filter { $0.watchedStatus == .wantToWatch }
            .compactMap(\.externalId)
            .map(ExternalID.canonical))
    }

    // MARK: - Ranking

    /// The sort quantity: **taste lift scaled by mood match, never the raw
    /// predicted value.**
    ///
    /// `value * moodWeight` would scale the type baseline too, and the baseline
    /// is most of the number while being identical for every candidate of a
    /// type. On a fixture with `baseline = 6.045`, a candidate with +0.70 lift
    /// at 0.9 mood weight scores 6.07 while one with +0.20 lift at 1.0 scores
    /// 6.25 — so a tenth of mood relevance beats three and a half times the
    /// taste fit. Relevance stops contributing and starts dominating.
    ///
    /// Invisible while `moodWeight` is binary; a live bug the moment moods are
    /// graded. See roadmap Phase 15 step 4.
    private func rank(_ scored: Scored, mood: Mood, baseline: Double) -> Double {
        Self.rankingScore(
            value: scored.predicted.value,
            baseline: baseline,
            moodWeight: mood.relevance(isPoolMember: true)
        )
    }

    /// The ranking quantity, extracted so the claim above can be asserted
    /// directly.
    ///
    /// It cannot be caught through the public API today: `moodWeight` is binary,
    /// so `value * weight` and `lift * weight` induce the *same order*. The bug
    /// only appears once weights vary — which is precisely why it needs a test
    /// now rather than after someone grades the moods.
    static func rankingScore(value: Double, baseline: Double, moodWeight: Double) -> Double {
        (value - baseline) * moodWeight
    }

    /// The single comparator both stages sort by, so they cannot drift apart.
    ///
    /// Total and deterministic: ranking on score alone would leave equal scores
    /// in whatever order the pool happened to hold them, and the list would
    /// reshuffle between renders. Title first because it is what the user sees;
    /// `externalId` behind it because two films really can share a title.
    private func sortsBefore(
        _ lhs: Scored, _ rhs: Scored, mood: Mood, baseline: Double
    ) -> Bool {
        let left = rank(lhs, mood: mood, baseline: baseline)
        let right = rank(rhs, mood: mood, baseline: baseline)
        if left != right { return left > right }
        if lhs.pooled.title != rhs.pooled.title {
            return lhs.pooled.title < rhs.pooled.title
        }
        return lhs.pooled.externalId < rhs.pooled.externalId
    }

    // MARK: - Stage 2

    /// Fetches full features for the stage-1 head and rescores it.
    ///
    /// Best effort throughout: a title whose fetch fails keeps its stage-1
    /// score rather than dropping out. Losing a candidate because TMDB was slow
    /// would be a worse failure than ranking it on genres alone.
    private func rerank(_ head: [Scored], using profile: TasteProfile) async -> [Scored] {
        guard let featureSource, !head.isEmpty else { return head }

        var enriched: [Scored] = []
        enriched.reserveCapacity(head.count)

        for scored in head {
            guard let parsed = TMDBIdentifier.parse(scored.pooled.externalId),
                  let fetched = await featureSource.features(
                      type: parsed.type, tmdbId: parsed.tmdbId
                  ),
                  !fetched.keys.isEmpty
            else {
                enriched.append(scored)
                continue
            }

            let features = CandidateFeatures(
                id: scored.features.id,
                type: scored.pooled.type,
                keys: fetched.keys
            )
            enriched.append(
                Scored(pooled: scored.pooled, features: features,
                       predicted: engine.predict(features, using: profile))
            )
        }

        return enriched
    }

    // MARK: - Diversity

    /// Caps any single genre at `genreCap` of the returned list, backfilling
    /// from the next-best candidates.
    ///
    /// Without it a user who rates crime highly gets twenty crime titles, which
    /// is technically their best twenty and useless as a browsing surface.
    ///
    /// - Important: the cap is a **soft** target, and backfill can exceed it.
    ///   The two goals are arithmetically incompatible on a narrow pool: with a
    ///   limit of 20 and a cap of 8, titles spread over two genres can only fill
    ///   16 slots. The cap is what gives, because eight rows on a browsing
    ///   screen is a worse outcome than a concentrated twenty — and the deferred
    ///   candidates are the next-best ones anyway, not filler. Where the pool
    ///   has the breadth to satisfy both, the cap holds exactly.
    private func applyGenreCap(to scored: [Scored], limit: Int) -> [Scored] {
        guard limit > 0 else { return [] }

        let cap = max(1, Int((Double(limit) * Self.genreCap).rounded(.up)))
        var counts: [String: Int] = [:]
        var accepted: [Scored] = []
        var deferred: [Scored] = []

        for candidate in scored {
            guard accepted.count < limit else { break }
            let genres = candidate.pooled.genres

            if genres.contains(where: { (counts[$0] ?? 0) >= cap }) {
                deferred.append(candidate)
                continue
            }
            for genre in genres { counts[genre, default: 0] += 1 }
            accepted.append(candidate)
        }

        if accepted.count < limit {
            accepted.append(contentsOf: deferred.prefix(limit - accepted.count))
        }
        return accepted
    }

    // MARK: - Scored

    /// A candidate mid-pipeline. Kept separate from `Recommendation` so the
    /// stages work in value types and no `MediaItem` is materialised until the
    /// list is final.
    private struct Scored {
        let pooled: PooledTitle
        let features: CandidateFeatures
        let predicted: PredictedScore
    }
}
