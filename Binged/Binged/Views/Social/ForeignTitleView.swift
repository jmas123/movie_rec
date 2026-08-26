//
//  ForeignTitleView.swift
//  Binged
//
//  A title tapped on somebody else's ranking, resolved into something the
//  ordinary detail screen can show.
//
//  A `TitleReference` is what a social surface knows about a title: an id, a
//  name, a year, maybe a poster path. It has no overview, no genres, and —
//  critically — it is not the viewer's `MediaItem`. Pushing it straight into
//  `MediaDetailView` is impossible, and faking a `MediaItem` from it when the
//  viewer *already has* that title would show a stranger's row in place of
//  their own ranked one.
//
//  It takes a reference rather than a `RankedItem` so the feed can reach it
//  too: a post carries no sentiment, score or bucket size, and inventing them
//  to satisfy this screen's parameter would mean rendering numbers nobody
//  published. See `TitleReference`.
//
//  So resolution goes in three steps, cheapest first: the viewer's own library,
//  then the catalog, then a husk carrying just the id. The husk is a real
//  fallback rather than an error state — the id is right, so acting on it still
//  writes the correct row.
//

import SwiftUI

// MARK: - ForeignTitleView

struct ForeignTitleView: View {

    let reference: TitleReference
    let catalog: MediaService?

    @Environment(MediaLibraryViewModel.self) private var library

    @State private var resolved: MediaItem?

    var body: some View {
        Group {
            if let resolved {
                MediaDetailView(item: resolved)
            } else {
                ProgressView()
                    .accessibilityLabel("Loading \(reference.title)")
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        guard resolved == nil else { return }

        let husk = MediaItem(
            externalId: reference.externalId,
            title: reference.title,
            year: reference.year,
            type: reference.mediaType,
            // Carried through so the husk is not artless while the catalog
            // fetch runs — the pushing surface already had this.
            posterURL: TMDBImage.posterURL(path: reference.posterPath)
        )

        // Already in the library: that copy is the one to show, because it
        // carries the viewer's own sentiment, score and review.
        let owned = library.canonicalItem(for: husk)
        if owned.modelContext != nil {
            resolved = owned
            return
        }

        if let fetched = try? await catalog?.fetch(id: reference.externalId) {
            resolved = library.canonicalItem(for: fetched)
        } else {
            resolved = husk
        }
    }
}
