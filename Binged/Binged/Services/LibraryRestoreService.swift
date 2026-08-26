//
//  LibraryRestoreService.swift
//  Binged
//
//  Reading your *own* library back off the account.
//
//  Separate from `RankingFeedService` even though both read `ranked_items`,
//  because they are different questions with different answers. That one reads
//  somebody else's *published* ranking, a page at a time, for rendering — and
//  returns empty when RLS refuses, because a private account must not be
//  detectable by its errors. This one reads the whole of your own library,
//  published or not, to reconcile against the device, and a failure here must
//  be *loud*: a restore that silently returns nothing looks exactly like a new
//  account, and merging against "nothing" would push a device's library over an
//  account that was simply unreachable.
//
//  The self-read needs no special permission. `app.can_view_library`
//  short-circuits on `owner = auth.uid()`, and the Part IV policy names it
//  outright — see `20260823000000_library_sync.sql`.
//
//  See `docs/PART-IV-SYNC.md` §6.2.
//

import Foundation

// MARK: - LibraryRestoreService

protocol LibraryRestoreService: Sendable {
    /// Every row the account holds for `userID`, published or not.
    ///
    /// Throws rather than returning empty on failure. The caller must be able to
    /// tell "your account is empty" from "we could not ask", because the two
    /// lead to opposite merges.
    func myRankedItems(userID: UUID) async throws -> [RemoteRankedItem]
}

// MARK: - SupabaseLibraryRestoreService

final class SupabaseLibraryRestoreService: LibraryRestoreService, @unchecked Sendable {

    private let client: SupabaseClient
    private let configuration: SupabaseConfiguration

    /// PostgREST caps a response; a library larger than this is paged. The
    /// number is deliberately well above any plausible library — the point is
    /// that a truncated restore is silently wrong, not that anyone will hit it.
    private static let pageSize = 1000

    init(client: SupabaseClient, configuration: SupabaseConfiguration) {
        self.client = client
        self.configuration = configuration
    }

    func myRankedItems(userID: UUID) async throws -> [RemoteRankedItem] {
        var all: [Row] = []
        var offset = 0

        while true {
            let page: [Row] = try await client.send(
                .init(
                    url: configuration.rest("ranked_items"),
                    query: [
                        URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
                        URLQueryItem(name: "select", value: "*"),
                        // A stable order, so paging cannot skip or repeat a row
                        // when the set shifts under a concurrent drain.
                        URLQueryItem(name: "order", value: "media_type.asc,external_id.asc"),
                    ],
                    range: offset...(offset + Self.pageSize - 1)
                )
            )

            all.append(contentsOf: page)
            guard page.count == Self.pageSize else { break }
            offset += Self.pageSize
        }

        return all.compactMap(\.asRemoteRankedItem)
    }

    // MARK: Row

    /// The wire shape. Decoded loosely on purpose: a row this client cannot make
    /// sense of — an unknown media type from a newer build — is dropped rather
    /// than failing the whole restore, because one bad row must not cost the
    /// user their library.
    private struct Row: Decodable {
        let externalId: String
        let mediaType: String
        let sentiment: String?
        let title: String
        let year: Int?
        let rankInBucket: Int?
        let updatedAt: Date
        let posterPath: String?
        let review: String?

        enum CodingKeys: String, CodingKey {
            case externalId = "external_id"
            case mediaType = "media_type"
            case sentiment
            case title
            case year
            case rankInBucket = "rank_in_bucket"
            case updatedAt = "updated_at"
            case posterPath = "poster_path"
            case review
        }

        var asRemoteRankedItem: RemoteRankedItem? {
            guard let type = MediaType(wireValue: mediaType) else { return nil }
            // A null sentiment is a want-to-watch entry, not a decode failure.
            // An unrecognised one is.
            let parsed: Sentiment?
            if let sentiment {
                guard let value = Sentiment(rawValue: sentiment) else { return nil }
                parsed = value
            } else {
                parsed = nil
            }

            return RemoteRankedItem(
                externalId: externalId,
                mediaType: type,
                sentiment: parsed,
                title: title,
                year: year ?? 0,
                rankInBucket: rankInBucket,
                updatedAt: updatedAt,
                posterPath: posterPath,
                review: review
            )
        }
    }
}

// MARK: - MockLibraryRestoreService

final class MockLibraryRestoreService: LibraryRestoreService, @unchecked Sendable {

    private let lock = NSLock()
    private var rows: [UUID: [RemoteRankedItem]] = [:]
    private var failure: Error?

    init() {}

    func set(_ items: [RemoteRankedItem], for userID: UUID) {
        lock.lock()
        rows[userID] = items
        lock.unlock()
    }

    /// Makes the next restore throw. The case that matters: a caller must not
    /// treat an unreachable account as an empty one.
    func setFailure(_ error: Error?) {
        lock.lock()
        failure = error
        lock.unlock()
    }

    func myRankedItems(userID: UUID) async throws -> [RemoteRankedItem] {
        lock.lock()
        let error = failure
        let result = rows[userID] ?? []
        lock.unlock()

        if let error { throw error }
        return result
    }
}
