//
//  BingedApp.swift
//  Binged
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
struct BingedApp: App {

    private let modelContainer: ModelContainer

    /// Why the on-disk store would not open, or `nil` when it did.
    ///
    /// Set means the app is running on a throwaway in-memory container and must
    /// not show the library — see `init` and `StoreRecoveryView`.
    private let storeFailure: String?
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

    /// Drains the publish outbox. `nil` when there is no server to drain to —
    /// the outbox still accrues, and a later sign-in on a configured build
    /// finds the debt waiting.
    @State private var sync: SyncEngine?

    /// The pull half of account sync. Nil for the same reasons `sync` is: no
    /// server configured, or a build with no social stack.
    @State private var restorer: LibraryRestorer?

    /// The account currently being asked to publish, or `nil` when nobody is.
    @State private var consentPrompt: ConsentPrompt?

    /// Fires the drain when the network returns. Held for the app's lifetime
    /// because a monitor nobody retains stops monitoring.
    private let connectivity: ConnectivityMonitor = NetworkConnectivityMonitor()

    @Environment(\.scenePhase) private var scenePhase

    /// Identifiable so `sheet(item:)` can present for exactly one account, and
    /// re-present if a different one signs in.
    struct ConsentPrompt: Identifiable, Equatable {
        let id: UUID
    }

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
        var failure: String?

        do {
            container = try Self.makeModelContainer(inMemory: isUITesting)
        } catch {
            // Was a `fatalError`. On a developer's simulator that is a fine
            // signal; on a shipped build it is an app that stops launching with
            // no explanation, and the advice in CLAUDE.md — delete and relaunch
            // — is the one action that destroys the library it is trying to
            // recover. The user gets `StoreRecoveryView` instead.
            //
            // The throwaway store below exists only so the scene has something
            // to attach to. It is never shown as a library: `body` swaps the
            // whole UI when `storeFailure` is set, so nothing writes to it and
            // no empty bucket can reach the publish outbox.
            failure = String(describing: error)
            guard let fallback = try? Self.makeFallbackContainer() else {
                // Genuinely unrecoverable: SwiftData cannot open a store that
                // has no file behind it. There is no screen left to show.
                fatalError("Failed to create an in-memory ModelContainer: \(error)")
            }
            container = fallback
        }

        self.storeFailure = failure

        let service = Self.makeService(isUITesting: isUITesting)
        let library = MediaLibraryViewModel(modelContext: container.mainContext)

