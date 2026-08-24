//
//  CompareView.swift
//  Binged
//
//  The pairwise comparison modal — the moment that defines the product. Shows
//  the new item beside the current pivot with the prompt "Which did you
//  prefer?" and a progress indicator. Each tap drives the binary-insertion
//  search in `MediaLibraryViewModel` via `CompareViewModel`; when the search
//  resolves the modal dismisses itself.
//

import SwiftUI

// MARK: - CompareView

struct CompareView: View {

    @State private var viewModel: CompareViewModel
    @Environment(\.dismiss) private var dismiss

    init(newItem: MediaItem, library: MediaLibraryViewModel) {
        _viewModel = State(initialValue: CompareViewModel(newItem: newItem, library: library))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let pair = viewModel.currentPair {
                    comparison(pair)
                } else {
                    ProgressView()
                        .accessibilityLabel("Preparing the next comparison")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
            .navigationTitle("Add to Ranking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Cancel through the view model rather than just dismissing:
                    // it places the item at the bucket midpoint and marks the
                    // session finished, so `isFinished` reflects reality.
                    // MediaDetailView's `onDismiss` still calls `cancelRanking`
                    // as the catch-all for a swipe-dismiss; both are idempotent,
                    // so whichever runs first wins and the other no-ops.
                    Button("Cancel") {
                        viewModel.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Undo") { viewModel.undo() }
                        .disabled(!viewModel.canUndo)
                        .accessibilityHint("Takes back your last comparison")
                }
            }
        }
        .onChange(of: viewModel.isFinished) { _, finished in
            if finished { dismiss() }
        }
        .onAppear {
            if viewModel.isFinished { dismiss() }
        }
    }

    // MARK: Content

    private func comparison(_ pair: ComparisonPair) -> some View {
        VStack(spacing: Spacing.section) {
            progressHeader

            Text("Which did you prefer?")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            HStack(alignment: .top, spacing: Spacing.lg) {
                CompareCard(item: pair.newItem, isNew: true) {
                    viewModel.choose(pair.newItem)
                }
                CompareCard(item: pair.existingItem, isNew: false) {
                    viewModel.choose(pair.existingItem)
                }
            }

            // An honest "I can't separate these" beats forcing a coin flip that
            // the ranking would then treat as a real preference.
            Button("Too close to call") {
                viewModel.markTooClose()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Places this title just below the other one")

            Spacer(minLength: 0)
        }
    }

    private var progressHeader: some View {
        VStack(spacing: Spacing.sm) {
            Text(viewModel.progressText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView(value: viewModel.progressFraction)
        }
        // Spoken as a single "Comparison 2 of 4" rather than the text followed
        // by an unlabeled progress bar reading a bare percentage.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.progressText)
    }
}

// MARK: - CompareCard

/// One tappable side of the comparison: a large poster, title, and year. The
/// new item carries a "NEW" badge so the user can tell which one they're
/// placing.
private struct CompareCard: View {

    let item: MediaItem
    let isNew: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                PosterView(title: item.title, posterURL: item.posterURL)
                    .frame(height: 220)
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(String(item.year))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(alignment: .topTrailing) {
                if isNew {
                    Text("NEW")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background(Color.accentColor, in: Capsule())
                        .padding(Spacing.sm)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(String(item.year))\(isNew ? ", new item" : "")")
        .accessibilityHint("Select if you preferred this")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func previewLibraryMidComparison() -> (MediaLibraryViewModel, MediaItem) {
    let library = MediaLibraryViewModel.previewInMemory()
    for i in 0..<3 {
        let seed = MediaItem(title: "Seed \(i)", year: 2000 + i, type: .movie)
        library.markWatched(seed, sentiment: .liked)
        while let pair = library.pendingComparison {
            library.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
        }
        library.finalizeRanking(for: seed)
    }
    let candidate = MediaItem(title: "Inception", year: 2010, type: .movie)
    library.markWatched(candidate, sentiment: .liked)
    return (library, candidate)
}

#Preview {
    let (library, candidate) = previewLibraryMidComparison()
    return CompareView(newItem: candidate, library: library)
}
#endif
