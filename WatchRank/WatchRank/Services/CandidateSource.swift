//
//  CandidateSource.swift
//  WatchRank
//
//  The one thing `CandidatePoolBuilder` needs from a catalog.
//
//  Narrower than `MediaService` on purpose, following the precedent
//  `FeatureSource` set in Phase 12. Widening `MediaService` would force a
//  mood-shaped method onto the seven search-only stubs the test suite already
//  has, and moods are not something every catalog has an opinion about — they
//  are a recommendation concern, and this keeps them out of the protocol every
//  screen depends on.
//

import Foundation

// MARK: - CandidateSource

protocol CandidateSource: Sendable {

    /// One page of one component of a mood, most popular first.
    ///
    /// A page past the end returns an empty array rather than throwing, matching
    /// `MediaService.popularTitles` — running off the end is a normal outcome of
    /// paging, not an error.
    func discover(
        type: MediaType,
        component: MoodQueryComponent,
        page: Int
    ) async throws -> [MediaItem]

    /// The genre tables, needed to turn a mood's genre *names* into ids.
    ///
    /// Returns `.empty` rather than throwing when they cannot be loaded, which
    /// costs the genre components of every mood and leaves the keyword ones
    /// working. That asymmetry is deliberate: television's moods are mostly
    /// keyword-based anyway, so a vocabulary outage degrades Discover rather
    /// than emptying it.
    func genreVocabulary() async -> TMDBGenreVocabulary

    /// Refreshes a keyword id from its name.
    ///
    /// Not on the cold-start path — `Mood` ships with measured ids — so this is
    /// a verification and drift-correction hook. `nil` means "leave the stored
    /// id alone", exactly as `IMDbResolver` does for external ids.
    func resolveKeywordId(_ name: String) async -> Int?
}

// MARK: - Defaults

extension CandidateSource {

    /// Conformers with no catalog to enumerate report an empty one rather than
    /// being forced to invent it. The builder reads empty as "no more pages".
    func discover(
        type: MediaType,
        component: MoodQueryComponent,
        page: Int
    ) async throws -> [MediaItem] {
        []
    }

    func genreVocabulary() async -> TMDBGenreVocabulary { .empty }

    func resolveKeywordId(_ name: String) async -> Int? { nil }
}
