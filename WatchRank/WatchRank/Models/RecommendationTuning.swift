//
//  RecommendationTuning.swift
//  WatchRank
//
//  Every constant the prediction engine leans on, in one place.
//
//  A struct with a `.standard` value rather than a wall of `static let`s, for
//  two reasons that both arrive in roadmap Phase 17:
//
//    - Cross-validation has to *sweep* these. `K_GENRE` as a `static let` can be
//      read in a test but not varied in a loop, and the only honest way to pick
//      a shrinkage constant is to minimise leave-one-out error over a real
//      library rather than to argue about it.
//    - Phase 17 step 5 contemplates auto-tuning per user. That needs a value
//      that can be constructed, not a global that can be read.
//
//  Everything here is a **prior to be replaced by measurement**, not a
//  measurement itself. The doc comments say what each number is anchored to so
//  a later session can tell a considered guess from a fitted value.
//
//  See `docs/PHASE-13-PLAN.md` §5 for the derivation and
//  `docs/FEATURE-SPACE.md` for the sparsity data the anchors come from.
//

import Foundation

// MARK: - RecommendationTuning

struct RecommendationTuning: Sendable, Equatable {

    // MARK: Type baseline

    /// `K_TYPE` — how hard a per-type mean is pulled toward the global mean.
    ///
    /// With a healthy library this barely moves the number; with two ranked
    /// shows it stops the TV baseline swinging on a single opinion.
    var typeShrinkage: Double

    /// Watched items of a type needed before the type baseline is considered
    /// fully evidenced. Gates confidence, never the point estimate.
    var typeEvidenceFull: Double

    /// What a prediction collapses to when there is no library at all — the
    /// midpoint of the 0–10 scale, deliberately *not* the midpoint of any
    /// sentiment band. An empty library has no sentiment mix to speak for it.
    var neutralScore: Double

    // MARK: Per-family knobs

    /// How much each family contributes to the final prediction. Sums to 1.0
    /// across all families, and absent families contribute nothing rather than
    /// being renormalised away — see `renormalizeOverPresentFamilies`.
    var weights: [Feature.Family: Double]

    /// `K` per family: the support at which a measured effect is taken at half
    /// face value, since `effect = (n / (n + K)) * mean(residual)`.
    var shrinkage: [Feature.Family: Double]

    /// Minimum support for a feature to enter the profile at all.
    ///
    /// Distinct from — and lower than — `displayFloor`. Shrinkage handles a
    /// feature seen twice; it does not help a feature seen once, where the
    /// "effect" is one title's residual wearing a decimal point.
    var inclusionFloor: [Feature.Family: Int]

    /// Support at which a family's evidence is considered complete, for the
    /// confidence calculation. Per family because the families differ by an
    /// order of magnitude in natural density: a genre reaches 7 in a 40-film
    /// library where a keyword sits at 1.
    var evidenceFull: [Feature.Family: Double]

    /// Confidence a prediction must reach before its **number** is shown.
    ///
    /// Ranking rule 6 withholds a real score until its bucket holds five items,
    /// on the grounds that a number implies precision the app has not earned. A
    /// *predicted* number is strictly weaker evidence, so it inherits the same
    /// discipline one layer out: below this, the UI shows a qualitative band.
    /// The value is always computed and stored — only its display is withheld.
    ///
    /// A guess, and explicitly a Phase 17 knob: cross-validation can bin
    /// predictions by confidence and find where error actually becomes
    /// acceptable, which is the only honest way to place this.
    var confidenceFloorForDisplay: Double

    /// How hard a fitted calibration slope is pulled toward 1.0.
    ///
    /// `s_used = 1 + (s_fit - 1) * n / (n + K)`. At n = 20 the user gets half
    /// their fitted personalisation, at n = 100 roughly five sixths. Without it
    /// a twelve-item library can produce a wild slope on noise and every
    /// displayed number inherits it.
    var calibrationShrinkage: Double

    /// Hard limits on the applied slope, after shrinkage.
    ///
    /// A backstop rather than a tuning surface: shrinkage should keep the slope
    /// reasonable, and this catches the case where it does not.
    var calibrationSlopeBounds: ClosedRange<Double>

    /// Matched pairs needed before a calibration is fitted at all. Below this,
    /// `.identity` — which is the correct answer, not a fallback.
    var minimumPairsForCalibration: Int

    /// Minimum support before a feature may be *stated as a fact about the
    /// user* — roadmap Phase 19's floors, parked here so there is one panel
    /// rather than constants scattered across a view.
    ///
    /// Higher than `inclusionFloor` on purpose. Feeding a prediction is cheap
    /// (the averaging damps a weak feature); asserting "your favourite director
    /// is X" is not.
    var displayFloor: [Feature.Family: Int]

    // MARK: Aggregation mode

    /// When `false` (the default), a family the candidate has no features for
    /// contributes zero against a denominator that is always 1.0 — so a
    /// sparsely-described title is pulled toward its baseline.
    ///
    /// When `true`, the weights are renormalised over the families actually
    /// present, giving a title's few known features full leverage.
    ///
    /// This is a flag rather than a decision because it is exactly the kind of
    /// question cross-validation answers and argument does not. The default is
    /// the conservative one: an absent family is an absence of evidence, and a
    /// prior of "no effect" is the honest reading of it. The cost of that
    /// choice is a mild bias toward metadata-rich (so: popular, recent,
    /// Anglophone) titles at the top of the list.
    var renormalizeOverPresentFamilies: Bool

    // MARK: - Defaults

