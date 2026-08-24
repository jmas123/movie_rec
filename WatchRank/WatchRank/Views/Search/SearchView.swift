//
//  SearchView.swift
//  WatchRank
//
//  The Search tab: a `.searchable` field over the catalog, a list of
//  `MediaRow`s, and `EmptyStateView`s for the pre-search and no-results
//  states. Tapping a row opens the title's detail.
//

import SwiftUI

// MARK: - SearchView

struct SearchView: View {

    @State private var viewModel: SearchViewModel

    /// Needed to resolve catalog results against titles already in the
    /// library — see `MediaLibraryViewModel.canonicalItem(for:)`.
    @Environment(MediaLibraryViewModel.self) private var library

    /// Whether this screen is the visible tab. Leaving the tab clears the
    /// query, so returning to Search starts fresh rather than showing stale
    /// text and results from a previous visit. Defaults to `true` for the
    /// modal presentation from Home, which is torn down on dismiss anyway.
    var isActive: Bool = true

    /// - Parameter service: catalog source, injected so the same screen can
    ///   run against the mock or a future TMDB service.
    init(service: MediaService, isActive: Bool = true) {
        _viewModel = State(initialValue: SearchViewModel(service: service))
        self.isActive = isActive
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            content
                .navigationTitle("Search")
                .searchable(
                    text: $viewModel.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Movies & TV shows"
                )
                .autocorrectionDisabled()
                .onSubmit(of: .search) {
                    Task { await viewModel.search() }
                }
                .onChange(of: isActive) { _, nowActive in
                    // Clearing the query cascades through its `didSet` and
                    // resets results, phase, and any in-flight task.
                    if !nowActive { viewModel.query = "" }
                }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
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
                message: "No matches for “\(viewModel.query)”.",
                actionTitle: "Clear search",
                action: { viewModel.query = "" }
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
}
#endif
