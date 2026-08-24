//
//  RootTabView.swift
//  Binged
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

    /// Social services, absent on a build with no Supabase credentials.
    var feedService: FeedService?
    var socialService: SocialService?
    /// Handed to `HomeTabView`, which owns the stack a profile is pushed onto.
    var rankingFeedService: RankingFeedService?

    @State private var selection: Tab = .home

    /// Whether the first-run explainer has been seen. Read here rather than
    /// inside `WelcomeView` so the sheet is only ever built when it is needed.
    @AppStorage("onboarding.hasSeenWelcome") private var hasSeenWelcome = false

    private var showWelcome: Binding<Bool> {
        Binding(get: { !hasSeenWelcome }, set: { if !$0 { hasSeenWelcome = true } })
    }

    private var saveErrorPrompt: Binding<Bool> {
        Binding(
            get: { library.lastSaveError != nil },
            set: { if !$0 { library.lastSaveError = nil } }
        )
    }

    var body: some View {
        TabView(selection: $selection) {
            // Home and the feed share this slot: a sixth tab becomes a "More"
            // list on iOS, which is where features go to be forgotten. See
            // `HomeTabView`.
            HomeTabView(
                service: service,
                feedService: feedService,
                socialService: socialService,
                rankingFeedService: rankingFeedService,
                onSignIn: { selection = .profile }
            )
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

            ProfileView(onBrowse: { selection = .search }, socialService: socialService)
                .tabItem { Label("Profile", systemImage: "person") }
                .tag(Tab.profile)
        }
        // Presented here, not per screen: a save can fail from Detail, Compare
        // or Ranking, and until now every one of those failures was discarded
        // silently while the UI kept showing the new ranking.
        // The comparison flow cannot be explained by an empty state: empty
        // states say *that* there is nothing here, not why the app refuses to
        // let you type an 8.4. Presented over the tab bar so it is the first
        // thing on screen, once.
        .sheet(isPresented: showWelcome) { WelcomeView() }
        .alert("Your change wasn't saved", isPresented: saveErrorPrompt) {
            Button("OK") { library.lastSaveError = nil }
        } message: {
            Text((library.lastSaveError ?? "")
                 + "\n\nYour most recent change may not have been stored. "
                 + "Check the Ranking tab before making more.")
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
