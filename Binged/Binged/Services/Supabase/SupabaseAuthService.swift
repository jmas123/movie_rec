//
//  SupabaseAuthService.swift
//  Binged
//
//  Accounts, against GoTrue and the `profiles` table.
//

import Foundation

// MARK: - SupabaseAuthService

final class SupabaseAuthService: AuthService, @unchecked Sendable {

    private let client: SupabaseClient
    private let configuration: SupabaseConfiguration
    private let pendingHandles: PendingHandleStore

    init(
        client: SupabaseClient,
        configuration: SupabaseConfiguration,
        pendingHandles: PendingHandleStore = UserDefaultsPendingHandleStore()
    ) {
        self.client = client
        self.configuration = configuration
        self.pendingHandles = pendingHandles
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

        // No session means the project has email confirmation switched on: the
        // account exists, but nobody is signed in until the link is clicked.
        // This used to surface as `underlying("No session returned")`, which
        // reads to the user as a bug rather than as an instruction.
        //
        // The handle needs a session to claim, so there is nothing to claim it
        // with yet. Park it and finish the job at the first sign-in rather than
        // discarding it — the account would otherwise arrive wearing the
        // trigger's placeholder for good. See `PendingHandleStore`.
        guard let session = token.session else {
            pendingHandles.record(handle: normalized, for: email)
            throw AuthError.emailConfirmationRequired
        }
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
        return await claimPendingHandleIfNeeded(on: profile, email: email)
    }

    /// Finishes a sign-up that email confirmation interrupted.
    ///
    /// Runs on every sign-in and does nothing at all in the normal case: it
    /// needs both a parked handle for *this* address and a profile still
    /// wearing the placeholder computed for *this* user id. Either one missing
    /// means there is nothing outstanding.
    ///
    /// **It never fails the sign-in.** The credentials were already accepted;
    /// refusing to let somebody in because the handle they picked three days
    /// ago was taken in the meantime would be a worse outcome than the one this
    /// is fixing. A lost race leaves the placeholder in place, and
    /// `EditProfileView` offers a handle field for exactly that state — which
    /// is the only route out of it, since handles are otherwise not editable.
    private func claimPendingHandleIfNeeded(
        on profile: UserProfile,
        email: String
    ) async -> UserProfile {
        guard let pending = pendingHandles.pendingHandle(for: email) else { return profile }
        guard Handle.isPlaceholder(profile.handle, for: profile.id) else {
            // The handle landed some other way. Nothing owed; stop asking.
            pendingHandles.clear()
            return profile
        }

        do {
            let claimed = try await claimHandle(pending, for: profile.id)
            pendingHandles.clear()
            AppLog.network.info("Claimed a handle parked through email confirmation.")
            return claimed
        } catch AuthError.handleTaken {
            // Gone for good — retrying will never succeed, so stop carrying it.
            pendingHandles.clear()
            AppLog.network.notice("Parked handle was taken before it could be claimed.")
            return profile
        } catch {
            // Transient. Keep the record and try again at the next sign-in.
            AppLog.network.error("Could not claim parked handle: \(error.localizedDescription, privacy: .public)")
            return profile
        }
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

    // MARK: Password reset

    func sendPasswordReset(email: String) async throws {
        do {
            try await client.send(
                .init(
                    method: "POST",
                    url: configuration.auth("recover"),
                    body: try SupabaseClient.encoder.encode(["email": email]),
                    anonymous: true
                )
            )
        } catch let error as SupabaseError {
            throw Self.translate(error)
        }
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
        /// **Not optional, though `UserProfile.displayName` is.**
        ///
        /// The client model treats nil as "no name — fall back to the handle"
        /// (`UserProfile.name`). The column disagrees: `display_name` is NOT
        /// NULL with a `length between 1 and 50` check, so neither `null` nor
        /// `""` is storable.
        ///
        /// Declared optional, the *synthesized* encoder resolved that
        /// disagreement by `encodeIfPresent` — a nil name dropped the key
        /// entirely, PostgREST patched the columns that remained, and the old
        /// display name stayed on the server. So clearing the field in Edit
        /// Profile appeared to work, dismissed the sheet, and changed nothing;
        /// the old name came back the next time the profile was fetched.
        ///
        /// Silent rather than dangerous — the rest of the body still saved, so
        /// this never cost anybody their privacy setting — but wrong, and
        /// invisible precisely because it failed by omission.
        ///
        /// Resolved the way the server itself resolves it: `app.handle_new_user`
        /// coalesces an empty name to the handle, so an emptied name lands back
        /// where a brand-new account starts. Non-optional here on purpose, so
        /// the fallback cannot be re-lost to `encodeIfPresent`.
        let displayName: String

        let bio: String?
        let avatarURL: String?
        let isPrivate: Bool

        init(_ profile: UserProfile) {
            let normalized = Handle.normalize(profile.handle)
            handle = normalized
            let trimmed = profile.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            displayName = trimmed.isEmpty ? normalized : trimmed
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
