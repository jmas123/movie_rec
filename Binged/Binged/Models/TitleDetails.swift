//
//  TitleDetails.swift
//  Binged
//
//  The catalog's answer to "tell me about this title" — the facts a detail
//  screen shows and nothing else stores.
//
//  Deliberately **not** folded into `MediaItem`. `MediaItem` is the persisted
//  entity the ranking buckets are built from, and every property added to it is
//  a row on disk, a column in `ranked_items`, and a conflict to resolve at sync
//  time. A cast list and a streaming provider are neither user data nor input
//  to the ranking: they are catalog trivia that is free to refetch, goes stale
//  on its own schedule (a show leaves Netflix; `MediaItem` should not have to
//  migrate), and is worthless offline anyway. So this is a fetched value type
//  with a lifetime of one screen.
//
//  Everything is optional. TMDB's coverage falls off sharply outside the
//  popular tail, and a title with no tagline, no headshots and no providers is
//  the normal case rather than an error — each section simply does not render.
//

import Foundation

// MARK: - TitleDetails

struct TitleDetails: Sendable, Equatable {

    // MARK: Blurb

    /// The marketing one-liner. Frequently absent, occasionally the same
    /// sentence as the overview's first line, and never load-bearing.
    var tagline: String?

    /// Films carry a single runtime; television carries a representative
    /// episode length. Minutes, and always > 0 when present.
    var runtimeMinutes: Int?

    /// 16:9 still, distinct from the poster. Used as the header wash.
    var backdropURL: String?

    // MARK: Crowd opinion

    /// TMDB's own average, 0–10.
    ///
    /// Shown alongside the user's derived score and never in place of it — the
    /// whole premise of the app is that the user's ranking is the opinion that
    /// counts, so this is labelled as TMDB's and typeset smaller.
    var voteAverage: Double?

    /// How many people that average is over. Shown because "7.4" from 40 voters
    /// and "7.4" from 40,000 are different claims.
    var voteCount: Int?

    // MARK: Production facts

    /// "Released", "Returning Series", "Ended", "In Production".
    var status: String?

    /// ISO 639-1 code, resolved to a display name by `languageName`.
    var originalLanguage: String?

    /// Television only.
    var seasonCount: Int?
    var episodeCount: Int?

    /// First air date / theatrical release, as TMDB's `YYYY-MM-DD`.
    var releaseDateText: String?

    // MARK: People

    /// Director for a film, creator(s) for a series — the label differs, which
    /// is why `creditTitle` exists rather than a bare "Director".
    var directors: [Person]

    /// Top-billed, in billing order for film and by episode count for
    /// television.
    var cast: [Person]

    // MARK: Availability

    /// Subscription streaming in the user's region. Rent and buy are
    /// deliberately excluded: "included with a subscription you may have" and
    /// "£13.99 to own" are different answers to "can I watch this tonight", and
    /// listing them together makes the row useless at a glance.
    var streamingProviders: [Provider]

    /// TMDB's own justwatch page for this title and region. Opened rather than
    /// deep-linking a provider app, because TMDB gives no per-provider URL.
    var providerLink: String?

    // MARK: Init

    init(
        tagline: String? = nil,
        runtimeMinutes: Int? = nil,
        backdropURL: String? = nil,
        voteAverage: Double? = nil,
        voteCount: Int? = nil,
        status: String? = nil,
        originalLanguage: String? = nil,
        seasonCount: Int? = nil,
        episodeCount: Int? = nil,
        releaseDateText: String? = nil,
        directors: [Person] = [],
        cast: [Person] = [],
        streamingProviders: [Provider] = [],
        providerLink: String? = nil
    ) {
        self.tagline = tagline
        self.runtimeMinutes = runtimeMinutes
        self.backdropURL = backdropURL
        self.voteAverage = voteAverage
        self.voteCount = voteCount
        self.status = status
        self.originalLanguage = originalLanguage
        self.seasonCount = seasonCount
        self.episodeCount = episodeCount
        self.releaseDateText = releaseDateText
        self.directors = directors
        self.cast = cast
        self.streamingProviders = streamingProviders
        self.providerLink = providerLink
    }

    /// The device's region, as an ISO 3166-1 code, or the US when the device
    /// declines to say.
    ///
    /// A fallback is needed because the alternative — no region — means no
    /// availability data at all, and TMDB's US coverage is its best. It is a
    /// guess, so the UI never names the country back to the user.
    static var deviceRegion: String {
        Locale.current.region?.identifier ?? "US"
    }

    // MARK: - Person

    /// A credited human. `role` is the character for cast and the job for crew.
    struct Person: Sendable, Equatable, Identifiable {
        /// TMDB's person id, as a string so it can key a `ForEach` without
        /// implying arithmetic on it.
        let id: String
        let name: String
        var role: String?
        var imageURL: String?
    }

    // MARK: - Provider

    struct Provider: Sendable, Equatable, Identifiable {
        let id: String
        let name: String
        var logoURL: String?
    }

    // MARK: - Derived display

    /// "2h 28m", "48m". `nil` when there is no runtime to show, so the caller
    /// omits the field rather than printing a dash.
    var runtimeText: String? {
        guard let runtimeMinutes, runtimeMinutes > 0 else { return nil }
        let hours = runtimeMinutes / 60
        let minutes = runtimeMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    /// "English", "Korean" — resolved through the user's own locale, so a
    /// French speaker reads "coréen" rather than an ISO code.
    var languageName: String? {
        guard let originalLanguage, !originalLanguage.isEmpty else { return nil }
        return Locale.current.localizedString(forLanguageCode: originalLanguage)?.capitalized
    }

    /// "3 seasons · 62 episodes". `nil` for film and for a series TMDB has no
    /// counts for.
    var seasonText: String? {
        var parts: [String] = []
        if let seasonCount, seasonCount > 0 {
            parts.append("\(seasonCount) season\(seasonCount == 1 ? "" : "s")")
        }
        if let episodeCount, episodeCount > 0 {
            parts.append("\(episodeCount) episode\(episodeCount == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "12K", "1.4K", "873" — a vote count is context for the average, not a
    /// figure anyone reads digit by digit.
    var voteCountText: String? {
        guard let voteCount, voteCount > 0 else { return nil }
        if voteCount < 1000 { return String(voteCount) }
        let thousands = Double(voteCount) / 1000
        return thousands < 10
            ? String(format: "%.1fK", thousands)
            : String(format: "%.0fK", thousands)
    }

    /// "Director" / "Directors" for film, "Creator" / "Creators" for TV. The
    /// distinction is real: television credits its showrunner, and calling that
    /// person the director would be wrong on the screen it appears on.
    func creditTitle(for type: MediaType) -> String {
        let singular = type == .movie ? "Director" : "Creator"
        return directors.count > 1 ? singular + "s" : singular
    }

    /// Whether there is anything at all worth drawing. Guards the whole block
    /// so a title TMDB knows nothing about shows the old, shorter screen rather
    /// than a stack of empty headers.
    var isEmpty: Bool {
        tagline == nil
            && runtimeMinutes == nil
            && voteAverage == nil
            && status == nil
            && seasonText == nil
            && languageName == nil
            && directors.isEmpty
            && cast.isEmpty
            && streamingProviders.isEmpty
    }
}
