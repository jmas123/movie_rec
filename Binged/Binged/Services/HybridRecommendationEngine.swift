//
//  HybridRecommendationEngine.swift
//  Binged
//
//  The production recommendation model: a coarse sentiment expectation, the
//  content model's own residual on top of it, and a crowd score weighted by how
//  far this user's rankings already agree with the crowd.
//
//  **Every constant here was measured, not chosen.** The harness is described in
//  `docs/RECOMMENDER-EVALUATION.md`: 478 MovieLens users' real ratings joined to
//  real TMDB metadata, a quarter of each library held out, this engine's own code
//  under test. Two earlier designs were rejected by that evaluation:
//
//  - **A semantic layer over TMDB overviews** (averaged word vectors, k-nearest
//    neighbours inside the sentiment band). It did not merely fail to help — it
//    made ranking *worse* than the content model alone at every setting tried,
//    including on its home turf, position inside the Liked bucket. Deleted.
//  - **A small fixed crowd weight** (0.10). Far too low: the crowd score is the
//    single strongest ordering signal available, and the sweep put the best
//    fixed weight near 0.35 — and a *learned* weight above that.
//

import Foundation

// MARK: - HybridRecommendationEngine

struct HybridRecommendationEngine {

    struct Profile: Sendable {
        let content: TasteProfile
        let sentiment: SentimentTasteProfile

        /// How much the crowd score is allowed to move this user's prediction,
        /// per media type. Learned — see `crowdWeight(forAgreement:)`.
        let crowdWeightByType: [MediaType: Double]

        /// The mean crowd score across what the user has watched, per type. The
        /// prior a thinly-voted candidate is shrunk toward.
        let crowdMeanByType: [MediaType: Double]

        func crowdWeight(for type: MediaType) -> Double {
            crowdWeightByType[type] ?? HybridRecommendationEngine.fallbackCrowdWeight
        }
    }

    private let contentEngine: RecommendationEngine
    private let sentimentEngine: SentimentRecommendationEngine
    private let maximumCrowdWeight: Double
    private let crowdPriorVotes: Double

    /// The weight used until the library says otherwise.
    ///
    /// The best *fixed* weight in the sweep, so a new user gets the best
    /// available guess and the estimate takes over as their library grows.
    static let fallbackCrowdWeight = 0.35

    init(
        contentEngine: RecommendationEngine = RecommendationEngine(),
        maximumCrowdWeight: Double = 1,
        crowdPriorVotes: Double = 500
    ) {
        self.contentEngine = contentEngine
        self.sentimentEngine = SentimentRecommendationEngine(tuning: contentEngine.tuning)
        self.maximumCrowdWeight = min(1, max(0, maximumCrowdWeight))
        self.crowdPriorVotes = max(0, crowdPriorVotes)
    }

    // MARK: - Profile

    func buildProfile(from watched: [MediaItem]) -> Profile {
        var means: [MediaType: Double] = [:]
        var weights: [MediaType: Double] = [:]

        let byType = Dictionary(grouping: watched) { $0.type }
        for (type, items) in byType {
            let pairs = CrowdAgreement.pairs(in: items)
            guard !pairs.isEmpty else { continue }

            means[type] = pairs.reduce(0) { $0 + $1.crowd } / Double(pairs.count)

            guard let agreement = CrowdAgreement.measure(pairs) else { continue }
            weights[type] = crowdWeight(forAgreement: agreement)
        }

        return Profile(
            content: contentEngine.buildProfile(from: watched),
            sentiment: sentimentEngine.buildProfile(from: watched),
            crowdWeightByType: weights,
            crowdMeanByType: means
        )
    }

    /// How far the crowd is allowed to move a prediction, given how well it
    /// already explains this user's own ranking.
    ///
    /// A user whose favourites are the consensus favourites gets a strong crowd
    /// term; one whose ranking has nothing to do with it gets none. Negative
    /// agreement floors at zero rather than inverting: "you like what the crowd
    /// dislikes" is not a claim a handful of titles can support, and acting on
    /// it would recommend by contrarianism.
    ///
    /// Measured to be worth roughly +0.007 Spearman and −0.02 points of error
    /// over the best fixed weight, and — the reason it is here — it is the
    /// difference between helping and hurting the third of users who agree with
    /// the crowd least.
    func crowdWeight(forAgreement agreement: Double) -> Double {
        guard agreement.isFinite else { return Self.fallbackCrowdWeight }
        return maximumCrowdWeight * min(1, max(0, agreement))
    }

    /// The expected score for an otherwise unknown title of this type.
    ///
    /// A candidate with no features gets exactly this from `predict`: the
    /// content residual is zero and the sentiment layer falls back to its prior,
    /// so the two agree by construction and "lift over baseline" stays honest.
    func baseline(for type: MediaType, using profile: Profile) -> Double {
        sentimentEngine.predict(
            CandidateFeatures(id: UUID(), type: type, keys: []),
            using: profile.sentiment
        ).score
    }

    // MARK: - Prediction

    func predict(
        item: MediaItem,
        features: CandidateFeatures,
        using profile: Profile,
        voteAverage: Double? = nil,
        voteCount: Int? = nil
    ) -> PredictedScore {
        predict(
            type: item.type,
            features: features,
            using: profile,
            voteAverage: voteAverage ?? item.tmdbVoteAverage,
            voteCount: voteCount ?? item.tmdbVoteCount
        )
    }

    func predict(
        type: MediaType,
        features: CandidateFeatures,
        using profile: Profile,
        voteAverage: Double?,
        voteCount: Int?
    ) -> PredictedScore {
        let content = contentEngine.predict(features, using: profile.content)

        // Which band, and where inside it, are separate questions. The sentiment
        // layer answers the first from feature-conditional bucket frequencies;
        // the content model's distance from its own type baseline answers the
        // second. Adding the residual rather than the value is what keeps the
        // band expectation from being counted twice.
        let coarse = sentimentEngine.predict(features, using: profile.sentiment)
        let personal = coarse.score + (content.value - profile.content.baseline(for: type))

        let weight = profile.crowdWeight(for: type)
        var value = personal
        if weight > 0,
           let voteAverage,
           voteAverage.isFinite,
           voteAverage > 0,
           let voteCount,
           voteCount > 0 {
            // An 8.8 from twenty votes is not an 8.8 from twenty thousand, so
            // the crowd score is shrunk toward what this user's own watched
            // titles average before it is allowed to count.
            let prior = profile.crowdMeanByType[type] ?? voteAverage
            let count = Double(voteCount)
            let adjusted = (count * voteAverage + crowdPriorVotes * prior) / (count + crowdPriorVotes)
            value = (1 - weight) * personal + weight * adjusted
        }

        // Feature contributions remain the explanation source: they name real
        // preferences learned from the user's own rankings. The crowd term moves
        // the point estimate and never manufactures a reason.
        return PredictedScore(
            value: min(10, max(0, value)),
            confidence: content.confidence,
            evidence: content.evidence,
            familiesPresent: content.familiesPresent,
            topContributingFeatures: content.topContributingFeatures
        )
    }
}
