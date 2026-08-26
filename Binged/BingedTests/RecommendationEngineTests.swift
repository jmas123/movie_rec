//
//  RecommendationEngineTests.swift
//  BingedTests
//
//  Prediction, confidence, contributions, and calibration.
//
//  Store-free throughout: the engine imports only Foundation, so every fixture
//  here is a hand-built `MediaItem` and no test needs a `ModelContainer`.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Helpers

/// A candidate carrying exactly these feature keys and nothing derived.
private func candidate(_ keys: [String], type: MediaType = .movie) -> CandidateFeatures {
    CandidateFeatures(id: UUID(), type: type, keys: keys)
}

private let horror = Feature.genre("Horror").key
private let romance = Feature.genre("Romance").key
private let filler = Feature.genre("Filler").key

// MARK: - Feature extraction

@Suite("RecommendationEngine — feature extraction")
struct RecommendationEngineExtractionTests {

    @Test("A backfilled item is consumed verbatim")
    func backfilledItemUsesItsFeatures() {
        let item = makeScored("x", score: 8.0, features: [horror, filler], genres: ["Ignored"], year: 1994)
        #expect(RecommendationEngine.featureKeys(for: item) == [horror, filler])
    }

    @Test("A pool candidate with no features derives genre and era")
    func poolCandidateDerivesFeatures() {
        // This is the case `/discover` actually returns: genres and a year, no
        // keywords, no credits. Without derivation every prediction would equal
        // the type baseline and Discover would rank alphabetically.
        let pooled = MediaItem(title: "Pooled", year: 2016, type: .movie, genres: ["Horror", "Drama"])
        let keys = RecommendationEngine.featureKeys(for: pooled)

        #expect(keys == [horror, Feature.genre("Drama").key, "era:2010s"])
    }

    @Test("Derived keys score identically to the same keys stored")
    func derivedAndStoredAgree() {
        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: makePlanFixtureLibrary())

        let derived = MediaItem(title: "Derived", year: 2016, type: .movie, genres: ["Horror"])
        let stored = MediaItem(
            title: "Stored", year: 2016, type: .movie,
            genres: [], features: [horror, "era:2010s"]
        )

        #expect(
            abs(engine.predict(derived, using: profile).value
                - engine.predict(stored, using: profile).value) < 0.0001
        )
    }

    @Test("An unrecognised or malformed key is dropped, never crashed on")
    func garbageKeysDegrade() {
        let item = makeScored("x", score: 8.0, features: ["quantum:42|Nonsense", "garbage", ":", "genre:"])
        #expect(RecommendationEngine.featureKeys(for: item).isEmpty)

        let profile = RecommendationEngine().buildProfile(from: [item])
        #expect(profile.featureEffects.isEmpty)
    }

    @Test("An undated title contributes no era evidence")
    func undatedTitleHasNoEra() {
        // TMDB routinely returns an empty release date, which maps to year 0.
        // "era:0s" would be a feature about nothing.
        let undated = MediaItem(title: "Undated", year: 0, type: .movie, genres: ["Horror"])
        #expect(RecommendationEngine.featureKeys(for: undated) == [horror])
    }
}

// MARK: - Prediction

@Suite("RecommendationEngine — prediction")
struct RecommendationEnginePredictionTests {

    @Test("An empty library predicts the neutral midpoint at zero confidence")
    func emptyLibraryIsNeutral() {
        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: [MediaItem]())

