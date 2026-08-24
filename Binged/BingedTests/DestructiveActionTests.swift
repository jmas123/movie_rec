//
//  DestructiveActionTests.swift
//  BingedTests
//
//  Taking a title back out — GAP-AUDIT Section 4.
//
//  The app shipped with no destructive action of any kind: no delete, no
//  unwatch, no way off the watchlist. There was no `modelContext.delete` for a
//  `MediaItem` anywhere, so a title added by a mis-tap was permanent.
//
//  The thing these tests actually guard is the **vacated bucket**. Any write
//  that moves an item out of a `(type, sentiment)` bucket owes that bucket a
//  recompute, or the survivors keep scores derived from the old N and a hole
//  opens in `rankInBucket`. That bug has been got wrong twice in this codebase,
//  which is why every exit path gets its own test here rather than a shared one.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - Helpers

@MainActor
private func rankedLibrary(_ titles: [String]) throws -> (MediaLibraryViewModel, [MediaItem]) {
    let library = try makeLibrary()
    var items: [MediaItem] = []
    for title in titles {
        let item = makeItem(title, externalId: "tmdb:movie:\(title)")
        library.markWatched(item, sentiment: .liked)
        driveSessionPreferringNew(vm: library)
        library.finalizeRanking(for: item)
        items.append(item)
    }
    return (library, items)
}

// MARK: - Removal

@Suite("Removing a title")
@MainActor
struct RemovalTests {

    @Test("A removed title is gone from the library")
    func removeDeletesTheRow() throws {
        let library = try makeLibrary()
        let item = makeItem("Dune", externalId: "tmdb:movie:1")
        library.addToWantToWatch(item)
        #expect(library.allItems.count == 1)

        library.remove(item)

        #expect(library.allItems.isEmpty)
    }

    @Test("Removing from a bucket renumbers the survivors with no gap")
    func removalPaysBackTheBucket() throws {
        let (library, items) = try rankedLibrary(["A", "B", "C", "D", "E"])
        #expect(library.allWatched.count == 5)

        // Take one out of the middle rather than an end, where an off-by-one
        // would still happen to look sorted.
        let middle = try #require(library.allWatched.first { $0.rankInBucket == 2 })
        library.remove(middle)

        let survivors = library.allWatched
            .filter { $0.sentiment == .liked && $0.type == .movie }
            .sorted { ($0.rankInBucket ?? 0) < ($1.rankInBucket ?? 0) }

        #expect(survivors.count == 4)
        // Contiguous from zero: no hole where the removed item was.
        #expect(survivors.compactMap(\.rankInBucket) == [0, 1, 2, 3])
        _ = items
    }

    @Test("Scores after a removal are recomputed for the new bucket size")
    func removalRecomputesScores() throws {
        let (library, _) = try rankedLibrary(["A", "B", "C", "D", "E"])
        let last = try #require(library.allWatched.first { $0.rankInBucket == 4 })
        library.remove(last)

        let survivors = library.allWatched.sorted {
            ($0.rankInBucket ?? 0) < ($1.rankInBucket ?? 0)
        }
        let range = Sentiment.liked.scoreRange
        let n = Double(survivors.count)

        for (index, item) in survivors.enumerated() {
            let expected = range.upperBound
                - ((Double(index) + 0.5) / n) * (range.upperBound - range.lowerBound)
            let actual = try #require(item.score)
            // Derived for N = 4, not left over from N = 5.
            #expect(abs(actual - expected) < 0.0001)
        }
    }
}

// MARK: - Unwatching

@Suite("Unwatching a title")
@MainActor
struct UnwatchTests {

    @Test("Unwatching keeps the title but drops the ranking")
    func unwatchClearsTheRanking() throws {
        let (library, items) = try rankedLibrary(["A", "B"])
        let target = try #require(items.first)

        library.unwatch(target)

        // Still in the library — "I haven't seen this" is not "forget this".
        #expect(library.allItems.count == 2)
        #expect(target.watchedStatus == .untracked)
        #expect(target.sentiment == nil)
        #expect(target.score == nil)
        #expect(target.rankInBucket == nil)
    }

    @Test("Unwatching renumbers the bucket it left")
    func unwatchPaysBackTheBucket() throws {
        let (library, _) = try rankedLibrary(["A", "B", "C"])
        let middle = try #require(library.allWatched.first { $0.rankInBucket == 1 })

        library.unwatch(middle)

        let survivors = library.allWatched
            .sorted { ($0.rankInBucket ?? 0) < ($1.rankInBucket ?? 0) }
        #expect(survivors.count == 2)
        #expect(survivors.compactMap(\.rankInBucket) == [0, 1])
    }

    @Test("An unwatched title can be ranked again from scratch")
    func unwatchThenRerank() throws {
        let (library, items) = try rankedLibrary(["A", "B"])
        let target = try #require(items.first)
        library.unwatch(target)

        library.markWatched(target, sentiment: .liked)
        driveSessionPreferringExisting(vm: library)
        library.finalizeRanking(for: target)

        #expect(target.watchedStatus == .watched)
        #expect(target.score != nil)
        #expect(library.allWatched.count == 2)
    }
}

// MARK: - Undoing a dismissal

@Suite("Undoing Not for me")
@MainActor
struct UndismissTests {

    @Test("A dismissal can be undone")
    func undismissRestores() throws {
        // `undismiss` existed from Phase 17 and only tests called it, so a
        // mis-swipe on Discover was permanent.
        let library = try makeLibrary()
        let item = makeItem("Dune", externalId: "tmdb:movie:1")
        library.dismiss(item)
        #expect(item.dismissed)

        library.undismiss(item)

        #expect(!item.dismissed)
    }
}
