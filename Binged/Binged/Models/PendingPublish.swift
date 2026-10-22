//
//  PendingPublish.swift
//  Binged
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

    /// `"movie|liked"`, or `"movie|queue"` for the want-to-watch list. Unique,
    /// so enqueueing the same bucket twice updates one row instead of adding a
    /// second.
    @Attribute(.unique) var key: String

    var mediaTypeRaw: String
    var sentimentRaw: String

    /// When the bucket first became dirty. Kept rather than overwritten so the
    /// oldest debt drains first.
    var enqueuedAt: Date

    /// Failed drain attempts, for backoff and for surfacing a stuck queue.
    var attempts: Int

    init(mediaType: MediaType, sentiment: Sentiment?, enqueuedAt: Date = .now) {
        self.key = PendingPublish.key(mediaType: mediaType, sentiment: sentiment)
        self.mediaTypeRaw = mediaType.rawValue
        self.sentimentRaw = sentiment?.rawValue ?? PendingPublish.queueMarker
        self.enqueuedAt = enqueuedAt
        self.attempts = 0
    }

    /// **The want-to-watch queue is a bucket like any other**, and this is the
    /// marker that lets a non-optional `String` column say so.
    ///
    /// A queued title has no sentiment — that is what `ranked_items`'
    /// `ranked_or_queued` constraint means by a legal row with three nulls —
    /// so the outbox has to be able to name a bucket that has none. Storing a
    /// reserved value rather than making `sentimentRaw` optional is deliberate:
    /// this is a disposable bookkeeping table (rows are created and deleted
    /// constantly, and an empty outbox is the normal state), and a property
    /// type change is a SwiftData version bump — which per `BingedSchema` needs
    /// a frozen copy of the model and has crashed this app on launch once.
    ///
    /// Safe because `Sentiment` is `liked | fine | disliked`: no raw value can
    /// collide with it. Asserted in `PendingPublishTests`.
    static let queueMarker = "queue"

    static func key(mediaType: MediaType, sentiment: Sentiment?) -> String {
        "\(mediaType.rawValue)|\(sentiment?.rawValue ?? queueMarker)"
    }

    var mediaType: MediaType? { MediaType(rawValue: mediaTypeRaw) }

    /// The sentiment, or `nil` for **both** the queue and an unparseable row.
    ///
    /// Kept for compatibility with readers that only care about the ranked
    /// case. Anything that has to tell those two apart — the drain does, since
    /// one is a bucket to publish and the other is a corrupt row to discard —
    /// must read `bucket` instead.
    var sentiment: Sentiment? { Sentiment(rawValue: sentimentRaw) }

    /// Which bucket this row owes a publish for, or `nil` if it can no longer
    /// be parsed at all.
    ///
    /// **The distinction `sentiment` alone cannot make.** Before the queue was
    /// syncable, `nil` meant "corrupt, drop it", and the drain did exactly that.
    /// A queue row reaching that branch would be silently deleted from the
    /// outbox on every launch — the watchlist failing to sync, quietly, which is
    /// the bug this type is being changed to fix.
    var bucket: Bucket? {
        if sentimentRaw == Self.queueMarker { return .queue }
        return Sentiment(rawValue: sentimentRaw).map(Bucket.ranked)
    }

    enum Bucket: Equatable, Sendable {
        case ranked(Sentiment)
        case queue

        var sentiment: Sentiment? {
            switch self {
            case .ranked(let sentiment): return sentiment
            case .queue:                 return nil
            }
        }
    }
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
    /// `nil` for a want-to-watch entry, alongside `score` and `rankInBucket`.
    /// The three are null together or not at all — `ranked_items`'
    /// `ranked_or_queued` constraint refuses anything in between.
    let sentiment: String?
    let title: String
    let year: Int
    let score: Double?
    let rankInBucket: Int?
    let bucketSize: Int
    /// TMDB's `/abc.jpg`, not the rendered URL — see `TMDBImage.posterPath`.
    /// Optional because a title can be ranked before its artwork is known.
    let posterPath: String?

    /// The owner's own words about the title, or `nil`.
    ///
    /// Published for the same reason the score is: it is part of the ranking a
    /// follower came to read, and — just as importantly — part of what a second
    /// device must get back. Until this field existed the restore path returned
    /// every title and none of the writing, so reinstalling silently discarded
    /// it. Who may read it is the account's privacy setting's job, decided in
    /// `ranked_items_select`, not this field's.
    let review: String?

    enum CodingKeys: String, CodingKey {
        case externalId = "external_id"
        case mediaType = "media_type"
        case sentiment
        case title
        case year
        case score
        case rankInBucket = "rank_in_bucket"
        case bucketSize = "bucket_size"
        case posterPath = "poster_path"
        case review
    }

    /// `nil` for an item the server cannot identify.
    ///
    /// A title with no `externalId` — from the bundled catalog, or an id
    /// migration that never resolved — has nothing to key on, so it stays
    /// local. Dropping it silently would be worse: the count of unpublished
    /// titles is surfaced instead.
    init?(_ item: MediaItem, bucketSize: Int) {
        guard let externalId = item.externalId else { return nil }

        switch item.watchedStatus {
        case .watched:
            // A half-ranked item is not publishable: the constraint would
            // refuse it, and a row reading "#null in null" is worse than a
            // missing one.
            guard let sentiment = item.sentiment,
                  let score = item.score,
                  let rank = item.rankInBucket
            else { return nil }
            self.sentiment = sentiment.rawValue
            self.score = score
            self.rankInBucket = rank

        case .wantToWatch:
            self.sentiment = nil
            self.score = nil
            self.rankInBucket = nil

        case .untracked:
            // Nothing to publish, and nothing to say about it: an untracked
            // title is one the user has expressed no opinion about at all.
            return nil
        }

        self.externalId = externalId
        self.mediaType = item.type.wireValue
        self.title = item.title
        self.year = item.year
        self.bucketSize = bucketSize
        self.posterPath = TMDBImage.posterPath(fromURL: item.posterURL)
        self.review = item.review
    }
}

// MARK: - PublishPayload

/// Everything one drained outbox row sends.
struct PublishPayload: Equatable, Sendable {

    let mediaType: MediaType
    /// `nil` addresses the want-to-watch queue, which is a bucket like any
    /// other — one per media type, holding every queued title of that type.
    let sentiment: Sentiment?

    /// **Every publishable item in the bucket**, not just the one that changed.
    let items: [PublishedItem]

    /// Items in the bucket that could not be published for want of an
    /// `externalId`. Surfaced, never silently dropped.
    let unpublishableCount: Int

    /// A bucket that emptied. The server rows for it must be deleted rather
    /// than left behind, or an un-watched title stays visible to followers.
    var isEmptying: Bool { items.isEmpty }

    init(mediaType: MediaType, sentiment: Sentiment?, bucket: [MediaItem]) {
        self.mediaType = mediaType
        self.sentiment = sentiment

        let size = bucket.count
        let published = bucket.compactMap { PublishedItem($0, bucketSize: size) }
        self.items = published
        self.unpublishableCount = size - published.count
    }
}
