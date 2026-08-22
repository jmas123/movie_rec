//
//  PersistenceTests.swift
//  WatchRankTests
//
//  Every other suite asserts against the same `ModelContext` it wrote to, which
//  proves the view model mutated some objects in memory — not that anything was
//  stored. `MediaLibraryViewModel.save()` swallows its error (`try?`) and bumps
//  `revision` either way, so from inside those tests a total persistence failure
//  is indistinguishable from success.
//
//  These tests close that gap: write through one library, then build a second
//  library over a **fresh `ModelContext` on the same container** and assert what
//  came back. WatchRank is a local-only app; the store is the product.
//

import Foundation
import SwiftData
import Testing
@testable import WatchRank

@MainActor
@Suite("Persistence")
struct PersistenceTests {

    // MARK: - Ranking survives

    @Test("An item ranked into an empty bucket is stored complete")
    func emptyBucketPlacementSurvives() throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)

        let solo = makeItem("Solo", externalId: "tt1")
        library.markWatched(solo, sentiment: .liked)

        let stored = try #require(try refetch(solo, in: container), "the item never reached the store")
        #expect(stored.watchedStatus == .watched)
        #expect(stored.sentiment == .liked)
        #expect(stored.rankInBucket == 0)
        #expect(stored.dateWatched != nil)

        let range = Sentiment.liked.scoreRange
        #expect(stored.score == (range.lowerBound + range.upperBound) / 2.0)
    }

    @Test("A finished comparison session stores the whole bucket")
    func finalizedBucketSurvives() throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)

        seedLikedBucket(vm: library, count: 3)
        let candidate = makeItem("Candidate")
        library.markWatched(candidate, sentiment: .liked)
        driveSessionPreferringNew(vm: library) // float it to the top
        library.finalizeRanking(for: candidate)

        // Read the bucket back through a library that shares nothing but the store.
        let reopened = makeLibrary(in: container)
        let bucket = reopened.bucket(for: .liked, type: .movie)
        expectBucketWellFormed(bucket, sentiment: .liked, count: 4)
        #expect(bucket.first?.title == "Candidate", "the earned position was not stored")
    }

    @Test("An abandoned comparison session still stores a usable score")
    func abandonedSessionSurvivesWithAScore() throws {
        // The session itself is in-memory by design and dies with the process.
        // What must not die with it is the item's rankability.
        let container = try makeContainer()
        let library = makeLibrary(in: container)

        seedLikedBucket(vm: library, count: 3)
        let abandoned = makeItem("Abandoned")
        library.markWatched(abandoned, sentiment: .liked)
        // No comparisons answered, no finalize — simulate the app dying here.

        let reopened = makeLibrary(in: container)
        expectNoStrandedItems(reopened)
        expectBucketWellFormed(reopened.bucket(for: .liked, type: .movie), sentiment: .liked, count: 4)
    }

    // MARK: - Demotion and re-rating survive

    @Test("Demoting to Want to Watch stores the cleared state and the fixed bucket")
    func demotionSurvives() throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)

        let liked = seedLikedBucket(vm: library, count: 3)
        library.addToWantToWatch(liked[1])

        let reopened = makeLibrary(in: container)
        let stored = try #require(try refetch(liked[1], in: container))
        #expect(stored.watchedStatus == .wantToWatch)
        #expect(stored.sentiment == nil)
        #expect(stored.score == nil)
        #expect(stored.rankInBucket == nil)

        expectBucketWellFormed(reopened.bucket(for: .liked, type: .movie), sentiment: .liked, count: 2)
    }

    @Test("Re-rating across buckets stores both buckets correctly")
    func reRatingSurvives() throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)

        let liked = seedLikedBucket(vm: library, count: 3)
        seedBucket(vm: library, sentiment: .fine, count: 2, titlePrefix: "Fine")

        let mover = liked[1]
        library.markWatched(mover, sentiment: .fine)
        driveSessionPreferringExisting(vm: library)
        library.finalizeRanking(for: mover)

        let reopened = makeLibrary(in: container)
        expectBucketWellFormed(reopened.bucket(for: .liked, type: .movie), sentiment: .liked, count: 2)
        expectBucketWellFormed(reopened.bucket(for: .fine, type: .movie), sentiment: .fine, count: 3)
        expectNoStrandedItems(reopened)
    }

    // MARK: - Reorder and review survive

    @Test("A drag-reorder is stored, not just applied in memory")
    func reorderSurvives() throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)

        let seeded = seedLikedBucket(vm: library, count: 4)
        let topID = library.bucket(for: .liked, type: .movie)[0].id
        library.reorder(in: .liked, type: .movie, from: IndexSet(integer: 0), to: 4)

        let reopened = makeLibrary(in: container)
        let bucket = reopened.bucket(for: .liked, type: .movie)
        expectBucketWellFormed(bucket, sentiment: .liked, count: 4)
        #expect(bucket.last?.id == topID, "the new ordering did not reach the store")
        #expect(seeded.count == 4)
    }

    @Test("A review is stored, and clearing it stores the nil")
    func reviewSurvives() throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)

        let item = makeItem("Reviewed")
        library.markWatched(item, sentiment: .liked)

        library.updateReview(item, to: "  Loved it.  ")
        #expect(try refetch(item, in: container)?.review == "Loved it.")

        // Clearing has to persist as an actual nil — a whitespace string left in
        // the store would render as an empty review section forever.
        library.updateReview(item, to: "   ")
        #expect(try refetch(item, in: container)?.review == nil)
    }

    @Test("Queueing an item stores it as want-to-watch")
    func wantToWatchSurvives() throws {
        let container = try makeContainer()
        let library = makeLibrary(in: container)

        let item = makeItem("Queued")
        library.addToWantToWatch(item)

        let reopened = makeLibrary(in: container)
        #expect(reopened.wantToWatch.contains { $0.id == item.id })
        #expect(try refetch(item, in: container)?.dateAdded != nil)
    }

    // MARK: - Model shape

    @Test("Every field of MediaItem round-trips unchanged")
    func mediaItemRoundTrips() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let watched = Date(timeIntervalSince1970: 1_700_000_000)
        let added = Date(timeIntervalSince1970: 1_600_000_000)
        let original = MediaItem(
            externalId: "tt0111161",
            title: "The Shawshank Redemption",
            year: 1994,
            type: .movie,
            overview: "Two imprisoned men bond over a number of years.",
            posterURL: "https://example.invalid/poster.jpg",
            genres: ["Drama", "Crime"],
            watchedStatus: .watched,
            sentiment: .liked,
            score: 9.4,
            rankInBucket: 2,
            review: "Still holds up.",
            dateAdded: added,
            dateWatched: watched
        )
        context.insert(original)
        try context.save()

        let stored = try #require(try refetch(original, in: container))
        #expect(stored.externalId == "tt0111161")
        #expect(stored.title == "The Shawshank Redemption")
        #expect(stored.year == 1994)
        #expect(stored.type == .movie)
        #expect(stored.overview == original.overview)
        #expect(stored.posterURL == "https://example.invalid/poster.jpg")
        #expect(stored.genres == ["Drama", "Crime"])
        #expect(stored.watchedStatus == .watched)
        #expect(stored.sentiment == .liked)
        #expect(stored.score == 9.4)
        #expect(stored.rankInBucket == 2)
        #expect(stored.review == "Still holds up.")
        #expect(stored.dateAdded == added)
        #expect(stored.dateWatched == watched)
    }

    @Test("A default-initialised MediaItem stores its documented defaults")
    func mediaItemDefaultsRoundTrip() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let bare = MediaItem(title: "Bare", year: 2024, type: .tvShow)
        context.insert(bare)
        try context.save()

        let stored = try #require(try refetch(bare, in: container))
        #expect(stored.externalId == nil)
        #expect(stored.overview == "")
        #expect(stored.posterURL == nil)
        #expect(stored.genres.isEmpty)
        #expect(stored.watchedStatus == .untracked)
        #expect(stored.sentiment == nil)
        #expect(stored.score == nil)
        #expect(stored.rankInBucket == nil)
        #expect(stored.review == nil)
        #expect(stored.dateWatched == nil)
    }

    @Test(
        "Every persisted enum case round-trips",
        arguments: Sentiment.allCases
    )
    func sentimentCasesRoundTrip(sentiment: Sentiment) throws {
        // These enums are `String`-backed and stored. Renaming a case silently
        // orphans every row already written, and CLAUDE.md deliberately declines
        // to write a migration plan — so the raw values are load-bearing.
        let container = try makeContainer()
        let context = ModelContext(container)

        let item = MediaItem(title: "Case", year: 2024, type: .movie, sentiment: sentiment)
        context.insert(item)
        try context.save()

        #expect(try refetch(item, in: container)?.sentiment == sentiment)
    }

    @Test("Persisted enum raw values are exactly what the store already holds")
    func enumRawValuesAreStable() {
        #expect(Sentiment.liked.rawValue == "liked")
        #expect(Sentiment.fine.rawValue == "fine")
        #expect(Sentiment.disliked.rawValue == "disliked")

        #expect(MediaType.movie.rawValue == "movie")
        #expect(MediaType.tvShow.rawValue == "tvShow")

        #expect(WatchedStatus.watched.rawValue == "watched")
        #expect(WatchedStatus.wantToWatch.rawValue == "wantToWatch")
        #expect(WatchedStatus.untracked.rawValue == "untracked")
    }

    @Test(
        "Every MediaType and WatchedStatus case round-trips",
        arguments: MediaType.allCases, WatchedStatus.allCases
    )
    func typeAndStatusRoundTrip(type: MediaType, status: WatchedStatus) throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let item = MediaItem(title: "Case", year: 2024, type: type, watchedStatus: status)
        context.insert(item)
        try context.save()

        let stored = try #require(try refetch(item, in: container))
        #expect(stored.type == type)
        #expect(stored.watchedStatus == status)
    }

    // MARK: - Multiple libraries over one store

    @Test("A second library sees everything the first one wrote")
    func librariesShareTheStore() throws {
        let container = try makeContainer()
        let first = makeLibrary(in: container)

        seedBucket(vm: first, sentiment: .liked, count: 2, titlePrefix: "Liked")
        seedBucket(vm: first, sentiment: .disliked, count: 3, titlePrefix: "Disliked")
        first.addToWantToWatch(makeItem("Queued"))

        let second = makeLibrary(in: container)
        #expect(second.allWatched.count == 5)
        #expect(second.wantToWatch.count == 1)
        #expect(second.bucket(for: .liked, type: .movie).count == 2)
        #expect(second.bucket(for: .disliked, type: .movie).count == 3)
        #expect(second.bucket(for: .fine, type: .movie).isEmpty)
        #expect(try fetchAll(in: container).count == 6)
    }
}
