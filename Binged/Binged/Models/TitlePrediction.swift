//
//  TitlePrediction.swift
//  Binged
//
//  What the app thinks the user would score one specific title they have not
//  watched. The Detail screen's answer to "is this worth my evening?".
//
//  Separate from `Recommendation` because the two carry different questions.
//  A `Recommendation` came out of a mood request and knows its mood weight and
//  its queue state; this came from the user tapping a title, where neither
//  exists and inventing them would be noise.
//

import Foundation

// MARK: - TitlePrediction

struct TitlePrediction: Sendable {

    let predicted: PredictedScore

    /// How far the prediction sits above or below the user's baseline for this
    /// type. Drives the qualitative band when confidence is too low for a
    /// number.
    let lift: Double

    /// Whether the full feature set was fetched, or the estimate rests on the
    /// genres and era alone.
    ///
    /// Not shown to the user, but it is the difference between a prediction
    /// worth a number and one worth a band — and it makes the two cases
    /// distinguishable when a prediction looks wrong.
    let isEnriched: Bool

    var display: PredictionDisplay {
        PredictionDisplay(predicted: predicted, lift: lift)
    }
}
