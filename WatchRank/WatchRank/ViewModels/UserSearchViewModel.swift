//
//  UserSearchViewModel.swift
//  WatchRank
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
            for person in found where states[person.id] == nil {
                states[person.id] = .none
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .error((error as? SocialError)?.description ?? String(describing: error))
        }
    }

    // MARK: Following

    func state(for user: UserProfile) -> FollowState {
        states[user.id] ?? .none
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
            phase = .error((error as? SocialError)?.description ?? String(describing: error))
        }
    }

    func block(_ user: UserProfile) async {
        do {
            try await service.block(user.id)
            states[user.id] = .blocked
            results.removeAll { $0.id == user.id }
        } catch {
            phase = .error((error as? SocialError)?.description ?? String(describing: error))
        }
    }

    func clearError() {
        if case .error = phase { phase = results.isEmpty ? .prompt : .results }
    }
}
