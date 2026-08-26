//
//  RankingFeedService.swift
//  Binged
//
//  Reading other people's published rankings.
//
//  Separate from `SocialService` for the same reason `FeatureSource` is separate
//  from `MediaService`: the graph and the rankings are different concerns with
//  different consumers, and a screen that only needs one should not depend on
//  both.
//

import Foundation

// MARK: - RankingFeedService

protocol RankingFeedService: Sendable {
    /// One page of a user's published ranking, best first within each bucket.
    ///
    /// Returns empty rather than throwing when the viewer is not allowed to
    /// see it — that is what row-level security produces, and the caller reads
    /// "empty and private" as the private state.
    func rankedItems(userID: UUID, offset: Int, limit: Int) async throws -> [RankedItem]

    /// Published opinions on one title from accounts the viewer actively
    /// follows, best first.
    ///
    /// Answers the question a title page asks, which is the reverse of the one
    /// above: not "what is on their ranking" but "who among my people has an
    /// opinion about this". Returns empty rather than throwing when nobody
    /// qualifies — an empty section and a private account are the same answer
    /// on purpose.
    func watchers(externalID: String, mediaType: MediaType, limit: Int) async throws -> [TitleWatcher]
}

// MARK: - SupabaseRankingFeedService

final class SupabaseRankingFeedService: RankingFeedService, @unchecked Sendable {

    private let client: SupabaseClient
    private let configuration: SupabaseConfiguration

    init(client: SupabaseClient, configuration: SupabaseConfiguration) {
        self.client = client
        self.configuration = configuration
    }

    func rankedItems(userID: UUID, offset: Int, limit: Int) async throws -> [RankedItem] {
        do {
            return try await client.send(
                .init(
                    url: configuration.rest("ranked_items"),
                    query: [
                        URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
                        URLQueryItem(name: "select", value: "*"),
                        URLQueryItem(name: "order", value: "media_type.asc,sentiment.asc,rank_in_bucket.asc"),
                    ],
                    range: offset...(offset + max(0, limit - 1))
                )
            )
        } catch SupabaseError.forbidden {
            // Not allowed to see it: the same answer as "there is nothing", by
            // design. A private account must not be detectable by its errors.
            return []
        }
    }

    func watchers(
        externalID: String, mediaType: MediaType, limit: Int
    ) async throws -> [TitleWatcher] {
        do {
            return try await client.send(
                .init(
                    method: "POST",
                    url: configuration.rpc("title_watchers"),
                    body: try SupabaseClient.encoder.encode(
                        WatchersRequest(
                            mediaType: mediaType.wireValue,
                            externalID: externalID,
                            limit: limit
                        )
                    )
                )
            )
        } catch SupabaseError.forbidden {
            return []
        }
    }

    private struct WatchersRequest: Encodable {
        let mediaType: String
        let externalID: String
        let limit: Int

        enum CodingKeys: String, CodingKey {
            case mediaType = "p_media_type"
            case externalID = "p_external_id"
            case limit = "p_limit"
        }
    }
}

// MARK: - MockRankingFeedService

final class MockRankingFeedService: RankingFeedService, @unchecked Sendable {

    private let lock = NSLock()
    private var libraries: [UUID: [RankedItem]] = [:]
    /// Users whose library the viewer may not read, standing in for RLS.
    private var hidden: Set<UUID> = []
    private var watchersByTitle: [String: [TitleWatcher]] = [:]

    init() {}

    func set(_ items: [RankedItem], for userID: UUID, visible: Bool = true) {
        lock.lock()
        libraries[userID] = items
        if visible { hidden.remove(userID) } else { hidden.insert(userID) }
        lock.unlock()
    }

    func rankedItems(userID: UUID, offset: Int, limit: Int) async throws -> [RankedItem] {
        lock.lock()
        defer { lock.unlock() }
        guard !hidden.contains(userID) else { return [] }
        let all = libraries[userID] ?? []
        guard offset < all.count else { return [] }
        return Array(all[offset..<min(offset + limit, all.count)])
    }

    /// Seeds one person's opinion of one title.
    ///
    /// Kept separate from `set(_:for:)` because the server answers these from
    /// different directions and a fixture that derived one from the other would
    /// hide the difference — including the follow requirement, which is the
    /// whole point of the RPC.
    func setWatchers(_ watchers: [TitleWatcher], forExternalID externalID: String, mediaType: MediaType) {
        lock.lock()
        watchersByTitle[Self.titleKey(externalID, mediaType)] = watchers
        lock.unlock()
    }

    func watchers(
        externalID: String, mediaType: MediaType, limit: Int
    ) async throws -> [TitleWatcher] {
        lock.lock()
        defer { lock.unlock() }
        let all = watchersByTitle[Self.titleKey(externalID, mediaType)] ?? []
        // Mirrors the server: hidden libraries contribute nothing, and the
        // limit is honoured rather than assumed generous.
        return Array(all.filter { !hidden.contains($0.userID) }.prefix(max(0, limit)))
    }

    private static func titleKey(_ externalID: String, _ mediaType: MediaType) -> String {
        "\(mediaType.rawValue)|\(externalID)"
    }
}
