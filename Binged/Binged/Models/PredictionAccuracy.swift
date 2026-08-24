//
//  PredictionAccuracy.swift
//  Binged
//
//  How good the predictions actually are, measured rather than asserted.
//
//  **Rank agreement is the primary metric, not error.** A stored score is a
//  quantile over its bucket, so it moves whenever the bucket grows — without the
//  user's opinion changing. Mean absolute error is therefore measured against a
//  drifting target, while Spearman's rho is invariant to exactly that drift.
//  Error is kept because it is the interpretable number a Profile line can show,
//  not because it is the better judge.
//
//  Two nulls, not one. Roughly 85% of a residual's magnitude is *which bucket* a
//  title landed in, so "always predict the type baseline" is the easy null and
//  "always predict the modal sentiment's midpoint" is the hard one. Beating only
//  the first is a weaker result than it looks.
//

import Foundation

// MARK: - PredictionAccuracy

struct PredictionAccuracy: Sendable, Equatable {

    // MARK: Sample

    let sampleSize: Int

    // MARK: Rank agreement

    /// Spearman's rho between predicted order and actual order, `-1...1`.
    ///
    /// The gate. `nil` when there is nothing to correlate — fewer than two
    /// pairs, or a prediction that never varies.
    let spearman: Double?

    /// The two-sided 5% threshold for this sample size: `1.96 / sqrt(n - 1)`.
    /// Below it, a positive rho is not distinguishable from luck.
    let significanceThreshold: Double

    var isSignificant: Bool {
        guard let spearman else { return false }
        return abs(spearman) >= significanceThreshold
    }

    // MARK: Error

    let meanAbsoluteError: Double

    /// "Always predict this type's baseline." The easy null.
    let baselineNullError: Double

    /// "Always predict the midpoint of the bucket the user uses most." The hard
    /// null, and the one that matters — it encodes the single fact that carries
    /// most of the signal.
    let modalNullError: Double

    var beatsEasyNull: Bool { meanAbsoluteError < baselineNullError }
    var beatsHardNull: Bool { meanAbsoluteError < modalNullError }

    // MARK: Ranking quality

    /// Share of the top ten predictions that the user actually placed in their
    /// Liked bucket. A smoke test: with half a library Liked the random baseline
    /// is already ~0.5.
    let precisionAtTen: Double?

    // MARK: Confidence

    /// Mean absolute error per confidence decile, lowest confidence first.
    ///
    /// If this does not trend downward, `confidence` is decoration and the
    /// Discover screen must stop gating a number on it.
    let errorByConfidenceDecile: [Double]

    /// Whether error falls as confidence rises, allowing one reversal for noise.
    var confidenceIsInformative: Bool {
        let deciles = errorByConfidenceDecile.filter(\.isFinite)
        guard deciles.count >= 3 else { return false }
        var reversals = 0
        for (lower, higher) in zip(deciles, deciles.dropFirst()) where higher > lower {
            reversals += 1
        }
        return reversals <= 1
    }

    // MARK: Empty

    static let empty = PredictionAccuracy(
        sampleSize: 0, spearman: nil, significanceThreshold: .infinity,
        meanAbsoluteError: 0, baselineNullError: 0, modalNullError: 0,
        precisionAtTen: nil, errorByConfidenceDecile: []
    )

    var isEmpty: Bool { sampleSize == 0 }

    // MARK: - Display

    /// One honest sentence for Profile, or `nil` when there is nothing earned to
    /// say.
    ///
    /// Deliberately refuses to speak when the correlation is not significant.
    /// "Predictions land within 1.2 points" sounds like a result and would be
    /// one only if the ordering held up; at n = 41 with rho below threshold it
    /// is a number dressed as a finding.
    var headline: String? {
        guard sampleSize >= 8 else { return nil }
        guard isSignificant else {
            return "Not enough ranked titles yet to tell whether predictions are working."
        }
        let points = String(format: "%.1f", meanAbsoluteError)
        return "Predictions are landing within \(points) points of what you go on to rate."
    }
}

// MARK: - Ranks

enum Ranks {

    /// Fractional ranks, ties sharing their midrank. Ties matter here: pool
    /// candidates routinely predict identically, and splitting them by array
    /// position would invent an ordering the model never expressed.
    static func midranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)

        var index = 0
        while index < order.count {
            var end = index
            while end + 1 < order.count, values[order[end + 1]] == values[order[index]] {
                end += 1
            }
            let midrank = Double(index + end) / 2
            for position in index...end { ranks[order[position]] = midrank }
            index = end + 1
        }
        return ranks
    }

    /// Pearson correlation, `nil` when either side is constant.
    static func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count, lhs.count >= 2 else { return nil }
        let n = Double(lhs.count)
        let meanL = lhs.reduce(0, +) / n
        let meanR = rhs.reduce(0, +) / n

        var covariance = 0.0, varianceL = 0.0, varianceR = 0.0
        for (l, r) in zip(lhs, rhs) {
            covariance += (l - meanL) * (r - meanR)
            varianceL += (l - meanL) * (l - meanL)
            varianceR += (r - meanR) * (r - meanR)
        }
        guard varianceL > 1e-12, varianceR > 1e-12 else { return nil }
        let result = covariance / (varianceL * varianceR).squareRoot()
        return result.isFinite ? result : nil
    }

    /// Spearman is Pearson over midranks.
    static func spearman(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        correlation(midranks(lhs), midranks(rhs))
    }
}
