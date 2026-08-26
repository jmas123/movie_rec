//
//  TitleWatchersTests.swift
//  BingedTests
//
//  "Friends who watched" — the section, the transport, and the review that has
//  to survive a round trip for either to mean anything.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Fixtures

private func watcher(
    _ handle: String,
    sentiment: Sentiment = .liked,
    score: Double? = 8.4,
    rank: Int? = 1,
    bucketSize: Int = 10,
    review: String? = nil,
    id: UUID = UUID()
) -> TitleWatcher {
    TitleWatcher(
        userID: id,
        handle: handle,
        displayName: handle.capitalized,
        avatarURL: nil,
        sentiment: sentiment,
        score: score,
        rankInBucket: rank,
        bucketSize: bucketSize,
        review: review
    )
}

// MARK: - Rule 6 travels

@Suite("A friend's score is withheld on the same terms as your own")
struct WatcherScoreVisibilityTests {

    @Test("A score from a bucket that has not earned it is not shown")
    func unearnedScoreWithheld() {
        // The whole point of rule 6: an 8.4 derived from a bucket of one is the
        // band midpoint wearing a decimal point. Attributing that to a *person*
        // is worse than showing it unattributed, because it reads as their
        // considered verdict.
        let thin = watcher("mina", bucketSize: 1)
        #expect(thin.displayScore == nil)
        #expect(thin.positionDescription == "#2 in “Liked it”")
    }

    @Test("A score from an earned bucket is shown")
    func earnedScoreShown() {
        let deep = watcher("devon", bucketSize: MediaLibraryViewModel.minimumBucketSizeForScore)
        #expect(deep.displayScore == 8.4)
    }

    @Test("The threshold is the same one the owner's own device applies")
    func thresholdMatchesOwner() {
        // If these two ever diverge a title reads differently on their screen
        // than on yours, which is exactly the inconsistency rule 6 exists to
        // prevent. Asserted rather than assumed because they are separate types.
        let size = MediaLibraryViewModel.minimumBucketSizeForScore
        let mine = RankedItem(
            externalId: "1", mediaType: .movie, sentiment: .liked,
            title: "T", year: 2024, score: 8.4, rankInBucket: 1, bucketSize: size - 1
        )
        let theirs = watcher("sasha", bucketSize: size - 1)
        #expect(mine.displayScore == nil)
        #expect(theirs.displayScore == nil)
    }

    @Test("A review is only a review when it has something in it")
    func blankReviewIsNotAReview() {
        #expect(!watcher("a", review: nil).hasReview)
        #expect(!watcher("b", review: "   \n ").hasReview)
        #expect(watcher("c", review: "Loved it.").hasReview)
    }
}

// MARK: - The section

@Suite("The friends section stays silent unless it has something to say")
@MainActor
struct TitleWatchersViewModelTests {

    @Test("No service means no section, and no request")
    func noServiceNoSection() async {
        let viewModel = TitleWatchersViewModel()
        await viewModel.load(from: nil, externalID: "603", mediaType: .movie)
        #expect(!viewModel.hasContent)
        #expect(viewModel.phase == .idle)
    }

    @Test("A title with no external id has nothing to look up")
    func noExternalIDNoRequest() async {
        let service = MockRankingFeedService()
        let viewModel = TitleWatchersViewModel()
        await viewModel.load(from: service, externalID: nil, mediaType: .movie)
        #expect(viewModel.phase == .idle)
    }

    @Test("Watchers load and are held for the section")
    func loadsWatchers() async {
        let service = MockRankingFeedService()
        service.setWatchers(
            [watcher("mina", review: "Still think about it."), watcher("devon")],
            forExternalID: "603", mediaType: .movie
        )
        let viewModel = TitleWatchersViewModel()
        await viewModel.load(from: service, externalID: "603", mediaType: .movie)

        #expect(viewModel.phase == .loaded)
        #expect(viewModel.watchers.map(\.handle) == ["mina", "devon"])
        #expect(viewModel.reviewCount == 1)
    }

    @Test("Nobody is an empty section, not an error")
    func nobodyIsEmpty() async {
        let viewModel = TitleWatchersViewModel()
        await viewModel.load(from: MockRankingFeedService(), externalID: "603", mediaType: .movie)
        #expect(viewModel.phase == .empty)
        #expect(!viewModel.hasContent)
    }

    @Test("A failure is silent, and leaves the title screen alone")
    func failureIsSilent() async {
        // The section is a garnish. A red box apologising for a garnish is a
        // worse screen than no garnish.
        final class FailingRankings: RankingFeedService, @unchecked Sendable {
            func rankedItems(userID: UUID, offset: Int, limit: Int) async throws -> [RankedItem] { [] }
            func watchers(
                externalID: String, mediaType: MediaType, limit: Int
            ) async throws -> [TitleWatcher] {
                throw SocialError.notConfigured
            }
        }
        let viewModel = TitleWatchersViewModel()
        await viewModel.load(from: FailingRankings(), externalID: "603", mediaType: .movie)

        #expect(viewModel.phase == .failed)
        #expect(!viewModel.hasContent, "a failure must not render a section")
    }

