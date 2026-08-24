//
//  FollowState.swift
//  Binged
//
//  The edge between two people, from the viewer's side.
//

import Foundation

// MARK: - FollowState

enum FollowState: String, Codable, Equatable, Sendable {

    /// No edge.
    case none

    /// Requested, awaiting approval. What following a private account produces —
    /// and until it is accepted the follower sees **nothing** of that account's
    /// library.
    case pending

    /// Following, and able to see their activity.
    case active

    /// The viewer blocked them, or they blocked the viewer. Deliberately one
    /// case rather than two: a blocked person must not be able to tell which
    /// direction it went, and the client should not hold the information.
    case blocked

    /// What the follow button should say.
    var actionTitle: String {
        switch self {
        case .none:    return "Follow"
        case .pending: return "Requested"
        case .active:  return "Following"
        case .blocked: return "Blocked"
        }
    }

    /// Whether tapping does anything.
    var isActionable: Bool { self != .blocked }

    /// What a tap moves to, optimistically.
    ///
    /// Private accounts land on `pending`, and the caller supplies that fact
    /// because only the server knows it for certain.
    func next(targetIsPrivate: Bool) -> FollowState {
        switch self {
        case .none:            return targetIsPrivate ? .pending : .active
        case .pending, .active: return .none
        case .blocked:         return .blocked
        }
    }
}

// MARK: - FollowEdge

/// A stored follow row.
struct FollowEdge: Codable, Equatable, Sendable, Identifiable {

    let followerID: UUID
    let followeeID: UUID
    let state: FollowState
    let createdAt: Date?

    var id: String { "\(followerID.uuidString)->\(followeeID.uuidString)" }

    enum CodingKeys: String, CodingKey {
        case followerID = "follower_id"
        case followeeID = "followee_id"
        case state
        case createdAt = "created_at"
    }
}

// MARK: - FollowCounts

struct FollowCounts: Codable, Equatable, Sendable {
    var followers: Int
    var following: Int

    static let zero = FollowCounts(followers: 0, following: 0)

    enum CodingKeys: String, CodingKey {
        case followers = "follower_count"
        case following = "following_count"
    }
}

// MARK: - SocialRelationship

/// Everything a profile screen needs to render its follow button.
struct SocialRelationship: Equatable, Sendable {
    var state: FollowState
    var counts: FollowCounts
    /// Whether *they* follow *you*, for a "Follows you" badge.
    var followsViewer: Bool

    static let unknown = SocialRelationship(
        state: .none, counts: .zero, followsViewer: false
    )
}
