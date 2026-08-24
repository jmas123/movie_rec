//
//  SettingsView.swift
//  Binged
//
//  Account, data, and the safety obligations that come with user-generated
//  content.
//
//  The account/data distinction is the load-bearing idea here: deleting an
//  account removes what was *published*, and leaves the library on the device
//  untouched. Those are two different things a user can want, and conflating
//  them would delete something nobody asked to lose.
//

import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {

    @Environment(MediaLibraryViewModel.self) private var library
    @Environment(SessionViewModel.self) private var session
    /// Absent on a build with no server. The publishing section then has
    /// nothing true to say and does not appear.
    @Environment(SyncEngine.self) private var sync: SyncEngine?

    /// Needed only by the blocked-accounts list. Absent on a build with no
    /// server, where there is nothing to have blocked.
    var socialService: SocialService?

    @State private var exportURL: URL?
    @State private var showDeleteConfirmation = false
    @State private var showUnpublishConfirmation = false
    @State private var isDeleting = false
    @State private var isWithdrawing = false
    /// Set when consent was withdrawn but the removal did not land. Publishing
    /// is off either way; what is already on the server is not, and the user is
    /// owed a way to try again rather than a promise that something will.
    @State private var removalFailed = false
    @State private var errorMessage: String?
    @State private var showSignIn = false

    var body: some View {
        List {
            accountSection
            publishingSection
            dataSection
            safetySection
            aboutSection
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showSignIn) { SignInView() }
        .sheet(item: $exportURL) { url in
            ShareLink(item: url) { Label("Share export", systemImage: "square.and.arrow.up") }
                .presentationDetents([.medium])
        }
        .alert("Delete account?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await deleteAccount() } }
        } message: {
            Text("This permanently deletes your profile, published rankings, "
                 + "comments and follows. **Your library on this device is kept** "
                 + "and stays usable signed out.")
        }
        .alert("Hide your ranking?", isPresented: $showUnpublishConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Hide", role: .destructive) { Task { await stopPublishing() } }
        } message: {
            Text("Your followers will no longer see any of your rankings. "
                 + "**Nothing is deleted** — your account keeps your library, so "
                 + "signing in on another device still restores it.")
        }
        .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Account

    @ViewBuilder
    private var accountSection: some View {
        if session.isAvailable {
            Section {
                if let profile = session.profile {
                    LabeledContent("Signed in as", value: "@\(profile.handle)")
                    NavigationLink("Edit Profile") { EditProfileView() }
                    Button("Sign Out") { Task { await session.signOut() } }
                    Button("Delete Account", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .disabled(isDeleting)
                    .accessibilityHint("Permanently deletes your profile and "
                                       + "everything you published. Your library "
                                       + "on this device is kept.")
                } else {
                    // Was a dead `Text`. Settings is reachable from a fresh
                    // install when the Profile screen is not, so this was the
                    // last place a new user could have found an account and it
                    // offered them nothing.
                    Button("Sign In or Create Account") { showSignIn = true }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Deleting your account removes everything you published. "
                     + "It does not touch the rankings stored on this device.")
            }
        }
    }

    // MARK: Publishing

    /// Who can see the ranking, and what is still on its way up.
    ///
    /// **This section is about an audience, not about a network.** The library
    /// syncs to the account regardless; saying "publishing: off" must not be
    /// read as "nothing is uploaded", so the footer says which is which.
    ///
    /// The unpublishable count is stated rather than omitted on purpose: a
    /// screen that says "48 titles" to somebody with 51 in their library reads
    /// as a bug or a lie, and the truth — the catalog never gave those three an
    /// id — is a sentence long.
    @ViewBuilder
    private var publishingSection: some View {
        if let sync, session.isSignedIn {
            Section {
                LabeledContent(
                    "Visible to followers",
                    value: sync.consentDecision == true ? "Yes" : "No"
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(sync.consentDecision == true
                                    ? "Your ranking is visible to followers"
                                    : "Your ranking is not visible to anyone")
                if sync.pendingCount > 0 {
                    LabeledContent("Waiting to sync", value: bucketsPhrase(sync.pendingCount))
                }

                if sync.consentDecision == true {
                    LabeledContent("Titles they can see", value: "\(sync.publishableCount)")
                    Button("Hide My Ranking", role: .destructive) {
                        showUnpublishConfirmation = true
                    }
                    .disabled(isWithdrawing)
                } else {
                    Button("Show My Followers") { Task { await startPublishing() } }
                    if removalFailed {
                        Button("Retry Hiding", role: .destructive) {
                            Task { await removePublished() }
                        }
                        .disabled(isWithdrawing)
                    }
                }
            } header: {
                Text("Sharing")
            } footer: {
                Text(publishingFooter)
            }
        }
    }

    private var publishingFooter: String {
        guard let sync else { return "" }
        let shared = sync.consentDecision == true
            ? "Followers see the title, its position and its list. A score "
                + "appears only once a list holds "
                + "\(MediaLibraryViewModel.minimumBucketSizeForScore) titles."
            : "Nobody else can see your ranking. You can turn this on at any time."
        // Said in both states, because "no" must not be heard as "nothing is
        // stored". The account holds the library either way; that is what makes
        // signing in on another device restore it.
        let sync_ = " Your account keeps your library either way, so signing in "
            + "on another device restores it."
        let base = shared + sync_
        guard sync.unpublishableCount > 0 else { return base }
        let count = sync.unpublishableCount
        let extra = count == 1
            ? " 1 title stays on this device only — the catalog gave it no id."
            : " \(count) titles stay on this device only — the catalog gave them no id."
        return base + extra
    }

    private func bucketsPhrase(_ count: Int) -> String {
        count == 1 ? "1 list" : "\(count) lists"
    }

    // MARK: Data

    private var dataSection: some View {
        Section {
            Button("Export My Data") {
                do {
                    exportURL = try LibraryExport.writeToTemporaryFile(items: library.allItems)
                } catch {
                    errorMessage = "Could not build the export."
                }
            }
            LabeledContent("Titles on this device", value: "\(library.allItems.count)")
        } header: {
            Text("Your data")
        } footer: {
            Text("A JSON file of everything this app knows about your taste, "
                 + "including titles that were never published.")
        }
    }

    // MARK: Safety

    /// The copy here describes controls that must actually exist. It previously
    /// promised reporting "from any post, comment or profile" while the only
    /// report UI sat inside a screen nothing opened — so it named the surfaces
    /// that are genuinely wired, and stops there.
    private var safetySection: some View {
        Section {
            Text("Touch and hold any post to report or block. Inside a post, "
                 + "swipe a comment to report it or block whoever wrote it. "
                 + "Reports are reviewed within 24 hours and content that breaks "
                 + "the rules is removed.")
            Text("Blocking someone hides them from you and you from them, "
                 + "immediately.")

            if session.isSignedIn {
                NavigationLink("Blocked Accounts") {
                    BlockedAccountsView(service: socialService)
                }
            }

            // Rendered only if they resolve — see SupportLinks. These were three
            // force-unwrapped literals, and a typo in any of them crashed this
            // screen.
            if let supportEmail = SupportLinks.supportEmail {
                Link("Contact us", destination: supportEmail)
            }
            if let terms = SupportLinks.termsOfUse {
                Link("Terms of Use (EULA)", destination: terms)
            }
            if let privacy = SupportLinks.privacyPolicy {
                Link("Privacy Policy", destination: privacy)
            }
        } header: {
            Text("Safety")
        } footer: {
            Text("We do not tolerate abusive content or behaviour.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.shortVersion)
            NavigationLink("How ranking works") { RankingExplainerView() }
        }
    }

    // MARK: Actions

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        // The answer belongs to the account. Forgetting it *before* the account
        // goes is deliberate: afterwards there is no user id to key it to, and
        // a stale grant would be found by whoever signs in next.
        sync?.forgetConsent()
        await session.deleteAccount()
        if let error = session.lastError { errorMessage = error }
    }

    private func startPublishing() async {
        await applyVisibility(true)
    }

    /// Withdraws consent and hides what is already up there.
    ///
    /// One action, not two: an answer that left the old rows visible would be a
    /// switch that does not do what it says.
    private func stopPublishing() async {
        await applyVisibility(false)
    }

    private func applyVisibility(_ granted: Bool) async {
        guard let sync else { return }
        isWithdrawing = true
        defer { isWithdrawing = false }
        do {
            try await sync.record(consent: granted)
            removalFailed = false
        } catch {
            // The local answer is saved; the server's copy is not. Say exactly
            // that rather than promising a retry nothing performs.
            removalFailed = !granted
            errorMessage = granted
                ? "Saved, but your followers may not see your ranking yet. "
                    + "Try again from Settings when you are online."
                : "Saved on this device, but your ranking may still be visible "
                    + "to followers. Try again from Settings when you are online."
        }
    }

    /// Retries the hide on its own, for when the flip failed but the answer
    /// stands.
    private func removePublished() async {
        guard let sync else { return }
        isWithdrawing = true
        defer { isWithdrawing = false }
        do {
            try await sync.reapplyVisibility()
            removalFailed = false
        } catch {
            errorMessage = "Still could not reach the server. Your ranking may "
                + "remain visible to followers until this succeeds."
        }
    }
}

// MARK: - RankingExplainerView

struct RankingExplainerView: View {
    var body: some View {
        List {
            Section("Why you never type a number") {
                Text("A number you type is a guess about a scale. A comparison is "
                     + "a fact about two films. Binged asks which of two titles "
                     + "you preferred, and works out the number from where things "
                     + "land.")
            }
            Section("Where the score comes from") {
                Text("Each sentiment owns a range: Liked it is 6.8–10, It was fine "
                     + "is 3.4–6.7, Didn't like it is 0–3.3. Your position inside "
                     + "that range is decided by your own comparisons.")
                Text("Scores are shown only once a list holds at least "
                     + "\(MediaLibraryViewModel.minimumBucketSizeForScore) titles. "
                     + "Before that a number would imply a precision the app has "
                     + "not earned, so it shows your position instead.")
            }
            Section("What other people see") {
                Text("Only what you publish, and only under an account you chose "
                     + "to create. The same rule applies to their scores as to "
                     + "yours: a number from a short list is hidden for them too.")
            }
        }
        .navigationTitle("How ranking works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Helpers

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

extension Bundle {
    var shortVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }
}
