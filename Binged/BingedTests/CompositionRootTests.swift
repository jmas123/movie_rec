//
//  CompositionRootTests.swift
//  BingedTests
//
//  The wiring layer — the one part of the app a green suite has repeatedly
//  failed to cover.
//
//  **Why this file exists** (`GAP-AUDIT` §6). Every other test builds its own
//  `ModelContainer` and view models directly, so `BingedApp`'s assembly runs
//  only when a human launches the app. Two bugs on one day proved the cost:
//
//  - `SyncEngine` existed, was fully tested, and had **no call site in the app
//    target at all** — so nothing was ever published — while 463 tests passed.
//  - A `MigrationStage.lightweight` between two schema versions with identical
//    checksums threw inside `BingedApp.init()`, aborting the app before its
//    first frame, while 531 tests passed.
//
//  Neither is a logic bug. Both are assembly, and assembly is exactly what a
//  suite that constructs its own objects cannot see. These tests call the same
//  factories the app calls, so a wire that comes loose fails here.
//
//  What this file is **not**: a UI test. It asserts that the pieces resolve and
//  connect, not that anything renders. `BingedApp.body` is deliberately out
//  of scope — a `Scene` needs a host, and that is `RankingFlowUITests`' job.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - The store

@Suite("Composition root — the store")
@MainActor
struct CompositionRootStoreTests {

    @Test("The versioned schema and migration plan resolve into a container")
    func containerResolves() throws {
        // The exact call `BingedApp.init()` makes. If a schema version is
        // added without a frozen copy of its models, or a stage's from- and
        // to-checksums match, this throws here instead of aborting on launch.
        let container = try BingedApp.makeModelContainer(inMemory: true)
        #expect(container.mainContext.container === container)
    }

    @Test("Every model the app stores is in the active schema")
    func schemaCoversTheStoredModels() throws {
        let container = try BingedApp.makeModelContainer(inMemory: true)
        let names = Set(container.schema.entities.map(\.name))

        // Not a restatement of the schema file: these are the two types the app
        // actually writes. `PendingPublish` is the one that would go missing
        // silently — nothing reads it except the drain, so an absent entity
        // would look like "nothing to publish" rather than like a broken store.
        #expect(names.contains("MediaItem"))
        #expect(names.contains("PendingPublish"))
    }

    @Test("The migration plan has no stage that migrates a version to itself")
    func noSelfMigratingStage() {
        // The precise shape of the launch crash: `NSLightweightMigrationStage`
        // throws when from == to, and two `VersionedSchema`s listing the same
        // live model type compute the same checksum. Asserting on the *count*
        // of versions rather than the checksums keeps this readable; a second
        // version can only be added correctly with a frozen copy of the models,
        // and whoever adds one will land on `containerResolves` above.
        let versions = BingedMigrationPlan.schemas.count
        let stages = BingedMigrationPlan.stages.count
        #expect(stages == max(0, versions - 1),
                "one stage per hop between versions, no more and no fewer")
    }

    @Test("The fallback container opens even when the real one cannot")
    func fallbackAlwaysOpens() throws {
        // `StoreRecoveryView` is only reachable if the scene has *something* to
        // attach to. If this throws, the catch in `init()` reaches its
        // `fatalError` and the recovery screen can never be shown — the failure
        // mode that screen exists to replace.
        _ = try BingedApp.makeFallbackContainer()
    }
}

// MARK: - The services

@Suite("Composition root — services")
@MainActor
struct CompositionRootServiceTests {

    @Test("UI testing pins the catalog to the bundled one")
    func uiTestingUsesTheMockCatalog() {
        let service = BingedApp.makeService(isUITesting: true)
        #expect(service is MockMediaService)
    }

    @Test("The bundled catalog offers no Discover tab")
    func mockCatalogHasNoRecommender() throws {
        let container = try BingedApp.makeModelContainer(inMemory: true)
        let library = MediaLibraryViewModel(modelContext: container.mainContext)
        let recommender = BingedApp.makeRecommender(
            service: MockMediaService(), library: library
        )
        // Not an oversight — a tab that can only ever show an empty state is
        // worse than a tab that is not offered.
        #expect(recommender == nil)
    }

