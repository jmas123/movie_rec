//
//  SyncEngine.swift
//  WatchRank
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

import Foundation
import SwiftData

// MARK: - PublishTransport

/// The one thing the engine needs from a server. Narrow, so tests drive it
/// without a network and the app can be signed out without a special case.
protocol PublishTransport: Sendable {
    /// Upserts a whole bucket. Idempotent by contract: the payload is the
    /// complete bucket, so re-running a drained queue changes nothing.
    func publish(_ payload: PublishPayload, userID: UUID) async throws

    /// Removes every server row for a bucket that has emptied.
    func deleteBucket(mediaType: MediaType, sentiment: Sentiment, userID: UUID) async throws
}

// MARK: - SyncEngine

@MainActor
final class SyncEngine {

    private let library: MediaLibraryViewModel
    private let transport: PublishTransport
    /// Optional: signed out, or on a build with no server, posts simply are not
    /// emitted and the publish half still runs.
    private let feed: FeedService?
    /// Signed out, there is nobody to publish for — and the outbox simply keeps
    /// accruing until there is.
    private let currentUserID: () -> UUID?

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

    // MARK: Draining

    /// Publishes every outstanding bucket.
    ///
    /// - Returns: how many buckets drained. Zero is the normal signed-out and
    ///   nothing-to-do answer, not a failure.
    @discardableResult
    func drain() async -> Int {
        guard !isDraining, let userID = currentUserID() else { return 0 }
        isDraining = true
        defer { isDraining = false }

        var drained = 0
        for pending in library.pendingPublishes {
            guard let mediaType = pending.mediaType, let sentiment = pending.sentiment else {
                // A row we can no longer parse is unpublishable and would block
                // the queue forever. Drop it rather than retry it every launch.
                library.clearPendingPublish(pending)
                continue
            }

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
                    reviewExcerpt: nil
                )
            )
        }
        library.clearPendingPosts()
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

    func deleteBucket(mediaType: MediaType, sentiment: Sentiment, userID: UUID) async throws {
        try await deleteBucket(
            mediaType: mediaType, sentiment: sentiment, userID: userID, except: []
        )
    }

    private func deleteBucket(
        mediaType: MediaType, sentiment: Sentiment, userID: UUID, except keep: [String]
    ) async throws {
        var query = [
            URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
            URLQueryItem(name: "media_type", value: "eq.\(mediaType.wireValue)"),
            URLQueryItem(name: "sentiment", value: "eq.\(sentiment.rawValue)"),
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
        let sentiment: String
        let title: String
        let year: Int
        let score: Double
        let rankInBucket: Int
        let bucketSize: Int

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
        }
    }
}
