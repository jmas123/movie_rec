//
//  MockSocialFixture.swift
//  WatchRank
//
//  A populated social world, in memory, with no server behind it.
//
//  **Why this exists.** The feed cannot be looked at without two accounts: a
//  feed page is drawn from people you follow, and the schema forbids following
//  yourself (`follows_no_self`). So the one thing a solo developer cannot do
//  against a real Supabase project is see a populated feed — which is precisely
//  the screen most in need of looking at. This builds that world out of the
//  same `Mock…` services the tests run against, seeded with people, posts,
//  comments and reactions.
//
//  Reached by launching with `-uiTestingMockSocial`; see
//  `WatchRankApp.mockSocialArgument`. Nothing here is used on a normal launch.
//
//  It is a *fixture*, not a fake server: the data is fixed, the ids are fresh
//  each launch, and nothing survives a relaunch. Anything that must persist,
//  or that must prove the client and the RLS policies agree, needs the real
//  project and two real accounts (roadmap Phase 29, step 7).
//

import Foundation

// MARK: - MockSocialFixture

struct MockSocialFixture {

    /// The signed-in user. `SessionViewModel.restore` finds them already
    /// signed in, so the app opens past the sign-in screen.
    let viewer: UserProfile

    let auth: MockAuthService
    let graph: MockSocialService
    let feed: MockFeedService
    let rankings: MockRankingFeedService

    // MARK: Building

    static func seeded() -> MockSocialFixture {
        let viewer = person("you", "You", bio: "Ranking things since Tuesday.")
        let mina = person("mina", "Mina Okafor", bio: "Films mostly. Shows when the films run out.")
        let devon = person("devon", "Devon Reyes", bio: nil)
        let sasha = person("sasha", "Sasha Bell", bio: "Will defend anything with a submarine in it.")
        let stranger = person("theo", "Theo Lindqvist", bio: "Not followed, on purpose.")

        let graph = MockSocialService(
            viewer: viewer.id, people: [viewer, mina, devon, sasha, stranger]
        )
        // The viewer follows three of the four. `stranger` stays unfollowed so
        // the Follow button has something to act on, and so user search returns
        // somebody who is not already in the feed.
        for person in [mina, devon, sasha] {
            graph.seedFollow(viewer.id, follows: person.id)
        }
        // Followed back, so the "Follows you" badge is exercised, and so the
        // follower list on the viewer's own profile is not empty.
        graph.seedFollow(mina.id, follows: viewer.id)
        graph.seedFollow(sasha.id, follows: viewer.id)

        let feed = MockFeedService(viewer: viewer.id)
        seedPosts(into: feed, mina: mina, devon: devon, sasha: sasha, viewer: viewer)

        let rankings = MockRankingFeedService()
        rankings.set(minaLibrary, for: mina.id)
        rankings.set(devonLibrary, for: devon.id)
        // Private: RLS answers an unauthorised read with zero rows, and
        // `UserProfileView` renders empty-and-not-following as the private
        // state. Seeding one this way keeps that path reachable.
        rankings.set(sashaLibrary, for: sasha.id, visible: false)

        return MockSocialFixture(
            viewer: viewer,
            auth: MockAuthService(signedInAs: viewer),
            graph: graph,
            feed: feed,
            rankings: rankings
        )
    }

    // MARK: People

    private static func person(
        _ handle: String, _ displayName: String?, bio: String?
    ) -> UserProfile {
        UserProfile(
            id: UUID(), handle: handle, displayName: displayName, bio: bio,
            avatarURL: nil, isPrivate: false,
            createdAt: Date(timeIntervalSinceNow: -60 * 60 * 24 * 200)
        )
    }

    // MARK: Posts

    /// Seven posts across the three followees, deliberately covering every
    /// shape the feed has to render: all three `Kind`s, both media types, a
    /// bucket too small for a rank (rule 6), a thread with replies, a post the
    /// viewer has already reacted to, and one with nothing on it at all.
    private static func seedPosts(
        into feed: MockFeedService,
        mina: UserProfile, devon: UserProfile, sasha: UserProfile, viewer: UserProfile
    ) {
        let dune = post(
            by: mina, kind: .ranked, minutesAgo: 40,
            payload: payload("438631", "Dune: Part Two", 2024, .movie,
                             sentiment: .liked, rank: 0, bucketSize: 12)
        )
        let severance = post(
            by: devon, kind: .ranked, minutesAgo: 3 * 60,
            payload: payload("95396", "Severance", 2022, .tvShow,
                             sentiment: .liked, rank: 2, bucketSize: 9)
        )
        // bucketSize 1 — `rankDescription` withholds the position, because
        // "#1 of 1" is not a ranking.
        let lonely = post(
            by: sasha, kind: .ranked, minutesAgo: 7 * 60,
            payload: payload("530385", "Midsommar", 2019, .movie,
                             sentiment: .fine, rank: 0, bucketSize: 1)
        )
        let wanted = post(
            by: mina, kind: .wantToWatch, minutesAgo: 26 * 60,
            payload: payload("507089", "Five Nights at Freddy's", 2023, .movie,
                             sentiment: nil, rank: nil, bucketSize: nil)
        )
        let reviewed = post(
            by: sasha, kind: .reviewed, minutesAgo: 30 * 60,
            payload: payload("1399", "Game of Thrones", 2011, .tvShow,
                             sentiment: .fine, rank: 5, bucketSize: 8,
                             review: "Eight seasons and I still think about the "
                                   + "first six more than the last two.")
        )
        let disliked = post(
            by: devon, kind: .ranked, minutesAgo: 49 * 60,
            payload: payload("447365", "Guardians of the Galaxy Vol. 3", 2023, .movie,
                             sentiment: .disliked, rank: 1, bucketSize: 5)
        )
        let older = post(
            by: mina, kind: .ranked, minutesAgo: 96 * 60,
            payload: payload("496243", "Parasite", 2019, .movie,
                             sentiment: .liked, rank: 1, bucketSize: 12)
        )

        for entry in [dune, severance, lonely, wanted, reviewed, disliked, older] {
            feed.seed(entry)
        }

        // A thread worth scrolling: two voices, and one deleted comment so the
        // soft-delete rendering ("Comment deleted") is on screen rather than
        // only in a test.
        feed.seedComment(comment(on: dune, by: devon, minutesAgo: 30,
                                 "The theatre shook. I have no notes."))
        feed.seedComment(comment(on: dune, by: sasha, minutesAgo: 22,
                                 "Above Part One? Genuinely?"))
        feed.seedComment(comment(on: dune, by: mina, minutesAgo: 18,
                                 "Genuinely. It earns the ending."))
        feed.seedComment(comment(on: dune, by: sasha, minutesAgo: 12,
                                 "Withdrawn.", deletedMinutesAgo: 9))
        feed.seedComment(comment(on: severance, by: mina, minutesAgo: 2 * 60,
                                 "Third is low. It's a top-of-the-list show."))

        // Reactions from other people, so a count can be something other than
        // 0 or 1 — and one the viewer has already made, so the filled state is
        // visible without tapping.
        for reactor in [devon.id, sasha.id] { feed.seedReaction(on: dune.id, by: reactor) }
        feed.seedReaction(on: dune.id, by: viewer.id)
        feed.seedReaction(on: severance.id, by: sasha.id)
        feed.seedReaction(on: reviewed.id, by: mina.id)
        feed.seedReaction(on: older.id, by: viewer.id)
    }

