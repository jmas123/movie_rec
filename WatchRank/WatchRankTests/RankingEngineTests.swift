//
//  RankingEngineTests.swift
//  WatchRankTests
//
//  Covers the two public surfaces of `RankingEngine`:
//    1. binary-insertion position lookup with a bounded comparator count
//    2. score recomputation across a bucket
//

import Foundation
import Testing
@testable import WatchRank

// MARK: - Test helpers

/// Builds a watched `MediaItem` whose intrinsic ordering for tests is driven by
/// `truePosition` — lower values are "better". The comparator closures below
/// use this property so individual tests stay readable.
private func makeItem(
    title: String,
    truePosition: Int,
    type: MediaType = .movie
) -> MediaItem {
    MediaItem(
        title: title,
        year: 2024,
        type: type,
        watchedStatus: .watched,
        sentiment: .liked
    )
    .tagged(truePosition: truePosition)
}

private extension MediaItem {
    /// Stashes a "true rank" into `rankInBucket` purely for test scaffolding.
    /// The engine itself overwrites this value during `recomputeScores`.
    func tagged(truePosition: Int) -> MediaItem {
        self.rankInBucket = truePosition
        return self
    }

    /// Reads the stashed test-only true position.
    var truePosition: Int { rankInBucket ?? Int.max }
}

/// Counts comparator invocations for the log2-bound test.
private final class ComparatorCounter {
    private(set) var calls = 0

    func compare(_ left: MediaItem, _ right: MediaItem) -> RankingEngine.Comparison {
        calls += 1
        return left.truePosition < right.truePosition ? .preferLeft : .preferRight
    }
}

// MARK: - Tests

@Suite("RankingEngine")
struct RankingEngineTests {

    // MARK: insertionPosition

    @Test("Empty bucket: midpoint score, no comparator calls")
    func emptyBucketGetsMidpoint() {
        let engine = RankingEngine()
        let bucket: [MediaItem] = []
        let newItem = makeItem(title: "Solo", truePosition: 0)
        let counter = ComparatorCounter()

        let position = engine.insertionPosition(
            for: newItem,
            in: bucket,
            comparator: counter.compare
        )

        #expect(position == 0)
        #expect(counter.calls == 0)

        // After placement, recomputeScores on the single-item bucket must
        // produce the midpoint of the sentiment range — the quantile formula
        // collapses to `upper - 0.5 * span` for N = 1.
        let updated = engine.recomputeScores(
            in: [newItem],
            range: Sentiment.liked.scoreRange
        )
        let liked = Sentiment.liked.scoreRange
        let midpoint = (liked.lowerBound + liked.upperBound) / 2.0
        #expect(updated[0].score == midpoint)
        #expect(updated[0].rankInBucket == 0)
    }

