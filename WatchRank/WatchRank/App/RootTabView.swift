//
//  RootTabView.swift
//  WatchRank
//
//  The app's tab bar: Home, Search, Discover, Ranking, Profile. Each tab owns its own
//  NavigationStack, so pushes and the Compare sheet present over the active tab
//  rather than replacing the whole UI. Dependencies are handed in from the App
//  layer: the shared `MediaLibraryViewModel` (also placed in the environment so
//  child screens and pushed detail views can read it) and the `MediaService`.
//

import SwiftUI

// MARK: - RootTabView

struct RootTabView: View {

    /// The five tabs, so empty-state CTAs can send the user somewhere useful
    /// instead of leaving them on a screen with nothing to do.
    enum Tab: Hashable {
        case home, search, discover, ranking, profile
    }

    let library: MediaLibraryViewModel
    let service: MediaService

    /// Optional so a build without a live catalog — the mock, or a missing API
    /// key — simply has no Discover tab rather than a tab that can never
    /// answer. An empty screen the user can tap into is worse than one that is
    /// not offered.
    var recommender: RecommendationViewModel?

    @State private var selection: Tab = .home

    var body: some View {
        TabView(selection: $selection) {
            HomeView(service: service)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)

            SearchView(service: service, isActive: selection == .search)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            if let recommender {
                DiscoverView(recommender: recommender, onBrowse: { selection = .search })
                    .tabItem { Label("Discover", systemImage: "sparkles") }
                    .tag(Tab.discover)
            }

            RankingView(library: library, onBrowse: { selection = .search })
                .tabItem { Label("Ranking", systemImage: "trophy") }
                .tag(Tab.ranking)

            ProfileView(onBrowse: { selection = .search })
                .tabItem { Label("Profile", systemImage: "person") }
                .tag(Tab.profile)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    let library = MediaLibraryViewModel.previewInMemory()
    let mock = MockMediaService()
    return RootTabView(
        library: library,
        service: mock,
        recommender: RecommendationViewModel(
            library: library,
            poolBuilder: CandidatePoolBuilder(source: mock)
        )
    )
    .environment(library)
}
#endif
