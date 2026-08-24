//
//  MediaCard.swift
//  Binged
//
//  Vertical poster card used on Home rails: the poster with the title and year
//  stacked beneath it. Falls back to a gradient when there is no artwork.
//

import SwiftUI

// MARK: - MediaCard

/// A compact vertical card for horizontally scrolling rails. Sized by `width`;
/// the poster keeps a 2:3 movie-poster aspect ratio.
struct MediaCard: View {

    let title: String
    let year: Int
    var width: CGFloat = 120
    var posterURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterView(title: title, posterURL: posterURL)
                .frame(width: width, height: width * 1.5)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)

            Text(String(year))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(String(year))")
    }
}

// MARK: - Convenience

extension MediaCard {
    /// Builds a card straight from a model object.
    init(item: MediaItem, width: CGFloat = 120) {
        self.init(title: item.title, year: item.year, width: width, posterURL: item.posterURL)
    }
}

// MARK: - Previews

#Preview("Standard", traits: .sizeThatFitsLayout) {
    MediaCard(title: "Interstellar", year: 2014)
        .padding()
}

#Preview("Long title", traits: .sizeThatFitsLayout) {
    MediaCard(title: "Spider-Man: Into the Spider-Verse", year: 2018)
        .padding()
}
