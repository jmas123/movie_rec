//
//  CompositionRootTests.swift
//  BingedTests
//
//  GAP-AUDIT Section 6: the layer nothing tested.
//
//  **The gap this closes.** No test constructed anything in `BingedApp`. The
//  suite builds its own `ModelContainer`s and view models directly, so the code
//  that resolves the schema, the migration plan, the catalogue and the social
//  stack ran only when a human launched the app.
//
//  On 2026-08-23 a `MigrationStage.lightweight` between two schema versions
//  whose `models` returned the same live types produced identical checksums,
//  `NSLightweightMigrationStage` threw inside `App.init()`, and the app died
//  with SIGABRT before drawing a frame — **while the suite reported 531 tests
//  green**, because nothing in it reached that code. Every Section 2 finding
//  lived in the same untested layer: three screens with no call site, a service
//  accepted and never read, a button wired to the wrong tab.
//
//  These tests are cheap and they are not clever. That is the point: the
//  failure they guard is catastrophic, instant, and was invisible to 531 tests.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - Schema and migration plan

@Suite("Composition root")
@MainActor
struct CompositionRootTests {

    @Test("The migration plan's stages can be constructed")
    func migrationStagesAreConstructible() {
        // The exact expression that threw. `MigrationStage.lightweight` raises
        // an Objective-C exception when the from- and to-checksums match, which
        // is not catchable in Swift — so merely evaluating this without dying
        // is the assertion.
        let stages = BingedMigrationPlan.stages
        #expect(stages.count == BingedMigrationPlan.schemas.count - 1)
    }

    @Test("Every declared schema version has a distinct identifier")
    func schemaVersionsAreDistinct() {
        let identifiers = BingedMigrationPlan.schemas.map { $0.versionIdentifier }
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test("A schema version whose models duplicate another is a launch abort waiting to happen")
    func schemaVersionsDoNotShareModels() {
        // The actual bug, stated as an invariant rather than as a stack trace.
        // Two versions listing the same live types compute the same checksum,
        // and a lightweight stage between them throws at launch. If someone
        // adds a version without freezing the old models, this fails here
        // instead of on a user's phone.
        let fingerprints = BingedMigrationPlan.schemas.map { schema in
            schema.models.map { String(describing: $0) }.sorted().joined(separator: ",")
        }
        #expect(Set(fingerprints).count == fingerprints.count)
    }

    @Test("The versioned schema names every model the app persists")
    func schemaCoversPersistedModels() {
        let names = Set(BingedSchemaV1.models.map { String(describing: $0) })
        // A `@Model` missing from the schema is not a compile error; it is a
        // table that quietly does not exist.
        #expect(names.contains("MediaItem"))
        #expect(names.contains("PendingPublish"))
    }

    // MARK: Containers

    @Test("The launch container opens")
    func modelContainerOpens() throws {
        // In-memory rather than on-disk: the assertion is that the schema and
        // plan resolve together, and a test has no business touching the
        // developer's real store.
        let container = try BingedApp.makeModelContainer(inMemory: true)
        #expect(container.mainContext.container === container)
    }

    @Test("The fallback container opens, because it is the last line of defence")
    func fallbackContainerOpens() throws {
        // If this throws in production the app calls `fatalError` — it is the
        // one path with no screen left to show, so it had better work.
        let container = try BingedApp.makeFallbackContainer()
        #expect(container.mainContext.container === container)
    }

    // MARK: Services

    @Test("A build with no credentials degrades instead of failing")
    func unconfiguredBuildStillComposes() {
        // The supported state a fresh clone lands in. It must produce a working
        // catalogue and simply no social stack — not a crash, and not a live
        // service pointed at nothing.
        let service = BingedApp.makeService(isUITesting: true)
        #expect(service is MockMediaService)
    }

    // MARK: The suite must not reach the network

    /// The load-bearing half. `makeSocialStack` returning nil below is only
    /// meaningful if `isRunningTests` is actually true in a test run — a
    /// silently-false value would restore live calls with every assertion still
    /// green, which is the exact failure mode this whole file exists for.
    ///
    /// It is asserted separately because it can only be observed from inside a
    /// test process, so there is nowhere else to check it.
    @Test("A test run is detectable from inside the app")
    func testRunIsDetectable() {
        #expect(BingedApp.isRunningTests)
    }

    /// Before this guard, `xcodebuild test` booted the app for real against the
    /// **production** project: `sessionChanged()` read the keychain, restored
    /// the signed-in user's library over the network, and called `sync.drain()`,
    /// which upserts and deletes buckets. A unit-test run could publish or
    /// destroy rows in a real account, and behaved differently depending on
    /// whether that particular simulator happened to hold a session.
    @Test("A test run gets no live social stack, configured or not")
    func testsGetNoLiveSocialStack() {
        // `isUITesting: false` and `useMockSocial: false` is the combination a
        // unit-test run actually presents — neither launch argument is passed —
        // so this is the path that was reaching Supabase.
        let stack = BingedApp.makeSocialStack(isUITesting: false, useMockSocial: false)
        #expect(stack == nil)
    }

    /// The fixture is asked for by name, so it must survive the new guard —
    /// otherwise this change would quietly disarm the UI suite's fast path.
    @Test("The mock social fixture is still available when asked for by name")
    func mockSocialSurvivesTheGuard() {
        let stack = BingedApp.makeSocialStack(isUITesting: false, useMockSocial: true)
        #expect(stack != nil)
        #expect(stack?.client == nil, "the fixture has no client, so nothing can reach a server")
    }
}
