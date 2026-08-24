//
//  RankingEngine.swift
//  Binged
//
//  Pure ranking logic. Intentionally imports only Foundation — no SwiftData,
//  no SwiftUI. The engine knows about `MediaItem` as a plain reference type
//  but does not assume anything about how it is persisted or rendered. The
//  pairwise comparator is supplied by the caller as a closure so the engine
//  has no knowledge of the UI prompt.
//

import Foundation

// MARK: - RankingEngine

/// Stateless service. Methods are instance methods so callers can inject a
/// mock or alternate implementation if the algorithm ever needs to vary.
struct RankingEngine {

    /// Result of comparing two items in a pairwise vote.
    /// `.preferLeft` means the left-hand item ranks higher than the right.
    enum Comparison {
        case preferLeft
        case preferRight
    }

    // MARK: - Insertion

    /// Find where `newItem` should be inserted into a bucket that is already
    /// sorted highest-rank-first. Uses binary insertion sort, so the worst
    /// case is `ceil(log2(N + 1))` comparator invocations for a bucket of
    /// size `N`.
    ///
    /// - Parameters:
    ///   - newItem: the item being placed.
    ///   - sortedBucket: the existing bucket, ordered so that index 0 is the
    ///     highest-ranked item.
    ///   - comparator: closure that receives `(left, right)` and returns
    ///     which one the user preferred. The engine never calls this for an
    ///     empty bucket.
    /// - Returns: the index in `sortedBucket` at which `newItem` should be
    ///   inserted. Range is `0 ... sortedBucket.count`.
    func insertionPosition(
        for newItem: MediaItem,
        in sortedBucket: [MediaItem],
        comparator: (_ left: MediaItem, _ right: MediaItem) -> Comparison
    ) -> Int {
        var lo = 0
        var hi = sortedBucket.count

        while lo < hi {
            let mid = (lo + hi) / 2
            switch comparator(newItem, sortedBucket[mid]) {
            case .preferLeft:
                // newItem ranks above the midpoint — search the upper half.
                hi = mid
            case .preferRight:
                // midpoint ranks above newItem — search the lower half.
                lo = mid + 1
            }
        }

        return lo
    }

    // MARK: - Score recomputation

    /// Mutates each item's `score` and `rankInBucket` so that scores are
    /// distributed across `range` using a quantile-style inset: each item
    /// sits at the center of its `1/N` slice of the range, so no item ever
    /// lands exactly on the bucket boundary. Higher-ranked items (lower
    /// index) get higher scores.
    ///
    /// Formula: `score[i] = upper - ((i + 0.5) / N) * (upper - lower)`
    ///
    /// Consequences:
    /// - Empty bucket  → returns immediately.
    /// - Single item   → midpoint of the range (since `(0 + 0.5)/1 = 0.5`).
    /// - N ≥ 2 items   → scores are strictly inside the range, monotonic
    ///                   decreasing, and evenly inset from the bounds; the
    ///                   gap between consecutive scores is `span / N`.
    ///
    /// - Returns: the same array, with mutations applied (`MediaItem` is a
    ///   reference type, so this is for caller convenience and chaining).
    @discardableResult
    func recomputeScores(
        in bucket: [MediaItem],
        range: ClosedRange<Double>
    ) -> [MediaItem] {
        let count = bucket.count
        guard count > 0 else { return bucket }

        let scores = Self.scores(count: count, range: range)
        for (index, item) in bucket.enumerated() {
            item.score = scores[index]
            item.rankInBucket = index
        }

        return bucket
    }

    // MARK: - Score positions

    /// The scores a bucket of `count` items receives, highest first.
    ///
    /// Pulled out of `recomputeScores` so callers that need the *values*
    /// without mutating anything can share one definition. Cross-validation is
    /// the caller that forced this: holding an item out of a bucket changes
    /// every remaining item's score, and simulating that against live
    /// `MediaItem`s would rewrite the user's real library.
    static func scores(count: Int, range: ClosedRange<Double>) -> [Double] {
        guard count > 0 else { return [] }
        let upper = range.upperBound
        let span = upper - range.lowerBound
        let n = Double(count)
        return (0..<count).map { upper - ((Double($0) + 0.5) / n) * span }
    }
}
