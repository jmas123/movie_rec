//
//  MediaService.swift
//  Binged
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

    /// Everything the detail screen shows beyond what `MediaItem` stores — the
    /// runtime, the cast, who directed it, where it is streaming.
    ///
    /// Returns `nil` rather than throwing, and takes no error path at all: this
    /// enriches a screen that already has a title, a poster, an overview and
    /// the user's own ranking on it. A failed lookup should cost the screen its
    /// cast strip, never its content, so "could not fetch" and "TMDB has
    /// nothing" collapse into the same answer.
    ///
    /// - Parameter region: ISO 3166-1 country code deciding which streaming
    ///   services are reported. Passed in rather than read from `Locale` inside
    ///   an implementation so a test can pin it.
    func titleDetails(id: String, region: String) async -> TitleDetails?

    /// Everything a cast member has been in, most prominent first.
    ///
    /// Takes the catalog's own person id — the one `TitleDetails.Person`
    /// carries — rather than a name, because two actors share a name often
    /// enough that resolving one by search would sometimes show the wrong
    /// person's filmography with no way to tell.
    ///
    /// Returns detached `MediaItem`s, like `search`: the caller decides whether
    /// any of them is already in the library. Takes no error path, like
    /// `titleDetails`, and for the same reason — the screen it feeds says
    /// "nobody you follow liked anything of theirs" when the answer is empty,
    /// and an unreachable catalog is not worth a different sentence.
    func personCredits(id: String) async -> [MediaItem]
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

    /// Conformers with no detail payload to offer — the search-only stubs, and
    /// the bundled catalog — report nothing rather than inventing a cast list.
    /// The detail screen renders the sections it has, so "nothing" degrades to
    /// the screen as it was before this existed.
    func titleDetails(id: String, region: String) async -> TitleDetails? {
        nil
    }

    /// Conformers with no catalog to enumerate — the search-only stubs, and the
    /// bundled `MockMediaService`, which has no cast data to be a filmography
    /// *of* — report nothing. The screen reads that as "no credits", which is
    /// the truthful answer from a catalog that has none.
    func personCredits(id: String) async -> [MediaItem] {
        []
    }
}
