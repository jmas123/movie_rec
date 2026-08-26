//
//  RatingCalibration.swift
//  Binged
//
//  Maps the engine's raw estimate onto the user's own 0–10 rating scale, fitted
//  separately for movies and television by `RecommendationViewModel`.
//
//  This replaces a quantile map from candidate rank, which was wrong in a way
//  worth recording so nobody rebuilds it. That version took a candidate's
//  percentile *within its batch* and looked up the user's score at the same
//  percentile — so the top of every mood's list was handed the user's maximum
//  score by arithmetic, every time, regardless of what the model thought. It
//  also implied that half of all popular unwatched titles would land in the
//  user's "Liked" bucket, reproducing a hit rate they achieved by *choosing*
//  what to watch, on a set they did not choose.
//
//  The replacement learns the mapping from the model's own errors instead:
//  leave-one-out predictions on the user's watched library, paired with what
//  they actually scored those titles. That has a statistical justification the
//  percentile map never had.
//
//  **The fitted slope is trusted in proportion to what the model explains**, not
//  merely to how many ratings exist. A library can be large and still say
//  nothing about how to rescale, and stretching numbers on the strength of a
//  slope fitted to noise makes the app look more certain than it has earned.
//
//  **The null result is slope 1.0, and it is meaningful.** If `raw` is a
//  well-calibrated conditional expectation then `E[actual | raw] == raw`, so the
//  fitted slope is exactly one and calibration correctly does nothing. A
//  conditional expectation is also *under-dispersed* by construction —
//  `var(raw) == r² · var(actual)` — so a compressed range is not evidence of
//  miscalibration. A slope above one means the model is genuinely over-shrunk;
//  that is a finding, not an assumption to design around.
//

import Foundation

// MARK: - RatingCalibration

struct RatingCalibration: Sendable, Equatable {

    /// The point the mapping pivots on: the user's mean rating.
    ///
    /// Pinned rather than fitted as a free intercept. `baseline` is a shrunk
    /// mean, so the model is unbiased at the centre by construction — fixing it
    /// there leaves one parameter to estimate instead of two, and a twelve-item
    /// library cannot drift the whole scale on noise. `observedBias` records
    /// whether that assumption held, so it can be checked rather than trusted.
    let center: Double

    /// The slope actually applied, already shrunk toward 1.0 and bounded.
    let slope: Double

    /// The unshrunk least-squares slope, kept for diagnosis. This is the number
    /// that says whether the model is over-shrunk (> 1), well calibrated (≈ 1),
    /// or over-confident (< 1).
    let fittedSlope: Double

    /// Matched pairs behind the fit.
    let sampleSize: Int

    /// Squared correlation between prediction and actual over those pairs — the
    /// share of variance the model explains, and the thing that decides how far
    /// the fitted slope is trusted.
    let explainedVariance: Double

    /// `mean(raw) - mean(actual)`. Should sit near zero; a large value means the
    /// centred form is the wrong shape and an intercept is genuinely needed.
    let observedBias: Double

    // MARK: Identity

    /// No personalisation: `apply` returns its input, clamped.
    ///
    /// The correct calibration in the absence of evidence, which makes it the
    /// right default rather than a placeholder — a library with nothing to learn
    /// from gets the raw conditional expectation, which is the honest number.
    static let identity = RatingCalibration(
        center: 0, slope: 1, fittedSlope: 1, sampleSize: 0,
        explainedVariance: 0, observedBias: 0
    )

    var isIdentity: Bool { slope == 1 }

    // MARK: Applying

    /// Maps a raw estimate onto the user's scale.
    ///
    /// Strictly increasing for any positive slope, so this can never reorder a
    /// list — the property the percentile map only appeared to have.
    func apply(_ raw: Double) -> Double {
        let mapped = center + slope * (raw - center)
        guard mapped.isFinite else { return min(10, max(0, raw)) }
        return min(10, max(0, mapped))
    }

    // MARK: Fitting

    /// Fits from leave-one-out matched pairs.
    ///
    /// Least squares on the centred form: minimising
    /// `Σ (actual − (μ + s(raw − μ)))²` over `s` alone.
    ///
    /// Returns `.identity` when there is nothing to learn — too few pairs, or a
    /// `raw` that never varies, which carries no information about slope no
    /// matter how many pairs there are.
    static func fit(
        pairs: [(raw: Double, actual: Double)],
        tuning: RecommendationTuning = .standard
    ) -> RatingCalibration {
        let usable = pairs.filter { $0.raw.isFinite && $0.actual.isFinite }
        let count = usable.count
        guard count >= tuning.minimumPairsForCalibration else { return .identity }

        let center = usable.map(\.actual).reduce(0, +) / Double(count)
        let meanRaw = usable.map(\.raw).reduce(0, +) / Double(count)

        // Does `raw` vary at all? Measured about its *own* mean, not about the
        // pinned centre. A constant raw sitting off-centre still produces a
        // non-zero denominator below, and least squares would dutifully answer
        // "slope 0" — compressing every title onto the user's average. That is
        // the right answer to "raw has no predictive power" and the wrong
        // answer to "we have not learned anything yet", and here it is the
        // second: with no evidence that the model is mis-scaled, leave it alone.
        let rawSpread = usable.reduce(0.0) { $0 + ($1.raw - meanRaw) * ($1.raw - meanRaw) }
        guard rawSpread > 1e-9 else { return .identity }

        var covariance = 0.0
        var variance = 0.0
        for pair in usable {
            let deviation = pair.raw - center
            covariance += deviation * (pair.actual - center)
            variance += deviation * deviation
        }

        guard variance > 1e-9 else { return .identity }

        let fitted = covariance / variance
        guard fitted.isFinite else { return .identity }

        // How much of the actual variation the model explains at all.
        let actualSpread = usable.reduce(0.0) { $0 + ($1.actual - center) * ($1.actual - center) }
        let explained = actualSpread > 1e-9
            ? min(1, max(0, (covariance * covariance) / (variance * actualSpread)))
            : 0

        // Shrink toward 1.0 on **two** counts: how much data there is, and how
        // much of it the model accounts for.
        //
        // Sample size alone is not enough, and assuming it was is what this
        // formula is a correction to. Forty-one ratings look like decent
        // evidence, so an n-only rule keeps most of a fitted slope — but if the
        // model explains 3% of the variance, that slope is almost entirely
        // noise and the honest response is to leave the numbers alone. On a real
        // 41-title library the two rules disagree completely: n-only gives 2.05
        // (clamped to the 1.75 ceiling), evidence-weighted gives 1.04, which is
        // very nearly the identity it should be.
        let weight = explained * Double(count) / (Double(count) + max(0, tuning.calibrationShrinkage))
        let shrunk = 1 + (fitted - 1) * weight

        let bounds = tuning.calibrationSlopeBounds
        let bounded = min(bounds.upperBound, max(bounds.lowerBound, shrunk))

        return RatingCalibration(
            center: center,
            slope: bounded,
            fittedSlope: fitted,
            sampleSize: count,
            explainedVariance: explained,
            observedBias: meanRaw - center
        )
    }
}
