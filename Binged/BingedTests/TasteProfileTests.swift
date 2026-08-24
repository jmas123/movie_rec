//
//  TasteProfileTests.swift
//  BingedTests
//
//  Profile construction: baselines, residuals, per-family shrinkage, and the
//  inclusion floor. Store-free — the engine never sees SwiftData, so neither
//  does its test.
//

import Foundation
import Testing
@testable import Binged

@Suite("TasteProfile")
struct TasteProfileTests {

    // MARK: - Degenerate libraries

    @Test("An empty library yields a valid, empty profile")
    func emptyLibrary() {
        let profile = RecommendationEngine().buildProfile(from: [MediaItem]())

        #expect(profile.isEmpty)
        #expect(profile.globalMean == RecommendationTuning.standard.neutralScore)
        #expect(profile.baseline(for: .movie) == 5.0)
        #expect(profile.baseline(for: .tvShow) == 5.0)
        #expect(profile.featureEffects.isEmpty)
        #expect(profile.watchedCount(of: .movie) == 0)
        #expect(profile.globalMean.isFinite)
    }

    @Test("Unwatched and unscored items are excluded")
    func onlyScoredWatchedItemsCount() {
        let queued = MediaItem(title: "Queued", year: 2024, type: .movie, watchedStatus: .wantToWatch)
        let scoreless = MediaItem(title: "Scoreless", year: 2024, type: .movie, watchedStatus: .watched)
        let ranked = makeScored("Ranked", score: 8.0, features: [Feature.genre("Horror").key])

        let profile = RecommendationEngine().buildProfile(from: [queued, scoreless, ranked])

        #expect(profile.watchedCount(of: .movie) == 1)
        #expect(profile.itemTypes.count == 1)
    }

    // MARK: - Baselines

    @Test("A bucket's mean score is exactly its band midpoint, for every N")
    func bucketMeanIsBandMidpoint() {
        // The whole baseline argument rests on this: `mean_t` is a pure function
        // of the user's sentiment mix and carries no information about
        // within-bucket ordering. If `recomputeScores` ever stops producing a
        // symmetric inset, the baseline stops meaning what the engine assumes.
        for sentiment in Sentiment.allCases {
            let range = sentiment.scoreRange
            let midpoint = (range.lowerBound + range.upperBound) / 2

            for count in [1, 2, 5, 20, 77] {
                let scores = bucketScores(count: count, range: range)
                let mean = scores.reduce(0, +) / Double(count)
                #expect(abs(mean - midpoint) < 0.0001, "\(sentiment) at N=\(count)")
            }
        }
    }

    @Test("The plan's worked fixture reproduces its stated arithmetic")
    func planFixtureArithmetic() {
        let profile = RecommendationEngine().buildProfile(from: makePlanFixtureLibrary())

        // 20 liked / 12 fine / 8 disliked films: (20*8.4 + 12*5.05 + 8*1.65)/40.
        #expect(abs(profile.globalMean - 6.045) < 0.0001)

        // Only one type, so the type mean *is* the global mean and shrinking one
        // toward the other is a no-op.
        #expect(abs(profile.baseline(for: .movie) - 6.045) < 0.0001)

        // Top 8 of the liked bucket sum to 74.88; residual sum is
        // 74.88 - 8*6.045 = 26.52; shrunk by K_GENRE = 3 over support 8.
        let horror = Feature.genre("Horror").key
        #expect(profile.featureSupport[horror]?.count == 8)
        #expect(abs(profile.effect(horror) - (26.52 / 11.0)) < 0.0001)
    }

    @Test("Type baselines stay independent of each other")
    func typeBaselinesAreIndependent() {
        // 20 generously-rated films, 5 harshly-rated shows.
        var library = bucketScores(count: 20, range: Sentiment.liked.scoreRange)
            .enumerated()
            .map { makeScored("film-\($0.offset)", score: $0.element, type: .movie) }

        let filmOnly = RecommendationEngine().buildProfile(from: library)
        #expect(abs(filmOnly.baseline(for: .movie) - 8.4) < 0.0001)

        library += bucketScores(count: 5, range: Sentiment.disliked.scoreRange)
            .enumerated()
            .map { makeScored("show-\($0.offset)", score: $0.element, type: .tvShow, sentiment: .disliked) }

        let both = RecommendationEngine().buildProfile(from: library)

        // globalMean = 7.05, so baseline[movie] = (20*8.4 + 3*7.05)/23 and
        // baseline[tv] = (5*1.65 + 3*7.05)/8.
        #expect(abs(both.baseline(for: .movie) - (189.15 / 23.0)) < 0.0001)
        #expect(abs(both.baseline(for: .tvShow) - (29.4 / 8.0)) < 0.0001)

        // Harsh television must not drag film down to meet it. The type
        // shrinkage term is a deliberate, bounded leak toward the global mean —
        // not contamination by the other type's mean.
        #expect(both.baseline(for: .movie) > 8.2)
        #expect(both.baseline(for: .tvShow) < 4.0)
        #expect(abs(both.baseline(for: .movie) - filmOnly.baseline(for: .movie)) < 0.2)
    }

