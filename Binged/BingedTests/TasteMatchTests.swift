//
//  TasteMatchTests.swift
//  BingedTests
//
//  Two libraries held against each other.
//
//  The tests that matter most here are not the percentage ones. They are the
//  two safety properties: a title the viewer has already *watched* must never be
//  offered as something to queue (queueing clears the sentiment, the score and
//  the rank), and rule 6 must survive the comparison — neither side may show a
//  number its bucket has not earned.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Helpers

private func theirItem(
    _ title: String,
    id: String,
    rank: Int = 0,
    bucketSize: Int = 8,
    sentiment: Sentiment = .liked,
    type: MediaType = .movie
) -> RankedItem {
    let scores = RankingEngine.scores(count: bucketSize, range: sentiment.scoreRange)
    return RankedItem(
        externalId: id, mediaType: type, sentiment: sentiment, title: title,
        year: 2020, score: scores[min(rank, scores.count - 1)],
        rankInBucket: rank, bucketSize: bucketSize
    )
}

private func mine(
    id: String,
    type: MediaType = .movie,
    status: WatchedStatus = .watched,
    sentiment: Sentiment? = .liked,
    score: Double? = 8.0,
    displayScore: Double? = 8.0,
    dismissed: Bool = false
) -> TasteMatch.LibraryEntry {
    TasteMatch.LibraryEntry(
        externalId: id, mediaType: type, status: status, sentiment: sentiment,
        score: score, displayScore: displayScore, dismissed: dismissed
    )
}

/// A pair of rankings over the same `count` titles, ordered the same way.
private func agreeingLibraries(count: Int) -> ([RankedItem], [TasteMatch.LibraryEntry]) {
    // Deliberately a *different* bucket size on the viewer's side, so the two
    // score scales do not line up numerically even though the order is identical.
    let myScores = RankingEngine.scores(count: count + 4, range: Sentiment.liked.scoreRange)

    let theirs = (0..<count).map {
        theirItem("Film \($0)", id: "tmdb:movie:\($0)", rank: $0, bucketSize: count)
    }
    let yours = (0..<count).map {
        mine(id: "tmdb:movie:\($0)", score: myScores[$0], displayScore: myScores[$0])
    }
    return (theirs, yours)
}

// MARK: - Identity

@Suite("Matching titles across two libraries")
struct TasteMatchIdentityTests {

    @Test("A title in both libraries becomes an overlap")
    func overlap() {
        let match = TasteMatch(
            theirs: [theirItem("Dune", id: "tmdb:movie:438631")],
            yours: [mine(id: "tmdb:movie:438631")]
        )
        #expect(match.sharedCount == 1)
        #expect(match.unseen.isEmpty)
    }

    @Test("The historical bare IMDb id matches the namespaced one")
    func canonicalIDs() {
        // A library written before the namespaced form stores `tt1375666`
        // where the server has `imdb:tt1375666`. Raw equality would read one
        // film as two, and the viewer would be told to watch what they ranked.
        let match = TasteMatch(
            theirs: [theirItem("Inception", id: "imdb:tt1375666")],
            yours: [mine(id: "tt1375666")]
        )
        #expect(match.sharedCount == 1)
    }

    @Test("Media type is part of the key")
    func typeIsPartOfIdentity() {
        let match = TasteMatch(
            theirs: [theirItem("Fargo", id: "x:1", type: .movie)],
            yours: [mine(id: "x:1", type: .tvShow)]
        )
        #expect(match.sharedCount == 0)
        #expect(match.unseen.count == 1)
    }
}

// MARK: - Standings

@Suite("What the viewer has already done about a title")
struct TasteMatchStandingTests {

    @Test("A watched title is never offered as something to queue")
    func watchedIsNeverSuggested() {
        // The load-bearing one. `addToWantToWatch` clears sentiment, score and
        // rank, so an Add button on a watched title is a one-tap way to destroy
        // a ranking from somebody else's screen.
        let item = theirItem("Heat", id: "tmdb:movie:949")

        for entry in [
            mine(id: "tmdb:movie:949"),                                     // ranked
            mine(id: "tmdb:movie:949", sentiment: nil, score: nil,          // mid-ranking
                 displayScore: nil),
        ] {
            let match = TasteMatch(theirs: [item], yours: [entry])
            #expect(match.unseen.isEmpty)
            #expect(match.standing(for: item) != .untracked)
        }
    }

