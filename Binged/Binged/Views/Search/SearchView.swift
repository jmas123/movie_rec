//
//  SearchView.swift
//  Binged
//
//  The Search tab: a `.searchable` field, a scope for what it searches, a list
//  of results, and `EmptyStateView`s for the pre-search and no-results states.
//
//  **Why people are searched here.** They were not, and the effect was that the
//  app looked like it had no way to find friends at all. The only door was an
//  unlabelled `person.badge.plus` menu on the *Home* tab, visible only when
//  signed in — so somebody looking for people went to the tab with the
//  magnifying glass, found it searched films, and concluded the feature did not
//  exist. Every comparable app puts both behind one magnifying glass.
//
//  **The query is shared across scopes, deliberately.** Switching from Titles to
//  People keeps what you typed and searches it as a handle. The alternative —
//  a query per scope — changes the text under the user when they switch, which
//  reads as the app having lost their input. The cost is one wasted request
//  when a film title is searched as a handle; that is cheaper than the
//  confusion.
//
//  **The scope picker is a principal segmented control, not `.searchScopes`.**
//  A scope bar only appears once the search field is focused, and this screen
//  exists because a control nobody could see was a control nobody used. The
//  principal picker is the same idiom `RankingView` and `HomeTabView` already
//  use, and it is on screen the moment the tab opens.
//

import SwiftUI

// MARK: - SearchView

struct SearchView: View {

    @State private var viewModel: SearchViewModel

    /// Nil on a build with no Supabase credentials, where there is no graph to
    /// search and the scope picker never appears.
    @State private var people: UserSearchViewModel?

    /// Needed to resolve catalog results against titles already in the
    /// library — see `MediaLibraryViewModel.canonicalItem(for:)`.
    @Environment(MediaLibraryViewModel.self) private var library

    /// Optional so the screen still builds in a preview or a test rig with no
    /// session in the environment. Absent is treated as signed out, which is
    /// the honest reading: with no session there is nobody to search as.
    @Environment(SessionViewModel.self) private var session: SessionViewModel?

    /// Whether this screen is the visible tab. Leaving the tab clears the
    /// query, so returning to Search starts fresh rather than showing stale
    /// text and results from a previous visit. Defaults to `true` for the
    /// modal presentation from Home, which is torn down on dismiss anyway.
    var isActive: Bool = true

    /// The catalog, kept so a profile pushed from a People result can open the
    /// titles on somebody else's ranking.
    private let service: MediaService
    private let socialService: SocialService?
    private let rankingFeedService: RankingFeedService?
    private let feedService: FeedService?

    /// The live search text, owned here rather than by either view model,
    /// because one field feeds both.
    @State private var query: String = ""
    @State private var scope: Scope = .titles

    // MARK: Scope

    enum Scope: String, CaseIterable, Identifiable {
        case titles, people
        var id: String { rawValue }
        var title: String { self == .titles ? "Titles" : "People" }
    }

    /// - Parameters:
    ///   - service: catalog source, injected so the same screen can run
    ///     against the mock or TMDB.
    ///   - socialService: the graph. Nil removes the People scope entirely
    ///     rather than offering a scope that can never answer.
    init(
        service: MediaService,
        isActive: Bool = true,
        socialService: SocialService? = nil,
        rankingFeedService: RankingFeedService? = nil,
        feedService: FeedService? = nil
    ) {
        _viewModel = State(initialValue: SearchViewModel(service: service))
        _people = State(initialValue: socialService.map(UserSearchViewModel.init(service:)))
        self.service = service
        self.isActive = isActive
        self.socialService = socialService
        self.rankingFeedService = rankingFeedService
        self.feedService = feedService
    }