        for keys in [[], [horror], [horror, romance, "keyword:1|x"]] {
            let prediction = engine.predict(candidate(keys), using: profile)

            #expect(prediction.value == 5.0)
            #expect(prediction.confidence == 0)
            #expect(prediction.value.isFinite)
            #expect(prediction.confidence.isFinite)
            #expect(prediction.evidence.isFinite)
            #expect(prediction.topContributingFeatures.isEmpty)
        }
    }

    @Test("A candidate with no features predicts exactly its type baseline")
    func featurelessCandidateIsBaseline() {
        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: makePlanFixtureLibrary())
        let prediction = engine.predict(candidate([]), using: profile)

        #expect(abs(prediction.value - 6.045) < 0.0001)
        #expect(prediction.familiesPresent.isEmpty)
    }

    @Test("The plan's worked example reproduces its stated value")
    func workedExampleValue() {
        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: makePlanFixtureLibrary())

        // Horror plus two genres the user has never seen. The unknowns dilute:
        // familyEffect = (2.4109 + 0 + 0) / 3, lifted by w[genre] = 0.30.
        let prediction = engine.predict(
            candidate([horror, "genre:Unknown1", "genre:Unknown2"]),
            using: profile
        )

        let expectedEffect = 26.52 / 11.0
        let expectedValue = 6.045 + 0.30 * (expectedEffect / 3.0)

        #expect(abs(prediction.value - expectedValue) < 0.0001)
        #expect(abs(prediction.value - 6.2860909) < 0.0001)

        // Confidence: only the genre family is present, mean support 8/3,
        // against an evidence scale of 8, weighted 0.30, type fully evidenced.
        #expect(abs(prediction.confidence - 0.30 * ((8.0 / 3.0) / 8.0)) < 0.0001)
    }

    @Test("A loved genre outranks a hated one")
    func lovedGenreBeatsHatedOne() {
        // Every horror entry sits at the top of Liked; every romance entry at
        // the bottom of Disliked.
        var library = makePlanFixtureLibrary()
        for index in 32..<40 {
            library[index] = makeScored(
                "romance-\(index)",
                score: library[index].score ?? 0,
                features: [romance],
                sentiment: .disliked
            )
        }

        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: library)

        let horrorPick = engine.predict(candidate([horror]), using: profile)
        let romancePick = engine.predict(candidate([romance]), using: profile)

        #expect(horrorPick.value > romancePick.value)
        #expect(profile.effect(horror) > 0)
        #expect(profile.effect(romance) < 0)
    }

    @Test("An unknown feature dilutes rather than being ignored")
    func unknownFeaturesDilute() {
        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: makePlanFixtureLibrary())

        let alone = engine.predict(candidate([horror]), using: profile).value
        let diluted = engine.predict(candidate([horror, "genre:Unknown"]), using: profile).value

        // Halving the family mean must halve the lift, not leave it untouched.
        let baseline = profile.baseline(for: .movie)
        #expect(abs((diluted - baseline) - (alone - baseline) / 2) < 0.0001)
    }

    @Test("Flooding a family with equally-effective features changes nothing")
    func keywordFloodIsAveraged() {
        // The regression test for a flat `Σ effect / |F|`: under a sum, thirty
        // keywords would carry thirty times the lift of one.
        var library: [MediaItem] = []
        let keywords = (0..<30).map { Feature.keyword(id: $0, name: "kw\($0)").key }

        for index in 0..<4 {
            library.append(makeScored("hit-\(index)", score: 9.0, features: keywords))
            library.append(makeScored("miss-\(index)", score: 3.0, features: [filler]))
        }

        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: library)

        let one = engine.predict(candidate([keywords[0]]), using: profile)
        let all = engine.predict(candidate(keywords), using: profile)

        #expect(abs(one.value - all.value) < 0.0001)

        // And the family as a whole cannot move the prediction further than its
        // own weight allows.
        let baseline = profile.baseline(for: .movie)
        let maxEffect = keywords.map { abs(profile.effect($0)) }.max() ?? 0
        #expect(abs(all.value - baseline) <= 0.24 * maxEffect + 0.0001)
    }

    @Test("Single-occurrence keywords cannot outweigh a well-supported genre")
    func sparseKeywordsLoseToGenre() {
        // Drawn from the measured distributions: median keyword support is 1,
        // median genre support is 7 in a 40-title library.
        var library = makePlanFixtureLibrary()
        let sparse = (0..<10).map { Feature.keyword(id: 100 + $0, name: "rare\($0)").key }

        // Ten keywords, each on exactly one top-rated title.
        for (offset, keyword) in sparse.enumerated() {
            library[offset] = makeScored(
                "sparse-\(offset)",
                score: library[offset].score ?? 0,
                features: [horror, keyword]
            )
        }

        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: library)

        let keywordPick = engine.predict(candidate(sparse), using: profile)
        let genrePick = engine.predict(candidate([horror]), using: profile)
        let baseline = profile.baseline(for: .movie)

        // Every one of them fell below the support floor, so the family
        // contributes exactly nothing.
        #expect(profile.droppedBelowFloor[.keyword] == 10)
        #expect(abs(keywordPick.value - baseline) < 0.0001)
        #expect(genrePick.value - baseline > keywordPick.value - baseline)
    }

    @Test("A sparsely described candidate stays closer to baseline")
    func missingFamiliesAreConservative() {
        let director = Feature.director(id: 1, name: "Chosen One").key

        var library = makePlanFixtureLibrary()
        for index in 0..<8 {
            library[index] = makeScored(
                "top-\(index)",
                score: library[index].score ?? 0,
                features: [horror, director]
            )
        }

        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: library)
        let baseline = profile.baseline(for: .movie)

        let genreOnly = engine.predict(candidate([horror]), using: profile).value
        let withDirector = engine.predict(candidate([horror, director]), using: profile).value

        #expect(withDirector - baseline > genreOnly - baseline)
    }

    @Test("Renormalising over present families gives sparse candidates full leverage")
    func renormalizationFlagChangesLeverage() {
        var tuning = RecommendationTuning.standard
        tuning.renormalizeOverPresentFamilies = true

        let conservative = RecommendationEngine()
        let aggressive = RecommendationEngine(tuning: tuning)
        let library = makePlanFixtureLibrary()

        let profileA = conservative.buildProfile(from: library)
        let profileB = aggressive.buildProfile(from: library)

        let lifted = conservative.predict(candidate([horror]), using: profileA).value
            - profileA.baseline(for: .movie)
        let liftedMore = aggressive.predict(candidate([horror]), using: profileB).value
            - profileB.baseline(for: .movie)

        // The flag exists so Phase 17 can sweep it; this pins that it does
        // something, and in the expected direction.
        #expect(liftedMore > lifted)
        #expect(abs(liftedMore - lifted / 0.30) < 0.0001)
    }

    @Test("Predictions never escape 0...10, including at the extremes")
    func predictionsStayInRange() {
        // Worth stating what this test found: the clamp is **defensive only**.
        // A baseline is a mean of scores, so it lies in [0, 10]; a shrunk effect
        // with K >= 0 is bounded by the largest residual; and the family mix is
        // a weighted average. So `lift <= max(score) - baseline`, which makes
        // `value <= max(score) <= 10` for every library the ranking system can
        // produce. Scaling a weight does not break it either — the prediction
        // divides by `totalWeight`, so the weight cancels.
        //
        // The clamp stays because it costs nothing and it is the last line of
        // defence against a NaN reaching a view. But nothing below reaches it,
        // and a test asserting it fires would be asserting a falsehood.
        var renormalized = RecommendationTuning.standard
        renormalized.renormalizeOverPresentFamilies = true
        renormalized.shrinkage[.genre] = 0
        renormalized.typeShrinkage = 0

        for tuning in [RecommendationTuning.standard, renormalized] {
            let engine = RecommendationEngine(tuning: tuning)

            // The widest residuals a 0-10 scale admits.
            let extreme = engine.buildProfile(from: [
                makeScored("top", score: 10.0, features: [horror]),
                makeScored("bottom", score: 0.0, features: [filler]),
            ])

            for keys in [[horror], [filler], [horror, filler], []] {
                let value = engine.predict(candidate(keys), using: extreme).value
                #expect(value >= 0.0 && value <= 10.0)
                #expect(value.isFinite)
            }

            // And at the real boundaries of the ranking system's own output.
            let boundaryLibrary = Sentiment.allCases.flatMap { sentiment in
                [sentiment.scoreRange.lowerBound, sentiment.scoreRange.upperBound].map {
                    makeScored("edge-\($0)", score: $0, features: [horror], sentiment: sentiment)
                }
            }
            let boundary = engine.buildProfile(from: boundaryLibrary)
            let atEdge = engine.predict(candidate([horror]), using: boundary).value
            #expect(atEdge >= 0.0 && atEdge <= 10.0)
        }
    }

    @Test("Movie and TV predictions are drawn from their own baselines")
    func typeSeparationHolds() {
        let library = bucketScores(count: 20, range: Sentiment.liked.scoreRange)
            .enumerated()
            .map { makeScored("film-\($0.offset)", score: $0.element, type: .movie, features: [horror]) }
            + bucketScores(count: 20, range: Sentiment.disliked.scoreRange)
            .enumerated()
            .map {
                makeScored(
                    "show-\($0.offset)", score: $0.element, type: .tvShow,
                    features: [horror], sentiment: .disliked
                )
            }

        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: library)

        let film = engine.predict(candidate([horror], type: .movie), using: profile)
        let show = engine.predict(candidate([horror], type: .tvShow), using: profile)

        #expect(film.value > 7.5)
        #expect(show.value < 4.0)
    }
}

