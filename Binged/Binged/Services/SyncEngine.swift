//
//  SyncEngine.swift
//  Binged
//
//  Drains the outbox. Nothing else in the app waits on it.
//
//  Part III's second invariant: **the comparison flow never waits on a
//  network.** "Which did you prefer?" resolves at local latency, always,
//  including in airplane mode. Publishing happens afterwards, here, and can fail
//  as often as it likes without the user losing a ranking.
//
//  Which is why the outbox is a persisted `@Model` rather than an in-memory
//  queue: killing the app mid-publish must lose nothing, and the debt has to
//  survive a relaunch.
//
//  **Syncing is not a question the user is asked.** A signed-in user's ranking
//  always reaches their own account, so signing in on a new phone restores it —
//  that is what an account is *for*, and gating it on an answer would mean the
//  people most careful about their privacy are the only ones with no backup.
//
//  Who else can read those rows is a separate question this file does not
//  answer at all: it is the account's own `is_private` setting, applied by
//  `ranked_items_select` in Postgres. There is no publication flag on a row and
//  no publish step in a drain — public account, anyone signed in; private
//  account, accepted followers.
//
//  So two things stop a drain, not three. No account: there is nobody to sync
//  for. A ranking in progress: the bucket is mid-rewrite, and sending it now
//  would store a position the user is still deciding. Both leave the outbox
//  exactly as it was, because the debt is still owed either way.
//

import Foundation
import Observation
import SwiftData

// MARK: - PublishTransport

/// The one thing the engine needs from a server. Narrow, so tests drive it
/// without a network and the app can be signed out without a special case.
protocol PublishTransport: Sendable {
    /// Upserts a whole bucket. Idempotent by contract: the payload is the
    /// complete bucket, so re-running a drained queue changes nothing.
    ///
    /// **Carries no visibility flag, and there is none to carry.** Who may
    /// read a row is decided entirely by the owner's `profiles.is_private` and
    /// the follow graph, in `ranked_items_select`. A publish is about content,
    /// never about an audience.
    func publish(_ payload: PublishPayload, userID: UUID) async throws

    /// Removes every server row for a bucket that has emptied.
    ///
    /// **Deletion, not hiding.** Used only when the titles are genuinely gone
    /// from the library — un-watched, re-rated into another bucket. Narrowing
    /// the audience is not this: that is the Private account toggle, which
    /// changes who may read the rows and never removes one.
    /// `sentiment` is `nil` for the want-to-watch queue.
    func deleteBucket(mediaType: MediaType, sentiment: Sentiment?, userID: UUID) async throws
}

// MARK: - SyncEngine

/// `@Observable` so the Settings screen can show what is still outstanding
/// without a second object holding a copy of it.
@MainActor
@Observable
final class SyncEngine {

    @ObservationIgnored private let library: MediaLibraryViewModel
    @ObservationIgnored private let transport: PublishTransport
    /// Optional: signed out, or on a build with no server, posts simply are not
    /// emitted and the publish half still runs.
    @ObservationIgnored private let feed: FeedService?
    /// Signed out, there is nobody to publish for — and the outbox simply keeps
    /// accruing until there is.
    @ObservationIgnored private let currentUserID: () -> UUID?

    private var isDraining = false

    init(
        library: MediaLibraryViewModel,
        transport: PublishTransport,
        feed: FeedService? = nil,
        currentUserID: @escaping () -> UUID?
    ) {
        self.library = library
        self.transport = transport
        self.feed = feed
        self.currentUserID = currentUserID
    }

    // MARK: State

    /// Buckets still owing a publish.
    var pendingCount: Int { library.pendingPublishes.count }

    /// Watched titles that can never be published, because the catalog gave
    /// them no id. Surfaced so the UI can say "3 titles are not published"
    /// rather than quietly omitting them.
    var unpublishableCount: Int {
        library.allWatched.filter { $0.externalId == nil }.count
    }

    /// Watched titles that *would* go to the server. Stated as a number rather
    /// than as "your library" so that Settings can say something a user is able
    /// to check against what they see on their own profile.
    var publishableCount: Int {
        library.allWatched.filter { $0.externalId != nil }.count
    }

    // MARK: Draining

