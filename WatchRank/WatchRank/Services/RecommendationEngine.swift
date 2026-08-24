//
//  RecommendationEngine.swift
//  WatchRank
//
//  Pure prediction logic. Imports only Foundation — no SwiftData, no SwiftUI,
//  no URLSession — exactly like `RankingEngine`, and testable the same way.
//
//  The engine turns a ranked library into a `TasteProfile`, then scores
//  arbitrary candidates against it. It never branches per feature family: it
//  shrinks residuals over whatever namespaced keys it is handed, which is what
//  lets a future family be added without touching this file.
//
//  The estimator is a shrunk mean of residuals per feature — empirical Bayes in
//  shape. It is deliberately not a regression. Features co-occur heavily (every
//  Nolan film is also `composer:Hans Zimmer`), so a naive per-feature mean
//  double-counts, and ridge over the one-hot matrix is the principled fix. It is
//  not the right call at this size: it needs a solver, it degrades badly at
//  n = 0, and it cannot hand Phase 19 a per-feature number it can put in a
//  sentence. The two-level averaging in `predict` damps the double-counting
//  enough for a ranking task. Revisit only if Phase 17's cross-validation says
//  the naive estimator is losing.
//
//  Calibration onto the user's scale lives in `RatingCalibration`, learned from
//  leave-one-out error rather than from where a candidate ranks among other
//  candidates — see that file for why the earlier percentile map was wrong.
//
//  See `docs/PHASE-13-PLAN.md` for the derivation of every choice here.
//

import Foundation

// MARK: - RecommendationEngine

struct RecommendationEngine {

    var tuning: RecommendationTuning

    init(tuning: RecommendationTuning = .standard) {
        self.tuning = tuning
    }

    /// How many contributors `PredictedScore.topContributingFeatures` keeps.
    /// Three is what a one-line rationale can name without becoming a list.
    static let maxContributions = 3

    // MARK: - Feature extraction

    /// The feature keys the engine will actually use for an item.
    ///
    /// Returns `item.features` when it has been backfilled, validated and
    /// deduplicated through `Feature` so an unrecognised or corrupt key becomes
    /// one less feature rather than a crash.
    ///
    /// Falls back to **deriving** `genre:` and `era:` keys from `genres` and
    /// `year` when the array is empty, which matters in two places that look
    /// unrelated and are not:
    ///
    ///   - **Candidates from the pool have no features at all.** `/discover`
    ///     returns genre ids and a date and nothing else — no keywords, no
    ///     credits, no runtime — so every pool title arrives with
    ///     `features == []`. Without this fallback every prediction would equal
    ///     the type baseline and Discover would rank alphabetically by
    ///     tie-break. This derivation is what makes the cheap first pass of a
    ///     retrieve-then-rerank pipeline possible.
    ///   - **Library items whose backfill never ran** — airplane mode, or an
    ///     unmigrated IMDb id — would otherwise contribute no feature evidence
    ///     whatsoever. `MockMediaService` already derives genre features at its
    ///     own boundary, so this is one implementation of a rule the codebase
    ///     has already committed to.
    static func featureKeys(for item: MediaItem) -> [String] {
        guard item.features.isEmpty else {
            return item.features.features.keys
        }
        return derivedFeatureKeys(for: item)
    }

    /// The subset of the feature space that needs no network call: genres,
    /// which the catalog already resolves, and the era band implied by `year`.
    static func derivedFeatureKeys(for item: MediaItem) -> [String] {
        var derived = item.genres.map(Feature.genre)
        if let era = Feature.era(year: item.year) {
            derived.append(era)
        }
        return derived.keys
    }

    // MARK: - Profile

    /// Builds the taste profile once, for reuse across every candidate.
    ///
    /// Filters to watched items that actually carry a score, rather than
    /// trusting the caller to have done it.
    ///
    /// - Note: this does **not** exclude an item mid-comparison.
    ///   `MediaLibraryViewModel.markWatched` seats a new item at its bucket
    ///   midpoint *before* opening the session, so a provisional item is
    ///   indistinguishable from a settled one at this layer — it is watched and
    ///   it has a score. The engine is pure and has no notion of a session, so
    ///   it cannot tell them apart and does not try. The effect is benign: a
    ///   provisional score is the band midpoint, so it contributes a residual of
    ///   roughly "typical for this sentiment", which is a fair prior for an item
    ///   whose exact position is still being decided. A caller that wants them
    ///   excluded should filter on `MediaLibraryViewModel.isRankingInProgress`
    ///   before calling — noted for roadmap Phase 15, which owns that decision.
    func buildProfile(from watched: [MediaItem]) -> TasteProfile {
        buildProfile(from: watched.compactMap(RankedSnapshot.init))
    }

