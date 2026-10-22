//
//  TitleLike.swift
//  Binged
//
//  One person you follow, one title of theirs — and the fact that they liked it.
//
//  A `TitleWatcher` with the title put back in. `TitleWatcher` exists for the
//  screen where the title is already known and the person is what has to be
//  carried; this is for the screen that asks about *many* titles at once — a
//  cast member's filmography — where the answer is useless unless each opinion
//  says which film it is about.
//
//  So it carries a `TitleWatcher` rather than restating its fields. That is not
//  only to avoid the duplication: `displayScore` applies rule 6's bucket
//  threshold, and a second copy of that rule is a second place for a friend's
//  unearned "8.4" to escape.
//
//  Decoded flat. The RPC returns one row per opinion with the title columns
//  alongside the person's, which is the shape Postgres produces and the shape
//  `title_watchers` already produces — so the nesting is Swift's idea and the
//  decoder does the folding.
//

import Foundation

// MARK: - TitleLike

struct TitleLike: Decodable, Identifiable, Sendable {

    let externalId: String
    let mediaType: MediaType

    /// Who liked it, and by how much.
    let person: TitleWatcher

    /// Unique per (title, person): the same friend appears against several of
    /// an actor's films, and the same film against several friends.
    var id: String { "\(externalId)|\(person.userID.uuidString)" }

    enum CodingKeys: String, CodingKey {
        case externalId = "external_id"
        case mediaType = "media_type"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        externalId = try container.decode(String.self, forKey: .externalId)
        mediaType = try container.decode(MediaType.self, forKey: .mediaType)
        // The same flat object, read again through `TitleWatcher`'s own keys.
        person = try TitleWatcher(from: decoder)
    }

    /// For fixtures and previews, which have a watcher and a title and no JSON.
    init(externalId: String, mediaType: MediaType, person: TitleWatcher) {
        self.externalId = externalId
        self.mediaType = mediaType
        self.person = person
    }
}
