//
//  DiagnosticsReporter.swift
//  Binged
//
//  Crash, hang and launch-time reports from devices you are not holding.
//
//  **Why `MetricKit` and not a crash-reporting SDK.** The project takes no
//  third-party dependencies, and `MetricKit` is a system framework that supplies
//  the one thing `AppLog` cannot: `OSLog` says what happened on a device in
//  front of you and nothing at all about a device in someone's pocket.
//
//  **This does not transmit anything.** Reports are logged locally, where a
//  sysdiagnose or a Console session can retrieve them. Sending them somewhere
//  is a privacy decision with a manifest entry attached, and not one to make
//  silently on a user's behalf. The value here is that the data stops being
//  discarded — today it is not collected at all.
//
//  Payloads arrive at most once a day, and only after the app is relaunched
//  following the event: a crash on first run reports on the second.
//

import Foundation
import MetricKit
import OSLog

// MARK: - DiagnosticsReporter

final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber {

    static let shared = DiagnosticsReporter()

    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Binged",
        category: "diagnostics"
    )

    /// Registers for delivery. Idempotent — `MXMetricManager` holds subscribers
    /// in a set, so a second call is harmless.
    func start() {
        MXMetricManager.shared.add(self)
    }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads where payload.applicationLaunchMetrics != nil {
            // Launch time is the one routine metric worth a line: it is the
            // first thing a user experiences, the easiest to regress
            // invisibly, and `BingedApp.init()` now resolves the schema and
            // builds every service on the launch path.
            log.info("launch metrics: \(payload.dictionaryRepresentation().count) keys")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                // `.public` is right here and only here. A termination reason
                // and a signal number carry no user content, and redacting them
                // would leave the log useless for its one job. Titles, handles
                // and review text must never be marked public.
                log.critical(
                    "crash: \(crash.terminationReason ?? "unknown", privacy: .public), signal \(crash.signal?.intValue ?? -1, privacy: .public)"
                )
            }
            for hang in payload.hangDiagnostics ?? [] {
                log.error("hang: \(hang.hangDuration.description, privacy: .public)")
            }
            for write in payload.diskWriteExceptionDiagnostics ?? [] {
                log.error("excessive disk writes: \(write.totalWritesCaused.description, privacy: .public)")
            }
        }
    }
}
