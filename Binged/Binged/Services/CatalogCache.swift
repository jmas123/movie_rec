//
//  CatalogCache.swift
//  Binged
//
//  A small, disposable JSON cache on disk for TMDB responses.
//
//  Deliberately **not** SwiftData. The SwiftData store holds the user's library
//  — the one thing in this app that cannot be re-fetched — and mixing a
//  disposable cache into it turns routine cache eviction into a data-loss risk
//  and every cache schema change into a store migration. This cache can be
//  deleted at any moment with no consequence beyond a slower next launch, and
//  keeping it in plain files is what makes that true.
//
//  Freshness is reported rather than enforced. `load` hands back stale entries
//  along with a flag, because "stale" and "useless" are different: with the
//  network down, last week's popular-titles page is the difference between a
//  working Discover screen and an empty one.
//

import Foundation

// MARK: - CatalogCache

final class CatalogCache {

    // MARK: Configuration

    private let directory: URL?
    private let ttl: TimeInterval
    private let fileManager: FileManager

    /// One week. The popular-title set and TMDB's genre tables do not churn
    /// daily, and a shorter window would spend the user's battery re-fetching
    /// data that has not changed.
    static let defaultTTL: TimeInterval = 60 * 60 * 24 * 7

    // MARK: Init

    /// - Parameter directory: cache location. Defaults to
    ///   `Application Support/TMDBCache`. `nil` disables persistence entirely
    ///   (used by tests that should not touch the filesystem), in which case
    ///   every load misses and every store is a no-op.
    init(
        directory: URL? = CatalogCache.defaultDirectory(),
        ttl: TimeInterval = CatalogCache.defaultTTL,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.ttl = ttl
        self.fileManager = fileManager
    }

    /// `Application Support` rather than `Caches`: the OS may evict `Caches`
    /// under storage pressure at arbitrary times, and losing the pool mid-use
    /// would strand the Discover screen precisely when the device is too full
    /// to re-download it.
    ///
    /// Returns `nil` if the directory cannot be resolved, which degrades this
    /// type to a no-op cache rather than failing the app.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base.appendingPathComponent("TMDBCache", isDirectory: true)
    }

    // MARK: - Reading

    /// A cache hit, with the freshness the caller needs to decide what to do.
    struct Hit<Value> {
        let value: Value

        /// `true` when the entry is older than the TTL. Still returned, because
        /// a stale answer beats no answer when the network is unreachable.
        let isStale: Bool
    }

    /// Returns the cached value for `key`, or `nil` if nothing is stored or the
    /// stored bytes no longer decode into `Value`.
    ///
    /// A decode failure is treated as a miss and the file is discarded: it means
    /// the cached shape predates a code change, and there is nothing to be
    /// gained by reporting an error for data the caller can simply re-fetch.
    func load<Value: Codable>(_ key: String, as type: Value.Type = Value.self) -> Hit<Value>? {
        guard let url = fileURL(for: key),
              let data = try? Data(contentsOf: url) else { return nil }

        guard let envelope = try? Self.decoder.decode(Envelope<Value>.self, from: data) else {
            try? fileManager.removeItem(at: url)
            return nil
        }

        let age = Date.now.timeIntervalSince(envelope.storedAt)
        return Hit(value: envelope.payload, isStale: age > ttl)
    }

    // MARK: - Writing

    /// Best-effort. A cache that cannot write is slow, not broken, so failures
    /// here are swallowed rather than propagated to a caller who has already
    /// successfully fetched the real thing.
    func store<Value: Codable>(_ value: Value, for key: String) {
        guard let directory, let url = fileURL(for: key) else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let envelope = Envelope(storedAt: .now, payload: value)
            try Self.encoder.encode(envelope).write(to: url, options: .atomic)
        } catch {
            // Intentionally ignored — see doc comment.
        }
    }

    /// Removes everything. Not called in normal operation; exists so a future
    /// "clear cached data" affordance, and the tests, have one honest way to
    /// reset rather than reaching into the filesystem themselves.
    func removeAll() {
        guard let directory else { return }
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Envelope

    /// Wraps the payload with the timestamp freshness is computed from. Storing
    /// the time *inside* the file rather than reading the filesystem's
    /// modification date keeps freshness meaningful after a backup restore or a
    /// file copy, both of which rewrite mtime.
    private struct Envelope<Payload>: Codable where Payload: Codable {
        let storedAt: Date
        let payload: Payload
    }

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    // MARK: - Filenames

    private func fileURL(for key: String) -> URL? {
        guard let directory else { return nil }
        return directory.appendingPathComponent("\(Self.filename(for: key)).json")
    }

    /// A readable prefix plus a stable hash of the full key.
    ///
    /// The prefix keeps the cache directory diagnosable by eye; the hash keeps
    /// two keys that sanitise to the same prefix ("search:the dark knight" and
    /// "search:the-dark-knight") in separate files. Swift's built-in
    /// `hashValue` is seeded per process and would produce a different filename
    /// on every launch, so the FNV-1a below is spelled out rather than borrowed.
    static func filename(for key: String) -> String {
        let prefix = key
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .prefix(48)
        return "\(prefix)-\(fnv1a(key))"
    }

    private static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x1000_0000_01b3
        }
        return String(hash, radix: 36)
    }
}

// MARK: - Cache keys

/// Cache keys in one place, so a reader and a writer cannot disagree about the
/// spelling of a key and silently never hit.
enum CatalogCacheKey {

    static func search(_ query: String) -> String {
        "search:\(query.lowercased())"
    }

    static func detail(type: MediaType, tmdbId: Int) -> String {
        "detail:\(TMDBIdentifier.segment(for: type)):\(tmdbId)"
    }

    static func popular(type: MediaType, page: Int) -> String {
        "popular:\(TMDBIdentifier.segment(for: type)):\(page)"
    }

    /// Distinct from `detail` on purpose. The two hit the same path but ask for
    /// different payloads, and sharing a key would let a plain detail response
    /// — fetched first by a search tap — satisfy a feature request that needs
    /// credits, yielding a title with silently no cast or director.
    static func features(type: MediaType, tmdbId: Int) -> String {
        "features:\(TMDBIdentifier.segment(for: type)):\(tmdbId)"
    }

    /// Keyed by the IMDb id alone: `/find` is a pure lookup and its answer does
    /// not depend on what the caller expected the type to be.
    static func find(imdbID: String) -> String {
        "find:imdb:\(imdbID)"
    }

    /// One page of one mood component. Keyed by the component's own identity
    /// rather than by the mood, so two moods sharing a basis share a cache
    /// entry instead of fetching the same page twice.
    static func pool(type: MediaType, component: MoodQueryComponent, page: Int) -> String {
        "pool:\(TMDBIdentifier.segment(for: type)):\(component.identity):\(page)"
    }

    static func keyword(_ name: String) -> String {
        "keyword:\(name.lowercased())"
    }

    /// The assembled pool itself, which outlives any single page.
    static let candidatePool = "pool:assembled"

    static let genreVocabulary = "genres:all"
}