    /// Publishes every outstanding bucket.
    ///
    /// - Returns: how many buckets drained. Zero is the normal signed-out and
    ///   nothing-to-do answer, not a failure.
    @discardableResult
    func drain() async -> Int {
        guard !isDraining, let userID = currentUserID() else { return 0 }
        // A bucket being rewritten right now is not a bucket to publish. The
        // provisional midpoint `markWatched` assigns is a placeholder the user
        // has not agreed to, and `finalizeRanking` saves again the moment the
        // session closes — which re-fires whatever trigger brought us here.
        guard !library.isRankingInProgress else { return 0 }
        isDraining = true
        defer { isDraining = false }

        var drained = 0
        for pending in library.pendingPublishes {
            // `bucket`, not `sentiment`: the latter is nil for the want-to-watch
            // queue *and* for an unparseable row, and those need opposite
            // treatment. Reading `sentiment` here is what silently discarded
            // every watchlist row before the queue was syncable — which is the
            // half of that bug living in this file.
            guard let mediaType = pending.mediaType, let bucket = pending.bucket else {
                // A row we can no longer parse is unpublishable and would block
                // the queue forever. Drop it rather than retry it every launch.
                library.clearPendingPublish(pending)
                continue
            }
            let sentiment = bucket.sentiment

            let payload = library.publishPayload(mediaType: mediaType, sentiment: sentiment)

            do {
                if payload.isEmptying {
                    // An emptied bucket must be deleted server-side, or an
                    // un-watched title stays visible to followers.
                    try await transport.deleteBucket(
                        mediaType: mediaType, sentiment: sentiment, userID: userID
                    )
                } else {
                    try await transport.publish(payload, userID: userID)
                }
                library.clearPendingPublish(pending)
                drained += 1
            } catch {
                // Leave the row in place. A failed publish must never mutate
                // local state — the ranking is the user's, and the server is a
                // copy of it.
                pending.attempts += 1
            }
        }
        await emitPosts()

        return drained
    }

    // MARK: Posts

    /// **One post per act, never one per changed row — and never fewer.**
    ///
    /// The two halves coalesce differently on purpose. Publishing is per
    /// *bucket*: five rankings rewrite one bucket and owe it one upsert.
    /// Posting is per *act*: five rankings are five things the user did, and
    /// folding them together would drop four of them from every follower's
    /// feed. A single insertion still produces exactly one post, because the
    /// act is one — not because the bucket is.
    private func emitPosts() async {
        guard let feed, !library.pendingPosts.isEmpty else { return }

        for entry in library.pendingPosts {
            guard let item = library.item(withID: entry.itemID),
                  let externalId = item.externalId else { continue }

            try? await feed.createPost(
                kind: entry.kind,
                payload: FeedPost.Payload(
                    externalId: externalId,
                    title: item.title,
                    year: item.year,
                    mediaType: item.type,
                    sentiment: entry.kind == .ranked ? item.sentiment : nil,
                    rankInBucket: entry.kind == .ranked ? item.rankInBucket : nil,
                    bucketSize: entry.kind == .ranked
                        ? library.bucket(for: item.sentiment ?? .liked, type: item.type).count
                        : nil,
                    // The author's own words, which used to be hardcoded `nil`
                    // — so a review written in the app reached the server's
                    // `ranked_items` row and never the feed, and the one part
                    // of a post that is actually *writing* was the one part
                    // followers could not read.
                    //
                    // Not sent for `wantToWatch`: a review of something you
                    // have not watched is not a thing, and a stale one left
                    // over from an earlier ranking would be worse.
                    reviewExcerpt: entry.kind == .wantToWatch
                        ? nil
                        : FeedPost.excerpt(from: item.review),
                    // Stored as TMDB's path rather than the rendered URL the
                    // local row holds — same reason `ranked_items.poster_path`
                    // does it, see `TMDBImage.posterPath`.
                    posterPath: TMDBImage.posterPath(fromURL: item.posterURL)
                )
            )
        }
        library.clearPendingPosts()
    }


}

// MARK: - MockPublishTransport

/// Accepts everything, keeps it in memory, reaches nothing.
///
/// What `-uiTestingMockSocial` publishes into, so the Settings sharing section
/// can be looked at without a server — it only appears once an account exists,
/// which makes it one of the hardest surfaces to see.
final class MockPublishTransport: PublishTransport, @unchecked Sendable {

    private let lock = NSLock()
    private(set) var published: [PublishPayload] = []
    private(set) var deleted: [(mediaType: MediaType, sentiment: Sentiment?)] = []

    init() {}

    func publish(_ payload: PublishPayload, userID: UUID) async throws {
        lock.lock(); published.append(payload); lock.unlock()
    }

    func deleteBucket(mediaType: MediaType, sentiment: Sentiment?, userID: UUID) async throws {
        lock.lock(); deleted.append((mediaType, sentiment)); lock.unlock()
    }

}

// MARK: - SupabasePublishTransport

final class SupabasePublishTransport: PublishTransport, @unchecked Sendable {

    private let client: SupabaseClient
    private let configuration: SupabaseConfiguration

    init(client: SupabaseClient, configuration: SupabaseConfiguration) {
        self.client = client
        self.configuration = configuration
    }

