//
//  FeedViewModel.swift
//  Binged
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

    /// Surfaced by `FeedView` as an alert. A failed report or block has to say
    /// so — a safety action that silently no-ops is worse than one that is
    /// missing, because the user believes they are protected.
    private(set) var lastError: String?

    /// Whether the last attempt at a further page failed, as distinct from
    /// there being no further page.
    private(set) var loadMoreFailed = false

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
            phase = .error(ErrorMessage.text(for: error))
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
            loadMoreFailed = false
        } catch {
            // `hasMore = false` alone made a transient 500 indistinguishable
            // from reaching the end of the feed: scrolling simply stopped, and
            // the reader was silently shown a truncated feed as if it were the
            // whole one. Stop paging — otherwise `onAppear` retries forever —
            // but say so, and let them ask again.
            hasMore = false
            loadMoreFailed = true
        }
    }

    /// Re-arms paging after a failed page and tries once more.
    func retryLoadMore() async {
        guard loadMoreFailed else { return }
        loadMoreFailed = false
        hasMore = true
        await loadMore()
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

    // MARK: Safety

    /// Reports a post or a comment.
    ///
    /// Reporting is fire-and-acknowledge: the row stays where it is. Hiding it
    /// would tell the reporter the report was *acted on*, which is a promise
    /// only a human reviewer can keep. Blocking is the button that changes what
    /// you see.
    func report(_ target: ReportTarget, reason: ReportReason, note: String?) async {
        guard let service else { return }
        do {
            try await service.report(target, reason: reason, note: note)
        } catch {
            lastError = ErrorMessage.text(for: error)
        }
    }

    /// Blocks a post's author and drops everything of theirs already on screen.
    ///
    /// The server severs the follow edges both ways; this only has to catch the
    /// page already in memory, because the next fetch will not include them.
    /// Local removal is not merely cosmetic — leaving their posts visible after
    /// a block reads as the block having failed.
    func block(_ post: FeedPost) async {
        guard let social else { return }
        do {
            try await social.block(post.authorID)
            posts.removeAll { $0.authorID == post.authorID }
            if posts.isEmpty {
                // Not `followingNobody`: they may still follow other people who
                // simply have nothing on this page.
                phase = .quiet
            }
        } catch {
            lastError = ErrorMessage.text(for: error)
        }
    }

    func clearError() { lastError = nil }
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
