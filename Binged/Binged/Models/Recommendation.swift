//
//  Recommendation.swift
//  Binged
//
//  One row of the Discover screen: an unwatched title, what the engine thinks
//  the user would score it, and how well it matches the mood they asked for.
//

import Foundation

// MARK: - Recommendation

struct Recommendation: Identifiable {

    /// Detached — built from the cached pool, never inserted into a
    /// `ModelContext`. The caller decides if and when, exactly as
    /// `MediaService` results work.
    let item: MediaItem

    let predicted: PredictedScore

    /// `0...1`. Binary today because moods are a hard filter; the field exists
    /// because roadmap Phase 14 left grading open.
    let moodWeight: Double

    /// Already on the user's Want to Watch list.
    ///
    /// Queued titles are *kept* rather than excluded: the user asked for things
    /// they have not seen, and a queued title is unseen. Flagging it lets the
    /// row say "already in your list" instead of the screen pretending it is a
    /// discovery.
    let isQueued: Bool

    /// How much the prediction moved off the type baseline. The ranking
    /// quantity — see `RecommendationViewModel.rank`.
    let lift: Double

    /// Chosen because the diversity pass deliberately reached past a run of
    /// same-genre titles. This is presentation provenance, not a weaker score:
    /// the row may honestly say "Something different" only when the selection
    /// algorithm actually made that tradeoff.
    let isExploration: Bool

    init(
        item: MediaItem,
        predicted: PredictedScore,
        moodWeight: Double,
        isQueued: Bool,
        lift: Double,
        isExploration: Bool = false
    ) {
        self.item = item
        self.predicted = predicted
        self.moodWeight = moodWeight
        self.isQueued = isQueued
        self.lift = lift
        self.isExploration = isExploration
    }

    var id: String { item.externalId ?? item.id.uuidString }
}

// MARK: - RecommendationResult

/// What a request produced. An enum rather than an array plus flags, so the
/// Discover screen renders one of a fixed set of states and cannot forget one.
enum RecommendationResult {

    case ready([Recommendation])

    /// The library is too thin to predict from.
    ///
    /// Rule 6's instinct one layer out: a prediction from three ranked titles
    /// is a number the app has not earned. `have` and `need` describe the
    /// **binding** constraint — the overall count when that is what is short,
    /// otherwise the per-type one — because the UI's job is to name the single
    /// next thing the user should do.
    case needsMoreRankings(have: Int, need: Int, type: MediaType?)

    /// The library is sufficient but nothing came back: an unbuilt pool, or a
    /// mood whose candidates the user has already worked through.
    case noCandidates(poolIsEmpty: Bool)

    var recommendations: [Recommendation] {
        if case .ready(let items) = self { return items }
        return []
    }

    var isReady: Bool {
        if case .ready(let items) = self { return !items.isEmpty }
        return false
    }
}
