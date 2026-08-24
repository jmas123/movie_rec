//
//  SupabaseAuthService.swift
//  WatchRank
//
//  Accounts, against GoTrue and the `profiles` table.
//

import Foundation

// MARK: - SupabaseAuthService

final class SupabaseAuthService: AuthService, @unchecked Sendable {

    private let client: SupabaseClient
    private let configuration: SupabaseConfiguration

    init(client: SupabaseClient, configuration: SupabaseConfiguration) {
        self.client = client
        self.configuration = configuration
    }

    // MARK: Sign up

    func signUp(email: String, password: String, handle: String) async throws -> UserProfile {
        if let problem = Handle.validate(handle) { throw AuthError.invalidHandle(problem) }
        guard password.count >= AuthError.minimumPasswordLength else { throw AuthError.weakPassword }

        let normalized = Handle.normalize(handle)

        let token: AuthTokenResponse
        do {
            token = try await client.send(
                .init(
                    method: "POST",
                    url: configuration.auth("signup"),
                    body: try SupabaseClient.encoder.encode(
                        Credentials(email: email, password: password)
                    ),
                    anonymous: true
                )
            )
        } catch SupabaseError.conflict {
            throw AuthError.emailInUse
        } catch let error as SupabaseError {
            throw Self.translate(error)
        }

        guard let session = token.session else { throw AuthError.underlying("No session returned") }
        await client.store(session)

        // The handle is claimed *after* the account exists, because it needs the
        // user id. If this fails the account is real but handle-less, so the
        // caller must be able to retry — see `claimHandle`.
        do {
            return try await claimHandle(normalized, for: session.userID)
        } catch {
            // Do not strand a signed-in session with no profile: sign back out
            // so a retry starts clean rather than half-created.
            await signOut()
            throw error
        }
    }

    /// Claims the handle on the profile row that already exists.
    ///
    /// **An update, not an insert.** `app.handle_new_user()` fires on
    /// `auth.users` and creates the profile the moment the account does, with a
    /// placeholder handle derived from the user id. Inserting here would collide
    /// with that row on the primary key and surface as a 409 — which this
    /// function reads as "handle taken", so a perfectly free handle would be
    /// reported as somebody else's.
    ///
    /// The 409 is still the *real* check, it just comes from the unique index on
    /// `handle` now rather than on `id`. An availability probe can pass for two
    /// people in the same second and only one write wins, so the constraint is
    /// what decides and this is where that is handled.
    func claimHandle(_ handle: String, for userID: UUID) async throws -> UserProfile {
        do {
            let rows: [UserProfile] = try await client.send(
                .init(
                    method: "PATCH",
                    url: configuration.rest("profiles"),
                    query: [
                        URLQueryItem(name: "id", value: "eq.\(userID.uuidString.lowercased())")
                    ],
                    body: try SupabaseClient.encoder.encode(HandleClaim(handle: handle)),
                    headers: ["Prefer": "return=representation"]
                )
            )
            guard let profile = rows.first else {
                throw AuthError.underlying("Profile was not returned")
            }
            return profile
        } catch SupabaseError.conflict {
            throw AuthError.handleTaken(handle)
        } catch let error as SupabaseError {
            throw Self.translate(error)
        }
    }

    // MARK: Sign in

    func signIn(email: String, password: String) async throws -> UserProfile {
        let token: AuthTokenResponse
        do {
            token = try await client.send(
                .init(
                    method: "POST",
                    url: configuration.auth("token"),
                    query: [URLQueryItem(name: "grant_type", value: "password")],
                    body: try SupabaseClient.encoder.encode(
                        Credentials(email: email, password: password)
                    ),
                    anonymous: true
                )
            )
        } catch SupabaseError.unauthorized {
            throw AuthError.invalidCredentials
        } catch let error as SupabaseError {
            throw Self.translate(error)
        }

        guard let session = token.session else { throw AuthError.invalidCredentials }
        await client.store(session)

        guard let profile = try await currentProfile() else {
            throw AuthError.underlying("Signed in, but no profile exists")
        }
        return profile
    }

