//
//  TitleReference.swift
//  Binged
//
//  A pointer to a title on somebody else's screen, and the value a social
//  surface pushes when it is tapped.
//
//  **Why this is not `RankedItem`.** A ranked row and a feed post both name a
//  title, but they carry different things around it — a row carries a position
//  and a score, a post carries a sentence and a timestamp — and neither can be
//  built from the other without inventing the difference. Pushing a `RankedItem`
//  from the feed would mean fabricating a `sentiment`, a `score` and a
//  `bucketSize` the post never had, and the destination would then be rendering
//  numbers nobody published.
//
//  So the navigation value is the intersection: the four fields that *identify*
//  a title, which is all `ForeignTitleView` ever reads. Both sides project into
//  it, one destination is registered per stack, and neither caller has to know
//  what opening a title means here.
//

import Foundation

// MARK: - TitleReference

/// `Hashable` because it is a `NavigationLink` value.
struct TitleReference: Hashable, Sendable {

    /// The catalog id. The load-bearing field — everything else is only there
    /// so the screen has something to draw before the fetch lands.
    let externalId: String

    let title: String
    let year: Int
    let mediaType: MediaType

    /// TMDB's `/abc.jpg`, when the surface that pushed this had one. Lets the
    /// destination show the right artwork immediately instead of a gradient
    /// that swaps to a poster a moment later.
    var posterPath: String?
}

// MARK: - Projections

extension RankedItem {

    var reference: TitleReference {
        TitleReference(
            externalId: externalId,
            title: title,
            year: year,
            mediaType: mediaType,
            posterPath: posterPath
        )
    }
}

extension FeedPost.Payload {

    var reference: TitleReference {
        TitleReference(
            externalId: externalId,
            title: title,
            year: year,
            mediaType: mediaType,
            posterPath: posterPath
        )
    }
}
