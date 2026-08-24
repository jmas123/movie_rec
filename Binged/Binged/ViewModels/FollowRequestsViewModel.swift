//
//  FollowRequestsViewModel.swift
//  Binged
//
//  The queue of people waiting to be let in.
//

import Foundation
import Observation

// MARK: - FollowRequestsViewModel

@MainActor
@Observable
final class FollowRequestsViewModel {

    enum Phase: Equatable {
        case loading, requests, empty
        case error(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var requests: [UserProfile] = []
    /// People whose request is being answered, so a slow network cannot produce
    /// a double-accept from an impatient second tap.
    private(set) var inFlight: Set<UUID> = []
    private(set) var lastError: String?

    @ObservationIgnored private let service: SocialService?

    init(service: SocialService?) {
        self.service = service
    }

    func load() async {
        guard let service else {
            phase = .empty
            return
        }
        do {
            let found = try await service.pendingRequests()
            requests = found
            phase = found.isEmpty ? .empty : .requests
        } catch {
            phase = .error(ErrorMessage.text(for: error))
        }
    }

    func accept(_ person: UserProfile) async {
        await answer(person) { try await $0.acceptRequest(from: person.id) }
    }

    func reject(_ person: UserProfile) async {
        await answer(person) { try await $0.rejectRequest(from: person.id) }
    }

    /// Removes the row on success and leaves it alone on failure.
    ///
    /// Not optimistic, deliberately — unlike a reaction, an approval is a
    /// permission. Showing someone as admitted and quietly putting them back
    /// would leave the user believing they had granted access they had not.
    private func answer(
        _ person: UserProfile,
        _ work: @escaping (SocialService) async throws -> Void
    ) async {
        guard let service, !inFlight.contains(person.id) else { return }
        inFlight.insert(person.id)
        defer { inFlight.remove(person.id) }

        do {
            try await work(service)
            requests.removeAll { $0.id == person.id }
            if requests.isEmpty { phase = .empty }
        } catch {
            lastError = ErrorMessage.text(for: error)
        }
    }

    func clearError() { lastError = nil }
}