    func signOut() async {
        // Local first and unconditionally: a user asking to sign out must always
        // succeed, whatever the network is doing.
        await client.signOutLocally()
    }

    // MARK: Profile

    func currentProfile() async throws -> UserProfile? {
        guard let userID = await client.currentUserID else { return nil }
        let rows: [UserProfile] = try await client.send(
            .init(
                url: configuration.rest("profiles"),
                query: [
                    URLQueryItem(name: "id", value: "eq.\(userID.uuidString.lowercased())"),
                    URLQueryItem(name: "select", value: "*"),
                ]
            )
        )
        return rows.first
    }

    func isHandleAvailable(_ handle: String) async -> Bool {
        guard Handle.isValid(handle) else { return false }
        let normalized = Handle.normalize(handle)
        do {
            let rows: [HandleRow] = try await client.send(
                .init(
                    url: configuration.rest("profiles"),
                    query: [
                        URLQueryItem(name: "handle", value: "eq.\(normalized)"),
                        URLQueryItem(name: "select", value: "handle"),
                    ]
                )
            )
            return rows.isEmpty
        } catch {
            // A failed probe must not read as "taken" — that would block a valid
            // handle because the network hiccuped. The insert decides anyway.
            return true
        }
    }

    func updateProfile(_ profile: UserProfile) async throws -> UserProfile {
        do {
            let rows: [UserProfile] = try await client.send(
                .init(
                    method: "PATCH",
                    url: configuration.rest("profiles"),
                    query: [URLQueryItem(name: "id", value: "eq.\(profile.id.uuidString.lowercased())")],
                    body: try SupabaseClient.encoder.encode(ProfileUpdate(profile)),
                    headers: ["Prefer": "return=representation"]
                )
            )
            guard let updated = rows.first else { throw AuthError.underlying("Nothing was updated") }
            return updated
        } catch SupabaseError.conflict {
            throw AuthError.handleTaken(profile.handle)
        } catch let error as SupabaseError {
            throw Self.translate(error)
        }
    }

    func deleteAccount() async throws {
        // One RPC, running as the definer, so `on delete cascade` can do the
        // work in a single statement rather than the client trying to delete
        // its own rows table by table and leaving orphans behind.
        do {
            try await client.send(
                .init(method: "POST", url: configuration.rpc("delete_account"), body: Data("{}".utf8))
            )
        } catch let error as SupabaseError {
            throw Self.translate(error)
        }
        await signOut()
    }

    // MARK: Translation

    private static func translate(_ error: SupabaseError) -> AuthError {
        switch error {
        case .notConfigured:  return .notConfigured
        case .unauthorized:   return .invalidCredentials
        default:              return .underlying(error.description)
        }
    }

    // MARK: Payloads

    private struct Credentials: Encodable {
        let email: String
        let password: String
    }

    /// What sign-up writes over the trigger's placeholders.
    ///
    /// `display_name` goes too, because the trigger had to put *something* in a
    /// NOT NULL column and chose the same generated placeholder as the handle
    /// (`app.handle_new_user`). Leaving it would give every new account a name
    /// like `u5f3a2b9c…` on every screen it appears. The handle is the best
    /// answer available at this point; Settings can change it afterwards.
    private struct HandleClaim: Encodable {
        let handle: String
        let displayName: String

        init(handle: String) {
            self.handle = handle
            self.displayName = handle
        }

        enum CodingKeys: String, CodingKey {
            case handle
            case displayName = "display_name"
        }
    }

    private struct HandleRow: Decodable {
        let handle: String
    }

    private struct ProfileUpdate: Encodable {
        let handle: String
        let displayName: String?
        let bio: String?
        let avatarURL: String?
        let isPrivate: Bool

        init(_ profile: UserProfile) {
            handle = Handle.normalize(profile.handle)
            displayName = profile.displayName
            bio = profile.bio
            avatarURL = profile.avatarURL
            isPrivate = profile.isPrivate
        }

        enum CodingKeys: String, CodingKey {
            case handle
            case displayName = "display_name"
            case bio
            case avatarURL = "avatar_url"
            case isPrivate = "is_private"
        }
    }
}