    /// Fallbacks for a family missing from a dictionary above.
    ///
    /// These exist so that adding a `Feature.Family` case cannot silently give
    /// it weight zero and delete it from the model. `RecommendationTuningTests`
    /// asserts every case is present explicitly, so these are a safety net for
    /// a hand-built tuning, not a licence to leave `.standard` incomplete.
    static let defaultWeight = 0.05
    static let defaultShrinkage = 3.0
    static let defaultInclusionFloor = 1
    static let defaultEvidenceFull = 5.0
    static let defaultDisplayFloor = 3

    // MARK: - The standard panel

    static let standard = RecommendationTuning(
        typeShrinkage: 3,
        typeEvidenceFull: 10,
        neutralScore: 5.0,

        // Sums to 1.00. Ordered by weight so the shape is readable.
        weights: [
            // Dense, vocabulary-reconciled, median support 7 at 40 films. The
            // workhorse, and the only family that is reliable at small library
            // sizes.
            .genre: 0.30,
            // Sparse per key, but ~10 per title means the within-family mean is
            // itself an average over ten estimates. Carries tone, which is the
            // thing genres cannot express.
            .keyword: 0.24,
            // High precision when it fires and it rarely fires: the measured
            // count of directors seen 3+ times is 0.4 at 50 films.
            .director: 0.10,
            // The densest credit family (3 per title), but 50% of a repeat
            // actor's appearances fall under one director, so this is partly
            // the director signal counted twice. Deliberately below `director`.
            .cast: 0.09,
            // Rare, near-deterministic when present. Two films from one
            // collection is a real statement of preference.
            .franchise: 0.06,
            // Repeats more than directors (8.2 vs 2.3 per 100 films) because a
            // composer spans directors, but is a weaker claim about taste.
            .composer: 0.05,
            // Confounded with the baseline — most libraries skew to one decade,
            // so this family mostly re-describes the mean. Low weight, high K.
            .era: 0.05,
            // Genuinely informative (subtitle tolerance is a fact about a
            // person) over very few distinct values.
            .lang: 0.05,
            // Weak, and mostly a proxy for format rather than for taste.
            .runtime: 0.03,
            // TV only, and the major networks are close to synonyms for
            // "exists". Kept for the rare distinctive one.
            .network: 0.03,
        ],

        shrinkage: [
            // Median support 7 at 40 films, so K = 3 leaves a typical genre at
            // 70% face value. The roadmap's value, and the measurement agrees.
            .genre: 3,
            // K = 3 would leave a support-2 keyword at 40% and silence the
            // family while still costing it denominator space — the worst of
            // both. Sparse features need a small K to speak at all.
            .keyword: 1,
            // Sparse by construction; K = 2 lets a twice-seen person contribute
            // at half weight.
            .director: 2,
            .composer: 2,
            .cast: 2,
            // Two films in one collection is strong evidence on its own.
            .franchise: 1,
            // Near-universal, so support is large regardless. A high K guards
            // against a lopsided library manufacturing an era or runtime effect
            // out of what is really the baseline.
            .era: 8,
            .runtime: 8,
            .lang: 4,
            .network: 4,
        ],

        inclusionFloor: [
            // 66% of keywords appear on exactly one title. A support-1 keyword's
            // "effect" is one film's residual and nothing else, so it is dropped
            // rather than shrunk — shrinking it would still cost denominator.
            .keyword: 2,
            // Many-per-title, so support accumulates cheaply and a floor of 2
            // costs the family very little.
            .cast: 2,
            // Everything else floors at 1: either one-per-title families where
            // 2 is genuinely hard to reach, or dense families where it is
            // automatic.
            .genre: 1,
            .era: 1,
            .runtime: 1,
            .lang: 1,
            .director: 1,
            .composer: 1,
            .franchise: 1,
            .network: 1,
        ],

        evidenceFull: [
            .genre: 8,
            .keyword: 3,
            .director: 3,
            .composer: 3,
            .cast: 3,
            .franchise: 3,
            .network: 3,
            // Near-universal families need a much higher bar before their
            // support counts as knowing something: `lang:en` reaching 35 in a
            // 40-film library says nothing about taste.
            .era: 15,
            .runtime: 15,
            .lang: 15,
        ],

        confidenceFloorForDisplay: 0.35,
        calibrationShrinkage: 20,
        calibrationSlopeBounds: 0.75...1.75,
        minimumPairsForCalibration: 8,

        displayFloor: [
            // Roadmap Phase 19. A "favourite director" card is empty below
            // roughly 100 watched films and empty at every measured size for
            // television — these floors are what make that honest rather than
            // embarrassing.
            .genre: 3,
            .keyword: 3,
            .director: 3,
            .composer: 3,
            .cast: 3,
            .franchise: 2,
            .network: 3,
            .era: 5,
            .runtime: 5,
            .lang: 5,
        ],

        renormalizeOverPresentFamilies: false
    )

    // MARK: - Lookups

    func weight(_ family: Feature.Family) -> Double {
        weights[family] ?? Self.defaultWeight
    }

    func shrinkage(_ family: Feature.Family) -> Double {
        shrinkage[family] ?? Self.defaultShrinkage
    }

    func inclusionFloor(_ family: Feature.Family) -> Int {
        inclusionFloor[family] ?? Self.defaultInclusionFloor
    }

    func evidenceFull(_ family: Feature.Family) -> Double {
        evidenceFull[family] ?? Self.defaultEvidenceFull
    }

    func displayFloor(_ family: Feature.Family) -> Int {
        displayFloor[family] ?? Self.defaultDisplayFloor
    }

    /// Total weight across every family, which is the denominator the
    /// prediction divides by when `renormalizeOverPresentFamilies` is off.
    ///
    /// Computed rather than assumed to be 1.0 so a hand-built tuning that does
    /// not sum to one still produces a bounded prediction instead of a silently
    /// scaled one.
    var totalWeight: Double {
        Feature.Family.allCases.reduce(0) { $0 + weight($1) }
    }
}
