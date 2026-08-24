//
//  MediaDetailView.swift
//  Binged
//
//  The full picture for one title plus its state-changing actions. This screen
//  owns no view model — it is a pure read-and-dispatch surface over
//  `MediaLibraryViewModel` (injected via the environment). The Mark Watched
//  flow presents `SentimentPicker`, then the comparison flow when the target
//  bucket isn't empty.
//

import SwiftUI
import SwiftData

// MARK: - MediaDetailView

struct MediaDetailView: View {

    @Environment(MediaLibraryViewModel.self) private var library

    /// Optional: a build on the bundled catalog has no recommendation stack, so
    /// the predicted section simply does not appear.
    @Environment(RecommendationViewModel.self) private var recommender: RecommendationViewModel?

    let item: MediaItem

    /// The score is the largest text in the app and was pinned at 48pt, so it
    /// alone ignored Dynamic Type. Scaling relative to .largeTitle keeps the
    /// visual weight while honouring the user's text size.
    @ScaledMetric(relativeTo: .largeTitle) private var scoreFontSize: CGFloat = 48

    // Sentiment / comparison flow.
    @State private var draftSentiment: Sentiment?
    @State private var showSentimentSheet = false
    @State private var showRemoveConfirmation = false

    /// Removing the item leaves this screen showing a row that no longer
    /// exists, so the screen leaves with it.
    @Environment(\.dismiss) private var dismiss
    @State private var showCompareSheet = false
    /// Bridges the two sheets: a comparison can only be presented *after* the
    /// sentiment sheet finishes dismissing, so we stash the intent here.
    @State private var compareAfterDismiss = false

    // Review editing.
    @State private var reviewDraft = ""
    @State private var showReviewSheet = false

