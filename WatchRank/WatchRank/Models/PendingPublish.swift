//
//  PendingPublish.swift
//  WatchRank
//
//  The outbox: one row per bucket that owes the server a publish.
//
//  Keyed by `(mediaType, sentiment)` rather than by item, because **a publish is
//  always a whole bucket**. Publishing only the item the user touched would be
//  the vacated-bucket bug with a network in the middle: every score in a bucket
//  is a quantile over its current size, so moving one item rewrites all of them,
//  and shipping one row would leave the survivors on the server holding scores
//  computed for the old N.
//
//  The unique key is what makes coalescing free. Rank five films in a row and
//  the outbox holds one row, not five — so the queue cannot grow faster than the
//  number of buckets, however fast the user ranks.
//

import Foundation
import SwiftData

// MARK: - PendingPublish

@Model
final class PendingPublish {

    /// `"movie|liked"`. Unique, so enqueueing the same bucket twice updates one
    /// row instead of adding a second.
    @Attribute(.unique) var key: String

    var mediaTypeRaw: String
    var sentimentRaw: String

    /// When the bucket first became dirty. Kept rather than overwritten so the
    /// oldest debt drains first.
    var enqueuedAt: Date

    /// Failed drain attempts, for backoff and for surfacing a stuck queue.
    var attempts: Int

    init(mediaType: MediaType, sentiment: Sentiment, enqueuedAt: Date = .now) {
        self.key = PendingPublish.key(mediaType: mediaType, sentiment: sentiment)
        self.mediaTypeRaw = mediaType.rawValue
        self.sentimentRaw = sentiment.rawValue
        self.enqueuedAt = enqueuedAt
        self.attempts = 0
    }

    static func key(mediaType: MediaType, sentiment: Sentiment) -> String {
        "\(mediaType.rawValue)|\(sentiment.rawValue)"
    }

    var mediaType: MediaType? { MediaType(rawValue: mediaTypeRaw) }
    var sentiment: Sentiment? { Sentiment(rawValue: sentimentRaw) }
}

// MARK: - PublishedItem

/// One title as the server stores it.
///
/// `bucketSize` travels with every row so **rule 6 is enforceable by whoever is
/// reading**. A viewer must be able to decide for themselves whether a score has
/// been earned; sending a bare 8.4 and trusting the reader to have counted the
/// bucket is how a stranger's one-item "8.4" ends up on screen.
struct PublishedItem: Codable, Equatable, Sendable {

    let externalId: String
    let mediaType: String
    let sentiment: String
    let title: String
    let year: Int
    let score: Double
    let rankInBucket: Int
    let bucketSize: Int

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

    /// `nil` for an item the server cannot identify.
    ///
    /// A title with no `externalId` — from the bundled catalog, or an id
    /// migration that never resolved — has nothing to key on, so it stays
    /// local. Dropping it silently would be worse: the count of unpublished
    /// titles is surfaced instead.
    init?(_ item: MediaItem, bucketSize: Int) {
        guard let externalId = item.externalId,
              let sentiment = item.sentiment,
              let score = item.score,
              let rank = item.rankInBucket,
              item.watchedStatus == .watched
        else { return nil }

        self.externalId = externalId
        self.mediaType = item.type.wireValue
        self.sentiment = sentiment.rawValue
        self.title = item.title
        self.year = item.year
        self.score = score
        self.rankInBucket = rank
        self.bucketSize = bucketSize
    }
}

// MARK: - PublishPayload

/// Everything one drained outbox row sends.
struct PublishPayload: Equatable, Sendable {

    let mediaType: MediaType
    let sentiment: Sentiment

    /// **Every publishable item in the bucket**, not just the one that changed.
    let items: [PublishedItem]

    /// Items in the bucket that could not be published for want of an
    /// `externalId`. Surfaced, never silently dropped.
    let unpublishableCount: Int

    /// A bucket that emptied. The server rows for it must be deleted rather
    /// than left behind, or an un-watched title stays visible to followers.
    var isEmptying: Bool { items.isEmpty }

    init(mediaType: MediaType, sentiment: Sentiment, bucket: [MediaItem]) {
        self.mediaType = mediaType
        self.sentiment = sentiment

        let size = bucket.count
        let published = bucket.compactMap { PublishedItem($0, bucketSize: size) }
        self.items = published
        self.unpublishableCount = size - published.count
    }
}
