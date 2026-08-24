//
//  CandidateFeatures.swift
//  Binged
//
//  A `Sendable` snapshot of everything the prediction engine needs about one
//  title. The engine scores these, not `MediaItem`s.
//
//  `MediaItem` is a SwiftData `@Model`: it is not `Sendable`, and it must be
//  touched on the actor that owns its `ModelContext`. If `predict` took one
//  directly, scoring the ~1200-title candidate pool would be pinned to the main
//  actor, and roadmap Phase 18's budget ("profile build + rank + diversity under
//  100 ms, off the main thread if not") would need a refactor to reach.
//
//  Taking a value snapshot instead means the boundary is crossed exactly once,
//  in `buildProfile`, and every subsequent scoring is free to run anywhere.
//

import Foundation

// MARK: - CandidateFeatures

struct CandidateFeatures: Sendable, Hashable {

    let id: UUID
    let type: MediaType

    /// Canonical `Feature` keys, already validated and deduplicated by
    /// `RecommendationEngine.featureKeys(for:)`.
    let keys: [String]

    // MARK: Init

    init(id: UUID, type: MediaType, keys: [String]) {
        self.id = id
        self.type = type
        self.keys = keys
    }

    /// Snapshots a library item or a pool candidate.
    ///
    /// Runs the same extraction as the profile builder, so a candidate and a
    /// watched title are described in one vocabulary — the alternative is an
    /// engine that learns from one key space and predicts over another, which
    /// fails silently rather than loudly.
    init(_ item: MediaItem) {
        self.init(
            id: item.id,
            type: item.type,
            keys: RecommendationEngine.featureKeys(for: item)
        )
    }

    // MARK: Derived

    var isEmpty: Bool { keys.isEmpty }

    /// Parsed features, grouped by family. Computed on demand rather than
    /// stored: `predict` needs it once and the struct is copied often.
    func featuresByFamily() -> [Feature.Family: [Feature]] {
        Dictionary(grouping: keys.features, by: \.family)
    }
}
