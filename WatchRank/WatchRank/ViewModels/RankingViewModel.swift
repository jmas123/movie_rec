//
//  RankingViewModel.swift
//  WatchRank
//
//  Backs the Ranking screen. Owns the media-type filter tab and exposes each
//  sentiment bucket (optionally narrowed to the selected type) in rank order.
//  All data and mutations flow through `MediaLibraryViewModel`; this VM never
//  touches SwiftData or the `RankingEngine` directly.
//

import Foundation
import Observation

// MARK: - RankingViewModel

@Observable
@MainActor
final class RankingViewModel {

    // MARK: TypeFilter

    /// The segmented tab at the top of the Ranking screen.
    enum TypeFilter: String, CaseIterable, Identifiable {
        case all
        case movies
        case tv

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all:    return "All"
            case .movies: return "Movies"
            case .tv:     return "TV"
            }
        }

        /// The `MediaType` to filter by, or `nil` for the All tab.
        var mediaType: MediaType? {
            switch self {
            case .all:    return nil
            case .movies: return .movie
            case .tv:     return .tvShow
            }
        }
    }

    // MARK: State

    var filter: TypeFilter = .all

    @ObservationIgnored
    private let library: MediaLibraryViewModel

    // MARK: Init

    init(library: MediaLibraryViewModel) {
        self.library = library
    }

    // MARK: Reads

    /// Items in `sentiment` for the current type tab, ranked best first.
    ///
    /// A bucket is `(type, sentiment)`, so a type tab shows exactly one bucket.
    /// The All tab shows two independent rankings at once; they are merged by
    /// score purely for browsing, since both types share the sentiment's score
    /// band. That merged list is not a bucket, which is why reordering is
    /// disabled there.
    func items(for sentiment: Sentiment) -> [MediaItem] {
        if let type = filter.mediaType {
            return library.bucket(for: sentiment, type: type)
        }
        return MediaType.allCases
            .flatMap { library.bucket(for: sentiment, type: $0) }
            .sorted { ($0.score ?? -.infinity) > ($1.score ?? -.infinity) }
    }

    /// True when no watched item matches the current filter — drives the
    /// screen-level empty state.
    var isEmpty: Bool {
        Sentiment.allCases.allSatisfy { items(for: $0).isEmpty }
    }

    /// What the row for `item` may say: a score once its bucket has earned one,
    /// otherwise the position rule 6 shows in its place.
    func scoreDisplay(for item: MediaItem) -> ScoreDisplay {
        library.scoreDisplay(for: item)
    }

    // MARK: Reorder

    /// Drag-to-reorder is offered only on a *type* tab, where the visible list
    /// maps 1:1 onto the `(type, sentiment)` bucket the engine rescores. The
    /// All tab interleaves two independent rankings, so a move there has no
    /// single bucket to resolve against — we disable it rather than guess.
    ///
    /// This is the reverse of the pre-type-separation rule, when a sentiment
    /// bucket spanned both media types and All was the only faithful view.
    /// (Cross-section moves stay impossible: each section is its own
    /// `ForEach`, so a drag cannot cross sentiment boundaries.)
    var canReorder: Bool { filter.mediaType != nil }

    /// Applies an in-bucket move. No-ops on the All tab so a stray event can
    /// never reorder against an interleaved list.
    func move(in sentiment: Sentiment, from source: IndexSet, to destination: Int) {
        guard let type = filter.mediaType else { return }
        library.reorder(in: sentiment, type: type, from: source, to: destination)
    }
}
