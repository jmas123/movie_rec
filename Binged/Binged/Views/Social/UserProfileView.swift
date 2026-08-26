//
//  UserProfileView.swift
//  Binged
//
//  Somebody else's ranking, rendered with the same care as your own — and with
//  none of the affordances that would let you edit it.
//
//  **What this screen is for.** Not "look at a list of things a person watched"
//  — that is a directory, and nobody opens a friend's profile for a directory.
//  The app spends every comparison making one person's 0–10 scale mean
//  something, which is exactly what makes two people's libraries comparable.
//  So the screen leads with the three questions a friend's ranking can actually
//  answer: how alike are we, what do they love that I have not seen, and where
//  do we disagree. The full ranking is still here, one tap away, under Movies
//  and TV — but it is the reference, not the headline.
//

import SwiftUI

// MARK: - PersonRoute

/// A push to somebody's profile, addressed by handle.
///
/// A distinct type rather than a bare `String` navigation value: a stack that
/// registers `navigationDestination(for: String.self)` claims *every* string
/// pushed anywhere inside it, which is a collision waiting to happen the next
/// time some other screen wants to push text.
struct PersonRoute: Hashable {
    let handle: String
}

// MARK: - UserProfileView

struct UserProfileView: View {

    let handle: String
    @State private var viewModel: UserProfileViewModel
    @State private var scope: Scope = .overview
    @State private var reportTarget: ReportTarget?
    @State private var showBlockConfirmation = false
    @State private var reportFailure: String?

    /// Titles the viewer has tapped Add on and whose catalog lookup is still in
    /// flight. Keyed by `RankedItem.id`, so a double tap cannot queue twice.
    @State private var queueing: Set<String> = []

    @Environment(\.dismiss) private var dismiss

    /// The viewer's own library — the other half of every comparison on this
    /// screen. Optional so the view still builds in a preview or a test rig
    /// that has no store; with none, the comparison sections stand down and the
    /// ranking is shown plain.
    @Environment(MediaLibraryViewModel.self) private var library: MediaLibraryViewModel?

    /// Kept, not only handed to the view model: the follower and following
    /// lists this screen pushes to need them too.
    private let social: SocialService
    private let rankings: RankingFeedService

    private let feed: FeedService?

    /// The catalog, so a title lifted off their ranking can be opened as a full
    /// detail screen — with a poster, an overview and the ordinary ways to act
    /// on it. Optional: without one, rows still queue, they just cannot open.
    private let catalog: MediaService?

    init(
        handle: String,
        social: SocialService,
        rankings: RankingFeedService,
        feed: FeedService? = nil,
        catalog: MediaService? = nil
    ) {
        self.feed = feed
        self.handle = handle
        self.social = social
        self.rankings = rankings
        self.catalog = catalog
        _viewModel = State(initialValue: UserProfileViewModel(social: social, rankings: rankings))
    }

    // MARK: Scope