    /// The predicted score for a title the user has not watched. `nil` while
    /// loading, and stays `nil` when there is nothing honest to say.
    @State private var prediction: TitlePrediction?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.section) {
                header
                if item.watchedStatus == .watched {
                    scoreSection
                } else if let prediction {
                    predictedSection(prediction)
                }
                if !item.overview.isEmpty { overviewSection }
                if !item.genres.isEmpty { genreSection }
                if let review = item.review, !review.isEmpty { reviewSection(review) }
                actionSection
            }
            .padding()
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        // Keyed on watched status so marking a title watched drops the
        // prediction immediately — a guess sitting next to a real score would
        // be the exact confusion the outlined badge exists to prevent.
        .task(id: item.watchedStatus) {
            prediction = await recommender?.prediction(for: item)
        }
        .sheet(isPresented: $showSentimentSheet, onDismiss: presentCompareIfNeeded) {
            sentimentSheet
        }
        .sheet(isPresented: $showCompareSheet, onDismiss: { library.cancelRanking(for: item) }) {
            CompareView(newItem: item, library: library)
        }
        .sheet(isPresented: $showReviewSheet) {
            reviewSheet
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Spacing.lg) {
            PosterView(title: item.title, posterURL: item.posterURL)
                .frame(width: 160, height: 240)
                .shadow(radius: 8, y: 4)

            VStack(spacing: Spacing.xs) {
                Text(item.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("\(String(item.year)) · \(item.type.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Score

    private var scoreSection: some View {
        VStack(spacing: 6) {
            if let score = library.displayScore(for: item) {
                Text(scoreString(score))
                    .font(.system(size: scoreFontSize, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            if let sentiment = item.sentiment {
                if library.isRanked(item), let rank = item.rankInBucket {
                    // Earned: this item has been compared against others.
                    Text("#\(rank + 1) in “\(sentiment.displayName)”")
                        .font(library.displayScore(for: item) == nil ? .title2.weight(.bold) : .subheadline)
                        .foregroundStyle(library.displayScore(for: item) == nil ? .primary : .secondary)
                } else {
                    // Alone in its bucket: no comparison has happened, so show
                    // only what the user actually told us.
                    Text(sentiment.displayName)
                        .font(.title2.weight(.bold))
                }
            }
            if item.watchedStatus == .watched,
               library.displayScore(for: item) == nil,
               !scoreProgressText.isEmpty {
                Text(scoreProgressText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            predictionVerdict
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        // Combining would read "8.4, #2 in Liked it" — a bare number with no
        // scale and a "#" the synthesizer stumbles over. Say it in words.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scoreAccessibilityLabel)
    }

    /// "We guessed 8.1 — you scored 7.4."
    ///
    /// The app froze a prediction when the title was queued from Discover and
    /// then never mentioned it again: the pair fed one aggregate correlation
    /// line on Profile, gated at n ≥ 8, and was invisible everywhere else. This
    /// is the single most compelling thing a taste-prediction product can show
    /// a person, and the data was already sitting in the row.
    ///
    /// Shown only once the score is shown. Comparing a real guess against a
    /// number rule 6 is deliberately withholding would leak the withheld value.
    @ViewBuilder
    private var predictionVerdict: some View {
        if item.watchedStatus == .watched,
           let predicted = item.predictedScore,
           let actual = library.displayScore(for: item) {
            let delta = abs(predicted - actual)
            VStack(spacing: 2) {
                Text("We guessed \(scoreString(predicted)) — you scored \(scoreString(actual)).")
                    .font(.footnote.weight(.medium))
                Text(verdictPhrase(delta: delta))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.top, Spacing.xs)
            .accessibilityElement(children: .combine)
        }
    }

    /// Deliberately plain about being wrong. A recommender that only celebrates
    /// its hits is not one whose numbers you can trust.
    private func verdictPhrase(delta: Double) -> String {
        switch delta {
        case ..<0.5:  return "Just about spot on."
        case ..<1.5:  return "Close."
        case ..<3.0:  return "Not our best guess."
        default:      return "We got that one wrong."
        }
    }

    // MARK: Predicted score

    /// What the app thinks the user would score a title they have not seen.
    ///
    /// Deliberately quieter than `scoreSection`. A real score is the largest
    /// text in the app because the user earned it through their own
    /// comparisons; this is a guess about a title they have never watched, and
    /// rendering the two at the same weight would let the guess borrow
    /// credibility the ranking system spent the whole app earning. So: smaller
    /// type, an outline rather than a fill, and the word "predicted" on screen
    /// and in the accessibility label rather than only implied.
    private func predictedSection(_ prediction: TitlePrediction) -> some View {
        VStack(spacing: 6) {
            switch prediction.display {
            case .score(let value):
                Text(scoreString(value))
                    .font(.system(size: scoreFontSize * 0.72, weight: .bold, design: .rounded)
                        .monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                Text("Predicted score")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .band(let band):
                Label(band.label, systemImage: band.symbolName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Not enough to put a number on yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let rationale = predictedRationale(prediction) {
                Text(rationale)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.md)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(predictedAccessibilityLabel(prediction))
    }

    /// "Because you like Crime and Christopher Nolan."
    ///
    /// Built from the contributions that actually moved the number, so the
    /// sentence cannot drift from the score. `nil` rather than invented when
    /// nothing contributed positively.
    private func predictedRationale(_ prediction: TitlePrediction) -> String? {
        let names = prediction.predicted.topContributingFeatures
            .prefix(2)
            .map(\.feature.displayName)
        guard !names.isEmpty else { return nil }
        return "Because you like \(names.joined(separator: " and "))"
    }

    private func predictedAccessibilityLabel(_ prediction: TitlePrediction) -> String {
        var label = prediction.display.accessibilityDescription
        if let rationale = predictedRationale(prediction) { label += ". \(rationale)" }
        return label
    }

    /// Copy shown in place of a score. Distinguishes "nothing to compare
    /// against yet" from "compared, but not enough for a number".
    private var scoreProgressText: String {
        // Mid-session: the comparisons themselves are the explanation.
        if library.isRankingInProgress(for: item) { return "" }
        let remaining = library.itemsUntilScoreRevealed(for: item)
        guard remaining > 0 else { return "" }
        let noun = item.type == .movie ? "film" : "show"
        let plural = item.type == .movie ? "films" : "shows"
        if !library.isRanked(item) {
            return "Rank another \(noun) you liked this much to place this one."
        }
        return "Rank \(remaining) more \(remaining == 1 ? noun : plural) in this list to see a score."
    }

    /// Spoken form of the score block. Mirrors what is on screen: a number
    /// once the bucket has earned one, otherwise the position and what is
    /// still needed.
    private var scoreAccessibilityLabel: String {
        var label: String
        if let score = library.displayScore(for: item) {
            label = "Score \(scoreString(score)) out of 10"
            if let sentiment = item.sentiment, let rank = item.rankInBucket {
                label += ", ranked number \(rank + 1) in \(sentiment.displayName)"
            }
            return label
        }
        if library.isRanked(item), let sentiment = item.sentiment, let rank = item.rankInBucket {
            label = "Ranked number \(rank + 1) in \(sentiment.displayName)"
        } else if let sentiment = item.sentiment {
            label = sentiment.displayName
        } else {
            label = "Not yet ranked"
        }
        if library.itemsUntilScoreRevealed(for: item) > 0 { label += ". \(scoreProgressText)" }
        return label
    }

    // MARK: Overview

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Overview")
                .font(.headline)
            Text(item.overview)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Genres

    private var genreSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(item.genres, id: \.self) { genre in
                    Text(genre)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
            }
            .padding(.horizontal, 1) // keeps capsule shadows from clipping
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Review

    private func reviewSection(_ review: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Your Review")
                .font(.headline)
            Text(review)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    @ViewBuilder
    private var actionSection: some View {
        VStack(spacing: Spacing.md) {
            switch item.watchedStatus {
            case .untracked:
                markWatchedButton
                wantToWatchButton

            case .wantToWatch:
                markWatchedButton
                Label("In your watchlist", systemImage: "bookmark.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // Was a dead label with no way back off the watchlist.
                removeFromWatchlistButton

            case .watched:
                editReviewButton
                reRankButton
                notWatchedButton
            }

            if item.watchedStatus != .untracked {
                removeButton
            }
        }
        .padding(.top, Spacing.xs)
        .confirmationDialog(
            "Remove \(item.title)?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove from Library", role: .destructive) {
                library.remove(item)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(item.watchedStatus == .watched
                 ? "This deletes your ranking for it. The other titles in that "
                   + "list are renumbered."
                 : "This takes it off your watchlist.")
        }
    }

    /// Correcting a mis-tap on Mark Watched, which is a different statement
    /// from "remove this" and from "I want to watch it".
    private var notWatchedButton: some View {
        Button {
            library.unwatch(item)
        } label: {
            Label("I haven't watched this", systemImage: "arrow.uturn.backward")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var removeFromWatchlistButton: some View {
        Button(role: .destructive) {
            showRemoveConfirmation = true
        } label: {
            Label("Remove from Watchlist", systemImage: "bookmark.slash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    /// The app had no destructive action anywhere: a title added by mistake
    /// stayed for good.
    private var removeButton: some View {
        Button(role: .destructive) {
            showRemoveConfirmation = true
        } label: {
            Label("Remove from Library", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var markWatchedButton: some View {
        Button {
            draftSentiment = item.sentiment
            showSentimentSheet = true
        } label: {
            Label("Mark Watched", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var wantToWatchButton: some View {
        Button {
            library.addToWantToWatch(item)
        } label: {
            Label("Want to Watch", systemImage: "bookmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var editReviewButton: some View {
        Button {
            reviewDraft = item.review ?? ""
            showReviewSheet = true
        } label: {
            Label(item.review == nil ? "Add a Review" : "Edit Review", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var reRankButton: some View {
        Button {
            draftSentiment = item.sentiment
            showSentimentSheet = true
        } label: {
            Label("Change Rating", systemImage: "arrow.up.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: Sentiment sheet

    private var sentimentSheet: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                SentimentPicker(selection: $draftSentiment)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("How was it?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        draftSentiment = nil
                        showSentimentSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rank it", action: confirmSentiment)
                        .disabled(draftSentiment == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func confirmSentiment() {
        guard let sentiment = draftSentiment else { return }
        library.markWatched(item, sentiment: sentiment)
        // A pending comparison means the bucket wasn't empty; show it once the
        // sentiment sheet has fully dismissed (SwiftUI can't swap two sheets
        // in the same runloop tick).
        compareAfterDismiss = library.pendingComparison != nil
        draftSentiment = nil
        showSentimentSheet = false
    }

    private func presentCompareIfNeeded() {
        guard compareAfterDismiss else { return }
        compareAfterDismiss = false
        showCompareSheet = true
    }

    // MARK: Review sheet

    private var reviewSheet: some View {
        NavigationStack {
            TextEditor(text: $reviewDraft)
                .padding()
                .navigationTitle("Your Review")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showReviewSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            library.updateReview(item, to: reviewDraft)
                            showReviewSheet = false
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Helpers

    private func scoreString(_ score: Double?) -> String {
        guard let score else { return "—" }
        return ScoreDisplay.formatter.string(from: score as NSNumber) ?? "—"
    }
}

// MARK: - Previews

#if DEBUG
extension MediaLibraryViewModel {
    /// Builds a fully in-memory library for SwiftUI previews, optionally seeded
    /// with items. Preview-only: force-try is acceptable here.
    static func previewInMemory(seed: [MediaItem] = []) -> MediaLibraryViewModel {
        let container = try! ModelContainer(
            for: MediaItem.self, PendingPublish.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        seed.forEach { container.mainContext.insert($0) }
        return MediaLibraryViewModel(modelContext: container.mainContext)
    }
}

#Preview("Untracked") {
    NavigationStack {
        MediaDetailView(item: MediaItem(
            title: "Inception",
            year: 2010,
            type: .movie,
            overview: "A thief who steals corporate secrets through dream-sharing technology is given a chance at redemption.",
            genres: ["Sci-Fi", "Thriller", "Action"]
        ))
    }
    .environment(MediaLibraryViewModel.previewInMemory())
}

#Preview("Watched") {
    let item = MediaItem(
        title: "Parasite",
        year: 2019,
        type: .movie,
        overview: "Greed and class discrimination threaten the newly formed symbiotic relationship between two families.",
        genres: ["Drama", "Thriller"],
        watchedStatus: .watched,
        sentiment: .liked,
        score: 9.2,
        rankInBucket: 0,
        review: "An absolute masterclass in tonal control."
    )
    return NavigationStack {
        MediaDetailView(item: item)
    }
    .environment(MediaLibraryViewModel.previewInMemory(seed: [item]))
}
#endif
