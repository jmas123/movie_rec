//
//  LibraryRestorer.swift
//  Binged
//
//  Pulls the account's library down and reconciles it with the device.
//
//  The counterpart to `SyncEngine`, and deliberately not part of it. The engine
//  pushes and owes the server a debt it drains; this pulls and owes the *device*
//  a merge. They meet only in their ordering, which the app enforces: restore
//  before drain, or a device that has not yet seen the account overwrites it.
//
//  See `docs/PART-IV-SYNC.md` §6.5.
//

import Foundation

// MARK: - LibraryRestorer

@MainActor
@Observable
final class LibraryRestorer {

    @ObservationIgnored private let library: MediaLibraryViewModel
    @ObservationIgnored private let service: LibraryRestoreService
    @ObservationIgnored private let currentUserID: () -> UUID?

    /// Accounts already reconciled this launch.
    ///
    /// The restore is idempotent — merging twice against the same account is a
    /// no-op — but it is not *free*, and `sessionChanged()` can fire more than
    /// once for one account. Keyed by account rather than a bare flag, so
    /// signing out and into a different one still restores.
    @ObservationIgnored private var restoredAccounts: Set<UUID> = []

    private var isRestoring = false

    /// Set when a restore could not complete. Distinct from "the account was
    /// empty", which is a successful restore that found nothing.
    private(set) var lastError: String?

    /// Titles the account can never hold, from the last successful restore.
    /// Zero until one runs.
    private(set) var unsyncableCount = 0

    init(
        library: MediaLibraryViewModel,
        service: LibraryRestoreService,
        currentUserID: @escaping () -> UUID?
    ) {
        self.library = library
        self.service = service
        self.currentUserID = currentUserID
    }

    // MARK: Restore

    /// Reconciles the signed-in account's library with this device's.
    ///
    /// - Returns: how many titles the account contributed that the device did
    ///   not have. Zero is the normal answer for a second launch, and for a
    ///   signed-out app.
    ///
    /// **A failure leaves the library exactly as it was.** The merge is computed
    /// in full before anything is written, and a fetch that throws never reaches
    /// that stage. This is the case that matters most: a restore which quietly
    /// returned nothing on a network error would look identical to a new
    /// account, and merging against "nothing" would push this device's library
    /// over an account that was merely unreachable.
    @discardableResult
    func restore(force: Bool = false) async -> Int {
        guard !isRestoring, let userID = currentUserID() else { return 0 }
        guard force || !restoredAccounts.contains(userID) else { return 0 }

        isRestoring = true
        defer { isRestoring = false }

        let remote: [RemoteRankedItem]
        do {
            remote = try await service.myRankedItems(userID: userID)
        } catch {
            // Deliberately not marking the account restored: the next trigger
            // — foreground, connectivity return — should try again.
            lastError = "Could not reach your account. Your library on this device is unchanged."
            return 0
        }

        lastError = nil

        let plan = LibraryMerge.plan(
            local: library.localItemsForMerge(),
            remote: remote,
            unsyncableCount: library.unsyncableCount
        )

        let restored = library.apply(plan, remote: remote)
        unsyncableCount = plan.unsyncableCount
        restoredAccounts.insert(userID)
        return restored
    }

    /// Forgets what has been restored, so the next sign-in reconciles again.
    /// What signing out owes: the next account is not this one.
    func reset() {
        restoredAccounts.removeAll()
        lastError = nil
        unsyncableCount = 0
    }
}