    @Test("The same title is not fetched twice")
    func loadsOncePerTitle() async {
        // `MediaDetailView` re-runs its task on more than the title changing,
        // and this request is attributed to real people.
        final class CountingRankings: RankingFeedService, @unchecked Sendable {
            let count = Counter()
            func rankedItems(userID: UUID, offset: Int, limit: Int) async throws -> [RankedItem] { [] }
            func watchers(
                externalID: String, mediaType: MediaType, limit: Int
            ) async throws -> [TitleWatcher] {
                count.bump()
                return [watcher("mina")]
            }
        }
        let service = CountingRankings()
        let viewModel = TitleWatchersViewModel()

        await viewModel.load(from: service, externalID: "603", mediaType: .movie)
        await viewModel.load(from: service, externalID: "603", mediaType: .movie)
        await viewModel.load(from: service, externalID: "603", mediaType: .movie)

        #expect(service.count.value == 1)
    }

    @Test("A different title does fetch again")
    func differentTitleRefetches() async {
        let service = MockRankingFeedService()
        service.setWatchers([watcher("mina")], forExternalID: "603", mediaType: .movie)
        service.setWatchers([watcher("devon")], forExternalID: "999", mediaType: .movie)

        let viewModel = TitleWatchersViewModel()
        await viewModel.load(from: service, externalID: "603", mediaType: .movie)
        await viewModel.load(from: service, externalID: "999", mediaType: .movie)

        #expect(viewModel.watchers.map(\.handle) == ["devon"])
    }
}

// MARK: - Counter

/// A `let` box so a `@unchecked Sendable` stub can count without `var` capture.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func bump() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}

// MARK: - Transport

@Suite("The watchers RPC")
struct TitleWatchersTransportTests {

    @Test("Asks the RPC by media type and external id")
    func callsRPC() async throws {
        let log = RequestLog()
        let client = makeSupabaseClient(log: log) { _ in .ok(Data("[]".utf8)) }
        let service = SupabaseRankingFeedService(
            client: client, configuration: makeSupabaseConfiguration()
        )

        _ = try await service.watchers(externalID: "603", mediaType: .movie, limit: 20)

        let url = log.urls.first ?? ""
        #expect(url.contains("/rpc/title_watchers"), "wrong endpoint: \(url)")
    }

    @Test("Forbidden reads as nobody, not as an error")
    func forbiddenIsEmpty() async throws {
        // Matches `rankedItems`: a library the viewer may not read must not be
        // detectable by the shape of the failure.
        let client = makeSupabaseClient { _ in .status(403, SupabaseFixtures.forbidden) }
        let service = SupabaseRankingFeedService(
            client: client, configuration: makeSupabaseConfiguration()
        )

        let found = try await service.watchers(externalID: "603", mediaType: .movie, limit: 20)
        #expect(found.isEmpty)
    }

    @Test("Decodes the RPC's snake_case rows")
    func decodesRows() async throws {
        let body = Data("""
        [{"user_id":"00000000-0000-0000-0000-0000000000BB","handle":"mina",
          "display_name":"Mina Okafor","avatar_url":null,"sentiment":"liked",
          "score":9.1,"rank_in_bucket":0,"bucket_size":12,"review":"Extraordinary."}]
        """.utf8)
        let client = makeSupabaseClient { _ in .ok(body) }
        let service = SupabaseRankingFeedService(
            client: client, configuration: makeSupabaseConfiguration()
        )

        let found = try await service.watchers(externalID: "603", mediaType: .movie, limit: 20)

        #expect(found.count == 1)
        #expect(found.first?.handle == "mina")
        #expect(found.first?.name == "Mina Okafor")
        #expect(found.first?.displayScore == 9.1)
        #expect(found.first?.review == "Extraordinary.")
    }
}

// MARK: - The review round trip

@Suite("A review survives publish and restore")
struct ReviewRoundTripTests {

    @Test("A review is published alongside the score")
    func reviewIsPublished() {
        // Before this field existed the restore path returned every title and
        // none of the writing, so reinstalling silently discarded it.
        let item = MediaItem(
            externalId: "603", title: "The Matrix", year: 1999, type: .movie,
            watchedStatus: .watched, sentiment: .liked, score: 9.1, rankInBucket: 0,
            review: "Still the best of them."
        )
        let published = PublishedItem(item, bucketSize: 8)

        #expect(published?.review == "Still the best of them.")
    }

    @Test("A title with no review publishes nil, not an empty string")
    func absentReviewStaysNil() {
        let item = MediaItem(
            externalId: "603", title: "The Matrix", year: 1999, type: .movie,
            watchedStatus: .watched, sentiment: .liked, score: 9.1, rankInBucket: 0
        )
        #expect(PublishedItem(item, bucketSize: 8)?.review == nil)
    }

    @Test("A restored row carries its review back")
    func restoreCarriesReview() {
        let remote = RemoteRankedItem(
            externalId: "603", mediaType: .movie, sentiment: .liked,
            title: "The Matrix", year: 1999, rankInBucket: 0,
            updatedAt: Date(timeIntervalSince1970: 1_000_000), posterPath: nil,
            review: "Still the best of them."
        )
        #expect(remote.review == "Still the best of them.")
    }

    @Test("Callers that predate the field still compile and mean nil")
    func reviewDefaultsToNil() {
        let remote = RemoteRankedItem(
            externalId: "603", mediaType: .movie, sentiment: .liked,
            title: "The Matrix", year: 1999, rankInBucket: 0,
            updatedAt: Date(timeIntervalSince1970: 1_000_000), posterPath: nil
        )
        #expect(remote.review == nil)
    }
}
