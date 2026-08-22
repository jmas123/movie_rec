//
//  RecommendationTuningTests.swift
//  WatchRankTests
//
//  The knob panel is mostly data, so what is worth testing is its
//  *completeness*: a new `Feature.Family` case that nobody remembered to give a
//  weight would be silently deleted from the model, and every prediction would
//  keep working while quietly ignoring it.
//

import Foundation
import Testing
@testable import WatchRank

@Suite("RecommendationTuning")
struct RecommendationTuningTests {

    // MARK: - Completeness

    @Test("Every feature family has an explicit entry in every table")
    func everyFamilyIsConfigured() {
        let tuning = RecommendationTuning.standard

        for family in Feature.Family.allCases {
            #expect(tuning.weights[family] != nil, "no weight for \(family)")
            #expect(tuning.shrinkage[family] != nil, "no shrinkage for \(family)")
            #expect(tuning.inclusionFloor[family] != nil, "no inclusion floor for \(family)")
            #expect(tuning.evidenceFull[family] != nil, "no evidence scale for \(family)")
            #expect(tuning.displayFloor[family] != nil, "no display floor for \(family)")
        }
    }

    @Test("Weights sum to one")
    func weightsSumToOne() {
        #expect(abs(RecommendationTuning.standard.totalWeight - 1.0) < 0.0001)
    }

    @Test("A family missing from a table falls back rather than vanishing")
    func missingFamilyFallsBack() {
        var tuning = RecommendationTuning.standard
        tuning.weights.removeValue(forKey: .genre)

        // The point is that it is non-zero: a zero would delete the family from
        // the model without any signal that it had happened.
        #expect(tuning.weight(.genre) == RecommendationTuning.defaultWeight)
        #expect(tuning.weight(.genre) > 0)
    }

    // MARK: - Ordering invariants

    @Test("Display floors are never below inclusion floors")
    func displayFloorsAreStricter() {
        let tuning = RecommendationTuning.standard

        // Feeding a prediction is cheap — the averaging damps a weak feature.
        // Asserting a fact about the user is not. The floors must not invert.
        for family in Feature.Family.allCases {
            #expect(
                tuning.displayFloor(family) >= tuning.inclusionFloor(family),
                "\(family) would be displayable before it is usable"
            )
        }
    }

    @Test("Sparse families are shrunk less than dense ones")
    func sparseFamiliesShrinkLess() {
        let tuning = RecommendationTuning.standard

        // A K large enough for genres silences keywords entirely: 66% of
        // keywords appear on exactly one title, so K = 3 would leave a
        // support-2 keyword at 40% of face value while still costing it a slot
        // in the denominator.
        #expect(tuning.shrinkage(.keyword) < tuning.shrinkage(.genre))
        #expect(tuning.shrinkage(.era) > tuning.shrinkage(.genre))
    }

    @Test("Keywords and cast carry a support floor; one-per-title families do not")
    func inclusionFloors() {
        let tuning = RecommendationTuning.standard

        #expect(tuning.inclusionFloor(.keyword) == 2)
        #expect(tuning.inclusionFloor(.cast) == 2)
        #expect(tuning.inclusionFloor(.director) == 1)
        #expect(tuning.inclusionFloor(.genre) == 1)
    }
}
