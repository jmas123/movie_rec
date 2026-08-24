//
//  SupabaseTestSupport.swift
//  BingedTests
//
//  Shared fixtures for the Supabase layer. Reuses `StubURLProtocol` from
//  `TMDBTestSupport.swift` — one stub network for the whole suite.
//

import Foundation
@testable import Binged

// MARK: - Configuration

func makeSupabaseConfiguration() -> SupabaseConfiguration {
    SupabaseConfiguration(
        url: URL(string: "https://project.supabase.test")!,
        anonKey: "anon-test-key"
    )
}

// MARK: - Sessions

func makeSession(
    access: String = "access-1",
    refresh: String = "refresh-1",
    expiresIn: TimeInterval = 3600,
    userID: UUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
) -> SupabaseSession {
    SupabaseSession(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: Date().addingTimeInterval(expiresIn),
        userID: userID
    )
}

// MARK: - Client

func makeSupabaseClient(
    configuration: SupabaseConfiguration? = makeSupabaseConfiguration(),
    session: SupabaseSession? = makeSession(),
    log: RequestLog? = nil,
    handler: @escaping StubURLProtocol.Handler
) -> SupabaseClient {
    let urlSession = StubURLProtocol.makeSession { request in
        log?.record(request)
        return handler(request)
    }
    return SupabaseClient(
        configuration: configuration,
        session: urlSession,
        tokens: InMemoryTokenStore(session: session)
    )
}

// MARK: - Counting stub

/// Counts requests by path fragment, so a test can assert "exactly one refresh"
/// rather than inspecting a transcript.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ request: URLRequest) {
        guard let path = request.url?.path else { return }
        lock.lock(); counts[path, default: 0] += 1; lock.unlock()
    }

    func count(_ fragment: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts.filter { $0.key.contains(fragment) }.map(\.value).reduce(0, +)
    }

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }
}

// MARK: - Payloads

enum SupabaseFixtures {

    static func tokenResponse(
        access: String = "access-2", refresh: String = "refresh-2"
    ) -> Data {
        Data("""
        {"access_token":"\(access)","refresh_token":"\(refresh)","expires_in":3600,
         "user":{"id":"00000000-0000-0000-0000-0000000000AA"}}
        """.utf8)
    }

    static let unauthorized = Data(#"{"message":"JWT expired"}"#.utf8)
    static let forbidden = Data(#"{"message":"new row violates row-level security policy"}"#.utf8)
    static let conflict = Data(#"{"message":"duplicate key value violates unique constraint"}"#.utf8)
    static let emptyArray = Data("[]".utf8)
}
