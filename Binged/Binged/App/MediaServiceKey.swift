//
//  MediaServiceKey.swift
//  Binged
//
//  Puts the catalog in the environment, so a screen pushed from five different
//  places can ask it a question.
//
//  `MediaDetailView` is reached from Home, Search, Discover, Ranking and the
//  watchlist. Threading a `MediaService` through every one of those call sites
//  would mean handing the service to screens that have no use for it — the
//  Ranking tab does not talk to the catalog — purely so it could be passed on
//  again. The library view model already travels this way for the same reason.
//
//  It is an `EnvironmentKey` rather than `.environment(service)` because
//  `MediaService` is a protocol, and the `@Observable` overload takes a
//  concrete observable type.
//

import SwiftUI

// MARK: - MediaServiceKey

struct MediaServiceKey: EnvironmentKey {

    /// The bundled catalog. A default is required by `EnvironmentKey`, and this
    /// is the one that is always safe: it reads a file in the bundle, never the
    /// network, so a preview or a screen rendered outside the app's composition
    /// root degrades to "no extra detail" rather than to a crash or a request
    /// nobody authorised.
    static let defaultValue: MediaService = MockMediaService()
}

// MARK: - EnvironmentValues

extension EnvironmentValues {

    var mediaService: MediaService {
        get { self[MediaServiceKey.self] }
        set { self[MediaServiceKey.self] = newValue }
    }
}
