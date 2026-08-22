//
//  TMDBGenreVocabulary.swift
//  WatchRank
//
//  Translates TMDB's two genre vocabularies into the single internal one the
//  rest of the app — and the recommendation engine in particular — depends on.
//
//  TMDB does not have *a* genre list; it has one for film and a different one
//  for television, and they disagree in ways that quietly corrupt a taste
//  profile if passed through raw:
//
//    - Film says "Science Fiction". The app (and the existing library, seeded
//      from MockMedia.json) says "Sci-Fi". Left alone, these are two unrelated
//      features and the evidence behind each is halved.
//    - Television has no Science Fiction genre at all. It has "Sci-Fi &
//      Fantasy" — one id covering two concepts that are separate for film.
//      Same for "Action & Adventure" and "War & Politics".
//    - Television has no Thriller, Horror, or Romance genre whatsoever. That
//      is not something normalization can fix; roadmap Phase 14 handles it
//      with keyword-backed moods. This type only makes sure that what TMDB
//      *does* say arrives under one spelling.
//
//  Genre *names* are normalized rather than ids, because the id tables are
//  fetched at runtime (they are TMDB's to change) while the names are the
//  stable, human-meaningful thing. An unrecognised name passes through
//  untouched, so a new TMDB genre degrades to "an extra feature" rather than
//  to a decode failure.
//

import Foundation

// MARK: - TMDBGenreVocabulary

struct TMDBGenreVocabulary: Sendable, Equatable {

    private let movieNamesById: [Int: String]
    private let tvNamesById: [Int: String]

    // MARK: Init

    init(movie: [TMDBGenreDTO] = [], tv: [TMDBGenreDTO] = []) {
        movieNamesById = Dictionary(movie.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        tvNamesById = Dictionary(tv.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// The vocabulary before the genre lists have loaded — or when they failed
    /// to. Titles mapped through it carry no genres, which is honest: an empty
    /// genre list means "unknown", and the predictor already treats a title
    /// with no features as one it cannot say anything about.
    static let empty = TMDBGenreVocabulary()

    var isEmpty: Bool { movieNamesById.isEmpty && tvNamesById.isEmpty }

    // MARK: Lookup

    /// Resolves the bare genre ids that `/search/*` and `/discover/*` return.
    func canonicalGenres(ids: [Int], type: MediaType) -> [String] {
        let table = type == .movie ? movieNamesById : tvNamesById
        return canonicalGenres(names: ids.compactMap { table[$0] })
    }

    /// Resolves the full genre objects that `/movie/{id}` and `/tv/{id}` return.
    func canonicalGenres(names: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for name in names {
            for canonical in Self.canonical(name) where seen.insert(canonical).inserted {
                ordered.append(canonical)
            }
        }
        return ordered
    }

    /// Resolves a TMDB genre *name* back to its id for this type.
    ///
    /// The inverse of `canonicalGenres(ids:type:)`, and it takes TMDB's own
    /// spelling rather than the app's canonical one: a mood is a *query*, so it
    /// names genres the way the endpoint does. `nil` means this type's
    /// vocabulary has no such genre — which is the normal case, not an error.
    /// Television has no Thriller, Horror or Romance, and a mood naming one is
    /// expected to fall back to its keyword basis.
    func tmdbGenreId(named name: String, type: MediaType) -> Int? {
        let table = type == .movie ? movieNamesById : tvNamesById
        return table.first { $0.value == name }?.key
    }

    // MARK: Normalization

    /// TMDB genre name to canonical app genre name(s).
    ///
    /// One name can produce two: TMDB's combined television genres cover two
    /// film concepts each, and splitting them is what lets a sci-fi series and
    /// a sci-fi film contribute to the same feature. The reverse — collapsing
    /// two names into one — is what `"Science Fiction" -> "Sci-Fi"` does.
    static func canonical(_ tmdbName: String) -> [String] {
        if let mapped = renames[tmdbName] { return mapped }
        return [tmdbName]
    }

    /// Only entries that genuinely differ appear here. Everything TMDB and the
    /// app already spell the same way — Drama, Comedy, Horror, Thriller,
    /// Romance, Animation, Documentary, Crime, Mystery, Western, History,
    /// Music, Family, Fantasy — is left alone on purpose, so this table stays
    /// short enough to audit.
    private static let renames: [String: [String]] = [
        // Film's spelling differs from the app's established one.
        "Science Fiction": ["Sci-Fi"],

        // Television's combined genres, split into the film concepts they cover.
        "Sci-Fi & Fantasy": ["Sci-Fi", "Fantasy"],
        "Action & Adventure": ["Action", "Adventure"],

        // "Politics" has no film counterpart and would be a feature supported
        // only ever by television, so it is dropped rather than invented.
        "War & Politics": ["War"],

        // Television's children's genre is film's Family genre under a
        // different name.
        "Kids": ["Family"],
    ]
}
