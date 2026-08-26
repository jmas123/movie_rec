//
//  HybridRecommendationEngineTests.swift
//  BingedTests
//
//  The offline evaluation (`docs/RECOMMENDER-EVALUATION.md`) is what says the
//  model works. These are the properties that evaluation relied on, pinned so a
//  later edit cannot quietly undo them.
//

import Foundation
import Testing
@testable import Binged

@Suite("Hybrid recommendation engine")
struct HybridRecommendationEngineTests {

    // MARK: - Layers

    @Test("Coarse sentiment separates features that lead to likes from fine reactions")
    func sentimentLayerPredictsReactionBucket() {
        let likedKey = Feature.genre("Science Fiction").key
        let fineKey = Feature.genre("Comedy").key
        let watched = (0..<8).map {
            makeScored("Liked \($0)", score: 8.4, features: [likedKey], sentiment: .liked)
        } + (0..<8).map {
            makeScored("Fine \($0)", score: 5.05, features: [fineKey], sentiment: .fine)
        }
        let engine = SentimentRecommendationEngine()
        let profile = engine.buildProfile(from: watched)

        let liked = engine.predict(
            CandidateFeatures(id: UUID(), type: .movie, keys: [likedKey]),
            using: profile
        )
        let fine = engine.predict(
            CandidateFeatures(id: UUID(), type: .movie, keys: [fineKey]),
            using: profile
        )

        #expect(liked.score > fine.score)
        #expect(liked.certainty > 0)
        #expect(fine.certainty > 0)
    }

    @Test("The content model's residual still separates titles inside one band")
    func contentResidualSurvivesTheSentimentLayer() {
        // Both candidates are Liked-bucket titles as far as the sentiment layer
        // is concerned; only the content model can tell them apart. The shipped
        // predecessor threw this signal away, which cost it 0.10 of Spearman ρ.
        let top = Feature.genre("Horror").key
        let bottom = Feature.genre("Musical").key
        let scores = bucketScores(count: 12, range: Sentiment.liked.scoreRange)
        var watched: [MediaItem] = []
        for index in 0..<6 {
            watched.append(makeScored("top \(index)", score: scores[index], features: [top]))
        }
        for index in 6..<12 {
            watched.append(makeScored("bottom \(index)", score: scores[index], features: [bottom]))
        }

        let engine = HybridRecommendationEngine()
        let profile = engine.buildProfile(from: watched)
        func predict(_ key: String) -> Double {
            engine.predict(
                type: .movie,
                features: CandidateFeatures(id: UUID(), type: .movie, keys: [key]),
                using: profile,
                voteAverage: nil,
                voteCount: nil
            ).value
        }

        #expect(predict(top) > predict(bottom))
    }

    @Test("A featureless candidate lands exactly on the baseline")
    func baselineAgreesWithPrediction() {
        let watched = (0..<10).map {
            makeScored("t\($0)", score: 8.2, features: [Feature.genre("Drama").key])
        }
        let engine = HybridRecommendationEngine()
        let profile = engine.buildProfile(from: watched)

        let prediction = engine.predict(
            type: .movie,
            features: CandidateFeatures(id: UUID(), type: .movie, keys: []),
            using: profile,
            voteAverage: nil,
            voteCount: nil
        )

        #expect(abs(prediction.value - engine.baseline(for: .movie, using: profile)) < 1e-9)
    }

    // MARK: - The crowd term

    @Test("The crowd weight follows how far the user agrees with the crowd")
    func crowdWeightIsLearnedFromTheLibrary() {
        let key = Feature.genre("Drama").key
        let scores = bucketScores(count: 10, range: Sentiment.liked.scoreRange)

        // One library ordered exactly as TMDB orders it, one ordered against it.
        func library(agreeing: Bool) -> [MediaItem] {
            scores.enumerated().map { index, score in
                let item = makeScored("t\(index)", score: score, features: [key])
                item.tmdbVoteAverage = agreeing ? 9.0 - Double(index) * 0.3
                                                : 6.0 + Double(index) * 0.3
                item.tmdbVoteCount = 4_000
                return item
            }
        }

        let engine = HybridRecommendationEngine()
        let agrees = engine.buildProfile(from: library(agreeing: true))
        let disagrees = engine.buildProfile(from: library(agreeing: false))

        #expect(agrees.crowdWeight(for: .movie) > 0.9)
        #expect(disagrees.crowdWeight(for: .movie) == 0)
    }

