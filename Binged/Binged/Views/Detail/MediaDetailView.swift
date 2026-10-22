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
//  It reads from two places, and the split is the thing to understand before
//  editing it:
//
//  - **`MediaItem`** — the persisted row. Title, poster, overview, genres, and
//    everything about the user's own relationship to it: watched, sentiment,
//    rank, score, review. Always present, works offline, survives a reinstall.
//  - **`TitleDetails`** — catalog trivia fetched fresh each time the screen
//    opens: runtime, cast, director, streaming availability, the backdrop. Not
//    persisted, not synced, and allowed to be absent. Every section built from
//    it renders only if it arrived, so the screen is complete without it and
//    richer with it.
//
//  A network failure therefore costs this screen its cast strip and nothing
//  else. Nothing here awaits anything before drawing, and the ranking actions
//  do not depend on the fetch having finished.
//

import SwiftUI
import SwiftData

// MARK: - MediaDetailView

struct MediaDetailView: View {

    @Environment(MediaLibraryViewModel.self) private var library

    /// Optional: a build on the bundled catalog has no recommendation stack, so
    /// the predicted section simply does not appear.
    @Environment(RecommendationViewModel.self) private var recommender: RecommendationViewModel?

    /// The catalog, for the detail fetch. Defaults to the bundled service, so a
    /// preview or a stray push renders without it (`MediaServiceKey`).
    @Environment(\.mediaService) private var service

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

    /// Catalog trivia. `nil` while the fetch is in flight, when it failed, and
    /// for a title the catalog knows nothing about — all three mean the same
    /// thing to this screen, which is why they are one state.
    @State private var details: TitleDetails?

    /// Overviews run from one line to eight. Collapsed by default so the
    /// user's own score stays on the first screenful, which is the thing this
    /// app exists to show them.
    @State private var isOverviewExpanded = false

    /// Other people's rankings, for the "friends who watched" section. Optional
    /// and environment-supplied: a build with no server simply has no section.
    @Environment(\.rankingFeedService) private var rankingFeed
    @State private var watchers = TitleWatchersViewModel()

    /// The cast member whose filmography is on screen, or `nil` for none.
    ///
    /// A sheet rather than a push — `CastMemberView` explains why at length,
    /// and the short version is that this screen is reached from six places,
    /// several of them through a closure-based link where a value-based push
    /// from here would silently do nothing.
    @State private var selectedCastMember: TitleDetails.Person?

