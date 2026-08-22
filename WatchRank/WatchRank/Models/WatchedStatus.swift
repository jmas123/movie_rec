//
//  WatchedStatus.swift
//  WatchRank
//

import Foundation

// MARK: - WatchedStatus

/// Where a `MediaItem` sits in the user's library: already watched and ranked,
/// queued to watch later, or merely surfaced from search without any user action.
enum WatchedStatus: String, Codable, CaseIterable, Identifiable {
    case watched
    case wantToWatch
    case untracked

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .watched:     return "Watched"
        case .wantToWatch: return "Want to Watch"
        case .untracked:   return "Untracked"
        }
    }
}
