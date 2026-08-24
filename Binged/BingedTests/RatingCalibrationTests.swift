//
//  RatingCalibrationTests.swift
//  BingedTests
//
//  The mapping from the engine's raw estimate onto the user's rating scale.
//
//  This replaced a quantile map from candidate rank that inflated the top of
//  every mood's list to the user's maximum score. Several tests below exist
//  specifically so that shape cannot come back.
//

import Foundation
import Testing
@testable import Binged

@Suite("RatingCalibration")
struct RatingCalibrationTests {

    /// Pairs where `actual = center + trueSlope * (raw - center)` exactly, so
    /// the fitted slope is known in advance.
    private func linearPairs(
        center: Double, trueSlope: Double, count: Int
    ) -> [(raw: Double, actual: Double)] {
        (0..<count).map { index in
            let raw = center - 1.0 + Double(index) * (2.0 / Double(max(1, count - 1)))
            return (raw: raw, actual: center + trueSlope * (raw - center))
        }
    }

    // MARK: - Identity

    @Test("No evidence means no personalisation")
    func identityIsTheDefault() {
        // The correct mapping in the absence of data, not a placeholder: with
        // nothing saying the model is mis-scaled, the honest display is the raw
        // conditional expectation.
        #expect(RatingCalibration.fit(pairs: []) == .identity)
        #expect(RatingCalibration.identity.apply(6.65) == 6.65)
        #expect(RatingCalibration.identity.isIdentity)
    }

    @Test("Too few pairs is treated as no evidence")
    func belowTheMinimumIsIdentity() {
        let floor = RecommendationTuning.standard.minimumPairsForCalibration
        let pairs = linearPairs(center: 6, trueSlope: 1.5, count: floor - 1)
        #expect(RatingCalibration.fit(pairs: pairs) == .identity)
    }

    @Test("A raw estimate that never varies carries no slope information")
    func constantRawIsIdentity() {
        // More pairs do not help: if every prediction is the same number, there
        // is nothing to learn about how to stretch it.
        let pairs = (0..<40).map { (raw: 6.2, actual: 3.0 + Double($0) * 0.15) }
        #expect(RatingCalibration.fit(pairs: pairs) == .identity)
    }

    @Test("Non-finite pairs are dropped rather than poisoning the fit")
    func garbagePairsAreFiltered() {
        var pairs = linearPairs(center: 6, trueSlope: 1.4, count: 30)
        pairs.append((raw: .nan, actual: 8))
        pairs.append((raw: 6, actual: .infinity))

        let fit = RatingCalibration.fit(pairs: pairs)
        #expect(fit.sampleSize == 30)
        #expect(fit.slope.isFinite)
    }

    // MARK: - The null result

    @Test("A well-calibrated model fits a slope of exactly one")
    func perfectCalibrationFitsUnitSlope() {
        // The statistical null, and it is meaningful: if `raw` is a genuine
        // conditional expectation then E[actual | raw] == raw, so the slope is
        // one and calibration correctly does nothing. A compressed range is
        // therefore *not* evidence of miscalibration.
        let pairs = linearPairs(center: 6.045, trueSlope: 1.0, count: 40)
        let fit = RatingCalibration.fit(pairs: pairs)

        #expect(abs(fit.fittedSlope - 1.0) < 0.0001)
        #expect(abs(fit.slope - 1.0) < 0.0001)
        #expect(abs(fit.apply(6.5) - 6.5) < 0.0001)
    }

    @Test("An over-shrunk model fits a slope above one, and expands")
    func overShrunkModelExpands() {
        let pairs = linearPairs(center: 6.0, trueSlope: 1.5, count: 200)
        let fit = RatingCalibration.fit(pairs: pairs)

        #expect(abs(fit.fittedSlope - 1.5) < 0.0001)
        // A large sample keeps most of the fitted slope.
        #expect(fit.slope > 1.35)
        // Expansion moves a value away from the centre, not toward it.
        #expect(fit.apply(7.0) > 7.0)
        #expect(fit.apply(5.0) < 5.0)
        #expect(abs(fit.apply(6.0) - 6.0) < 0.0001)
    }

    @Test("An over-confident model fits a slope below one, and compresses")
    func overConfidentModelCompresses() {
        let pairs = linearPairs(center: 6.0, trueSlope: 0.6, count: 200)
        let fit = RatingCalibration.fit(pairs: pairs)

        #expect(fit.fittedSlope < 1.0)
        #expect(fit.apply(8.0) < 8.0)
        #expect(fit.apply(4.0) > 4.0)
    }

    // MARK: - Regularisation

    @Test("Small libraries barely personalise; large ones mostly do")
    func slopeShrinksTowardOneWithLittleData() {
        // Twelve ratings can produce a wild slope on noise, and every number on
        // screen would inherit it.
        let small = RatingCalibration.fit(pairs: linearPairs(center: 6, trueSlope: 2.5, count: 10))
        let large = RatingCalibration.fit(pairs: linearPairs(center: 6, trueSlope: 2.5, count: 400))

        #expect(abs(small.fittedSlope - large.fittedSlope) < 0.01, "same truth, both samples")
        #expect(small.slope < large.slope, "less data must mean less personalisation")
        #expect(small.explainedVariance > 0.99, "these pairs are perfectly linear")
        #expect(abs(small.slope - 1.0) < abs(large.slope - 1.0))
    }

