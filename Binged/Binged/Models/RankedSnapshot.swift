//
//  RankedSnapshot.swift
//  Binged
//
//  One ranked title as a plain value: everything the taste profile reads, and
//  nothing that belongs to SwiftData.
//
//  Exists because cross-validation has to *simulate* a library it does not
//  have. Holding an item out of a bucket changes every remaining item's score —
//  the score is a quantile over the bucket, not an independent observation — so
//  a fold has to recompute the rest. Doing that against live `MediaItem`s would
//  rewrite the user's real library, since `@Model` is a reference type and
//  `RankingEngine.recomputeScores` mutates in place.
//

import Foundation

// MARK: - RankedSnapshot

struct RankedSnapshot: Sendable, Hashable {

    let id: UUID
    let type: MediaType
    let sentiment: Sentiment?
    let score: Double
    let keys: [String]

    init(id: UUID, type: MediaType, sentiment: Sentiment?, score: Double, keys: [String]) {
        self.id = id
        self.type = type
        self.sentiment = sentiment
        self.score = score
        self.keys = keys
    }

    /// `nil` for an item that is not watched-and-scored, which is the filter
    /// every profile build applies anyway.
    init?(_ item: MediaItem) {
        guard item.watchedStatus == .watched, let score = item.score else { return nil }
        self.init(
            id: item.id,
            type: item.type,
            sentiment: item.sentiment,
            score: score,
            keys: RecommendationEngine.featureKeys(for: item)
        )
    }

    func withScore(_ newScore: Double) -> RankedSnapshot {
        RankedSnapshot(id: id, type: type, sentiment: sentiment, score: newScore, keys: keys)
    }

    var candidate: CandidateFeatures {
        CandidateFeatures(id: id, type: type, keys: keys)
    }
}

// MARK: - Bucket recomputation

extension Array where Element == RankedSnapshot {

    /// Re-derives every score the way `RankingEngine` would, in value space.
    ///
    /// Buckets are `(type, sentiment)` and members keep their existing relative
    /// order, so this reproduces exactly what the app would hold if this were
    /// the whole library. An item with no sentiment cannot be placed in a
    /// bucket and keeps the score it came with.
    func recomputingScores() -> [RankedSnapshot] {
        var buckets: [BucketKey: [RankedSnapshot]] = [:]
        var unplaced: [RankedSnapshot] = []

        for snapshot in self {
            guard let sentiment = snapshot.sentiment else {
                unplaced.append(snapshot)
                continue
            }
            buckets[BucketKey(type: snapshot.type, sentiment: sentiment), default: []]
                .append(snapshot)
        }

        var rebuilt: [RankedSnapshot] = unplaced
        // Deterministic bucket order. Iterating the dictionary directly leaves
        // the output array ordered by hashing, and the profile builder then
        // accumulates its sums in that order — enough to move the last ulp
        // between two identical calls.
        let ordered = buckets.keys.sorted {
            $0.type.rawValue != $1.type.rawValue
                ? $0.type.rawValue < $1.type.rawValue
                : $0.sentiment.rawValue < $1.sentiment.rawValue
        }
        for key in ordered {
            let members = buckets[key] ?? []
            let ordered = members.sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.id.uuidString < rhs.id.uuidString
            }
            let scores = RankingEngine.scores(
                count: ordered.count, range: key.sentiment.scoreRange
            )
            for (index, member) in ordered.enumerated() {
                rebuilt.append(member.withScore(scores[index]))
            }
        }
        return rebuilt
    }

    private struct BucketKey: Hashable {
        let type: MediaType
        let sentiment: Sentiment
    }
}
