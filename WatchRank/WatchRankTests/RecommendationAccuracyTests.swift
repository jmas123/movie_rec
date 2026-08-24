//
//  RecommendationAccuracyTests.swift
//  WatchRankTests
//
//  Whether the recommender works, measured rather than asserted.
//
//  This is the phase's real deliverable. Everything before it is a plausible
//  algorithm; these numbers are what say whether it is a working one — and a
//  failure here is a finding, not a broken test.
//

import Foundation
import SwiftData
import Testing
@testable import WatchRank

// MARK: - Fixtures

/// A library with genuine, planted taste: horror sits at the top of Liked,
/// romance at the bottom of Disliked, and everything else is filler.
///
/// Deliberately not random. A fixture with no signal proves only that the
/// harness returns zero, which is worth one test rather than the suite.
@MainActor
private func makeSignalLibrary(perGenre: Int = 14) -> [MediaItem] {
    let loved = ["Horror", "Thriller"]
    let hated = ["Romance", "Musical"]
    var plan: [(Sentiment, [String])] = []

    for _ in 0..<perGenre { plan.append((.liked, loved)) }
    for _ in 0..<(perGenre / 2) { plan.append((.fine, ["Drama"])) }
    for _ in 0..<perGenre { plan.append((.disliked, hated)) }

    var items: [MediaItem] = []
    var bySentiment: [Sentiment: [(Int, [String])]] = [:]
    for (index, entry) in plan.enumerated() {
        bySentiment[entry.0, default: []].append((index, entry.1))
    }

    for (sentiment, members) in bySentiment {
        let scores = RankingEngine.scores(count: members.count, range: sentiment.scoreRange)
        for (position, member) in members.enumerated() {
            items.append(makeScored(
                "t\(member.0)",
                score: scores[position],
                features: member.1.map { Feature.genre($0).key },
                sentiment: sentiment
            ))
        }
    }
    return items
}

// MARK: - The gate

@Suite("Recommendation accuracy")
@MainActor
struct RecommendationAccuracyTests {

    @Test("Cross-validation finds the signal in a library that has one")
    func spearmanClearsSignificance() {
        // The acceptance criterion. If this fails, the feature effects are noise
        // and the algorithm needs rethinking — which is exactly what the test is
        // for, so do not "fix" it by loosening the threshold.
        let accuracy = RecommendationEngine().accuracy(for: makeSignalLibrary())

        #expect(accuracy.sampleSize >= 35)
        let rho = try? #require(accuracy.spearman)
        #expect((rho ?? 0) > 0)
        #expect(accuracy.isSignificant,
                "rho \(accuracy.spearman ?? .nan) vs threshold \(accuracy.significanceThreshold)")
    }

    @Test("It beats both null models on error, not just the easy one")
    func beatsBothNulls() {
        // Roughly 85% of a residual is bucket membership, so always-predict-the-
        // modal-midpoint is a genuinely strong null. Beating only the baseline
        // null is a weaker result than it looks.
        let accuracy = RecommendationEngine().accuracy(for: makeSignalLibrary())

        #expect(accuracy.beatsEasyNull,
                "MAE \(accuracy.meanAbsoluteError) vs baseline null \(accuracy.baselineNullError)")
        #expect(accuracy.beatsHardNull,
                "MAE \(accuracy.meanAbsoluteError) vs modal null \(accuracy.modalNullError)")
    }

    @Test("The top of the list holds titles the user actually liked")
    func precisionAtTenIsAboveChance() {
        let library = makeSignalLibrary()
        let accuracy = RecommendationEngine().accuracy(for: library)
        let likedShare = Double(library.filter { $0.sentiment == .liked }.count)
            / Double(library.count)

        let precision = try? #require(accuracy.precisionAtTen)
        #expect((precision ?? 0) > likedShare, "no better than the base rate")
    }

    @Test("A library with no signal is reported as having none")
    func noSignalIsNotDressedUp() {
        // Every item carries the same single genre, so nothing distinguishes
        // them. The harness must say so rather than manufacturing a correlation.
        let scores = RankingEngine.scores(count: 30, range: Sentiment.liked.scoreRange)
        let flat = scores.enumerated().map {
            makeScored("f\($0.offset)", score: $0.element,
                       features: [Feature.genre("Drama").key])
        }

        let accuracy = RecommendationEngine().accuracy(for: flat)
        #expect(!accuracy.isSignificant)
        #expect(accuracy.headline?.contains("Not enough") == true)
    }

    // MARK: Confidence

    @Test("Confidence deciles are reported so the display gate can be audited")
    func confidenceDecilesAreProduced() {
        // If error does not fall as confidence rises, `confidence` is decoration
        // and Phase 16 must stop gating a number on it. Recording the deciles is
        // what makes that checkable rather than assumed.
        let accuracy = RecommendationEngine().accuracy(for: makeSignalLibrary())

        #expect(accuracy.errorByConfidenceDecile.count >= 2)
        let finite = accuracy.errorByConfidenceDecile.filter { !$0.isFinite }
        #expect(finite.isEmpty)
    }

    // MARK: Degenerate inputs

    @Test("Empty and single-item libraries produce no accuracy claim")
    func degenerateLibraries() {
        let engine = RecommendationEngine()
        #expect(engine.accuracy(for: [MediaItem]()).isEmpty)
        #expect(engine.accuracy(for: [makeScored("one", score: 8.4)]).isEmpty)
        #expect(PredictionAccuracy.empty.headline == nil)
    }

    @Test("A single-sentiment library is measurable but honest about itself")
    func singleBucketLibrary() {
        // The real user case: 41 watched, all Liked. Both baselines collapse to
        // the band midpoint, residuals are confined to the band, and the coarse
        // signal that carries ~85% of the information does not exist.
        let scores = RankingEngine.scores(count: 40, range: Sentiment.liked.scoreRange)
        let library = scores.enumerated().map { entry in
            makeScored("liked\(entry.offset)", score: entry.element,
                       features: [Feature.genre(entry.offset % 3 == 0 ? "Horror" : "Drama").key])
        }

        let accuracy = RecommendationEngine().accuracy(for: library)
        #expect(!accuracy.isEmpty)
        #expect(accuracy.meanAbsoluteError.isFinite)
        // Both nulls collapse to the same number when there is one bucket.
        #expect(abs(accuracy.baselineNullError - accuracy.modalNullError) < 0.0001)
    }

    // MARK: Statistics

    @Test("Spearman is a rank correlation, invariant to monotone rescaling")
    func spearmanIsRankBased() {
        // The property that makes it drift-invariant: a score is a quantile, so
        // it moves when its bucket grows. A metric that noticed that would be
        // measuring the ranking system, not the model.
        let predicted = [1.0, 2.0, 3.0, 4.0, 5.0]
        let actual = [2.0, 4.0, 6.0, 8.0, 10.0]
        let stretched = actual.map { $0 * $0 * 3 + 1 }

        #expect(Ranks.spearman(predicted, actual) == 1.0)
        #expect(Ranks.spearman(predicted, stretched) == 1.0)
        #expect(Ranks.spearman(predicted, actual.reversed()) == -1.0)
    }

    @Test("Ties take their midrank rather than an arbitrary order")
    func tiesShareRanks() {
        #expect(Ranks.midranks([5, 5, 5]) == [1, 1, 1])
        #expect(Ranks.midranks([1, 2, 2, 3]) == [0, 1.5, 1.5, 3])
        #expect(Ranks.correlation([1, 1, 1], [1, 2, 3]) == nil, "a constant correlates with nothing")
    }

    @Test("The significance threshold tightens as the library grows")
    func thresholdScalesWithSampleSize() {
        let small = RecommendationEngine().accuracy(for: makeSignalLibrary(perGenre: 8))
        let large = RecommendationEngine().accuracy(for: makeSignalLibrary(perGenre: 30))

        #expect(large.significanceThreshold < small.significanceThreshold)
        #expect(abs(small.significanceThreshold - 1.96 / Double(small.sampleSize - 1).squareRoot()) < 0.0001)
    }
}

