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

    /// Their ranking held against the viewer's own.
    ///
    /// Recomputed whenever either side moves — a page of theirs arriving, or
    /// the viewer queueing something from this very screen. Held here rather
    /// than derived in `body` because it is O(their library) and SwiftUI may
    /// evaluate a body many times per frame.
    private(set) var match = TasteMatch(theirs: [], yours: [])
    private(set) var isLoadingMore = false

    /// A failed page, as distinct from the end of the list.
    private(set) var loadMoreFailed = false
    private(set) var hasMore = true

    /// Set once the viewer blocks this person, so the screen can leave: it is
    /// showing the ranking of somebody they just asked never to see again.
    private(set) var didBlock = false
    private(set) var lastError: String?

    @ObservationIgnored private let social: SocialService
    @ObservationIgnored private let rankings: RankingFeedService
    @ObservationIgnored private var offset = 0
    @ObservationIgnored private var libraryEntries: [TasteMatch.LibraryEntry] = []

    static let pageSize = 100

    init(social: SocialService, rankings: RankingFeedService) {
        self.social = social
        self.rankings = rankings
    }

    // MARK: Loading

    /// Loads the profile, or refreshes one already on screen.
    ///
    /// **The distinction is the whole point.** `UserProfileView` drives this
    /// from `.task`, and `.task` is cancelled when the view disappears and
    /// restarts when it reappears — which is exactly what a push and a pop are.
    /// So every trip into the follower list, the following list, or a title on
    /// this ranking came back through here.
    ///
    /// Resetting to `.loading` unconditionally meant that return trip replaced
    /// a fully-rendered profile with a spinner and re-fetched three requests
    /// worth of data the screen already had — and if any of them failed or was
    /// cancelled on the way, the profile the user had been reading was replaced
    /// by an error state.
    ///
    /// Refreshing is still right — following somebody from their following list
    /// changes the counts on this very screen — so the fetch stays. What
    /// changes is that a refresh no longer tears the page down to do it.
    func load(handle: String) async {
        let isRefresh = hasContent
        if !isRefresh { phase = .loading }

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

            let fetched = try await rankings.rankedItems(
                userID: found.id, offset: 0, limit: Self.pageSize
            )
            // Assigned only once the request has actually returned. Writing
            // straight into `items` would empty the list for the duration of a
            // refresh, and every comparison section on the screen with it.
            items = fetched
            offset = items.count
            hasMore = items.count == Self.pageSize
            loadMoreFailed = false
            recomputeMatch()

            // A private account the viewer does not follow returns nothing —
            // enforced by RLS, observed here.
            phase = (found.isPrivate && relationship.state != .active && items.isEmpty)
                ? .privateAccount
                : .loaded
        } catch is CancellationError {
            // Navigating away cancels the task. That is not a failure to
            // report, and turning it into one is how leaving this screen left
            // an error behind for the next visit to find.
            if !isRefresh { phase = .loading }
        } catch SocialError.notFound {
            phase = .notFound
        } catch {
            // A refresh that fails keeps what is on screen. The alternative —
            // replacing a profile the user is reading with an error, because a
            // background re-fetch they did not ask for timed out — is strictly
            // worse than showing slightly stale counts.
            if isRefresh {
                lastError = ErrorMessage.text(for: error)
            } else {
                phase = .error(ErrorMessage.text(for: error))
            }
        }
    }

    /// Whether there is a rendered profile to preserve.
    ///
    /// `privateAccount` counts: it is a complete answer with a header on it,
    /// not a half-loaded state.
    private var hasContent: Bool {
        profile != nil && (phase == .loaded || phase == .privateAccount)
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
            recomputeMatch()
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

    // MARK: Taste comparison

    /// Hands the viewer's own library in, and recomputes the comparison.
    ///
    /// Pushed in rather than pulled: this view model talks to two services and
    /// has no business also reaching into SwiftData, and the flattening it
    /// needs — including which scores rule 6 lets the viewer see — is something
    /// only `MediaLibraryViewModel` can do.
    func updateViewerLibrary(_ entries: [TasteMatch.LibraryEntry]) {
        libraryEntries = entries
        recomputeMatch()
    }

    private func recomputeMatch() {
        match = TasteMatch(theirs: items, yours: libraryEntries)
    }

    // MARK: Following

    /// Blocks the person whose profile this is.
    ///
    /// A profile shows a name, a bio and an entire ranking — it is a surface
    /// displaying another person's content, and App Store guideline 1.2 asks
    /// for report and block on every one of those. This screen had neither
    /// until it became reachable, at which point the omission became real.
    func block() async {
        guard let profile else { return }
        do {
            try await social.block(profile.id)
            didBlock = true
        } catch {
            lastError = ErrorMessage.text(for: error)
        }
    }

    func clearError() { lastError = nil }

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
