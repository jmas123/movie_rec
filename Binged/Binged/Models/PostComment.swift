//
//  PostComment.swift
//  Binged
//
//  One comment on one post.
//
//  Named `PostComment` rather than `Comment`: the bare word reads as a keyword
//  at every call site and collides with documentation tooling.
//

import Foundation

// MARK: - PostComment

struct PostComment: Codable, Identifiable, Equatable, Sendable {

    let id: UUID
    let postID: UUID
    let authorID: UUID
    let body: String
    let createdAt: Date

    /// Soft delete. The row stays so the thread keeps its shape — a deleted
    /// comment that vanished entirely would leave replies answering nothing,
    /// and counts that no longer match.
    let deletedAt: Date?

    /// When the author last changed the body; nil means never.
    ///
    /// Recorded so an edit is visible. A comment somebody has already read,
    /// replied to or reported must not be able to become a different comment
    /// with nothing to show for it — a report names an id, and a moderator
    /// looking at that id needs to know the text moved after it was filed.
    let editedAt: Date?

    let authorHandle: String
    let authorDisplayName: String?
    let authorAvatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case postID = "post_id"
        case authorID = "author_id"
        case body
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
        case editedAt = "edited_at"
        case authorHandle = "author_handle"
        case authorDisplayName = "author_display_name"
        case authorAvatarURL = "author_avatar_url"
    }

    var isDeleted: Bool { deletedAt != nil }

    /// Whether to show the "edited" marker. A deleted comment is not marked
    /// edited as well — its body is gone either way, and two disclaimers on one
    /// empty row reads as noise.
    var isEdited: Bool { editedAt != nil && !isDeleted }

    /// The local copy after a successful edit, so a thread can update in place
    /// rather than refetching the whole page to change one string.
    func edited(body newBody: String, at date: Date) -> PostComment {
        PostComment(
            id: id,
            postID: postID,
            authorID: authorID,
            body: newBody,
            createdAt: createdAt,
            deletedAt: deletedAt,
            editedAt: date,
            authorHandle: authorHandle,
            authorDisplayName: authorDisplayName,
            authorAvatarURL: authorAvatarURL
        )
    }

    var authorName: String {
        let trimmed = authorDisplayName?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? "@\(authorHandle)" : trimmed
    }

    /// What to render. A deleted comment keeps its place and loses its content.
    var displayBody: String {
        isDeleted ? "Comment deleted" : body
    }

    // MARK: Validation

    /// Mirrors the database's check constraint.
    ///
    /// The constraint is the real limit — a client that forgets this must still
    /// fail — but rejecting locally means the user finds out while typing rather
    /// than after tapping send.
    static let maximumLength = 1000

    enum Problem: Equatable {
        case empty
        case tooLong(Int)

        var message: String {
            switch self {
            case .empty:            return "Write something first."
            case .tooLong(let over): return "\(over) character\(over == 1 ? "" : "s") too long."
            }
        }
    }

    static func validate(_ raw: String) -> Problem? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > maximumLength { return .tooLong(trimmed.count - maximumLength) }
        return nil
    }
}

// MARK: - Report

/// Why something was reported. Deliberately a closed list: free-text-only
/// reports are unactionable at any volume.
enum ReportReason: String, Codable, CaseIterable, Identifiable, Sendable {
    case spam
    case harassment
    case hateSpeech = "hate_speech"
    case sexualContent = "sexual_content"
    case violence
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spam:          return "Spam"
        case .harassment:    return "Harassment or bullying"
        case .hateSpeech:    return "Hate speech"
        case .sexualContent: return "Sexual content"
        case .violence:      return "Violence or threats"
        case .other:         return "Something else"
        }
    }
}

/// What is being reported. A report must be possible wherever content appears,
/// so the target is a small closed set rather than a free-form string.
enum ReportTarget: Equatable, Sendable, Identifiable {
    case post(UUID)
    case comment(UUID)
    case profile(UUID)

    var column: String {
        switch self {
        case .post:    return "post_id"
        case .comment: return "comment_id"
        case .profile: return "profile_id"
        }
    }

    var id: UUID {
        switch self {
        case .post(let id), .comment(let id), .profile(let id): return id
        }
    }
}
