//
//  MediaItem.swift
//  Binged
//

import Foundation
import SwiftData

// MARK: - MediaItem

/// The single persisted entity in the app. A `MediaItem` represents one movie
/// or TV show — surfaced from search, queued to watch, or watched and ranked.
///
/// Scores are never user-entered: they are recomputed from `rankInBucket`
/// inside `RankingEngine` after every insertion or drag-to-reorder.
@Model
final class MediaItem {

    // MARK: - Identity

    @Attribute(.unique) var id: UUID

    /// Stable identifier from an external catalog (e.g., TMDB) when known.
    /// Optional so the mock service and user-created entries can omit it.
    var externalId: String?

    // MARK: - Catalog metadata

    var title: String
    var year: Int
    var type: MediaType
    var overview: String
    var posterURL: String?
    var genres: [String]

    /// Everything the recommendation engine can learn a preference for, as
    /// namespaced keys: `genre:Horror`, `keyword:1721|neo-noir`,
    /// `director:525|Christopher Nolan`, `era:2010s`, and so on.
    ///
    /// One array rather than a property per family, so a new feature family is
    /// a new `Feature.Family` case rather than a SwiftData migration — see
    /// `Feature`. It is also already the key space Phase 13's
    /// `featureEffects: [String: Double]` uses, so the engine reads it directly.
    ///
    /// `genres` is kept alongside deliberately: it is catalog metadata the UI
    /// displays as chips, while this is model input. The genre entries here are
    /// derived from it, so the duplication is one-way and cheap.
    ///
    /// Empty means "not fetched yet", which is not the same as "has none".
    var features: [String]

    /// TMDB's own average user score, 0–10.
    ///
    /// Deliberately **not** a feature key: it is a scalar, and mixing it into
    /// the categorical key space would make it a feature named after its own
    /// value. Reserved for the crowd-agreement statistic in roadmap Phase 19,
    /// and never shown as if it were the user's own score.
    var tmdbVoteAverage: Double?

    // MARK: - User state

    var watchedStatus: WatchedStatus
    var sentiment: Sentiment?

    /// Derived 0–10 score. `nil` until the item is watched and ranked.
    var score: Double?

    /// Zero-based position within the item's sentiment bucket. Lower index ==
    /// higher score. `nil` for unwatched items.
    var rankInBucket: Int?

    var review: String?

    // MARK: - Prediction feedback

    /// What the app predicted the user would score this, recorded when they
    /// queued it from a recommendation.
    ///
    /// Frozen at the moment of the guess. Re-deriving it later would compare
    /// the model against itself after it had already seen more of the user's
    /// taste, which measures nothing — the whole point is to hold the app to
    /// what it actually said at the time.
    var predictedScore: Double?

    /// When that guess was made. Kept because the target drifts: a score is a
    /// quantile over its bucket, so a pair recorded months apart is not
    /// strictly comparable to a fresh one.
    var predictedAt: Date?

    /// "Not for me." The only negative signal available without asking the user
    /// to rate something they have not seen.
    var dismissed: Bool = false

    // MARK: - Timestamps

    var dateAdded: Date
    var dateWatched: Date?

    /// When the user last decided *which bucket* this title belongs in —
    /// marking it watched with a sentiment, or moving it to the queue.
    ///
    /// The clock account sync uses to settle a disagreement between two
    /// devices (`docs/PART-IV-SYNC.md` §6.3). Three things it deliberately is
    /// not:
    ///
    /// - **Not `dateWatched`.** That records when they saw the film. Re-rating
    ///   a 2019 title does not move 2019, so it cannot order two decisions.
    /// - **Not stamped by `finalizeRanking`.** Completing comparisons refines a
    ///   *position*, which the user never chose directly (rule 4). If finishing
    ///   a comparison session bumped this, it could outrank a genuine sentiment
    ///   change made elsewhere — a refinement beating a decision.
    /// - **Not a sync bookkeeping field.** It records a user act, so it stays
    ///   meaningful for a user who never signs in.
    ///
    /// `nil` for rows written before this property existed. Such a row loses a
    /// conflict to the server, which is the documented fallback.
    var lastRankedAt: Date?

    // MARK: - Init

    init(
        id: UUID = UUID(),
        externalId: String? = nil,
        title: String,
        year: Int,
        type: MediaType,
        overview: String = "",
        posterURL: String? = nil,
        genres: [String] = [],
        features: [String] = [],
        tmdbVoteAverage: Double? = nil,
        watchedStatus: WatchedStatus = .untracked,
        sentiment: Sentiment? = nil,
        score: Double? = nil,
        rankInBucket: Int? = nil,
        review: String? = nil,
        predictedScore: Double? = nil,
        predictedAt: Date? = nil,
        dismissed: Bool = false,
        dateAdded: Date = .now,
        dateWatched: Date? = nil,
        lastRankedAt: Date? = nil
    ) {
        self.id = id
        self.externalId = externalId
        self.title = title
        self.year = year
        self.type = type
        self.overview = overview
        self.posterURL = posterURL
        self.genres = genres
        self.features = features
        self.tmdbVoteAverage = tmdbVoteAverage
        self.watchedStatus = watchedStatus
        self.sentiment = sentiment
        self.score = score
        self.rankInBucket = rankInBucket
        self.review = review
        self.predictedScore = predictedScore
        self.predictedAt = predictedAt
        self.dismissed = dismissed
        self.dateAdded = dateAdded
        self.dateWatched = dateWatched
        self.lastRankedAt = lastRankedAt
    }
}

// MARK: - Persisting a batch

extension Sequence where Element == MediaItem {

    /// Saves each distinct `ModelContext` these items actually belong to.
    ///
    /// Exists because saving an injected context is not the same as saving the
    /// one that owns the objects. A `@Model` belongs to exactly one context, and
    /// a caller holding a *different* context — a second context on the same
    /// container, which is a normal thing to have — gets a `save()` that
    /// succeeds and writes nothing. The mutation stays live in memory, so every
    /// in-process assertion passes and the work is silently lost at relaunch.
    ///
    /// Saving through the objects removes the chance to get that pairing wrong.
    ///
    /// - Returns: how many distinct contexts were saved. Zero means none of
    ///   these items is attached to a store, which is the caller's cue to fall
    ///   back to whatever context it was given.
    @discardableResult
    func saveOwningContexts() -> Int {
        var contexts: [ObjectIdentifier: ModelContext] = [:]
        for item in self {
            guard let context = item.modelContext else { continue }
            contexts[ObjectIdentifier(context)] = context
        }
        for context in contexts.values {
            do {
                try context.save()
            } catch {
                AppLog.persistence.error("owning-context save failed: \(error)")
            }
        }
        return contexts.count
    }
}
