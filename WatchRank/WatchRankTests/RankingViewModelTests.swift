//
//  RankingViewModelTests.swift
//  WatchRankTests
//
//  Covers the Ranking screen's view model: type-tab filtering, the empty-state
//  flag, the reorder gate (All-tab only), and that an All-tab move delegates to
//  the library VM and rescore the bucket.
//

import Foundation
import SwiftData
import Testing
@testable import WatchRank

// MARK: - Helpers

/// Marks an item watched into `sentiment`, driving any comparison to the bottom
/// so seeding is deterministic. Returns the inserted item.
@MainActor
@discardableResult
private func add(
    _ library: MediaLibraryViewModel,
    _ title: String,
    _ type: MediaType,
    _ sentiment: Sentiment
) -> MediaItem {
    let item = MediaItem(title: title, year: 2020, type: type)
    library.markWatched(item, sentiment: sentiment)
    while let pair = library.pendingComparison {
        library.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
    }
    library.finalizeRanking(for: item)
    return item
}

// MARK: - Tests

@MainActor
@Suite("RankingViewModel")
struct RankingViewModelTests {

    // MARK: filtering

    @Test("The All tab returns the full bucket; type tabs narrow it")
    func typeFilterNarrowsBucket() throws {
        let library = try makeLibrary()
        add(library, "Movie A", .movie, .liked)
        add(library, "Movie B", .movie, .liked)
        add(library, "Show A", .tvShow, .liked)

        let vm = RankingViewModel(library: library)

        vm.filter = .all
        #expect(vm.items(for: .liked).count == 3)

        vm.filter = .movies
        #expect(vm.items(for: .liked).count == 2)
        #expect(vm.items(for: .liked).allSatisfy { $0.type == .movie })

        vm.filter = .tv
        #expect(vm.items(for: .liked).count == 1)
        #expect(vm.items(for: .liked).first?.type == .tvShow)
    }

    @Test("items(for:) preserves the library's rank order")
    func filterPreservesRankOrder() throws {
        let library = try makeLibrary()
        add(library, "A", .movie, .liked)
        add(library, "B", .movie, .liked)
        add(library, "C", .movie, .liked)

        let vm = RankingViewModel(library: library)
        let ids = vm.items(for: .liked).map(\.id)
        let libraryIDs = library.bucket(for: .liked, type: .movie).map(\.id)
        #expect(ids == libraryIDs)
    }

    // MARK: empty state

    @Test("isEmpty is true with no watched items and false once one exists")
    func isEmptyReflectsLibrary() throws {
        let library = try makeLibrary()
        let vm = RankingViewModel(library: library)
        #expect(vm.isEmpty)

        add(library, "Solo", .movie, .liked)
        #expect(!vm.isEmpty)
    }

    @Test("isEmpty respects the active type filter")
    func isEmptyRespectsFilter() throws {
        let library = try makeLibrary()
        add(library, "Only Movie", .movie, .liked)

        let vm = RankingViewModel(library: library)
        vm.filter = .movies
        #expect(!vm.isEmpty)
        vm.filter = .tv
        #expect(vm.isEmpty) // no TV items
    }

    // MARK: reorder gate

    @Test("canReorder is true only on a type tab")
    func canReorderOnlyOnTypeTab() throws {
        let library = try makeLibrary()
        let vm = RankingViewModel(library: library)

        // A bucket is (type, sentiment), so only a type tab shows exactly one
        // bucket. The All tab interleaves two independent rankings and has no
        // single bucket a move could resolve against.
        vm.filter = .all
        #expect(!vm.canReorder)
        vm.filter = .movies
        #expect(vm.canReorder)
        vm.filter = .tv
        #expect(vm.canReorder)
    }

    @Test("A type-tab move reorders that bucket and rescores it")
    func moveReordersOnTypeTab() throws {
        let library = try makeLibrary()
        add(library, "A", .movie, .liked)
        add(library, "B", .movie, .liked)
        add(library, "C", .movie, .liked)

        let vm = RankingViewModel(library: library)
        vm.filter = .movies

        let before = vm.items(for: .liked)
        let topID = before[0].id
        let topScore = before[0].score

        // Move the top item to the bottom.
        vm.move(in: .liked, from: IndexSet(integer: 0), to: 3)

        let after = vm.items(for: .liked)
        #expect(after.last?.id == topID)
        #expect(after.first?.score == topScore) // position-based score stays put
        for (i, item) in after.enumerated() {
            #expect(item.rankInBucket == i)
        }
    }

    @Test("A move is ignored on the All tab")
    func moveIgnoredOnAllTab() throws {
        let library = try makeLibrary()
        add(library, "A", .movie, .liked)
        add(library, "B", .movie, .liked)
        add(library, "C", .movie, .liked)

        let vm = RankingViewModel(library: library)
        vm.filter = .all

        let before = vm.items(for: .liked).map(\.id)
        vm.move(in: .liked, from: IndexSet(integer: 0), to: 3)
        let after = vm.items(for: .liked).map(\.id)

        #expect(before == after) // unchanged
    }
}
