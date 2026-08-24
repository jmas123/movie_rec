//
//  FeedViewModel.swift
//  WatchRank
//
//  The feed, paged by keyset cursor.
//

import Foundation
import Observation

// MARK: - FeedViewModel

@MainActor
@Observable
final class FeedViewModel {

    enum Phase: Equatable {
        case loading
        case posts
        /// No account. The feed is the one surface that genuinely needs one.
        case signedOut
        /// Signed in, following nobody. A different problem with a different fix.
        case followingNobody
        /// Following people who have not done anything yet. A third, distinct
        /// state — telling someone to find people they already found is useless.
        case quiet
        case error(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var posts: [FeedPost] = []
    private(set) var isLoadingMore = false
    private(set) var hasMore = true

    @ObservationIgnored private let service: FeedService?
    @ObservationIgnored private let social: SocialService?
    @ObservationIgnored private let isSignedIn: () -> Bool
    @ObservationIgnored private let viewerID: () -> UUID?

    static let pageSize = 25

    init(
        service: FeedService?,
        social: SocialService?,
        isSignedIn: @escaping () -> Bool,
        viewerID: @escaping () -> UUID? = { nil }
    ) {
        self.service = service
        self.social = social
        self.isSignedIn = isSignedIn
        self.viewerID = viewerID
    }

    // MARK: Loading

    func refresh() async {
        guard let service, isSignedIn() else {
            phase = .signedOut
            posts = []
            return
        }

        do {
            let page = try await service.feed(before: nil, limit: Self.pageSize)
            posts = page
            hasMore = page.count == Self.pageSize
            phase = try await emptyPhase(for: page) ?? .posts
        } catch {
            phase = .error(String(describing: error))
        }
    }

    /// Which empty state applies, if any.
    ///
    /// Three distinct answers, because they need three different actions:
    /// sign in, find people, or simply wait.
    private func emptyPhase(for page: [FeedPost]) async throws -> Phase? {
        guard page.isEmpty else { return nil }
        guard let social, let viewer = viewerID() else { return .quiet }
        let followees = try await social.following(of: viewer, limit: 1)
        return followees.isEmpty ? .followingNobody : .quiet
    }

    /// Next page, keyed on the oldest post already held.
    ///
    /// A keyset cursor rather than an offset: posts arriving while the reader
    /// scrolls shift every offset underneath them, which makes an `OFFSET` page
    /// repeat rows it has shown and skip rows it has not. "Older than this exact
    /// post" cannot be moved by anything landing later.
    func loadMore() async {
        guard let service, hasMore, !isLoadingMore, phase == .posts else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let cursor = FeedCursor(posts.last)
            let page = try await service.feed(before: cursor, limit: Self.pageSize)

            // Belt and braces against a server that returns an overlapping page:
            // the cursor should make this impossible, and a duplicated row in a
            // feed is very visible when it is not.
            let known = Set(posts.map(\.id))
            posts.append(contentsOf: page.filter { !known.contains($0.id) })
            hasMore = page.count == Self.pageSize
        } catch {
            hasMore = false
        }
    }

    // MARK: Reactions

    /// Optimistic, with rollback. The count moves immediately because the tap
    /// should feel instant; it moves back if the server disagrees.
    func toggleReaction(_ post: FeedPost) async {
        guard let service, let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        let original = posts[index]
        let wasReacted = original.viewerHasReacted

        posts[index] = original.togglingReaction()

        do {
            if wasReacted {
                try await service.unreact(to: post.id)
            } else {
                try await service.react(to: post.id)
            }
        } catch {
            posts[index] = original
        }
    }
}

// MARK: - Optimistic helper

extension FeedPost {
    /// A copy with the viewer's reaction flipped and the count moved to match.
    func togglingReaction() -> FeedPost {
        FeedPost(
            id: id, authorID: authorID, kind: kind, createdAt: createdAt,
            authorHandle: authorHandle, authorDisplayName: authorDisplayName,
            authorAvatarURL: authorAvatarURL, payload: payload,
            commentCount: commentCount,
            reactionCount: max(0, reactionCount + (viewerHasReacted ? -1 : 1)),
            viewerHasReacted: !viewerHasReacted
        )
    }
}
