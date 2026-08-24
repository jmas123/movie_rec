//
//  MediaRow.swift
//  Binged
//
//  Horizontal list row used in Search, Ranking, and Profile: the poster, the
//  title with year and type, and a trailing badge saying where the title
//  stands.
//
//  The badge is driven by `ScoreDisplay`, not by a bare `Double?`. A row whose
//  bucket has not yet earned a number still has something true to say — "#2" in
//  its sentiment — and rule 6 asks for exactly that. Passing an optional score
//  could only express "number" or "silence", which made a ranked title in a
//  small bucket indistinguishable from an unwatched one.
//

import SwiftUI

// MARK: - MediaRow

/// A single row in a list. The trailing badge follows `display`: a score pill
/// once the bucket has earned one, a quieter rank pill while it has not, and
/// nothing at all for unwatched items (search results, the want-to-watch
/// queue).
struct MediaRow: View {

    let title: String
    let year: Int
    let type: MediaType
    var display: ScoreDisplay = .none
    /// Real artwork when the catalogue supplied it. `PosterView` falls back to
    /// the gradient on a nil URL or a failed load, so this is never worse than
    /// the placeholder it replaces.
    var posterURL: String?

    var body: some View {
        HStack(spacing: Spacing.md) {
            PosterView(title: title, posterURL: posterURL)
                .frame(width: 48, height: 72)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text("\(String(year)) · \(type.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            badge
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Badge

    @ViewBuilder
    private var badge: some View {
        switch display {
        case .score(let value):
            ScoreBadge(score: value)
        case .rank(let position, _):
            RankBadge(position: position)
        case .sentimentOnly, .none:
            EmptyView()
        }
    }

    private var accessibilityLabel: String {
        var label = "\(title), \(String(year)), \(type.displayName)"
        if let description = display.accessibilityDescription {
            label += ", \(description)"
        }
        return label
    }
}

// MARK: - ScoreBadge

/// The rounded 0–10 score pill shown once a bucket has earned a number.
private struct ScoreBadge: View {
    let score: Double

    var body: some View {
        Text(ScoreDisplay.formatter.string(from: score as NSNumber) ?? "—")
            .font(.callout.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor, in: Capsule())
    }
}

// MARK: - RankBadge

/// The position pill shown while a score is still withheld. Deliberately
/// quieter than `ScoreBadge` — an outline rather than a filled capsule — so the
/// two are never confused at a glance: "#2" is a place in a short list, "8.4" is
/// a rating the app stands behind.
private struct RankBadge: View {
    let position: Int

    var body: some View {
        Text("#\(position)")
            .font(.callout.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            )
    }
}

// MARK: - Convenience

extension MediaRow {
    /// Builds an unadorned row from a model object — no badge. Used where the
    /// row is not about ranking (search results before the library is
    /// consulted, the want-to-watch queue).
    init(item: MediaItem) {
        self.init(
            title: item.title, year: item.year, type: item.type,
            posterURL: item.posterURL
        )
    }

    /// Score visibility is a library-level decision (it depends on the size of a
    /// bucket the row cannot see), so screens pass the resolved
    /// `MediaLibraryViewModel.scoreDisplay(for:)` rather than reading
    /// `item.score` themselves.
    init(item: MediaItem, display: ScoreDisplay) {
        self.init(
            title: item.title, year: item.year, type: item.type,
            display: display, posterURL: item.posterURL
        )
    }
}

// MARK: - Previews

#Preview("With score", traits: .sizeThatFitsLayout) {
    List {
        MediaRow(title: "Parasite", year: 2019, type: .movie, display: .score(9.2))
        MediaRow(title: "Breaking Bad", year: 2008, type: .tvShow, display: .score(8.7))
    }
}

#Preview("Score withheld", traits: .sizeThatFitsLayout) {
    List {
        MediaRow(title: "Parasite", year: 2019, type: .movie,
                 display: .rank(position: 1, sentiment: .liked))
        MediaRow(title: "Arrival", year: 2016, type: .movie,
                 display: .rank(position: 2, sentiment: .liked))
    }
}

#Preview("No badge", traits: .sizeThatFitsLayout) {
    List {
        MediaRow(title: "Dune", year: 2021, type: .movie)
        MediaRow(title: "Spider-Man: Into the Spider-Verse", year: 2018, type: .movie)
    }
}
