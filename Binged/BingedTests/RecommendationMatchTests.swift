//
//  RecommendationMatchTests.swift
//  BingedTests
//

import Foundation
import Testing
@testable import Binged

// MARK: - RecommendationMatchTests

@Suite("RecommendationMatch")
struct RecommendationMatchTests {

    private func recommendation(lift: Double, exploration: Bool = false) -> Recommendation {
        Recommendation(
            item: MediaItem(title: "Candidate", year: 2024, type: .movie),
            predicted: PredictedScore(
                value: 8.0 + lift,
                confidence: 0.8,
                evidence: 5,
                familiesPresent: [.genre],
                topContributingFeatures: []
            ),
            moodWeight: 1,
            isQueued: false,
            lift: lift,
            isExploration: exploration
        )
    }

    @Test("The first result is explicitly relative")
    func firstResultIsBestMatch() {
        #expect(RecommendationMatch(
            recommendation: recommendation(lift: 0), placement: 0
        ) == .bestMatch)
    }

    @Test("A diversity pick never masquerades as the best match")
    func explorationWinsOverPlacement() {
        #expect(RecommendationMatch(
            recommendation: recommendation(lift: 0.8, exploration: true), placement: 0
        ) == .somethingDifferent)
    }

    @Test("Ordinary rows use the direction of their taste lift")
    func standardRowsUseLift() {
        #expect(RecommendationMatch(
            recommendation: recommendation(lift: 0.3), placement: 1
        ) == .strongMatch)
        #expect(RecommendationMatch(
            recommendation: recommendation(lift: 0), placement: 2
        ) == .worthAShot)
        #expect(RecommendationMatch(
            recommendation: recommendation(lift: -0.3), placement: 3
        ) == .outsideUsualPicks)
    }
}