    /// Overview first, deliberately. The ranking is long and undifferentiated;
    /// the comparison is the part that could only exist because both people use
    /// this app.
    enum Scope: Hashable, CaseIterable, Identifiable {
        case overview
        case movies
        case shows

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .movies:   return "Movies"
            case .shows:    return "TV"
            }
        }

        var mediaType: MediaType? {
            switch self {
            case .overview: return nil
            case .movies:   return .movie
            case .shows:    return .tvShow
            }
        }
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .loading:
                ProgressView()
                    .accessibilityLabel("Loading profile")
            case .notFound:
                EmptyStateView(
                    systemImage: "person.fill.questionmark",
                    message: "No account with that handle."
                )
            case .privateAccount:
                privateState
            case .error(let message):
                EmptyStateView(systemImage: "exclamationmark.triangle", message: message)
            case .loaded:
                content
            }
        }
        .navigationTitle(viewModel.profile.map { "@\($0.handle)" } ?? handle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let profile = viewModel.profile {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if feed != nil {
                            Button {
                                reportTarget = .profile(profile.id)
                            } label: { Label("Report Profile", systemImage: "flag") }
                        }

                        Button(role: .destructive) {
                            showBlockConfirmation = true
                        } label: {
                            Label("Block \(profile.name)", systemImage: "hand.raised")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Profile actions")
                }
            }
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target) { reason, note in
                Task { await report(target, reason: reason, note: note) }
            }
        }
        .alert("Block this person?", isPresented: $showBlockConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Block", role: .destructive) { Task { await viewModel.block() } }
        } message: {
            Text("You will not see \(viewModel.profile?.name ?? "them") again, and "
                 + "they will not see you. Any follow between you is removed.")
        }
        .alert("Something went wrong", isPresented: errorPrompt) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.lastError ?? reportFailure ?? "")
        }
        .onChange(of: viewModel.didBlock) { _, blocked in
            if blocked { dismiss() }
        }
        // Queueing a title from this screen changes the viewer's side of every
        // comparison on it, so the match is recomputed from the same revision
        // counter the rest of the app redraws on.
        .onChange(of: library?.revision) { _, _ in syncLibrary() }
        .task {
            syncLibrary()
            await viewModel.load(handle: handle)
        }
    }

    private func syncLibrary() {
        guard let library else { return }
        viewModel.updateViewerLibrary(library.tasteEntries())
    }

    /// Reporting goes through the feed service, which owns the `reports`
    /// table. `ReportTarget.profile` existed from Phase 28 and had no
    /// construction site anywhere until now.
    private func report(_ target: ReportTarget, reason: ReportReason, note: String?) async {
        guard let feed else { return }
        do {
            try await feed.report(target, reason: reason, note: note)
        } catch {
            reportFailure = ErrorMessage.text(for: error)
        }
    }

    private var errorPrompt: Binding<Bool> {
        Binding(
            get: { viewModel.lastError != nil || reportFailure != nil },
            set: { if !$0 { viewModel.clearError(); reportFailure = nil } }
        )
    }

    // MARK: States

    private var privateState: some View {
        VStack(spacing: Spacing.lg) {
            header
            EmptyStateView(
                systemImage: "lock",
                message: "This account is private. Follow to see their ranking.",
                style: .inline
            )
        }
        .padding()
    }

    // MARK: Content

    private var content: some View {
        List {
            Section { header }

            if let profile = viewModel.profile {
                followRows(profile)
            }

            if viewModel.items.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "trophy",
                        message: "Hasn't ranked anything yet.",
                        style: .inline
                    )
                }
            } else {
                Section {
                    Picker("Section", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                switch scope {
                case .overview:
                    overview
                case .movies, .shows:
                    ranking(type: scope.mediaType ?? .movie)
                }
            }
        }
        // No `.onDelete`, no `.onMove`, no edit button: this ranking is not the
        // viewer's to change, and the absence is deliberate rather than pending.
    }

    // MARK: Overview

    @ViewBuilder
    private var overview: some View {
        let match = viewModel.match
        let name = viewModel.profile?.name ?? "they"

        matchSection(match)

        if !match.unseen.isEmpty {
            Section {
                ForEach(match.unseen.prefix(Self.suggestionLimit)) { item in
                    suggestionRow(item)
                }
            } header: {
                Text("They loved these — you haven't seen them")
            } footer: {
                Text("Ordered by where each one sits in their ranking, best first.")
            }
        }

        if !match.bothLoved.isEmpty {
            Section("You both loved") {
                ForEach(match.bothLoved.prefix(Self.comparisonLimit)) { overlap in
                    comparisonRow(overlap)
                }
            }
        }

        if !match.disagreements.isEmpty {
            Section {
                ForEach(match.disagreements.prefix(Self.comparisonLimit)) { overlap in
                    comparisonRow(overlap)
                }
            } header: {
                Text("Where you disagree")
            } footer: {
                Text("Ranked far apart, or in different buckets altogether.")
            }
        }

        if !match.alreadyQueued.isEmpty {
            Section {
                ForEach(match.alreadyQueued.prefix(Self.comparisonLimit)) { item in
                    RankedItemRow(item: item, standing: .queued)
                }
            } header: {
                Text("Already on your watchlist")
            } footer: {
                Text("You queued these before you knew \(name) had ranked them.")
            }
        }

        // A viewer with nothing ranked gets no comparison at all, so the
        // ranking still needs an entry point that is not a segmented control
        // they have no reason to press.
        if match.overlaps.isEmpty && match.unseen.isEmpty && match.alreadyQueued.isEmpty {
            Section("Their top titles") {
                ForEach(viewModel.topFive) { item in
                    RankedItemRow(item: item, standing: viewModel.match.standing(for: item))
                }
            }
        }
    }

    /// The headline: one number for how alike the two rankings are.
    @ViewBuilder
    private func matchSection(_ match: TasteMatch) -> some View {
        Section {
            if let percentage = match.percentage {
                VStack(spacing: Spacing.xs) {
                    Text("\(percentage)%")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                    if let verdict = match.verdict {
                        Text(verdict).font(.headline)
                    }
                    Text("Across \(match.sharedCount) "
                         + "\(match.sharedCount == 1 ? "title" : "titles") you've both ranked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Taste match \(percentage) percent, "
                    + "across \(match.sharedCount) shared titles"
                )
            } else {
                Label(match.sampleNote, systemImage: "arrow.left.arrow.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Taste match")
        } footer: {
            // The number is a rank correlation stretched onto 0–100, and a
            // reader who assumes "half the same" would misread 50 badly.
            Text(match.percentage == nil
                 ? "Rank a few of the same titles and this becomes a comparison."
                 : "How closely the two of you order the same titles. "
                   + "50% means no pattern either way.")
        }
    }

    // MARK: Ranking

    @ViewBuilder
    private func ranking(type: MediaType) -> some View {
        let buckets = viewModel.items.bucketed(type: type)

        if buckets.isEmpty {
            Section {
                EmptyStateView(
                    systemImage: "film",
                    message: "Nothing ranked in \(type.displayName.lowercased())s yet.",
                    style: .inline
                )
            }
        } else {
            ForEach(buckets, id: \.sentiment) { bucket in
                Section(bucket.sentiment.displayName) {
                    ForEach(bucket.items) { item in
                        RankedItemRow(
                            item: item,
                            standing: viewModel.match.standing(for: item),
                            isQueueing: queueing.contains(item.id),
                            onQueue: library == nil ? nil : { Task { await queue(item) } }
                        )
                        .onAppear {
                            if item.id == viewModel.items.last?.id {
                                Task { await viewModel.loadMore() }
                            }
                        }
                    }
                }
            }
        }

        if viewModel.loadMoreFailed {
            // A truncated ranking presented as a complete one is worse
            // here than in the feed: the reader is looking at an
            // ordering, and a missing tail changes what it says.
            Section {
                VStack(spacing: Spacing.xs) {
                    Text("Couldn't load the rest of this ranking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await viewModel.retryLoadMore() } }
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Rows

    private func suggestionRow(_ item: RankedItem) -> some View {
        RankedItemRow(
            item: item,
            standing: viewModel.match.standing(for: item),
            isQueueing: queueing.contains(item.id),
            onQueue: library == nil ? nil : { Task { await queue(item) } }
        )
    }

    private func comparisonRow(_ overlap: TasteMatch.Overlap) -> some View {
        RankedItemRow(item: overlap.theirs, standing: .ranked(overlap))
    }

    // MARK: Queueing

    /// Adds one of their titles to the viewer's watchlist.
    ///
    /// The catalog lookup is what makes the queued row a real library entry —
    /// poster, overview, genres, and the features the recommender reads. A
    /// published ranking carries a title, a year and an id and nothing else, so
    /// queueing straight from it would seed the library with a husk. When the
    /// lookup fails the husk is still better than nothing: the id is right, so
    /// a later fetch can fill it in.
    private func queue(_ item: RankedItem) async {
        guard let library, !queueing.contains(item.id) else { return }
        queueing.insert(item.id)
        defer { queueing.remove(item.id) }

        let placeholder = MediaItem(
            externalId: item.externalId,
            title: item.title,
            year: item.year,
            type: item.mediaType
        )
        let fetched = try? await catalog?.fetch(id: item.externalId)

        // Canonicalised before the write: these paths take a detached item, and
        // `insertIfNeeded` would turn a detached duplicate into a second row.
        library.addToWantToWatch(library.canonicalItem(for: fetched ?? placeholder))
        syncLibrary()
    }

    /// How many of their unseen favourites to offer. Enough to choose from, few
    /// enough that it is a suggestion rather than a second ranking.
    private static let suggestionLimit = 6
    private static let comparisonLimit = 5

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let profile = viewModel.profile {
                HStack(spacing: Spacing.md) {
                    PosterView(title: profile.name, posterURL: profile.avatarURL)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).font(.headline)
                        Text("@\(profile.handle)")
                            .font(.caption).foregroundStyle(.secondary)
                        if viewModel.relationship.followsViewer {
                            Text("Follows you")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if viewModel.relationship.state.isActionable {
                        Button(viewModel.relationship.state.actionTitle) {
                            Task { await viewModel.toggleFollow() }
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.caption.weight(.semibold))
                    }
                }

                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio).font(.callout)
                }

                // Numbers only. **Nothing in this row navigates**, and that is
                // the fix for a real bug rather than a simplification: two
                // `NavigationLink`s inside one `List` row do not behave as two
                // independent links. Tapping "Following" activated the
                // *Followers* link as well, pushing both screens, so one Back
                // tap landed the reader on the follower list instead of the
                // profile they came from — which reads as the profile failing
                // to render.
                //
                // `.buttonStyle(.borderless)`, the usual answer for multiple
                // buttons in a row, was tried and measured: it stops the link
                // activating at all. So the links moved out to `followRows`,
                // where each one owns its whole row — the shape `List`
                // actually supports.
                HStack(spacing: Spacing.lg) {
                    stat("\(viewModel.relationship.counts.followers)", "Followers")
                    stat("\(viewModel.relationship.counts.following)", "Following")
                    stat("\(viewModel.stats.total)", "Ranked")
                    if let percentage = viewModel.match.percentage {
                        stat("\(percentage)%", "Match")
                    }
                }
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    /// The two lists, one per row.
    ///
    /// A row apiece because a `List` row containing two links is a row with one
    /// link and a bug — see the note in `header`. Each of these is the whole
    /// row, which is the only arrangement `List` routes unambiguously.
    ///
    /// A count of zero gets no row at all: zero is information, not a
    /// destination, and the header already states it. That is also why these
    /// are not simply always shown — a section of two rows that both lead
    /// nowhere is worse than no section.
    @ViewBuilder
    private func followRows(_ profile: UserProfile) -> some View {
        let counts = viewModel.relationship.counts
        if counts.followers > 0 || counts.following > 0 {
            Section {
                if counts.followers > 0 {
                    followRow(.followers, count: counts.followers, profile: profile)
                }
                if counts.following > 0 {
                    followRow(.following, count: counts.following, profile: profile)
                }
            }
        }
    }

    private func followRow(
        _ direction: FollowListView.Direction,
        count: Int,
        profile: UserProfile
    ) -> some View {
        NavigationLink(value: FollowListRoute(direction: direction, subject: profile)) {
            HStack {
                Text(direction.title)
                Spacer(minLength: Spacing.md)
                Text("\(count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(direction.title), \(count)")
        .accessibilityHint("Opens the list")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

// MARK: - RankedItemRow

/// A foreign ranked title, with the viewer's own standing on it.
///
/// **Rule 6 applies here exactly as it does locally, on both sides.** Below the
/// bucket-size threshold the position is shown and the number is withheld —
/// showing a stranger's "8.4" from a bucket of one would be the same unearned
/// precision, published, and showing the viewer's own unearned number beside it
/// would be inventing a contrast.
struct RankedItemRow: View {

    let item: RankedItem
    /// Where the viewer stands on this title. Defaults to untracked, which is
    /// what a screen with no library context should assume.
    var standing: TasteMatch.Standing = .untracked
    var isQueueing = false
    /// `nil` when there is no library to queue into.
    var onQueue: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.md) {
            // A value push, resolved by whichever stack is hosting this row.
            // The row does not know — and must not know — what opening a title
            // means here, and a stack that declares its own destination for
            // `RankedItem` would shadow the one at its root.
            NavigationLink(value: item.reference) { rowContent }
                .buttonStyle(.plain)

            trailing
        }
        .padding(.vertical, Spacing.xs)
    }

    private var rowContent: some View {
        HStack(spacing: Spacing.md) {
            // The published artwork where the row carries a path — every row
            // written before `poster_path` was decoded has none, and falls back
            // to the gradient this used to draw unconditionally.
            PosterView(title: item.title, posterURL: item.posterURL)
                .frame(width: 40, height: 60)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                Text("\(String(item.year)) · \(item.mediaType.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
                standingLine
            }

            Spacer(minLength: Spacing.sm)

            theirScore
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Their side

    private var theirScore: some View {
        Group {
            if let score = item.displayScore {
                Text(ScoreDisplay.formatter.string(from: score as NSNumber) ?? "—")
                    .font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
            } else {
                Text(item.positionDescription)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: Your side

    /// One line saying where the viewer already stands, or nothing at all.
    ///
    /// Silence is the right answer for an untracked title in a long list: a row
    /// that said "you haven't seen this" on every line would be noise, and the
    /// Add button already implies it.
    @ViewBuilder
    private var standingLine: some View {
        switch standing {
        case .ranked(let overlap):
            HStack(spacing: Spacing.xs) {
                Text(yourVerdict(overlap))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(overlap.agreesOnSentiment ? Color.green : Color.orange)
                if overlap.isFullyScored, overlap.gap >= TasteMatch.notableGap {
                    Text("· \(gapText(overlap)) apart")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .watched:
            Text("You've watched this")
                .font(.caption).foregroundStyle(.secondary)
        case .queued:
            Label("On your watchlist", systemImage: "bookmark.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .untracked:
            EmptyView()
        }
    }

    /// "You: 8.2" once the viewer's own bucket has earned a number, and the
    /// sentiment alone before that.
    private func yourVerdict(_ overlap: TasteMatch.Overlap) -> String {
        if let score = overlap.yourDisplayScore,
           let text = ScoreDisplay.formatter.string(from: score as NSNumber) {
            return "You: \(text)"
        }
        return "You: \(overlap.yourSentiment.displayName.lowercased())"
    }

    private func gapText(_ overlap: TasteMatch.Overlap) -> String {
        ScoreDisplay.formatter.string(from: overlap.gap as NSNumber) ?? ""
    }

    // MARK: Trailing action

    @ViewBuilder
    private var trailing: some View {
        if case .untracked = standing, let onQueue {
            Button {
                onQueue()
            } label: {
                if isQueueing {
                    ProgressView()
                } else {
                    Image(systemName: "bookmark")
                        .font(.body.weight(.semibold))
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 32)
            .disabled(isQueueing)
            .accessibilityLabel("Add \(item.title) to your watchlist")
        }
    }

    private var accessibilityLabel: String {
        var label = "\(item.title), \(String(item.year))"
        if let score = item.displayScore {
            label += ", they scored \(ScoreDisplay.formatter.string(from: score as NSNumber) ?? "")"
        } else {
            label += ", \(item.positionDescription)"
        }
        switch standing {
        case .ranked(let overlap): label += ", \(yourVerdict(overlap))"
        case .watched:             label += ", you've watched this"
        case .queued:              label += ", on your watchlist"
        case .untracked:           break
        }
        return label
    }
}