    /// The profile core, over plain values.
    ///
    /// Cross-validation needs to build profiles for libraries that do not
    /// exist — a fold with one title removed and every remaining score
    /// re-derived — and it cannot do that against `@Model` objects without
    /// rewriting the user's real data.
    func buildProfile(from snapshots: [RankedSnapshot]) -> TasteProfile {
        let items = snapshots

        guard !items.isEmpty else {
            return TasteProfile(
                globalMean: tuning.neutralScore,
                baselinesByType: [:],
                watchedCountsByType: [:],
                featureEffects: [:],
                featureSupport: [:],
                droppedBelowFloor: [:],
                itemTypes: [:],
                scoresByType: [:],
                tuning: tuning
            )
        }

        // MARK: Baselines

        var countsByType: [MediaType: Int] = [:]
        var sumByType: [MediaType: Double] = [:]
        var scoresByType: [MediaType: [Double]] = [:]
        var itemTypes: [UUID: MediaType] = [:]
        var globalSum = 0.0

        for item in items {
            let score = item.score
            globalSum += score
            countsByType[item.type, default: 0] += 1
            sumByType[item.type, default: 0] += score
            scoresByType[item.type, default: []].append(score)
            itemTypes[item.id] = item.type
        }

        let globalMean = globalSum / Double(items.count)

        // Shrink each type's mean toward the global mean. With a healthy
        // library this is just the type mean; with two ranked shows it mostly
        // falls back rather than swinging on a single opinion.
        var baselinesByType: [MediaType: Double] = [:]
        for (type, count) in countsByType {
            let n = Double(count)
            let mean = (sumByType[type] ?? 0) / n
            let k = max(0, tuning.typeShrinkage)
            baselinesByType[type] = (n * mean + k * globalMean) / (n + k)
        }

        // MARK: Residuals per feature

        // Residuals rather than raw means, so a feature effect is independent
        // of the type baseline: "I rate TV harshly" must not be counted a
        // second time into every TV genre.
        var featureSupport: [String: Set<UUID>] = [:]
        var residualSums: [String: Double] = [:]

        for item in items {
            let residual = item.score - (baselinesByType[item.type] ?? globalMean)
            for key in item.keys {
                featureSupport[key, default: []].insert(item.id)
                residualSums[key, default: 0] += residual
            }
        }

        // MARK: Shrinkage and the inclusion floor

        var featureEffects: [String: Double] = [:]
        var droppedBelowFloor: [Feature.Family: Int] = [:]

        for (key, backers) in featureSupport {
            guard let feature = Feature(key: key) else { continue }
            let family = feature.family
            let support = backers.count

            // Shrinkage handles a feature seen twice. It does not help a
            // feature seen once, where the "effect" is one title's residual and
            // nothing else — that gets dropped rather than shrunk, so it costs
            // no denominator either.
            guard support >= tuning.inclusionFloor(family) else {
                droppedBelowFloor[family, default: 0] += 1
                continue
            }

            let denominator = Double(support) + max(0, tuning.shrinkage(family))
            guard denominator > 0 else { continue }
            featureEffects[key] = (residualSums[key] ?? 0) / denominator
        }

        return TasteProfile(
            globalMean: globalMean,
            baselinesByType: baselinesByType,
            watchedCountsByType: countsByType,
            featureEffects: featureEffects,
            featureSupport: featureSupport,
            droppedBelowFloor: droppedBelowFloor,
            itemTypes: itemTypes,
            scoresByType: scoresByType.mapValues { $0.sorted() },
            tuning: tuning
        )
    }

    // MARK: - Prediction

