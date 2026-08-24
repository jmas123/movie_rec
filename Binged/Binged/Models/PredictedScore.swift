//
//  PredictedScore.swift
//  Binged
//
//  What the engine says about one candidate: a number, how much it is worth
//  trusting, and why.
//
//  The "why" is not decoration. Roadmap Phase 16 puts a one-line rationale under
//  every recommendation ("because you rate crime thrillers highly"), and a
//  rationale generated separately from the arithmetic is a rationalisation. The
//  contributions here are the actual summands of the prediction, so the sentence
//  the user reads and the number they see cannot drift apart.
//

import Foundation

// MARK: - FeatureContribution

/// One feature's signed contribution to a prediction, in points of score.
///
/// `amount` is the term as it entered the sum — `weight(family) * effect /
/// familySize`, not the raw effect — so the contributions of a prediction add
/// up to its lift over baseline. That makes an explanation auditable and a
/// wrong number traceable to the feature that caused it.
struct FeatureContribution: Sendable, Hashable {

    let feature: Feature
    let amount: Double

    /// The feature's support in the library, carried through so a caller can
    /// apply Phase 19's display floor without re-consulting the profile.
    let support: Int
}

// MARK: - PredictedScore

struct PredictedScore: Sendable {

    /// The raw estimate, clamped to `0...10`.
    ///
    /// This is a conditional expectation and it is deliberately conservative:
    /// because family weights sum to one and absent families contribute zero,
    /// it cannot be lifted further above baseline than the single strongest
    /// family effect. That is correct under squared loss and misleading on a
    /// screen — which is what `displayValue` exists to fix.
    let value: Double

    /// `0...1`. Two independent ways to be ignorant, multiplied: how much the
    /// app knows about this candidate's features, and how much it knows about
    /// this media type at all.
    ///
    /// A heuristic, not a calibrated probability. Roadmap Phase 17 checks
    /// whether error actually decreases across confidence deciles; if it does
    /// not, this is decoration and Phase 16 must stop gating on it.
    let confidence: Double

    /// Weighted mean per-feature support behind this prediction. Diagnostic
    /// only — `confidence` is the number to gate on.
    let evidence: Double

    /// Which families the candidate carried any feature for.
    ///
    /// The retrieve-then-rerank hook: a candidate scored from the pool alone
    /// carries only `.genre` and `.era`, so a caller can tell which titles are
    /// worth spending a metadata fetch on before rescoring them.
    let familiesPresent: Set<Feature.Family>

    /// Positive contributors, largest first, ties broken by feature key so the
    /// order is total. Determinism matters here: this feeds a rank correlation
    /// in Phase 17 and a sentence in Phase 16, and neither survives a list that
    /// reshuffles between renders.
    let topContributingFeatures: [FeatureContribution]

    /// `value` mapped onto the user's own scoring scale, blended by confidence.
    ///
    /// Equal to `value` until `RecommendationEngine.calibrate` has run over the
    /// batch, and equal to it always at `confidence == 0`. Calibration is
    /// monotone, so this never reorders a list — it only changes what the
    /// numbers read as.
    let displayValue: Double

    // MARK: - Init

    init(
        value: Double,
        confidence: Double,
        evidence: Double,
        familiesPresent: Set<Feature.Family>,
        topContributingFeatures: [FeatureContribution],
        displayValue: Double? = nil
    ) {
        self.value = value
        self.confidence = confidence
        self.evidence = evidence
        self.familiesPresent = familiesPresent
        self.topContributingFeatures = topContributingFeatures
        self.displayValue = displayValue ?? value
    }

    // MARK: - Derived

    /// A prediction with no library behind it: the neutral midpoint, and an
    /// explicit statement that nothing is known.
    static func neutral(_ value: Double) -> PredictedScore {
        PredictedScore(
            value: value,
            confidence: 0,
            evidence: 0,
            familiesPresent: [],
            topContributingFeatures: []
        )
    }

    /// A copy carrying a calibrated display number. Everything else is the
    /// estimate as computed, which is what Phase 17 evaluates against.
    func withDisplayValue(_ newValue: Double) -> PredictedScore {
        PredictedScore(
            value: value,
            confidence: confidence,
            evidence: evidence,
            familiesPresent: familiesPresent,
            topContributingFeatures: topContributingFeatures,
            displayValue: newValue
        )
    }
}
