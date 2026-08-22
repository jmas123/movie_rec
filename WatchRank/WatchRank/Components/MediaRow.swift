//
//  MediaRow.swift
//  WatchRank
//
//  Horizontal list row used in Search, Ranking, and Profile: a small gradient
//  poster, the title with year and type, and an optional trailing score badge.
//

import SwiftUI

// MARK: - MediaRow

/// A single row in a list. The trailing `score` is shown as a rounded badge
/// only when present — unwatched items (search results, the want-to-watch
/// queue) simply omit it.
struct MediaRow: View {

    let title: String
    let year: Int
    let type: MediaType
    var score: Double?

    var body: some View {
        HStack(spacing: 12) {
            PosterPlaceholder(title: title)
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

            if let score {
                ScoreBadge(score: score)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var label = "\(title), \(String(year)), \(type.displayName)"
        if let score {
            label += ", scored \(Self.scoreFormatter.string(from: score as NSNumber) ?? "")"
        }
        return label
    }

    static let scoreFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

// MARK: - ScoreBadge

/// The rounded 0–10 score pill shown on watched rows.
private struct ScoreBadge: View {
    let score: Double

    var body: some View {
        Text(MediaRow.scoreFormatter.string(from: score as NSNumber) ?? "—")
            .font(.callout.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor, in: Capsule())
    }
}

// MARK: - Convenience

extension MediaRow {
    /// Builds a row straight from a model object, surfacing its score when set.
    init(item: MediaItem) {
        self.init(title: item.title, year: item.year, type: item.type, score: item.score)
    }

    /// Score visibility is a library-level decision (a bucket must hold
    /// `MediaLibraryViewModel.minimumBucketSizeForScore` items), so screens
    /// pass the already-resolved value rather than reading `item.score`.
    init(item: MediaItem, score: Double?) {
        self.init(title: item.title, year: item.year, type: item.type, score: score)
    }
}

// MARK: - Previews

#Preview("With score", traits: .sizeThatFitsLayout) {
    List {
        MediaRow(title: "Parasite", year: 2019, type: .movie, score: 9.2)
        MediaRow(title: "Breaking Bad", year: 2008, type: .tvShow, score: 8.7)
    }
}

#Preview("Without score", traits: .sizeThatFitsLayout) {
    List {
        MediaRow(title: "Dune", year: 2021, type: .movie)
        MediaRow(title: "Spider-Man: Into the Spider-Verse", year: 2018, type: .movie)
    }
}
