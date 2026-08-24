//
//  AccountLifecycleTests.swift
//  WatchRankTests
//
//  Deletion and export. The rule underneath both: **your account and your data
//  are different things**, and an action on one must not quietly consume the
//  other.
//

import Foundation
import SwiftData
import Testing
@testable import WatchRank

// MARK: - Deletion

@Suite("Account deletion")
@MainActor
struct AccountDeletionTests {

    @Test("Deleting the account leaves the local library intact and usable")
    func localLibrarySurvives() async throws {
        // App Store 5.1.1(v) asks for in-app deletion; it does not ask for the
        // user's own device data to go with it. Wiping the library would be a
        // second deletion nobody requested.
        let library = try makeRankedLibrary(movies: 8, shows: 2)
        let auth = MockAuthService()
        let session = SessionViewModel(service: auth)

        await session.signUp(email: "a@b.test", password: "longenough", handle: "someone")
        #expect(session.isSignedIn)

        let before = library.allWatched.count
        await session.deleteAccount()

        #expect(!session.isSignedIn)
        #expect(session.state == .signedOut)
        #expect(library.allWatched.count == before, "deleting the account ate the library")
        #expect(library.bucket(for: .liked, type: .movie).allSatisfy { $0.score != nil })
    }

    @Test("A deleted account's handle is released")
    func handleIsFreed() async throws {
        let auth = MockAuthService()
        _ = try await auth.signUp(email: "a@b.test", password: "longenough", handle: "reclaimed")
        #expect(await auth.isHandleAvailable("reclaimed") == false)

        try await auth.deleteAccount()
        #expect(await auth.isHandleAvailable("reclaimed") == true)
    }

    @Test("Ranking still works after deleting the account")
    func appIsWholeAfterDeletion() async throws {
        // The app was whole before an account existed; it must be whole again
        // afterwards.
        let library = try makeLibrary()
        let session = SessionViewModel(service: MockAuthService())
        await session.signUp(email: "a@b.test", password: "longenough", handle: "gone")
        await session.deleteAccount()

        let item = MediaItem(title: "After", year: 2024, type: .movie)
        library.markWatched(item, sentiment: .liked)
        library.finalizeRanking(for: item)

        #expect(item.score != nil)
        #expect(library.bucket(for: .liked, type: .movie).count == 1)
    }
}

// MARK: - Export

@Suite("Data export")
@MainActor
struct LibraryExportTests {

    @Test("The export contains every title, published or not")
    func exportIsComplete() throws {
        let library = try makeLibrary()
        let published = MediaItem(externalId: "tmdb:movie:1", title: "Published",
                                  year: 2020, type: .movie)
        library.markWatched(published, sentiment: .liked)
        library.finalizeRanking(for: published)

        let local = MediaItem(title: "Local only", year: 2020, type: .movie)
        library.markWatched(local, sentiment: .liked)
        driveSessionPreferringExisting(vm: library)
        library.finalizeRanking(for: local)

        let document = LibraryExport.document(for: library.allItems)

        #expect(document.itemCount == 2)
        #expect(document.items.map(\.title).sorted() == ["Local only", "Published"])
        #expect(document.localOnlyCount == 1, "the local/published split was not stated")
    }

    @Test("Two exports of an unchanged library are byte-identical")
    func exportIsDeterministic() throws {
        // A diff between two exports should mean something changed, not that a
        // dictionary iterated differently.
        let library = try makeRankedLibrary(movies: 6, shows: 3)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try LibraryExport.json(for: library.allItems, now: now)
        let second = try LibraryExport.json(for: library.allItems, now: now)

        #expect(first == second)
    }

    @Test("Scores and reviews survive the round trip")
    func exportPreservesTheInterestingParts() throws {
        let library = try makeLibrary()
        let item = MediaItem(externalId: "tmdb:movie:7", title: "Reviewed", year: 2020, type: .movie)
        library.markWatched(item, sentiment: .liked)
        library.finalizeRanking(for: item)
        library.updateReview(item, to: "Loved it")

        let document = LibraryExport.document(for: library.allItems)
        let entry = try #require(document.items.first)

        #expect(entry.score != nil)
        #expect(entry.sentiment == "liked")
        #expect(entry.review == "Loved it")
        #expect(entry.rankInBucket == 0)
    }

    @Test("An empty library exports an empty document, not a failure")
    func emptyExport() throws {
        let library = try makeLibrary()
        let document = LibraryExport.document(for: library.allItems)

        #expect(document.itemCount == 0)
        #expect(document.items.isEmpty)
        #expect(document.localOnlyCount == 0)
    }

    @Test("The export writes a readable file")
    func writesAFile() throws {
        let library = try makeRankedLibrary(movies: 3, shows: 1)
        let url = try LibraryExport.writeToTemporaryFile(items: library.allItems)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        #expect(!data.isEmpty)
        #expect(url.lastPathComponent.hasPrefix("WatchRank-"))
        #expect(url.pathExtension == "json")

        // Readable by something other than this app.
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["itemCount"] as? Int == 4)
    }
}

// MARK: - Safety surface

@Suite("Safety obligations")
struct SafetySurfaceTests {

    @Test("Every report reason is offered and named")
    func reasonsAreComplete() {
        // Guideline 1.2 wants a way to report objectionable content. A single
        // "report" with no reason is not actionable.
        let expected: Set<ReportReason> = [.spam, .harassment, .hateSpeech,
                                           .sexualContent, .violence, .other]
        #expect(Set(ReportReason.allCases) == expected)
    }

    @Test("Reporting covers posts, comments and profiles")
    func everySurfaceIsReportable() {
        // Content appears in three places, so a report has to be possible in
        // three places.
        let targets: [ReportTarget] = [.post(UUID()), .comment(UUID()), .profile(UUID())]
        #expect(Set(targets.map(\.column)) == ["post_id", "comment_id", "profile_id"])
    }
}
