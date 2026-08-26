//
//  TitleWatcher.swift
//  Binged
//
//  One person you follow, and what they made of one title.
//
//  A sibling of `RankedItem` rather than a reuse of it, because the two answer
//  opposite questions: `RankedItem` is "one title on one person's ranking",
//  reached from that person's profile, where the identity is already on screen.
//  This is "one person's opinion of the title I am looking at", so the person is
//  the part that has to be carried and the title is the part already known.
//
//  Read-only, like `RankedItem`, and for the same reason: it is somebody else's
//  ranking and must never gain an edit affordance or reach the store.
//

import Foundation

// MARK: - TitleWatcher

struct TitleWatcher: Codable, Identifiable, Hashable, Sendable {

    let userID: UUID
    let handle: String
    let displayName: String?
    let avatarURL: String?

    let sentiment: Sentiment
    let score: Double?
    let rankInBucket: Int?

    /// How many titles were in their bucket when it was published — the input
    /// to rule 6, carried so this screen can apply the owner's own threshold.
    let bucketSize: Int

    let review: String?

    var id: UUID { userID }

    var name: String { displayName ?? handle }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case handle
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case sentiment
        case score
        case rankInBucket = "rank_in_bucket"
        case bucketSize = "bucket_size"
        case review
    }

    /// Their score, or `nil` when their bucket has not earned a number.
    ///
    /// The same threshold their own device applies, so a title reads identically
    /// on their screen and on yours. Showing a friend's "8.4" from a bucket of
    /// one would leak exactly the unearned precision the ranking rules refuse to
    /// show its owner — and it would be worse here, because a number attributed
    /// to a person reads as their considered verdict.
    var displayScore: Double? {
        guard let score, bucketSize >= MediaLibraryViewModel.minimumBucketSizeForScore else {
            return nil
        }
        return score
    }

    /// "#2 in Liked it" — what stands in when the score is withheld.
    var positionDescription: String? {
        guard let rankInBucket else { return nil }
        return "#\(rankInBucket + 1) in “\(sentiment.displayName)”"
    }

    var hasReview: Bool {
        guard let review else { return false }
        return !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