// MARK: - Confidence

@Suite("RecommendationEngine — confidence")
struct RecommendationEngineConfidenceTests {

    @Test("Confidence is zero until the type itself is evidenced")
    func typeEvidenceGatesConfidence() {
        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: makePlanFixtureLibrary())

        // 40 films, no television at all.
        #expect(engine.predict(candidate([horror], type: .tvShow), using: profile).confidence == 0)
        #expect(engine.predict(candidate([horror], type: .movie), using: profile).confidence > 0)
    }

    @Test("Confidence does not decrease as support grows")
    func confidenceIsMonotoneInSupport() {
        let engine = RecommendationEngine()
        var previous = -1.0

        for supported in [2, 4, 8, 16] {
            let library = (0..<supported).map {
                makeScored("hit-\($0)", score: 9.0, features: [horror])
            } + (0..<supported).map {
                makeScored("miss-\($0)", score: 3.0, features: [filler])
            }

            let profile = engine.buildProfile(from: library)
            let confidence = engine.predict(candidate([horror]), using: profile).confidence

            #expect(confidence >= previous)
            previous = confidence
        }
    }

    @Test("A thinly described candidate is not more confident than a rich one")
    func coveragePenaltyHolds() {
        // The regression test for the formula this replaced. Under a flat mean
        // of per-feature support, the *least*-described candidate scored maximum
        // confidence, because era and language carry enormous support and
        // dominate the average when nothing else is present.
        var library: [MediaItem] = []
        let director = Feature.director(id: 7, name: "Auteur").key
        let keyword = Feature.keyword(id: 7, name: "slow burn").key

        for index in 0..<12 {
            library.append(
                makeScored(
                    "rich-\(index)", score: 9.0 - Double(index) * 0.1,
                    features: [horror, director, keyword, "era:2010s", "lang:en"],
                    year: 2015
                )
            )
        }

        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: library)

        let thin = engine.predict(candidate(["era:2010s", "lang:en"]), using: profile)
        let rich = engine.predict(candidate([horror, director, keyword, "era:2010s", "lang:en"]), using: profile)

        #expect(rich.confidence > thin.confidence)
        #expect(thin.confidence < 1.0)
    }

    @Test("Confidence stays inside 0...1 and reaches high values on a rich library")
    func confidenceIsBounded() {
        var library: [MediaItem] = []
        let keys = [horror, Feature.director(id: 1, name: "D").key,
                    Feature.keyword(id: 1, name: "k").key, "era:2010s", "lang:en",
                    Feature.composer(id: 1, name: "C").key, Feature.castMember(id: 1, name: "A").key,
                    Feature.franchise(id: 1, name: "F").key, "runtime:long"]

        for index in 0..<40 {
            library.append(makeScored("x-\(index)", score: 9.0 - Double(index) * 0.15, features: keys))
        }

        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: library)
        let prediction = engine.predict(candidate(keys), using: profile)

        #expect(prediction.confidence >= 0 && prediction.confidence <= 1)
        // Every family but `network` is present and richly supported, so this
        // must be able to get genuinely high — a formula that tops out at 0.5
        // would make Phase 16's gate fire on everything.
        #expect(prediction.confidence > 0.8)
    }
}

