//
//  Feature.swift
//  Binged
//
//  One signal the recommendation engine can learn a preference for.
//
//  Everything the predictor knows about a title — its genres, its tone
//  keywords, its era, its director, its language — is flattened into a single
//  namespaced string array on `MediaItem.features`. One array rather than a
//  property per family, for two reasons:
//
//    - It is already the shape Phase 13's `featureEffects: [String: Double]`
//      wants, so the engine consumes it with no translation layer.
//    - Adding a family later costs a new case here, not a SwiftData migration.
//      Given the MVP has no migration plan, that difference is the difference
//      between "one more feature" and "everyone deletes the app again".
//
//  Key form is `family:id|Display Name`, or `family:value` for families with no
//  external identity. Ids carry identity and names carry display, because
//  neither alone is enough: two different people are credited as "Chris Evans",
//  so a name cannot be a key — and `person:19498` cannot be rendered into
//  "because you like Christopher Nolan", so an id cannot be the whole story.
//

import Foundation

// MARK: - Feature

struct Feature: Hashable, Sendable {

    let family: Family
    /// TMDB's id for this entity, for families that have one. Identity lives
    /// here; `displayName` is never used for comparison.
    let id: String?
    let displayName: String

    // MARK: Family

    enum Family: String, CaseIterable, Sendable {
        case genre
        case keyword
        case era
        case runtime
        case lang
        case director
        case composer
        case cast
        case franchise
        case network

        /// Whether keys in this family carry a TMDB id. Derived rather than
        /// stored so a new case cannot forget to declare it.
        var carriesIdentity: Bool {
            switch self {
            case .keyword, .director, .composer, .cast, .franchise, .network:
                return true
            case .genre, .era, .runtime, .lang:
                return false
            }
        }
    }

    // MARK: Init

    init(family: Family, id: String? = nil, displayName: String) {
        self.family = family
        self.id = id
        self.displayName = displayName
    }

    /// Parses a stored key. Returns `nil` for an unrecognised family or a
    /// malformed key.
    ///
    /// Dropping rather than trapping is deliberate: these strings come off
    /// disk, so a key written by a newer build — or corrupted — must degrade to
    /// "one less feature" and never to a crash on launch.
    init?(key: String) {
        guard let separator = key.firstIndex(of: ":") else { return nil }

        let rawFamily = String(key[key.startIndex..<separator])
        guard let family = Family(rawValue: rawFamily) else { return nil }

        let remainder = String(key[key.index(after: separator)...])
        guard !remainder.isEmpty else { return nil }

        // Split on the *first* pipe only. Display names legitimately contain
        // punctuation — "Mission: Impossible Collection" carries a colon, which
        // is why the family split above is also first-only.
        if let pipe = remainder.firstIndex(of: "|") {
            let id = String(remainder[remainder.startIndex..<pipe])
            let name = String(remainder[remainder.index(after: pipe)...])
            guard !id.isEmpty, !name.isEmpty else { return nil }
            self.init(family: family, id: id, displayName: name)
        } else {
            self.init(family: family, id: nil, displayName: remainder)
        }
    }

    // MARK: Key

    /// The canonical stored form. Round-trips through `init?(key:)`.
    var key: String {
        if let id {
            return "\(family.rawValue):\(id)|\(displayName)"
        }
        return "\(family.rawValue):\(displayName)"
    }

    // MARK: - Constructors

    static func genre(_ name: String) -> Feature {
        Feature(family: .genre, displayName: name)
    }

    static func keyword(id: Int, name: String) -> Feature {
        Feature(family: .keyword, id: String(id), displayName: name)
    }

    static func language(_ code: String) -> Feature {
        Feature(family: .lang, displayName: code)
    }

    static func director(id: Int, name: String) -> Feature {
        Feature(family: .director, id: String(id), displayName: name)
    }

    static func composer(id: Int, name: String) -> Feature {
        Feature(family: .composer, id: String(id), displayName: name)
    }

    static func castMember(id: Int, name: String) -> Feature {
        Feature(family: .cast, id: String(id), displayName: name)
    }

    static func franchise(id: Int, name: String) -> Feature {
        Feature(family: .franchise, id: String(id), displayName: name)
    }

    static func network(id: Int, name: String) -> Feature {
        Feature(family: .network, id: String(id), displayName: name)
    }

    /// Decade band. `nil` for the unknown-year sentinel — an undated title
    /// should contribute no era evidence rather than evidence for "the 0s".
    static func era(year: Int) -> Feature? {
        guard year >= 1870 else { return nil }
        return Feature(family: .era, displayName: "\(year / 10 * 10)s")
    }

    /// Length band. Bands rather than raw minutes because the predictor needs
    /// features that repeat: "142 minutes" appears once in a library, "long"
    /// appears many times.
    ///
    /// `nil` for a missing or nonsensical runtime, which is common for TV.
    static func runtime(minutes: Int?) -> Feature? {
        guard let minutes, minutes > 0 else { return nil }
        let band: String
        switch minutes {
        case ..<35:    band = "short"      // a half-hour episode
        case ..<70:    band = "episode"    // an hour-long episode
        case ..<105:   band = "brisk"
        case ..<135:   band = "standard"
        case ..<165:   band = "long"
        default:       band = "epic"
        }
        return Feature(family: .runtime, displayName: band)
    }
}

// MARK: - Collections

extension Sequence where Element == String {

    /// Parses stored keys, silently dropping any that no longer make sense.
    var features: [Feature] {
        compactMap(Feature.init(key:))
    }

    func features(in family: Feature.Family) -> [Feature] {
        features.filter { $0.family == family }
    }
}

extension Sequence where Element == Feature {

    /// Canonical keys, deduplicated, with first-seen order preserved so a
    /// stored array is stable between writes.
    var keys: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for key in map(\.key) where seen.insert(key).inserted {
            ordered.append(key)
        }
        return ordered
    }
}
