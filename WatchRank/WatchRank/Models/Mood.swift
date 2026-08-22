//
//  Mood.swift
//  WatchRank
//
//  The word the user taps before they get recommendations.
//
//  A mood and the taste profile are two jobs over the same TMDB metadata, and
//  conflating them is the easy mistake: the taste profile knows *who the user
//  is*, a mood knows *what they want tonight*. Without moods, Discover returns
//  the same list every time it opens — a static personal leaderboard rather
//  than a browsing surface. The mood filters; the engine ranks what survives.
//
//  **These definitions are measured, not guessed.** `docs/MOOD-YIELD.md` records
//  the per-mood yield of every candidate keyword, and it retired seven of the
//  thirty-two originally proposed for returning five or fewer titles. Three
//  moods had named themselves after a tag nobody applies — `feel good` (0
//  titles), `mind bending` (0), `epic` (3). Before adding a keyword here, check
//  its volume; the most on-the-nose tag is routinely the deadest.
//
//  Re-run `scripts/measure_mood_yield.py` to refresh the numbers. Its `MOODS`
//  table is the source this file is ported from, and its `RETIRED` table records
//  what was tried and rejected, so a later session does not re-propose it.
//

import Foundation

// MARK: - MoodKeyword

/// A TMDB keyword, carried as id plus name for the same reason `Feature` does:
/// the id is identity and the query needs it, the name is what makes a
/// definition auditable and a refresh verifiable.
struct MoodKeyword: Hashable, Sendable {
    let id: Int
    let name: String

