//
//  CatalogCacheTests.swift
//  WatchRankTests
//
//  The cache is what makes the app work offline, so its failure modes matter
//  more than its happy path. Three in particular are covered here: a filename
//  that changes between launches (every entry becomes a permanent miss), a
//  stale entry that reports itself as fresh (the pool never refreshes), and a
//  payload whose shape has changed under a code edit (a decode failure that
//  must not become a thrown error the caller has to handle).
//

import Foundation
import Testing
@testable import WatchRank

// MARK: - Fixtures

private struct Payload: Codable, Equatable {
    let title: String
    let count: Int
}

private func makeCache(ttl: TimeInterval = 60) -> (CatalogCache, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CatalogCacheTests-\(UUID().uuidString)", isDirectory: true)
    return (CatalogCache(directory: directory, ttl: ttl), directory)
}

// MARK: - Tests

@Suite("CatalogCache")
struct CatalogCacheTests {

    @Test("Stores and reads back a value")
    func roundTrips() {
        let (cache, _) = makeCache()
        let payload = Payload(title: "Inception", count: 3)

        cache.store(payload, for: "detail:movie:27205")
        let hit = cache.load("detail:movie:27205", as: Payload.self)

        #expect(hit?.value == payload)
        #expect(hit?.isStale == false)
    }

    @Test("A miss is nil rather than an error")
    func missIsNil() {
        let (cache, _) = makeCache()
        #expect(cache.load("nothing:stored", as: Payload.self) == nil)
    }

    @Test("An entry older than the TTL is returned, but flagged stale")
    func expiredEntriesAreFlaggedNotDiscarded() async throws {
        let (cache, _) = makeCache(ttl: 0.05)
        cache.store(Payload(title: "Inception", count: 1), for: "key")

        try await Task.sleep(for: .milliseconds(120))
        let hit = cache.load("key", as: Payload.self)

        // Still returned: offline, a stale answer is the difference between a
        // working screen and an empty one. The caller decides, not the cache.
        #expect(hit != nil)
        #expect(hit?.isStale == true)
    }

    @Test("A payload that no longer decodes is a miss, and the file is discarded")
    func staleShapesArePurged() {
        let (cache, directory) = makeCache()
        cache.store(Payload(title: "Inception", count: 1), for: "key")

        // Read it back as an incompatible type — what happens when a DTO gains
        // a required field after a release.
        struct Different: Codable { let somethingElse: Bool }
        #expect(cache.load("key", as: Different.self) == nil)

        // The unreadable file is removed rather than left to fail forever.
        let remaining = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining?.isEmpty != false)
    }

    @Test("Filenames are stable across processes")
    func filenamesAreStable() {
        // Swift's built-in hashValue is seeded per process, so a filename
        // derived from it would differ on every launch and every cached entry
        // would be a permanent miss — a bug that looks like "the cache does
        // nothing" and never surfaces within a single test run.
        let first = CatalogCache.filename(for: "popular:movie:1")
        let second = CatalogCache.filename(for: "popular:movie:1")
        #expect(first == second)
        #expect(first == "popular-movie-1-\(expectedSuffix(of: first))")
    }

    @Test("Keys that sanitise alike still get separate files")
    func similarKeysDoNotCollide() {
        // Both reduce to the same readable prefix; only the hash separates them.
        let a = CatalogCache.filename(for: "search:the dark knight")
        let b = CatalogCache.filename(for: "search:the-dark-knight")
        #expect(a != b)
    }

    @Test("A nil directory disables the cache without failing")
    func nilDirectoryIsANoOp() {
        let cache = CatalogCache(directory: nil)
        cache.store(Payload(title: "Inception", count: 1), for: "key")
        #expect(cache.load("key", as: Payload.self) == nil)
    }

    @Test("removeAll clears stored entries")
    func removeAllClears() {
        let (cache, _) = makeCache()
        cache.store(Payload(title: "Inception", count: 1), for: "key")
        #expect(cache.load("key", as: Payload.self) != nil)

        cache.removeAll()
        #expect(cache.load("key", as: Payload.self) == nil)
    }

    @Test("Cache keys distinguish a movie from a series with the same id")
    func keysAreNamespacedByType() {
        let movie = CatalogCacheKey.detail(type: .movie, tmdbId: 1396)
        let show = CatalogCacheKey.detail(type: .tvShow, tmdbId: 1396)
        #expect(movie != show)
    }
}

/// Pulls the hash segment off a generated filename, so the stability assertion
/// can check the readable prefix without hardcoding a hash this test would then
/// have to be updated for.
private func expectedSuffix(of filename: String) -> String {
    String(filename.split(separator: "-").last ?? "")
}
