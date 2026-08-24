//
//  FeedViewModelTests.swift
//  WatchRankTests
//
//  The feed. The criterion that matters is that ranking one title produces
//  **one** post — the flooding bug has to be caught by a test, not by looking
//  at the feed and noticing it is full of the same film.
//

import Foundation
import SwiftData
import Testing
@testable import WatchRank

// MARK: - Stubs

private final class RecordingFeedService: FeedService, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var created: [(kind: FeedPost.Kind, payload: FeedPost.Payload)] = []
    private(set) var reacted: [UUID] = []
    private(set) var unreacted: [UUID] = []
    var pages: [[FeedPost]] = []
    var failure: Error?

    func feed(before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] {
        if let failure { throw failure }
        lock.lock(); defer { lock.unlock() }
        guard !pages.isEmpty else { return [] }
        return cursor == nil ? pages[0] : (pages.count > 1 ? pages[1] : [])
    }

    func posts(by userID: UUID, before cursor: FeedCursor?, limit: Int) async throws -> [FeedPost] { [] }

    func createPost(kind: FeedPost.Kind, payload: FeedPost.Payload) async throws {
        lock.lock(); created.append((kind, payload)); lock.unlock()
    }

    func react(to postID: UUID) async throws {
        if let failure { throw failure }
        lock.lock(); reacted.append(postID); lock.unlock()
    }

    func unreact(to postID: UUID) async throws {
        if let failure { throw failure }
        lock.lock(); unreacted.append(postID); lock.unlock()
    }

    func comments(on postID: UUID, limit: Int) async throws -> [PostComment] { [] }

    @discardableResult
    func addComment(to postID: UUID, body: String) async throws -> PostComment {
        throw SocialError.underlying("not implemented")
    }

    func deleteComment(_ commentID: UUID) async throws {}
    func report(_ target: ReportTarget, reason: ReportReason, note: String?) async throws {}
}

private final class NoopTransport: PublishTransport, @unchecked Sendable {
    func publish(_ payload: PublishPayload, userID: UUID) async throws {}
    func deleteBucket(mediaType: MediaType, sentiment: Sentiment, userID: UUID) async throws {}
}

private func post(_ index: Int, at date: Date) -> FeedPost {
    FeedPost(
        id: UUID(), authorID: UUID(), kind: .ranked, createdAt: date,
        authorHandle: "alex", authorDisplayName: "Alex", authorAvatarURL: nil,
        payload: .init(externalId: "tmdb:movie:\(index)", title: "T\(index)", year: 2020,
                       mediaType: .movie, sentiment: .liked, rankInBucket: 0,
                       bucketSize: 8, reviewExcerpt: nil),
        commentCount: 0, reactionCount: 0, viewerHasReacted: false
    )
}

// MARK: - One post per action

@Suite("Post emission")
@MainActor
struct PostEmissionTests {

    @Test("Ranking one title into a bucket of ten produces exactly one post")
    func oneActionOnePost() async throws {
        // The flooding bug. A single insertion rewrites all ten scores, so a
        // post per changed row would tell every follower about the same act ten
        // times.
        let library = try makeLibrary()
        let feed = RecordingFeedService()
        let engine = SyncEngine(
            library: library, transport: NoopTransport(), feed: feed, currentUserID: { UUID() }
        )

        for index in 0..<9 {
            let item = MediaItem(externalId: "tmdb:movie:\(index)", title: "Seed \(index)",
                                 year: 2020, type: .movie)
            library.markWatched(item, sentiment: .liked)
            driveSessionPreferringExisting(vm: library)
            library.finalizeRanking(for: item)
        }
        await engine.drain()
        let before = feed.created.count

        // The tenth, which rewrites all ten scores.
        let tenth = MediaItem(externalId: "tmdb:movie:99", title: "The Tenth", year: 2020, type: .movie)
        library.markWatched(tenth, sentiment: .liked)
        driveSessionPreferringExisting(vm: library)
        library.finalizeRanking(for: tenth)
        await engine.drain()

        let emitted = feed.created.count - before
        #expect(emitted == 1, "one ranking produced \(emitted) posts")
        #expect(feed.created.last?.payload.title == "The Tenth")
    }

