//
//  PredictionDisplay.swift
//  WatchRank
//
//  What the Discover screen is allowed to say about a prediction.
//
//  Ranking rule 6 withholds a real score until its bucket holds five items,
//  because a number derived from one comparison implies precision the app has
//  not earned. A *predicted* number is strictly weaker evidence than a real one,
//  so it inherits the rule rather than escaping it: above a confidence floor the
//  number is shown, below it a qualitative band.
//
//  A separate value type rather than a computed property on a view, because it
//  is a product decision with thresholds in it — and because a rule this easy to
//  get quietly wrong should be testable without rendering anything.
//

import Foundation

// MARK: - PredictionDisplay

enum PredictionDisplay: Equatable {

    /// Confident enough to show the number. Carries `displayValue`, the
    /// calibrated figure on the user's own scale — never the raw estimate,
    /// which is muted by roughly three points against the scores the user
    /// writes themselves.
    case score(Double)

    /// Not confident enough for a number. Still says something useful.
    case band(Band)

    // MARK: Band

    enum Band: String, Equatable, CaseIterable {
        case likelyHit
        case worthAShot
        case notForYou

        var label: String {
            switch self {
            case .likelyHit:  return "Likely a hit"
            case .worthAShot: return "Worth a shot"
            case .notForYou:  return "Probably not for you"
            }
        }

        var symbolName: String {
            switch self {
            case .likelyHit:  return "hand.thumbsup"
            case .worthAShot: return "questionmark.circle"
            case .notForYou:  return "hand.thumbsdown"
            }
        }
    }

    // MARK: Thresholds

    /// How far a prediction must sit from the user's baseline before the band
    /// commits to a direction.
    ///
    /// Anchored to the measured effect scale rather than picked round: a
    /// unanimously-loved genre contributes about +0.24 points to a prediction,
    /// so ±0.1 is "less than half of one strong signal" — small enough to let a
    /// real preference register, large enough that noise reads as "worth a
    /// shot" instead of a confident claim.
    static let bandDeadZone = 0.1

    // MARK: Init

    /// - Parameters:
    ///   - predicted: the scored candidate.
    ///   - lift: how far the prediction sits above or below the type baseline.
    ///     Passed in rather than derived, because the baseline belongs to the
    ///     profile and this type deliberately knows nothing about profiles.
    ///   - floor: confidence required to show a number.
    init(
        predicted: PredictedScore,
        lift: Double,
        floor: Double = RecommendationTuning.standard.confidenceFloorForDisplay
    ) {
        guard predicted.confidence >= floor else {
            self = .band(Self.band(for: lift))
            return
        }
        self = .score(predicted.displayValue)
    }

    /// The band a lift falls into.
    ///
    /// Bands read the **lift**, not the value. A low-confidence prediction sits
    /// close to the baseline and is barely calibrated, so its absolute number
    /// says almost nothing — while its direction still does. "Above where you
    /// usually land" is a claim the data supports at low confidence; "7.4" is
    /// not.
    static func band(for lift: Double) -> Band {
        if lift > bandDeadZone { return .likelyHit }
        if lift < -bandDeadZone { return .notForYou }
        return .worthAShot
    }

    // MARK: Accessibility

    /// What VoiceOver reads. The word "predicted" is mandatory: a prediction
    /// spoken as a bare number is indistinguishable from an earned score, and
    /// confusing the two undermines the ranking system's whole claim to
    /// precision.
    var accessibilityDescription: String {
        switch self {
        case .score(let value):
            let formatted = ScoreDisplay.formatter.string(from: value as NSNumber) ?? "—"
            return "predicted \(formatted) out of 10"
        case .band(let band):
            return "predicted: \(band.label)"
        }
    }
}
