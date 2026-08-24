//
//  MediaType.swift
//  Binged
//

import Foundation

// MARK: - MediaType

/// The kind of title a `MediaItem` represents. Drives filtering on the
/// Ranking and Home screens (Movies / TV Shows tabs).
enum MediaType: String, Codable, CaseIterable, Identifiable {
    case movie
    case tvShow

    var id: String { rawValue }

    /// Human-readable label for UI surfaces.
    var displayName: String {
        switch self {
        case .movie:  return "Movie"
        case .tvShow: return "TV Show"
        }
    }

    // MARK: - Wire representation

    /// The label used by the Postgres `public.media_type` enum.
    ///
    /// `rawValue` stays `tvShow` and `wireValue` is `tv_show`, which looks like
    /// a wart and is deliberate. SwiftData persists this enum *by raw value*, so
    /// renaming the case to match the server would be a store migration for a
    /// spelling; and the schema is snake_case for every other identifier, so
    /// bending it to Swift's camelCase would be worse. The translation belongs
    /// at the boundary, alongside the column-name translation every DTO in
    /// `Services/` already does.
    var wireValue: String {
        switch self {
        case .movie:  return "movie"
        case .tvShow: return "tv_show"
        }
    }

    /// Encodes the wire form, so anything JSON-encoded is server-shaped by
    /// default. Nothing persists this enum through `Codable` — SwiftData uses
    /// the raw value — so this affects the network only.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }

    /// Accepts either spelling.
    ///
    /// The server sends `tv_show`; `MockMedia.json` and anything written by an
    /// older build send `tvShow`. A decoder that took only one of them would
    /// fail on real data from the other, and both are real.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = MediaType(wireValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unrecognised media type “\(raw)”")
            )
        }
        self = value
    }

    /// The same parse, without a decoder — for callers that want to *skip* an
    /// unrecognised value rather than fail. Restoring a library is the case:
    /// one row written by a newer build must not cost the user the other
    /// nine hundred.
    init?(wireValue raw: String) {
        switch raw {
        case "movie":             self = .movie
        case "tv_show", "tvShow": self = .tvShow
        default:                  return nil
        }
    }
}
