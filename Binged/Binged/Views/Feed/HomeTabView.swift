//
//  HomeTabView.swift
//  Binged
//
//  Home and the feed, in one tab.
//
//  **Why they share a slot.** The tab bar was full at five after Discover, and a
//  sixth tab does not become a sixth tab on iOS — it becomes a "More" list, and
//  whatever lands there is effectively hidden. So one of the six had to give.
//
//  Neither Home nor the feed could simply be cut: Home is the personal dashboard
//  the whole app feeds, and a social app whose feed is buried is not a social
//  app. But they answer the same question — "what's going on?" — for two
//  different subjects, which makes them a natural pair rather than an awkward
//  merge. "Yours" is your library; "Following" is everyone else's.
//
//  The switcher only appears when signed in. Signed out there is nothing on the
//  other side, and offering an empty half would advertise a feature as missing
//  rather than as optional.
//
//  **Where the switcher lives.** In the navigation bar, as the principal item,
//  not in a band above it. A band is a second row of chrome: it pushes the
//  first rail a title's height further down, and because it sits outside the
//  navigation stack it stays on screen over pushed detail screens, where there
//  is nothing to switch. In the bar it costs no vertical space and leaves with
//  the root screen. Signed out there is no switcher, so the bar goes back to a
//  large "Binged" title.
//

import SwiftUI

// MARK: - HomeTabView

struct HomeTabView: View {

    @Environment(SessionViewModel.self) private var session

    let service: MediaService
    let feedService: FeedService?
    let socialService: SocialService?
    /// Somebody else's ranking, for the profiles reached from here. Previously
    /// accepted by `RootTabView` and never read by anything — the whole
    /// ranking-feed feature was inert for want of this one hand-off.
    let rankingFeedService: RankingFeedService?
    var onSignIn: () -> Void = {}

    @State private var scope: Scope = .yours
    @State private var showPeopleSearch = false
    @State private var showRequests = false

    enum Scope: String, CaseIterable, Identifiable {
        case yours, following
        var id: String { rawValue }
        var title: String { self == .yours ? "Yours" : "Following" }
    }

    /// Only worth switching when there is something on the other side.
    private var showsSwitcher: Bool { session.isSignedIn }

    var body: some View {
        // One stack for both halves: switching scope swaps the content under a
        // navigation bar that stays put, and a pushed detail covers the bar.
        NavigationStack {
            Group {
                switch scope {
                case .yours:     HomeView(service: service)
                case .following: feed
                }
            }
            // The title stays set even when the switcher sits on top of it: it
            // is what a pushed detail screen labels its back button with.
            .navigationTitle("Binged")
            .navigationBarTitleDisplayMode(showsSwitcher ? .inline : .large)
            .toolbar {
                if showsSwitcher {
                    ToolbarItem(placement: .principal) {
                        Picker("Scope", selection: $scope) {
                            ForEach(Scope.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                    }
                }
                if canFindPeople {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { showPeopleSearch = true } label: {
                                Label("Find People", systemImage: "magnifyingglass")
                            }
                            Button { showRequests = true } label: {
                                Label("Follow Requests", systemImage: "tray")
                            }
                        } label: {
                            Image(systemName: "person.badge.plus")
                        }
                        .accessibilityLabel("People")
                    }
                }
            }
            .navigationDestination(isPresented: $showPeopleSearch) {
                if let socialService {
                    UserSearchView(service: socialService, rankings: rankingFeedService)
                }
            }
            .navigationDestination(isPresented: $showRequests) {
                FollowRequestsView(service: socialService, rankings: rankingFeedService)
            }
            // Registered once, on the stack, so a profile can be opened from
            // the feed and from search without either knowing about the other.
            .navigationDestination(for: PersonRoute.self) { route in
                if let socialService, let rankingFeedService {
                    UserProfileView(
                        handle: route.handle,
                        social: socialService,
                        rankings: rankingFeedService
                    )
                }
            }
        }
        // Signed out mid-session, there is no "Following" to be looking at.
        .onChange(of: session.isSignedIn) { _, signedIn in
            if !signedIn { scope = .yours }
        }
    }

    private var feed: some View {
        FeedView(
            service: feedService,
            social: socialService,
            rankings: rankingFeedService,
            isSignedIn: { session.isSignedIn },
            viewerID: { session.profile?.id },
            // Was wired to the *movie* search tab, which meant "find people"
            // led somewhere that cannot find people. It stays inside this
            // stack now, because that is where a profile can be pushed.
            onFindPeople: { showPeopleSearch = true },
            onSignIn: onSignIn
        )
    }

    /// Whether there is anywhere to go looking. Signed out there is no graph to
    /// search, and on a build with no server there is no search at all.
    private var canFindPeople: Bool {
        socialService != nil && session.isSignedIn
    }
}
