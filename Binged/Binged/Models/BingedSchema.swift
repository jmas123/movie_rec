//
//  BingedSchema.swift
//  Binged
//
//  The persisted shape of the app, versioned.
//
//  **Why this exists now, with only one version in it.** The app previously
//  built its `ModelContainer` from a bare model list and crashed on
//  `fatalError` if the store would not open. CLAUDE.md's advice for that —
//  delete the app and relaunch — is fine on a simulator and impossible on a
//  stranger's phone, and it stopped being merely awkward at Phase 23: the
//  store now holds `PendingPublish`, the only record of what this device owes
//  the server. A store that will not open loses that silently.
//
//  A `VersionedSchema` cannot be introduced retroactively. Stamping V1 while V1
//  is the only version in the world is free; doing it after a build ships means
//  writing a migration *from* an unversioned store, which is the expensive
//  version of this file. Nothing here changes the on-disk format today — it
//  names what is already there.
//
//  **Adding a version — and the trap in it.** The obvious procedure is: copy
//  `BingedSchemaV1` to `V2`, add both to `schemas`, append a
//  `MigrationStage`. That is wrong on its own, and it fails in the worst
//  possible way.
//
//  A `VersionedSchema` describes the models *as they were at that version*. If
//  V1 and V2 both list the live `MediaItem.self`, they describe the same shape
//  and compute the **same version checksum** —
//  `NSLightweightMigrationStage` throws when `from == to`. Because the plan is
//  built inside `BingedApp.init()`, that throw is unrecoverable: the app
//  aborts with SIGABRT before drawing a frame. `StoreRecoveryView` cannot catch
//  it either, since it guards `ModelContainer` creation and this fails one line
//  earlier, building the plan itself.
//
//  This happened on 2026-08-23, adding `MediaItem.lastRankedAt`. Note that the
//  unit suite stayed green throughout — it builds containers directly and never
//  calls `BingedApp.init()`, so **a launch crash is invisible to it.** Run
//  the app, or the UI tests, after touching this file.
//
//  So a real version needs a **frozen copy** of every changed model: a
//  `MediaItemV1` `@Model` inside a V1 namespace carrying the old property list,
//  with only V2 referring to the live type. That is the actual price of a schema
//  version. It is worth paying the moment a build ships — a stranger's phone
//  holds a store nobody can delete — and not before, which is why there is one
//  version here today.
//

import Foundation
import SwiftData

// MARK: - BingedSchemaV1

/// The current persisted shape: the library, and the publish outbox beside it.
///
/// **Why there is only one version here, and why adding a second is not a
/// two-line change.** A `VersionedSchema` must describe the models *as they
/// were at that version*. Two versions that both list the live `MediaItem.self`
/// compute the **same checksum**, and `MigrationStage.lightweight` throws on a
/// stage whose from- and to-checksums match — `NSLightweightMigrationStage
/// initWithVersionChecksums:` raises, and because this runs inside
/// `BingedApp.init()` the app dies with SIGABRT before it draws a frame.
/// That is not a theoretical hazard; it happened here on 2026-08-23.
///
/// So a genuine V2 needs a **frozen copy** of every changed model — a
/// `MediaItemV1` `@Model` inside a V1 namespace, preserving the old property
/// list — with only V2 referring to the live type. That is the real cost of a
/// schema version, and it is worth paying once there is a store in the wild.
///
/// **There is no store in the wild.** Nothing has shipped; development deletes
/// the app between shape changes (CLAUDE.md). `MediaItem.lastRankedAt`, which
/// `PART-IV-SYNC.md` §6.3 introduces, is therefore folded into V1 rather than
/// migrated to — there is no device holding a pre-`lastRankedAt` store to
/// migrate *from*. The first version that ships is the first one that can
/// never be folded into again.
enum BingedSchemaV1: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [MediaItem.self, PendingPublish.self]
    }
}

// MARK: - BingedMigrationPlan

enum BingedMigrationPlan: SchemaMigrationPlan {

    static var schemas: [any VersionedSchema.Type] {
        [BingedSchemaV1.self]
    }

    /// Empty, and correct while there is one version. Adding a stage between
    /// two versions that share their models is what crashed the app — see
    /// `BingedSchemaV1`.
    static var stages: [MigrationStage] { [] }
}
