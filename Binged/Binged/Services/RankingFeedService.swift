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
}

// MARK: - MockRankingFeedService

final class MockRankingFeedService: RankingFeedService, @unchecked Sendable {

    private let lock = NSLock()
    private var libraries: [UUID: [RankedItem]] = [:]
    /// Users whose library the viewer may not read, standing in for RLS.
    private var hidden: Set<UUID> = []

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
}
