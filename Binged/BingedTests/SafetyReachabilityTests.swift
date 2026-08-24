//
//  SafetyReachabilityTests.swift
//  BingedTests
//
//  The safety obligations that come with user-generated content: reporting,
//  blocking, and saying so when either fails.
//
//  **Why this file exists.** The gap audit found `ReportSheet` and every block
//  path fully implemented, fully unit-tested, and reachable from nowhere — the
//  suite covered the view models and stopped exactly at the wiring. Tests
//  cannot press a button, so these assert the layer directly underneath one:
//  that the view model a control calls does the thing, and that a failure
//  becomes a message rather than silence.
//

import Foundation
import Testing
@testable import Binged

// MARK: - Stubs

private final class StubFeedService: FeedService, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reports: [(target: ReportTarget, reason: ReportReason, note: String?)] = []
    var reportFailure: Error?
    var page: [FeedPost] = []

    func feed(before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] {
        cursor == nil ? page : []
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

    func deleteComment(_ commentID: UUID) async throws {}

    func report(_ target: ReportTarget, reason: ReportReason, note: String?) async throws {
        if let reportFailure { throw reportFailure }
        lock.lock(); reports.append((target, reason, note)); lock.unlock()
    }
}

/// Blocks always fail. Used to prove the failure is surfaced, not swallowed.
/// Standalone rather than a subclass — `MockSocialService` is `final`.
private final class FailingSocialService: SocialService, @unchecked Sendable {
    func searchUsers(query: String, limit: Int) async throws -> [UserProfile] { [] }
    func profile(handle: String) async throws -> UserProfile? { nil }
    func relationship(with userID: UUID) async throws -> SocialRelationship { .unknown }
    func follow(_ userID: UUID) async throws -> FollowState { .none }
    func unfollow(_ userID: UUID) async throws {}
    func pendingRequests() async throws -> [UserProfile] { [] }
    func acceptRequest(from userID: UUID) async throws {}
    func rejectRequest(from userID: UUID) async throws {}
    func followers(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
    func following(of userID: UUID, limit: Int) async throws -> [UserProfile] { [] }
    func unblock(_ userID: UUID) async throws {}
    func blockedAccounts() async throws -> [UserProfile] { [] }

    func block(_ userID: UUID) async throws {
        throw SupabaseError.transport("offline")
    }
}

private func makePost(author: UUID, title: String = "Dune") -> FeedPost {
    FeedPost(
        id: UUID(), authorID: author, kind: .ranked, createdAt: .now,
        authorHandle: "alex", authorDisplayName: "Alex", authorAvatarURL: nil,
        payload: .init(
            externalId: "tmdb:movie:1", title: title, year: 2024, mediaType: .movie,
            sentiment: .liked, rankInBucket: 0, bucketSize: 8, reviewExcerpt: nil
        ),
        commentCount: 0, reactionCount: 0, viewerHasReacted: false
    )
}

// MARK: - Reporting

@Suite("Reporting")
@MainActor
struct ReportingTests {

    @Test("A report from the feed reaches the service with its reason intact")
    func reportFromFeed() async throws {
        let feed = StubFeedService()
        let target = ReportTarget.post(UUID())
        let viewModel = FeedViewModel(
            service: feed, social: MockSocialService(), isSignedIn: { true }
        )

        await viewModel.report(target, reason: .harassment, note: "context")

        #expect(feed.reports.count == 1)
        #expect(feed.reports.first?.target == target)
        #expect(feed.reports.first?.reason == .harassment)
        #expect(feed.reports.first?.note == "context")
    }

    @Test("A failed report says so rather than pretending it worked")
    func failedReportIsSurfaced() async throws {
        let feed = StubFeedService()
        feed.reportFailure = SupabaseError.transport("offline")
        let viewModel = FeedViewModel(
            service: feed, social: MockSocialService(), isSignedIn: { true }
        )

        await viewModel.report(.post(UUID()), reason: .spam, note: nil)

        // The sentence, not the case dump. A reader offline previously saw
        // `transport("Could not reach the server.")`.
        #expect(viewModel.lastError == "Could not reach the server.")
    }
}

// MARK: - Blocking

@Suite("Blocking")
@MainActor
struct BlockingTests {