// MARK: - Contributions and determinism

@Suite("RecommendationEngine — explanations")
struct RecommendationEngineExplanationTests {

    @Test("Contributions sum to the lift over baseline")
    func contributionsReconcile() {
        let director = Feature.director(id: 3, name: "Auteur").key
        var library = makePlanFixtureLibrary()
        for index in 0..<8 {
            library[index] = makeScored(
                "top-\(index)", score: library[index].score ?? 0,
                features: [horror, director]
            )
        }

        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: library)
        let prediction = engine.predict(candidate([horror, director]), using: profile)

        let lift = prediction.value - profile.baseline(for: .movie)
        let stated = prediction.topContributingFeatures.reduce(0) { $0 + $1.amount }

        // Both features are positive here, so the top-3 list is the whole sum.
        #expect(abs(lift - stated) < 0.0001)
        #expect(prediction.topContributingFeatures.count == 2)
    }

    @Test("Contributions are ranked by effect and carry their support")
    func contributionsAreRankedAndAttributed() {
        let director = Feature.director(id: 3, name: "Auteur").key
        var library = makePlanFixtureLibrary()
        for index in 0..<8 {
            library[index] = makeScored(
                "top-\(index)", score: library[index].score ?? 0,
                features: [horror, director]
            )
        }

        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: library)
        let top = engine.predict(candidate([horror, director]), using: profile).topContributingFeatures

        #expect(top.first?.feature.family == .genre)
        #expect(top.first?.feature.displayName == "Horror")
        #expect(top.first?.support == 8)
        let amounts = top.map(\.amount)
        #expect(amounts == amounts.sorted { $0 > $1 })
    }

    @Test("Negative contributors are excluded from the rationale")
    func onlyPositiveContributorsSurface() {
        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: [
            makeScored("loved", score: 9.5, features: [horror]),
            makeScored("hated", score: 1.0, features: [romance]),
        ])

        let prediction = engine.predict(candidate([horror, romance]), using: profile)

        let named = prediction.topContributingFeatures.map(\.feature.displayName)
        let negative = prediction.topContributingFeatures.filter { $0.amount <= 0 }
        #expect(negative.isEmpty)
        #expect(named.contains("Horror"))
        #expect(!named.contains("Romance"))
    }

    @Test("Contributions are capped so a rationale stays a sentence")
    func contributionsAreCapped() {
        let genres = (0..<8).map { Feature.genre("G\($0)").key }
        let library = (0..<6).map { makeScored("x-\($0)", score: 9.0 - Double($0) * 0.2, features: genres) }
            + [makeScored("low", score: 1.0, features: [filler])]

        let engine = RecommendationEngine()
        let profile = engine.buildProfile(from: library)
        let prediction = engine.predict(candidate(genres), using: profile)

        #expect(prediction.topContributingFeatures.count == RecommendationEngine.maxContributions)
    }

    @Test("Profiles and predictions are identical regardless of input order")
    func resultsAreDeterministic() {
        let engine = RecommendationEngine()
        let library = makePlanFixtureLibrary()
        let shuffled = library.reversed().map { $0 }

        let a = engine.buildProfile(from: library)
        let b = engine.buildProfile(from: shuffled)

        // Reversal-invariance holds to floating-point noise, not to the last
        // bit: `+=` over residuals is not associative, so a different input
        // order moves the final ulp. What must hold exactly is same-input
        // reproducibility and a total output ordering, both asserted below.
        #expect(Set(a.featureEffects.keys) == Set(b.featureEffects.keys))
        for (key, effect) in a.featureEffects {
            #expect(abs(effect - (b.featureEffects[key] ?? .nan)) < 0.0000001)
        }
        #expect(abs(a.globalMean - b.globalMean) < 0.0000001)

        // Same input, byte-for-byte the same profile, every time.
        let repeated = engine.buildProfile(from: library)
        #expect(a.featureEffects == repeated.featureEffects)
        #expect(a.globalMean == repeated.globalMean)

        // Deliberate exact tie: two features with identical effect must order by
        // key, not by whichever the dictionary happened to yield first.
        let tied = [Feature.genre("Alpha").key, Feature.genre("Beta").key]
        let tieLibrary = [
            makeScored("hit", score: 9.0, features: tied),
            makeScored("miss", score: 3.0, features: [filler]),
        ]
        let tieProfile = engine.buildProfile(from: tieLibrary)

        for _ in 0..<20 {
            let forward = engine.predict(candidate(tied), using: tieProfile)
            let backward = engine.predict(candidate(tied.reversed()), using: tieProfile)

            #expect(forward.value == backward.value)
            #expect(forward.topContributingFeatures.map(\.feature) == backward.topContributingFeatures.map(\.feature))
            #expect(forward.topContributingFeatures.first?.feature.displayName == "Alpha")
        }
    }
}