    @Test(
        "Binary insertion uses at most ceil(log2(N + 1)) comparator calls",
        arguments: [1, 2, 3, 4, 7, 8, 15, 16, 31, 100]
    )
    func insertionIsLogarithmic(bucketSize: Int) {
        let engine = RankingEngine()
        // Sorted bucket: index 0 == best (truePosition 0), index N-1 == worst.
        let sortedBucket: [MediaItem] = (0..<bucketSize).map { i in
            makeItem(title: "Item \(i)", truePosition: i)
        }

        // Insert a candidate whose "true" position lands somewhere in the
        // middle of the bucket — this is the path that tends to maximize
        // comparisons in a binary search.
        let candidate = makeItem(
            title: "Candidate",
            truePosition: bucketSize / 2
        )
        let counter = ComparatorCounter()

        _ = engine.insertionPosition(
            for: candidate,
            in: sortedBucket,
            comparator: counter.compare
        )

        let bound = ceilLog2(bucketSize + 1)
        #expect(
            counter.calls <= bound,
            "N=\(bucketSize) used \(counter.calls) comparisons; bound is \(bound)"
        )
    }

    @Test("Single-item bucket: one comparator call, position 0 or 1")
    func singleItemBucket() {
        let engine = RankingEngine()
        let existing = makeItem(title: "Existing", truePosition: 5)
        let counter = ComparatorCounter()

        // Candidate ranks above the existing item.
        let better = makeItem(title: "Better", truePosition: 1)
        let positionBetter = engine.insertionPosition(
            for: better,
            in: [existing],
            comparator: counter.compare
        )
        #expect(positionBetter == 0)
        #expect(counter.calls == 1)

        // Reset and try the other direction.
        let counter2 = ComparatorCounter()
        let worse = makeItem(title: "Worse", truePosition: 10)
        let positionWorse = engine.insertionPosition(
            for: worse,
            in: [existing],
            comparator: counter2.compare
        )
        #expect(positionWorse == 1)
        #expect(counter2.calls == 1)
    }

    @Test("Order is preserved across multiple inserts")
    func orderPreservedAcrossInserts() {
        let engine = RankingEngine()

        // Insert several candidates one at a time, in arrival order. The
        // resulting bucket must be sorted by truePosition ascending.
        let arrivals: [MediaItem] = [
            makeItem(title: "C", truePosition: 5),
            makeItem(title: "A", truePosition: 1),
            makeItem(title: "E", truePosition: 9),
            makeItem(title: "B", truePosition: 3),
            makeItem(title: "D", truePosition: 7),
            makeItem(title: "F", truePosition: 11),
            makeItem(title: "Z", truePosition: 99)
        ]

        var bucket: [MediaItem] = []
        for arrival in arrivals {
            let counter = ComparatorCounter()
            let position = engine.insertionPosition(
                for: arrival,
                in: bucket,
                comparator: counter.compare
            )
            bucket.insert(arrival, at: position)
        }

        let positions = bucket.map(\.truePosition)
        #expect(positions == positions.sorted())
        #expect(bucket.map(\.title) == ["A", "B", "C", "D", "E", "F", "Z"])
    }

    // MARK: recomputeScores

    @Test("Score recomputation: monotonic decreasing, strictly inside range, evenly inset")
    func scoresAreEvenlyInsetInRange() {
        let engine = RankingEngine()
        let range = Sentiment.liked.scoreRange
        let bucket: [MediaItem] = (0..<5).map { i in
            makeItem(title: "Item \(i)", truePosition: i)
        }

        engine.recomputeScores(in: bucket, range: range)

        // Pull the scores out, validate them.
        let scores = bucket.compactMap(\.score)
        #expect(scores.count == bucket.count)

        // All STRICTLY inside the range — the quantile inset means no score
        // ever lands exactly on a bucket boundary.
        for score in scores {
            #expect(score > range.lowerBound)
            #expect(score < range.upperBound)
        }

        // Monotonic decreasing.
        for pair in zip(scores, scores.dropFirst()) {
            #expect(pair.0 > pair.1)
        }

        // Evenly inset — consecutive gaps equal to `span / N`.
        let span = range.upperBound - range.lowerBound
        let expectedGap = span / Double(bucket.count)
        let gaps = zip(scores, scores.dropFirst()).map { $0 - $1 }
        for gap in gaps {
            #expect(abs(gap - expectedGap) < 1e-9)
        }

        // First and last scores sit half a slice from the bucket's bounds.
        let halfSlice = span / (2.0 * Double(bucket.count))
        #expect(abs(scores.first! - (range.upperBound - halfSlice)) < 1e-9)
        #expect(abs(scores.last! - (range.lowerBound + halfSlice)) < 1e-9)

        // rankInBucket follows array index.
        for (i, item) in bucket.enumerated() {
            #expect(item.rankInBucket == i)
        }
    }

    @Test("Single-item bucket: midpoint of range, rankInBucket = 0")
    func singleItemScoreIsMidpoint() {
        let engine = RankingEngine()
        let range = Sentiment.fine.scoreRange
        let item = makeItem(title: "Only", truePosition: 0)

        engine.recomputeScores(in: [item], range: range)

        let midpoint = (range.lowerBound + range.upperBound) / 2.0
        #expect(item.score == midpoint)
        #expect(item.rankInBucket == 0)
    }

    @Test("Two-item bucket: scores sit at the 0.25 and 0.75 quantiles, not at the bounds")
    func twoItemScoresAreQuantileInset() {
        let engine = RankingEngine()
        let range = Sentiment.disliked.scoreRange
        let top = makeItem(title: "Top", truePosition: 0)
        let bottom = makeItem(title: "Bottom", truePosition: 1)

        engine.recomputeScores(in: [top, bottom], range: range)

        let span = range.upperBound - range.lowerBound
        let expectedTop = range.upperBound - 0.25 * span
        let expectedBottom = range.upperBound - 0.75 * span

        #expect(abs((top.score ?? .nan) - expectedTop) < 1e-9)
        #expect(abs((bottom.score ?? .nan) - expectedBottom) < 1e-9)
        #expect((top.score ?? 0) < range.upperBound)
        #expect((bottom.score ?? 0) > range.lowerBound)
        #expect(top.rankInBucket == 0)
        #expect(bottom.rankInBucket == 1)
    }
}