    init(_ id: Int, _ name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - MoodQueryComponent

/// One TMDB request's worth of a mood.
///
/// A mood is *not* one query. Within a single `/discover` parameter `|` means
/// OR and `,` means AND — but two **different** parameters are AND-ed together,
/// so `with_genres=27&with_keywords=9714` asks for "horror AND supernatural",
/// never "horror OR supernatural". A mood with both a genre basis and a keyword
/// basis therefore needs two requests whose results are unioned client-side.
///
/// Modelling that as a list of components rather than as one query object is
/// deliberate: the AND form returns a plausible, non-empty, silently wrong
/// result, so the type system is a better place to prevent it than a comment.
struct MoodQueryComponent: Sendable, Equatable, Hashable {

    enum Basis: Sendable, Equatable, Hashable {
        /// TMDB genre ids, OR-ed. `names` are carried alongside so an offline
        /// catalog with no TMDB ids can still match, and so a cache key or a
        /// log line reads.
        case genres(ids: [Int], names: [String])
        case keywords(ids: [Int], names: [String])
    }

    let basis: Basis

    /// Overrides the endpoint's per-type default.
    ///
    /// The default floor (300 film / 100 TV) keeps junk out of a popularity
    /// sort, which is free for a broad mood and can be the binding constraint
    /// for a narrow one. A starved mood lowers its own floor rather than
    /// forcing a global loosening that would degrade every other mood.
    let minimumVotes: Int?

    var ids: [Int] {
        switch basis {
        case .genres(let ids, _), .keywords(let ids, _): return ids
        }
    }

    var names: [String] {
        switch basis {
        case .genres(_, let names), .keywords(_, let names): return names
        }
    }

    var isEmpty: Bool { ids.isEmpty }

    /// Stable, readable, and unique per component — used as a cache key
    /// fragment, so it must not depend on `Set` or dictionary ordering.
    var identity: String {
        let kind: String
        switch basis {
        case .genres:   kind = "g"
        case .keywords: kind = "k"
        }
        return "\(kind)\(ids.sorted().map(String.init).joined(separator: "-"))"
    }
}

// MARK: - Mood

enum Mood: String, CaseIterable, Identifiable, Sendable {
    case crime
    case thriller
    case dark
    case horror
    case romance
    case comedy
    case mindBending
    case feelGood
    case trueStory
    case epic

    var id: String { rawValue }

    // MARK: Display

    var displayName: String {
        switch self {
        case .crime:       return "Crime"
        case .thriller:    return "Thriller"
        case .dark:        return "Dark"
        case .horror:      return "Horror"
        case .romance:     return "Romance"
        case .comedy:      return "Comedy"
        case .mindBending: return "Mind-bending"
        case .feelGood:    return "Feel-good"
        case .trueStory:   return "True story"
        case .epic:        return "Epic"
        }
    }

    /// SF Symbols only, per SPEC's UX rules. Chips carry the label too — a
    /// symbol-only control is unusable to VoiceOver, which Phase 18 checks.
    var symbolName: String {
        switch self {
        case .crime:       return "handcuffs"
        case .thriller:    return "bolt.heart"
        case .dark:        return "moon.stars"
        case .horror:      return "theatermask.and.paintbrush"
        case .romance:     return "heart"
        case .comedy:      return "face.smiling"
        case .mindBending: return "arrow.triangle.branch"
        case .feelGood:    return "sun.max"
        case .trueStory:   return "book.closed"
        case .epic:        return "mountain.2"
        }
    }

    // MARK: Definition

    /// TMDB genre names this mood draws on for `type`, in TMDB's own spelling
    /// because this is a query, not display. Empty means the mood is carried by
    /// keywords alone — the normal case for television, whose vocabulary has no
    /// Thriller, Horror or Romance.
    func genreNames(for type: MediaType) -> [String] {
        switch (self, type) {
        case (.crime, _):              return ["Crime"]
        case (.thriller, .movie):      return ["Thriller"]
        case (.thriller, .tvShow):     return ["Mystery"]
        case (.horror, .movie):        return ["Horror"]
        case (.romance, .movie):       return ["Romance"]
        case (.comedy, _):             return ["Comedy"]
        case (.epic, .movie):          return ["Adventure"]
        case (.epic, .tvShow):         return ["Sci-Fi & Fantasy"]
        default:                       return []
        }
    }

    /// Measured keyword bases. Volumes in comments are (film / television)
    /// title counts above the vote floor, from `docs/MOOD-YIELD.md`.
    func keywords(for type: MediaType) -> [MoodKeyword] {
        switch (self, type) {
        case (.thriller, .tvShow):
            return [.init(316362, "thriller"),            // 7 / 132
                    .init(288394, "suspense")]            // 17 / 80

        case (.dark, .movie):
            return [.init(207268, "neo-noir"),            // 173 / 30
                    .init(4565, "dystopia"),              // 265 / 55
                    .init(12565, "psychological thriller"),  // 110 / 52
                    .init(1541, "nihilism")]              // 21 / 1
        case (.dark, .tvShow):
            return [.init(207268, "neo-noir"),
                    .init(4565, "dystopia"),
                    .init(12565, "psychological thriller"),
                    .init(10123, "dark comedy")]          // 232 / 105

        case (.horror, .tvShow):
            return [.init(315058, "horror"),              // 58 / 127
                    .init(6152, "supernatural"),          // 208 / 218
                    .init(12377, "zombie"),               // 141 / 31
                    .init(10224, "haunting"),             // 27 / 6
                    .init(3133, "vampire")]               // 114 / 60

        case (.romance, .tvShow):
            return [.init(9840, "romance"),               // 133 / 443
                    .init(128, "love triangle"),          // 77 / 61
                    .init(9799, "romcom")]                // 139 / 99

        case (.mindBending, .movie):
            return [.init(4379, "time travel"),           // 165 / 101
                    .init(10937, "memory"),               // 41 / 4
                    .init(157171, "nonlinear timeline"),  // 19 / 3
                    .init(10854, "time loop")]            // 28 / 9
        case (.mindBending, .tvShow):
            return [.init(4379, "time travel"),
                    .init(33465, "parallel world"),       // 25 / 33
                    .init(10937, "memory"),
                    .init(10854, "time loop")]

        case (.feelGood, .movie):
            return [.init(6054, "friendship"),            // 351 / 215
                    .init(10683, "coming of age"),        // 248 / 106
                    .init(1415, "small town")]            // 196 / 58
        case (.feelGood, .tvShow):
            return [.init(6054, "friendship"),
                    .init(10683, "coming of age"),
                    .init(210605, "workplace comedy")]    // 6 / 47

        case (.trueStory, _):
            // `based on a true story` is the same id, and `historical event`
            // (5 / 3) was retired — see MOOD-YIELD.md.
            return [.init(9672, "based on true story"),   // 629 / 74
                    .init(5565, "biography")]             // 352 / 29

        case (.epic, .movie):
            return [.init(234213, "sword and sorcery"),   // 36 / 19
                    .init(207372, "quest")]               // 39 / 8
        case (.epic, .tvShow):
            return [.init(234213, "sword and sorcery")]

        default:
            return []
        }
    }

    /// The one-to-two TMDB requests this mood needs for `type`.
    ///
    /// Genre names are resolved through the live vocabulary rather than
    /// hardcoded ids, so a mood naming a genre its type does not have yields a
    /// missing component instead of a silently empty query.
    func queryComponents(
        for type: MediaType,
        vocabulary: TMDBGenreVocabulary
    ) -> [MoodQueryComponent] {
        var components: [MoodQueryComponent] = []

        let names = genreNames(for: type)
        let genreIds = names.compactMap { vocabulary.tmdbGenreId(named: $0, type: type) }
        if !genreIds.isEmpty {
            components.append(
                MoodQueryComponent(
                    basis: .genres(ids: genreIds, names: names),
                    minimumVotes: minimumVotes(for: type)
                )
            )
        }

        let keys = keywords(for: type)
        if !keys.isEmpty {
            components.append(
                MoodQueryComponent(
                    basis: .keywords(ids: keys.map(\.id), names: keys.map(\.name)),
                    minimumVotes: minimumVotes(for: type)
                )
            )
        }

        return components
    }

    /// `nil` uses the endpoint's per-type default. No mood needs an override
    /// today — the thinnest, `trueStory` on television, still measured 94
    /// titles above the standard floor. The hook exists because tag volumes
    /// drift and a future mood may be narrower than any of these.
    func minimumVotes(for type: MediaType) -> Int? { nil }

    // MARK: Relevance

    /// How well a candidate matches, `0...1`.
    ///
    /// Binary today: pool membership is a hard filter, which is far easier to
    /// validate than a graded score. The signature is a `Double` so grading
    /// later is a change to this function body rather than a refactor through
    /// `Recommendation`, the view model and the Discover screen.
    ///
    /// - Important: before grading, ranking must already apply relevance to the
    ///   taste **lift** rather than to the predicted value — see roadmap Phase
    ///   15 step 4. Multiplying a raw 0–10 prediction by relevance scales the
    ///   baseline too, and the baseline is most of the number while being
    ///   identical for every candidate of a type, so relevance stops
    ///   contributing and starts dominating.
    func relevance(isPoolMember: Bool) -> Double {
        isPoolMember ? 1.0 : 0.0
    }
}