    @Test("Blocking drops everything of theirs already on screen, and nothing else")
    func blockClearsTheirPosts() async throws {
        let offender = UUID()
        let bystander = UUID()
        let feed = StubFeedService()
        feed.page = [
            makePost(author: offender, title: "One"),
            makePost(author: bystander, title: "Two"),
            makePost(author: offender, title: "Three"),
        ]
        let viewModel = FeedViewModel(
            service: feed, social: MockSocialService(), isSignedIn: { true }
        )
        await viewModel.refresh()
        #expect(viewModel.posts.count == 3)

        await viewModel.block(makePost(author: offender))

        // Leaving their posts visible after a block reads as the block having
        // failed, whatever the server did.
        let remaining = viewModel.posts
        #expect(remaining.count == 1)
        #expect(remaining.first?.authorID == bystander)
        #expect(viewModel.lastError == nil)
    }

    @Test("Blocking the last visible author leaves a quiet feed, not an empty list")
    func blockingEveryoneIsQuietNotBroken() async throws {
        let offender = UUID()
        let feed = StubFeedService()
        feed.page = [makePost(author: offender)]
        let viewModel = FeedViewModel(
            service: feed, social: MockSocialService(), isSignedIn: { true }
        )
        await viewModel.refresh()

        await viewModel.block(makePost(author: offender))

        // Not `followingNobody` — they may follow other people who simply have
        // nothing on this page.
        #expect(viewModel.phase == .quiet)
    }

    @Test("A failed block is reported, and their posts stay put")
    func failedBlockIsSurfaced() async throws {
        let offender = UUID()
        let feed = StubFeedService()
        feed.page = [makePost(author: offender)]
        let viewModel = FeedViewModel(
            service: feed, social: FailingSocialService(), isSignedIn: { true }
        )
        await viewModel.refresh()

        await viewModel.block(makePost(author: offender))

        #expect(viewModel.lastError == "Could not reach the server.")
        // Removing them locally after a failed block would be a lie: the next
        // refresh brings them straight back.
        #expect(viewModel.posts.count == 1)
    }

    @Test("A post thread offers blocking only when there is a service to block with")
    func blockIsOfferedOnlyWhenAvailable() async throws {
        let feed = StubFeedService()
        let post = makePost(author: UUID())

        let withSocial = PostViewModel(
            post: post, service: feed, viewerID: UUID(), social: MockSocialService()
        )
        let withoutSocial = PostViewModel(post: post, service: feed, viewerID: UUID())

        #expect(withSocial.canBlock)
        #expect(!withoutSocial.canBlock)
    }

    @Test("Blocking from a thread flags the view to leave it")
    func blockingFromThreadDismisses() async throws {
        let feed = StubFeedService()
        let post = makePost(author: UUID())
        let viewModel = PostViewModel(
            post: post, service: feed, viewerID: UUID(), social: MockSocialService()
        )
        #expect(!viewModel.didBlock)

        await viewModel.block(post.authorID)

        // Staying on the thread would be the app arguing with the button.
        #expect(viewModel.didBlock)
    }
}

// MARK: - Error wording

@Suite("Error wording")
struct ErrorMessageTests {

    @Test("Known errors speak their own sentence")
    func knownErrorsAreReadable() {
        #expect(ErrorMessage.text(for: SocialError.cannotFollowSelf) == "You cannot follow yourself.")
        #expect(ErrorMessage.text(for: SupabaseError.unauthorized) == "Your session has expired. Sign in again.")
    }

    @Test("A transport failure does not leak its Swift case")
    func transportIsNotACaseDump() {
        let text = ErrorMessage.text(for: SupabaseError.transport("NSURLErrorDomain -1009"))
        #expect(text == "Could not reach the server.")
        #expect(!text.contains("transport("))
    }
}
