//
//  SocialService.swift
//  Binged
//
//  Finding people and the edges between them.
//
//  **Blocking lives here, not in the moderation phase.** The graph is where a
//  block has to be enforced — every visibility check downstream reads from it —
//  and adding it later would mean retrofitting each one.
//

import Foundation

// MARK: - SocialService

protocol SocialService: Sendable {

    /// Handle and display-name search. Paginated because a popular prefix
    /// matches thousands.
    func searchUsers(query: String, limit: Int) async throws -> [UserProfile]

    func profile(handle: String) async throws -> UserProfile?

    func relationship(with userID: UUID) async throws -> SocialRelationship

    /// The viewer's follow state toward each of `userIDs`.
    ///
    /// A batch because the caller is a list: people search renders twenty-five
    /// rows, and asking `relationship` per row would be twenty-five requests to
    /// draw twenty-five buttons.
    ///
    /// Users with no edge are **absent from the result** rather than mapped to
    /// `.none`, so a caller can tell "no relationship" from "not asked about".
    func followStates(for userIDs: [UUID]) async throws -> [UUID: FollowState]

    /// Follows, or requests to follow a private account.
    /// - Returns: the resulting state, which the server decides.
    func follow(_ userID: UUID) async throws -> FollowState

    func unfollow(_ userID: UUID) async throws

    /// Pending requests awaiting the signed-in user's approval.
    func pendingRequests() async throws -> [UserProfile]

    /// How many requests are waiting, for a badge that has no list to show.
    ///
    /// Separate from `pendingRequests` because the two want different amounts
    /// of data: the screen wants every requester, and a badge that can only
    /// render "9+" wants ten rows at most. A conformer that cannot do better
    /// gets the default below.
    ///
    /// - Parameter limit: the most the caller can display. Returning fewer than
    ///   the true total is expected once the total exceeds it.
    func pendingRequestCount(limit: Int) async throws -> Int

    func acceptRequest(from userID: UUID) async throws
    func rejectRequest(from userID: UUID) async throws

    func followers(of userID: UUID, limit: Int) async throws -> [UserProfile]
    func following(of userID: UUID, limit: Int) async throws -> [UserProfile]

    func block(_ userID: UUID) async throws
    func unblock(_ userID: UUID) async throws

    /// People the signed-in user has blocked.
    ///
    /// Needs its own server function rather than a select-and-join: blocking is
    /// mutual invisibility, so `profiles_select` hides a blocked profile from
    /// the blocker too and a client-side join yields bare ids. Without this,
    /// blocking is irreversible.
    func blockedAccounts() async throws -> [UserProfile]
}

// MARK: - Defaults

extension SocialService {

    /// One request per user, for conformers with nothing better. Correct but
    /// chatty — `SupabaseSocialService` overrides it with a single query.
    func followStates(for userIDs: [UUID]) async throws -> [UUID: FollowState] {
        var states: [UUID: FollowState] = [:]
        for id in userIDs {
            states[id] = try await relationship(with: id).state
        }
        return states
    }

    /// Counts the full list. Correct everywhere, wasteful only where the list
    /// is long — which is why `SupabaseSocialService` asks for a bounded page
    /// instead.
    func pendingRequestCount(limit: Int) async throws -> Int {
        try await pendingRequests().count
    }
}

// MARK: - SocialError

enum SocialError: Error, Equatable, CustomStringConvertible {
    /// The database's own check constraint, surfaced. Not a UI guard — a client
    /// that forgets the guard must still fail.
    case cannotFollowSelf
    case blocked
    case notFound
    case notConfigured
    case underlying(String)

    var description: String {
        switch self {
        case .cannotFollowSelf: return "You cannot follow yourself."
        case .blocked:          return "That account is unavailable."
        case .notFound:         return "No such account."
        case .notConfigured:    return "Social features are not available in this build."
        case .underlying(let m): return m
        }
    }
}
