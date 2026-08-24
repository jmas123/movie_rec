//
//  RankingView.swift
//  Binged
//
//  The hero screen: browse your ranked items by sentiment, collapse sections,
//  and drag-to-reorder within a bucket. A segmented tab filters by media type.
//
//  The type tab lives in the navigation bar rather than in a band beneath it.
//  A band is a second row of chrome under a large title, and between the two of
//  them the first row of the ranking — the thing the screen is for — started a
//  third of the way down the phone. In the bar it costs nothing, and the tab
//  bar already says "Ranking", so the title is not missed. `HomeTabView` puts
//  its Yours/Following switcher in the same place for the same reason.
//
//  Reorder scope: drag-to-reorder is enabled only on the Movies and TV tabs.
//  There the visible list *is* the `(type, sentiment)` bucket, so a move maps
//  1:1 onto what `RankingEngine` rescores. The All tab interleaves two
//  independent rankings by score for browsing, so it is not a bucket and
//  offers no Edit button — see `RankingViewModel.canReorder`. Each sentiment
//  is its own section, so drags can never cross sentiment boundaries either.
//

import SwiftUI

// MARK: - RankingView

struct RankingView: View {

    @State private var viewModel: RankingViewModel
    @State private var expanded: Set<Sentiment> = Set(Sentiment.allCases)
    @State private var editMode: EditMode = .inactive

    /// Sends the user to Search from the empty state. Optional so previews and
    /// tests can build the screen without wiring up navigation.
    private let onBrowse: (() -> Void)?

    init(library: MediaLibraryViewModel, onBrowse: (() -> Void)? = nil) {
        _viewModel = State(initialValue: RankingViewModel(library: library))
        self.onBrowse = onBrowse
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            content
                .navigationTitle("Ranking")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $viewModel.query,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Find in your ranking"
                )
                .environment(\.editMode, $editMode)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("Type", selection: $viewModel.filter) {
                            ForEach(RankingViewModel.TypeFilter.allCases) { filter in
                                Text(filter.displayName).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                    }
                    if viewModel.canReorder && !viewModel.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) { EditButton() }
                    }
                }
                .onChange(of: viewModel.filter) { _, _ in
                    editMode = .inactive // never stay in edit mode on a non-reorderable tab
                }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isEmpty {
            // Two different emptinesses. "Nothing ranked yet" is false and
            // faintly insulting when the user has 200 titles and simply
            // mistyped one, and "Find something to watch" is the wrong way out
            // of it — the way out is clearing the search.
            EmptyStateView(
                systemImage: viewModel.isFiltering ? "magnifyingglass" : "trophy",
                message: viewModel.isFiltering
                    ? "Nothing in your ranking matches “\(viewModel.query)”."
                    : "Nothing ranked yet. Mark something watched to start your ranking.",
                actionTitle: viewModel.isFiltering
                    ? "Clear search"
                    : (onBrowse == nil ? nil : "Find something to watch"),
                action: viewModel.isFiltering ? { viewModel.query = "" } : onBrowse
            )
            // Fill the space below the filter and centre in it. Without this
            // the empty state hugs the picker and leaves a large void beneath.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(Sentiment.allCases) { sentiment in
                    section(for: sentiment)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func section(for sentiment: Sentiment) -> some View {
        let items = viewModel.items(for: sentiment)
        let isExpanded = expanded.contains(sentiment)

        return Section {
            if isExpanded {
                if items.isEmpty {
                    // Seen rendered for the first time on 2026-08-24: two empty
                    // sentiment sections each took a full-width card to say
                    // "Nothing here in this view yet", which is both vague — on
                    // the All tab there is no "view" being filtered — and
                    // heavier than the nothing it describes. Named copy, and a
                    // single quiet line rather than a card.
                    Text(emptyMessage(for: sentiment))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(items, id: \.id) { item in
                        NavigationLink {
                            MediaDetailView(item: item)
                        } label: {
                            MediaRow(item: item, display: viewModel.scoreDisplay(for: item))
                        }
                    }
                    .onMove { offsets, destination in
                        viewModel.move(in: sentiment, from: offsets, to: destination)
                    }
                }
            }
        } header: {
            sectionHeader(sentiment: sentiment, count: items.count, isExpanded: isExpanded)
        }
    }

    /// Copy for a sentiment nobody has used yet. Names the bucket rather than
    /// the screen, so it reads the same on every tab.
    private func emptyMessage(for sentiment: Sentiment) -> String {
        switch sentiment {
        case .liked:    return "Nothing you loved yet."
        case .fine:     return "Nothing middling yet."
        case .disliked: return "Nothing you disliked yet."
        }
    }

    private func sectionHeader(sentiment: Sentiment, count: Int, isExpanded: Bool) -> some View {
        Button {
            toggle(sentiment)
        } label: {
            HStack {
                Text(sentiment.displayName)
                Text("·")
                Text("\(count)")
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(sentiment.displayName), \(count) items, \(isExpanded ? "expanded" : "collapsed")")
    }

    private func toggle(_ sentiment: Sentiment) {
        if expanded.contains(sentiment) {
            expanded.remove(sentiment)
        } else {
            expanded.insert(sentiment)
        }
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func rankingPreviewLibrary() -> MediaLibraryViewModel {
    let library = MediaLibraryViewModel.previewInMemory()

    func add(_ title: String, _ type: MediaType, _ sentiment: Sentiment) {
        let item = MediaItem(title: title, year: 2020, type: type)
        library.markWatched(item, sentiment: sentiment)
        while let pair = library.pendingComparison {
            library.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
        }
        library.finalizeRanking(for: item)
    }

    add("Inception", .movie, .liked)
    add("Parasite", .movie, .liked)
    add("Breaking Bad", .tvShow, .liked)
    add("The Office", .tvShow, .fine)
    add("Some Flop", .movie, .disliked)

    return library
}

#Preview {
    let library = rankingPreviewLibrary()
    return RankingView(library: library)
        .environment(library)
}

#Preview("Empty") {
    let library = MediaLibraryViewModel.previewInMemory()
    return RankingView(library: library)
        .environment(library)
}
#endif