// MARK: - Leave-one-out

@Suite("RecommendationEngine — leave-one-out")
struct RecommendationEngineLOOTests {

    @Test("Each fold predicts a title from a profile that excludes it")
    func foldsAreIndependent() {
        // Predicting a held-out title from a profile containing it would report
        // the model's memory rather than its skill, and every downstream number
        // — the fitted calibration slope, Phase 17's MAE and rank correlation —
        // would inherit the leak.
        let engine = RecommendationEngine()
        let library = makePlanFixtureLibrary()
        let pairs = engine.leaveOneOutPairs(for: library)

        #expect(pairs.count == library.count)

        // With the held title removed, `genre:Horror` has support 7, not 8.
        let holdout = library[0]
        let withoutIt = engine.buildProfile(from: library.filter { $0.id != holdout.id })
        #expect(withoutIt.featureSupport[Feature.genre("Horror").key]?.count == 7)

        let full = engine.buildProfile(from: library)
        #expect(full.featureSupport[Feature.genre("Horror").key]?.count == 8)
    }

    @Test("Actual scores are carried through untouched")
    func actualsAreTheStoredScores() {
        let engine = RecommendationEngine()
        let library = makePlanFixtureLibrary()
        let pairs = engine.leaveOneOutPairs(for: library)

        #expect(Set(pairs.map(\.actual)) == Set(library.compactMap(\.score)))
        let escaped = pairs.filter { !$0.raw.isFinite || $0.raw < 0 || $0.raw > 10 }
        #expect(escaped.isEmpty)
    }

