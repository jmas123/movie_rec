//
//  TasteAnalysisTests.swift
//  WatchRankTests
//
//  Claims about a person, so the bar is higher than for a prediction. A guess
//  the user disagrees with is dismissible; a wrong statement about their own
//  taste is not.
//

import Foundation
import Testing
@testable import WatchRank

// MARK: - Helpers

@MainActor
private func analyse(_ items: [MediaItem]) -> TasteAnalysis {
    TasteAnalysis(
        profile: RecommendationEngine().buildProfile(from: items),
        watched: items
    )
}

/// A library where `loved` sits at the top of Liked and `hated` at the bottom
/// of Disliked, both repeated enough to clear their display floors.
@MainActor
private func makeTasteLibrary(
    loved: [Feature], hated: [Feature], each: Int = 6, filler: Int = 8
) -> [MediaItem] {
    var plan: [(Sentiment, [Feature])] = []
    for _ in 0..<each { plan.append((.liked, loved)) }
    for _ in 0..<filler { plan.append((.fine, [.genre("Filler")])) }
    for _ in 0..<each { plan.append((.disliked, hated)) }

    var grouped: [Sentiment: [(Int, [Feature])]] = [:]
    for (index, entry) in plan.enumerated() {
        grouped[entry.0, default: []].append((index, entry.1))
    }

    var items: [MediaItem] = []
    for (sentiment, members) in grouped {
        let scores = RankingEngine.scores(count: members.count, range: sentiment.scoreRange)
        for (position, member) in members.enumerated() {
            items.append(makeScored(
                "t\(member.0)", score: scores[position],
                features: member.1.keys, sentiment: sentiment
            ))
        }
    }
    return items
}

// MARK: - Tests

@Suite("TasteAnalysis")
@MainActor
struct TasteAnalysisTests {

    private let tuning = RecommendationTuning.standard

    // MARK: Selection

    @Test("Claims are ranked by effect, not by how often something was watched")
    func rankedByEffect() {
        // A count-ranked list answers "what do you watch most", which is a
        // different and duller question — and one that would contradict the
        // recommender, which ranks by effect.
        var items = makeTasteLibrary(loved: [.genre("Horror")], hated: [.genre("Romance")])
        // Add a very frequent but exactly-average genre.
        for item in items { item.features = item.features + [Feature.genre("Ubiquitous").key] }

        let analysis = analyse(items)
        let top = try? #require(analysis.genres.first)

        #expect(top?.feature.displayName == "Horror")
        #expect(analysis.genres.first?.feature.displayName != "Ubiquitous")
    }

    @Test("A feature below its family's display floor never appears")
    func displayFloorsHold() {
        // Feeding a prediction is cheap; asserting "your favourite director is
        // X" is not, so the floors differ from the inclusion floors.
        let director = Feature.director(id: 1, name: "Seen Twice")
        var items = makeTasteLibrary(loved: [.genre("Horror")], hated: [.genre("Romance")])
        items[0].features = items[0].features + [director.key]
        items[1].features = items[1].features + [director.key]

        let analysis = analyse(items)
        #expect(tuning.displayFloor(.director) > 2)
        #expect(!analysis.people.contains { $0.feature.displayName == "Seen Twice" })
    }

