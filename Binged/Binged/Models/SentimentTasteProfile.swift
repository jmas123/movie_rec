//
//  SentimentTasteProfile.swift
//  Binged
//
//  The coarse half of the hybrid recommender: how often each feature has led
//  to Liked, Fine or Disliked, kept separate from within-bucket preference.
//

import Foundation

// MARK: - SentimentTasteProfile

struct SentimentTasteProfile: Sendable {

    let countsByType: [MediaType: [Sentiment: Int]]
    let featureCounts: [String: [Sentiment: Int]]
    let tuning: RecommendationTuning

    func count(_ sentiment: Sentiment, type: MediaType) -> Int {
        countsByType[type]?[sentiment] ?? 0
    }

    func watchedCount(of type: MediaType) -> Int {
        countsByType[type]?.values.reduce(0, +) ?? 0
    }

    func counts(for key: String) -> [Sentiment: Int] {
        featureCounts[key] ?? [:]
    }
}
