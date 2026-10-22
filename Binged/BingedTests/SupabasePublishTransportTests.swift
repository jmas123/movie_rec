//
//  SupabasePublishTransportTests.swift
//  BingedTests
//
//  The wire shape of publishing, against a hazard a behavioural test cannot
//  see because it is about what the *request* contains.
//
//  **The upsert body may name only columns `authenticated` may UPDATE.** The
//  upsert is a PostgREST `resolution=merge-duplicates`, which becomes
//  `INSERT … ON CONFLICT DO UPDATE SET` over every column sent — and UPDATE on
//  `ranked_items` is granted column by column rather than table-wide
//  (`20260823010000_fix_is_published_privileges.sql`). A column in the payload
//  that is not in that grant inserts a bucket's first row happily and then
//  fails 42501 on every later drain that touches an existing one, which is
//  every drain after the first. The failure needs no client bug and no unusual
//  state; it needs a second ranking.
//
//  Asserted as a subset rather than as an exact list, because that is the shape
//  of the rule: adding a column the grant already covers is fine, and adding one
//  it does not is the bug. `is_published` — the column this test was originally
//  written for — no longer exists at all; visibility is the account's privacy
//  setting now (`20260826020000_visibility_follows_account_privacy.sql`).
//

import Foundation
import Testing
@testable import Binged

// MARK: - Helpers

/// `URLProtocol` hands the body back as a stream, so `httpBody` is nil for
/// anything URLSession has already packaged. Read whichever is present.
private func body(of request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }

    var data = Data()
    let size = 4096
    var buffer = [UInt8](repeating: 0, count: size)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: size)
        if read <= 0 { break }
        data.append(contentsOf: buffer[0..<read])
    }
    return data
}

private func makeItem(_ title: String) -> MediaItem {
    let item = MediaItem(
        externalId: "tmdb:movie:1", title: title, year: 2020, type: .movie
    )
    item.watchedStatus = .watched
    item.sentiment = .liked
    item.rankInBucket = 0
    item.score = 8.4
    return item
}

private func makePayload() -> PublishPayload {
    PublishPayload(mediaType: .movie, sentiment: .liked, bucket: [makeItem("Dune")])
}

// MARK: - Tests

@Suite("SupabasePublishTransport wire shape")
struct SupabasePublishTransportTests {

    /// Every column `20260823010000` grants UPDATE on, by name.
    /// A queued title: watched-status `.wantToWatch`, and so no sentiment,
    /// score or rank.
    private func makeQueuedPayload() -> PublishPayload {
        let item = MediaItem(
            externalId: "tmdb:movie:2", title: "Sinners", year: 2025, type: .movie
        )
        item.watchedStatus = .wantToWatch
        return PublishPayload(mediaType: .movie, sentiment: nil, bucket: [item])
    }

    private static let grantable: Set<String> = [
        "user_id", "media_type", "external_id", "title", "year", "poster_path",
        "sentiment", "score", "rank_in_bucket", "bucket_size", "review",
        "date_watched", "updated_at",
    ]

    @Test("The upsert body names only columns the client may write")
    func upsertNamesOnlyGrantableColumns() async throws {
        let captured = Captured()
        let configuration = makeSupabaseConfiguration()
        let client = makeSupabaseClient(configuration: configuration) { request in
            captured.record(request)
            return .ok(Data())
        }
        let transport = SupabasePublishTransport(client: client, configuration: configuration)

        try await transport.publish(makePayload(), userID: UUID())

        let upsert = try #require(captured.first { $0.method == "POST" })
        let json = try #require(
            try JSONSerialization.jsonObject(with: upsert.body) as? [[String: Any]]
        )
        let row = try #require(json.first)

        let ungranted = Set(row.keys).subtracting(Self.grantable)
        #expect(ungranted.isEmpty, "not granted to `authenticated`; 42501s on upsert: \(ungranted)")
        // And the row is still a row — this is an omission test, not an
        // assertion that the payload may be empty.
        #expect(row["external_id"] as? String == "tmdb:movie:1")
        #expect(row["bucket_size"] as? Int == 1)
    }

    @Test("A queued row sends explicit nulls, not omitted columns")
    func queuedRowSendsNulls() async throws {
        let captured = Captured()
        let configuration = makeSupabaseConfiguration()
        let client = makeSupabaseClient(configuration: configuration) { request in
            captured.record(request)
            return .ok(Data())
        }
        let transport = SupabasePublishTransport(client: client, configuration: configuration)

        try await transport.publish(makeQueuedPayload(), userID: UUID())

        let upsert = try #require(captured.first { $0.method == "POST" })
        let json = try #require(
            try JSONSerialization.jsonObject(with: upsert.body) as? [[String: Any]]
        )
        let row = try #require(json.first)

        // **Present-and-null, not absent.** PostgREST compiles the upsert into
        // ON CONFLICT DO UPDATE SET over the columns in the body, so an omitted
        // column keeps its old server value — a title moved from "Liked it" to
        // the watchlist would keep the ranking it just left. `JSONSerialization`
        // renders an explicit null as `NSNull`, and a missing key as nil, which
        // is exactly the distinction being asserted.
        for column in ["sentiment", "score", "rank_in_bucket"] {
            #expect(row[column] is NSNull, "\(column) was omitted rather than nulled")
        }
        #expect(row["external_id"] as? String == "tmdb:movie:2")
    }

    @Test("Emptying the queue filters on is.null, never eq.null")
    func queueDeleteUsesIsNull() async throws {
        let captured = Captured()
        let configuration = makeSupabaseConfiguration()
        let client = makeSupabaseClient(configuration: configuration) { request in
            captured.record(request)
            return .ok(Data())
        }
        let transport = SupabasePublishTransport(client: client, configuration: configuration)

        try await transport.deleteBucket(mediaType: .movie, sentiment: nil, userID: UUID())

        let delete = try #require(captured.first { $0.method == "DELETE" })
        let query = delete.query.removingPercentEncoding ?? delete.query

        // SQL comparison with null is null, so `sentiment=eq.null` matches no
        // row: the DELETE would succeed, report success, and delete nothing.
        // Nothing downstream would notice — the outbox row is cleared either
        // way — and the account would keep watchlist entries forever.
        #expect(query.contains("sentiment=is.null"))
        #expect(!query.contains("eq.null"))
    }
}

// MARK: - Capture

private final class Captured: @unchecked Sendable {
    struct Entry {
        let method: String
        let path: String
        /// The raw query string. The difference between a DELETE that empties
        /// the watchlist and one that silently matches nothing lives here and
        /// nowhere else.
        let query: String
        let body: Data
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(_ request: URLRequest) {
        let entry = Entry(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            query: request.url?.query ?? "",
            body: body(of: request)
        )
        lock.lock(); entries.append(entry); lock.unlock()
    }

    var all: [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func first(where predicate: (Entry) -> Bool) -> Entry? {
        all.first(where: predicate)
    }
}
