//
//  HomeView.swift
//  Binged
//
//  The landing screen: four horizontally-scrolling rails (top movies, top TV,
//  recently watched, want to watch) plus a floating "+" that presents Search.
//  No view model — the rails read straight off `MediaLibraryViewModel` from the
//  environment, so they update live as the ranking changes.
//
//  The screen supplies no `NavigationStack` or title of its own: `HomeTabView`
//  owns both, because it shares one navigation bar with the feed and puts the
//  Yours/Following switcher in it. Two stacks would mean two bars.
//

import SwiftUI

// MARK: - HomeView

struct HomeView: View {

    @Environment(MediaLibraryViewModel.self) private var library

    /// Catalog source handed to the modally-presented `SearchView`.
    let service: MediaService

    @State private var showSearch = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                rail(
                    "Top Movies",
                    systemImage: "film",
                    emptyMessage: "Rank some movies to see your top picks.",
                    items: library.topMovies
                )
                rail(
                    "Top TV Shows",
                    systemImage: "tv",
                    emptyMessage: "Rank some shows to see your top picks.",
                    items: library.topShows
                )
                rail(
                    "Recently Watched",
                    systemImage: "clock",
                    emptyMessage: "Nothing watched yet.",
                    items: library.recentlyWatched
                )
                rail(
                    "Want to Watch",
                    systemImage: "bookmark",
                    emptyMessage: "Your watchlist is empty.",
                    items: library.wantToWatch,
                    seeAll: true
                )
            }
            .padding(.vertical)
            .padding(.bottom, Spacing.floatingButtonClearance)
        }
        .overlay(alignment: .bottomTrailing) { addButton }
        .sheet(isPresented: $showSearch) {
            SearchView(service: service)
        }
    }

    // MARK: Rail

    private func rail(
        _ title: String,
        systemImage: String,
        emptyMessage: String,
        items: [MediaItem],
        seeAll: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text(title)
                    .font(.title3.weight(.bold))
                Spacer()
                // The rail is capped at five, and until now that cap was the
                // whole watchlist as far as the UI was concerned — a sixth
                // queued title could not be reached from anywhere.
                if seeAll, !items.isEmpty {
                    NavigationLink("See all") {
                        WatchlistView(onBrowse: { showSearch = true })
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal)

            if items.isEmpty {
                EmptyStateView(
                    systemImage: systemImage,
                    message: emptyMessage,
                    style: .inline,
                    actionTitle: "Browse",
                    action: { showSearch = true }
                )
                .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(items, id: \.id) { item in
                            NavigationLink {
                                MediaDetailView(item: item)
                            } label: {
                                MediaCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    // MARK: Add button

    private var addButton: some View {
        Button {
            showSearch = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: Circle())
                .shadow(radius: 6, y: 3)
        }
        .padding()
        .accessibilityLabel("Add a title")
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func homePreviewLibrary() -> MediaLibraryViewModel {
    let library = MediaLibraryViewModel.previewInMemory()

    func watched(_ title: String, _ type: MediaType, _ sentiment: Sentiment) {
        let item = MediaItem(title: title, year: 2019, type: type)
        library.markWatched(item, sentiment: sentiment)
        while let pair = library.pendingComparison {
            library.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
        }
        library.finalizeRanking(for: item)
    }

    watched("Inception", .movie, .liked)
    watched("Parasite", .movie, .liked)
    watched("Breaking Bad", .tvShow, .liked)
    watched("The Office", .tvShow, .fine)
    library.addToWantToWatch(MediaItem(title: "Dune", year: 2021, type: .movie))
    library.addToWantToWatch(MediaItem(title: "Severance", year: 2022, type: .tvShow))

    return library
}

#Preview {
    let library = homePreviewLibrary()
    return NavigationStack { HomeView(service: MockMediaService()) }
        .environment(library)
}

#Preview("Empty") {
    NavigationStack { HomeView(service: MockMediaService()) }
        .environment(MediaLibraryViewModel.previewInMemory())
}
#endif
