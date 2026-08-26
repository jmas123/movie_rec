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
        didSet { scheduleSearch() }
    }

    private(set) var phase: Phase = .prompt
    private(set) var results: [UserProfile] = []

    /// Follow state per user, held here so a row can render optimistically
    /// without each one holding its own copy.
    private(set) var states: [UUID: FollowState] = [:]

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
        } catch {
            guard !Task.isCancelled else { return }
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
    /// A failure leaves the states alone rather than falling back to `.none`:
    /// silence is better than a confident wrong answer, and the search results
    /// themselves are still worth showing.
    private func seedStates(for people: [UserProfile]) async {
        let unknown = people.map(\.id).filter { states[$0] == nil }
        guard !unknown.isEmpty else { return }

        guard let found = try? await service.followStates(for: unknown) else { return }
        guard !Task.isCancelled else { return }

        for id in unknown {
            // Absent from the answer means no edge — see `followStates`.
            states[id] = found[id] ?? .none
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
