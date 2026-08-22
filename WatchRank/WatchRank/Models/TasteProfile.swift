//
//  TasteProfile.swift
//  WatchRank
//
//  Everything the engine has learned from one user's ranked library, in a form
//  that can be built once and reused for every candidate in a request.
//
//  Built once per request, never per candidate: building it per candidate is
//  O(library × pool) for no reason at all, and over a 1200-title pool that is
//  the difference between an instant screen and a visible hang.
//
//  `featureSupport` records *which* items back each feature rather than merely
//  how many. The counts fall out of it, roadmap Phase 19's nesting-suppression
//  rule needs the sets themselves, and keeping the sets costs a few thousand
//  UUIDs for a realistic library.
//

import Foundation

// MARK: - TasteProfile

struct TasteProfile: Sendable {

    // MARK: Baselines

    /// Mean score across every scored watched item, both types pooled.
    /// `tuning.neutralScore` when the library is empty.
    let globalMean: Double

    /// Per-type mean, shrunk toward `globalMean`. Only types the user has
    /// actually watched appear here — see `baseline(for:)`.
    let baselinesByType: [MediaType: Double]

    let watchedCountsByType: [MediaType: Int]

    // MARK: Features

    /// Shrunk residual effect per feature key, in points of score.
    ///
    /// Contains only features that cleared their family's inclusion floor. A
    /// feature absent from this dictionary contributes nothing and is treated
    /// as evidence of nothing — the two are the same statement.
    let featureEffects: [String: Double]

    /// Which watched items carry each feature. Complete: this includes features
    /// that fell below the inclusion floor and so have no entry in
    /// `featureEffects`, because Phase 19 and any future recalibration want the
    /// observation even where the model declines to use it.
    let featureSupport: [String: Set<UUID>]

    /// How many distinct features per family were observed but dropped for
    /// falling below the inclusion floor.
    ///
    /// Exists to answer roadmap open question 13 — whether the keyword support
    /// floor discards the tone signal it was added for — with a number instead
    /// of an argument. Costs one `Int` per family.
    let droppedBelowFloor: [Feature.Family: Int]

    // MARK: Provenance

    /// The type of every item that contributed, so a per-type split of
    /// `featureSupport` is derivable without re-reading the library.
    ///
    /// This is what lets roadmap Phase 17 test open question 5 — whether film
    /// taste predicts TV taste — without a schema change or a second profile.
    let itemTypes: [UUID: MediaType]

    /// The user's own scores per type, sorted ascending. The empirical
    /// distribution `RecommendationEngine.calibrate` maps predictions onto.
    let scoresByType: [MediaType: [Double]]

    let tuning: RecommendationTuning

    // MARK: - Derived

    /// Support count per feature. Computed, not stored — the roadmap's point is
    /// that the counts fall out of the sets, so storing both would be two
    /// things to keep in agreement.
    var featureCounts: [String: Int] {
        featureSupport.mapValues(\.count)
    }

    var isEmpty: Bool { itemTypes.isEmpty }

    /// The score a candidate of this type starts from before any feature moves
    /// it. Falls back to `globalMean` for a type the user has never ranked,
    /// which is the honest answer: nothing is known about this type
    /// specifically, so say what is known in general.
    func baseline(for type: MediaType) -> Double {
        baselinesByType[type] ?? globalMean
    }

    func watchedCount(of type: MediaType) -> Int {
        watchedCountsByType[type] ?? 0
    }

    /// Support that the model is actually willing to use.
    ///
    /// A feature below its inclusion floor has observations but no effect, so
    /// counting its support as evidence would claim knowledge the prediction
    /// does not use. Zero is the truthful answer.
    func effectiveSupport(_ key: String) -> Int {
        guard featureEffects[key] != nil else { return 0 }
        return featureSupport[key]?.count ?? 0
    }

    func effect(_ key: String) -> Double {
        featureEffects[key] ?? 0
    }
}