    @Test("Every displayed claim clears its own family's floor")
    func everyClaimIsEarned() {
        let analysis = analyse(makeTasteLibrary(
            loved: [.genre("Horror"), .keyword(id: 1, name: "dread")],
            hated: [.genre("Romance")]
        ))

        for claim in analysis.genres + analysis.keywords + analysis.people + analysis.context {
            #expect(claim.support >= tuning.displayFloor(claim.feature.family),
                    "\(claim.feature.key) shown on \(claim.support) titles")
        }
    }

    // MARK: Nesting suppression

    @Test("An actor who only appears for one director is suppressed")
    func nestedClaimsAreSuppressed() {
        // The shrunk residual credits both features fully for the same films.
        // Harmless inside a prediction, where the averaging damps it; misleading
        // as two separate claims about the person.
        let director = Feature.director(id: 1, name: "Auteur")
        let actor = Feature.castMember(id: 2, name: "Regular")

        let items = makeTasteLibrary(
            loved: [.genre("Horror"), director, actor], hated: [.genre("Romance")]
        )
        let analysis = analyse(items)
        let names = analysis.people.map(\.feature.displayName)

        #expect(names.contains("Auteur") || names.contains("Regular"))
        #expect(!(names.contains("Auteur") && names.contains("Regular")),
                "the same films were claimed twice: \(names)")
    }

    @Test("An actor spread across directors survives")
    func independentClaimsBothSurvive() {
        let actor = Feature.castMember(id: 2, name: "Everywhere")
        let items = makeTasteLibrary(loved: [.genre("Horror"), actor], hated: [.genre("Romance")])

        // Give each loved title a different director, so the actor's support is
        // not contained in any one of them.
        var directorIndex = 0
        for item in items where item.sentiment == .liked {
            item.features = item.features + [Feature.director(id: 100 + directorIndex, name: "D\(directorIndex)").key]
            directorIndex += 1
        }

        let analysis = analyse(items)
        #expect(analysis.people.contains { $0.feature.displayName == "Everywhere" })
    }

    // MARK: Contrast

    @Test("The headline pairs most-watched with highest-rated")
    func contrastNamesBoth() {
        var items = makeTasteLibrary(loved: [.genre("Horror")], hated: [.genre("Romance")])
        for item in items { item.features = item.features + [Feature.genre("Ubiquitous").key] }

        let contrast = try? #require(analyse(items).contrast)
        #expect(contrast?.mostWatched.feature.displayName == "Ubiquitous")
        #expect(contrast?.highestRated.feature.displayName == "Horror")
        #expect(contrast?.isInteresting == true)
    }

    // MARK: Crowd agreement

    @Test("Crowd agreement is a rank correlation, invariant to rescaling")
    func crowdAgreementIsRankBased() {
        // The test that proves it is not a mean difference in disguise. Scores
        // are bucket-relative quantiles, so `mean(user - crowd)` measures
        // nothing at all.
        let scores = RankingEngine.scores(count: 12, range: Sentiment.liked.scoreRange)
        func library(_ transform: (Double) -> Double) -> [MediaItem] {
            scores.enumerated().map { entry in
                let item = makeScored("c\(entry.offset)", score: entry.element,
                                      features: [Feature.genre("Drama").key])
                item.tmdbVoteAverage = transform(entry.element)
                return item
            }
        }

        let plain = analyse(library { $0 })
        let squashed = analyse(library { $0 * 0.3 + 1 })

        #expect(plain.crowdAgreement != nil)
        #expect(abs((plain.crowdAgreement ?? 0) - (squashed.crowdAgreement ?? -1)) < 0.0001)
        #expect(abs((plain.crowdAgreement ?? 0) - 1.0) < 0.0001)
    }

    @Test("Crowd agreement stays silent below a usable sample")
    func crowdAgreementNeedsASample() {
        let items = makeTasteLibrary(loved: [.genre("Horror")], hated: [.genre("Romance")])
        items[0].tmdbVoteAverage = 8.0
        items[1].tmdbVoteAverage = 7.0

        let analysis = analyse(items)
        #expect(analysis.crowdAgreement == nil)
        #expect(analysis.crowdDescription == nil)
    }

    // MARK: Degenerate input

    @Test("Empty, single-item and featureless libraries all produce a valid analysis")
    func degenerateLibraries() {
        let empty = analyse([])
        #expect(empty.isEmpty)
        #expect(!empty.hasEnoughLibrary)
        #expect(empty.crowdAgreement == nil)

        let single = analyse([makeScored("one", score: 8.4, features: [Feature.genre("Drama").key])])
        #expect(single.watchedCount == 1)
        #expect(!single.hasEnoughLibrary)

        let featureless = analyse([makeScored("bare", score: 8.4, features: [])])
        #expect(featureless.isSilent || !featureless.genres.isEmpty)
    }

    @Test("Analysis is deterministic regardless of library order")
    func analysisIsDeterministic() {
        // `featureEffects` is a Dictionary; without a total tie-break the
        // screen would reshuffle between renders.
        let items = makeTasteLibrary(
            loved: [.genre("Horror"), .genre("Thriller")], hated: [.genre("Romance")]
        )
        let forward = analyse(items)
        let backward = analyse(items.reversed())

        #expect(forward.genres.map(\.id) == backward.genres.map(\.id))
        #expect(forward.people.map(\.id) == backward.people.map(\.id))
    }

    @Test("The analysis needs no store and no network")
    func purity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WatchRank/Models/TasteAnalysis.swift")
        let source = try String(contentsOf: root, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        for banned in ["import SwiftData", "import SwiftUI", "URLSession"] {
            #expect(!code.contains(banned))
        }
    }
}