    @Test("Unwatched and unscored items never enter a fold")
    func onlyRankedItemsParticipate() {
        let engine = RecommendationEngine()
        let library = makePlanFixtureLibrary() + [
            MediaItem(title: "Queued", year: 2024, type: .movie, watchedStatus: .wantToWatch),
            MediaItem(title: "Scoreless", year: 2024, type: .movie, watchedStatus: .watched),
        ]
        #expect(engine.leaveOneOutPairs(for: library).count == 40)
    }

    @Test("A library too small to hold anything out yields no pairs")
    func degenerateLibrariesYieldNothing() {
        let engine = RecommendationEngine()
        #expect(engine.leaveOneOutPairs(for: [MediaItem]()).isEmpty)
        #expect(engine.leaveOneOutPairs(for: [makeScored("only", score: 8.4)]).isEmpty)
    }

    @Test("A library with nothing to learn from calibrates to identity")
    func calibrationFallsBackToIdentity() {
        // Every fixture item carries one of two genres in one sentiment mix, so
        // the folds barely disagree — and the honest response to that is to
        // leave the numbers alone.
        let engine = RecommendationEngine()
        let calibration = engine.calibration(for: [makeScored("only", score: 8.4)])
        #expect(calibration == .identity)
    }

    @Test("Every fold's baseline is identical, because the bucket is re-derived")
    func loobaselineIsInvariant() {
        // The invariant that makes cross-validation mean anything. A score is a
        // quantile over its bucket, so removing a title changes every remaining
        // title's score — and a bucket's mean is its band midpoint for *every*
        // N. Re-derive the fold and the baseline cannot move; skip that and the
        // baseline becomes a decreasing function of the held-out score, which
        // on a real 41-title library correlated -0.885 with it and reported a
        // +0.187 model as -0.394.
        let engine = RecommendationEngine()
        let snapshots = makePlanFixtureLibrary().compactMap(RankedSnapshot.init)

        var byBucket: [Sentiment: Set<String>] = [:]
        for held in snapshots {
            let fold = snapshots.filter { $0.id != held.id }.recomputingScores()
            let profile = engine.buildProfile(from: fold)
            let baseline = String(format: "%.9f", profile.baseline(for: .movie))
            byBucket[held.sentiment ?? .fine, default: []].insert(baseline)
        }

        // Within a bucket, every fold must produce the *same* baseline — that is
        // what stops the baseline from tracking the held-out item's own score.
        for (sentiment, values) in byBucket {
            #expect(values.count == 1, "\(sentiment) folds disagreed: \(values.sorted())")
        }

        // Across buckets it legitimately differs: losing a Liked title really
        // does leave a slightly harsher library than losing a Disliked one, and
        // a fold is supposed to reflect the library it models. This is bounded
        // bucket-level movement, not the per-item coupling that made a +0.187
        // model measure as -0.394.
        #expect(byBucket.count == 3)

        // Single-sentiment libraries — the common real case — get the strong
        // form for free: one bucket, so one baseline, so no coupling at all.
        let likedOnly = snapshots.filter { $0.sentiment == .liked }
        var single: Set<String> = []
        for held in likedOnly {
            let fold = likedOnly.filter { $0.id != held.id }.recomputingScores()
            single.insert(String(format: "%.9f", engine.buildProfile(from: fold).baseline(for: .movie)))
        }
        #expect(single.count == 1)
        #expect(single.first == String(format: "%.9f", 8.4))
    }

