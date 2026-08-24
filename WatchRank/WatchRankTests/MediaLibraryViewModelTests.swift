//
//  MediaLibraryViewModelTests.swift
//  WatchRankTests
//
//  Exercises `MediaLibraryViewModel` against an in-memory SwiftData container.
//  The view model is the integration seam between the pure `RankingEngine` and
//  persistence, so these tests focus on:
//    - the comparison session counting the right number of pairs (binary
//      insertion sort bound, matches `RankingEngineTests.insertionIsLogarithmic`)
//    - scores landing where `RankingEngine.recomputeScores` would put them
//    - reorder + cross-bucket moves recomputing both affected buckets
//

import Foundation
import Observation
import SwiftData
import Testing
@testable import WatchRank

// MARK: - Tests

@MainActor
@Suite("MediaLibraryViewModel")
struct MediaLibraryViewModelTests {

    // MARK: empty-bucket placement

    @Test("Marking watched into an empty bucket skips comparison and sets midpoint")
    func emptyBucketSkipsComparisonAndSetsMidpoint() throws {
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)

        let solo = makeItem("Solo")
        let pairs = vm.markWatched(solo, sentiment: .liked)

        #expect(pairs.isEmpty)
        #expect(vm.pendingComparison == nil)
        #expect(solo.watchedStatus == .watched)
        #expect(solo.sentiment == .liked)

