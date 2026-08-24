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

    /// Follows, or requests to follow a private account.
    /// - Returns: the resulting state, which the server decides.
    func follow(_ userID: UUID) async throws -> FollowState

    func unfollow(_ userID: UUID) async throws

    /// Pending requests awaiting the signed-in user's approval.
    func pendingRequests() async throws -> [UserProfile]

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