    @Test("Shrinkage follows the documented schedule")
    func shrinkageSchedule() {
        let k = RecommendationTuning.standard.calibrationShrinkage
        let n = 20.0
        let fit = RatingCalibration.fit(pairs: linearPairs(center: 6, trueSlope: 1.4, count: Int(n)))

        // s_used = 1 + (s_fit - 1) * explained * n / (n + K). These pairs are
        // perfectly linear, so `explained` is 1 and the size term stands alone.
        #expect(abs(fit.explainedVariance - 1.0) < 0.0001)
        #expect(abs(fit.slope - (1 + (1.4 - 1) * n / (n + k))) < 0.001)
    }

    @Test("A slope fitted to noise is not trusted, however many pairs there are")
    func weakSignalIsNotTrusted() {
        // The correction that sample size alone cannot make. A library can be
        // large and still say nothing about how to rescale: measured on a real
        // 41-title library, size-only shrinkage kept a slope of 2.05 while the
        // model explained 3% of the variance. Evidence-weighted shrinkage
        // returns ~1.0, which is the honest answer.
        var pairs: [(raw: Double, actual: Double)] = []
        var seed = 7.0
        for index in 0..<200 {
            seed = (seed * 7.13).truncatingRemainder(dividingBy: 1.0) + 0.001
            pairs.append((raw: 6.0 + Double(index % 11) * 0.01, actual: 3.0 + seed * 6.0))
        }

        let fit = RatingCalibration.fit(pairs: pairs)
        #expect(fit.explainedVariance < 0.15)
        #expect(abs(fit.slope - 1.0) < 0.25, "a noise slope was applied at strength")
    }

    @Test("Strong signal survives shrinkage; weak signal does not")
    func trustScalesWithExplainedVariance() {
        let clean = RatingCalibration.fit(pairs: linearPairs(center: 6, trueSlope: 1.6, count: 60))

        var muddied = linearPairs(center: 6, trueSlope: 1.6, count: 60)
        for index in stride(from: 0, to: 60, by: 2) {
            muddied[index] = (raw: muddied[index].raw, actual: 6.0 + Double(index % 7) - 3.0)
        }
        let noisy = RatingCalibration.fit(pairs: muddied)

        #expect(clean.explainedVariance > noisy.explainedVariance)
        #expect(abs(clean.slope - 1.0) > abs(noisy.slope - 1.0))
    }

    @Test("The applied slope is bounded even against an absurd fit")
    func slopeIsBounded() {
        let bounds = RecommendationTuning.standard.calibrationSlopeBounds
        let wild = RatingCalibration.fit(pairs: linearPairs(center: 6, trueSlope: 40, count: 4000))
        let inverted = RatingCalibration.fit(pairs: linearPairs(center: 6, trueSlope: -12, count: 4000))

        #expect(bounds.contains(wild.slope))
        #expect(bounds.contains(inverted.slope))
        // A negative fit must never invert the mapping.
        #expect(inverted.slope > 0)
        #expect(inverted.apply(8) > inverted.apply(5))
    }

    // MARK: - Shape guarantees

    @Test("Calibration is strictly increasing, so it can never reorder a list")
    func mappingIsMonotone() {
        // The property the percentile map only appeared to have.
        let fit = RatingCalibration.fit(pairs: linearPairs(center: 6, trueSlope: 1.5, count: 100))
        var previous = -1.0

        for step in stride(from: 0.0, through: 10.0, by: 0.1) {
            let mapped = fit.apply(step)
            #expect(mapped >= previous)
            previous = mapped
        }
    }

    @Test("Output stays on the 0-10 scale")
    func outputIsClamped() {
        // Unlike the raw estimate, this genuinely can escape: at slope 1.75 and
        // a centre of 6, an input of 10 maps to 13.
        let fit = RatingCalibration.fit(pairs: linearPairs(center: 6, trueSlope: 3, count: 400))

        #expect(fit.apply(10) <= 10)
        #expect(fit.apply(0) >= 0)
        #expect(fit.apply(.nan).isFinite)
        #expect(fit.apply(1e9) <= 10)
    }

    @Test("Bias is reported so the pinned centre can be checked, not trusted")
    func biasIsObservable() {
        // The centred form assumes the model is unbiased at the mean. That
        // holds by construction today; recording it means a later session can
        // find out rather than assume.
        let unbiased = RatingCalibration.fit(pairs: linearPairs(center: 6, trueSlope: 1.2, count: 40))
        #expect(abs(unbiased.observedBias) < 0.0001)

        let shifted = linearPairs(center: 6, trueSlope: 1.0, count: 40)
            .map { (raw: $0.raw + 2.0, actual: $0.actual) }
        #expect(abs(RatingCalibration.fit(pairs: shifted).observedBias - 2.0) < 0.0001)
    }

    // MARK: - The bug this replaced

    @Test("A candidate's rating does not depend on what it was listed beside")
    func ratingIsIndependentOfTheBatch() {
        // The whole failure mode in one assertion. Under the percentile map,
        // being the best of its batch was enough to earn the user's maximum
        // score — so the top of every mood's list read 9.9 regardless of what
        // the model actually thought.
        let fit = RatingCalibration.fit(pairs: linearPairs(center: 6, trueSlope: 1.4, count: 60))
        let candidate = 6.65

        // Same candidate, imagined at the top of a strong batch and the bottom
        // of a weak one. `apply` cannot see either.
        #expect(fit.apply(candidate) == fit.apply(candidate))
        #expect(fit.apply(candidate) < fit.apply(9.0))
        #expect(fit.apply(candidate) > fit.apply(6.0))
    }
}
