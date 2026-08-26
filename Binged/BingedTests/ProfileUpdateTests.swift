//
//  ProfileUpdateTests.swift
//  BingedTests
//
//  What "Save" on Edit Profile actually puts on the wire.
//
//  Written for one bug and one near-miss, and both are about the same thing:
//  **Swift's synthesized encoder omits nil optionals rather than writing null**
//  (`encodeIfPresent`), so an optional property is not a request to send
//  `null` — it is a request to send nothing.
//
//  The bug: `display_name` was declared optional, so clearing the field in Edit
//  Profile dropped the key, PostgREST patched the other columns, and the old
//  name stayed on the server. The sheet dismissed, nothing changed, and the
//  name reappeared on the next fetch.
//
//  The near-miss: `profiles.display_name` is NOT NULL, so had that nil ever
//  been encoded as an explicit null the request would have failed with a 23502
//  — taking `is_private` down with it, since the privacy toggle rides in the
//  same body. It never did. But the difference between "silently no-ops" and
//  "silently loses your privacy setting" is one keyword, which is reason enough
//  to pin the encoding down with assertions rather than trust it to stay put.
//
//  Hence a transport test rather than a view test: what matters is the JSON.
//

import Foundation
import Testing

@testable import Binged

@Suite("Profile update encoding")
struct ProfileUpdateTests {

    /// The stub sees the body as a stream, the way `URLProtocol` delivers it —
    /// `httpBody` is nil by the time a request reaches this layer.
    private static func body(of request: URLRequest) -> [String: Any] {
        if let data = request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Runs one `updateProfile` against a stub and hands back the JSON it sent.
    private func sentBody(for profile: UserProfile) async throws -> [String: Any] {
        let captured = Captured()
        let client = makeSupabaseClient { request in
            captured.store(Self.body(of: request))
            // Echoed back so the service has a row to decode and return.
            let row = """
            [{"id":"\(profile.id.uuidString.lowercased())","handle":"\(profile.handle)",
              "display_name":"x","bio":null,"avatar_url":null,
              "is_private":\(profile.isPrivate),"created_at":null}]
            """
            return .ok(Data(row.utf8))
        }
        let service = SupabaseAuthService(
            client: client, configuration: makeSupabaseConfiguration()
        )
        _ = try await service.updateProfile(profile)
        return captured.value
    }

    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: Any] = [:]
        func store(_ json: [String: Any]) { lock.lock(); stored = json; lock.unlock() }
        var value: [String: Any] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func profile(
        displayName: String?,
        handle: String = "jude",
        isPrivate: Bool = false
    ) -> UserProfile {
        UserProfile(
            id: UUID(), handle: handle, displayName: displayName, bio: nil,
            avatarURL: nil, isPrivate: isPrivate, createdAt: nil
        )
    }

    // MARK: - The bug

    @Test("A cleared display name is never sent as null")
    func nilDisplayNameFallsBackToTheHandle() async throws {
        let sent = try await sentBody(for: profile(displayName: nil))

        #expect(sent["display_name"] as? String == "jude")
        #expect(!(sent["display_name"] is NSNull))
    }

    @Test("Neither is a whitespace-only one, which the length check also rejects")
    func blankDisplayNameFallsBackToTheHandle() async throws {
        let sent = try await sentBody(for: profile(displayName: "   "))

        #expect(sent["display_name"] as? String == "jude")
    }

    @Test("Privacy still travels when the display name was cleared")
    func privacySurvivesAClearedName() async throws {
        // These two share one request, and `display_name` is the only NOT NULL
        // column in it — so any encoding that made the name unstorable would
        // take the privacy toggle down with it.
        let sent = try await sentBody(for: profile(displayName: nil, isPrivate: true))

        #expect(sent["is_private"] as? Bool == true)
        #expect(sent["display_name"] as? String == "jude")
    }

    // MARK: - Everything else is unchanged

    @Test("A real display name is sent as typed")
    func realNameIsUntouched() async throws {
        let sent = try await sentBody(for: profile(displayName: "Jude E"))

        #expect(sent["display_name"] as? String == "Jude E")
    }

    @Test("The handle is normalised, and is what an empty name falls back to")
    func handleIsNormalised() async throws {
        let sent = try await sentBody(for: profile(displayName: nil, handle: "JudeE"))

        #expect(sent["handle"] as? String == "judee")
        #expect(sent["display_name"] as? String == "judee")
    }

    @Test("A nil bio is omitted, not nulled — which is why the name needed fixing")
    func nilOptionalsAreOmitted() async throws {
        // Documents the encoder behaviour the bug turned on, on a column where
        // it is harmless: `bio` and `avatar_url` are nullable, so leaving them
        // untouched is the right outcome. `display_name` is not nullable, and
        // "leave it untouched" was the wrong outcome there.
        let sent = try await sentBody(for: profile(displayName: "Jude"))

        #expect(sent["bio"] == nil)
        #expect(sent["avatar_url"] == nil)
        #expect(sent.keys.contains("display_name"))
    }
}
