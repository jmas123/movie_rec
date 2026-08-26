//
//  UserSearchViewModel.swift
//  Binged
//
//  Finding people, and the optimistic follow button.
//

import Foundation
import Observation

// MARK: - UserSearchViewModel

@MainActor
@Observable
final class UserSearchViewModel {

    enum Phase: Equatable {
        case prompt, searching, results, noResults, error(String)
    }

    var query: String = "" {
        didSet {
            // **Only when it actually changed.** `didSet` fires on every
            // assignment, and a `.searchable` binding writing the same string
            // back is an assignment. Restarting on a no-op cancels the in-flight
            // `searchTask` and re-arms the debounce — and because `seedStates`
            // runs *after* `results` is published inside that same task, a
            // write-back landing in that window kills the follow-state read
            // before it can store anything. `isStateKnown` then stays false and
            // every Follow button is disabled at 40% opacity, permanently,
            // because each restart re-enters the same window. Reported from a
            // device on 2026-08-26 as an account that looked "unselected".
            //
            // `SearchView.reset()` already guards its own writes this way
            // (`if people.query != "" { … }`), which is the same lesson learned
            // at the call site instead of here, where it belongs.
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }

    private(set) var phase: Phase = .prompt
    private(set) var results: [UserProfile] = []

    /// Follow state per user, held here so a row can render optimistically
    /// without each one holding its own copy.
    private(set) var states: [UUID: FollowState] = [:]

    /// Whether the last relationship read failed.
    ///
    /// Separate from `phase`, deliberately: the search itself succeeded and the
    /// results are worth showing, so this must not take the screen over with an
    /// error state. It exists so the failure is *knowable* — by a view that
    /// wants to caption it, and by anyone reading a log — rather than showing up
    /// only as buttons that behave oddly.
    private(set) var stateReadFailed = false

    @ObservationIgnored private let service: SocialService
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    static let debounce = Duration.milliseconds(300)
    static let pageSize = 25

    init(service: SocialService) {
        self.service = service
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespaces)

        guard !needle.isEmpty else {
            phase = .prompt
            results = []
            return
        }

        phase = .searching
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await search(needle)
        }
    }

    private func search(_ needle: String) async {
        do {
            let found = try await service.searchUsers(query: needle, limit: Self.pageSize)
            guard !Task.isCancelled else { return }
            results = found
            phase = found.isEmpty ? .noResults : .results
            await seedStates(for: found)
        } catch is CancellationError {
            // A newer search superseded this one; the new task owns the states.
            // Not a failure, and must not be recorded as one.
            return
        } catch {
            guard !Task.isCancelled else {
                AppLog.network.debug("Follow-state read cancelled by a newer search.")
                return
            }
            phase = .error(ErrorMessage.text(for: error))
        }
    }

    /// Reads the viewer's real relationship with each result.
    ///
    /// **This used to assume `.none`**, which made every row say "Follow" —
    /// including rows for people the viewer already followed, and people whose
    /// request was still pending. Tapping such a row re-sent the follow, which
    /// the server refused (`follows_update` is the followee's policy, not the
    /// follower's), and the refusal surfaced as **"No such account."** on a
    /// screen displaying that account.
    ///
    /// `follow` is idempotent now, so the stale button no longer errors — but a
    /// button that offers to do something already done is still wrong, and a
    /// pending request that presents itself as un-sent invites the user to send
    /// it again and wonder why nothing happens.
    ///
    /// **A failed read must not be mistaken for a slow one.** This originally
    /// returned early on failure, on the reasoning that silence beats a
    /// confident wrong answer. That is right about the *state* and wrong about
    /// the *button*: `isStateKnown` gates it, so leaving the states alone left
    /// every row's Follow permanently disabled at 40% opacity, with nothing on
    /// screen to say why and no way to retry. Reported from a device on
    /// 2026-08-26 as an account that looked "unselected".
    ///
    /// So a failure now falls back to `.none` and records that it did. That is
    /// safe in a way it was not when the original comment was written: `follow`
    /// is idempotent server-side and *returns the resulting state*, so acting on
    /// an unread relationship self-corrects on the first tap. The residual cost
    /// is a pending request that offers Follow again — one wasted tap that
    /// resolves itself — against a control that never works at all.
    private func seedStates(for people: [UserProfile]) async {
        let unknown = people.map(\.id).filter { states[$0] == nil }
        guard !unknown.isEmpty else { return }

        let found: [UUID: FollowState]
        do {
            found = try await service.followStates(for: unknown)
            stateReadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            // Swallowed by `try?` before, which is why this was invisible both
            // to the user and to anyone reading a log.
            AppLog.network.error(
                "Follow-state read failed: \(ErrorMessage.text(for: error), privacy: .public)"
            )
            stateReadFailed = true
            // `FollowState.none` spelled out, not `.none`. The subscript setter
            // takes `FollowState?`, so a bare `.none` binds to `Optional.none`
            // and *removes* the key — leaving `isStateKnown` false and the
            // button disabled, which is the exact bug this is fixing. The line
            // below survives it only because `??` forces the non-optional type.
            for id in unknown { states[id] = FollowState.none }
            return
        }
        guard !Task.isCancelled else { return }

        for id in unknown {
            // Absent from the answer means no edge — see `followStates`.
            //
            // **`FollowState.none`, spelled out.** The subscript setter takes
            // `FollowState?`, so `?? .none` selects the `T? ?? T?` overload and
            // yields `Optional.none` — which *removes* the key instead of
            // storing "no edge". `isStateKnown` then reports false for exactly
            // the people who have no relationship, which is everyone a search
            // for somebody new returns, and their Follow button renders
            // disabled at 40% opacity for good. The compiler warns about this
            // ("assuming you mean 'Optional<FollowState>.none'") and the warning
            // was not treated as an error.
            states[id] = found[id] ?? FollowState.none
        }
    }

    // MARK: Following

    func state(for user: UserProfile) -> FollowState {
        states[user.id] ?? .none
    }

    /// Whether the relationship has actually been read back yet.
    ///
    /// `state(for:)` answers `.none` for an unknown user because a button needs
    /// *a* title, but "no edge" and "not asked yet" are different claims and
    /// only one of them should be actionable. Results appear before the states
    /// do — deliberately, so search stays as fast as the search — and offering
    /// Follow during that window is how a pending request gets sent twice.
    func isStateKnown(for user: UserProfile) -> Bool {
        states[user.id] != nil
    }

    /// Follows or unfollows, updating immediately and rolling back on failure.
    ///
    /// Optimism is what makes the button feel instant; the rollback is what
    /// stops a failed request leaving a phantom follow that survives until the
    /// next refresh and confuses everything downstream.
    func toggleFollow(_ user: UserProfile) async {
        let current = state(for: user)
        guard current.isActionable else { return }

        let optimistic = current.next(targetIsPrivate: user.isPrivate)
        states[user.id] = optimistic

        do {
            if optimistic == .none {
                try await service.unfollow(user.id)
            } else {
                // The server decides active vs pending — it is the only side
                // that knows for certain whether the target is private.
                states[user.id] = try await service.follow(user.id)
            }
        } catch {
            states[user.id] = current
            phase = .error(ErrorMessage.text(for: error))
        }
    }

    func block(_ user: UserProfile) async {
        do {
            try await service.block(user.id)
            states[user.id] = .blocked
            results.removeAll { $0.id == user.id }
        } catch {
            phase = .error(ErrorMessage.text(for: error))
        }
    }

    /// Re-runs the last search after a failure, without the debounce — the
    /// user has already waited, and tapping Try again is not a keystroke.
    func retry() {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            phase = .prompt
            return
        }
        searchTask?.cancel()
        phase = .searching
        searchTask = Task { await search(needle) }
    }

    func clearError() {
        if case .error = phase { phase = results.isEmpty ? .prompt : .results }
    }
}
