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
//  **Syncing and publishing are different things, and only one of them is a
//  choice.** A signed-in user's ranking always reaches their own account, so
//  signing in on a new phone restores it — that is what an account is *for*,
//  and gating it on a consent answer would mean the people most careful about
//  their privacy are the only ones with no backup. What consent decides is
//  whether anybody *else* can see those rows: it travels as `is_published` on
//  every row, and row-level security does the rest.
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
    /// **Carries no visibility flag, deliberately.** `is_published` is revoked
    /// from `authenticated` at the column level, so a client cannot write it at
    /// all: new rows inherit their bucket's answer from a trigger, and changing
    /// the answer goes through `setPublished`. A parameter the client could not
    /// honour would be a lie in the signature.
    func publish(_ payload: PublishPayload, userID: UUID) async throws

    /// Removes every server row for a bucket that has emptied.
    ///
    /// **Deletion, not hiding.** Used only when the titles are genuinely gone
    /// from the library — un-watched, re-rated into another bucket. Turning
    /// visibility off goes through `setPublished`, which keeps the rows.
    func deleteBucket(mediaType: MediaType, sentiment: Sentiment, userID: UUID) async throws

    /// Flips visibility on every row this user owns.
    ///
    /// What withdrawing consent does. Deleting the rows instead would destroy
    /// the user's own backup to answer a question about *other people's*
    /// access, which is not what they asked for.
    ///
    /// Also what a *new bucket* needs: the inheritance trigger reads the
    /// bucket's existing rows, and a bucket with none — the first show a
    /// film-only user ranks — has nothing to inherit and lands private. Re-
    /// applying the standing answer after a drain is what stops a consented
    /// user quietly acquiring invisible buckets.
    func setPublished(_ isPublished: Bool, userID: UUID) async throws
}

// MARK: - SyncEngine

