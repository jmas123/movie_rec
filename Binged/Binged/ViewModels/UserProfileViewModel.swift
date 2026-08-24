//
//  UserProfileViewModel.swift
//  Binged
//
//  Somebody else's ranking.
//

import Foundation
import Observation

// MARK: - UserProfileViewModel

@MainActor
@Observable
final class UserProfileViewModel {

    enum Phase: Equatable {
        case loading
        /// Loaded, with whatever the viewer is allowed to see.
        case loaded
        /// A private account the viewer does not follow. The server returned
        /// nothing; this is not a client-side filter.
        case privateAccount
        case notFound
        case error(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var profile: UserProfile?
    private(set) var relationship: SocialRelationship = .unknown
    private(set) var items: [RankedItem] = []
    private(set) var isLoadingMore = false

    /// A failed page, as distinct from the end of the list.
    private(set) var loadMoreFailed = false
    private(set) var hasMore = true

    @ObservationIgnored private let social: SocialService
    @ObservationIgnored private let rankings: RankingFeedService
    @ObservationIgnored private var offset = 0

    static let pageSize = 100

    init(social: SocialService, rankings: RankingFeedService) {
        self.social = social
        self.rankings = rankings
    }

    // MARK: Loading

    func load(handle: String) async {
        phase = .loading
        do {
            guard let found = try await social.profile(handle: handle) else {
                phase = .notFound
                return
            }
            profile = found
            relationship = try await social.relationship(with: found.id)

            if relationship.state == .blocked {
                phase = .notFound   // indistinguishable from absent, deliberately
                return
            }

            items = try await rankings.rankedItems(
                userID: found.id, offset: 0, limit: Self.pageSize
            )
            offset = items.count
            hasMore = items.count == Self.pageSize

            // A private account the viewer does not follow returns nothing —
            // enforced by RLS, observed here.
            phase = (found.isPrivate && relationship.state != .active && items.isEmpty)
                ? .privateAccount
                : .loaded
        } catch SocialError.notFound {
            phase = .notFound
        } catch {
            phase = .error(ErrorMessage.text(for: error))
        }
    }

    /// Next page. A 500-title library must not arrive in one request.
    func loadMore() async {
        guard hasMore, !isLoadingMore, let profile, phase == .loaded else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let next = try await rankings.rankedItems(
                userID: profile.id, offset: offset, limit: Self.pageSize
            )
            items.append(contentsOf: next)
            offset += next.count
            hasMore = next.count == Self.pageSize
            loadMoreFailed = false
        } catch {
            // See `FeedViewModel.loadMore`: a failed page and a finished list
            // must not look the same to the reader.
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

    // MARK: Following

    func toggleFollow() async {
        guard let profile, relationship.state.isActionable else { return }
        let previous = relationship.state
        relationship.state = previous.next(targetIsPrivate: profile.isPrivate)

        do {
            if relationship.state == .none {
                try await social.unfollow(profile.id)
            } else {
                relationship.state = try await social.follow(profile.id)
            }
            // Newly accepted access may reveal a library that was hidden.
            if previous != .active && relationship.state == .active {
                await load(handle: profile.handle)
            }
        } catch {
            relationship.state = previous
        }
    }

    // MARK: Stats

    /// Totals for the header. Computed from what the viewer can see, which is
    /// the only honest basis — a private account's hidden items are not the
    /// viewer's to count.
    var stats: (total: Int, movies: Int, shows: Int) {
        (
            total: items.count,
            movies: items.filter { $0.mediaType == .movie }.count,
            shows: items.filter { $0.mediaType == .tvShow }.count
        )
    }

    /// Best five visible, by published score.
    var topFive: [RankedItem] {
        items.sorted { $0.score > $1.score }.prefix(5).map { $0 }
    }
}