// MARK: - Feedback loop

@Suite("Prediction feedback")
@MainActor
struct PredictionFeedbackTests {

    @Test("A recorded guess survives relaunch")
    func matchedPairsPersist() throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)

        let item = MediaItem(externalId: "tmdb:movie:1", title: "Guessed", year: 2020, type: .movie)
        library.addToWantToWatch(item, predicted: 8.2)

        // A second library over a fresh context on the same container: this is
        // what proves the write reached the store rather than only memory.
        let reopened = makeLibrary(in: container)
        let stored = reopened.allItems.first { $0.externalId == "tmdb:movie:1" }

        #expect(stored?.predictedScore == 8.2)
        #expect(stored?.predictedAt != nil)
    }

    @Test("The first guess is the one that gets graded")
    func predictionIsNotOverwritten() throws {
        // Re-deriving it later would score the model against a profile that had
        // since seen more of the user's taste. Holding the app to what it said
        // at the time is the entire point.
        let library = try makeLibrary()
        let item = MediaItem(externalId: "tmdb:movie:2", title: "Once", year: 2020, type: .movie)

        library.addToWantToWatch(item, predicted: 7.0)
        library.addToWantToWatch(item, predicted: 9.9)

        #expect(item.predictedScore == 7.0)
    }

    @Test("Matched pairs appear only once a guess has been graded")
    func matchedPairsRequireAScore() throws {
        let library = try makeLibrary()
        let item = MediaItem(externalId: "tmdb:movie:3", title: "Pending", year: 2020, type: .movie)
        library.addToWantToWatch(item, predicted: 8.0)

        #expect(library.matchedPredictions.isEmpty, "not watched yet")

        library.markWatched(item, sentiment: .liked)
        library.finalizeRanking(for: item)

        let pairs = library.matchedPredictions
        #expect(pairs.count == 1)
        #expect(pairs.first?.predicted == 8.0)
        #expect(pairs.first?.actual != nil)
    }

    @Test("A dismissal persists and is not an opinion about quality")
    func dismissalPersists() throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)
        let item = MediaItem(externalId: "tmdb:movie:4", title: "Nope", year: 2020, type: .movie)

        library.dismiss(item)

        let reopened = makeLibrary(in: container)
        let stored = reopened.allItems.first { $0.externalId == "tmdb:movie:4" }

        #expect(stored?.dismissed == true)
        // Never enters a bucket: the user has not seen it.
        #expect(stored?.watchedStatus != .watched)
        #expect(stored?.sentiment == nil)
        #expect(stored?.score == nil)
    }

    @Test("Undismissing restores a title")
    func dismissalIsReversible() throws {
        let library = try makeLibrary()
        let item = MediaItem(externalId: "tmdb:movie:5", title: "Maybe", year: 2020, type: .movie)

        library.dismiss(item)
        #expect(item.dismissed)
        library.undismiss(item)
        #expect(!item.dismissed)
    }
}