        self.modelContainer = container
        self.service = service
        _library = State(initialValue: library)
        _recommender = State(initialValue: Self.makeRecommender(service: service, library: library))
        let stack = Self.makeSocialStack(isUITesting: isUITesting)
        self.social = stack
        let session = SessionViewModel(service: stack?.auth)
        _session = State(initialValue: session)
        _sync = State(initialValue: Self.makeSyncEngine(stack: stack, library: library, session: session))
        _restorer = State(initialValue: Self.makeRestorer(stack: stack, library: library, session: session))
    }

    /// The publish half of the social stack.
    ///
    /// Separate from `makeSocialStack` because it needs the library and the
    /// session, which the stack knows nothing about — publishing is the one
    /// place where the local ranking and the server meet, and it is built where
    /// both are in scope rather than by handing the stack a view model.
    ///
    /// The mock stack publishes into `MockPublishTransport`. The consent sheet
    /// and the Settings publishing section only exist once an account does,
    /// which makes them the two surfaces hardest to look at — an engine over a
    /// transport that reaches nothing is what makes them reachable under
    /// `-uiTestingMockSocial`.
    @MainActor
    static func makeSyncEngine(
        stack: SocialStack?,
        library: MediaLibraryViewModel,
        session: SessionViewModel
    ) -> SyncEngine? {
        guard let stack else { return nil }

        let transport: PublishTransport
        if let client = stack.client, let configuration = stack.configuration {
            transport = SupabasePublishTransport(client: client, configuration: configuration)
        } else {
            transport = MockPublishTransport()
        }

        return SyncEngine(
            library: library,
            transport: transport,
            feed: stack.feed,
            consent: PublishConsent(),
            currentUserID: { session.profile?.id }
        )
    }

    /// The pull half. Built beside `makeSyncEngine` and for the same reason —
    /// it needs the library and the session, which the stack knows nothing
    /// about.
    @MainActor
    static func makeRestorer(
        stack: SocialStack?,
        library: MediaLibraryViewModel,
        session: SessionViewModel
    ) -> LibraryRestorer? {
        guard let stack else { return nil }

        let service: LibraryRestoreService
        if let client = stack.client, let configuration = stack.configuration {
            service = SupabaseLibraryRestoreService(client: client, configuration: configuration)
        } else {
            service = MockLibraryRestoreService()
        }

        return LibraryRestorer(
            library: library,
            service: service,
            currentUserID: { session.profile?.id }
        )
    }

    // MARK: - Store

    /// The store, resolved from the versioned schema and the migration plan.
    ///
    /// **Extracted so a test can run the same resolution the app runs.** This is
    /// the one line in the app that a green unit suite has twice failed to
    /// cover: `SyncEngine` sat with no call site under 463 passing tests, and a
    /// `MigrationStage` whose from- and to-checksums matched aborted the app on
    /// launch under 531. Both lived here, in wiring that no test reached
    /// because no test constructs `BingedApp` (`GAP-AUDIT` §6).
    ///
    /// Naming a *versioned* schema rather than a bare model list is what gives a
    /// shape change somewhere to migrate from. It names the **latest** version:
    /// the plan walks a store forward from whatever it is, and naming an older
    /// one would silently drop the newer properties out of the active schema.
    static func makeModelContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: BingedSchemaV1.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: BingedMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        )
    }

    /// A throwaway store for the scene to attach to when the real one will not
    /// open. Never shown as a library — `body` swaps the whole UI for
    /// `StoreRecoveryView` when `storeFailure` is set.
    ///
    /// Deliberately carries **no migration plan**: it exists precisely because
    /// the plan failed, and re-running it here would fail the same way.
    static func makeFallbackContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: BingedSchemaV1.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
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
    static func makeRecommender(
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
    static func makeSocialStack(
        isUITesting: Bool,
        useMockSocial: Bool = ProcessInfo.processInfo.arguments.contains(mockSocialArgument)
    ) -> SocialStack? {
        if useMockSocial {
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

    // MARK: - Publishing

    /// Re-reads consent for whoever is signed in now, drains, and asks the
    /// sharing question if it has never been answered.
    ///
    /// **The drain runs either way.** The library belongs in the account so that
    /// signing in on another device restores it, and somebody who has not
    /// answered a question about followers has not declined to keep their own
    /// data — unanswered rows go up private. The answer decides `is_published`
    /// and nothing else.
    @MainActor
    private func sessionChanged() async {
        guard let sync else { return }
        sync.refreshConsent()

        // A stale prompt for a previous account must go before a new one can
        // appear.
        consentPrompt = nil
        if sync.needsConsentDecision, let userID = session.profile?.id {
            consentPrompt = ConsentPrompt(id: userID)
        }

        // **Restore before drain, and the order is not a preference.** Draining
        // first would push a device that has not yet seen the account over the
        // top of it: last-write-wins, and the account loses whatever this device
        // never knew about. Restoring first merges both sides, then the drain
        // sends the union.
        //
        // A failed restore returns 0 and leaves the library untouched, so the
        // drain below still runs — this device's own rankings are not held
        // hostage to a network it cannot reach. What it must never do is treat
        // an unreachable account as an empty one, which is why
        // `LibraryRestoreService` throws rather than returning [].
        if session.isSignedIn {
            await restorer?.restore()
        } else {
            restorer?.reset()
        }

        await sync.drain()
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
    static func makeService(isUITesting: Bool) -> MediaService {
        guard !isUITesting, let configuration = TMDBConfiguration.fromBundle() else {
            return MockMediaService()
        }
        return TMDBMediaService(configuration: configuration)
    }

    var body: some Scene {
        WindowGroup {
            // A store that would not open must not be papered over with a
            // working-looking UI: an empty library invites the user to
            // re-rank on top of data that is still there.
            if let storeFailure {
                StoreRecoveryView(message: storeFailure)
            } else {
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
                    .environment(sync)
                    .task { await runStartupMaintenance() }
                    .task { await session.restore() }
                    // Subscribed at launch because MetricKit delivers the
                    // *previous* run's crash on this one — a subscriber
                    // registered later misses the report it exists for.
                    .task { DiagnosticsReporter.shared.start() }
                    // Trigger 1 — the session changed. Covers both a fresh sign-in
                    // and a session restored at launch, and re-reads consent first
                    // because the answer belongs to the account, not the device.
                    .task(id: session.profile?.id) { await sessionChanged() }
                    // Trigger 2 — foreground. Catches whatever failed while the app
                    // was away, including a failure it never got to retry.
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        Task { await sync?.drain() }
                    }
                    // Trigger 3 — the library changed. One central trigger rather
                    // than a call after each of the five mutation sites: "remember
                    // to drain everywhere" is the same instruction the vacated-bucket
                    // bug got wrong twice. `drain` skips a ranking in progress and
                    // costs nothing when the outbox is empty.
                    .onChange(of: library.revision) { _, _ in
                        Task { await sync?.drain() }
                    }
                    // Trigger 4 — the network came back.
                    .onAppear {
                        connectivity.start { Task { @MainActor in await sync?.drain() } }
                    }
                    .sheet(item: $consentPrompt) { _ in
                        PublishConsentView(
                            publishableCount: sync?.publishableCount ?? 0,
                            unpublishableCount: sync?.unpublishableCount ?? 0
                        ) { granted in
                            consentPrompt = nil
                            // The local answer gates the *next* drain's flag, so
                            // a failed flip here costs visibility on rows already
                            // up — which Settings can retry — not the sync.
                            Task { try? await sync?.record(consent: granted) }
                        }
                    }
            }
        }
        .modelContainer(modelContainer)
    }
}
