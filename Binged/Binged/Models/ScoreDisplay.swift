//
//  ScoreDisplay.swift
//  Binged
//
//  What a list row is allowed to say about an item's standing.
//
//  Ranking rule 6 withholds a real score until its `(type, sentiment)` bucket
//  holds five items, and says the UI shows *position* in the meantime — "#2 in
//  Liked it". That fallback shipped on `MediaDetailView` and nowhere else, so
//  every row on Ranking, Search and Profile went blank for a bucket under the
//  threshold: a watched, ranked title looked exactly like an unwatched search
//  result. The rule's second half was never wired up.
//
//  A value type rather than a computed property on each view, for the reason
//  `PredictionDisplay` is one: the thresholds are a product decision, they must
//  agree everywhere, and a rule this easy to get quietly wrong should be
//  testable without rendering anything.
//

import Foundation

// MARK: - ScoreDisplay

enum ScoreDisplay: Equatable {

    /// The bucket has earned a number. Carries the derived 0–10 score.
    case score(Double)

    /// Watched and genuinely compared, but the bucket is still under
    /// `MediaLibraryViewModel.minimumBucketSizeForScore`. `position` is
    /// 1-based — what the user is shown, not the stored `rankInBucket`.
    case rank(position: Int, sentiment: Sentiment)

    /// Watched, but alone in its bucket or mid-comparison: there is a stored
    /// score and it means nothing yet. The sentiment is all the app can honestly
    /// claim, and rule 6's reasoning applies to a position just as it does to a
    /// number — the first item into a bucket was never compared to anything.
    case sentimentOnly(Sentiment)

    /// Nothing to say: unwatched, queued, or untracked.
    case none

    // MARK: Accessibility

    /// Spoken form. Mirrors `MediaDetailView`'s wording so a title reads the
    /// same in a list as it does on its own screen.
    var accessibilityDescription: String? {
        switch self {
        case .score(let value):
            return "scored \(Self.formatter.string(from: value as NSNumber) ?? "—") out of 10"
        case .rank(let position, let sentiment):
            return "ranked number \(position) in \(sentiment.displayName)"
        case .sentimentOnly(let sentiment):
            return sentiment.displayName
        case .none:
            return nil
        }
    }

    // MARK: Formatting

    /// One decimal place, matching the score shown on the detail screen.
    static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}
