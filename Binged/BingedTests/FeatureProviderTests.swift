//
//  FeatureProviderTests.swift
//  BingedTests
//
//  The launch backfill. Previously had no test file at all, despite running on
//  every launch and writing to the store.
//
//  The poster cases are the reason this file exists. Artwork was fetched,
//  stored on new items, and displayed on exactly one screen — but nothing ever
//  filled it in for rows that already existed, so a library built before the
//  live catalogue (or before artwork was displayed anywhere) drew a gradient
//  for every title, permanently, with no way for the user to fix it.
//

import Foundation
import SwiftData
import Testing
@testable import Binged

// MARK: - Stub

private final class StubFeatureSource: FeatureSource, @unchecked Sendable {
    private let lock = NSLock()
    var keys: [String] = ["genre:drama"]
    var voteAverage: Double? = 7.5
    var posterURL: String? = "https://image.tmdb.org/t/p/w500/poster.jpg"
    private(set) var requests: [Int] = []

    func features(type: MediaType, tmdbId: Int) async -> TMDBMediaService.ExtractedFeatures? {
        lock.lock(); requests.append(tmdbId); lock.unlock()
        return .init(keys: keys, voteAverage: voteAverage, posterURL: posterURL)
    }
}

// MARK: - Tests

@Suite("Feature backfill")
@MainActor
struct FeatureProviderTests {

    private func item(_ title: String, tmdbId: Int) -> MediaItem {
        makeItem(title, externalId: "tmdb:movie:\(tmdbId)")
    }

    @Test("A title with no artwork gets some, even when its features are already there")
    func backfillsPosterForAnEnrichedItem() async throws {
        // The bug. The work list was `features.isEmpty`, so any title enriched
        // before artwork existed was never revisited and kept a nil posterURL.
        let container = try makeContainer()
        let context = ModelContext(container)
        let stored = item("Dune", tmdbId: 438631)
        stored.features = ["genre:sci-fi"]
        stored.posterURL = nil
        context.insert(stored)

        let source = StubFeatureSource()
        let enriched = await FeatureProvider(source: source, modelContext: context)
            .backfill(items: [stored])

        #expect(enriched == 1)
        #expect(stored.posterURL == "https://image.tmdb.org/t/p/w500/poster.jpg")
        // Features it already had are not clobbered.
        #expect(stored.features == ["genre:sci-fi"])
    }

    @Test("A title that already has artwork is left alone")
    func doesNotRefetchASatisfiedItem() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let stored = item("Dune", tmdbId: 438631)
        stored.features = ["genre:sci-fi"]
        stored.posterURL = "https://image.tmdb.org/t/p/w500/existing.jpg"
        context.insert(stored)

        let source = StubFeatureSource()
        _ = await FeatureProvider(source: source, modelContext: context)
            .backfill(items: [stored])

        #expect(source.requests.isEmpty)
        #expect(stored.posterURL == "https://image.tmdb.org/t/p/w500/existing.jpg")
    }

    @Test("Existing artwork is never overwritten by a response that has none")
    func nilPosterDoesNotClobber() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let stored = item("Dune", tmdbId: 438631)
        stored.posterURL = "https://image.tmdb.org/t/p/w500/existing.jpg"
        context.insert(stored)

        let source = StubFeatureSource()
        source.posterURL = nil
        _ = await FeatureProvider(source: source, modelContext: context)
            .backfill(items: [stored])

        #expect(stored.posterURL == "https://image.tmdb.org/t/p/w500/existing.jpg")
    }

    @Test("Artwork lands even when the title has no features to speak of")
    func posterIsNotGatedOnFeatures() async throws {
        // Assignment used to sit behind `!result.keys.isEmpty`, so a title
        // whose features came back empty kept its gradient even though the
        // same response carried a poster.
        let container = try makeContainer()
        let context = ModelContext(container)
        let stored = item("Obscure Film", tmdbId: 999)
        context.insert(stored)

        let source = StubFeatureSource()
        source.keys = []
        let enriched = await FeatureProvider(source: source, modelContext: context)
            .backfill(items: [stored])

        #expect(enriched == 1)
        #expect(stored.posterURL == "https://image.tmdb.org/t/p/w500/poster.jpg")
    }

    @Test("An item with no external id is skipped rather than requested")
    func skipsItemsWithoutAnId() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let stored = makeItem("Hand-made", externalId: nil)
        context.insert(stored)

        let source = StubFeatureSource()
        let enriched = await FeatureProvider(source: source, modelContext: context)
            .backfill(items: [stored])

        #expect(enriched == 0)
        #expect(source.requests.isEmpty)
    }
}