    var body: some View {
        ScrollView {
            // Two nested stacks because the header is full-bleed and the rest
            // is inset: a single padded stack cannot run the backdrop to the
            // screen edges, and padding every other section individually is
            // the kind of thing that drifts one section at a time.
            VStack(spacing: Spacing.section) {
                TitleBackdropHeader(
                    item: item,
                    backdropURL: details?.backdropURL,
                    subtitle: "\(String(item.year)) · \(item.type.displayName)",
                    tagline: details?.tagline
                )

                VStack(spacing: Spacing.section) {
                    if item.watchedStatus == .watched {
                        scoreSection
                    } else if let prediction {
                        predictedSection(prediction)
                    }
                    if let details, TitleFactsRow.hasFacts(details, type: item.type) {
                        TitleFactsRow(details: details, type: item.type)
                    }
                    if !item.overview.isEmpty { overviewSection }
                    if !item.genres.isEmpty { genreSection }
                    if let details, !details.streamingProviders.isEmpty {
                        WatchProvidersRow(
                            providers: details.streamingProviders,
                            link: details.providerLink
                        )
                    }
                    if let details, !details.cast.isEmpty {
                        CastStrip(
                            people: details.cast,
                            title: "Cast",
                            onSelect: { selectedCastMember = $0 },
                            subtitle: creditLine
                        )
                    } else if let creditLine {
                        // No cast came back but the director did — still worth
                        // a line, and cheaper than an empty strip.
                        Text(creditLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let review = item.review, !review.isEmpty { reviewSection(review) }
                    // After your own take, before the buttons: this is context
                    // for a decision, not an action you can perform.
                    if watchers.hasContent { friendsSection }
                    actionSection
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.lg)
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        // Keyed on watched status so marking a title watched drops the
        // prediction immediately — a guess sitting next to a real score would
        // be the exact confusion the outlined badge exists to prevent.
        .task(id: item.watchedStatus) {
            prediction = await recommender?.prediction(for: item)
        }
        // Keyed on the catalog id, not the item: the same title reached from
        // Search and from the library is two `MediaItem` instances, and keying
        // on identity would refetch on every one of them. An item with no
        // external id has nothing to look up and simply never fetches.
        .task(id: item.externalId) {
            guard let externalId = item.externalId else { return }
            details = await service.titleDetails(
                id: externalId,
                region: TitleDetails.deviceRegion
            )
        }
        // Keyed the same way and for the same reason. Separate from the fetch
        // above so a slow catalog does not hold up the friends section, or the
        // reverse.
        .task(id: item.externalId) {
            await watchers.load(
                from: rankingFeed, externalID: item.externalId, mediaType: item.type
            )
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
        .sheet(item: $selectedCastMember) { person in
            CastMemberView(person: person)
        }
    }

    // MARK: Credits

    /// "Directed by Bong Joon-ho", "Created by Vince Gilligan".
    ///
    /// The verb follows the media type because television credits its
    /// showrunner rather than an episode director — calling that person the
    /// director would be wrong on the one screen where it is stated outright.
    private var creditLine: String? {
        guard let names = details?.directors.map(\.name), !names.isEmpty else { return nil }
        let verb = item.type == .movie ? "Directed by" : "Created by"
        let joined: String
        switch names.count {
        case 1: joined = names[0]
        case 2: joined = "\(names[0]) and \(names[1])"
        default: joined = names.dropLast().joined(separator: ", ") + " and \(names[names.count - 1])"
        }
        return "\(verb) \(joined)"
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
                .lineLimit(isOverviewExpanded ? nil : Self.collapsedOverviewLines)
                .animation(.easeInOut(duration: 0.2), value: isOverviewExpanded)

            if isOverviewTruncatable {
                Button(isOverviewExpanded ? "Show less" : "Show more") {
                    isOverviewExpanded.toggle()
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Four lines is roughly where a TMDB synopsis stops being a hook and
    /// starts being the second act.
    private static let collapsedOverviewLines = 4

    /// Measured in characters rather than by reading back the rendered line
    /// count, which SwiftUI will not tell a view without a geometry dance for
    /// the sake of hiding one button. The cost of being wrong is a "Show more"
    /// that expands nothing, so the threshold is set well clear of four lines.
    private var isOverviewTruncatable: Bool {
        item.overview.count > 240
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

    // MARK: Friends

    /// What the people you follow made of this title.
    ///
    /// Rendered only when there is something to say — `hasContent` gates it, so
    /// no empty state, no spinner and no error box ever appears here. See
    /// `TitleWatchersViewModel.Phase`.
    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Friends Who Watched")
                    .font(.headline)
                if let subtitle = friendsSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(watchers.watchers) { watcher in
                friendRow(watcher)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var friendsSubtitle: String? {
        let people = watchers.watchers.count
        let reviews = watchers.reviewCount
        guard reviews > 0 else { return nil }
        return "\(people) ranked it · \(reviews) wrote about it"
    }

    private func friendRow(_ watcher: TitleWatcher) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                PosterView(title: watcher.name, posterURL: watcher.avatarURL)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(watcher.name)
                        .font(.subheadline.weight(.semibold))
                    Text("@\(watcher.handle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: Spacing.sm)

                verdict(for: watcher)
            }

            if let review = watcher.review, watcher.hasReview {
                Text(review)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Spacing.md)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: watcher))
    }

    /// Their number, or their position when the number has not been earned.
    ///
    /// `displayScore` applies the same bucket threshold their own device does,
    /// so a friend never appears here wearing a precision the app refuses to
    /// show them. With neither, the sentiment alone is still an answer.
    @ViewBuilder
    private func verdict(for watcher: TitleWatcher) -> some View {
        if let score = watcher.displayScore {
            Text(Self.formattedScore(score))
                .font(.title3.weight(.semibold).monospacedDigit())
        } else if let position = watcher.positionDescription {
            Text(position)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        } else {
            Text(watcher.sentiment.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// One decimal place, via the same formatter the rest of the app uses, so a
    /// friend's number is written exactly like your own.
    private static func formattedScore(_ score: Double) -> String {
        ScoreDisplay.formatter.string(from: score as NSNumber) ?? "—"
    }

    private func accessibilityLabel(for watcher: TitleWatcher) -> String {
        var parts = ["\(watcher.name), @\(watcher.handle)"]
        if let score = watcher.displayScore {
            parts.append("scored \(Self.formattedScore(score)) out of 10")
        } else if let position = watcher.positionDescription {
            parts.append(position)
        } else {
            parts.append(watcher.sentiment.displayName)
        }
        if let review = watcher.review, watcher.hasReview {
            parts.append("wrote: \(review)")
        }
        return parts.joined(separator: ", ")
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
            // Seeded, so re-opening the sheet does not silently discard a
            // review the user has already written.
            reviewDraft = item.review ?? ""
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
            reviewDraft = item.review ?? ""
            showSentimentSheet = true
        } label: {
            Label("Change Rating", systemImage: "arrow.up.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: Sentiment sheet

    /// Sentiment first, then — optionally — the review, in one sheet.
    ///
    /// **Why the review belongs here and not only after.** The old flow was
    /// sentiment → comparisons → back to Detail → Add a Review, which asks
    /// somebody to write down what they thought several taps *after* the app
    /// stopped asking them about it. What they want to say is loudest the
    /// moment they pick "Liked it"; by the end of four comparisons it has
    /// cooled into a chore, and the review sheet on Detail was easy never to
    /// find at all.
    ///
    /// It stays optional and stays below the picker: sentiment is what the
    /// ranking needs and a required text field would be a toll on the one
    /// interaction the whole app is built around. "Rank it" is enabled by the
    /// sentiment alone, exactly as before.
    private var sentimentSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    SentimentPicker(selection: $draftSentiment)

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Add a review")
                            .font(.headline)
                        Text("Optional. Your followers see this alongside the ranking.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        // `axis: .vertical` rather than a `TextEditor`: an
                        // editor is a fixed-height box that looks like a form
                        // field you must fill, while this grows from one line
                        // and reads as an invitation.
                        TextField(
                            "What did you think?",
                            text: $reviewDraft,
                            axis: .vertical
                        )
                        .lineLimit(3...8)
                        .textFieldStyle(.plain)
                        .padding(Spacing.md)
                        .background(
                            Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("How was it?")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
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
        // `.large` as well as `.medium`, because the keyboard over a medium
        // sheet leaves the text field with almost nothing to stand in.
        .presentationDetents([.medium, .large])
    }

    private func confirmSentiment() {
        guard let sentiment = draftSentiment else { return }

        // **The review is written first, and the order is load-bearing.**
        // `markWatched` queues the feed post, and `SyncEngine` builds that
        // post's payload from the item as it stands. Saving the review
        // afterwards would still reach the server's `ranked_items` row, but the
        // post could already have been drained without it — the follower would
        // see the ranking and never the sentence.
        //
        // Writing it here is also why this costs no *extra* post: the title is
        // not `.watched` yet, so `updateReview` stays quiet and the `.ranked`
        // post carries the text.
        library.updateReview(item, to: reviewDraft)

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
