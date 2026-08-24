//
//  DiscoverView.swift
//  WatchRank
//
//  The recommendation surface: pick a type, pick a mood, see unwatched titles
//  with predicted ratings.
//
//  Two-step rather than a single scrolling feed, because the two controls answer
//  different questions and collapsing them would hide that. The type picker
//  selects which of the user's two independent rankings to predict from — films
//  and shows have separate baselines, so this is not a filter but a change of
//  model. The mood picker says what they are in the market for tonight.
//

import SwiftUI

// MARK: - DiscoverView

struct DiscoverView: View {

    let recommender: RecommendationViewModel

    /// Sends the user to Search when there is nothing useful to do here — a
    /// cold-start empty state with no way out is a dead end.
    var onBrowse: () -> Void = {}

    @Environment(MediaLibraryViewModel.self) private var library

    @State private var type: MediaType = .movie
    @State private var mood: Mood?
    @State private var result: RecommendationResult?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    typePicker
                    moodGrid
                }

                resultsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Discover")
            .task(id: requestKey) { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: - Controls

    private var typePicker: some View {
        Picker("Media type", selection: $type) {
            ForEach(MediaType.allCases) { type in
                Text(type.displayName + "s").tag(type)
            }
        }
        .pickerStyle(.segmented)
        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.lg,
                                  bottom: Spacing.sm, trailing: Spacing.lg))
    }

    private var moodGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 108), spacing: Spacing.sm)],
            spacing: Spacing.sm
        ) {
            ForEach(Mood.allCases) { candidate in
                MoodChip(mood: candidate, isSelected: candidate == mood) {
                    mood = candidate == mood ? nil : candidate
                }
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if mood == nil {
            Section {
                EmptyStateView(
                    systemImage: "sparkles",
                    message: "Pick a mood to see what we think you'd rate highly.",
                    style: .inline
                )
            }
        } else if isLoading && result == nil {
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                        .accessibilityLabel("Finding recommendations")
                    Spacer()
                }
                .padding(.vertical, Spacing.section)
            }
        } else if let result {
            switch result {
            case .ready(let recommendations) where !recommendations.isEmpty:
                Section {
                    ForEach(recommendations) { recommendation in
                        NavigationLink {
                            MediaDetailView(item: recommendation.item)
                        } label: {
                            RecommendationRow(
                                recommendation: recommendation,
                                onQueue: {
                                    // The guess is frozen here so the app can be
                                    // graded on what it actually said.
                                    library.addToWantToWatch(
                                        recommendation.item,
                                        predicted: recommendation.predicted.displayValue
                                    )
                                },
                                onDismiss: {
                                    library.dismiss(recommendation.item)
                                    Task { await load() }
                                }
                            )
                        }
                    }
                } header: {
                    Text("For you")
                } footer: {
                    Text("Predicted ratings are estimates from your own rankings — "
                         + "not scores you've given.")
                }

            case .ready:
                Section { noCandidates(poolIsEmpty: false) }

            case .needsMoreRankings(let have, let need, let shortType):
                Section { coldStart(have: have, need: need, type: shortType) }

            case .noCandidates(let poolIsEmpty):
                Section { noCandidates(poolIsEmpty: poolIsEmpty) }
            }
        }
    }

    // MARK: - States

    /// Names the exact number still needed, and which kind. "Rank 4 more shows"
    /// is actionable in a way "rank more titles" is not — and the per-type
    /// baselines mean a large film library genuinely says nothing about TV.
    private func coldStart(have: Int, need: Int, type shortType: MediaType?) -> some View {
        let remaining = max(0, need - have)
        let noun: String
        switch shortType {
        case .some(.movie):  noun = remaining == 1 ? "film" : "films"
        case .some(.tvShow): noun = remaining == 1 ? "show" : "shows"
        case nil:            noun = remaining == 1 ? "title" : "titles"
        }

        return EmptyStateView(
            systemImage: "chart.bar.doc.horizontal",
            message: "Rank \(remaining) more \(noun) and we can start predicting "
                   + "what you'd score things.",
            style: .inline,
            actionTitle: "Find something to rank",
            action: onBrowse
        )
    }

    private func noCandidates(poolIsEmpty: Bool) -> some View {
        // Two genuinely different situations, and telling them apart is the
        // difference between "try again later" and "try another mood".
        EmptyStateView(
            systemImage: poolIsEmpty ? "wifi.slash" : "magnifyingglass",
            message: poolIsEmpty
                ? "We haven't been able to load anything to recommend yet. "
                  + "Check your connection and pull to refresh."
                : "Nothing left in this mood — you've seen them all. Try another.",
            style: .inline
        )
    }

    // MARK: - Loading

    /// Re-runs whenever either control changes, so `.task(id:)` cancels the
    /// in-flight request instead of racing it.
    private var requestKey: String { "\(type.rawValue)|\(mood?.rawValue ?? "none")" }

    private func load() async {
        guard let mood else {
            result = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        result = await recommender.recommendations(type: type, mood: mood)
    }
}

// MARK: - MoodChip

/// A mood button. Label *and* symbol, never symbol alone — a symbol-only
/// control is unusable to VoiceOver, and moods are this screen's primary
/// control.
private struct MoodChip: View {

    let mood: Mood
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xs) {
                Image(systemName: mood.symbolName)
                    .font(.title3)
                Text(mood.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .accessibilityLabel(mood.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    let library = MediaLibraryViewModel.previewInMemory()
    return DiscoverView(
        recommender: RecommendationViewModel(
            library: library,
            poolBuilder: CandidatePoolBuilder(source: MockMediaService())
        )
    )
    .environment(library)
}
#endif
