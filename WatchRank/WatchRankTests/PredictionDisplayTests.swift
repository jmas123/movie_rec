//
//  PredictionDisplayTests.swift
//  WatchRankTests
//
//  What the Discover screen is allowed to say about a prediction.
//
//  Store-free and view-free: the rule is a product decision with thresholds in
//  it, and this is the layer that decides whether the app claims precision it
//  has not earned. It should be checkable without rendering anything.
//

import Foundation
import Testing
@testable import WatchRank

// MARK: - Helpers

private func prediction(
    value: Double = 6.5,
    confidence: Double,
    displayValue: Double? = nil
) -> PredictedScore {
    PredictedScore(
        value: value,
        confidence: confidence,
        evidence: 5,
        familiesPresent: [.genre],
        topContributingFeatures: [],
        displayValue: displayValue ?? value
    )
}

// MARK: - Tests

@Suite("PredictionDisplay")
struct PredictionDisplayTests {

    private let floor = RecommendationTuning.standard.confidenceFloorForDisplay

    // MARK: Gating

    @Test("A confident prediction shows its calibrated number")
    func confidentPredictionsShowANumber() {
        let display = PredictionDisplay(
            predicted: prediction(value: 6.4, confidence: 0.9, displayValue: 9.2),
            lift: 0.6
        )

        // The *calibrated* figure, never the raw estimate — which is muted by
        // roughly three points against the scores the user writes themselves.
        #expect(display == .score(9.2))
    }

    @Test("An unconfident prediction withholds the number")
    func unconfidentPredictionsShowABand() {
        // Rule 6's discipline one layer out: a number implies precision the app
        // has not earned, and a *predicted* number is weaker evidence than a
        // real one.
        let display = PredictionDisplay(
            predicted: prediction(value: 6.4, confidence: 0.05, displayValue: 9.2),
            lift: 0.6
        )

        #expect(display == .band(.likelyHit))
        if case .score = display { Issue.record("a number escaped the floor") }
    }

    @Test("The floor is inclusive at its exact value")
    func floorIsInclusive() {
        let atFloor = PredictionDisplay(predicted: prediction(confidence: floor), lift: 0.5)
        let justUnder = PredictionDisplay(
            predicted: prediction(confidence: floor - 0.0001), lift: 0.5
        )

        if case .band = atFloor { Issue.record("the floor should admit its own value") }
        if case .score = justUnder { Issue.record("below the floor must not show a number") }
    }

    @Test("Confidence gates the display; the value never changes")
    func onlyDisplayIsWithheld() {
        // The score is always computed and stored — only its display is
        // withheld — so it appears the moment confidence grows, with no
        // recomputation anywhere.
        let scored = prediction(value: 7.1, confidence: 0.9, displayValue: 9.4)
        let shy = prediction(value: 7.1, confidence: 0.01, displayValue: 9.4)

        #expect(scored.displayValue == shy.displayValue)
        #expect(PredictionDisplay(predicted: scored, lift: 0.4) == .score(9.4))
        #expect(PredictionDisplay(predicted: shy, lift: 0.4) == .band(.likelyHit))
    }

    // MARK: Bands

    @Test("Bands read the lift, and commit only outside the dead zone")
    func bandsFollowLift() {
        let dead = PredictionDisplay.bandDeadZone

        #expect(PredictionDisplay.band(for: dead + 0.01) == .likelyHit)
        #expect(PredictionDisplay.band(for: -dead - 0.01) == .notForYou)

        // Inside the dead zone, in both directions and at the boundary itself,
        // the honest answer is that the app does not know.
        #expect(PredictionDisplay.band(for: 0) == .worthAShot)
        #expect(PredictionDisplay.band(for: dead) == .worthAShot)
        #expect(PredictionDisplay.band(for: -dead) == .worthAShot)
        #expect(PredictionDisplay.band(for: dead - 0.01) == .worthAShot)
    }

    @Test("Bands are monotone in lift")
    func bandsAreMonotone() {
        // A better-fitting title may never be described more pessimistically.
        let order: [PredictionDisplay.Band: Int] = [.notForYou: 0, .worthAShot: 1, .likelyHit: 2]
        var previous = -1

        for step in stride(from: -1.0, through: 1.0, by: 0.05) {
            let rank = order[PredictionDisplay.band(for: step)] ?? -1
            #expect(rank >= previous)
            previous = rank
        }
    }

    @Test("A band is used for the direction even when the number is hidden")
    func bandsStillDiscriminate() {
        // The point of banding on lift rather than on the value: at low
        // confidence the absolute number sits near the baseline and says almost
        // nothing, while its direction still does.
        let low = 0.05
        #expect(PredictionDisplay(predicted: prediction(confidence: low), lift: 0.9)
                == .band(.likelyHit))
        #expect(PredictionDisplay(predicted: prediction(confidence: low), lift: 0.0)
                == .band(.worthAShot))
        #expect(PredictionDisplay(predicted: prediction(confidence: low), lift: -0.9)
                == .band(.notForYou))
    }

    // MARK: Copy and accessibility

    @Test("Every band has distinct, non-empty copy and a symbol")
    func bandCopyIsComplete() {
        var labels: Set<String> = []
        var symbols: Set<String> = []

        for band in PredictionDisplay.Band.allCases {
            #expect(!band.label.isEmpty)
            #expect(!band.symbolName.isEmpty)
            #expect(labels.insert(band.label).inserted)
            #expect(symbols.insert(band.symbolName).inserted)
        }
        #expect(PredictionDisplay.Band.allCases.count == 3)
    }

    @Test("VoiceOver always says the word predicted")
    func accessibilityNeverHidesThatItIsAGuess() {
        // A prediction spoken as a bare number is indistinguishable from an
        // earned score, and confusing the two undermines the ranking system's
        // whole claim to precision.
        let number = PredictionDisplay.score(8.2).accessibilityDescription
        #expect(number.contains("predicted"))
        #expect(number.contains("8.2"))

        for band in PredictionDisplay.Band.allCases {
            let spoken = PredictionDisplay.band(band).accessibilityDescription
            #expect(spoken.contains("predicted"))
            #expect(spoken.contains(band.label))
        }
    }

    // MARK: Degenerate input

    @Test("Extreme and zero confidences are handled")
    func extremesAreSafe() {
        #expect(PredictionDisplay(predicted: prediction(confidence: 0), lift: 0) == .band(.worthAShot))
        #expect(PredictionDisplay(predicted: prediction(value: 10, confidence: 1, displayValue: 10), lift: 3)
                == .score(10))
        #expect(PredictionDisplay(predicted: prediction(value: 0, confidence: 1, displayValue: 0), lift: -3)
                == .score(0))
    }
}