    @Test("Anti-correlation floors at zero rather than inverting")
    func contrarianWeightIsNeverNegative() {
        let engine = HybridRecommendationEngine()
        #expect(engine.crowdWeight(forAgreement: -0.8) == 0)
        #expect(engine.crowdWeight(forAgreement: .nan)
                == HybridRecommendationEngine.fallbackCrowdWeight)
    }

    @Test("Too small a library falls back rather than trusting a noisy estimate")
    func smallLibraryUsesTheFallbackWeight() {
        let key = Feature.genre("Drama").key
        let watched = (0..<(CrowdAgreement.minimumSample - 1)).map {
            index -> MediaItem in
            let item = makeScored("t\(index)", score: 8.4, features: [key])
            item.tmdbVoteAverage = 7.0 + Double(index) * 0.1
            item.tmdbVoteCount = 2_000
            return item
        }

        let profile = HybridRecommendationEngine().buildProfile(from: watched)

        #expect(profile.crowdWeight(for: .movie)
                == HybridRecommendationEngine.fallbackCrowdWeight)
    }

    @Test("A well-supported crowd score separates otherwise identical titles")
    func crowdScoreBreaksOtherwiseIdenticalTies() {
        let key = Feature.genre("Drama").key
        let watched = (0..<10).map { index -> MediaItem in
            let item = makeScored("Drama \(index)", score: 8.2, features: [key])
            item.tmdbVoteAverage = 7.0
            item.tmdbVoteCount = 5_000
            return item
        }
        let engine = HybridRecommendationEngine()
        let profile = engine.buildProfile(from: watched)
        let features = CandidateFeatures(id: UUID(), type: .movie, keys: [key])

        let low = engine.predict(type: .movie, features: features, using: profile,
                                 voteAverage: 5.5, voteCount: 20_000)
        let high = engine.predict(type: .movie, features: features, using: profile,
                                  voteAverage: 8.5, voteCount: 20_000)

        // The library's crowd scores are constant, so agreement is unmeasurable
        // and the fallback weight applies — a real term, not the near-nothing
        // the 0.10 predecessor used.
        #expect(high.value > low.value)
        #expect(high.value - low.value > 0.5)
    }

    @Test("A thinly voted score is shrunk toward what this user usually watches")
    func thinlyVotedScoresAreShrunk() {
        let key = Feature.genre("Drama").key
        let watched = (0..<10).map { index -> MediaItem in
            let item = makeScored("Drama \(index)", score: 8.2, features: [key])
            item.tmdbVoteAverage = 7.0
            item.tmdbVoteCount = 5_000
            return item
        }
        let engine = HybridRecommendationEngine()
        let profile = engine.buildProfile(from: watched)
        let features = CandidateFeatures(id: UUID(), type: .movie, keys: [key])

        let thin = engine.predict(type: .movie, features: features, using: profile,
                                  voteAverage: 9.8, voteCount: 12)
        let solid = engine.predict(type: .movie, features: features, using: profile,
                                   voteAverage: 9.8, voteCount: 40_000)

        #expect(solid.value > thin.value)
    }

    // MARK: - Explanations

    @Test("Explanations still come from the feature model alone")
    func explanationsComeFromTheContentModel() {
        let key = Feature.genre("Horror").key
        let watched = (0..<8).map {
            makeScored("Horror \($0)", score: 8.8, features: [key])
        }
        let content = RecommendationEngine()
        let hybrid = HybridRecommendationEngine(contentEngine: content)
        let profile = hybrid.buildProfile(from: watched)
        let candidate = MediaItem(title: "Candidate", year: 2024, type: .movie, features: [key])
        let features = CandidateFeatures(candidate)

        let fromContent = content.predict(features, using: profile.content)
        let fromHybrid = hybrid.predict(item: candidate, features: features, using: profile)

        #expect(fromHybrid.confidence == fromContent.confidence)
        #expect(fromHybrid.evidence == fromContent.evidence)
        #expect(fromHybrid.familiesPresent == fromContent.familiesPresent)
        #expect(fromHybrid.topContributingFeatures == fromContent.topContributingFeatures)
    }
}