    @Test("With type shrinkage off, baselines are exactly the type means")
    func zeroTypeShrinkageIsExact() {
        var tuning = RecommendationTuning.standard
        tuning.typeShrinkage = 0

        let library = bucketScores(count: 20, range: Sentiment.liked.scoreRange)
            .enumerated()
            .map { makeScored("film-\($0.offset)", score: $0.element, type: .movie) }
            + bucketScores(count: 5, range: Sentiment.disliked.scoreRange)
            .enumerated()
            .map { makeScored("show-\($0.offset)", score: $0.element, type: .tvShow, sentiment: .disliked) }

        let profile = RecommendationEngine(tuning: tuning).buildProfile(from: library)

        #expect(abs(profile.baseline(for: .movie) - 8.4) < 0.0001)
        #expect(abs(profile.baseline(for: .tvShow) - 1.65) < 0.0001)
    }

    // MARK: - Shrinkage

    @Test("The same residual from 1 item and from 10 shrinks in the documented ratio")
    func shrinkageRatio() {
        let engine = RecommendationEngine()
        let target = Feature.genre("Target").key
        let other = Feature.genre("Other").key

        // One item at +2.0 against a mean of 5.0.
        let single = [
            makeScored("a", score: 7.0, features: [target]),
            makeScored("b", score: 3.0, features: [other]),
        ]

        // Ten items at +2.0 against the same mean.
        var many: [MediaItem] = []
        for index in 0..<10 {
            many.append(makeScored("hit-\(index)", score: 7.0, features: [target]))
            many.append(makeScored("miss-\(index)", score: 3.0, features: [other]))
        }

        let one = engine.buildProfile(from: single).effect(target)
        let ten = engine.buildProfile(from: many).effect(target)

        // effect = Σresidual / (n + K), K_GENRE = 3.
        #expect(abs(one - 0.5) < 0.0001)
        #expect(abs(ten - (20.0 / 13.0)) < 0.0001)

        // Stated as a ratio too, so a refactor cannot quietly drop the `+ K`
        // and still satisfy one of the two absolute values.
        #expect(abs(ten / one - (40.0 / 13.0)) < 0.0001)
    }

    @Test("Support-weighted effects cancel to zero when nothing is shrunk")
    func effectsAreZeroSumWithoutShrinkage() {
        // With no shrinkage anywhere and exactly one feature per item, an
        // effect is a plain mean residual, and residuals are exactly
        // type-centred — so the support-weighted effects must cancel. Catches
        // sign errors and residuals computed against the wrong baseline.
        var tuning = RecommendationTuning.standard
        tuning.typeShrinkage = 0
        tuning.shrinkage[.genre] = 0

        let library = (0..<12).map { index in
            makeScored(
                "item-\(index)",
                score: Double(index) * 0.5 + 1.0,
                features: [Feature.genre("g\(index % 4)").key]
            )
        }

        let profile = RecommendationEngine(tuning: tuning).buildProfile(from: library)
        let weighted = profile.featureEffects.reduce(0.0) { total, entry in
            total + Double(profile.featureSupport[entry.key]?.count ?? 0) * entry.value
        }

        #expect(abs(weighted) < 0.0001)
    }

    // MARK: - Inclusion floor

    @Test("A keyword seen once is dropped; seen twice it survives")
    func keywordSupportFloor() {
        let once = Feature.keyword(id: 1, name: "solo").key
        let twice = Feature.keyword(id: 2, name: "repeat").key

        let library = [
            makeScored("a", score: 9.0, features: [once, twice]),
            makeScored("b", score: 8.0, features: [twice]),
            makeScored("c", score: 3.0, features: [Feature.genre("Other").key]),
        ]

        let profile = RecommendationEngine().buildProfile(from: library)

        #expect(profile.featureEffects[once] == nil)
        #expect(profile.featureEffects[twice] != nil)

        // The observation survives even where the model declines to use it —
        // Phase 19 wants the set, and the discard rate answers open question 13.
        #expect(profile.featureSupport[once]?.count == 1)
        #expect(profile.droppedBelowFloor[.keyword] == 1)

        // A dropped feature is absent, not zero: claiming evidence for
        // something the prediction does not use would inflate confidence.
        #expect(profile.effectiveSupport(once) == 0)
        #expect(profile.effectiveSupport(twice) == 2)
    }

    @Test("A single-item library and an item with no features both stay valid")
    func minimalLibraries() {
        let engine = RecommendationEngine()

        let single = engine.buildProfile(from: [makeScored("only", score: 8.4)])
        #expect(abs(single.globalMean - 8.4) < 0.0001)
        #expect(single.globalMean.isFinite)

        // No features and no genres: derivation yields the era band alone.
        let featureless = engine.buildProfile(from: [makeScored("bare", score: 7.0, year: 2015)])
        let onlyEra = featureless.featureEffects.keys.filter { !$0.hasPrefix("era:") }
        let nonFinite = featureless.featureEffects.values.filter { !$0.isFinite }
        #expect(onlyEra.isEmpty)
        #expect(nonFinite.isEmpty)
    }
}
