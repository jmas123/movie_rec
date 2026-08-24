//
//  ProfileView.swift
//  Binged
//
//  Personal stats over the user's watched library: totals, a movie/TV split,
//  average score, all-time top 5, and top genres. Per the roadmap this screen
//  has no view model — the numbers are derived by the pure `ProfileStats` value
//  type (testable on its own) from a `MediaLibraryViewModel` query.
//

import SwiftUI

// MARK: - ProfileView

struct ProfileView: View {

    @Environment(MediaLibraryViewModel.self) private var library
    @Environment(SessionViewModel.self) private var session

    @State private var showSignIn = false

    /// Sends the user to Search from the empty state. Optional so previews and
    /// tests can build the screen without wiring up navigation.
    var onBrowse: (() -> Void)?

    /// Passed to Settings for the blocked-accounts list; this screen does not
    /// use it directly.
    var socialService: SocialService?

    private var stats: ProfileStats {
        ProfileStats(watched: library.allWatched)
    }

    var body: some View {
        NavigationStack {
            Group {
                if stats.isEmpty {
                    emptyProfile
                } else {
                    statsList
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView(socialService: socialService) } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSignIn) { SignInView() }
        }
    }

    // MARK: Empty

    /// The empty library, **plus a way to make an account.**
    ///
    /// This screen previously rendered the empty state *instead of* `statsList`
    /// — and `accountSection` lives inside `statsList`. The result was that a
    /// fresh install had no reachable sign-in anywhere in the app: the whole
    /// social layer was gated behind ranking something first, by accident. The
    /// account entry point therefore cannot live only in the populated branch.
    private var emptyProfile: some View {
        VStack(spacing: Spacing.section) {
            EmptyStateView(
                systemImage: "person.crop.circle",
                message: "Watch and rank something to start building your stats.",
                actionTitle: onBrowse == nil ? nil : "Find something to watch",
                action: onBrowse
            )

            if session.isAvailable, session.profile == nil {
                VStack(spacing: Spacing.sm) {
                    Button("Sign In or Create Account") { showSignIn = true }
                        .buttonStyle(.borderedProminent)

                    Text("Optional. Ranking works signed out — an account is for "
                         + "following people and keeping your library if you "
                         + "change device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.section)
                }
            }
        }
    }

    // MARK: List

    private var statsList: some View {
        List {
            Section("Summary") {
                LabeledContent("Watched", value: "\(stats.totalWatched)")
                LabeledContent("Movies", value: "\(stats.movieCount)")
                LabeledContent("TV Shows", value: "\(stats.tvCount)")
                LabeledContent("Average Score", value: averageText)
            }

            if !stats.topFive.isEmpty {
                Section("Top 5 of All Time") {
                    ForEach(stats.topFive, id: \.id) { item in
                        MediaRow(item: item, display: library.scoreDisplay(for: item))
                    }
                }
            }

            accountSection

            tasteSection

            accuracySection
        }
    }

    // MARK: Account

    /// The one social entry point in this phase. Everything else on Profile —
    /// and everywhere else in the app — works identically signed out.
    @ViewBuilder
    private var accountSection: some View {
        if session.isAvailable {
            Section {
                if let profile = session.profile {
                    LabeledContent("Signed in as", value: "@\(profile.handle)")
                    Button("Sign Out", role: .destructive) {
                        Task { await session.signOut() }
                    }
                } else {
                    Button("Sign In or Create Account") { showSignIn = true }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Your rankings stay on this device. An account only adds "
                     + "the social features.")
            }
        }
    }

    // MARK: Taste

    /// Replaces the old Top Genres list.
    ///
    /// That list ranked by *count*, which answers "what do you watch most" — a
    /// duller question the user can already answer, and one that would now
    /// contradict the taste screen's effect-ranked claims. Two lists disagreeing
    /// about the same library is worse than one fewer list.
    @ViewBuilder
    private var tasteSection: some View {
        Section {
            NavigationLink {
                TasteAnalysisView(onBrowse: onBrowse ?? {})
            } label: {
                Label("Your taste", systemImage: "chart.pie")
            }
        } footer: {
            Text("What you gravitate toward, what you actually rate highly, and "
                 + "where those disagree.")
        }
    }

    // MARK: Prediction accuracy

    /// One honest line about whether the recommender is working.
    ///
    /// It refuses to speak when the rank correlation is not significant.
    /// "Predictions land within 1.2 points" *sounds* like a result, and is one
    /// only if the ordering holds up — quoting the error alone would dress a
    /// number as a finding.
    @ViewBuilder
    private var accuracySection: some View {
        if let accuracy, let headline = accuracy.headline {
            Section {
                Text(headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if accuracy.isSignificant {
                    LabeledContent(
                        "Rank agreement",
                        value: accuracy.spearman.map { String(format: "%.2f", $0) } ?? "—"
                    )
                }
                if !matched.isEmpty {
                    LabeledContent("Graded guesses", value: "\(matched.count)")
                }
            } header: {
                Text("Predictions")
            } footer: {
                Text("Measured by holding each ranked title out and predicting it "
                     + "from the rest.")
            }
        }
    }

    private var matched: [(predicted: Double, actual: Double)] {
        library.matchedPredictions
    }

    /// Cached against the library revision: cross-validation costs one profile
    /// build per watched title, which is far too much for a `body` evaluation.
    private var accuracy: PredictionAccuracy? {
        ProfileView.accuracyCache.value(for: library.revision) {
            RecommendationEngine().accuracy(for: library.allWatched)
        }
    }

    private var averageText: String {
        guard let average = stats.averageScore else { return "—" }
        return ScoreDisplay.formatter.string(from: average as NSNumber) ?? "—"
    }
}

// MARK: - Accuracy cache

/// A one-slot memo keyed on the library revision.
///
/// `ProfileStats` is cheap enough to rebuild on every `body` evaluation;
/// cross-validation is emphatically not — it is O(library) profile builds, and
/// SwiftUI may evaluate a body many times per frame.
@MainActor
final class RevisionCache<Value> {
    private var revision: Int?
    private var stored: Value?

    func value(for revision: Int, build: () -> Value) -> Value {
        if self.revision == revision, let stored { return stored }
        let fresh = build()
        self.revision = revision
        self.stored = fresh
        return fresh
    }
}

extension ProfileView {
    static let accuracyCache = RevisionCache<PredictionAccuracy>()
}

// MARK: - ProfileStats

/// Pure, view-agnostic aggregate of a set of watched items. Kept a value type
/// (not a view model) so it can be unit-tested directly against a fixture.
struct ProfileStats {

    let totalWatched: Int
    let movieCount: Int
    let tvCount: Int
    /// Mean score across items that have one; `nil` when none do.
    let averageScore: Double?
    /// Highest-scored items, best first, up to five.
    let topFive: [MediaItem]
    init(watched items: [MediaItem]) {
        totalWatched = items.count
        movieCount = items.filter { $0.type == .movie }.count
        tvCount = items.filter { $0.type == .tvShow }.count

        let scores = items.compactMap(\.score)
        averageScore = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)

        topFive = items
            .sorted { ($0.score ?? -.infinity) > ($1.score ?? -.infinity) }
            .prefix(5)
            .map { $0 }

    }

    var isEmpty: Bool { totalWatched == 0 }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func profilePreviewLibrary() -> MediaLibraryViewModel {
    let library = MediaLibraryViewModel.previewInMemory()

    func watched(_ title: String, _ type: MediaType, _ sentiment: Sentiment, _ genres: [String]) {
        let item = MediaItem(title: title, year: 2018, type: type, genres: genres)
        library.markWatched(item, sentiment: sentiment)
        while let pair = library.pendingComparison {
            library.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
        }
        library.finalizeRanking(for: item)
    }

    watched("Parasite", .movie, .liked, ["Drama", "Thriller"])
    watched("Inception", .movie, .liked, ["Sci-Fi", "Thriller"])
    watched("Breaking Bad", .tvShow, .liked, ["Drama", "Crime"])
    watched("The Office", .tvShow, .fine, ["Comedy"])
    watched("Some Flop", .movie, .disliked, ["Drama"])

    return library
}

#Preview {
    ProfileView()
        .environment(profilePreviewLibrary())
}

#Preview("Empty") {
    ProfileView()
        .environment(MediaLibraryViewModel.previewInMemory())
}
#endif
