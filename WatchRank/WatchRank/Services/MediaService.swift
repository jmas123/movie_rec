//
//  MediaService.swift
//  WatchRank
//
//  Abstraction over the source of catalog metadata. The MVP ships with a
//  `MockMediaService` backed by a bundled JSON file, but the protocol is
//  written so a TMDB-backed implementation can be a single-class swap-in
//  later without touching call sites.
//

import Foundation

// MARK: - MediaService

/// A catalog data source for searching and looking up titles.
///
/// MVP simplicity: the protocol returns persisted model objects (`MediaItem`)
/// directly rather than DTOs. Conforming types are free to construct fresh,
/// un-inserted `MediaItem` instances — the caller decides if and when to
/// attach them to a `ModelContext`.
protocol MediaService {

    /// Returns titles whose `title` or `overview` match `query` using a
    /// case-insensitive substring search. An empty `query` returns an empty
    /// list. Implementations may apply additional sorting or relevance
    /// ranking, but order within the returned array is not guaranteed by the
    /// protocol.
    func search(query: String) async throws -> [MediaItem]

    /// Looks up a single title by its catalog `externalId` (e.g., TMDB id).
    /// Returns `nil` if no such title exists in the source.
    func fetch(id: String) async throws -> MediaItem?

    /// Returns one page of popular titles of `type`, most popular first.
    ///
    /// This is the primitive the recommendation candidate pool is paged out of
    /// (roadmap Phase 14): search answers "the title I already have in mind",
    /// this answers "what is there to recommend at all". Paging is explicit
    /// rather than hidden behind an unbounded fetch, because the caller is
    /// building a bounded pool and needs to decide when to stop.
    ///
    /// `page` is 1-based, matching TMDB. A page past the end returns an empty
    /// array rather than throwing — running off the end is a normal outcome of
    /// paging, not an error.
    func popularTitles(type: MediaType, page: Int) async throws -> [MediaItem]
}

// MARK: - Default catalog enumeration

extension MediaService {

    /// Conformers that cannot enumerate a catalog — the search-only stubs used
    /// in tests — report an empty catalog rather than being forced to invent
    /// one. Returning empty is safe: the pool builder treats it as "no more
    /// pages", which is exactly what a service with nothing to enumerate means.
    func popularTitles(type: MediaType, page: Int) async throws -> [MediaItem] {
        []
    }
}
