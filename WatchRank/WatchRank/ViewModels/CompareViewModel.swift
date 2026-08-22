//
//  CompareViewModel.swift
//  WatchRank
//
//  Presentation driver for the pairwise comparison modal. The binary-insertion
//  search itself lives in `MediaLibraryViewModel` (which owns the session and
//  is proven correct by `MediaLibraryViewModelTests`); this view model is a
//  thin, SwiftUI-free adapter that surfaces the current pair, the progress
//  label, and translates a tapped card into a winner/loser choice. Keeping the
//  search in one place avoids two implementations of the same algorithm.
//

import Foundation
import Observation

// MARK: - CompareViewModel

@Observable
@MainActor
final class CompareViewModel {

    /// The item being inserted into its sentiment bucket.
    let newItem: MediaItem

    /// Flips to `true` once the search resolves (or the user cancels). The view
    /// observes this to dismiss the modal.
    private(set) var isFinished = false

    @ObservationIgnored
    private let library: MediaLibraryViewModel

    // MARK: Init

    init(newItem: MediaItem, library: MediaLibraryViewModel) {
        self.newItem = newItem
        self.library = library
        // Nothing to compare (e.g., the bucket was empty and `markWatched`
        // already finalized) — finish immediately so the view just dismisses.
        if library.pendingComparison == nil {
            isFinished = true
        }
    }

    // MARK: Derived state

    /// The pair the UI should render right now, or `nil` once finished.
    var currentPair: ComparisonPair? {
        library.pendingComparison
    }

    /// "Comparison X of Y" — Y is the worst-case `ceil(log2(N + 1))` bound the
    /// library VM computed when the session started.
    var progressText: String {
        guard let pair = currentPair else { return "" }
        return "Comparison \(pair.step) of \(pair.totalSteps)"
    }

    /// 0...1 completion fraction for a progress bar.
    var progressFraction: Double {
        guard let pair = currentPair, pair.totalSteps > 0 else { return 1 }
        let done = min(pair.step - 1, pair.totalSteps)
        return Double(done) / Double(pair.totalSteps)
    }

    /// Whether there is an answered comparison to take back.
    var canUndo: Bool { library.canUndoComparison }

    // MARK: Actions

    /// Records that the user preferred `preferred` over the other card in the
    /// current pair, then advances the search or finalizes the ranking.
    func choose(_ preferred: MediaItem) {
        guard let pair = currentPair else { return }

        let other = preferred.id == pair.newItem.id ? pair.existingItem : pair.newItem
        library.applyComparisonChoice(winner: preferred, loser: other)

        if library.pendingComparison == nil {
            // Search resolved: insert at the position the engine computed.
            library.finalizeRanking(for: newItem)
            isFinished = true
        }
    }

    /// Takes back the last answer and re-presents that pair.
    func undo() {
        guard !isFinished else { return }
        library.undoLastComparison()
    }

    /// The user could not separate the two titles. Ends the search, seating the
    /// new item just below the one it was weighed against.
    func markTooClose() {
        guard currentPair != nil else { return }
        library.applyComparisonTie()

        if library.pendingComparison == nil {
            library.finalizeRanking(for: newItem)
            isFinished = true
        }
    }

    /// User dismissed the modal without finishing — place the item at the
    /// bucket midpoint so it still gets a score. Idempotent.
    func cancel() {
        guard !isFinished else { return }
        library.cancelRanking(for: newItem)
        isFinished = true
    }
}
