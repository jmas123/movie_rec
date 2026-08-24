//
//  LibraryMerge.swift
//  Binged
//
//  Reconciles a device's library with the account's copy of it.
//
//  Pure, for the reason `RankingEngine` is pure: every interesting failure here
//  is a decision about two disagreeing records, and none of them need a server
//  to reproduce. No `URLSession`, no `ModelContext`, no `MediaItem` — the caller
//  hands over plain values and receives a plan it can apply.
//
//  **This type never computes a score.** It resolves *positions*, and the caller
//  recomputes every affected bucket afterwards through the shared recompute.
//  Two reasons, and both are load-bearing:
//
//  1. Merging changes N. A bucket whose size moved without a recompute leaves
//     survivors holding scores computed for the old N — the vacated-bucket bug
//     with a network in the middle.
//  2. Part III invariant 1: the server never computes a score. If the remote
//     `score` were written into the store, it would have.
//
//  See `docs/PART-IV-SYNC.md` §6.
//

import Foundation

// MARK: - RemoteRankedItem

/// One row of `ranked_items` as the account holds it.
///
/// `updatedAt` is the server's own clock, maintained by the `ranked_items_touch`
/// trigger — not a value the client sends, and so not one a stale device can
/// backdate.
struct RemoteRankedItem: Equatable, Sendable {

    let externalId: String
    let mediaType: MediaType
    /// `nil` for a want-to-watch entry. The queue is a bucket like any other.
    let sentiment: Sentiment?
    let title: String
    let year: Int
    let rankInBucket: Int?
    let updatedAt: Date

    /// Deliberately absent: `score`. See this file's header.
}

// MARK: - LibraryMerge

enum LibraryMerge {

    // MARK: Input

    /// The device's side, reduced to what a merge actually reasons about.
    ///
    /// A struct rather than a `MediaItem` so the merge stays testable without a
    /// `ModelContainer`, and so it cannot accidentally read a field it has no
    /// business resolving.
    struct LocalItem: Equatable, Sendable {
        let externalId: String
        let mediaType: MediaType
        let sentiment: Sentiment?
        let rankInBucket: Int?
        /// When the user last made a *deliberate* ranking decision about this
        /// title — marking it watched, finishing a comparison session, or
        /// changing its sentiment.
        ///
        /// Explicitly **not** `dateWatched`, which records when they saw the
        /// film. Re-rating a 2019 film does not move 2019, so `dateWatched`
        /// cannot order two disagreeing decisions.
        ///
        /// `nil` for rows written before the property existed. Such a row loses
        /// to the server, which is the stated "server wins ties" fallback.
        let lastRankedAt: Date?
    }

    // MARK: Output

    /// What the caller should do with one title.
    enum Resolution: Equatable, Sendable {

        /// Only the account knows it. Insert locally.
        case insertLocally(RemoteRankedItem)

        /// Only the device knows it. Keep, and mark its bucket dirty so it
        /// pushes on the next drain.
        case pushToServer(externalId: String)

        /// Both agree on which bucket it belongs in. Nothing to reconcile —
        /// position differences inside a bucket are settled by the recompute,
        /// not here.
        case alreadyAgreed(externalId: String)

        /// Both know it and they disagree about *which bucket*, which is a
        /// disagreement about something the user chose. Carries the winner.
        case resolvedConflict(externalId: String, winner: Side, sentiment: Sentiment?)

        enum Side: Equatable, Sendable { case local, remote }
    }

    struct Plan: Equatable, Sendable {

        var resolutions: [Resolution] = []

        /// Every `(type, sentiment)` bucket the plan disturbs. The caller owes
        /// each of these a recompute — including buckets an item *left*, which
        /// is the half that is easy to forget and is exactly the vacated-bucket
        /// bug.
        var bucketsNeedingRecompute: Set<BucketKey> = []

        /// Titles the device holds that can never reach the account, because the
        /// catalog gave them no id. Counted, never dropped silently: the UI owes
        /// the user "3 titles stay on this device" rather than a quiet gap when
        /// they sign in elsewhere.
        var unsyncableCount: Int = 0
    }

    struct BucketKey: Hashable, Sendable {
        let mediaType: MediaType
        let sentiment: Sentiment?
    }

    // MARK: Merge

