//
//  FeedPost.swift
//  WatchRank
//
//  One thing somebody did, frozen at the moment they did it.
//
//  **The payload is denormalised on purpose.** A post says "Alex ranked *Dune*
//  #1 in Liked it" and must go on saying that forever. If it read through to the
//  live ranking, every later insertion into that bucket would silently rewrite
//  history — a follower scrolling back would see a feed that disagrees with what
//  they remember reading, and comments underneath would be answering a sentence
//  that no longer exists.
//

import Foundation

// MARK: - FeedPost

struct FeedPost: Codable, Identifiable, Equatable, Sendable {

    let id: UUID
    let authorID: UUID
    let kind: Kind
    let createdAt: Date

    /// The author as they were when this was fetched. Denormalised for the same
    /// reason as the payload: a feed page must be one request, not one plus a
    /// profile lookup per row.
    let authorHandle: String
    let authorDisplayName: String?
    let authorAvatarURL: String?

    let payload: Payload

    /// Trigger-maintained on the server. The client displays them and never
    /// writes them — a count the client can write is a count that drifts.
    let commentCount: Int
    let reactionCount: Int
    /// Whether the viewer has reacted. Comes from the same query as the post.
    let viewerHasReacted: Bool

    // MARK: Kind

    enum Kind: String, Codable, Equatable, Sendable {
        case ranked
        case wantToWatch = "want_to_watch"
        case reviewed
    }

    // MARK: Payload

    /// Everything needed to render the sentence, captured at post time.
    struct Payload: Codable, Equatable, Sendable {
        let externalId: String
        let title: String
        let year: Int
        let mediaType: MediaType
        /// Absent for `wantToWatch`.
        let sentiment: Sentiment?
        let rankInBucket: Int?
        let bucketSize: Int?
        let reviewExcerpt: String?

        enum CodingKeys: String, CodingKey {
            case externalId = "external_id"
            case title
            case year
            case mediaType = "media_type"
            case sentiment
            case rankInBucket = "rank_in_bucket"
            case bucketSize = "bucket_size"
            case reviewExcerpt = "review_excerpt"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case authorID = "author_id"
        case kind
        case createdAt = "created_at"
        case authorHandle = "author_handle"
        case authorDisplayName = "author_display_name"
        case authorAvatarURL = "author_avatar_url"
        case payload
        case commentCount = "comment_count"
        case reactionCount = "reaction_count"
        case viewerHasReacted = "viewer_has_reacted"
    }

    // MARK: Display

    var authorName: String {
        let trimmed = authorDisplayName?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? "@\(authorHandle)" : trimmed
    }

    /// "ranked", "wants to watch", "reviewed".
    var verb: String {
        switch kind {
        case .ranked:      return "ranked"
        case .wantToWatch: return "wants to watch"
        case .reviewed:    return "reviewed"
        }
    }

    /// "#1 in Liked it", or `nil` when the rank was not earned or does not
    /// apply.
    ///
    /// **Rule 6 again**, applied to the frozen `bucketSize`: a position from a
    /// bucket of one is not a ranking, it is the only thing in the list.
    var rankDescription: String? {
        guard kind == .ranked,
              let sentiment = payload.sentiment,
              let rank = payload.rankInBucket,
              let size = payload.bucketSize,
              size >= 2
        else { return nil }
        return "#\(rank + 1) of \(size) in “\(sentiment.displayName)”"
    }

    /// The whole sentence, for VoiceOver and for tests.
    var sentence: String {
        var text = "\(authorName) \(verb) \(payload.title)"
        if let rank = rankDescription { text += ", \(rank)" }
        return text
    }
}

// MARK: - FeedCursor

/// Where the next page starts.
///
/// `(createdAt, id)` rather than an offset. New posts landing mid-scroll shift
/// every offset underneath the reader, which makes an `OFFSET` page duplicate
/// rows it already showed and skip rows it never did. A keyset cursor is
/// immune: it asks for "older than this exact post", and nothing arriving later
/// can change what that means.
struct FeedCursor: Equatable, Sendable {
    let createdAt: Date
    let id: UUID

    init(createdAt: Date, id: UUID) {
        self.createdAt = createdAt
        self.id = id
    }

    init?(_ post: FeedPost?) {
        guard let post else { return nil }
        self.init(createdAt: post.createdAt, id: post.id)
    }
}