        let range = Sentiment.liked.scoreRange
        let midpoint = (range.lowerBound + range.upperBound) / 2.0
        #expect(solo.score == midpoint)
        #expect(solo.rankInBucket == 0)
    }

    // MARK: reads are observable

    @Test("Reading a bucket registers an observation that a mutation fires")
    func bucketReadIsObservable() throws {
        // The bucket lives in SwiftData, which `@Observable` can't see through
        // a fetch. Without the `revision` dependency, SwiftUI would render the
        // Ranking and Home screens once and never redraw them.
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)
        let flag = ChangeFlag()

        withObservationTracking {
            _ = vm.bucket(for: .liked, type: .movie)
        } onChange: {
            flag.mark()
        }

        let item = makeItem("Solo")
        vm.markWatched(item, sentiment: .liked)
        vm.finalizeRanking(for: item)

        #expect(flag.fired)
    }

    // MARK: pair count == binary insertion bound

    @Test(
        "Marking watched costs at most ceil(log2(N+1)) comparisons",
        arguments: [1, 2, 3, 4, 7, 8, 15]
    )
    func markWatchedComparisonCountMatchesBinaryInsertion(bucketSize: Int) throws {
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)

        seedLikedBucket(vm: vm, count: bucketSize)
        let candidate = makeItem("Candidate")
        let initial = vm.markWatched(candidate, sentiment: .liked)

        // markWatched returns a single-element array with the first pair when
        // the target bucket is non-empty.
        #expect(initial.count == 1)
        #expect(initial.first?.totalSteps == ceilLog2(bucketSize + 1))

        let stepsWalked = driveSessionPreferringExisting(vm: vm)
        vm.finalizeRanking(for: candidate)

        // The advertised total is the worst case; always preferring the
        // existing item sinks the candidate down the right half, which lands
        // on `lo == hi` early whenever the bucket isn't one short of a power
        // of two (N = 4 finishes in 2 taps, not 3).
        #expect(stepsWalked >= 1)
        #expect(stepsWalked <= ceilLog2(bucketSize + 1))
        #expect(vm.pendingComparison == nil)
    }

    // MARK: finalize → scores match RankingEngine.recomputeScores

    @Test("After finalize, bucket scores equal RankingEngine.recomputeScores output")
    func scoresAfterFinalizeMatchEngine() throws {
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)

        // Seed three items, then insert a fourth.
        seedLikedBucket(vm: vm, count: 3)
        let candidate = makeItem("Candidate")
        vm.markWatched(candidate, sentiment: .liked)
        driveSessionPreferringExisting(vm: vm)
        vm.finalizeRanking(for: candidate)

        let bucket = vm.bucket(for: .liked, type: .movie)
        #expect(bucket.count == 4)

        // Replay RankingEngine.recomputeScores onto a parallel array and
        // compare. Position-based, so the only thing that needs to match is
        // the *count*, not which item lands where.
        let engine = RankingEngine()
        let expected: [MediaItem] = (0..<4).map { i in
            makeItem("Expected \(i)")
        }
        engine.recomputeScores(in: expected, range: Sentiment.liked.scoreRange)

        for (actual, want) in zip(bucket, expected) {
            #expect(actual.score == want.score)
            #expect(actual.rankInBucket == want.rankInBucket)
        }
    }

    // MARK: drag-to-reorder updates scores

    @Test("Reorder swaps positions and recomputes scores in place")
    func reorderUpdatesScores() throws {
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)

        let seeded = seedLikedBucket(vm: vm, count: 4)
        let originalTopID = seeded[0].id
        let originalScore0 = vm.bucket(for: .liked, type: .movie)[0].score
        let originalScore3 = vm.bucket(for: .liked, type: .movie)[3].score

        // Move the top item to the bottom of the bucket.
        vm.reorder(in: .liked, type: .movie, from: IndexSet(integer: 0), to: 4)
        let after = vm.bucket(for: .liked, type: .movie)

        #expect(after.last?.id == originalTopID)
        #expect(after.last?.score == originalScore3)
        // The new top item should now hold what used to be the top score.
        #expect(after.first?.score == originalScore0)

        // All ranks contiguous from 0..<count.
        for (i, item) in after.enumerated() {
            #expect(item.rankInBucket == i)
        }
    }

    // MARK: home rails

    @Test("topMovies is score-descending and capped at 10; topShows stays empty")
    func topMoviesSortedAndCapped() throws {
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)

        for i in 0..<12 {
            let movie = makeItem("Movie \(i)", type: .movie)
            vm.markWatched(movie, sentiment: .liked)
            driveSessionPreferringExisting(vm: vm)
            vm.finalizeRanking(for: movie)
        }

        let movies = vm.topMovies
        #expect(movies.count == 10) // capped
        for i in 1..<movies.count {
            #expect((movies[i - 1].score ?? 0) >= (movies[i].score ?? 0))
        }
        #expect(vm.topShows.isEmpty)
    }

    @Test("wantToWatch lists queued items (capped at 5) and excludes watched ones")
    func wantToWatchRail() throws {
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)

        for i in 0..<6 { vm.addToWantToWatch(makeItem("Queued \(i)")) }
        #expect(vm.wantToWatch.count == 5) // capped

        let watched = makeItem("Watched")
        vm.markWatched(watched, sentiment: .liked)
        #expect(!vm.wantToWatch.contains { $0.id == watched.id })
    }

    @Test("recentlyWatched contains only watched items, capped at 5")
    func recentlyWatchedRail() throws {
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)

        for i in 0..<6 {
            let item = makeItem("Watched \(i)")
            vm.markWatched(item, sentiment: .liked)
            driveSessionPreferringExisting(vm: vm)
            vm.finalizeRanking(for: item)
        }
        vm.addToWantToWatch(makeItem("Queued"))

        let recent = vm.recentlyWatched
        #expect(recent.count == 5) // capped
        #expect(recent.allSatisfy { $0.watchedStatus == .watched })
    }

    // MARK: review editing

    @Test("updateReview persists trimmed text and clears on empty input")
    func updateReviewPersistsAndClears() throws {
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)

        let item = makeItem("Reviewed")
        vm.markWatched(item, sentiment: .liked)

        vm.updateReview(item, to: "  Loved it.  ")
        #expect(item.review == "Loved it.") // trimmed

        vm.updateReview(item, to: "   ")
        #expect(item.review == nil) // whitespace-only clears
    }

    // MARK: cross-bucket move

    @Test("Re-rating via markWatched recomputes the bucket the item left")
    func reRatingRecomputesVacatedBucket() throws {
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)

        // Three items in liked. This is the path the Detail screen's "Change
        // Rating" button actually takes.
        let liked = seedLikedBucket(vm: vm, count: 3)
        let mover = liked[1] // the middle one

        // Re-rate the middle item down to `fine`, walking its new session to
        // completion the way the Compare modal would.
        vm.markWatched(mover, sentiment: .fine)
        driveSessionPreferringExisting(vm: vm)
        vm.finalizeRanking(for: mover)

        let remainingLiked = vm.bucket(for: .liked, type: .movie)
        #expect(remainingLiked.count == 2)
        #expect(!remainingLiked.contains { $0.id == mover.id })
        #expect(mover.sentiment == .fine)

        // The bucket it left must be renumbered 0..<2 with no gap, and its
        // scores must match what recomputeScores would produce for N = 2 —
        // not the stale N = 3 values.
        let range = Sentiment.liked.scoreRange
        let span = range.upperBound - range.lowerBound
        for (i, item) in remainingLiked.enumerated() {
            #expect(item.rankInBucket == i)
            let expected = range.upperBound - ((Double(i) + 0.5) / 2.0) * span
            #expect(abs((item.score ?? .nan) - expected) < 0.0001)
        }
    }

    // MARK: identity / dedupe

    @Test("The same catalog entry searched twice resolves to one library item")
    func canonicalItemDedupesByExternalId() throws {
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)

        // Two distinct objects for one catalog entry — exactly what a
        // MediaService hands back when the same title is searched twice.
        let firstHit = MediaItem(
            externalId: "tt0111161",
            title: "The Shawshank Redemption",
            year: 1994,
            type: .movie
        )
        let secondHit = MediaItem(
            externalId: "tt0111161",
            title: "The Shawshank Redemption",
            year: 1994,
            type: .movie
        )
        #expect(firstHit.id != secondHit.id) // different objects, same film

        vm.markWatched(firstHit, sentiment: .liked) // empty bucket → finalizes

        // The second hit must resolve to the copy already in the library.
        let resolved = vm.canonicalItem(for: secondHit)
        #expect(resolved.id == firstHit.id)

        // Re-ranking it must not insert a duplicate, and must not offer a
        // comparison of the film against itself.
        let pairs = vm.markWatched(resolved, sentiment: .liked)
        #expect(pairs.isEmpty, "must not compare the item against itself")
        #expect(vm.bucket(for: .liked, type: .movie).count == 1, "duplicate row was inserted")
    }

    @Test("Items without an externalId are never merged")
    func canonicalItemKeepsUnidentifiedItemsDistinct() throws {
        let context = try makeContext()
        let vm = MediaLibraryViewModel(modelContext: context)

        // Same title and year, no catalog id: must stay two separate entries,
        // since merging on metadata alone could destroy a real distinction.
        let handMade = makeItem("Untitled")
        let other = makeItem("Untitled")
        vm.markWatched(handMade, sentiment: .liked)

        #expect(vm.canonicalItem(for: other).id == other.id)
    }

    // MARK: - Demotion back to the queue

    @Test("Demoting a ranked item to Want to Watch recomputes the bucket it left")
    func demotingToWantToWatchRecomputesVacatedBucket() throws {
        // Same shape as `reRatingRecomputesVacatedBucket`, but through the other
        // door: MediaDetailView's "Want to Watch" button on an already-ranked
        // item. Any write that takes an item *out* of a bucket owes that bucket
        // a recompute, or the survivors keep scores computed for the old N.
        let vm = try makeLibrary()
        let liked = seedLikedBucket(vm: vm, count: 3)
        let demoted = liked[1] // the middle one, so a gap is unmistakable

        vm.addToWantToWatch(demoted)

        #expect(demoted.watchedStatus == .wantToWatch)
        #expect(demoted.sentiment == nil)
        #expect(demoted.score == nil)
        #expect(demoted.rankInBucket == nil)

        let remaining = vm.bucket(for: .liked, type: .movie)
        #expect(!remaining.contains { $0.id == demoted.id })
        expectBucketWellFormed(remaining, sentiment: .liked, count: 2)
    }

    @Test("Demoting the only ranked item leaves an empty, consistent bucket")
    func demotingLastItemEmptiesBucket() throws {
        let vm = try makeLibrary()
        let solo = makeItem("Solo")
        vm.markWatched(solo, sentiment: .liked)

        vm.addToWantToWatch(solo)

        #expect(vm.bucket(for: .liked, type: .movie).isEmpty)
        #expect(vm.wantToWatch.contains { $0.id == solo.id })
    }

    // MARK: - Sessions that never finish

    @Test("An item marked watched is never left watched-but-unscored")
    func markWatchedNeverStrandsAnItem() throws {
        // Reachable in the app: confirm a sentiment, then navigate back out of
        // MediaDetailView before the Compare sheet's onDismiss runs. The session
        // is in-memory and dies with the screen, but the item stays watched.
        let vm = try makeLibrary()
        seedLikedBucket(vm: vm, count: 3)

        let candidate = makeItem("Abandoned")
        vm.markWatched(candidate, sentiment: .liked)
        // Deliberately no comparisons answered and no finalize.

        expectNoStrandedItems(vm)
        expectBucketWellFormed(vm.bucket(for: .liked, type: .movie), sentiment: .liked, count: 4)
    }

    @Test("Starting a second ranking session does not strand the first item")
    func secondSessionDoesNotStrandTheFirst() throws {
        let vm = try makeLibrary()
        seedLikedBucket(vm: vm, count: 3)

        let first = makeItem("First")
        vm.markWatched(first, sentiment: .liked)

        let second = makeItem("Second")
        vm.markWatched(second, sentiment: .liked)
        driveSessionPreferringExisting(vm: vm)
        vm.finalizeRanking(for: second)

        expectNoStrandedItems(vm)
        expectBucketWellFormed(vm.bucket(for: .liked, type: .movie), sentiment: .liked, count: 5)
    }

    @Test(
        "Cancelling at any point in any session leaves a well-formed bucket",
        arguments: [1, 2, 3, 4, 5, 6, 7, 8], [0, 1, 2, 3]
    )
    func cancelMidSessionAlwaysLandsInBucket(bucketSize: Int, answered: Int) throws {
        // Existing coverage only cancels at step 0. A user who answers two of
        // four comparisons and then swipes the sheet away exercises a different
        // `lo`/`hi` state each time.
        let vm = try makeLibrary()
        seedLikedBucket(vm: vm, count: bucketSize)

        let candidate = makeItem("Candidate")
        vm.markWatched(candidate, sentiment: .liked)
        let stepsTaken = driveSession(vm: vm, steps: answered)

        vm.cancelRanking(for: candidate)

        #expect(vm.pendingComparison == nil)
        let bucket = vm.bucket(for: .liked, type: .movie)
        #expect(bucket.contains { $0.id == candidate.id })
        expectBucketWellFormed(
            bucket,
            sentiment: .liked,
            count: bucketSize + 1,
            "cancelled after \(stepsTaken) of \(ceilLog2(bucketSize + 1)) comparisons"
        )
    }

    @Test("Cancelling a session that already resolved is a no-op")
    func cancelAfterResolutionKeepsEarnedPosition() throws {
        // MediaDetailView calls cancelRanking on *every* compare-sheet dismissal,
        // including a successful one. Correctness depends entirely on
        // finalizeRanking having already torn the session down.
        let vm = try makeLibrary()
        seedLikedBucket(vm: vm, count: 3)

        let candidate = makeItem("Candidate")
        vm.markWatched(candidate, sentiment: .liked)
        driveSessionPreferringNew(vm: vm) // floats it to the top
        vm.finalizeRanking(for: candidate)
        #expect(candidate.rankInBucket == 0)

        vm.cancelRanking(for: candidate)

        #expect(candidate.rankInBucket == 0, "cancel demoted an item that had already been placed")
        expectBucketWellFormed(vm.bucket(for: .liked, type: .movie), sentiment: .liked, count: 4)
    }

    // MARK: - Robustness against stale UI events

    @Test("A comparison choice for items outside the session is ignored")
    func staleComparisonChoiceIsIgnored() throws {
        // The one branch the whole suite never reached. Models a double-tap on
        // the Compare screen: the second tap carries the pair that was on
        // screen a moment ago.
        let vm = try makeLibrary()
        seedLikedBucket(vm: vm, count: 7)

        let candidate = makeItem("Candidate")
        vm.markWatched(candidate, sentiment: .liked)
        let before = try #require(vm.pendingComparison)

        let strangerA = makeItem("Stranger A")
        let strangerB = makeItem("Stranger B")
        vm.applyComparisonChoice(winner: strangerA, loser: strangerB)

        let after = try #require(vm.pendingComparison)
        #expect(after.step == before.step, "a stale event advanced the session")
        #expect(after.existingItem.id == before.existingItem.id)
        #expect(after.totalSteps == before.totalSteps)
    }

    @Test("A choice naming the right items in the wrong roles is ignored")
    func comparisonChoiceWithUnrelatedLoserIsIgnored() throws {
        let vm = try makeLibrary()
        seedLikedBucket(vm: vm, count: 7)

        let candidate = makeItem("Candidate")
        vm.markWatched(candidate, sentiment: .liked)
        let before = try #require(vm.pendingComparison)

        // Winner is genuinely in the pair; loser is not.
        vm.applyComparisonChoice(winner: before.newItem, loser: makeItem("Nobody"))

        let after = try #require(vm.pendingComparison)
        #expect(after.step == before.step)
        #expect(after.existingItem.id == before.existingItem.id)
    }

    @Test("Finalizing a different item leaves the live session untouched")
    func finalizeForWrongItemIsIgnored() throws {
        let vm = try makeLibrary()
        seedLikedBucket(vm: vm, count: 3)

        let candidate = makeItem("Candidate")
        vm.markWatched(candidate, sentiment: .liked)
        let before = try #require(vm.pendingComparison)

        vm.finalizeRanking(for: makeItem("Somebody Else"))

        let after = try #require(vm.pendingComparison, "the live session was torn down")
        #expect(after.step == before.step)
    }

    // MARK: - Re-rating inside the same bucket

    @Test("Re-rating into the same bucket leaves it contiguous")
    func reRatingIntoSameBucketKeepsBucketContiguous() throws {
        // markWatched skips the vacated-bucket recompute when the sentiment is
        // unchanged, so the item carries a stale rankInBucket through its own
        // session. The bucket still has to come out right.
        let vm = try makeLibrary()
        let liked = seedLikedBucket(vm: vm, count: 4)
        let mover = liked[3] // currently at the top

        vm.markWatched(mover, sentiment: .liked)
        driveSessionPreferringExisting(vm: vm) // send it to the bottom
        vm.finalizeRanking(for: mover)

        let bucket = vm.bucket(for: .liked, type: .movie)
        expectBucketWellFormed(bucket, sentiment: .liked, count: 4)
        #expect(bucket.last?.id == mover.id)
        #expect(bucket.filter { $0.id == mover.id }.count == 1, "re-rating duplicated the item")
    }

    // MARK: - Spec invariants

    @Test("The three sentiment ranges partition the 0–10 scale in order")
    func sentimentRangesArePartitioned() {
        // Locks the table in CLAUDE.md. If someone widens a range, every score
        // in the store silently changes meaning.
        let disliked = Sentiment.disliked.scoreRange
        let fine = Sentiment.fine.scoreRange
        let liked = Sentiment.liked.scoreRange

        #expect(disliked.upperBound < fine.lowerBound)
        #expect(fine.upperBound < liked.lowerBound)
        #expect(disliked.lowerBound == 0.0)
        #expect(liked.upperBound == 10.0)

        for sentiment in Sentiment.allCases {
            let range = sentiment.scoreRange
            #expect(range.lowerBound < range.upperBound)
        }
    }

    @Test("Every score the library produces lands strictly inside its bucket range")
    func everyScoreStaysInsideItsRange() throws {
        let vm = try makeLibrary()
        for sentiment in Sentiment.allCases {
            seedBucket(vm: vm, sentiment: sentiment, count: 5, titlePrefix: "\(sentiment)")
            expectBucketWellFormed(vm.bucket(for: sentiment, type: .movie), sentiment: sentiment, count: 5)
        }
        expectNoStrandedItems(vm)
    }

    // MARK: media-type separation

    @Test("A show is never compared against a film")
    func buckentsAreScopedByMediaType() throws {
        let vm = try makeLibrary()

        // Three films already ranked as "Liked it".
        for i in 0..<3 {
            let film = makeItem("Film \(i)", type: .movie)
            vm.markWatched(film, sentiment: .liked)
            driveSessionPreferringExisting(vm: vm)
            vm.finalizeRanking(for: film)
        }

        // The first show into "Liked it" meets an empty bucket of its own kind,
        // so it must be placed with no comparisons at all — never measured
        // against the films.
        let show = makeItem("Show A", type: .tvShow)
        let pairs = vm.markWatched(show, sentiment: .liked)
        #expect(pairs.isEmpty, "a show was compared against films")
        #expect(vm.pendingComparison == nil)

        // A second show does compare — but only ever against the first show.
        let second = makeItem("Show B", type: .tvShow)
        vm.markWatched(second, sentiment: .liked)
        var offered: [MediaItem] = []
        while let pair = vm.pendingComparison {
            offered.append(pair.existingItem)
            vm.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
        }
        vm.finalizeRanking(for: second)
        #expect(!offered.isEmpty, "expected at least one comparison")
        #expect(offered.allSatisfy { $0.type == .tvShow }, "a film was offered to a show")

        // Each type keeps its own contiguous ranks and its own score band.
        expectBucketWellFormed(vm.bucket(for: .liked, type: .movie), sentiment: .liked, count: 3)
        expectBucketWellFormed(vm.bucket(for: .liked, type: .tvShow), sentiment: .liked, count: 2)
    }

    @Test("Each media type ranks from #1 independently")
    func eachTypeHasItsOwnTopSpot() throws {
        let vm = try makeLibrary()
        let film = makeItem("Solo Film", type: .movie)
        let show = makeItem("Solo Show", type: .tvShow)
        vm.markWatched(film, sentiment: .liked)
        vm.markWatched(show, sentiment: .liked)

        // Both are #1 of their own bucket, and both sit at the band midpoint.
        #expect(film.rankInBucket == 0)
        #expect(show.rankInBucket == 0)
        #expect(film.score == show.score)
    }

    // MARK: score visibility

    @Test("A score stays hidden until its bucket holds five items")
    func scoreIsWithheldUntilBucketEarnsIt() throws {
        let vm = try makeLibrary()
        var ranked: [MediaItem] = []

        for n in 1...MediaLibraryViewModel.minimumBucketSizeForScore {
            let film = makeItem("Film \(n)", type: .movie)
            vm.markWatched(film, sentiment: .liked)
            driveSessionPreferringExisting(vm: vm)
            vm.finalizeRanking(for: film)
            ranked.append(film)

            let expectedRemaining = MediaLibraryViewModel.minimumBucketSizeForScore - n
            for item in ranked {
                // The score is always computed and stored ...
                #expect(item.score != nil)
                // ... but only surfaced once the bucket is big enough.
                if n < MediaLibraryViewModel.minimumBucketSizeForScore {
                    #expect(vm.displayScore(for: item) == nil)
                    #expect(vm.itemsUntilScoreRevealed(for: item) == expectedRemaining)
                } else {
                    #expect(vm.displayScore(for: item) == item.score)
                    #expect(vm.itemsUntilScoreRevealed(for: item) == 0)
                }
            }
        }
    }

    @Test("Each media type reaches the score threshold on its own")
    func scoreThresholdIsPerMediaType() throws {
        let vm = try makeLibrary()

        // Five films: the film bucket earns its numbers.
        for n in 1...5 {
            let film = makeItem("Film \(n)", type: .movie)
            vm.markWatched(film, sentiment: .liked)
            driveSessionPreferringExisting(vm: vm)
            vm.finalizeRanking(for: film)
        }
        // One show: its own bucket is nowhere near, so no number for it.
        let show = makeItem("Show A", type: .tvShow)
        vm.markWatched(show, sentiment: .liked)

        #expect(vm.displayScore(for: vm.bucket(for: .liked, type: .movie)[0]) != nil)
        #expect(vm.displayScore(for: show) == nil)
        #expect(vm.itemsUntilScoreRevealed(for: show) == 4)
    }

    @Test("A row shows a position while its bucket has not earned a number")
    func scoreDisplayFallsBackToPosition() throws {
        let vm = try makeLibrary()
        var ranked: [MediaItem] = []

        for n in 1...MediaLibraryViewModel.minimumBucketSizeForScore {
            let film = makeItem("Film \(n)", type: .movie)
            vm.markWatched(film, sentiment: .liked)
            driveSessionPreferringExisting(vm: vm)
            vm.finalizeRanking(for: film)
            ranked.append(film)
        }

        // Full bucket: every row is entitled to its number.
        for item in ranked {
            let score = try #require(item.score)
            #expect(vm.scoreDisplay(for: item) == .score(score))
        }

        // Under the threshold a row must still say something. The bug this
        // guards is silence — a ranked title rendering exactly like an
        // unwatched search result.
        let vm2 = try makeLibrary()
        let first = makeItem("First", type: .movie)
        vm2.markWatched(first, sentiment: .liked)
        driveSessionPreferringExisting(vm: vm2)
        vm2.finalizeRanking(for: first)

        // Alone in the bucket: never compared, so not even a position is earned.
        #expect(vm2.scoreDisplay(for: first) == .sentimentOnly(.liked))

        let second = makeItem("Second", type: .movie)
        vm2.markWatched(second, sentiment: .liked)
        driveSessionPreferringExisting(vm: vm2)
        vm2.finalizeRanking(for: second)

        // Now a comparison has happened, so positions mean something — and the
        // bucket is still two short of a number.
        for item in vm2.bucket(for: .liked, type: .movie) {
            let rank = try #require(item.rankInBucket)
            #expect(vm2.scoreDisplay(for: item) == .rank(position: rank + 1, sentiment: .liked))
        }
    }

    @Test("A position is not shown mid-comparison")
    func scoreDisplaySaysNothingWhileASessionIsOpen() throws {
        let vm = try makeLibrary()
        for n in 1...2 {
            let film = makeItem("Film \(n)", type: .movie)
            vm.markWatched(film, sentiment: .liked)
            driveSessionPreferringExisting(vm: vm)
            vm.finalizeRanking(for: film)
        }

        let candidate = makeItem("Candidate", type: .movie)
        vm.markWatched(candidate, sentiment: .liked)

        // The stored rank is a placeholder the user's next tap will overwrite.
        // Showing it would present a guess as an answer.
        #expect(vm.scoreDisplay(for: candidate) == .sentimentOnly(.liked))
    }

    @Test("An unwatched item shows no badge at all")
    func scoreDisplayIsNoneForUnwatchedItems() throws {
        let vm = try makeLibrary()
        let queued = makeItem("Queued", type: .movie)
        vm.addToWantToWatch(queued)
        #expect(vm.scoreDisplay(for: queued) == .none)
        #expect(vm.scoreDisplay(for: queued).accessibilityDescription == nil)
    }

    @Test("An unwatched item never shows a score")
    func unwatchedItemsHaveNoDisplayScore() throws {
        let vm = try makeLibrary()
        let queued = makeItem("Queued", type: .movie)
        vm.addToWantToWatch(queued)
        #expect(vm.displayScore(for: queued) == nil)
        #expect(vm.itemsUntilScoreRevealed(for: queued) == 0)
    }

    @Test("The first item in a bucket is not treated as ranked")
    func firstItemIsNotRankedUntilComparedAgainstSomething() throws {
        let vm = try makeLibrary()

        // Picking a sentiment with an empty bucket runs no comparisons at all,
        // so nothing about a rating has been earned yet.
        let first = makeItem("Alone", type: .movie)
        let pairs = vm.markWatched(first, sentiment: .liked)
        #expect(pairs.isEmpty)
        #expect(!vm.isRanked(first), "a rating was implied before any comparison")
        #expect(vm.displayScore(for: first) == nil)

        // A second title actually gets compared, which orders both of them.
        let second = makeItem("Second", type: .movie)
        vm.markWatched(second, sentiment: .liked)
        driveSessionPreferringExisting(vm: vm)
        vm.finalizeRanking(for: second)

        #expect(vm.isRanked(first))
        #expect(vm.isRanked(second))
        // Still no number: two is short of the five-item threshold.
        #expect(vm.displayScore(for: first) == nil)
    }

    @Test("isRanked is per bucket, not per library")
    func isRankedIsScopedToTheBucket() throws {
        let vm = try makeLibrary()
        for n in 1...3 {
            let film = makeItem("Film \(n)", type: .movie)
            vm.markWatched(film, sentiment: .liked)
            driveSessionPreferringExisting(vm: vm)
            vm.finalizeRanking(for: film)
        }
        // A lone show, and a lone disliked film, are each still unranked
        // despite a busy "Liked it" film bucket next door.
        let show = makeItem("Show", type: .tvShow)
        vm.markWatched(show, sentiment: .liked)
        let disliked = makeItem("Dud", type: .movie)
        vm.markWatched(disliked, sentiment: .disliked)

        #expect(!vm.isRanked(show))
        #expect(!vm.isRanked(disliked))
        #expect(vm.isRanked(vm.bucket(for: .liked, type: .movie)[0]))
    }

    @Test("No rating is shown while comparisons are still outstanding")
    func ratingIsWithheldDuringAnOpenSession() throws {
        let vm = try makeLibrary()

        // A bucket big enough that a score would normally be displayed.
        for n in 1...6 {
            let film = makeItem("Film \(n)", type: .movie)
            vm.markWatched(film, sentiment: .liked)
            driveSessionPreferringExisting(vm: vm)
            vm.finalizeRanking(for: film)
        }
        #expect(vm.displayScore(for: vm.bucket(for: .liked, type: .movie)[0]) != nil)

        // Confirming a sentiment places the item provisionally and opens a
        // session. A score exists immediately — the user just must not see it.
        let candidate = makeItem("Candidate", type: .movie)
        vm.markWatched(candidate, sentiment: .liked)
        #expect(candidate.score != nil, "provisional placement should still happen")
        #expect(vm.isRankingInProgress(for: candidate))
        #expect(vm.displayScore(for: candidate) == nil, "a rating showed mid-ranking")
        #expect(!vm.isRanked(candidate))

        // Answer one comparison but leave the session open where possible.
        if let pair = vm.pendingComparison {
            vm.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
        }
        if vm.pendingComparison != nil {
            #expect(vm.displayScore(for: candidate) == nil, "a rating showed mid-ranking")
        }

        // Finish it: now the rating is earned and appears.
        driveSessionPreferringExisting(vm: vm)
        vm.finalizeRanking(for: candidate)
        #expect(!vm.isRankingInProgress(for: candidate))
        #expect(vm.isRanked(candidate))
        #expect(vm.displayScore(for: candidate) == candidate.score)

        // Other items in the bucket are unaffected throughout.
        #expect(vm.displayScore(for: vm.bucket(for: .liked, type: .movie)[0]) != nil)
    }

    @Test("Abandoning a comparison still resolves the rating")
    func ratingAppearsAfterCancelling() throws {
        let vm = try makeLibrary()
        for n in 1...6 {
            let film = makeItem("Film \(n)", type: .movie)
            vm.markWatched(film, sentiment: .liked)
            driveSessionPreferringExisting(vm: vm)
            vm.finalizeRanking(for: film)
        }

        let candidate = makeItem("Bailed", type: .movie)
        vm.markWatched(candidate, sentiment: .liked)
        #expect(vm.displayScore(for: candidate) == nil)

        // Walking away closes the session, so the item stops being in limbo.
        vm.cancelRanking(for: candidate)
        #expect(!vm.isRankingInProgress(for: candidate))
        #expect(vm.displayScore(for: candidate) != nil)
    }

    // MARK: undo + ties

    @Test("Undo restores the previous pair and search bounds")
    func undoRestoresThePreviousComparison() throws {
        let vm = try makeLibrary()
        seedLikedBucket(vm: vm, count: 7) // 3 comparisons worst case

        let candidate = makeItem("Candidate", type: .movie)
        vm.markWatched(candidate, sentiment: .liked)

        #expect(!vm.canUndoComparison, "nothing answered yet")
        let firstPair = try #require(vm.pendingComparison)
        let firstOpponent = firstPair.existingItem.id
        let firstStep = firstPair.step

        vm.applyComparisonChoice(winner: candidate, loser: firstPair.existingItem)
        let secondPair = try #require(vm.pendingComparison)
        #expect(secondPair.existingItem.id != firstOpponent, "search did not advance")
        #expect(vm.canUndoComparison)

        vm.undoLastComparison()
        let restored = try #require(vm.pendingComparison)
        #expect(restored.existingItem.id == firstOpponent, "undo showed a different pair")
        #expect(restored.step == firstStep, "progress counter did not rewind")
        #expect(!vm.canUndoComparison, "undo stack should be empty again")

        // Answering the other way now leads somewhere different.
        vm.applyComparisonChoice(winner: restored.existingItem, loser: candidate)
        let afterOtherAnswer = try #require(vm.pendingComparison)
        #expect(afterOtherAnswer.existingItem.id != secondPair.existingItem.id)
    }

    @Test("Undo can rewind several comparisons in a row")
    func undoIsRepeatable() throws {
        let vm = try makeLibrary()
        seedLikedBucket(vm: vm, count: 15)

        let candidate = makeItem("Candidate", type: .movie)
        vm.markWatched(candidate, sentiment: .liked)
        let opening = try #require(vm.pendingComparison).existingItem.id

        var answered = 0
        while let pair = vm.pendingComparison, answered < 3 {
            vm.applyComparisonChoice(winner: candidate, loser: pair.existingItem)
            answered += 1
        }
        #expect(answered == 3)

        while vm.canUndoComparison { vm.undoLastComparison() }
        #expect(vm.pendingComparison?.existingItem.id == opening)
        #expect(vm.pendingComparison?.step == 1)
    }

    @Test("A tie ends the search and seats the item below its opponent")
    func tieSeatsItemBelowTheOpponent() throws {
        let vm = try makeLibrary()
        let seeds = seedLikedBucket(vm: vm, count: 7)

        let candidate = makeItem("Candidate", type: .movie)
        vm.markWatched(candidate, sentiment: .liked)
        let pair = try #require(vm.pendingComparison)
        let opponent = pair.existingItem

        vm.applyComparisonTie()
        #expect(vm.pendingComparison == nil, "a tie should end the search immediately")
        vm.finalizeRanking(for: candidate)

        let bucket = vm.bucket(for: .liked, type: .movie)
        let opponentIndex = try #require(bucket.firstIndex { $0.id == opponent.id })
        let candidateIndex = try #require(bucket.firstIndex { $0.id == candidate.id })
        #expect(candidateIndex == opponentIndex + 1, "tie did not seat the item just below")
        #expect(bucket.count == seeds.count + 1)
        expectBucketWellFormed(bucket, sentiment: .liked, count: seeds.count + 1)
    }

    @Test("A tie can be undone like any other answer")
    func tieIsUndoable() throws {
        let vm = try makeLibrary()
        seedLikedBucket(vm: vm, count: 7)
        let candidate = makeItem("Candidate", type: .movie)
        vm.markWatched(candidate, sentiment: .liked)
        let opening = try #require(vm.pendingComparison).existingItem.id

        vm.applyComparisonTie()
        #expect(vm.pendingComparison == nil)
        #expect(vm.canUndoComparison)

        vm.undoLastComparison()
        #expect(vm.pendingComparison?.existingItem.id == opening, "undo did not reopen the tie")
    }
}
