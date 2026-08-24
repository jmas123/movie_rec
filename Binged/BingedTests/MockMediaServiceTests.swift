//
//  MockMediaServiceTests.swift
//  BingedTests
//
//  Exercises the bundle-backed `MockMediaService`:
//    1. the seed JSON loads from the host-app bundle
//    2. case-insensitive substring search across title and overview
//    3. empty / whitespace / no-match queries return an empty list
//    4. `fetch(id:)` resolves known ids and returns nil for unknown ones
//    5. every call mints fresh, un-shared `MediaItem` instances
//
//  Tests are app-hosted (TEST_HOST = Binged.app), so `Bundle.main` is the
//  host bundle that carries `MockMedia.json`. Each service is built with a
//  zero artificial delay so the suite stays fast and the latency assertion is
//  meaningful.
//

import Foundation
import Testing
@testable import Binged

// MARK: - MockMediaServiceTests

@Suite("MockMediaService")
struct MockMediaServiceTests {

    /// A service wired to the real seed JSON with the UI delay stripped out.
    private func makeService() -> MockMediaService {
        MockMediaService(artificialDelay: .zero)
    }

    // MARK: Loading

    @Test("Seed JSON loads from the bundle and is searchable")
    func bundleLoads() async throws {
        let service = makeService()
        // A title we know is in the catalog proves the JSON decoded.
        let results = try await service.search(query: "Inception")
        #expect(!results.isEmpty)
    }

    @Test("Missing resource throws rather than returning empty results")
    func missingResourceThrows() async {
        let service = MockMediaService(resourceName: "DoesNotExist", artificialDelay: .zero)
        await #expect(throws: MockMediaService.LoadError.self) {
            _ = try await service.search(query: "anything")
        }
    }

    // MARK: Search — matching

    @Test("Search is case-insensitive on title")
    func caseInsensitiveTitleSearch() async throws {
        let service = makeService()
        let results = try await service.search(query: "iNcEpTiOn")
        #expect(results.count == 1)
        #expect(results.first?.externalId == "imdb:tt1375666")
        #expect(results.first?.title == "Inception")
    }

    @Test("Search matches the overview, not just the title")
    func overviewSubstringSearch() async throws {
        let service = makeService()
        // "facebook" appears only in The Social Network's overview, never in a title.
        let results = try await service.search(query: "facebook")
        #expect(results.count == 1)
        #expect(results.first?.title == "The Social Network")
    }

    @Test("A common substring returns many titles")
    func commonSubstringSearch() async throws {
        let service = makeService()
        let results = try await service.search(query: "the")
        #expect(results.count > 1)
    }

    // MARK: Search — empty results

    @Test(
        "Empty and whitespace-only queries return no results",
        arguments: ["", "   ", "\n\t"]
    )
    func emptyQueryReturnsEmpty(_ query: String) async throws {
        let service = makeService()
        let results = try await service.search(query: query)
        #expect(results.isEmpty)
    }

    @Test("A query matching nothing returns an empty list")
    func noMatchReturnsEmpty() async throws {
        let service = makeService()
        let results = try await service.search(query: "zzzznotarealtitle")
        #expect(results.isEmpty)
    }

    // MARK: fetch(id:)

    @Test("fetch resolves a known external id")
    func fetchKnownId() async throws {
        let service = makeService()
        let item = try await service.fetch(id: "imdb:tt0903747")
        #expect(item?.title == "Breaking Bad")
        #expect(item?.type == .tvShow)
    }

    @Test("fetch returns nil for an unknown id")
    func fetchUnknownId() async throws {
        let service = makeService()
        let item = try await service.fetch(id: "tt-does-not-exist")
        #expect(item == nil)
    }

    // MARK: Instance freshness

    @Test("Each call mints fresh MediaItem instances")
    func mintsFreshInstances() async throws {
        let service = makeService()
        let first = try await service.search(query: "Inception")
        let second = try await service.search(query: "Inception")
        let a = try #require(first.first)
        let b = try #require(second.first)
        // Same catalog entry, but distinct objects so callers can attach each
        // to its own ModelContext without a "model already inserted" conflict.
        #expect(a !== b)
        #expect(a.externalId == b.externalId)
    }

    // MARK: Performance

    @Test("Search over the in-memory catalog is fast")
    func searchIsFast() async throws {
        let service = makeService()
        // Warm the lazy decode so we time the search, not the one-time load.
        _ = try await service.search(query: "the")

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await service.search(query: "the")
        }
        #expect(elapsed < .milliseconds(50))
    }

    // MARK: Protocol contract

    @Test("MockMediaService satisfies the MediaService contract")
    func mockSatisfiesContract() async throws {
        try await verifyMediaServiceContract(
            makeService(),
            matchingQuery: "Inception",
            knownExternalId: "imdb:tt1375666"
        )
    }
}

// MARK: - MediaServiceContractTests

/// The contract every `MediaService` owes its callers, checked against each
/// conformer rather than against one concrete class.
///
/// CLAUDE.md commits to swapping in a TMDB-backed service behind this protocol
/// as a single-class replacement. Nothing was guarding that seam: a new
/// conformer could satisfy the two signatures and still hand back items already
/// attached to a `ModelContext`, or throw on an unknown id instead of returning
/// nil, and every existing test would stay green. Adding the TMDB class here
/// costs one line.
@Suite("MediaService contract")
struct MediaServiceContractTests {

    @Test("MockMediaService")
    func mockService() async throws {
        try await verifyMediaServiceContract(
            MockMediaService(artificialDelay: .zero),
            matchingQuery: "Inception",
            knownExternalId: "imdb:tt1375666"
        )
    }

    @Test("StubMediaService")
    func stubService() async throws {
        try await verifyMediaServiceContract(
            StubMediaService(),
            matchingQuery: "Inception",
            knownExternalId: "1"
        )
    }
}
