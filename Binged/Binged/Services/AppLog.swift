//
//  AppLog.swift
//  Binged
//
//  Where failures go when there is no user to tell.
//
//  **Why this exists.** The app had no logging of any kind — no `OSLog`, no
//  `MetricKit`, not one `print`. Combined with the write path that discarded
//  its errors, a failed save in production was invisible to the user *and*
//  invisible to the developer. There was no way to find out it had happened.
//
//  `OSLog` and `MetricKit` are both system frameworks, so this adds no
//  dependency — the project's no-third-party rule is intact.
//
//  **Privacy.** `Logger` redacts interpolated strings by default, and that
//  default is kept. Titles, handles, emails and review text must never be
//  marked `public`: the log is readable over a cable and shipped in a sysdiagnose.
//  Categories and error descriptions are safe; user content is not.
//

import Foundation
import OSLog

// MARK: - AppLog

enum AppLog {

    private static let subsystem = Bundle.main.bundleIdentifier ?? "Binged"

    /// The SwiftData store: saves, fetches, migrations.
    static let persistence = Logger(subsystem: subsystem, category: "persistence")

    /// TMDB, and the catalogue cache in front of it.
    static let catalog = Logger(subsystem: subsystem, category: "catalog")

    /// Supabase: auth, the social graph, the feed.
    static let network = Logger(subsystem: subsystem, category: "network")

    /// The publish outbox.
    static let sync = Logger(subsystem: subsystem, category: "sync")

    /// Background maintenance that nobody is waiting on — the feature backfill,
    /// the external-id migration. These fail silently by design, which is
    /// exactly why they need a log line.
    static let maintenance = Logger(subsystem: subsystem, category: "maintenance")
}
