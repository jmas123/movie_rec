//
//  RankingView.swift
//  WatchRank
//
//  The hero screen: browse your ranked items by sentiment, collapse sections,
//  and drag-to-reorder within a bucket. A segmented tab filters by media type.
//
//  Reorder scope (decision for this phase): drag-to-reorder is enabled only on
//  the "All" tab. There the visible list is the entire sentiment bucket, so a
//  move maps 1:1 onto what `RankingEngine` rescore. On the Movies/TV tabs the
//  list is a subset, so reordering is disabled (no Edit button) — see
//  `RankingViewModel.canReorder`. Each sentiment is its own section, so drags
//  can never cross sentiment boundaries either.
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
            VStack(spacing: 0) {
                Picker("Type", selection: $viewModel.filter) {
                    ForEach(RankingViewModel.TypeFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                content
            }
            .navigationTitle("Ranking")
            .environment(\.editMode, $editMode)
            .toolbar {
                if viewModel.canReorder && !viewModel.isEmpty {
                    EditButton()
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
            EmptyStateView(
                systemImage: "trophy",
                message: "Nothing ranked yet. Mark something watched to start your ranking.",
                actionTitle: onBrowse == nil ? nil : "Find something to watch",
                action: onBrowse
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
                    Text("Nothing here in this view yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items, id: \.id) { item in
                        NavigationLink {
                            MediaDetailView(item: item)
                        } label: {
                            MediaRow(item: item, score: viewModel.displayScore(for: item))
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
