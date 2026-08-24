//
//  MockSocialFixtureTests.swift
//  BingedTests
//
//  The fixture behind `-uiTestingMockSocial`.
//
//  A fixture nobody asserts on is a fixture that rots quietly: a renamed field
//  or a changed threshold leaves it compiling and showing the wrong thing, and
//  the only symptom is a screen that looks plausible. These pin the states it
//  exists to put on screen — a populated feed, a thread with a deleted comment,
//  a bucket too small to have earned its number — so a change that empties one
//  of them fails here rather than in someone's eyes.
//

import Foundation
import Testing
@testable import Binged

@Suite("MockSocialFixture")
@MainActor
struct MockSocialFixtureTests {

    // MARK: Session

    @Test("comes up already signed in")
    func signedIn() async throws {
        let fixture = MockSocialFixture.seeded()
        let profile = try await fixture.auth.currentProfile()
        #expect(profile?.id == fixture.viewer.id)
        #expect(profile?.handle == "you")
    }

    @Test("the viewer follows people, so the feed is not the followingNobody state")
    func followsPeople() async throws {
        let fixture = MockSocialFixture.seeded()
        let followees = try await fixture.graph.following(of: fixture.viewer.id, limit: 10)
        #expect(followees.count == 3)
    }

    // MARK: The feed

    @Test("the feed loads posts, newest first")
    func feedIsPopulated() async throws {
        let fixture = MockSocialFixture.seeded()
        let viewModel = FeedViewModel(
            service: fixture.feed,
            social: fixture.graph,
            isSignedIn: { true },
            viewerID: { fixture.viewer.id }
        )
        await viewModel.refresh()

        #expect(viewModel.phase == .posts)
        #expect(viewModel.posts.count == 7)

        let dates = viewModel.posts.map(\.createdAt)
        let isDescending = zip(dates, dates.dropFirst()).allSatisfy { $0 >= $1 }
        #expect(isDescending)
    }

    @Test("every kind of post is represented")
    func coversEveryKind() async throws {
        let fixture = MockSocialFixture.seeded()
        let posts = try await fixture.feed.feed(before: nil, limit: 50)
        let kinds = Set(posts.map(\.kind))
        #expect(kinds == Set([.ranked, .wantToWatch, .reviewed]))
    }

    // MARK: Counts and reactions

    @Test("counts come from the seeded comments and reactions, and skip deletions")
    func countsAreRecomputed() async throws {
        let fixture = MockSocialFixture.seeded()
        let posts = try await fixture.feed.feed(before: nil, limit: 50)
        let dune = try #require(posts.first { $0.payload.title == "Dune: Part Two" })

        // Four comments seeded, one of them soft-deleted.
        #expect(dune.commentCount == 3)
        // Two other people plus the viewer.
        #expect(dune.reactionCount == 3)
        #expect(dune.viewerHasReacted)

        let comments = try await fixture.feed.comments(on: dune.id, limit: 50)
        #expect(comments.count == 4)
        #expect(comments.filter(\.isDeleted).count == 1)
    }

    @Test("a post the viewer has not reacted to reads as unreacted")
    func unreactedPost() async throws {
        let fixture = MockSocialFixture.seeded()
        let posts = try await fixture.feed.feed(before: nil, limit: 50)
        let midsommar = try #require(posts.first { $0.payload.title == "Midsommar" })
        #expect(!midsommar.viewerHasReacted)
        #expect(midsommar.reactionCount == 0)
    }

    // MARK: Rule 6

    @Test("a bucket of one publishes no position")
    func lonelyBucketWithholdsRank() async throws {
        let fixture = MockSocialFixture.seeded()
        let posts = try await fixture.feed.feed(before: nil, limit: 50)
        let midsommar = try #require(posts.first { $0.payload.title == "Midsommar" })
        #expect(midsommar.payload.bucketSize == 1)
        #expect(midsommar.rankDescription == nil)
    }

    @Test("a large bucket shows its scores and a small one withholds them")
    func publishedLibrariesStraddleTheThreshold() async throws {
        let fixture = MockSocialFixture.seeded()
        let followees = try await fixture.graph.following(of: fixture.viewer.id, limit: 10)

        let mina = try #require(followees.first { $0.handle == "mina" })
        let minaItems = try await fixture.rankings.rankedItems(userID: mina.id, offset: 0, limit: 50)
        #expect(!minaItems.isEmpty)
        let allScored = minaItems.allSatisfy { $0.displayScore != nil }
        #expect(allScored)

        let devon = try #require(followees.first { $0.handle == "devon" })
        let devonItems = try await fixture.rankings.rankedItems(userID: devon.id, offset: 0, limit: 50)
        #expect(!devonItems.isEmpty)
        let noneScored = devonItems.allSatisfy { $0.displayScore == nil }
        #expect(noneScored)
    }

    @Test("scores stay inside their sentiment's range")
    func scoresAreInRange() async throws {
        let fixture = MockSocialFixture.seeded()
        let followees = try await fixture.graph.following(of: fixture.viewer.id, limit: 10)
        let mina = try #require(followees.first { $0.handle == "mina" })
        let items = try await fixture.rankings.rankedItems(userID: mina.id, offset: 0, limit: 50)

        let inRange = items.allSatisfy { $0.sentiment.scoreRange.contains($0.score) }
        #expect(inRange)
    }

    @Test("a private library reads as empty, the way row-level security answers it")
    func privateLibraryIsEmpty() async throws {
        let fixture = MockSocialFixture.seeded()
        let followees = try await fixture.graph.following(of: fixture.viewer.id, limit: 10)
        let sasha = try #require(followees.first { $0.handle == "sasha" })
        let items = try await fixture.rankings.rankedItems(userID: sasha.id, offset: 0, limit: 50)
        #expect(items.isEmpty)
    }

    // MARK: Discovery

    @Test("somebody remains unfollowed, so the follow button has work to do")
    func aStrangerExists() async throws {
        let fixture = MockSocialFixture.seeded()
        let found = try await fixture.graph.searchUsers(query: "theo", limit: 10)
        let stranger = try #require(found.first)
        let relationship = try await fixture.graph.relationship(with: stranger.id)
        #expect(relationship.state == .none)
    }
}
