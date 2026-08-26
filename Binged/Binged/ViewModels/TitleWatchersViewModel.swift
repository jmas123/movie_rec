//
//  TitleWatchersViewModel.swift
//  Binged
//
//  What the people you follow made of one title.
//

import Foundation
import Observation

// MARK: - TitleWatchersViewModel

@MainActor
@Observable
final class TitleWatchersViewModel {

    /// Loading is not a state this screen renders.
    ///
    /// The section sits below a title's own detail on a screen that is already
    /// full and already useful. A spinner there would promise something is
    /// coming and reserve height for it, and on the common answer — nobody you
    /// follow has seen this — the promise is broken and the space collapses.
    /// So it stays absent until it has something, and an error is silence too:
    /// this is a garnish, and a red box apologising for a garnish is worse than
    /// no garnish.
    enum Phase: Equatable {
        case idle, loading, loaded, empty, failed
    }

    private(set) var phase: Phase = .idle
    private(set) var watchers: [TitleWatcher] = []

    @ObservationIgnored private var loaded: Set<String> = []

    static let pageSize = 20

    var hasContent: Bool { !watchers.isEmpty }

    /// How many of them wrote something, for the section's subtitle.
    var reviewCount: Int { watchers.filter(\.hasReview).count }

    /// Loads once per title.
    ///
    /// `MediaDetailView` re-runs its `task` on more than the title changing, and
    /// this is a network call attributed to real people — repeating it on every
    /// redraw would spend requests to arrive at the same list.
    /// - Parameter service: taken here rather than at init because it arrives
    ///   from the environment, which a `@State` initialiser cannot read.
    func load(
        from service: RankingFeedService?, externalID: String?, mediaType: MediaType
    ) async {
        guard let service, let externalID, !externalID.isEmpty else {
            phase = .idle
            return
        }
        let key = "\(mediaType.rawValue)|\(externalID)"
        guard !loaded.contains(key) else { return }
        loaded.insert(key)

        phase = .loading
        do {
            let found = try await service.watchers(
                externalID: externalID, mediaType: mediaType, limit: Self.pageSize
            )
            watchers = found
            phase = found.isEmpty ? .empty : .loaded
        } catch {
            // Deliberately silent — see `Phase`. The title itself is unaffected,
            // and the user did not ask for this.
            watchers = []
            phase = .failed
            AppLog.network.debug("title watchers failed: \(String(describing: error), privacy: .public)")
        }
    }
}
