//
//  DiscoverView.swift
//  Binged
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

    /// Remembered across launches. Discover previously opened on a blank mood
    /// grid every single time — plain `@State`, no default — so the screen's
    /// first frame was always an empty state, however many times the user had
    /// picked the same mood.
    @AppStorage("discover.mediaType") private var storedType: String = MediaType.movie.rawValue
    @AppStorage("discover.mood") private var storedMood: String = ""

    private var type: MediaType {
        get { MediaType(rawValue: storedType) ?? .movie }
        nonmutating set { storedType = newValue.rawValue }
    }

    private var mood: Mood? {
        get { storedMood.isEmpty ? nil : Mood(rawValue: storedMood) }
        nonmutating set { storedMood = newValue?.rawValue ?? "" }
    }
    @State private var result: RecommendationResult?
    @State private var isLoading = false

    /// The most recent "Not for me", offered back for as long as the user stays
    /// on this screen.
    @State private var lastDismissed: DismissedTitle?

    /// How many rows to ask for. Discover previously returned a fixed 20 with
    /// no way to see a twenty-first, which is a hard stop on a browsing screen.
    @State private var visibleLimit = RecommendationViewModel.pageSize

    private struct DismissedTitle: Identifiable, Equatable {
        let id: UUID
        let title: String
    }

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
            .safeAreaInset(edge: .bottom) { undoBar }
            .task(id: requestKey) {
                visibleLimit = RecommendationViewModel.pageSize
                await load()
            }
            .refreshable { await load() }
        }
    }

    // MARK: - Controls

    /// A one-item undo for the last "Not for me". Sits above the list rather
    /// than in an alert: a dismissal is a small, cheap action and interrupting
    /// it with a modal would cost more attention than the mistake does.
    @ViewBuilder
    private var undoBar: some View {
        if let dismissed = lastDismissed {
            HStack(spacing: Spacing.md) {
                Text("Hid \(dismissed.title)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                Button("Undo") {
                    if let item = library.allItems.first(where: { $0.id == dismissed.id }) {
                        library.undismiss(item)
                    }
                    lastDismissed = nil
                    Task { await load() }
                }
                .font(.footnote.weight(.semibold))
                Button {
                    lastDismissed = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Dismiss undo")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(.bar)
        }
    }

    /// Explicit, because `type` is computed over `@AppStorage` and so has no
    /// projected value to take a `$` from.
    private var typeSelection: Binding<MediaType> {
        Binding(get: { type }, set: { type = $0 })
    }

    private var typePicker: some View {
        Picker("Media type", selection: typeSelection) {
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
                        let placement = recommendations.firstIndex {
                            $0.id == recommendation.id
                        } ?? 0
                        NavigationLink {
                            // Canonicalised, exactly as `SearchView` does it.
                            // A recommendation carries a freshly minted,
                            // detached `MediaItem`; Discover deliberately keeps
                            // already-queued titles, so pushing the detached
                            // copy opened a detail screen that reported
                            // `.untracked` for something already in the library
                            // — and marking it watched inserted a *second* row.
                            // `canonicalItem`'s own doc comment describes this
                            // failure, including that the comparison flow can
                            // then pit the film against itself.
                            MediaDetailView(item: library.canonicalItem(for: recommendation.item))
                        } label: {
                            RecommendationRow(
                                recommendation: recommendation,
                                placement: placement,
                                onQueue: {
                                    // Canonicalised for the same reason as the
                                    // push above: these write paths take a
                                    // detached item, and `insertIfNeeded` turns
                                    // a detached duplicate into a second row.
                                    // The row suppresses this action when a
                                    // title is already queued, but that guard is
                                    // one derived flag away from being wrong.
                                    //
                                    // The guess is frozen here so the app can be
                                    // graded on what it actually said.
                                    library.addToWantToWatch(
                                        library.canonicalItem(for: recommendation.item),
                                        predicted: recommendation.predicted.displayValue
                                    )
                                },
                                onDismiss: {
                                    let item = library.canonicalItem(for: recommendation.item)
                                    library.dismiss(item)
                                    // `undismiss` has existed since Phase 17
                                    // and only tests ever called it, so a
                                    // mis-swipe was permanent and silent — the
                                    // row simply vanished on the next load.
                                    lastDismissed = DismissedTitle(
                                        id: item.id, title: item.title
                                    )
                                    Task { await load() }
                                }
                            )
                        }
                    }
                    // Only offered when the last request came back full: a
                    // short page means the pool is exhausted for this mood, and
                    // a button that returns the same list is worse than none.
                    if recommendations.count >= visibleLimit {
                        Button {
                            Task { await showMore() }
                        } label: {
                            if isLoading {
                                HStack { Spacer(); ProgressView(); Spacer() }
                            } else {
                                Text("Show More")
                                    .frame(maxWidth: .infinity)
                                    .font(.callout.weight(.semibold))
                            }
                        }
                        .disabled(isLoading)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("For you")
                        Text("Ordered by your taste and selected mood")
                            .font(.caption)
                            .textCase(nil)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Open a title for its predicted enjoyment. Match labels are "
                         + "relative to this list, not scores you've given.")
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
        result = await recommender.recommendations(type: type, mood: mood, limit: visibleLimit)
    }

    /// Extends the list by one page.
    ///
    /// A re-request rather than an append, which is safe because the genre cap
    /// is computed from a fixed basis: a longer request is a strict
    /// prefix-preserving superset of a shorter one, so rows already on screen
    /// keep their place. See `RecommendationViewModel.applyGenreCap`.
    private func showMore() async {
        visibleLimit += RecommendationViewModel.pageSize
        await load()
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
