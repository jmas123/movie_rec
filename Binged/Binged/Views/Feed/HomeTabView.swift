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

    /// The one place this stack's navigation lives.
    ///
    /// **Every push in this tab goes through here, and that is the whole
    /// point.** A `NavigationStack` keeps one destination per data type: when
    /// two views inside it both declare a destination for `PersonRoute` —
    /// which is what happened when `FeedView` registered its own alongside the
    /// one below — SwiftUI keeps one and silently drops the other, and every
    /// `NavigationLink(value:)` in the losing half stops doing anything at all.
    /// The tap highlights, the list redraws, nothing opens. Search results,
    /// follower lists and follow requests were all dead this way.
    ///
    /// `isPresented`-based destinations were the same hazard from the other
    /// direction: pushing a value onto a stack that is already showing one can
    /// dismiss it. So: one path, one destination per type, no exceptions.
    @State private var path = NavigationPath()

    /// How many people are waiting to be let in. There is no push notification
    /// in this app, so this badge is the only way a request announces itself.
    @State private var requests = PendingRequestBadge()
    @Environment(\.scenePhase) private var scenePhase

    /// The screens this tab pushes that are not addressed by a model value.
    enum Destination: Hashable {
        case peopleSearch
        case followRequests
    }

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
        NavigationStack(path: $path) {
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
                            Button { path.append(Destination.peopleSearch) } label: {
                                Label("Find People", systemImage: "magnifyingglass")
                            }
                            Button { path.append(Destination.followRequests) } label: {
                                // The count is repeated inside the menu because
                                // the bubble outside it says only that
                                // *something* is waiting, not what.
                                Label(
                                    requests.text.map { "Follow Requests (\($0))" }
                                        ?? "Follow Requests",
                                    systemImage: "tray"
                                )
                            }
                        } label: {
                            Image(systemName: "person.badge.plus")
                                .overlay(alignment: .topTrailing) { bubble }
                        }
                        .accessibilityLabel(requests.accessibilityLabel)
                    }
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .peopleSearch:
                    if let socialService {
                        UserSearchView(service: socialService, rankings: rankingFeedService)
                    }
                case .followRequests:
                    FollowRequestsView(service: socialService, rankings: rankingFeedService)
                }
            }
            // Registered once, on the stack, so a profile can be opened from
            // the feed, from search, from a follower list and from a follow
            // request without any of them knowing about the others.
            .navigationDestination(for: PersonRoute.self) { route in
                if let socialService, let rankingFeedService {
                    UserProfileView(
                        handle: route.handle,
                        social: socialService,
                        rankings: rankingFeedService,
                        feed: feedService,
                        catalog: service
                    )
                }
            }
            .navigationDestination(for: FeedPost.self) { post in
                if let feedService {
                    PostDetailView(
                        post: post,
                        service: feedService,
                        viewerID: session.profile?.id,
                        social: socialService,
                        onOpenTitle: { path.append($0) }
                    )
                }
            }
            // A title lifted off somebody else's ranking.
            .navigationDestination(for: TitleReference.self) { reference in
                ForeignTitleView(reference: reference, catalog: service)
            }
            .navigationDestination(for: FollowListRoute.self) { route in
                if let socialService {
                    FollowListView(
                        direction: route.direction,
                        subject: route.subject,
                        service: socialService,
                        rankings: rankingFeedService
                    )
                }
            }
        }
        // Signed out mid-session, there is no "Following" to be looking at.
        .onChange(of: session.isSignedIn) { _, signedIn in
            if !signedIn { scope = .yours }
        }
        // Three triggers, because a request arrives while the app is closed and
        // there is nothing to push it here: sign-in state settling at launch,
        // coming back to the foreground, and leaving the screen that answers
        // them — where the count has just changed by however many were answered.
        .task(id: session.isSignedIn) { await refreshRequestCount() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshRequestCount() }
        }
        .onChange(of: path.isEmpty) { _, atRoot in
            // Back at the root, which is where you land after answering
            // requests — and the count has just changed by however many.
            guard atRoot else { return }
            Task { await refreshRequestCount() }
        }
    }

    private func refreshRequestCount() async {
        await requests.refresh(using: socialService, isSignedIn: session.isSignedIn)
    }

    /// The count bubble on the people icon. Nothing at all when nothing waits —
    /// an empty badge is a permanent alarm about no news.
    @ViewBuilder
    private var bubble: some View {
        if let text = requests.text {
            Text(text)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.red, in: Capsule())
                .offset(x: 10, y: -8)
                // The toolbar button already says it in full.
                .accessibilityHidden(true)
        }
    }

    private var feed: some View {
        FeedView(
            service: feedService,
            social: socialService,
            rankings: rankingFeedService,
            isSignedIn: { session.isSignedIn },
            viewerID: { session.profile?.id },
            viewerHandle: { session.profile?.handle },
            // Was wired to the *movie* search tab, which meant "find people"
            // led somewhere that cannot find people. It stays inside this
            // stack now, because that is where a profile can be pushed.
            onOpenPerson: rankingFeedService == nil ? nil : { path.append($0) },
            onOpenPost: { path.append($0) },
            // Routed through the stack's own `TitleReference` destination, the
            // same one a title tapped on somebody's profile uses — so a film
            // opens identically whichever social surface it was tapped on.
            onOpenTitle: { path.append($0) },
            onFindPeople: { path.append(Destination.peopleSearch) },
            onSignIn: onSignIn
        )
    }

    /// Whether there is anywhere to go looking. Signed out there is no graph to
    /// search, and on a build with no server there is no search at all.
    private var canFindPeople: Bool {
        socialService != nil && session.isSignedIn
    }
}