/// `@Observable` so the Settings screen can show what is outstanding and what
/// the current answer to consent is, without a second object holding a copy of
/// either.
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
    @ObservationIgnored private let consent: PublishConsent

    private var isDraining = false

    /// The signed-in user's answer: `true` granted, `false` refused, `nil`
    /// never asked. Mirrored from `PublishConsent` rather than read through to
    /// it on every access, because `UserDefaults` is not observable and a
    /// screen showing this has to update when it changes.
    private(set) var consentDecision: Bool?

    init(
        library: MediaLibraryViewModel,
        transport: PublishTransport,
        feed: FeedService? = nil,
        consent: PublishConsent,
        currentUserID: @escaping () -> UUID?
    ) {
        self.library = library
        self.transport = transport
        self.feed = feed
        self.consent = consent
        self.currentUserID = currentUserID
        self.consentDecision = currentUserID().flatMap { consent.decision(for: $0) }
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

    /// Watched titles that *would* go to the server. What the consent sheet
    /// counts, so the question is about a number the user can check rather than
    /// about "your library".
    var publishableCount: Int {
        library.allWatched.filter { $0.externalId != nil }.count
    }

    // MARK: Consent

    /// Re-reads the stored answer for whoever is signed in now.
    ///
    /// Called when the session changes: the answer belongs to an account, so a
    /// different account has a different one — possibly none.
    func refreshConsent() {
        consentDecision = currentUserID().flatMap { consent.decision(for: $0) }
    }

    /// Whether the app owes this user the question — "can followers see this?",
    /// not "may this be uploaded?", which is no longer asked.
    ///
    /// Not asked when there is nothing to show: a brand-new account with an
    /// empty library is offered a decision about nothing, and would be asked
    /// again the moment it mattered anyway. It is asked once the library has
    /// something in it, which is the first moment the answer means anything.
    var needsConsentDecision: Bool {
        currentUserID() != nil && consentDecision == nil && publishableCount > 0
    }

    /// Whether anybody but the owner can see these rows.
    ///
    /// **Not a gate on syncing.** A signed-in user's ranking reaches their own
    /// account either way; this only answers whether it is visible to others.
    var isVisibleToOthers: Bool {
        currentUserID() != nil && consentDecision == true
    }

    /// Records an answer and brings the server in line with it.
    ///
    /// Drains first so anything owed lands carrying the new flag, then flips
    /// whatever was already there. The two overlap by design — the flip is the
    /// only thing that reaches rows published before today's answer.
    ///
    /// - Throws: when the flip does not land. The local answer is saved
    ///   regardless, and the caller is expected to offer a retry rather than
    ///   claim a visibility change that did not happen.
    func record(consent granted: Bool) async throws {
        guard let userID = currentUserID() else { return }
        consent.record(granted, for: userID)
        consentDecision = granted
        await drain()
        try await transport.setPublished(granted, userID: userID)
    }

    /// Re-applies the current answer to the server, for retrying a failed flip.
    ///
    /// **Three things a user might mean by "take it down", and this is the
    /// middle one.** Deleting the account takes the profile, the follows and
    /// the comments. Deleting the *data* would take the backup that signing in
    /// on a new phone restores. Withdrawing consent takes neither: the rows
    /// stay in the owner's account and stop being visible to anybody else.
    func reapplyVisibility() async throws {
        guard let userID = currentUserID() else { return }
        try await transport.setPublished(consentDecision == true, userID: userID)
    }

    /// Forgets this account's answer, so the next sign-in asks again.
    ///
    /// What deleting the account owes — the answer must not outlive the account
    /// it belonged to.
    func forgetConsent() {
        guard let userID = currentUserID() else { return }
        consent.forget(for: userID)
        consentDecision = nil
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

        // A bucket that did not exist before this drain inherited nothing, so it
        // arrived private whatever the user has said. Re-stating the standing
        // answer costs one idempotent call and makes the invariant — the whole
        // library matches the answer — true after every drain rather than only
        // after the answer changes.
        if drained > 0, consentDecision == true {
            try? await transport.setPublished(true, userID: userID)
        }

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
/// What `-uiTestingMockSocial` publishes into, so the consent sheet and the
/// Settings publishing section can be looked at without a server — they are
/// the two surfaces that only appear once an account exists, which makes them
/// the two hardest to see.
final class MockPublishTransport: PublishTransport, @unchecked Sendable {

    private let lock = NSLock()
    private(set) var published: [PublishPayload] = []
    private(set) var deleted: [(mediaType: MediaType, sentiment: Sentiment)] = []
    private(set) var visibility: Bool?

    init() {}

    func publish(_ payload: PublishPayload, userID: UUID) async throws {
        lock.lock(); published.append(payload); lock.unlock()
    }

    func deleteBucket(mediaType: MediaType, sentiment: Sentiment, userID: UUID) async throws {
        lock.lock(); deleted.append((mediaType, sentiment)); lock.unlock()
    }

    func setPublished(_ isPublished: Bool, userID: UUID) async throws {
        lock.lock(); visibility = isPublished; lock.unlock()
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

        // **`is_published` is not in the payload, and must not be.** This is an
        // upsert, so PostgREST turns it into INSERT … ON CONFLICT DO UPDATE SET
        // over every column sent — and `update (is_published)` is revoked from
        // `authenticated`. Including it would insert the first row of a bucket
        // happily and then fail with 42501 on every later drain that touched an
        // existing row, which is every drain after the first.
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

    /// An RPC, not a PATCH.
    ///
    /// A direct `PATCH …?user_id=eq.<id>` setting this column is refused: the
    /// column-level UPDATE privilege is revoked from `authenticated` precisely
    /// so that no client can flip one row and leave a bucket half-visible.
    /// `set_library_published` is the sanctioned way past that, and it takes no
    /// user parameter at all — it authorises on `auth.uid()` alone, so there is
    /// no shape of call that touches somebody else's library.
    func setPublished(_ isPublished: Bool, userID: UUID) async throws {
        _ = try await client.send(
            .init(
                method: "POST",
                url: configuration.rpc("set_library_published"),
                body: try SupabaseClient.encoder.encode(["p_published": isPublished])
            )
        ) as Data
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