    @Test("A fold re-derives the remaining scores rather than leaving them stale")
    func foldsRecomputeScores() {
        let snapshots = makePlanFixtureLibrary().compactMap(RankedSnapshot.init)
        let held = snapshots[0]
        let fold = snapshots.filter { $0.id != held.id }.recomputingScores()

        // Liked went from 20 items to 19, so the whole bucket shifts.
        let liked = fold.filter { $0.sentiment == .liked }.map(\.score).sorted(by: >)
        #expect(liked.count == 19)
        #expect(liked == RankingEngine.scores(count: 19, range: Sentiment.liked.scoreRange))

        // And every bucket still averages its band midpoint, which is the
        // property the invariant above rests on.
        for sentiment in Sentiment.allCases {
            let bucket = fold.filter { $0.sentiment == sentiment }.map(\.score)
            guard !bucket.isEmpty else { continue }
            let midpoint = (sentiment.scoreRange.lowerBound + sentiment.scoreRange.upperBound) / 2
            #expect(abs(bucket.reduce(0, +) / Double(bucket.count) - midpoint) < 0.0001)
        }
    }

    @Test("Cross-validation never rewrites the user's real library")
    func foldsDoNotMutateTheStore() {
        // `MediaItem` is a reference type and `recomputeScores` mutates in
        // place, so simulating a fold against live models would silently
        // re-rank the user's actual library.
        let engine = RecommendationEngine()
        let library = makePlanFixtureLibrary()
        let before = library.map(\.score)

        _ = engine.leaveOneOutPairs(for: library)

        #expect(library.map(\.score) == before)
    }

