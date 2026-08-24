//
//  SupabaseClient.swift
//  Binged
//
//  The one HTTP client every social service is built on.
//
//  An `actor` for one reason that matters: **single-flight token refresh.** A
//  feed screen fires several requests at once, so several 401s arriving together
//  is the common case rather than the edge case. Refreshing per 401 would send N
//  refreshes, and because Supabase rotates refresh tokens, N−1 of them would be
//  invalidated — signing the user out precisely when they opened the busiest
//  screen. Serialising through one actor makes concurrent 401s await a single
//  refresh and then retry.
//

import Foundation

// MARK: - SupabaseClient

actor SupabaseClient {

    // MARK: Dependencies

    private let configuration: SupabaseConfiguration?
    private let session: URLSession
    private let tokens: TokenStore

    /// The refresh currently in flight, if any. The whole point of the actor.
    private var refreshTask: Task<SupabaseSession, Error>?

    /// Bumped whenever the session is replaced or cleared, so a request that
    /// began before a refresh can tell whether its 401 is stale.
    private var sessionGeneration = 0

    // MARK: Init

    init(
        configuration: SupabaseConfiguration?,
        session: URLSession = .shared,
        tokens: TokenStore = KeychainTokenStore()
    ) {
        self.configuration = configuration
        self.session = session
        self.tokens = tokens
    }

    // MARK: State

    var isConfigured: Bool { configuration != nil }

    var currentSession: SupabaseSession? { tokens.load() }

    var isSignedIn: Bool { tokens.load() != nil }

    var currentUserID: UUID? { tokens.load()?.userID }

    func store(_ newSession: SupabaseSession) {
        tokens.save(newSession)
        sessionGeneration += 1
    }

    func signOutLocally() {
        tokens.clear()
        refreshTask = nil
        sessionGeneration += 1
    }

    // MARK: - Requests

    struct Request {
        var method: String = "GET"
        var url: URL
        var query: [URLQueryItem] = []
        var body: Data?
        var headers: [String: String] = [:]
        /// PostgREST pagination, inclusive on both ends.
        var range: ClosedRange<Int>?
        /// When true, sends the anon key as the bearer even if signed in.
        /// Auth endpoints that mint a session must not carry the old one.
        var anonymous: Bool = false
    }

    /// Sends a request and decodes the result.
    func send<Value: Decodable>(_ request: Request, as type: Value.Type = Value.self) async throws -> Value {
        let data = try await sendData(request)
        if data.isEmpty, let empty = EmptyResponse() as? Value { return empty }
        do {
            return try Self.decoder.decode(Value.self, from: data)
        } catch {
            throw SupabaseError.decoding(String(describing: error))
        }
    }

    /// Sends a request whose response body is not needed.
    @discardableResult
    func send(_ request: Request) async throws -> Data {
        try await sendData(request)
    }

    // MARK: - The retry rule

    private func sendData(_ request: Request) async throws -> Data {
        guard configuration != nil else { throw SupabaseError.notConfigured }

        let generation = sessionGeneration
        do {
            return try await perform(request)
        } catch SupabaseError.unauthorized {
            // Anonymous requests have no session to refresh, so a 401 is final.
            guard !request.anonymous else { throw SupabaseError.unauthorized }

            // Refresh once, then retry once. A second 401 signs out rather than
            // looping — an unbounded retry against a rejected credential is how
            // a client hammers an auth server.
            _ = try await refreshSession(startedAtGeneration: generation)
            do {
                return try await perform(request)
            } catch SupabaseError.unauthorized {
                signOutLocally()
                throw SupabaseError.unauthorized
            }
        }
    }

    private func perform(_ request: Request) async throws -> Data {
        guard let configuration else { throw SupabaseError.notConfigured }

        var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        if !request.query.isEmpty { components?.queryItems = request.query }
        guard let url = components?.url else {
            throw SupabaseError.transport("Could not build a URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body

        // `apikey` identifies the project; `Authorization` identifies the user.
        // Signed out, both are the anon key — which is what lets RLS policies
        // written against `anon` serve public reads with no session at all.
        urlRequest.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        let bearer = request.anonymous ? configuration.anonKey
                                       : (tokens.load()?.accessToken ?? configuration.anonKey)
        urlRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        if let range = request.range {
            urlRequest.setValue("\(range.lowerBound)-\(range.upperBound)",
                                forHTTPHeaderField: "Range")
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw SupabaseError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.transport("Not an HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw SupabaseError.unauthorized
        case 403:
            throw SupabaseError.forbidden
        case 409:
            throw SupabaseError.conflict(Self.message(from: data))
        default:
            throw SupabaseError.http(status: http.statusCode, message: Self.message(from: data))
        }
    }

    // MARK: - Single-flight refresh

    /// Refreshes the session, coalescing concurrent callers onto one request.
    ///
    /// `startedAtGeneration` is what makes a *stale* 401 harmless: a request
    /// that set off before someone else's refresh completed will fail with 401
    /// through no fault of the new token. Seeing that the generation has already
    /// moved, this returns the current session instead of spending another
    /// refresh — and, critically, instead of rotating a refresh token that the
    /// just-completed refresh has already replaced.
    private func refreshSession(startedAtGeneration generation: Int) async throws -> SupabaseSession {
        if generation != sessionGeneration, let current = tokens.load() {
            return current
        }
        if let existing = refreshTask {
            return try await existing.value
        }

        guard let configuration, let stored = tokens.load() else {
            signOutLocally()
            throw SupabaseError.unauthorized
        }

        let task = Task<SupabaseSession, Error> { [session] in
            var request = URLRequest(
                url: configuration.auth("token")
                    .appending(queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")])
            )
            request.httpMethod = "POST"
            request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(configuration.anonKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(
                ["refresh_token": stored.refreshToken]
            )

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw SupabaseError.transport(String(describing: error))
            }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw SupabaseError.unauthorized
            }
            guard let token = try? Self.decoder.decode(AuthTokenResponse.self, from: data),
                  let refreshed = token.session else {
                throw SupabaseError.unauthorized
            }
            return refreshed
        }

        refreshTask = task
        defer { refreshTask = nil }

        do {
            let refreshed = try await task.value
            store(refreshed)
            return refreshed
        } catch {
            signOutLocally()
            throw SupabaseError.unauthorized
        }
    }

    // MARK: - Coding

    /// One date strategy everywhere. Postgres `timestamptz` comes back as
    /// ISO-8601, sometimes with fractional seconds and sometimes without, and a
    /// decoder that handles only one of those fails on real data.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = iso8601Fractional.date(from: raw) { return date }
            if let date = iso8601Plain.date(from: raw) { return date }
            throw SupabaseError.decoding("Unparseable date: \(raw)")
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601Fractional.string(from: date))
        }
        return encoder
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func message(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (payload["message"] ?? payload["error_description"]
                ?? payload["msg"] ?? payload["details"]) as? String
    }
}

// MARK: - Payloads

/// GoTrue's token response.
struct AuthTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?
    let user: AuthUser?

    struct AuthUser: Decodable {
        let id: UUID
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }

    var session: SupabaseSession? {
        guard let accessToken, let refreshToken, let user else { return nil }
        return SupabaseSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn ?? 3600),
            userID: user.id
        )
    }
}

/// Stand-in for an endpoint that returns no body.
struct EmptyResponse: Codable {}