    private static func post(
        by author: UserProfile,
        kind: FeedPost.Kind,
        minutesAgo: Double,
        payload: FeedPost.Payload
    ) -> FeedPost {
        FeedPost(
            id: UUID(),
            authorID: author.id,
            kind: kind,
            createdAt: Date(timeIntervalSinceNow: -minutesAgo * 60),
            authorHandle: author.handle,
            authorDisplayName: author.displayName,
            authorAvatarURL: nil,
            payload: payload,
            // Counts are trigger-maintained on the server and recomputed by the
            // mock on read, so what is stored here is never what is displayed.
            commentCount: 0,
            reactionCount: 0,
            viewerHasReacted: false
        )
    }

    private static func payload(
        _ externalId: String, _ title: String, _ year: Int, _ type: MediaType,
        sentiment: Sentiment?, rank: Int?, bucketSize: Int?, review: String? = nil
    ) -> FeedPost.Payload {
        FeedPost.Payload(
            externalId: externalId, title: title, year: year, mediaType: type,
            sentiment: sentiment, rankInBucket: rank, bucketSize: bucketSize,
            reviewExcerpt: review
        )
    }

    private static func comment(
        on post: FeedPost, by author: UserProfile, minutesAgo: Double,
        _ body: String, deletedMinutesAgo: Double? = nil
    ) -> PostComment {
        PostComment(
            id: UUID(),
            postID: post.id,
            authorID: author.id,
            body: body,
            createdAt: Date(timeIntervalSinceNow: -minutesAgo * 60),
            deletedAt: deletedMinutesAgo.map { Date(timeIntervalSinceNow: -$0 * 60) },
            authorHandle: author.handle,
            authorDisplayName: author.displayName,
            authorAvatarURL: nil
        )
    }

    // MARK: Published libraries

    /// Twelve titles, so the bucket clears
    /// `minimumBucketSizeForScore` and the profile shows real numbers.
    private static var minaLibrary: [RankedItem] {
        let titles: [(String, String, Int, MediaType)] = [
            ("438631", "Dune: Part Two", 2024, .movie),
            ("496243", "Parasite", 2019, .movie),
            ("155", "The Dark Knight", 2008, .movie),
            ("13", "Forrest Gump", 1994, .movie),
            ("372058", "Your Name.", 2016, .movie),
            ("324857", "Spider-Man: Into the Spider-Verse", 2018, .movie),
        ]
        return bucket(titles, sentiment: .liked, size: 12)
    }

    /// Three titles — below the threshold, so the profile shows positions and
    /// withholds the numbers. The same rule the owner's own screen applies.
    private static var devonLibrary: [RankedItem] {
        let titles: [(String, String, Int, MediaType)] = [
            ("95396", "Severance", 2022, .tvShow),
            ("1396", "Breaking Bad", 2008, .tvShow),
            ("60625", "Rick and Morty", 2013, .tvShow),
        ]
        return bucket(titles, sentiment: .fine, size: 3)
    }

    private static var sashaLibrary: [RankedItem] {
        let titles: [(String, String, Int, MediaType)] = [
            ("1399", "Game of Thrones", 2011, .tvShow),
            ("530385", "Midsommar", 2019, .movie),
        ]
        return bucket(titles, sentiment: .fine, size: 2)
    }

    /// Scores by the same quantile inset `RankingEngine` uses, so a fixture can
    /// never show a distribution the real engine would not produce.
    private static func bucket(
        _ titles: [(String, String, Int, MediaType)], sentiment: Sentiment, size: Int
    ) -> [RankedItem] {
        let range = sentiment.scoreRange
        let span = range.upperBound - range.lowerBound
        return titles.enumerated().map { index, entry in
            RankedItem(
                externalId: entry.0,
                mediaType: entry.3,
                sentiment: sentiment,
                title: entry.1,
                year: entry.2,
                score: range.upperBound - ((Double(index) + 0.5) / Double(size)) * span,
                rankInBucket: index,
                bucketSize: size
            )
        }
    }
}
