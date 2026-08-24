//
//  RankedItem.swift
//  WatchRank
//
//  One title on somebody else's ranking, as the server stores it.
//
//  Distinct from `MediaItem` on purpose: that is the user's own, persisted,
//  mutable library row. This is a read-only copy of a *stranger's* ranking, and
//  it must never gain an edit affordance or reach the store.
//

import Foundation

// MARK: - RankedItem

struct RankedItem: Codable, Identifiable, Equatable, Sendable {

    let externalId: String
    let mediaType: MediaType
    let sentiment: Sentiment
    let title: String
    let year: Int
    let score: Double
    let rankInBucket: Int

    /// How many titles were in this bucket when it was published.
    ///
    /// **This is what makes rule 6 enforceable by the reader.** A viewer must be
    /// able to decide for themselves whether a score has been earned; a bare 8.4
    /// from a bucket of one is the same unearned precision the ranking system
    /// refuses to show locally, and publishing it would be worse, not better.
    let bucketSize: Int

    var id: String { "\(mediaType.rawValue)|\(externalId)" }

    enum CodingKeys: String, CodingKey {
        case externalId = "external_id"
        case mediaType = "media_type"
        case sentiment
        case title
        case year
        case score
        case rankInBucket = "rank_in_bucket"
        case bucketSize = "bucket_size"
    }

    /// The score, or `nil` when the bucket has not earned a number.
    ///
    /// Applies `MediaLibraryViewModel.minimumBucketSizeForScore` — the *same*
    /// threshold the owner's device applies — so a title reads identically on
    /// their screen and on a stranger's.
    var displayScore: Double? {
        bucketSize >= MediaLibraryViewModel.minimumBucketSizeForScore ? score : nil
    }

    /// "#2 in Liked it" — what is shown when the score is withheld.
    var positionDescription: String {
        "#\(rankInBucket + 1) in “\(sentiment.displayName)”"
    }
}

// MARK: - Sections

extension Array where Element == RankedItem {

    /// Grouped the way `RankingView` groups: `(type, sentiment)`, best first.
    /// A foreign ranking should look like a ranking.
    func bucketed(type: MediaType) -> [(sentiment: Sentiment, items: [RankedItem])] {
        Sentiment.allCases.compactMap { sentiment in
            let items = filter { $0.mediaType == type && $0.sentiment == sentiment }
                .sorted { $0.rankInBucket < $1.rankInBucket }
            return items.isEmpty ? nil : (sentiment: sentiment, items: items)
        }
    }
}
