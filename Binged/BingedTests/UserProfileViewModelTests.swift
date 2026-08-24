//
//  UserProfileViewModelTests.swift
//  BingedTests
//
//  Someone else's ranking. The rule that matters most is rule 6 — an unearned
//  score is no more publishable than it is displayable.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Helpers

private func rankedItem(
    _ title: String, rank: Int, bucketSize: Int,
    sentiment: Sentiment = .liked, type: MediaType = .movie
) -> RankedItem {
    let scores = RankingEngine.scores(count: bucketSize, range: sentiment.scoreRange)
    return RankedItem(
        externalId: "tmdb:movie:\(abs(title.hashValue % 99999))",
        mediaType: type, sentiment: sentiment, title: title, year: 2020,
        score: scores[min(rank, scores.count - 1)],
        rankInBucket: rank, bucketSize: bucketSize
    )
}

private func person(_ handle: String, isPrivate: Bool = false) -> UserProfile {
    UserProfile(id: UUID(), handle: handle, displayName: handle.capitalized, bio: nil,
                avatarURL: nil, isPrivate: isPrivate, createdAt: .now)
}

// MARK: - Rule 6

@Suite("Rule 6 travels with a published ranking")
struct PublishedRuleSixTests {

    @Test("A score from a bucket below the threshold is withheld")
    func smallBucketsShowPosition() {
        // Showing a stranger's 8.4 from a bucket of one is the same unearned
        // precision the ranking system refuses to show locally — publishing it
        // makes it worse, not better.
        let threshold = MediaLibraryViewModel.minimumBucketSizeForScore

        for size in 1..<threshold {
            let item = rankedItem("Small", rank: 0, bucketSize: size)
            #expect(item.displayScore == nil, "a bucket of \(size) showed a number")
            #expect(item.positionDescription.contains("#1"))
        }
    }

    @Test("At the threshold the number appears")
    func fullBucketsShowScores() {
        let threshold = MediaLibraryViewModel.minimumBucketSizeForScore
        let item = rankedItem("Big", rank: 0, bucketSize: threshold)
        #expect(item.displayScore != nil)
    }

    @Test("The threshold is the same one the owner's device applies")
    func thresholdMatchesLocal() {
        // A title must read identically on their screen and on a stranger's.
        // If these ever diverge, one of the two is lying.
        let size = MediaLibraryViewModel.minimumBucketSizeForScore
        #expect(rankedItem("X", rank: 0, bucketSize: size).displayScore != nil)
        #expect(rankedItem("X", rank: 0, bucketSize: size - 1).displayScore == nil)
    }

    @Test("Buckets group like the local Ranking screen")
    func bucketing() {
        let items = [
            rankedItem("A", rank: 0, bucketSize: 2, sentiment: .liked),
            rankedItem("B", rank: 1, bucketSize: 2, sentiment: .liked),
            rankedItem("C", rank: 0, bucketSize: 1, sentiment: .fine),
            rankedItem("D", rank: 0, bucketSize: 1, sentiment: .liked, type: .tvShow),
        ]

        let movies = items.bucketed(type: .movie)
        #expect(movies.count == 2)
        #expect(movies.first?.sentiment == .liked)
        #expect(movies.first?.items.map(\.rankInBucket) == [0, 1])

        #expect(items.bucketed(type: .tvShow).count == 1)
    }
}

// MARK: - View model

@Suite("UserProfileViewModel")
@MainActor
struct UserProfileViewModelTests {

    @Test("A public profile loads its ranking")
    func loadsPublicProfile() async {
        let alex = person("alex")
        let social = MockSocialService(people: [alex])
        let rankings = MockRankingFeedService()
        rankings.set((0..<6).map { rankedItem("T\($0)", rank: $0, bucketSize: 6) }, for: alex.id)

        let viewModel = UserProfileViewModel(social: social, rankings: rankings)
        await viewModel.load(handle: "alex")

        #expect(viewModel.phase == .loaded)
        #expect(viewModel.items.count == 6)
        #expect(viewModel.stats.total == 6)
    }

