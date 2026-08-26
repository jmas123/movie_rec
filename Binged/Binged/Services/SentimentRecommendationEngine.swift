//
//  SentimentRecommendationEngine.swift
//  Binged
//
//  Predicts the coarse reaction bucket independently from position inside it.
//  This prevents the 3.3-point gap between sentiment bands from consuming the
//  same signal that should distinguish two titles the user both liked.
//

import Foundation

// MARK: - SentimentRecommendationEngine

struct SentimentRecommendationEngine {

    let tuning: RecommendationTuning

    init(tuning: RecommendationTuning = .standard) {
        self.tuning = tuning
    }

    func buildProfile(from watched: [MediaItem]) -> SentimentTasteProfile {
        buildProfile(from: watched.compactMap(RankedSnapshot.init))
    }

    func buildProfile(from snapshots: [RankedSnapshot]) -> SentimentTasteProfile {
        var countsByType: [MediaType: [Sentiment: Int]] = [:]
        var featureCounts: [String: [Sentiment: Int]] = [:]

        for item in snapshots {
            guard let sentiment = item.sentiment else { continue }
            countsByType[item.type, default: [:]][sentiment, default: 0] += 1
            for key in Set(item.keys) {
                featureCounts[key, default: [:]][sentiment, default: 0] += 1
            }
        }

        return SentimentTasteProfile(
            countsByType: countsByType,
            featureCounts: featureCounts,
            tuning: tuning
        )
    }

    /// Expected midpoint of the three sentiment bands.
    ///
    /// Starts with a Laplace-smoothed per-type prior, then lets each feature
    /// family move that distribution. Effects are averaged within a family and
    /// weighted between families, matching `RecommendationEngine`'s protection
    /// against titles carrying thirty keywords but only two genres.
    func predict(
        _ candidate: CandidateFeatures,
        using profile: SentimentTasteProfile
    ) -> (score: Double, certainty: Double) {
        let sentiments = Sentiment.allCases
        let typeCount = profile.watchedCount(of: candidate.type)
        let denominator = Double(typeCount + sentiments.count)

        guard denominator > 0 else {
            return (tuning.neutralScore, 0)
        }

        var prior: [Sentiment: Double] = [:]
        for sentiment in sentiments {
            prior[sentiment] = Double(profile.count(sentiment, type: candidate.type) + 1)
                / denominator
        }

        var probabilities = prior
        for (family, features) in candidate.featuresByFamily() where !features.isEmpty {
            var familyProbabilities: [Sentiment: Double] = [:]

            for feature in features {
                let counts = profile.counts(for: feature.key)
                let support = counts.values.reduce(0, +)

                for sentiment in sentiments {
                    let probability: Double
                    if support < tuning.inclusionFloor(family) {
                        probability = prior[sentiment] ?? 0
                    } else {
                        let k = max(0, tuning.shrinkage(family))
                        probability = (
                            Double(counts[sentiment] ?? 0) + k * (prior[sentiment] ?? 0)
                        ) / (Double(support) + k)
                    }
                    familyProbabilities[sentiment, default: 0] += probability
                        / Double(features.count)
                }
            }

            let weight = tuning.weight(family)
            for sentiment in sentiments {
                probabilities[sentiment, default: 0] += weight * (
                    (familyProbabilities[sentiment] ?? 0) - (prior[sentiment] ?? 0)
                )
            }
        }

        let total = probabilities.values.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return (tuning.neutralScore, 0) }

        var expected = 0.0
        var entropy = 0.0
        for sentiment in sentiments {
            let probability = max(0, probabilities[sentiment] ?? 0) / total
            let range = sentiment.scoreRange
            expected += probability * (range.lowerBound + range.upperBound) / 2
            if probability > 0 { entropy -= probability * log(probability) }
        }

        let maximumEntropy = log(Double(sentiments.count))
        let certainty = maximumEntropy > 0 ? max(0, min(1, 1 - entropy / maximumEntropy)) : 0
        return (max(0, min(10, expected)), certainty)
    }
}
