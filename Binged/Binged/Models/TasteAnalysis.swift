//
//  TasteAnalysis.swift
//  Binged
//
//  The taste profile, turned into claims about a person.
//
//  **No new mathematics.** Phase 13 already computes shrunk residual effects
//  over a namespaced feature space and Phase 12 already populates it. This is
//  selection, suppression and presentation — which is exactly why it comes last:
//  a *prediction* the user disagrees with is dismissible, because it is a guess
//  about a film they have not seen. A stated fact about their own taste that is
//  wrong is not, and it costs trust the ranking mechanic spent the whole app
//  earning.
//
//  Three rules keep it honest, and each exists because the obvious version is
//  wrong:
//
//  1. **Rank by effect, not by count.** A count-ranked list answers "what do you
//     watch most", which is a different and duller question the user can already
//     answer themselves.
//  2. **Per-family support floors.** Many-per-title families accumulate evidence
//     far faster than one-per-title ones, so "seen three times" means something
//     different for a genre than for a director.
//  3. **Nesting suppression.** If every film by a director also stars the same
//     actor, "favourite actor" and "favourite director" are one observation
//     counted twice. Harmless inside a prediction, misleading as a claim.
//

import Foundation

// MARK: - TasteAnalysis

struct TasteAnalysis: Sendable {

    // MARK: Claim

    /// One displayable statement about the user's taste.
    struct Claim: Sendable, Identifiable, Equatable {
        let feature: Feature
        /// Points above or below the user's baseline.
        let effect: Double
        /// How many watched titles carry it.
        let support: Int

        var id: String { feature.key }

        /// "+1.4 above your average" / "−0.6 below".
        var effectDescription: String {
            let magnitude = String(format: "%.1f", abs(effect))
            if abs(effect) < 0.05 { return "right on your average" }
            return effect > 0 ? "+\(magnitude) above your average" : "−\(magnitude) below your average"
        }
    }

    // MARK: Contrast

    /// The headline: what the user watches most, beside what they rate highest.
    ///
    /// Either number alone is duller and less honest than the pair. "You have
    /// watched 22 Dramas — they land on your baseline. Your 6 Sci-Fis run +1.4
    /// above it" is the interesting shape, and it only exists when the two
    /// disagree.
    struct Contrast: Sendable, Equatable {
        let mostWatched: Claim
        let highestRated: Claim
        var isInteresting: Bool { mostWatched.id != highestRated.id }
    }

    // MARK: Sections

    let genres: [Claim]
    let keywords: [Claim]
    /// Director, composer and cast, after floors and suppression.
    let people: [Claim]
    /// Era, runtime, language, network, franchise.
    let context: [Claim]

    let contrast: Contrast?

    /// Spearman correlation between the user's score order and TMDB's
    /// `vote_average` order, across watched titles carrying both.
    ///
    /// **A rank correlation, never a score difference.** Scores are
    /// bucket-relative quantiles: a user's top film scores ~9.7 whether they
    /// merely liked it or consider it the best ever made. So
    /// `mean(userScore − tmdbVoteAverage)` measures nothing, and "you rate 1.2
    /// points harsher than the crowd" would be a fabrication dressed as a
    /// statistic.
    let crowdAgreement: Double?

    /// Watched titles carrying a TMDB vote average, so the correlation can be
    /// reported with its own sample size rather than bare.
    let crowdSampleSize: Int

    let watchedCount: Int

    // MARK: Thresholds

    /// Below this, the screen shows a cold-start state rather than a portrait
    /// built from three titles.
    static let minimumLibrary = 10

    /// A feature must clear 80% containment in a higher-effect one to be
    /// suppressed. Measured: for actors seen more than once, the median share of
    /// appearances falling under a single director is 50%, so a floor at 80%
    /// suppresses genuine redundancy without hiding an actor the user follows
    /// across directors.
    static let nestingThreshold = 0.8

    var isEmpty: Bool { watchedCount == 0 }
    var hasEnoughLibrary: Bool { watchedCount >= Self.minimumLibrary }

    var isSilent: Bool {
        genres.isEmpty && keywords.isEmpty && people.isEmpty && context.isEmpty
    }

