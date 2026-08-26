//
//  ProfileView.swift
//  Binged
//
//  The user's own page: who they are, who follows them, who they follow, and
//  personal stats over their watched library — totals, a movie/TV split,
//  average score, all-time top 5, and taste.
//
//  Per the roadmap the stats half has no view model: the numbers are derived by
//  the pure `ProfileStats` value type (testable on its own) from a
//  `MediaLibraryViewModel` query. The social half is one call to
//  `relationship(with:)`, whose counts work for any target including yourself.
//
//  **Why the identity block is here and not on a sixth screen.** Every other
//  account in the app has a page — `UserProfileView` — reached by tapping their
//  name, and the one account that had none was your own. The follower and
//  following counts existed, `FollowListView` existed and was reachable from
//  *other people's* profiles, and none of it was reachable for yourself. This
//  tab was already "you"; it was just missing the half that says so.
//

import SwiftUI

// MARK: - ProfileView

struct ProfileView: View {

    @Environment(MediaLibraryViewModel.self) private var library
    @Environment(SessionViewModel.self) private var session

    /// Only so a title tapped on somebody else's ranking can be resolved —
    /// this tab has no catalog of its own to show. Taken from the environment
    /// rather than a parameter for the reason `MediaServiceKey` gives.
    @Environment(\.mediaService) private var catalog

    @State private var showSignIn = false

    /// Sends the user to Search from the empty state. Optional so previews and
    /// tests can build the screen without wiring up navigation.
    var onBrowse: (() -> Void)?

    /// Used here for the follower and following counts, and passed to Settings
    /// for the blocked-accounts list.
    var socialService: SocialService?

    /// Needed only so a follower row can open the person it names.
    var rankingFeedService: RankingFeedService?

    /// Counts for the signed-in account. `nil` until the first load, and after
    /// a failure — a count that might be wrong is worse than no count, because
    /// it looks like information rather than a request that did not land.
    @State private var counts: FollowCounts?

    private var stats: ProfileStats {
        ProfileStats(watched: library.allWatched)
    }

    var body: some View {
        NavigationStack {
            Group {
                // Signed in, the page is worth showing even with nothing
                // ranked yet: it is where your handle and your people live.
                if stats.isEmpty && session.profile == nil {
                    emptyProfile
                } else {
                    statsList
                }
            }
            .navigationTitle("Profile")
            // Registered on this stack so the counts can push a list, and a row
            // of that list can push the person it names. One mechanism per
            // stack, all the way down — see `FollowListRoute`.
            .navigationDestination(for: FollowListRoute.self) { route in
                if let socialService {
                    FollowListView(
                        direction: route.direction,
                        subject: route.subject,
                        service: socialService,
                        rankings: rankingFeedService
                    )
                }
            }
            .navigationDestination(for: PersonRoute.self) { route in
                if let socialService, let rankingFeedService {
                    UserProfileView(
                        handle: route.handle,
                        social: socialService,
                        rankings: rankingFeedService
                    )
                }
            }
            // A title tapped on somebody else's ranking, three pushes deep:
            // Profile → followers → their page → one of their titles. The rows
            // have always been `NavigationLink`s; without this destination on
            // *this* stack they were links to nowhere, and tapping one did
            // nothing at all. Registered here rather than inside
            // `UserProfileView` because a stack keeps one destination per type,
            // and one declared down there would shadow the stack's own.
            .navigationDestination(for: TitleReference.self) { reference in
                ForeignTitleView(reference: reference, catalog: catalog)
            }
            .task(id: session.profile?.id) { await loadCounts() }
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
            identitySection

            if stats.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "chart.bar",
                        message: "Rank something and your stats will appear here.",
                        style: .inline,
                        actionTitle: onBrowse == nil ? nil : "Browse",
                        action: onBrowse
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } else {
                Section("Summary") {
                    LabeledContent("Watched", value: "\(stats.totalWatched)")
                    LabeledContent("Movies", value: "\(stats.movieCount)")
                    LabeledContent("TV Shows", value: "\(stats.tvCount)")
                    LabeledContent("Average Score", value: averageText)
                }
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

    // MARK: Identity

    /// Who you are, and your two follow counts.
    ///
    /// Rendered only when there is an account to describe. Signed out this tab
    /// is exactly the stats screen it has always been.
    @ViewBuilder
    private var identitySection: some View {
        if let profile = session.profile {
            Section {
                HStack(spacing: Spacing.md) {
                    PosterView(title: profile.name, posterURL: profile.avatarURL)
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .font(.title3.weight(.semibold))
                        Text("@\(profile.handle)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if profile.isPrivate {
                            Label("Private", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, Spacing.xs)
                .accessibilityElement(children: .combine)

                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                followCounts(for: profile)
            }
        }
    }

    /// The two counts, as pushes.
    ///
    /// Both are links even at zero. An empty list that says "Nobody follows you
    /// yet" is an answer; a number that stops being tappable when it reaches
    /// zero reads as a control that has broken.
    @ViewBuilder
    private func followCounts(for profile: UserProfile) -> some View {
        if socialService != nil {
            HStack(spacing: 0) {
                countLink(.followers, value: counts?.followers, subject: profile)
                Divider().frame(height: 32)
                countLink(.following, value: counts?.following, subject: profile)
            }
        }
    }

    private func countLink(
        _ direction: FollowListView.Direction, value: Int?, subject: UserProfile
    ) -> some View {
        NavigationLink(value: FollowListRoute(direction: direction, subject: subject)) {
            VStack(spacing: 2) {
                // An em dash until the count lands, so the row never claims a
                // zero it has not actually been told.
                Text(value.map(String.init) ?? "—")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(direction.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value.map(String.init) ?? "Unknown") \(direction.title)")
    }

    private func loadCounts() async {
        guard let socialService, let profile = session.profile else {
            counts = nil
            return
        }
        // `relationship` counts followers and followees of the target with two
        // plain queries, so it answers for your own id as readily as anyone's.
        // The `state` it returns is meaningless here — you cannot follow
        // yourself — and is deliberately ignored.
        counts = try? await socialService.relationship(with: profile.id).counts
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
                // Was: "Your rankings stay on this device. An account only
                // adds the social features." Both halves were false once signed
                // in — the library syncs to the account unconditionally, which
                // is what makes a second device restore it — and this is
                // exactly the stale copy that gets repeated into a privacy
                // policy. Consent governs who *else* can see a bucket, not
                // whether it is stored. See `docs/PART-IV-SYNC.md` §3.
                Text("Your library is saved to your account so you can restore "
                     + "it on another device. Who else can see it is a separate "
                     + "choice, per bucket, and off until you say otherwise.")
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