    @Test("Calibration is fitted from the folds, not from stored scores alone")
    func calibrationConsumesTheFolds() {
        let engine = RecommendationEngine()
        let library = makePlanFixtureLibrary()

        let direct = RatingCalibration.fit(pairs: engine.leaveOneOutPairs(for: library))
        let viaHelper = engine.calibration(for: library)

        #expect(abs(viaHelper.slope - direct.slope) < 0.0000001)
        #expect(abs(viaHelper.center - direct.center) < 0.0000001)
        #expect(viaHelper.sampleSize == direct.sampleSize)
    }

    @Test("Type calibration restricts holdouts, not the training profile")
    func calibrationIsPerType() {
        let engine = RecommendationEngine()
        let movies = makePlanFixtureLibrary()
        let tvScores = bucketScores(count: 8, range: Sentiment.liked.scoreRange)
        let shows = tvScores.enumerated().map { index, score in
            makeScored(
                "show-\(index)",
                score: score,
                type: .tvShow,
                features: [index < 4 ? horror : filler],
                sentiment: .liked
            )
        }
        let library = movies + shows

        let moviePairs = engine.leaveOneOutPairs(for: library, holdingOut: .movie)
        let showPairs = engine.leaveOneOutPairs(for: library, holdingOut: .tvShow)

        #expect(moviePairs.count == movies.count)
        #expect(showPairs.count == shows.count)

        let direct = RatingCalibration.fit(pairs: showPairs)
        let viaHelper = engine.calibration(for: library, type: .tvShow)
        #expect(viaHelper == direct)
        #expect(viaHelper.sampleSize == shows.count)
    }
}

// MARK: - Purity and scale

@Suite("RecommendationEngine — purity and scale")
struct RecommendationEnginePurityTests {

    @Test("The engine and its models import Foundation only")
    func noFrameworkImports() throws {
        // The engine must stay testable without a store, a screen, or a network,
        // which is a property of its imports rather than of its behaviour.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BingedTests
            .deletingLastPathComponent()   // Binged
            .appendingPathComponent("Binged")

        let files = [
            "Services/RecommendationEngine.swift",
            "Models/TasteProfile.swift",
            "Models/PredictedScore.swift",
            "Models/CandidateFeatures.swift",
            "Models/RecommendationTuning.swift",
        ]

        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)

            // Strip comments before scanning. These files *document* what they
            // exclude ("no SwiftData, no SwiftUI, no URLSession"), and a test
            // that trips over its own subject's prose tests nothing.
            let code = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")

            for banned in ["import SwiftData", "import SwiftUI", "import Combine", "URLSession"] {
                #expect(!code.contains(banned), "\(file) contains \(banned)")
            }
            #expect(code.contains("import Foundation"))
        }
    }

    @Test("A pool-sized request builds one profile and scores 1200 candidates")
    func poolScaleRequest() {
        // Not a timing assertion — those are flaky in CI. This makes Phase 18's
        // budget observable and forces the value-snapshot path to be exercised
        // at real scale before Phase 15 depends on it.
        let engine = RecommendationEngine()
        let library = (0..<100).map { index in
            makeScored(
                "lib-\(index)",
                score: Double(index % 10) + 0.5,
                features: [
                    Feature.genre("G\(index % 12)").key,
                    Feature.keyword(id: index % 40, name: "k\(index % 40)").key,
                    "era:20\(10 + index % 2)0s",
                ]
            )
        }

        let profile = engine.buildProfile(from: library)
        let candidates = (0..<1200).map { index in
            CandidateFeatures(
                id: UUID(),
                type: index % 3 == 0 ? .tvShow : .movie,
                keys: [
                    Feature.genre("G\(index % 12)").key,
                    Feature.keyword(id: index % 40, name: "k\(index % 40)").key,
                ]
            )
        }

        let scored = candidates.map { engine.predict($0, using: profile) }

        #expect(scored.count == 1200)
        let badValue = scored.filter { !($0.value >= 0 && $0.value <= 10) || !$0.value.isFinite }
        let badConfidence = scored.filter { !($0.confidence >= 0 && $0.confidence <= 1) }
        #expect(badValue.isEmpty)
        #expect(badConfidence.isEmpty)
    }
}