    // MARK: - Init

    init(profile: TasteProfile, watched: [MediaItem]) {
        watchedCount = watched.count

        let tuning = profile.tuning
        let counts = profile.featureCounts

        /// Claims for one set of families, floored, ranked by effect, and
        /// deduplicated by nesting.
        func claims(_ families: Set<Feature.Family>, limit: Int) -> [Claim] {
            let candidates = profile.featureEffects
                .compactMap { key, effect -> Claim? in
                    guard let feature = Feature(key: key),
                          families.contains(feature.family),
                          let support = counts[key],
                          support >= tuning.displayFloor(feature.family)
                    else { return nil }
                    return Claim(feature: feature, effect: effect, support: support)
                }
                // Effect descending, ties broken by key so the order is total —
                // `featureEffects` is a Dictionary and would otherwise reshuffle.
                .sorted { lhs, rhs in
                    lhs.effect != rhs.effect ? lhs.effect > rhs.effect : lhs.id < rhs.id
                }

            var kept: [Claim] = []
            var keptSets: [Set<UUID>] = []

            for claim in candidates {
                let support = profile.featureSupport[claim.id] ?? []
                guard !support.isEmpty else { continue }

                // Suppress anything largely contained in a stronger claim
                // already on screen. This is what stops "favourite actor:
                // Leonardo DiCaprio" from restating "favourite director: Martin
                // Scorsese" — the shrunk residual credits both fully for the
                // same films, which the prediction damps and a sentence does not.
                let nested = keptSets.contains { existing in
                    let overlap = Double(support.intersection(existing).count)
                    return overlap / Double(support.count) >= Self.nestingThreshold
                }
                guard !nested else { continue }

                kept.append(claim)
                keptSets.append(support)
                if kept.count >= limit { break }
            }
            return kept
        }

        genres = claims([.genre], limit: 6)
        keywords = claims([.keyword], limit: 6)
        people = claims([.director, .composer, .cast], limit: 5)
        context = claims([.era, .runtime, .lang, .network, .franchise], limit: 5)

        // MARK: Contrast

        let allGenres = profile.featureEffects.compactMap { key, effect -> Claim? in
            guard let feature = Feature(key: key), feature.family == .genre,
                  let support = counts[key] else { return nil }
            return Claim(feature: feature, effect: effect, support: support)
        }
        let mostWatched = allGenres.max { lhs, rhs in
            lhs.support != rhs.support ? lhs.support < rhs.support : lhs.id > rhs.id
        }
        let highestRated = allGenres
            .filter { $0.support >= tuning.displayFloor(.genre) }
            .max { lhs, rhs in
                lhs.effect != rhs.effect ? lhs.effect < rhs.effect : lhs.id > rhs.id
            }
        contrast = zip([mostWatched].compactMap { $0 }, [highestRated].compactMap { $0 })
            .map { Contrast(mostWatched: $0, highestRated: $1) }
            .first

        // MARK: Crowd agreement

        let paired = watched.compactMap { item -> (Double, Double)? in
            guard let score = item.score, let crowd = item.tmdbVoteAverage, crowd > 0 else {
                return nil
            }
            return (score, crowd)
        }
        crowdSampleSize = paired.count
        crowdAgreement = paired.count >= 8
            ? Ranks.spearman(paired.map(\.0), paired.map(\.1))
            : nil
    }

    // MARK: - Crowd copy

    /// A sentence rather than a coefficient. "0.41" is inside-baseball, and the
    /// interesting reading of it ("you are a contrarian") is a characterisation
    /// the app would be putting in the user's mouth — so this stays descriptive.
    var crowdDescription: String? {
        guard let crowdAgreement, crowdSampleSize >= 8 else { return nil }
        switch crowdAgreement {
        case 0.5...:      return "Your ranking usually agrees with the crowd."
        case 0.2..<0.5:   return "Your ranking loosely tracks the crowd."
        case -0.2..<0.2:  return "Your ranking is largely independent of the crowd."
        default:          return "Your ranking often runs against the crowd."
        }
    }
}
