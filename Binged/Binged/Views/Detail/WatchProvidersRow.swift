//
//  WatchProvidersRow.swift
//  Binged
//
//  Where the user can actually watch this tonight.
//
//  Scoped hard to *subscription* availability. TMDB also reports rent and buy
//  prices, and folding all three into one row would answer a question nobody
//  asked: "available on eleven services" is worthless, while "it's on Netflix"
//  is the reason someone opens a detail screen at all.
//
//  The data is JustWatch's, licensed to TMDB on the condition that it is shown
//  with a link back. `providerLink` carries that link, and the attribution line
//  below is not decoration — it is the terms.
//

import SwiftUI

// MARK: - WatchProvidersRow

struct WatchProvidersRow: View {

    let providers: [TitleDetails.Provider]

    /// JustWatch's page for this title, in the region the availability was
    /// looked up for.
    var link: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Streaming now")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.md) {
                    ForEach(providers) { provider in
                        providerView(provider)
                    }
                }
                .padding(.horizontal, 1)
            }

            if let url = link.flatMap(URL.init(string:)) {
                Link(destination: url) {
                    Label("More ways to watch", systemImage: "arrow.up.right")
                        .font(.footnote.weight(.medium))
                }
            }

            // Required attribution, and honest about the caveat: this is the
            // catalogue's view of a region, and it goes out of date.
            Text("Availability from JustWatch, for your region.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: One provider

    private func providerView(_ provider: TitleDetails.Provider) -> some View {
        VStack(spacing: Spacing.xs) {
            logo(for: provider)
                .frame(width: Self.logoSize, height: Self.logoSize)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(provider.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.columnWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Streaming on \(provider.name)")
    }

    /// Provider logos are square marks on a solid ground, so — unlike a poster
    /// — a failed load has no sensible picture to fall back to. It falls back
    /// to the first letter on a neutral tile instead, which keeps the row's
    /// rhythm without pretending to be the brand.
    @ViewBuilder
    private func logo(for provider: TitleDetails.Provider) -> some View {
        if let url = provider.logoURL.flatMap(URL.init(string:)) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    logoFallback(provider)
                }
            }
        } else {
            logoFallback(provider)
        }
    }

    private func logoFallback(_ provider: TitleDetails.Provider) -> some View {
        ZStack {
            Color(.secondarySystemBackground)
            Text(provider.name.prefix(1))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private static let logoSize: CGFloat = 48
    private static let columnWidth: CGFloat = 56
}

// MARK: - Previews

#if DEBUG
#Preview("Providers", traits: .sizeThatFitsLayout) {
    WatchProvidersRow(
        providers: [
            TitleDetails.Provider(id: "8", name: "Netflix"),
            TitleDetails.Provider(id: "9", name: "Prime Video"),
            TitleDetails.Provider(id: "350", name: "Apple TV+"),
        ],
        link: "https://www.themoviedb.org/movie/496243/watch"
    )
    .padding()
}
#endif