    /// Scores one candidate. Pure in `(profile, candidate)` — no caching, no
    /// hidden state, because Phase 17's leave-one-out folds must be independent
    /// and anything remembered between calls quietly correlates them.
    func predict(_ candidate: CandidateFeatures, using profile: TasteProfile) -> PredictedScore {
        let baseline = profile.baseline(for: candidate.type)
        let byFamily = candidate.featuresByFamily()

        // Prediction divides by the full weight sum, so a family the candidate
        // has no features for contributes zero and pulls the estimate toward
        // baseline. That is the honest prior for an absent family, and it is
        // what makes a first-pass score over metadata-poor pool candidates safe.
        //
        // The alternative — renormalising over present families — gives a
        // sparse title's few features full leverage. It is a flag rather than a
        // decision because cross-validation answers it and argument does not.
        let predictionDenominator = tuning.renormalizeOverPresentFamilies
            ? byFamily.keys.reduce(0) { $0 + tuning.weight($1) }
            : tuning.totalWeight

        // Confidence always divides by the full weight sum, whatever the
        // prediction does. Renormalising here would hand a candidate described
        // by two dense families the same confidence as one described by ten —
        // the precise failure this formula was rewritten to fix.
        let coverageDenominator = tuning.totalWeight

        guard predictionDenominator > 0, coverageDenominator > 0 else {
            return .neutral(clamp(baseline))
        }

        var lift = 0.0
        var featureConfidence = 0.0
        var evidence = 0.0
        var contributions: [FeatureContribution] = []

        // Iterate a fixed family order rather than the dictionary's. Floating
        // point addition is not associative, so dictionary order would make the
        // last decimal place depend on hashing — and Phase 17 measures a rank
        // correlation over these numbers.
        for family in Feature.Family.allCases {
            guard let features = byFamily[family], !features.isEmpty else { continue }

            let familySize = Double(features.count)
            let weight = tuning.weight(family)

            var effectSum = 0.0
            var supportSum = 0.0

            for feature in features {
                let key = feature.key
                let effect = profile.effect(key)
                let support = profile.effectiveSupport(key)

                // An unknown feature contributes 0 to the numerator but still
                // counts in `familySize`. A candidate tagged [Horror (+2.4),
                // Comedy (never seen)] gets +1.2, not +2.4 — an unknown feature
                // is evidence of nothing and should dilute.
                effectSum += effect
                supportSum += Double(support)

                if effect != 0 {
                    contributions.append(
                        FeatureContribution(
                            feature: feature,
                            amount: weight * effect / familySize / predictionDenominator,
                            support: support
                        )
                    )
                }
            }

            let familyEffect = effectSum / familySize
            lift += weight * familyEffect / predictionDenominator

            // Support is normalised against a per-family scale before being
            // combined. The families differ by an order of magnitude in natural
            // density — a genre reaches 7 in a 40-film library where a keyword
            // sits at 1 — so a flat mean across them measures which families
            // happen to be present rather than how much the app knows.
            let familySupport = supportSum / familySize
            let scale = max(tuning.evidenceFull(family), .leastNonzeroMagnitude)
            featureConfidence += weight * min(1, familySupport / scale) / coverageDenominator
            evidence += weight * familySupport / coverageDenominator
        }

        // Two independent ways to be ignorant, and both must be satisfied: "I
        // know nothing about your taste in these features" and "I know nothing
        // about your taste in this media type."
        let typeScale = max(tuning.typeEvidenceFull, .leastNonzeroMagnitude)
        let typeConfidence = min(1, Double(profile.watchedCount(of: candidate.type)) / typeScale)
        let confidence = clampUnit(featureConfidence * typeConfidence)

        contributions.sort { lhs, rhs in
            lhs.amount != rhs.amount ? lhs.amount > rhs.amount : lhs.feature.key < rhs.feature.key
        }

        return PredictedScore(
            value: clamp(baseline + lift),
            confidence: confidence,
            evidence: evidence.isFinite ? evidence : 0,
            familiesPresent: Set(byFamily.keys),
            topContributingFeatures: Array(
                contributions.filter { $0.amount > 0 }.prefix(Self.maxContributions)
            )
        )
    }

    /// Convenience for tests and one-off call sites. The hot path should snapshot
    /// once and score the snapshot.
    func predict(_ item: MediaItem, using profile: TasteProfile) -> PredictedScore {
        predict(CandidateFeatures(item), using: profile)
    }

    // MARK: - Calibration

    /// Leave-one-out matched pairs over the user's own library: what the engine
    /// would have predicted for each watched title had it never seen it, beside
    /// what the user actually scored it.
    ///
    /// The input `RatingCalibration.fit` learns from, and the harness roadmap
    /// Phase 17 measures accuracy with. Rebuilding the profile per fold is what
    /// makes the folds independent — predicting a title from a profile that
    /// contains it would report the model's memory rather than its skill.
    ///
    /// O(n) profile builds for n items, each O(library x features): a hundred
    /// item library is a few hundred thousand operations, which is why this can
    /// simply be recomputed rather than cached across sessions.
    ///
    /// - Important: every fold **re-derives the remaining scores**. See below.
    func leaveOneOutPairs(for watched: [MediaItem]) -> [(raw: Double, actual: Double)] {
        leaveOneOutPairs(for: watched.compactMap(RankedSnapshot.init))
    }

    func leaveOneOutPairs(for snapshots: [RankedSnapshot]) -> [(raw: Double, actual: Double)] {
        guard snapshots.count >= 2 else { return [] }

        return snapshots.map { held in
            // Recompute the remaining library rather than deleting one row from
            // it. The score is a *quantile over its bucket*, not an independent
            // observation, so removing a title changes every other title's
            // score — and skipping that re-derivation breaks the invariant that
            // a bucket averages its band midpoint.
            //
            // The cost of getting this wrong is not subtle. Leaving the other
            // scores stale makes the fold's baseline a decreasing function of
            // the held-out score: hold out a high scorer and the mean of what
            // remains drops. Measured on a real 41-title library that artefact
            // alone correlated -0.885 with the held-out score and swamped the
            // model, reporting -0.394 for a model that is in fact +0.187.
            let remaining = snapshots
                .filter { $0.id != held.id }
                .recomputingScores()

            let profile = buildProfile(from: remaining)
            let raw = predict(held.candidate, using: profile).value

            // Compared against the score the user's library actually holds.
            return (raw: raw, actual: held.score)
        }
    }

