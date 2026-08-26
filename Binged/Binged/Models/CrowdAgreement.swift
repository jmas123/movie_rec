//
//  CrowdAgreement.swift
//  Binged
//
//  How far a user's own ranking agrees with TMDB's averages, as a rank
//  correlation.
//
//  **One definition, two callers, deliberately.** Profile renders this as a
//  sentence ("Your ranking loosely tracks the crowd"); the recommender uses it
//  to decide how much the crowd score is allowed to move a prediction. Computed
//  in two places they would drift, and the app would then be showing the user a
//  number it no longer acts on.
//
//  It is a rank correlation and never a mean difference: scores are
//  bucket-relative quantiles, so a user's favourite film scores ~9.7 whether
//  they merely liked it or think it the best ever made, and
//  `mean(score − voteAverage)` would measure the shape of the bands rather than
//  anything about the person.
//

import Foundation

// MARK: - CrowdAgreement

enum CrowdAgreement {

    /// Rated titles carrying a crowd score needed before the estimate is worth
    /// having. Below it the correlation is mostly noise, and both callers are
    /// expected to fall back rather than act on it.
    static let minimumSample = 8

    /// The `(own score, crowd score)` pairs a library can contribute.
    ///
    /// Everything unranked, unwatched or unrated by TMDB drops out — those
    /// carry no evidence either way.
    static func pairs(in items: [MediaItem]) -> [(score: Double, crowd: Double)] {
        items.compactMap { item in
            guard item.watchedStatus == .watched,
                  let score = item.score,
                  let crowd = item.tmdbVoteAverage,
                  crowd.isFinite,
                  crowd > 0 else { return nil }
            return (score, crowd)
        }
    }

    /// `nil` when there is too little evidence, or when one side does not vary
    /// (every title carrying the same crowd score says nothing about order).
    static func measure(_ pairs: [(score: Double, crowd: Double)]) -> Double? {
        guard pairs.count >= minimumSample else { return nil }
        return Ranks.spearman(pairs.map(\.score), pairs.map(\.crowd))
    }
}
