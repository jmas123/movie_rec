//
//  LibraryMergeTests.swift
//  BingedTests
//
//  `LibraryMerge` is pure, so these need no container, no context and no
//  network — which is the point of it being pure. Everything that can go wrong
//  when a device and an account disagree is reproducible here in three lines.
//
//  See `docs/PART-IV-SYNC.md` §6.3.
//

import Foundation
import Testing

@testable import Binged

@MainActor
@Suite("LibraryMerge")
struct LibraryMergeTests {

    // MARK: Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func local(
        _ externalId: String,
        type: MediaType = .movie,
        sentiment: Sentiment? = .liked,
        rank: Int? = 0,
        rankedAt: Date? = epoch
    ) -> LibraryMerge.LocalItem {
        .init(
            externalId: externalId,
            mediaType: type,
            sentiment: sentiment,
            rankInBucket: rank,
            lastRankedAt: rankedAt
        )
    }

    private func remote(
        _ externalId: String,
        type: MediaType = .movie,
        sentiment: Sentiment? = .liked,
        rank: Int? = 0,
        updatedAt: Date = epoch,
        posterPath: String? = "/poster.jpg"
    ) -> RemoteRankedItem {
        .init(
            externalId: externalId,
            mediaType: type,
            sentiment: sentiment,
            title: "Title",
            year: 2020,
            rankInBucket: rank,
            updatedAt: updatedAt,
            posterPath: posterPath
        )
    }

    private static let epochRef = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Union

    @Test("Nothing is ever lost: both sides survive a merge")
    func mergeIsAUnion() {
        let plan = LibraryMerge.plan(
            local: [local("tmdb:movie:1"), local("tmdb:movie:2")],
            remote: [remote("tmdb:movie:2"), remote("tmdb:movie:3")]
        )

        // 1 is device-only, 2 is on both, 3 is account-only. All three survive.
        #expect(plan.resolutions.count == 3)
        #expect(plan.resolutions.contains(.pushToServer(externalId: "tmdb:movie:1")))
        #expect(plan.resolutions.contains(.alreadyAgreed(externalId: "tmdb:movie:2")))

        let insertsThree = plan.resolutions.contains {
            if case .insertLocally(let item) = $0 { return item.externalId == "tmdb:movie:3" }
            return false
        }
        #expect(insertsThree)
    }

    @Test("A signed-in device with an empty account keeps everything and pushes it")
    func firstSignInPushesEverything() {
        let plan = LibraryMerge.plan(
            local: [local("tmdb:movie:1"), local("tmdb:movie:2")],
            remote: []
        )

        #expect(plan.resolutions.allSatisfy {
            if case .pushToServer = $0 { return true }
            return false
        })
        #expect(plan.resolutions.count == 2)
    }

    @Test("A fresh device with a populated account restores it")
    func freshDeviceRestoresAccount() {
        let plan = LibraryMerge.plan(
            local: [],
            remote: [remote("tmdb:movie:1"), remote("tmdb:tv:9", type: .tvShow)]
        )

        #expect(plan.resolutions.count == 2)
        #expect(plan.resolutions.allSatisfy {
            if case .insertLocally = $0 { return true }
            return false
        })
        // Two types, two buckets, both owed a recompute.
        #expect(plan.bucketsNeedingRecompute.count == 2)
    }

    @Test("A merge of two empty sides does nothing rather than something")
    func emptyMergeIsEmpty() {
        let plan = LibraryMerge.plan(local: [], remote: [])
        #expect(plan.resolutions.isEmpty)
        #expect(plan.bucketsNeedingRecompute.isEmpty)
    }

    // MARK: - Position is not a conflict

    @Test("Disagreeing about position is not a conflict — the recompute settles it")
    func positionDisagreementIsNotAConflict() {
        // Same bucket, different rank. Rule 4 says the user never chose a rank,
        // so there is no decision here to preserve.
        let plan = LibraryMerge.plan(
            local: [local("tmdb:movie:1", rank: 3)],
            remote: [remote("tmdb:movie:1", rank: 7)]
        )

        #expect(plan.resolutions == [.alreadyAgreed(externalId: "tmdb:movie:1")])

        // Still owed a recompute: the other side may be inserting siblings,
        // which moves N for everyone already in the bucket.
        #expect(plan.bucketsNeedingRecompute.contains(
            .init(mediaType: .movie, sentiment: .liked)
        ))
    }

    // MARK: - Sentiment is a conflict

    @Test("The newest deliberate act wins a sentiment disagreement")
    func newerLocalDecisionWins() {
        let older = Self.epochRef
        let newer = older.addingTimeInterval(3600)

        // The device re-rated it an hour after the account last heard anything.
        let plan = LibraryMerge.plan(
            local: [local("tmdb:movie:1", sentiment: .fine, rankedAt: newer)],
            remote: [remote("tmdb:movie:1", sentiment: .liked, updatedAt: older)]
        )

        #expect(plan.resolutions == [
            .resolvedConflict(externalId: "tmdb:movie:1", winner: .local, sentiment: .fine)
        ])
    }

    @Test("A stale device does not overwrite a newer decision on the account")
    func staleLocalDecisionLoses() {
        let older = Self.epochRef
        let newer = older.addingTimeInterval(3600)

        // This is the failure the design brief called out: device A syncing an
        // old opinion over device B's deliberate re-rate.
        let plan = LibraryMerge.plan(
            local: [local("tmdb:movie:1", sentiment: .liked, rankedAt: older)],
            remote: [remote("tmdb:movie:1", sentiment: .fine, updatedAt: newer)]
        )

        #expect(plan.resolutions == [
            .resolvedConflict(externalId: "tmdb:movie:1", winner: .remote, sentiment: .fine)
        ])
    }

    @Test("A local row with no timestamp loses — the stated server-wins fallback")
    func missingTimestampLosesToServer() {
        let plan = LibraryMerge.plan(
            local: [local("tmdb:movie:1", sentiment: .disliked, rankedAt: nil)],
            remote: [remote("tmdb:movie:1", sentiment: .liked)]
        )

        #expect(plan.resolutions == [
            .resolvedConflict(externalId: "tmdb:movie:1", winner: .remote, sentiment: .liked)
        ])
    }

    @Test("A sentiment change recomputes the bucket it left as well as the one it joined")
    func bothSidesOfACrossBucketMoveAreRecomputed() {
        let plan = LibraryMerge.plan(
            local: [local("tmdb:movie:1", sentiment: .fine, rankedAt: Self.epochRef.addingTimeInterval(60))],
            remote: [remote("tmdb:movie:1", sentiment: .liked)]
        )

        // The vacated bucket owes a recompute exactly as much as the joined one
        // — CLAUDE.md rule 4, and the bug class this project has hit before.
        #expect(plan.bucketsNeedingRecompute == [
            .init(mediaType: .movie, sentiment: .fine),
            .init(mediaType: .movie, sentiment: .liked),
        ])
    }

    // MARK: - Buckets

    @Test("Movies and TV are separate buckets even at the same sentiment")
    func typesDoNotShareABucket() {
        let plan = LibraryMerge.plan(
            local: [local("tmdb:movie:1", type: .movie, sentiment: .liked)],
            remote: [remote("tmdb:tv:1", type: .tvShow, sentiment: .liked)]
        )

        #expect(plan.bucketsNeedingRecompute == [
            .init(mediaType: .movie, sentiment: .liked),
            .init(mediaType: .tvShow, sentiment: .liked),
        ])
    }

    @Test("The want-to-watch queue is a bucket, not an absence of one")
    func queueIsItsOwnBucket() {
        let plan = LibraryMerge.plan(
            local: [],
            remote: [remote("tmdb:movie:1", sentiment: nil, rank: nil)]
        )

        #expect(plan.bucketsNeedingRecompute == [
            .init(mediaType: .movie, sentiment: nil)
        ])
    }

    @Test("Moving out of the queue into a sentiment is a conflict like any other")
    func queueToRankedIsAConflict() {
        let plan = LibraryMerge.plan(
            local: [local("tmdb:movie:1", sentiment: .liked, rankedAt: Self.epochRef.addingTimeInterval(60))],
            remote: [remote("tmdb:movie:1", sentiment: nil, rank: nil)]
        )

        #expect(plan.resolutions == [
            .resolvedConflict(externalId: "tmdb:movie:1", winner: .local, sentiment: .liked)
        ])
        #expect(plan.bucketsNeedingRecompute.contains(.init(mediaType: .movie, sentiment: nil)))
    }

    // MARK: - Determinism and honesty

    @Test("The same input produces the same plan, every time")
    func planIsDeterministic() {
        let localItems = [local("tmdb:movie:3"), local("tmdb:movie:1"), local("tmdb:movie:2")]
        let remoteItems = [remote("tmdb:movie:2"), remote("tmdb:movie:9")]

        let first = LibraryMerge.plan(local: localItems, remote: remoteItems)
        let second = LibraryMerge.plan(local: localItems.reversed(), remote: remoteItems.reversed())

        // Order of the inputs must not change the outcome — the failure mode is
        // "the merge did something different the second time".
        #expect(first == second)
    }

    @Test("Titles the account can never hold are counted, not dropped")
    func unsyncableTitlesAreCounted() {
        // A title with a nil externalId cannot appear in `local` at all, so the
        // caller supplies the count. It exists so the UI can say "3 titles stay
        // on this device" rather than leaving a silent gap on the next device.
        let plan = LibraryMerge.plan(
            local: [local("tmdb:movie:1")],
            remote: [],
            unsyncableCount: 3
        )

        #expect(plan.unsyncableCount == 3)
    }
}
