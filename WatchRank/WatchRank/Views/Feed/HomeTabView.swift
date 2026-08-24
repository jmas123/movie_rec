//
//  HomeTabView.swift
//  WatchRank
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
//  large "WatchRank" title.
//

import SwiftUI

// MARK: - HomeTabView

struct HomeTabView: View {

    @Environment(SessionViewModel.self) private var session

    let service: MediaService
    let feedService: FeedService?
    let socialService: SocialService?
    var onFindPeople: () -> Void = {}
    var onSignIn: () -> Void = {}

    @State private var scope: Scope = .yours

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
            .navigationTitle("WatchRank")
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
            isSignedIn: { session.isSignedIn },
            viewerID: { session.profile?.id },
            onFindPeople: onFindPeople,
            onSignIn: onSignIn
        )
    }
}
