//
//  CorrectnessRegressionTests.swift
//  BingedTests
//
//  GAP-AUDIT Section 3: bugs on paths a user can actually reach.
//
//  Each test names the failure it prevents rather than the method it calls —
//  these are regressions, and the thing worth writing down is what went wrong.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - #15 Duplicate rows from Discover

@Suite("Library identity")
@MainActor
struct LibraryIdentityTests {

    @Test("A queued title opened again resolves to the row already stored")
    func canonicalResolvesQueuedTitle() throws {
        // Discover deliberately keeps already-queued titles in its results and
        // mints a fresh, detached MediaItem for each. Pushing that copy into
        // the detail screen showed `.untracked` for something already in the
        // library, and marking it watched inserted a second row.
        let library = try makeLibrary()
        let queued = makeItem("Dune", externalId: "tmdb:movie:438631")
        library.addToWantToWatch(queued)

        let fromDiscover = makeItem("Dune", externalId: "tmdb:movie:438631")
        let resolved = library.canonicalItem(for: fromDiscover)

        #expect(resolved.id == queued.id)
        #expect(resolved.watchedStatus == .wantToWatch)
    }

    @Test("Marking a canonicalised recommendation watched does not add a second row")
    func noDuplicateRowOnWatch() throws {
        let library = try makeLibrary()
        library.addToWantToWatch(makeItem("Dune", externalId: "tmdb:movie:438631"))
        #expect(library.allItems.count == 1)

        // What DiscoverView now does before pushing the detail screen.
        let detached = makeItem("Dune", externalId: "tmdb:movie:438631")
        library.markWatched(library.canonicalItem(for: detached), sentiment: .liked)

        #expect(library.allItems.count == 1)
        #expect(library.allWatched.count == 1)
    }

    @Test("Without canonicalising, the same title becomes two rows")
    func uncanonicalisedDuplicates() throws {
        // The bug itself, pinned so nobody "simplifies" the call site away.
        let library = try makeLibrary()
        library.addToWantToWatch(makeItem("Dune", externalId: "tmdb:movie:438631"))

        library.markWatched(makeItem("Dune", externalId: "tmdb:movie:438631"), sentiment: .liked)

        #expect(library.allItems.count == 2)
    }

    @Test("Identity is the external id, so a different title is never merged")
    func differentTitlesStayDistinct() throws {
        let library = try makeLibrary()
        library.addToWantToWatch(makeItem("Dune", externalId: "tmdb:movie:438631"))

        let other = makeItem("Arrival", externalId: "tmdb:movie:329865")
        #expect(library.canonicalItem(for: other).id == other.id)
    }
}

// MARK: - #20 A failed page is not the end of the list

@Suite("Pagination honesty")
@MainActor
struct PaginationHonestyTests {

    /// Serves one full page, then fails.
    private final class FlakyFeedService: FeedService, @unchecked Sendable {
        let first: [FeedPost]
        init(first: [FeedPost]) { self.first = first }

        func feed(before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] {
            guard cursor != nil else { return first }
            throw SupabaseError.http(status: 500, message: nil)
        }
        func posts(by userID: UUID, before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] { [] }
        func createPost(kind: FeedPost.Kind, payload: FeedPost.Payload) async throws {}
        func react(to postID: UUID) async throws {}
        func unreact(to postID: UUID) async throws {}
        func comments(on postID: UUID, limit: Int) async throws -> [PostComment] { [] }
        @discardableResult
        func addComment(to postID: UUID, body: String) async throws -> PostComment {
            throw SocialError.underlying("not implemented")
        }
        func editComment(_ commentID: UUID, body: String) async throws {}
        func deleteComment(_ commentID: UUID) async throws {}
        func report(_ target: ReportTarget, reason: ReportReason, note: String?) async throws {}
    }

    private func fullPage() -> [FeedPost] {
        (0..<FeedViewModel.pageSize).map { index in
            FeedPost(
                id: UUID(), authorID: UUID(), kind: .ranked,
                createdAt: Date().addingTimeInterval(-Double(index)),
                authorHandle: "alex", authorDisplayName: "Alex", authorAvatarURL: nil,
                payload: .init(
                    externalId: "tmdb:movie:\(index)", title: "T\(index)", year: 2024,
                    mediaType: .movie, sentiment: .liked, rankInBucket: 0,
                    bucketSize: 8, reviewExcerpt: nil
                ),
                commentCount: 0, reactionCount: 0, viewerHasReacted: false
            )
        }
    }

    @Test("A failed page is reported, not passed off as the end of the feed")
    func failedPageIsDistinguishable() async {
        let viewModel = FeedViewModel(
            service: FlakyFeedService(first: fullPage()),
            social: MockSocialService(),
            isSignedIn: { true }
        )
        await viewModel.refresh()
        #expect(viewModel.hasMore)

        await viewModel.loadMore()

        // Paging stops either way — otherwise `onAppear` retries forever — but
        // the reader must not be shown a truncated feed as if it were whole.
        #expect(!viewModel.hasMore)
        #expect(viewModel.loadMoreFailed)
    }

    @Test("A genuinely short page ends the feed without claiming a failure")
    func shortPageIsNotAFailure() async {
        let service = StubShortFeed()
        let viewModel = FeedViewModel(
            service: service, social: MockSocialService(), isSignedIn: { true }
        )
        await viewModel.refresh()

        #expect(!viewModel.hasMore)
        #expect(!viewModel.loadMoreFailed)
    }

    private final class StubShortFeed: FeedService, @unchecked Sendable {
        func feed(before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] {
            cursor == nil ? [] : []
        }
        func posts(by userID: UUID, before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] { [] }
        func createPost(kind: FeedPost.Kind, payload: FeedPost.Payload) async throws {}
        func react(to postID: UUID) async throws {}
        func unreact(to postID: UUID) async throws {}
        func comments(on postID: UUID, limit: Int) async throws -> [PostComment] { [] }
        @discardableResult
        func addComment(to postID: UUID, body: String) async throws -> PostComment {
            throw SocialError.underlying("not implemented")
        }
        func editComment(_ commentID: UUID, body: String) async throws {}
        func deleteComment(_ commentID: UUID) async throws {}
        func report(_ target: ReportTarget, reason: ReportReason, note: String?) async throws {}
    }
}


// MARK: - Search error stickiness

@Suite("Search error recovery")
@MainActor
struct SearchErrorRecoveryTests {

    private final class FailOnceService: MediaService, @unchecked Sendable {
        var shouldFail = true
        func search(query: String) async throws -> [MediaItem] {
            if shouldFail { throw TMDBError.decoding("boom") }
            return [makeItem("Dune", externalId: "tmdb:movie:1")]
        }
        func popularTitles(type: MediaType, page: Int) async throws -> [MediaItem] { [] }
        func fetch(id: String) async throws -> MediaItem? { nil }
    }

    @Test("Typing a new query clears the previous failure instead of keeping it on screen")
    func staleErrorDoesNotSurviveTheNextKeystroke() async {
        let service = FailOnceService()
        let viewModel = SearchViewModel(service: service, debounce: .milliseconds(1))

        viewModel.query = "dune"
        try? await Task.sleep(for: .milliseconds(80))
        guard case .error = viewModel.phase else {
            Issue.record("expected the first search to fail")
            return
        }

        // `phase` reads `errorMessage` before anything else, so a stale error
        // used to sit on screen through the whole debounce of the next query.
        service.shouldFail = false
        viewModel.query = "arrival"

        #expect(viewModel.phase == .searching)
    }
}
