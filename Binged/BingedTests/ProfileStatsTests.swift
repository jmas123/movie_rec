//
//  ProfileStatsTests.swift
//  BingedTests
//
//  Verifies the pure `ProfileStats` aggregate against a hand-built fixture:
//  totals, the movie/TV split, average score, the all-time top 5 (capped), and
//  the top-3 genre tally with a deterministic alphabetical tie-break. No store
//  is needed — `ProfileStats` is a value type over plain `MediaItem`s.
//

import Foundation
import Testing
@testable import Binged

// MARK: - ProfileStatsTests

@Suite("ProfileStats")
struct ProfileStatsTests {

    private func item(
        _ title: String,
        _ type: MediaType,
        score: Double,
        genres: [String]
    ) -> MediaItem {
        MediaItem(
            title: title,
            year: 2020,
            type: type,
            genres: genres,
            watchedStatus: .watched,
            score: score
        )
    }

    /// Six watched items: 4 movies, 2 TV. Scores 9.5 … 4.0.
    private func fixture() -> [MediaItem] {
        [
            item("A", .movie, score: 9.5, genres: ["Drama", "Sci-Fi"]),
            item("B", .movie, score: 8.0, genres: ["Drama"]),
            item("C", .tvShow, score: 7.0, genres: ["Comedy", "Drama"]),
            item("D", .tvShow, score: 6.0, genres: ["Sci-Fi"]),
            item("E", .movie, score: 5.0, genres: ["Comedy"]),
            item("F", .movie, score: 4.0, genres: ["Action"]),
        ]
    }

    // MARK: empty

    @Test("An empty library yields zeroed, empty stats")
    func emptyStats() {
        let stats = ProfileStats(watched: [])
        #expect(stats.isEmpty)
        #expect(stats.totalWatched == 0)
        #expect(stats.movieCount == 0)
        #expect(stats.tvCount == 0)
        #expect(stats.averageScore == nil)
        #expect(stats.topFive.isEmpty)
    }

    // MARK: counts

    @Test("Totals and the movie/TV split are correct")
    func counts() {
        let stats = ProfileStats(watched: fixture())
        #expect(!stats.isEmpty)
        #expect(stats.totalWatched == 6)
        #expect(stats.movieCount == 4)
        #expect(stats.tvCount == 2)
    }

    // MARK: average

    @Test("Average score is the mean across watched items")
    func averageScore() {
        let stats = ProfileStats(watched: fixture())
        let expected = (9.5 + 8.0 + 7.0 + 6.0 + 5.0 + 4.0) / 6.0
        #expect(abs((stats.averageScore ?? .nan) - expected) < 0.0001)
    }

    // MARK: top 5

    @Test("Top 5 is score-descending and drops the 6th item")
    func topFive() {
        let stats = ProfileStats(watched: fixture())
        #expect(stats.topFive.map(\.title) == ["A", "B", "C", "D", "E"])
        #expect(!stats.topFive.contains { $0.title == "F" })
    }

    // MARK: genres

    // `topGenres` was removed in Phase 19. It ranked by *count*, which answers
    // "what do you watch most" — a duller question than the taste screen's
    // effect-ranked claims, and one that would now contradict them. Two lists
    // disagreeing about the same library is worse than one fewer list. Coverage
    // moved to `TasteAnalysisTests.rankedByEffect`.
}
