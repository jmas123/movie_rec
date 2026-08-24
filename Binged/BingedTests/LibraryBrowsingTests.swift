//
//  LibraryBrowsingTests.swift
//  BingedTests
//
//  Finding a title in your own ranking, and asking Discover for more than one
//  screenful — GAP-AUDIT Section 4.
//
//  Both had a trap worth a test. Filtering a ranked list breaks the 1:1 mapping
//  that drag-to-reorder depends on, and growing a recommendation request can
//  reshuffle rows the user is already looking at.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - Ranking search

@Suite("Searching your ranking")
@MainActor
struct RankingSearchTests {

    private func libraryWith(_ titles: [String]) throws -> MediaLibraryViewModel {
        let library = try makeLibrary()
        for title in titles {
            let item = makeItem(title, externalId: "tmdb:movie:\(title)")
            library.markWatched(item, sentiment: .liked)
            driveSessionPreferringNew(vm: library)
            library.finalizeRanking(for: item)
        }
        return library
    }

    @Test("A query narrows the list to matching titles")
    func queryFilters() throws {
        let library = try libraryWith(["Dune", "Arrival", "Dunkirk"])
        let viewModel = RankingViewModel(library: library)
        viewModel.filter = .movies

        viewModel.query = "dun"

        let titles = viewModel.items(for: .liked).map(\.title).sorted()
        #expect(titles == ["Dune", "Dunkirk"])
    }

    @Test("Filtering hides rows but never re-sorts them")
    func filterPreservesRankOrder() throws {
        let library = try libraryWith(["Dune", "Arrival", "Dunkirk"])
        let viewModel = RankingViewModel(library: library)
        viewModel.filter = .movies

        let unfiltered = viewModel.items(for: .liked).map(\.title)
        viewModel.query = "d"
        let filtered = viewModel.items(for: .liked).map(\.title)

        // A search that reordered a ranking would be showing the user
        // something that is not their ranking.
        #expect(filtered == unfiltered.filter { $0.localizedCaseInsensitiveContains("d") })
    }

    @Test("Reordering is refused while a filter is active")
    func filteringDisablesReorder() throws {
        // The trap. A filtered list does not map onto the bucket the engine
        // rescores, so a drag from visible row 0 to row 2 would move the item
        // to the wrong place in the real ranking.
        let library = try libraryWith(["Dune", "Arrival", "Dunkirk"])
        let viewModel = RankingViewModel(library: library)
        viewModel.filter = .movies
        #expect(viewModel.canReorder)

        viewModel.query = "dun"

        #expect(!viewModel.canReorder)
    }

    @Test("A move attempted while filtered changes nothing")
    func filteredMoveIsANoOp() throws {
        let library = try libraryWith(["Dune", "Arrival", "Dunkirk"])
        let viewModel = RankingViewModel(library: library)
        viewModel.filter = .movies
        viewModel.query = "dun"

        let before = library.bucket(for: .liked, type: .movie).map(\.title)
        viewModel.move(in: .liked, from: IndexSet(integer: 0), to: 2)
        let after = library.bucket(for: .liked, type: .movie).map(\.title)

        // Guarded in the view model as well as the view: a stray event must
        // not be able to reorder against an interleaved or filtered list.
        #expect(before == after)
    }

    @Test("Clearing the query restores the whole list and re-enables reordering")
    func clearingRestores() throws {
        let library = try libraryWith(["Dune", "Arrival"])
        let viewModel = RankingViewModel(library: library)
        viewModel.filter = .movies
        viewModel.query = "dune"
        #expect(viewModel.items(for: .liked).count == 1)

        viewModel.query = ""

        #expect(viewModel.items(for: .liked).count == 2)
        #expect(viewModel.canReorder)
    }

    @Test("An unmatched query is empty, and reports itself as filtering")
    func unmatchedQuery() throws {
        let library = try libraryWith(["Dune"])
        let viewModel = RankingViewModel(library: library)
        viewModel.query = "nothing matches this"

        // `isEmpty` alone would drive the "Nothing ranked yet" empty state,
        // which is false and unhelpful when the user has a library and a typo.
        #expect(viewModel.isEmpty)
        #expect(viewModel.isFiltering)
    }
}