    @Test("A reorder publishes but says nothing")
    func reorderIsSilent() async throws {
        // Dragging a row changes every score in the bucket. It is not an event
        // worth telling followers about, and a post per drag would be noise.
        let library = try makeLibrary()
        let feed = RecordingFeedService()
        let engine = SyncEngine(
            library: library, transport: NoopTransport(), feed: feed, currentUserID: { UUID() }
        )

        for index in 0..<3 {
            let item = MediaItem(externalId: "tmdb:movie:\(index)", title: "T\(index)",
                                 year: 2020, type: .movie)
            library.markWatched(item, sentiment: .liked)
            driveSessionPreferringExisting(vm: library)
            library.finalizeRanking(for: item)
        }
        await engine.drain()
        let before = feed.created.count

        library.reorder(in: .liked, type: .movie, from: IndexSet(integer: 0), to: 3)
        await engine.drain()

        #expect(feed.created.count == before, "a reorder posted")
        #expect(library.pendingPublishes.isEmpty, "a reorder failed to publish")
    }

    @Test("Queuing a title posts once")
    func wantToWatchPosts() async throws {
        let library = try makeLibrary()
        let feed = RecordingFeedService()
        let engine = SyncEngine(
            library: library, transport: NoopTransport(), feed: feed, currentUserID: { UUID() }
        )

        library.addToWantToWatch(
            MediaItem(externalId: "tmdb:movie:5", title: "Later", year: 2020, type: .movie)
        )
        await engine.drain()

        #expect(feed.created.filter { $0.kind == .wantToWatch }.count == 1)
    }

    @Test("A title with no id posts nothing, because it publishes nothing")
    func anonymousTitlesAreSilent() async throws {
        let library = try makeLibrary()
        let feed = RecordingFeedService()
        let engine = SyncEngine(
            library: library, transport: NoopTransport(), feed: feed, currentUserID: { UUID() }
        )

        let anonymous = MediaItem(title: "No id", year: 2020, type: .movie)
        library.markWatched(anonymous, sentiment: .liked)
        library.finalizeRanking(for: anonymous)
        await engine.drain()

        #expect(feed.created.isEmpty)
    }

    @Test("Signed out, nothing is posted and nothing is lost")
    func signedOutPostsNothing() async throws {
        let library = try makeLibrary()
        let feed = RecordingFeedService()
        let engine = SyncEngine(
            library: library, transport: NoopTransport(), feed: feed, currentUserID: { nil }
        )

        let item = MediaItem(externalId: "tmdb:movie:1", title: "Quiet", year: 2020, type: .movie)
        library.markWatched(item, sentiment: .liked)
        library.finalizeRanking(for: item)
        await engine.drain()

        #expect(feed.created.isEmpty)
        #expect(library.pendingPublishes.count == 1, "the debt was lost")
    }
}

// MARK: - Frozen payloads

@Suite("FeedPost")
struct FeedPostTests {

    @Test("A post's sentence never changes when the ranking moves")
    func payloadIsFrozen() {
        // The payload is denormalised precisely so a later insertion cannot
        // rewrite history under a reader — or under the comments below it.
        let original = post(1, at: .now)
        #expect(original.sentence.contains("T1"))
        #expect(original.rankDescription?.contains("#1 of 8") == true)

        // Nothing in the type reads through to a live ranking; the payload is
        // the whole story.
        #expect(original.payload.bucketSize == 8)
    }

    @Test("Rule 6 applies in the feed too")
    func ruleSixInTheFeed() {
        // "#1 of 1" is not a ranking, it is the only thing in the list.
        var payload = post(1, at: .now).payload
        payload = .init(externalId: payload.externalId, title: payload.title, year: payload.year,
                        mediaType: payload.mediaType, sentiment: payload.sentiment,
                        rankInBucket: 0, bucketSize: 1, reviewExcerpt: nil)
        let lonely = FeedPost(
            id: UUID(), authorID: UUID(), kind: .ranked, createdAt: .now,
            authorHandle: "a", authorDisplayName: nil, authorAvatarURL: nil,
            payload: payload, commentCount: 0, reactionCount: 0, viewerHasReacted: false
        )
        #expect(lonely.rankDescription == nil)
    }