    /// Reconciles the two sides.
    ///
    /// - Parameters:
    ///   - local: every item on the device, including ones with no `externalId`.
    ///   - remote: every row the account holds for this user.
    /// - Returns: a plan. Applying it is the caller's job; deciding is this
    ///   function's, and it decides the same way every time for the same input.
    static func plan(local: [LocalItem], remote: [RemoteRankedItem]) -> Plan {
        var plan = Plan()

        // Identity is `externalId`, already namespaced by type (`tmdb:movie:27205`),
        // so a film and a series sharing a TMDB number cannot collide.
        let localByID = Dictionary(local.map { ($0.externalId, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.map { ($0.externalId, $0) }, uniquingKeysWith: { first, _ in first })

        // Sorted so a plan is deterministic — worth having when the failure mode
        // is "the merge did something different the second time".
        for externalId in Set(localByID.keys).union(remoteByID.keys).sorted() {
            switch (localByID[externalId], remoteByID[externalId]) {

            case let (.some(localItem), .none):
                plan.resolutions.append(.pushToServer(externalId: externalId))
                plan.bucketsNeedingRecompute.insert(
                    BucketKey(mediaType: localItem.mediaType, sentiment: localItem.sentiment)
                )

            case let (.none, .some(remoteItem)):
                plan.resolutions.append(.insertLocally(remoteItem))
                plan.bucketsNeedingRecompute.insert(
                    BucketKey(mediaType: remoteItem.mediaType, sentiment: remoteItem.sentiment)
                )

            case let (.some(localItem), .some(remoteItem)):
                plan.merge(localItem, remoteItem, externalId: externalId)

            case (.none, .none):
                continue // unreachable: the id came from one of the two maps
            }
        }

        // `unsyncableCount` stays at its default here. A title with a nil
        // `externalId` cannot appear in `local` at all — the array is keyed by
        // that id — so this function has no way to count them. The overload
        // below takes the count from the caller, which does.
        return plan
    }

    /// `plan(local:remote:)` plus the count of device-only titles the account can
    /// never hold, which the caller knows and this function does not — a title
    /// with a nil `externalId` cannot appear in `local` at all, since `local` is
    /// keyed by that id.
    static func plan(
        local: [LocalItem],
        remote: [RemoteRankedItem],
        unsyncableCount: Int
    ) -> Plan {
        var result = plan(local: local, remote: remote)
        result.unsyncableCount = unsyncableCount
        return result
    }
}

// MARK: - Conflict resolution

private extension LibraryMerge.Plan {

    /// Both sides know this title. Decide what, if anything, disagrees.
    ///
    /// **Position differences are not conflicts.** A rank is derived — the user
    /// answered comparisons and the engine computed a number; they never chose
    /// "fourth". Two devices that agree a film is Liked but disagree whether it
    /// sits third or fourth have no disagreement worth preserving, and the
    /// recompute settles it. Treating that as a conflict would ask the user
    /// about a value ranking rule 4 says they never enter.
    ///
    /// **Sentiment differences are conflicts.** Liked versus Fine is a thing the
    /// user chose, twice, differently. The newest deliberate act wins, measured
    /// by the device's `lastRankedAt` against the server's `updatedAt`.
    mutating func merge(
        _ local: LibraryMerge.LocalItem,
        _ remote: RemoteRankedItem,
        externalId: String
    ) {
        guard local.sentiment != remote.sentiment else {
            resolutions.append(.alreadyAgreed(externalId: externalId))
            // Still a recompute: the other side may be inserting siblings into
            // this bucket, which moves N for everyone already in it.
            bucketsNeedingRecompute.insert(
                .init(mediaType: remote.mediaType, sentiment: remote.sentiment)
            )
            return
        }

        // A local row with no `lastRankedAt` predates the property and cannot
        // argue its case. It loses, which is the stated server-wins fallback.
        let winner: LibraryMerge.Resolution.Side = {
            guard let lastRankedAt = local.lastRankedAt else { return .remote }
            return lastRankedAt > remote.updatedAt ? .local : .remote
        }()

        let sentiment = winner == .local ? local.sentiment : remote.sentiment
        resolutions.append(
            .resolvedConflict(externalId: externalId, winner: winner, sentiment: sentiment)
        )

        // BOTH buckets, always. The title lands in one and vacates the other,
        // and the bucket it left owes a recompute exactly as much as the one it
        // joined — see CLAUDE.md ranking rule 4.
        bucketsNeedingRecompute.insert(
            .init(mediaType: local.mediaType, sentiment: local.sentiment)
        )
        bucketsNeedingRecompute.insert(
            .init(mediaType: remote.mediaType, sentiment: remote.sentiment)
        )
    }
}