    @Test("A private, unfollowed account renders the private state and returns nothing")
    func privateAccountIsEmpty() async {
        // The emptiness comes from row-level security, not from a client
        // filter — the mock hides it the same way the policy does.
        let sam = person("sam", isPrivate: true)
        let social = MockSocialService(people: [sam])
        let rankings = MockRankingFeedService()
        rankings.set([rankedItem("Secret", rank: 0, bucketSize: 6)], for: sam.id, visible: false)

        let viewModel = UserProfileViewModel(social: social, rankings: rankings)
        await viewModel.load(handle: "sam")

        #expect(viewModel.phase == .privateAccount)
        #expect(viewModel.items.isEmpty)
    }

    @Test("A blocked account is indistinguishable from one that does not exist")
    func blockedLooksMissing() async {
        let ghost = person("ghost")
        let social = MockSocialService(people: [ghost])
        try? await social.block(ghost.id)

        let viewModel = UserProfileViewModel(social: social, rankings: MockRankingFeedService())
        await viewModel.load(handle: "ghost")

        #expect(viewModel.phase == .notFound)
    }

    @Test("An unknown handle is not found")
    func unknownHandle() async {
        let viewModel = UserProfileViewModel(
            social: MockSocialService(), rankings: MockRankingFeedService()
        )
        await viewModel.load(handle: "nobody")
        #expect(viewModel.phase == .notFound)
    }

    @Test("A large library pages rather than arriving at once")
    func paginates() async {
        // A 500-title library in one request is a slow screen and a rude query.
        let alex = person("alex")
        let social = MockSocialService(people: [alex])
        let rankings = MockRankingFeedService()
        let size = UserProfileViewModel.pageSize
        rankings.set((0..<(size + 40)).map { rankedItem("T\($0)", rank: $0, bucketSize: size + 40) },
                     for: alex.id)

        let viewModel = UserProfileViewModel(social: social, rankings: rankings)
        await viewModel.load(handle: "alex")

        #expect(viewModel.items.count == size)
        #expect(viewModel.hasMore)

        await viewModel.loadMore()
        #expect(viewModel.items.count == size + 40)
        #expect(!viewModel.hasMore)

        // Past the end is a no-op, not a duplicate page.
        await viewModel.loadMore()
        #expect(viewModel.items.count == size + 40)
    }

    @Test("Following a private account does not immediately reveal it")
    func followingPrivateStaysHidden() async {
        let sam = person("sam", isPrivate: true)
        let social = MockSocialService(people: [sam])
        let rankings = MockRankingFeedService()
        rankings.set([rankedItem("Secret", rank: 0, bucketSize: 6)], for: sam.id, visible: false)

        let viewModel = UserProfileViewModel(social: social, rankings: rankings)
        await viewModel.load(handle: "sam")
        await viewModel.toggleFollow()

        #expect(viewModel.relationship.state == .pending)
        #expect(viewModel.items.isEmpty, "a pending follower saw a private library")
    }

    @Test("A failed follow rolls back")
    func followRollsBack() async {
        let alex = person("alex")
        let social = MockSocialService(people: [alex])
        let rankings = MockRankingFeedService()
        rankings.set([], for: alex.id)

        let viewModel = UserProfileViewModel(social: social, rankings: rankings)
        await viewModel.load(handle: "alex")
        try? await social.block(alex.id)   // now every follow fails

        await viewModel.toggleFollow()
        #expect(viewModel.relationship.state != .active, "a phantom follow survived")
    }

    @Test("Stats and top five count only what the viewer can see")
    func statsReflectVisibility() async {
        let alex = person("alex")
        let social = MockSocialService(people: [alex])
        let rankings = MockRankingFeedService()
        rankings.set([
            rankedItem("Film", rank: 0, bucketSize: 6),
            rankedItem("Show", rank: 0, bucketSize: 6, type: .tvShow),
        ], for: alex.id)

        let viewModel = UserProfileViewModel(social: social, rankings: rankings)
        await viewModel.load(handle: "alex")

        #expect(viewModel.stats.movies == 1)
        #expect(viewModel.stats.shows == 1)
        #expect(viewModel.topFive.count == 2)
    }
}