    func publish(_ payload: PublishPayload, userID: UUID) async throws {
        guard !payload.items.isEmpty else { return }

        // **Send only columns `authenticated` may UPDATE.** This is an upsert,
        // so PostgREST turns it into INSERT … ON CONFLICT DO UPDATE SET over
        // every column in the payload — and UPDATE on this table is granted
        // column by column (`20260823010000`). A column in the payload that is
        // not in that grant inserts a bucket's first row happily and then fails
        // 42501 on every later drain that touches an existing one, which is
        // every drain after the first.
        let rows = payload.items.map { Row($0, userID: userID) }

        // The whole bucket in one upsert. `on_conflict` makes a re-run a no-op,
        // which is what lets a half-drained queue simply be replayed.
        try await client.send(
            .init(
                method: "POST",
                url: configuration.rest("ranked_items"),
                query: [URLQueryItem(name: "on_conflict", value: "user_id,media_type,external_id")],
                body: try SupabaseClient.encoder.encode(rows),
                headers: ["Prefer": "resolution=merge-duplicates,return=minimal"]
            )
        )

        // Anything the server still holds for this bucket that is no longer in
        // it — an item that moved sentiment, or was un-watched — must go, or a
        // follower sees a title in two buckets at once.
        let keep = payload.items.map(\.externalId)
        try await deleteBucket(
            mediaType: payload.mediaType, sentiment: payload.sentiment,
            userID: userID, except: keep
        )
    }

    func deleteBucket(mediaType: MediaType, sentiment: Sentiment?, userID: UUID) async throws {
        try await deleteBucket(
            mediaType: mediaType, sentiment: sentiment, userID: userID, except: []
        )
    }

    private func deleteBucket(
        mediaType: MediaType, sentiment: Sentiment?, userID: UUID, except keep: [String]
    ) async throws {
        var query = [
            URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
            URLQueryItem(name: "media_type", value: "eq.\(mediaType.wireValue)"),
            // **`is.null`, never `eq.null`.** SQL comparison with null is null,
            // so `sentiment=eq.null` matches no row and a DELETE built that way
            // silently deletes nothing — the queue would accumulate rows on the
            // server that nothing could ever remove.
            URLQueryItem(
                name: "sentiment",
                value: sentiment.map { "eq.\($0.rawValue)" } ?? "is.null"
            ),
        ]
        if !keep.isEmpty {
            let list = keep.map { "\"\($0)\"" }.joined(separator: ",")
            query.append(URLQueryItem(name: "external_id", value: "not.in.(\(list))"))
        }

        try await client.send(
            .init(
                method: "DELETE",
                url: configuration.rest("ranked_items"),
                query: query,
                headers: ["Prefer": "return=minimal"]
            )
        )
    }

    // MARK: Row

    private struct Row: Encodable {
        let userID: UUID
        let externalId: String
        let mediaType: String
        /// Null together, for a want-to-watch entry.
        let sentiment: String?
        let title: String
        let year: Int
        let score: Double?
        let rankInBucket: Int?
        let bucketSize: Int
        let posterPath: String?
        let review: String?

        init(_ item: PublishedItem, userID: UUID) {
            self.userID = userID
            externalId = item.externalId
            mediaType = item.mediaType
            sentiment = item.sentiment
            title = item.title
            year = item.year
            score = item.score
            rankInBucket = item.rankInBucket
            bucketSize = item.bucketSize
            posterPath = item.posterPath
            review = item.review
        }

        /// **Nulls are sent, not omitted, and that is the whole correctness of
        /// re-queueing a ranked title.**
        ///
        /// This is an upsert — `INSERT … ON CONFLICT DO UPDATE SET` over the
        /// columns *present in the body*. A column left out of the body is left
        /// out of the SET list, so it keeps whatever the server already had.
        /// The synthesised encoder omits nil optionals, which would mean a title
        /// moved from "Liked it" back to the watchlist arriving as an upsert
        /// that says nothing about `sentiment`, `score` or `rank_in_bucket` —
        /// and a server row that keeps its old ranking while the owner's device
        /// says the title is queued. `ranked_or_queued` would not catch it: the
        /// row stays internally consistent, just wrong.
        ///
        /// `posterPath` keeps `encodeIfPresent`, and the asymmetry is
        /// deliberate: a nil poster means "this device does not know the
        /// artwork", not "there is none", so nulling it would discard a good
        /// value the server already holds. `review` is explicit for the
        /// opposite reason — clearing a review has to actually clear it.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(userID, forKey: .userID)
            try container.encode(externalId, forKey: .externalId)
            try container.encode(mediaType, forKey: .mediaType)
            try container.encode(title, forKey: .title)
            try container.encode(year, forKey: .year)
            try container.encode(bucketSize, forKey: .bucketSize)
            try container.encodeIfPresent(posterPath, forKey: .posterPath)

            if let sentiment { try container.encode(sentiment, forKey: .sentiment) }
            else { try container.encodeNil(forKey: .sentiment) }

            if let score { try container.encode(score, forKey: .score) }
            else { try container.encodeNil(forKey: .score) }

            if let rankInBucket { try container.encode(rankInBucket, forKey: .rankInBucket) }
            else { try container.encodeNil(forKey: .rankInBucket) }

            if let review { try container.encode(review, forKey: .review) }
            else { try container.encodeNil(forKey: .review) }
        }

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
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
    }
}
