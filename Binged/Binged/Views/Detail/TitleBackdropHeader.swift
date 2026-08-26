//
//  TitleBackdropHeader.swift
//  Binged
//
//  The top of the detail screen: a full-bleed still with the poster and title
//  sitting on it.
//
//  The centred poster it replaces was honest but anonymous — every title looked
//  like every other title, and the first screenful said little more than the
//  row the user tapped to get here. A backdrop is the cheapest way to make a
//  page feel like it is about *this* film.
//
//  It degrades in one step: with no backdrop URL — an obscure title, a build on
//  the bundled catalog, a slow network — the layout falls back to the centred
//  poster, which is the design that shipped before this file existed.
//

import SwiftUI

// MARK: - TitleBackdropHeader

struct TitleBackdropHeader: View {

    let item: MediaItem

    /// `nil` until the detail fetch lands, and permanently `nil` for a title
    /// TMDB has no still for.
    var backdropURL: String?

    /// The line under the title: year, type, and whatever facts arrived.
    var subtitle: String

    /// The marketing one-liner, when there is one worth printing.
    var tagline: String?

    var body: some View {
        if let url = backdropURL.flatMap(URL.init(string:)) {
            backdropLayout(url: url)
        } else {
            centredLayout
        }
    }

    // MARK: With a backdrop

    private func backdropLayout(url: URL) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        // The poster's own gradient, reused so the header has
                        // the title's colours while the still loads rather than
                        // a grey block that then jumps.
                        PosterPlaceholder(title: item.title, cornerRadius: 0)
                    }
                }
                .frame(height: Self.backdropHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                // Text sits on the lower third, and a still is whatever
                // brightness it happens to be. The scrim is what keeps the
                // title legible over a snow scene.
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.15), .black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                HStack(alignment: .bottom, spacing: Spacing.md) {
                    PosterView(title: item.title, posterURL: item.posterURL)
                        .frame(width: 92, height: 138)
                        .shadow(radius: 6, y: 3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .minimumScaleFactor(0.7)
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .shadow(radius: 4)
                    .padding(.bottom, Spacing.sm)
                }
                .padding(.horizontal, Spacing.lg)
                // Lets the poster hang below the still, which is what stops the
                // header reading as one flat rectangle.
                .padding(.bottom, -Spacing.section)
            }
            .padding(.bottom, Spacing.section)

            if let tagline {
                taglineText(tagline)
                    .padding(.horizontal, Spacing.lg)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Without one

    private var centredLayout: some View {
        VStack(spacing: Spacing.lg) {
            PosterView(title: item.title, posterURL: item.posterURL)
                .frame(width: 160, height: 240)
                .shadow(radius: 8, y: 4)

            VStack(spacing: Spacing.xs) {
                Text(item.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let tagline {
                    taglineText(tagline)
                        .multilineTextAlignment(.center)
                        .padding(.top, Spacing.xs)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.lg)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Pieces

    private func taglineText(_ tagline: String) -> some View {
        Text(tagline)
            .font(.callout.italic())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One announcement rather than four. VoiceOver reading "Dune. 2021, Film.
    /// Beyond fear, destiny awaits." as three separate stops is three swipes to
    /// learn what a sighted user reads at a glance.
    private var accessibilityLabel: String {
        var label = "\(item.title). \(subtitle)"
        if let tagline { label += ". \(tagline)" }
        return label
    }

    /// Tall enough to read as an image rather than a band, short enough that
    /// the user's own score is still on the first screenful — which is the
    /// thing this app exists to show them.
    private static let backdropHeight: CGFloat = 200
}

// MARK: - Previews

#if DEBUG
#Preview("No backdrop", traits: .sizeThatFitsLayout) {
    TitleBackdropHeader(
        item: MediaItem(title: "Parasite", year: 2019, type: .movie),
        subtitle: "2019 · Film · 2h 12m",
        tagline: "Act like you own the place."
    )
}
#endif
