//
//  SupabasePublishTransportTests.swift
//  BingedTests
//
//  The wire shape of publishing, against two hazards that a behavioural test
//  cannot see because both are about what the *request* contains.
//
//  1. **`is_published` must not appear in the upsert body.** The upsert is a
//     PostgREST `resolution=merge-duplicates`, which becomes
//     `INSERT … ON CONFLICT DO UPDATE SET` over every column sent — and
//     `update (is_published)` is revoked from `authenticated`
//     (`20260823000000_library_sync.sql`). Sending it would insert the first
//     row of a bucket happily and then fail 42501 on every later drain that
//     touched an existing row, which is every drain after the first. The
//     failure needs no client bug and no unusual state; it needs a second
//     ranking.
//
//  2. **Changing visibility must be the RPC, not a PATCH.** Same revoke. A
//     direct `PATCH …?user_id=eq.<id>` reads as the obvious implementation and
//     is refused by the database on purpose, so that no client can flip one row
//     and leave a bucket half-visible.
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

    @Test("The upsert body never carries is_published")
    func upsertOmitsTheRevokedColumn() async throws {
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

        #expect(row["is_published"] == nil, "the column is revoked; sending it 42501s on upsert")
        // The rest of the row is still expected to be there — this is an
        // omission, not an empty payload.
        #expect(row["external_id"] as? String == "tmdb:movie:1")
        #expect(row["bucket_size"] as? Int == 1)
    }

    @Test("Changing visibility calls the RPC, never a PATCH on the table")
    func visibilityGoesThroughTheRPC() async throws {
        let captured = Captured()
        let configuration = makeSupabaseConfiguration()
        let client = makeSupabaseClient(configuration: configuration) { request in
            captured.record(request)
            return .ok(Data("1".utf8))
        }
        let transport = SupabasePublishTransport(client: client, configuration: configuration)

        try await transport.setPublished(true, userID: UUID())

        let request = try #require(captured.all.first)
        #expect(request.method == "POST")
        #expect(request.path.hasSuffix("/rest/v1/rpc/set_library_published"))

        let json = try #require(
            try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        #expect(json["p_published"] as? Bool == true)
        // The function authorises on auth.uid() alone. A user parameter would
        // be a shape of call that could name somebody else's library.
        #expect(json["user_id"] == nil)

        let patches = captured.all.filter { $0.method == "PATCH" }
        #expect(patches.isEmpty, "a direct PATCH of is_published is refused by the database")
    }

    @Test("Unpublishing sends false rather than deleting anything")
    func unpublishingIsNotADelete() async throws {
        let captured = Captured()
        let configuration = makeSupabaseConfiguration()
        let client = makeSupabaseClient(configuration: configuration) { request in
            captured.record(request)
            return .ok(Data("3".utf8))
        }
        let transport = SupabasePublishTransport(client: client, configuration: configuration)

        try await transport.setPublished(false, userID: UUID())

        let json = try #require(
            try JSONSerialization.jsonObject(with: captured.all[0].body) as? [String: Any]
        )
        #expect(json["p_published"] as? Bool == false)

        let deletes = captured.all.filter { $0.method == "DELETE" }
        #expect(deletes.isEmpty, "hiding a library must never delete the owner's rows")
    }
}

// MARK: - Capture

private final class Captured: @unchecked Sendable {
    struct Entry {
        let method: String
        let path: String
        let body: Data
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(_ request: URLRequest) {
        let entry = Entry(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
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
