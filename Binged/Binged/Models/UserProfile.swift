//
//  UserProfile.swift
//  Binged
//
//  A person, as the server knows them. Deliberately *not* a SwiftData `@Model`:
//  the store holds the user's own library, and remote objects are cache. Mixing
//  them would make signing out a data-migration problem instead of a delete.
//

import Foundation

// MARK: - UserProfile

struct UserProfile: Codable, Identifiable, Hashable, Sendable {

    let id: UUID

    /// Unique, lowercase, the thing that appears in a URL.
    var handle: String

    var displayName: String?
    var bio: String?
    var avatarURL: String?

    /// When true, only accepted followers see this person's activity. The
    /// server enforces it; the client must never be the only thing that does.
    var isPrivate: Bool

    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case handle
        case displayName = "display_name"
        case bio
        case avatarURL = "avatar_url"
        case isPrivate = "is_private"
        case createdAt = "created_at"
    }

    /// What to show when there is no display name. Never an empty string.
    var name: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "@\(handle)" : trimmed
    }
}

// MARK: - Handle

/// The rules a handle must satisfy before it is worth asking the server.
///
/// The client checks these to give instant feedback; **the unique constraint in
/// Postgres is the real arbiter**, and a 409 must be handled regardless. Two
/// people can pass an availability check for the same handle within the same
/// second, and only one insert will win.
enum Handle {

    static let minimumLength = 3

    /// 20, because `profiles_handle_format` says `^[a-z0-9_]{3,20}$`.
    ///
    /// The database is the boundary, so the client must never be the *more*
    /// permissive of the two: at 24 this accepted handles the insert then
    /// rejected with a check violation, which reaches the user as a generic
    /// failure on a handle the form had just told them was fine. Stricter than
    /// the constraint would be harmless; looser is a bug.
    static let maximumLength = 20

    enum Problem: Equatable {
        case tooShort
        case tooLong
        case invalidCharacters
        case reserved

        var message: String {
            switch self {
            case .tooShort:  return "Handles need at least \(Handle.minimumLength) characters."
            case .tooLong:   return "Handles can be at most \(Handle.maximumLength) characters."
            case .invalidCharacters:
                return "Letters, numbers and underscores only."
            case .reserved:  return "That handle is reserved."
            }
        }
    }

    /// Names that would collide with routes or impersonate the app.
    ///
    /// A superset of `profiles_handle_reserved`, for the reason above: every
    /// name the constraint rejects must be rejected here first, or the user
    /// meets it as a failed insert instead of as form validation. Extras beyond
    /// the constraint's list are fine — refusing early costs nothing.
    private static let reserved: Set<String> = [
        // In profiles_handle_reserved.
        "admin", "administrator", "root", "system", "support", "help", "about",
        // Every name this product has ever had stays reserved. A handle does not
        // become claimable because the product moved on — `@watchrank` and
        // `@binge` would both still read as official to anyone who saw an
        // earlier build.
        "api", "watchrank", "binge", "binged", "official", "staff", "moderator", "mod", "settings",
        "login", "signup", "signin", "logout", "me", "you", "null", "undefined",
        "everyone", "all",
        // Client-side only.
        "app", "auth",
    ]

    /// Lowercased and trimmed. Handles are case-insensitive, so the canonical
    /// form is what gets stored and compared.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func validate(_ raw: String) -> Problem? {
        let handle = normalize(raw)
        if handle.count < minimumLength { return .tooShort }
        if handle.count > maximumLength { return .tooLong }
        if reserved.contains(handle) { return .reserved }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        guard handle.unicodeScalars.allSatisfy(allowed.contains) else {
            return .invalidCharacters
        }
        return nil
    }

    static func isValid(_ raw: String) -> Bool { validate(raw) == nil }
}