    @Test("Watched but not yet ranked is not an overlap either")
    func midRankingIsNotComparable() {
        let item = theirItem("Heat", id: "tmdb:movie:949")
        let match = TasteMatch(
            theirs: [item],
            yours: [mine(id: "tmdb:movie:949", sentiment: nil, score: nil, displayScore: nil)]
        )
        #expect(match.sharedCount == 0)
        #expect(match.standing(for: item) == .watched)
    }

    @Test("A queued title is reported as queued, not suggested again")
    func queued() {
        let item = theirItem("Sicario", id: "tmdb:movie:273481")
        let match = TasteMatch(theirs: [item], yours: [mine(id: "tmdb:movie:273481", status: .wantToWatch)])
        #expect(match.unseen.isEmpty)
        #expect(match.alreadyQueued.count == 1)
        #expect(match.standing(for: item) == .queued)
    }

    @Test("A dismissed title is not re-suggested because a friend liked it")
    func dismissed() {
        // "Not for me" is an answer the user already gave.
        let match = TasteMatch(
            theirs: [theirItem("Cats", id: "tmdb:movie:excuse")],
            yours: [mine(id: "tmdb:movie:excuse", status: .untracked, sentiment: nil,
                         score: nil, displayScore: nil, dismissed: true)]
        )
        #expect(match.unseen.isEmpty)
    }

    @Test("Only titles they liked are suggested")
    func suggestionsComeFromTheirLikedBucket() {
        let match = TasteMatch(
            theirs: [
                theirItem("Good", id: "a", sentiment: .liked),
                theirItem("Fine", id: "b", sentiment: .fine),
                theirItem("Bad", id: "c", sentiment: .disliked),
            ],
            yours: []
        )
        #expect(match.unseen.map(\.title) == ["Good"])
    }

    @Test("Suggestions are ordered by where they sit in their ranking")
    func suggestionsAreOrdered() {
        let match = TasteMatch(
            theirs: [
                theirItem("Third", id: "c", rank: 2, bucketSize: 5),
                theirItem("First", id: "a", rank: 0, bucketSize: 5),
                theirItem("Second", id: "b", rank: 1, bucketSize: 5),
            ],
            yours: []
        )
        #expect(match.unseen.map(\.title) == ["First", "Second", "Third"])
    }
}

// MARK: - Percentage

@Suite("The taste match percentage")
struct TasteMatchPercentageTests {

    @Test("Below the shared-title threshold there is no percentage")
    func refusesSmallSamples() {
        for count in 0..<TasteMatch.minimumSharedForPercentage {
            let (theirs, yours) = agreeingLibraries(count: count)
            let match = TasteMatch(theirs: theirs, yours: yours)
            #expect(match.percentage == nil, "spoke at \(count) shared titles")
            #expect(match.verdict == nil)
        }
    }

    @Test("At the threshold, identical orderings are 100%")
    func perfectAgreement() {
        let (theirs, yours) = agreeingLibraries(count: TasteMatch.minimumSharedForPercentage)
        let match = TasteMatch(theirs: theirs, yours: yours)
        #expect(match.percentage == 100)
    }

    @Test("The percentage survives two libraries of different sizes")
    func invariantToBucketDrift() {
        // The reason it is a rank correlation and not a score distance: a score
        // is a quantile over its bucket, so it moves as the bucket grows. Two
        // people with the same taste and different library sizes must not read
        // as disagreeing. `agreeingLibraries` deliberately gives the two sides
        // different bucket sizes.
        let (theirs, yours) = agreeingLibraries(count: 9)
        let match = TasteMatch(theirs: theirs, yours: yours)
        #expect(match.percentage == 100)
    }

    @Test("A reversed ordering is 0%")
    func perfectDisagreement() {
        let count = 6
        let theirs = (0..<count).map {
            theirItem("Film \($0)", id: "tmdb:movie:\($0)", rank: $0, bucketSize: count)
        }
        let scores = RankingEngine.scores(count: count, range: Sentiment.liked.scoreRange)
        // Their best is the viewer's worst, all the way down.
        let yours = (0..<count).map {
            mine(id: "tmdb:movie:\($0)", score: scores[count - 1 - $0],
                 displayScore: scores[count - 1 - $0])
        }
        let match = TasteMatch(theirs: theirs, yours: yours)
        #expect(match.percentage == 0)
    }