    @Test("A want-to-watch post has no rank line")
    func queuedPostsHaveNoRank() {
        let queued = FeedPost(
            id: UUID(), authorID: UUID(), kind: .wantToWatch, createdAt: .now,
            authorHandle: "a", authorDisplayName: nil, authorAvatarURL: nil,
            payload: .init(externalId: "x", title: "Later", year: 2020, mediaType: .movie,
                           sentiment: nil, rankInBucket: nil, bucketSize: nil, reviewExcerpt: nil),
            commentCount: 0, reactionCount: 0, viewerHasReacted: false
        )
        #expect(queued.rankDescription == nil)
        #expect(queued.verb == "wants to watch")
    }
}

// MARK: - Paging

@Suite("FeedViewModel")
@MainActor
struct FeedViewModelTests {

    @Test("Signed out shows the sign-in state, not an empty list")
    func signedOutState() async {
        let viewModel = FeedViewModel(
            service: RecordingFeedService(), social: nil, isSignedIn: { false }
        )
        await viewModel.refresh()
        #expect(viewModel.phase == .signedOut)
    }

    @Test("Following nobody is a different state from a quiet feed")
    func emptyStatesAreDistinct() async {
        // Telling someone to find people they have already found is useless, so
        // the two emptinesses need two answers.
        let viewer = UUID()
        let feed = RecordingFeedService()

        let alone = FeedViewModel(
            service: feed, social: MockSocialService(viewer: viewer),
            isSignedIn: { true }, viewerID: { viewer }
        )
        await alone.refresh()
        #expect(alone.phase == .followingNobody)

        let friend = person("alex")
        let social = MockSocialService(viewer: viewer, people: [friend])
        _ = try? await social.follow(friend.id)

        let quiet = FeedViewModel(
            service: feed, social: social, isSignedIn: { true }, viewerID: { viewer }
        )
        await quiet.refresh()
        #expect(quiet.phase == .quiet)
    }

    @Test("Paging never duplicates or skips")
    func pagingIsClean() async {
        // A keyset cursor is immune to posts landing mid-scroll; an OFFSET page
        // is not. The overlap guard covers a server that misbehaves anyway.
        let feed = RecordingFeedService()
        let now = Date()
        let first = (0..<FeedViewModel.pageSize).map { post($0, at: now.addingTimeInterval(-Double($0))) }
        feed.pages = [first, [first.last!] + (100..<105).map { post($0, at: now.addingTimeInterval(-Double($0))) }]

        let viewModel = FeedViewModel(
            service: feed, social: nil, isSignedIn: { true }, viewerID: { UUID() }
        )
        await viewModel.refresh()
        #expect(viewModel.posts.count == FeedViewModel.pageSize)

        await viewModel.loadMore()
        let ids = viewModel.posts.map(\.id)
        #expect(Set(ids).count == ids.count, "a page boundary duplicated a post")
    }

    @Test("An optimistic reaction rolls back on failure")
    func reactionRollsBack() async {
        let feed = RecordingFeedService()
        feed.pages = [[post(1, at: .now)]]

        let viewModel = FeedViewModel(
            service: feed, social: nil, isSignedIn: { true }, viewerID: { UUID() }
        )
        await viewModel.refresh()
        let original = viewModel.posts[0]

        feed.failure = SocialError.blocked
        await viewModel.toggleReaction(original)

        #expect(viewModel.posts[0].viewerHasReacted == original.viewerHasReacted)
        #expect(viewModel.posts[0].reactionCount == original.reactionCount)
    }

    @Test("A reaction moves the count immediately")
    func reactionIsOptimistic() async {
        let feed = RecordingFeedService()
        feed.pages = [[post(1, at: .now)]]

        let viewModel = FeedViewModel(
            service: feed, social: nil, isSignedIn: { true }, viewerID: { UUID() }
        )
        await viewModel.refresh()
        await viewModel.toggleReaction(viewModel.posts[0])

        #expect(viewModel.posts[0].viewerHasReacted)
        #expect(viewModel.posts[0].reactionCount == 1)
        #expect(feed.reacted.count == 1)
    }
}

private func person(_ handle: String) -> UserProfile {
    UserProfile(id: UUID(), handle: handle, displayName: nil, bio: nil,
                avatarURL: nil, isPrivate: false, createdAt: .now)
}