    /// Whether there is anywhere to go looking. Signed out there is no graph to
    /// search, and on a build with no server there is no search at all — the
    /// same test `HomeTabView` applies to its People menu.
    private var canFindPeople: Bool {
        people != nil && (session?.isSignedIn ?? false)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(canFindPeople ? .inline : .large)
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: scope == .people ? "Handle or name" : "Movies & TV shows"
                )
                .autocorrectionDisabled()
                // Handles are lower-case by constraint (`^[a-z0-9_]{3,20}$`),
                // so capitalising the first letter fights the user on every
                // people search. Titles do not care either way.
                .textInputAutocapitalization(scope == .people ? .never : .sentences)
                .toolbar {
                    if canFindPeople {
                        ToolbarItem(placement: .principal) {
                            Picker("Search for", selection: $scope) {
                                ForEach(Scope.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                        }
                    }
                }
                // Registered on the stack, so a People result can push a
                // profile the same way the Home tab's search does.
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
                // A title tapped on somebody else's ranking. Registered here
                // too, because a profile pushed into *this* stack must resolve
                // its rows in this stack — a destination declared inside
                // `UserProfileView` would shadow one of the two.
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
                .onSubmit(of: .search) {
                    // Only the catalog honours submit; people search is
                    // debounce-only and has already run by now.
                    if scope == .titles { Task { await viewModel.search() } }
                }
                .onChange(of: query) { _, text in propagate(text) }
                .onChange(of: scope) { _, _ in propagate(query) }
                .onChange(of: isActive) { _, nowActive in
                    if !nowActive { reset() }
                }
                // Signed out mid-session, there is no graph left to be
                // searching — and the scope picker is about to disappear from
                // under a scope that is still selected.
                .onChange(of: session?.isSignedIn ?? false) { _, signedIn in
                    if !signedIn && scope == .people { scope = .titles }
                }
        }
    }

    // MARK: Query plumbing

    /// Feeds the active scope's view model, and only that one. Searching both
    /// on every keystroke would double the request rate to show one of the
    /// answers.
    ///
    /// The inequality guard matters on a scope switch: if that view model has
    /// already answered this exact query, its results are still there and
    /// re-assigning would throw them away and re-fetch.
    private func propagate(_ text: String) {
        switch scope {
        case .titles:
            if viewModel.query != text { viewModel.query = text }
        case .people:
            if let people, people.query != text { people.query = text }
        }
    }

    /// Clearing cascades through each view model's `didSet`, resetting results,
    /// phase, and any in-flight task.
    private func reset() {
        query = ""
        scope = .titles
        if viewModel.query != "" { viewModel.query = "" }
        if let people, people.query != "" { people.query = "" }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch scope {
        case .titles: titles
        case .people:
            if let people {
                UserSearchResults(viewModel: people, rankings: rankingFeedService)
            }
        }
    }

    @ViewBuilder
    private var titles: some View {
        switch viewModel.phase {
        case .prompt:
            EmptyStateView(
                systemImage: "magnifyingglass",
                message: "Search for a movie or show to get started."
            )

        case .searching:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Searching the catalog")

        case .results:
            resultsList

        case .noResults:
            EmptyStateView(
                systemImage: "film",
                message: "No matches for \u{201C}\(viewModel.query)\u{201D}.",
                actionTitle: "Clear search",
                action: { query = "" }
            )

        case .error(let message):
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                message: message,
                actionTitle: "Try again",
                action: { Task { await viewModel.search() } }
            )
        }
    }

    private var resultsList: some View {
        List(viewModel.results, id: \.id) { result in
            // A catalog hit is a fresh object every search. If this title is
            // already in the library, show that copy instead so the row and
            // its detail screen reflect real state (watched, score) rather
            // than an unranked duplicate — and so marking it watched again
            // updates the existing entry instead of inserting a second one.
            let item = library.canonicalItem(for: result)
            NavigationLink {
                MediaDetailView(item: item)
            } label: {
                MediaRow(item: item, display: library.scoreDisplay(for: item))
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    SearchView(service: MockMediaService())
        .environment(MediaLibraryViewModel.previewInMemory())
        .environment(SessionViewModel(service: MockAuthService()))
}
#endif