    @Test("Nothing shared says how little is shared, and claims nothing else")
    func emptySampleNote() {
        let match = TasteMatch(theirs: [theirItem("A", id: "a")], yours: [])
        #expect(match.percentage == nil)
        #expect(match.sampleNote.contains("Nothing you've both ranked"))
    }
}

// MARK: - Rule 6

@Suite("Rule 6 applies to both sides of a comparison")
struct TasteMatchRuleSixTests {

    @Test("A row is fully scored only when both buckets earned a number")
    func bothSidesMustEarnTheNumber() {
        let threshold = MediaLibraryViewModel.minimumBucketSizeForScore

        // Their bucket is big enough; the viewer's is not.
        let match = TasteMatch(
            theirs: [theirItem("Alien", id: "a", bucketSize: threshold)],
            yours: [mine(id: "a", score: 7.9, displayScore: nil)]
        )
        let overlap = try? #require(match.overlaps.first)
        #expect(overlap?.yourDisplayScore == nil)
        #expect(overlap?.isFullyScored == false)

        // And the other way round.
        let reversed = TasteMatch(
            theirs: [theirItem("Alien", id: "a", bucketSize: threshold - 1)],
            yours: [mine(id: "a", score: 7.9, displayScore: 7.9)]
        )
        #expect(reversed.overlaps.first?.isFullyScored == false)
    }

    @Test("The gap is still known even when neither side may show it")
    func gapIsComputedFromStoredScores() {
        // The stored score always exists; only its display is withheld. That is
        // what lets "where you disagree" work on a library too small to show
        // numbers.
        let match = TasteMatch(
            theirs: [theirItem("Alien", id: "a", bucketSize: 1, sentiment: .liked)],
            yours: [mine(id: "a", sentiment: .disliked, score: 1.0, displayScore: nil)]
        )
        #expect(match.disagreements.count == 1)
        #expect((match.overlaps.first?.gap ?? 0) > 5)
    }
}

// MARK: - Slices

@Suite("What the overview shows")
struct TasteMatchSliceTests {

    @Test("Both loved needs both people in the liked bucket")
    func bothLoved() {
        let match = TasteMatch(
            theirs: [
                theirItem("Shared", id: "a", sentiment: .liked),
                theirItem("Only theirs", id: "b", sentiment: .liked),
            ],
            yours: [
                mine(id: "a", sentiment: .liked, score: 9.0, displayScore: 9.0),
                mine(id: "b", sentiment: .fine, score: 5.0, displayScore: 5.0),
            ]
        )
        #expect(match.bothLoved.map { $0.theirs.title } == ["Shared"])
    }

    @Test("A different sentiment is a disagreement however small the gap")
    func sentimentSplitAlwaysCounts() {
        // 6.8 against 6.7 is a tenth of a point and a whole bucket apart: one
        // of them liked it and the other did not.
        let match = TasteMatch(
            theirs: [theirItem("Borderline", id: "a", bucketSize: 1, sentiment: .liked)],
            yours: [mine(id: "a", sentiment: .fine, score: 6.7, displayScore: 6.7)]
        )
        #expect(match.disagreements.count == 1)
    }

    @Test("Agreeing closely inside one bucket is not a disagreement")
    func closeAgreementIsNotSurfaced() {
        let match = TasteMatch(
            theirs: [theirItem("Close", id: "a", rank: 0, bucketSize: 2, sentiment: .liked)],
            yours: [mine(id: "a", sentiment: .liked, score: 9.1, displayScore: 9.1)]
        )
        #expect(match.disagreements.isEmpty)
    }

    @Test("Overlaps are ordered closest agreement first")
    func overlapOrdering() {
        let match = TasteMatch(
            theirs: [
                theirItem("Far", id: "a", rank: 0, bucketSize: 1, sentiment: .liked),
                theirItem("Near", id: "b", rank: 0, bucketSize: 1, sentiment: .liked),
            ],
            yours: [
                mine(id: "a", sentiment: .disliked, score: 1.0, displayScore: 1.0),
                mine(id: "b", sentiment: .liked, score: 8.5, displayScore: 8.5),
            ]
        )
        #expect(match.overlaps.map { $0.theirs.title } == ["Near", "Far"])
    }
}
