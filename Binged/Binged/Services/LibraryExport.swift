//
//  LibraryExport.swift
//  Binged
//
//  "Download my data", as a file the user can actually read.
//
//  Exports the **local** library, which is the whole of what the app knows about
//  someone's taste — including the parts that were never published. Pure and
//  synchronous: it takes items and returns bytes, so it can be tested without a
//  store, a network, or a share sheet.
//

import Foundation

// MARK: - LibraryExport

enum LibraryExport {

    /// One exported title. Field names are the app's own vocabulary rather than
    /// the server's, because this file is for a person, not for a re-import.
    struct Entry: Codable, Equatable {
        let title: String
        let year: Int
        let type: String
        let status: String
        let sentiment: String?
        let score: Double?
        let rankInBucket: Int?
        let review: String?
        let dateAdded: Date
        let dateWatched: Date?
        let externalId: String?
        let published: Bool

        init(_ item: MediaItem) {
            title = item.title
            year = item.year
            type = item.type.rawValue
            status = item.watchedStatus.rawValue
            sentiment = item.sentiment?.rawValue
            score = item.score
            rankInBucket = item.rankInBucket
            review = item.review
            dateAdded = item.dateAdded
            dateWatched = item.dateWatched
            externalId = item.externalId
            // A title with no external id was never publishable, so it can only
            // ever have lived on this device.
            published = item.externalId != nil && item.watchedStatus == .watched
        }
    }

    struct Document: Codable, Equatable {
        let exportedAt: Date
        let itemCount: Int
        let items: [Entry]

        /// How many titles exist only on this device. Stated explicitly so the
        /// distinction between "my account" and "my data" is visible in the
        /// export itself, not only in a settings screen.
        let localOnlyCount: Int
    }

    /// Builds the document. Sorted by title so two exports of an unchanged
    /// library are byte-identical and a diff means something.
    static func document(for items: [MediaItem], now: Date = .now) -> Document {
        let entries = items
            .map(Entry.init)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return Document(
            exportedAt: now,
            itemCount: entries.count,
            items: entries,
            localOnlyCount: entries.filter { !$0.published }.count
        )
    }

    static func json(for items: [MediaItem], now: Date = .now) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document(for: items, now: now))
    }

    /// Writes the export to a temporary file and returns its URL, for a share
    /// sheet. Named with the date so a user with several exports can tell them
    /// apart.
    static func writeToTemporaryFile(items: [MediaItem], now: Date = .now) throws -> URL {
        let stamp = ISO8601DateFormatter.string(
            from: now, timeZone: .current, formatOptions: [.withFullDate]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Binged-\(stamp).json")
        try json(for: items, now: now).write(to: url, options: .atomic)
        return url
    }
}
