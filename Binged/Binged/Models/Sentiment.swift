//
//  Sentiment.swift
//  Binged
//

import Foundation

// MARK: - Sentiment

/// The coarse reaction the user picks after marking a title as watched. Each
/// sentiment owns a fixed slice of the 0–10 score range; the precise score is
/// derived later from the item's position within its bucket.
///
/// Score ranges (per spec, do not change without product sign-off):
///   - Liked it       → 6.8 ... 10.0
///   - It was fine    → 3.4 ... 6.7
///   - Didn't like it → 0.0 ... 3.3
enum Sentiment: String, Codable, CaseIterable, Identifiable {
    case liked
    case fine
    case disliked

    var id: String { rawValue }

    // MARK: - Display

    var displayName: String {
        switch self {
        case .liked:    return "Liked it"
        case .fine:     return "It was fine"
        case .disliked: return "Didn't like it"
        }
    }

    // MARK: - Score range

    /// The closed 0–10 score range this sentiment owns. The ranges are
    /// non-overlapping and cover [0.0, 10.0] with a small gap between buckets
    /// so the boundaries (3.3 / 3.4 and 6.7 / 6.8) make the tier visible.
    var scoreRange: ClosedRange<Double> {
        switch self {
        case .liked:    return 6.8 ... 10.0
        case .fine:     return 3.4 ... 6.7
        case .disliked: return 0.0 ... 3.3
        }
    }
}
