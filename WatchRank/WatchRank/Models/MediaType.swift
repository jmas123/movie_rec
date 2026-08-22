//
//  MediaType.swift
//  WatchRank
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
}