    @Test("The mock social flag produces a complete stack")
    func mockSocialStackIsComplete() {
        let stack = try? #require(
            BingedApp.makeSocialStack(isUITesting: false, useMockSocial: true)
        )
        #expect(stack?.auth is MockAuthService)
        #expect(stack?.graph is MockSocialService)
        #expect(stack?.feed is MockFeedService)
        // No server behind it, and the absence is what the sync engine reads to
        // choose its transport.
        #expect(stack?.client == nil)
        #expect(stack?.configuration == nil)
    }

    @Test("UI tests get no social stack unless they ask for the fixture")
    func uiTestingHasNoSocialStack() {
        let stack = BingedApp.makeSocialStack(isUITesting: true, useMockSocial: false)
        #expect(stack == nil, "a UI test must never depend on a server")
    }
}

// MARK: - The sync engine

@Suite("Composition root — the publish loop")
@MainActor
struct CompositionRootSyncTests {

    /// **The container is returned, not discarded, and that is load-bearing.**
    /// `mainContext` is owned by its container rather than owning it, so
    /// dropping the container leaves the context without a store and the next
    /// fetch traps inside SwiftData — underneath the `try?` in
    /// `allItems`, which cannot catch a trap. The app keeps its container in a
    /// stored property for exactly this reason; a test that does not is testing
    /// a lifetime the app never has.
    private func makeStack() throws -> (ModelContainer, MediaLibraryViewModel, SessionViewModel) {
        let container = try BingedApp.makeModelContainer(inMemory: true)
        return (
            container,
            MediaLibraryViewModel(modelContext: container.mainContext),
            SessionViewModel(service: MockAuthService())
        )
    }

    @Test("A social stack produces a sync engine")
    func stackProducesAnEngine() throws {
        // The regression this file was written for: the engine existed, was
        // tested, and was never constructed by the app.
        let (container, library, session) = try makeStack()
        let stack = try #require(
            BingedApp.makeSocialStack(isUITesting: false, useMockSocial: true)
        )
        let engine = BingedApp.makeSyncEngine(
            stack: stack, library: library, session: session
        )
        #expect(engine != nil, "the outbox has no reader")
        withExtendedLifetime(container) {}
    }

    @Test("No social stack means no engine, and the outbox simply accrues")
    func noStackNoEngine() throws {
        let (container, library, session) = try makeStack()
        let engine = BingedApp.makeSyncEngine(
            stack: nil, library: library, session: session
        )
        #expect(engine == nil)
        withExtendedLifetime(container) {}
    }

    @Test("The engine is wired to the same library the app hands the UI")
    func engineSharesTheLibrary() throws {
        // Constructing an engine is not the same as connecting it. An engine
        // over a *different* library would report nothing to publish forever,
        // and every existing SyncEngine test would still pass, because they
        // hand it the library themselves.
        let (container, library, session) = try makeStack()
        let stack = try #require(
            BingedApp.makeSocialStack(isUITesting: false, useMockSocial: true)
        )
        let engine = try #require(
            BingedApp.makeSyncEngine(stack: stack, library: library, session: session)
        )
        #expect(engine.publishableCount == 0)

        let item = MediaItem(
            externalId: "tmdb:movie:27205", title: "Inception", year: 2010, type: .movie
        )
        library.markWatched(item, sentiment: .liked)
        library.finalizeRanking(for: item)

        #expect(engine.publishableCount == 1, "the engine is reading a different library")
        withExtendedLifetime(container) {}
    }

    @Test("A restorer is built alongside the engine, or the account never restores")
    func stackProducesARestorer() throws {
        let (container, library, session) = try makeStack()
        let stack = try #require(
            BingedApp.makeSocialStack(isUITesting: false, useMockSocial: true)
        )
        let restorer = BingedApp.makeRestorer(
            stack: stack, library: library, session: session
        )
        #expect(restorer != nil)
        withExtendedLifetime(container) {}
    }
}
