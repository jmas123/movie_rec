//
//  WatchRankApp.swift
//  WatchRank
//
//  Created by Jude El Masr on 5/19/26.
//
//  App entry point. Owns the on-disk SwiftData `ModelContainer`, builds the
//  shared `MediaLibraryViewModel` over its main context, and injects both the
//  view model (via the environment) and the catalog `MediaService` into
//  `RootTabView`.
//

import SwiftUI
import SwiftData

@main
struct WatchRankApp: App {

    private let modelContainer: ModelContainer
    private let service: MediaService

    @State private var library: MediaLibraryViewModel

    /// `nil` on the bundled catalog — see `makeRecommender`.
    @State private var recommender: RecommendationViewModel?

    /// The social stack, or `nil` on a build with no Supabase credentials.
    private let social: SocialStack?

    /// Always present. On a build with no Supabase credentials it reports
    /// `.unavailable`, which the social surfaces render as an explanation
    /// rather than as a broken form.
    @State private var session: SessionViewModel

    /// Launch argument that swaps the on-disk store for a throwaway in-memory
    /// one, so UI tests start from a known-empty library every run.
    static let inMemoryStoreArgument = "-uiTestingInMemoryStore"

    /// Launch argument that swaps Supabase for `MockSocialFixture` — a seeded,
    /// in-memory social world with no server behind it.
    ///
    /// The feed is the one screen that cannot be looked at any other way: a
    /// feed page is drawn from people you follow, and `follows_no_self` means a
    /// single account can never appear in its own. Verifying it against the
    /// real project therefore takes two accounts, which is the right test and a
    /// slow one. This is the fast one.
    static let mockSocialArgument = "-uiTestingMockSocial"

    init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains(Self.inMemoryStoreArgument)
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: MediaItem.self, PendingPublish.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: isUITesting)
            )
        } catch {
            // Unrecoverable at launch. During development this usually means a
            // SwiftData schema change without a migration — delete the app from
            // the simulator and relaunch (see CLAUDE.md).
            fatalError("Failed to create ModelContainer: \(error)")
        }

        let service = Self.makeService(isUITesting: isUITesting)
        let library = MediaLibraryViewModel(modelContext: container.mainContext)

        self.modelContainer = container
        self.service = service
        _library = State(initialValue: library)
        _recommender = State(initialValue: Self.makeRecommender(service: service, library: library))
        let stack = Self.makeSocialStack(isUITesting: isUITesting)
        self.social = stack
        _session = State(initialValue: SessionViewModel(service: stack?.auth))
    }

    // MARK: - Startup maintenance

    /// Background work that brings a stored library up to date with the live
    /// catalog. Runs once per launch, off the critical path — the UI is already
    /// on screen and fully usable while this happens.
    ///
    /// Order matters: the migration rewrites IMDb ids into TMDB ids, and the
    /// feature backfill can only fetch for items that already carry a TMDB id.
    /// Reversing them would leave a freshly migrated library un-enriched until
    /// the next launch.
    ///
    /// Both steps no-op when the app is on the bundled catalog, which has
    /// nothing to migrate to and no features to fetch.
    @MainActor
    private func runStartupMaintenance() async {
        guard let tmdb = service as? TMDBMediaService else { return }
        let context = modelContainer.mainContext

        await ExternalIDMigration(resolver: tmdb, modelContext: context)
            .run(items: library.allItems)

        await FeatureProvider(source: tmdb, modelContext: context)
            .backfill(items: library.allItems)
    }

    /// The Discover stack, or `nil` when there is nothing to recommend from.
    ///
    /// Both halves need the live catalog: the candidate pool is paged out of
    /// `/discover`, and stage two of the rerank needs `/movie/{id}` features.
    /// On the bundled catalog `CandidateSource` answers genre components only,
    /// which is enough to be *thin* but not enough to be worth a tab — so a
    /// tokenless build simply has no Discover tab rather than one that opens on
    /// a permanent empty state.
    @MainActor
    private static func makeRecommender(
        service: MediaService,
        library: MediaLibraryViewModel
    ) -> RecommendationViewModel? {
        guard let tmdb = service as? TMDBMediaService else { return nil }
        return RecommendationViewModel(
            library: library,
            poolBuilder: CandidatePoolBuilder(source: tmdb),
            featureSource: tmdb
        )
    }

    /// Everything the social layer needs, built once and shared.
    ///
    /// One object rather than five separate optionals, so "is social available"
    /// is a single question with a single answer instead of five that could
    /// disagree.
    struct SocialStack {
        let auth: AuthService
        let graph: SocialService
        let feed: FeedService
        let rankings: RankingFeedService
        /// Absent on the mock stack, which has no server to talk to. Held so
        /// that whatever needs the raw client next — Phase 29's publish
        /// transport is the first — does not have to rebuild it.
        let client: SupabaseClient?
        let configuration: SupabaseConfiguration?
    }

    /// Which social world this launch gets: the real one, the seeded mock, or
    /// none at all.
    ///
    /// The mock is checked first and independently of `isUITesting`, because it
    /// is asked for by name — a run with the flag wants the fixture whatever
    /// else is true of it.
    private static func makeSocialStack(isUITesting: Bool) -> SocialStack? {
        if ProcessInfo.processInfo.arguments.contains(mockSocialArgument) {
            let fixture = MockSocialFixture.seeded()
            return SocialStack(
                auth: fixture.auth, graph: fixture.graph, feed: fixture.feed,
                rankings: fixture.rankings, client: nil, configuration: nil
            )
        }
        guard !isUITesting, let configuration = SupabaseConfiguration.fromBundle() else {
            return nil
        }
        let client = SupabaseClient(configuration: configuration)
        return SocialStack(
            auth: SupabaseAuthService(client: client, configuration: configuration),
            graph: SupabaseSocialService(client: client, configuration: configuration),
            feed: SupabaseFeedService(client: client, configuration: configuration),
            rankings: SupabaseRankingFeedService(client: client, configuration: configuration),
            client: client,
            configuration: configuration
        )
    }

    // MARK: - Catalog

    /// Picks the live catalog when the build carries a TMDB token, and the
    /// bundled one when it does not.
    ///
    /// Two cases deliberately stay on the mock:
    ///
    /// - **No token.** A checkout without `Config/Secrets.xcconfig` is a
    ///   supported state, so this degrades to the bundled catalog instead of
    ///   launching into an app where every screen is an error.
    /// - **UI tests.** `RankingFlowUITests` drives search with a title it knows
    ///   is in `MockMedia.json`. Pointed at TMDB it would depend on the network,
    ///   on TMDB's ranking of that query, and on the rate limiter — a test that
    ///   fails for three reasons unrelated to the code it covers.
    private static func makeService(isUITesting: Bool) -> MediaService {
        guard !isUITesting, let configuration = TMDBConfiguration.fromBundle() else {
            return MockMediaService()
        }
        return TMDBMediaService(configuration: configuration)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(
                library: library,
                service: service,
                recommender: recommender,
                feedService: social?.feed,
                socialService: social?.graph,
                rankingFeedService: social?.rankings
            )
                .environment(library)
                .environment(recommender)
                .environment(session)
                .task { await runStartupMaintenance() }
                .task { await session.restore() }
        }
        .modelContainer(modelContainer)
    }
}
