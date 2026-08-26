//
//  PendingRequestBadge.swift
//  Binged
//
//  How many people are waiting to be let in.
//
//  **Why this exists.** `FollowRequestsView` shipped reachable but unannounced:
//  the only way to learn that somebody had asked to follow a private account was
//  to open Home, tap the people menu and choose Requests on the off-chance. A
//  request that nobody knows about is a request nobody answers, and the person
//  waiting reads the silence as a refusal.
//
//  This is an *in-app* badge and nothing more. There is no push notification in
//  this app — no APNs entitlement, no device-token table, no server to send
//  from — so the honest thing is a count the user meets the next time they open
//  the app, rather than a half-built notification path that fires sometimes.
//

import Foundation
import Observation

// MARK: - PendingRequestBadge

@MainActor
@Observable
final class PendingRequestBadge {

    /// Waiting requests, never more than `displayCap + 1` — the fetch is
    /// bounded, so this is "how many the badge counted", not a true total.
    private(set) var count = 0

    /// The largest number the badge spells out. Above it, "9+".
    static let displayCap = 9

    @ObservationIgnored private var isRefreshing = false

    init() {}

    // MARK: Refresh

    /// Re-reads the count.
    ///
    /// **Failures are swallowed on purpose.** A badge is ambient: an alert
    /// about it would interrupt the user to report something they did not ask
    /// for, and a count that silently keeps its last value is the smaller lie
    /// than one that drops to zero because a request timed out. The screen
    /// behind the badge reports its own errors, where they are actionable.
    func refresh(using service: SocialService?, isSignedIn: Bool) async {
        guard let service, isSignedIn else {
            // Signed out there is no inbox, and a stale badge would point at a
            // screen that can no longer load.
            count = 0
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // One more than the cap: enough to know that "9+" is warranted, and no
        // more than the badge can say.
        guard let found = try? await service.pendingRequestCount(
            limit: Self.displayCap + 1
        ) else { return }
        count = found
    }

    /// Answered requests are gone from the queue; the badge should not outlive
    /// them while a refresh is in flight.
    func clear() { count = 0 }

    // MARK: Display

    /// What the bubble says, or `nil` when there is no bubble.
    var text: String? {
        guard count > 0 else { return nil }
        return count > Self.displayCap ? "\(Self.displayCap)+" : "\(count)"
    }

    /// What VoiceOver says instead of reading a bare number out of context.
    var accessibilityLabel: String {
        switch count {
        case 0:  return "People"
        case 1:  return "People, 1 follow request waiting"
        case ...Self.displayCap: return "People, \(count) follow requests waiting"
        default: return "People, more than \(Self.displayCap) follow requests waiting"
        }
    }
}
