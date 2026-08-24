//
//  TasteAnalysisView.swift
//  Binged
//
//  A portrait of the user's taste, built from the same profile the recommender
//  predicts with — so what the app says about you and what it recommends to you
//  cannot disagree.
//

import SwiftUI

// MARK: - TasteAnalysisView

struct TasteAnalysisView: View {

    @Environment(MediaLibraryViewModel.self) private var library

    var onBrowse: () -> Void = {}

    private var analysis: TasteAnalysis {
        TasteAnalysisView.cache.value(for: library.revision) {
            let watched = library.allWatched
            return TasteAnalysis(
                profile: RecommendationEngine().buildProfile(from: watched),
                watched: watched
            )
        }
    }

    var body: some View {
        Group {
            if !analysis.hasEnoughLibrary {
                coldStart
            } else if analysis.isSilent {
                EmptyStateView(
                    systemImage: "chart.pie",
                    message: "Nothing has repeated often enough to say anything about yet. "
                           + "Keep ranking and patterns will show up here.",
                    actionTitle: "Find something to rank",
                    action: onBrowse
                )
            } else {
                list
            }
        }
        .navigationTitle("Your taste")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: States

    private var coldStart: some View {
        let remaining = max(0, TasteAnalysis.minimumLibrary - analysis.watchedCount)
        return EmptyStateView(
            systemImage: "chart.pie",
            message: "Rank \(remaining) more \(remaining == 1 ? "title" : "titles") "
                   + "and we can show you what your taste looks like.",
            actionTitle: "Find something to rank",
            action: onBrowse
        )
    }

    // MARK: List

    private var list: some View {
        List {
            if let headline = contrastSentence {
                Section {
                    Text(headline).font(.callout)
                } header: {
                    Text("The headline")
                } footer: {
                    Text("What you watch most and what you rate highest are "
                         + "different questions.")
                }
            }

            claimSection("Genres", analysis.genres)
            claimSection("Themes", analysis.keywords)
            claimSection("People", analysis.people,
                         footer: "Only people who show up often enough to mean something, "
                               + "and never twice for the same films.")
            claimSection("Era, length and language", analysis.context)

            if let crowd = analysis.crowdDescription {
                Section {
                    Text(crowd).font(.callout)
                } header: {
                    Text("Versus the crowd")
                } footer: {
                    Text("Compares the *order* of your rankings against TMDB's, "
                         + "across \(analysis.crowdSampleSize) titles. Your scores are "
                         + "positions within your own list, so comparing them to "
                         + "someone else's numbers directly would mean nothing.")
                }
            }
        }
    }

    /// Built as a plain `String` rather than inline in the view: the
    /// interpolated form defeated the type checker.
    private var contrastSentence: String? {
        guard let contrast = analysis.contrast, contrast.isInteresting else { return nil }
        let watched = contrast.mostWatched
        let rated = contrast.highestRated
        let watchedNoun = watched.support == 1 ? "title" : "titles"
        let ratedNoun = rated.support == 1 ? "title" : "titles"

        var sentence = "You have watched \(watched.support) \(watched.feature.displayName) "
        sentence += "\(watchedNoun) — they land \(watched.effectDescription). "
        sentence += "Your \(rated.support) \(rated.feature.displayName) "
        sentence += "\(ratedNoun) run \(rated.effectDescription)."
        return sentence
    }

    @ViewBuilder
    private func claimSection(
        _ title: String, _ claims: [TasteAnalysis.Claim], footer: String? = nil
    ) -> some View {
        if !claims.isEmpty {
            Section {
                ForEach(claims) { claim in
                    LabeledContent {
                        Text(claim.effectDescription)
                            .font(.caption)
                            .foregroundStyle(claim.effect >= 0 ? Color.accentColor : .secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(claim.feature.displayName)
                            Text("\(claim.support) title\(claim.support == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(claim.feature.displayName), \(claim.support) titles, "
                        + claim.effectDescription
                    )
                }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }
}

// MARK: - Cache

extension TasteAnalysisView {
    /// Rebuilt only when the library changes. The analysis is a multi-pass
    /// feature tally plus set-containment checks — far too much for a `body`
    /// evaluation, which SwiftUI may run many times per frame.
    static let cache = RevisionCache<TasteAnalysis>()
}

// MARK: - Previews

#if DEBUG
#Preview {
    NavigationStack {
        TasteAnalysisView()
            .environment(MediaLibraryViewModel.previewInMemory())
    }
}
#endif