    /// Measures the model against the user's own library by cross-validation.
    ///
    /// This is the accountability surface: everything before it is a plausible
    /// algorithm, and this is what says whether it is a working one.
    func accuracy(for watched: [MediaItem]) -> PredictionAccuracy {
        accuracy(for: watched.compactMap(RankedSnapshot.init))
    }

    func accuracy(for snapshots: [RankedSnapshot]) -> PredictionAccuracy {
        guard snapshots.count >= 2 else { return .empty }

        var predicted: [Double] = []
        var actual: [Double] = []
        var confidences: [Double] = []
        var baselineNull: [Double] = []
        var sentiments: [Sentiment?] = []

        for held in snapshots {
            let fold = snapshots.filter { $0.id != held.id }.recomputingScores()
            let profile = buildProfile(from: fold)
            let score = predict(held.candidate, using: profile)

            predicted.append(score.value)
            actual.append(held.score)
            confidences.append(score.confidence)
            baselineNull.append(profile.baseline(for: held.type))
            sentiments.append(held.sentiment)
        }

        let n = Double(snapshots.count)

        // The hard null: the midpoint of whichever bucket the user reaches for
        // most. It encodes the one fact that carries most of the signal, which
        // is why beating the easy null alone proves little.
        var bucketCounts: [Sentiment: Int] = [:]
        for sentiment in sentiments.compactMap({ $0 }) {
            bucketCounts[sentiment, default: 0] += 1
        }
        let modal = bucketCounts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.rawValue > rhs.key.rawValue
        }?.key
        let modalMidpoint = modal.map {
            ($0.scoreRange.lowerBound + $0.scoreRange.upperBound) / 2
        } ?? tuning.neutralScore

        func mae(_ estimates: [Double]) -> Double {
            zip(estimates, actual).reduce(0) { $0 + abs($1.0 - $1.1) } / n
        }

        // Precision@10 over the Liked bucket.
        let byPrediction = predicted.indices.sorted { predicted[$0] > predicted[$1] }
        let topTen = byPrediction.prefix(10)
        let liked = topTen.filter { sentiments[$0] == .liked }.count
        let precision = topTen.isEmpty ? nil : Double(liked) / Double(topTen.count)

        return PredictionAccuracy(
            sampleSize: snapshots.count,
            spearman: Ranks.spearman(predicted, actual),
            significanceThreshold: 1.96 / max(1, n - 1).squareRoot(),
            meanAbsoluteError: mae(predicted),
            baselineNullError: mae(baselineNull),
            modalNullError: mae(Array(repeating: modalMidpoint, count: snapshots.count)),
            precisionAtTen: precision,
            errorByConfidenceDecile: Self.errorByDecile(
                confidences: confidences, predicted: predicted, actual: actual
            )
        )
    }

    /// Mean absolute error per confidence decile, least confident first.
    private static func errorByDecile(
        confidences: [Double], predicted: [Double], actual: [Double]
    ) -> [Double] {
        let order = confidences.indices.sorted { confidences[$0] < confidences[$1] }
        guard order.count >= 3 else { return [] }

        // As many buckets as the sample can fill with at least three each —
        // ten deciles over forty items would be four per bucket of pure noise.
        let bucketCount = max(2, min(10, order.count / 3))
        let size = Double(order.count) / Double(bucketCount)

        return (0..<bucketCount).compactMap { index in
            let lower = Int((Double(index) * size).rounded())
            let upper = Int((Double(index + 1) * size).rounded())
            guard upper > lower else { return nil }
            let slice = order[lower..<upper]
            return slice.reduce(0.0) { $0 + abs(predicted[$1] - actual[$1]) } / Double(slice.count)
        }
    }

    /// Fits the mapping from raw estimates onto this user's rating scale.
    ///
    /// Returns `.identity` for a library with nothing to learn from, which is
    /// the correct answer rather than a fallback: with no evidence that the
    /// model is mis-scaled, the honest display is the raw conditional
    /// expectation.
    func calibration(for watched: [MediaItem]) -> RatingCalibration {
        RatingCalibration.fit(pairs: leaveOneOutPairs(for: watched), tuning: tuning)
    }

    // MARK: - Helpers

    /// Clamps to the 0–10 score scale, and converts a non-finite value into the
    /// neutral midpoint rather than letting a `NaN` reach a view.
    private func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return tuning.neutralScore }
        return min(10.0, max(0.0, value))
    }

    private func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1.0, max(0.0, value))
    }
}
