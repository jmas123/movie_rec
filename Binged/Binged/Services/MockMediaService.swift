//
//  MockMediaService.swift
//  Binged
//
//  Bundle-backed `MediaService` used in the MVP. Loads `MockMedia.json` from
//  the main bundle on first access, decodes a flat list of catalog entries,
//  and performs an in-memory case-insensitive substring search across title
//  and overview.
//

import Foundation

// MARK: - MockMediaService

final class MockMediaService: MediaService, CandidateSource {

    // MARK: Configuration

    /// Resource name (without extension) of the seed JSON in the bundle.
    private let resourceName: String

    /// Bundle to look up the seed JSON in. Injectable so unit tests can pass
    /// the test bundle without touching the main app bundle.
    private let bundle: Bundle

    /// Artificial delay applied to every async call so the UI doesn't flash
    /// instant results. 50 ms is below human perception of jank but is just
    /// enough to let loading states render.
    private let artificialDelay: Duration

    // MARK: State

    /// Cached entries, decoded lazily on first use. Stored as DTOs so we can
    /// mint fresh `MediaItem` instances for every call (callers may insert
    /// them into a `ModelContext`, and a `@Model` reference can only belong
    /// to one context at a time).
    private var cachedEntries: [Entry]?

    // MARK: Init

    init(
        resourceName: String = "MockMedia",
        bundle: Bundle = .main,
        artificialDelay: Duration = .milliseconds(50)
    ) {
        self.resourceName = resourceName
        self.bundle = bundle
        self.artificialDelay = artificialDelay
    }

    // MARK: MediaService

    func search(query: String) async throws -> [MediaItem] {
        try await sleepArtificially()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let needle = trimmed.lowercased()
        let entries = try loadEntries()
        return entries
            .filter { entry in
                entry.title.lowercased().contains(needle)
                    || entry.overview.lowercased().contains(needle)
            }
            .map { $0.makeMediaItem() }
    }

    func fetch(id: String) async throws -> MediaItem? {
        try await sleepArtificially()
        // Accepts either form of an IMDb id, since a caller may hold an id
        // minted before namespacing existed.
        let wanted = ExternalID.canonical(id)
        let entries = try loadEntries()
        return entries.first { ExternalID.canonical($0.externalId) == wanted }?.makeMediaItem()
    }

    /// The bundled catalog has no popularity signal, so "popular" here means
    /// "in file order" — stable, deterministic, and honest about being a
    /// stand-in. This exists so the offline path can still build a candidate
    /// pool; when the network is up, `TMDBMediaService` supplies a real
    /// popularity ordering.
    func popularTitles(type: MediaType, page: Int) async throws -> [MediaItem] {
        try await sleepArtificially()
        guard page >= 1 else { return [] }

        let matching = try loadEntries().filter { $0.type == type }
        let start = (page - 1) * Self.pageSize
        guard start < matching.count else { return [] }
        let end = min(start + Self.pageSize, matching.count)
        return matching[start..<end].map { $0.makeMediaItem() }
    }

    /// Matches TMDB's fixed page size, so paging logic written against one
    /// service behaves identically against the other.
    static let pageSize = 20

    // MARK: - CandidateSource

    /// Serves a mood's **genre** component by matching canonical genre names.
    ///
    /// Keyword components return empty: the bundled catalog has no TMDB keyword
    /// ids and inventing them would be worse than admitting the gap. So offline
    /// Discover is thinner — the keyword-only moods are quiet — rather than
    /// broken, which is the same trade `popularTitles` makes.
    func discover(
        type: MediaType,
        component: MoodQueryComponent,
        page: Int
    ) async throws -> [MediaItem] {
        try await sleepArtificially()
        guard page >= 1, !component.isEmpty else { return [] }

        guard case .genres(_, let names) = component.basis else { return [] }
        let wanted = Set(TMDBGenreVocabulary.empty.canonicalGenres(names: names))

        let matching = try loadEntries().filter { entry in
            entry.type == type && !wanted.isDisjoint(with: Set(entry.genres))
        }

        let start = (page - 1) * Self.pageSize
        guard start < matching.count else { return [] }
        let end = min(start + Self.pageSize, matching.count)
        return matching[start..<end].map { $0.makeMediaItem() }
    }

    // MARK: Loading

    private func loadEntries() throws -> [Entry] {
        if let cached = cachedEntries { return cached }

        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw LoadError.resourceNotFound(resourceName)
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let entries = try decoder.decode([Entry].self, from: data)
        cachedEntries = entries
        return entries
    }

    private func sleepArtificially() async throws {
        guard artificialDelay > .zero else { return }
        try await Task.sleep(for: artificialDelay)
    }

    // MARK: - Entry (decode-only DTO)

    /// A single record in `MockMedia.json`. Kept private because nothing
    /// outside the service should know about the on-disk shape.
    private struct Entry: Decodable {
        let externalId: String
        let title: String
        let year: Int
        let type: MediaType
        let overview: String
        let genres: [String]

        /// Optional so an entry written before features existed still decodes.
        /// A missing key means "not tagged", which is how `MediaItem.features`
        /// reads an empty array anyway.
        ///
        /// The bundled catalog only ever supplies genre features — it has no
        /// credits, keywords, or runtimes — so an offline item is a genuinely
        /// thinner signal than a TMDB-backed one, not an equivalent to it.
        let features: [String]?

        func makeMediaItem() -> MediaItem {
            MediaItem(
                // Namespaced so the source of an id is never ambiguous — the
                // bundled catalog's ids are IMDb ids, and TMDB's are not.
                externalId: ExternalID.canonical(externalId),
                title: title,
                year: year,
                type: type,
                overview: overview,
                genres: genres,
                features: features ?? genres.map { Feature.genre($0).key }
            )
        }
    }

    // MARK: - Errors

    enum LoadError: Error, CustomStringConvertible {
        case resourceNotFound(String)

        var description: String {
            switch self {
            case .resourceNotFound(let name):
                return "MockMediaService: could not find \(name).json in bundle."
            }
        }
    }
}
