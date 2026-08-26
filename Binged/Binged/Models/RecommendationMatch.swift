//
//  RecommendationMatch.swift
//  Binged
//
//  The relative language Discover uses instead of presenting a column of
//  nearly identical predicted numbers. The number remains available on the
//  title detail; this is what helps someone choose what to open next.
//

import Foundation

// MARK: - RecommendationMatch

enum RecommendationMatch: Equatable {
    case bestMatch
    case strongMatch
    case worthAShot
    case outsideUsualPicks
    case somethingDifferent

    init(recommendation: Recommendation, placement: Int) {
        if recommendation.isExploration {
            self = .somethingDifferent
        } else if placement == 0 {
            // Relative, not absolute: the first row is the strongest match in
            // the mood the user asked for even when every estimate is close.
            self = .bestMatch
        } else {
            switch PredictionDisplay.band(for: recommendation.lift) {
            case .likelyHit:  self = .strongMatch
            case .worthAShot: self = .worthAShot
            case .notForYou:  self = .outsideUsualPicks
            }
        }
    }

    var label: String {
        switch self {
        case .bestMatch:         return "Best match"
        case .strongMatch:       return "Strong match"
        case .worthAShot:        return "Worth a shot"
        case .outsideUsualPicks: return "Outside your usual picks"
        case .somethingDifferent: return "Something different"
        }
    }

    var symbolName: String {
        switch self {
        case .bestMatch:          return "sparkles"
        case .strongMatch:        return "hand.thumbsup"
        case .worthAShot:         return "questionmark.circle"
        case .outsideUsualPicks:  return "arrow.up.right"
        case .somethingDifferent: return "arrow.triangle.branch"
        }
    }
}
