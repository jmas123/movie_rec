//
//  RankingFeedServiceKey.swift
//  Binged
//
//  Puts other people's rankings in the environment, for the same reason
//  `MediaServiceKey` puts the catalog there.
//
//  `MediaDetailView` is reached from Home, Search, Discover, Ranking, the
//  watchlist and now a friend's profile. Threading a `RankingFeedService`
//  through every one of those call sites would hand the service to screens with
//  no use for it — the watchlist does not care who else watched anything —
//  purely so it could be passed on again.
//
//  **The default is nil, not a mock.** `MediaServiceKey` can default to the
//  bundled catalog because reading a file in the bundle is always safe and
//  always truthful. There is no equivalent here: a stub graph would invent
//  friends who do not exist, and inventing social proof is a worse failure than
//  showing none. A build with no server, or a preview, simply has no section.
//

import SwiftUI

// MARK: - RankingFeedServiceKey

struct RankingFeedServiceKey: EnvironmentKey {
    static let defaultValue: RankingFeedService? = nil
}

// MARK: - EnvironmentValues

extension EnvironmentValues {

    var rankingFeedService: RankingFeedService? {
        get { self[RankingFeedServiceKey.self] }
        set { self[RankingFeedServiceKey.self] = newValue }
    }
}
