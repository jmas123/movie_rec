//
//  SupabaseConfiguration.swift
//  Binged
//
//  Where the Supabase credentials come from, and what happens when they are
//  absent — which is a supported state, not a broken one.
//
//  Injected the same way the TMDB token is: `Config/Secrets.xcconfig`
//  (gitignored) defines `SUPABASE_URL` and `SUPABASE_ANON_KEY`,
//  `Config/Info.plist` carries them through, and this reads them back. A
//  checkout without the secrets file still builds and launches; it is simply
//  signed out with the social features unavailable, exactly as a missing TMDB
//  token falls back to the bundled catalog.
//
//  **The anon key belongs in the bundle.** It is a publishable credential that
//  identifies the project and carries no privilege of its own — row-level
//  security in Postgres is the entire authorisation boundary. The `service_role`
//  key must never appear in the app, in this file, or in any xcconfig.
//

import Foundation

// MARK: - SupabaseConfiguration

struct SupabaseConfiguration: Equatable, Sendable {

    /// Project URL, e.g. `https://abcdefgh.supabase.co`.
    let url: URL

    /// The `anon` / `public` key. Sent as both `apikey` and, when signed out,
    /// as the bearer token.
    let anonKey: String

    // MARK: Info.plist keys

    static let urlKey = "SupabaseURL"
    static let anonKeyKey = "SupabaseAnonKey"

    /// What an unset build setting resolves to. Treated as absent, so a
    /// half-configured build fails the same way an unconfigured one does rather
    /// than sending the literal string to a server.
    static let unsetURLPlaceholder = "$(SUPABASE_URL)"
    static let unsetKeyPlaceholder = "$(SUPABASE_ANON_KEY)"

    // MARK: Loading

    static func fromBundle(_ bundle: Bundle = .main) -> SupabaseConfiguration? {
        let rawURL = bundle.object(forInfoDictionaryKey: urlKey) as? String
        let rawKey = bundle.object(forInfoDictionaryKey: anonKeyKey) as? String
        return make(url: rawURL ?? "", anonKey: rawKey ?? "")
    }

    /// Split out so the validation rules can be tested without a bundle.
    static func make(url rawURL: String, anonKey rawKey: String) -> SupabaseConfiguration? {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty, trimmedURL != unsetURLPlaceholder,
              !trimmedKey.isEmpty, trimmedKey != unsetKeyPlaceholder,
              let url = URL(string: trimmedURL),
              url.scheme == "https" || url.scheme == "http",
              // A host is required, not implied by a valid scheme. xcconfig
              // treats `//` as a comment even inside a value, so a pasted
              // `https://ref.supabase.co` arrives here as bare `https:` — which
              // URL happily parses, scheme and all. Without this the app would
              // consider itself configured and fail on every request instead of
              // reporting itself unconfigured.
              let host = url.host, !host.isEmpty
        else { return nil }

        return SupabaseConfiguration(url: url, anonKey: trimmedKey)
    }

    // MARK: Endpoints

    /// PostgREST table endpoint. Query items are appended by the caller.
    func rest(_ table: String) -> URL {
        url.appendingPathComponent("rest/v1").appendingPathComponent(table)
    }

    /// GoTrue auth endpoint.
    func auth(_ path: String) -> URL {
        url.appendingPathComponent("auth/v1").appendingPathComponent(path)
    }

    /// A Postgres function exposed over PostgREST.
    func rpc(_ function: String) -> URL {
        url.appendingPathComponent("rest/v1/rpc").appendingPathComponent(function)
    }
}

// MARK: - SupabaseError

enum SupabaseError: Error, Equatable, CustomStringConvertible {

    /// The build carries no Supabase credentials. Distinct from every network
    /// failure: no amount of retrying fixes it, and the UI should offer sign-in
    /// nowhere rather than offering it and failing.
    case notConfigured

    /// 401. The session is missing, expired, or was rejected after a refresh.
    case unauthorized

    /// 403 — a row-level-security denial.
    ///
    /// **Deliberately distinct from `unauthorized`.** Being told "you cannot see
    /// this row" is an expected outcome of asking for something private, and
    /// treating it as a broken session would sign the user out for browsing a
    /// profile they do not follow.
    case forbidden

    /// 409 — a uniqueness violation. A taken handle is the common case.
    case conflict(String?)

    /// Any other non-2xx.
    case http(status: Int, message: String?)

    case transport(String)
    case decoding(String)

    var description: String {
        switch self {
        case .notConfigured:
            return "This build has no Supabase configuration, so social features are off."
        case .unauthorized:
            return "Your session has expired. Sign in again."
        case .forbidden:
            return "You do not have access to that."
        case .conflict(let detail):
            return detail ?? "That is already taken."
        case .http(let status, let message):
            return message ?? "The server returned \(status)."
        case .transport:
            return "Could not reach the server."
        case .decoding:
            return "The server sent something unexpected."
        }
    }

    /// Whether encountering this should end the session.
    ///
    /// Only `unauthorized`, and only after a refresh has already been tried.
    var shouldSignOut: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}
