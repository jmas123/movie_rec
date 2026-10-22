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
    /// Absent on a build with no server. The sharing section then has nothing
    /// true to say and does not appear.
    @Environment(SyncEngine.self) private var sync: SyncEngine?
    @Environment(LibraryRestorer.self) private var restorer: LibraryRestorer?

    /// Needed only by the blocked-accounts list. Absent on a build with no
    /// server, where there is nothing to have blocked.
    var socialService: SocialService?

    @State private var exportURL: URL?
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var showSignIn = false

    var body: some View {
        List {
            accountSection
            restoreSection
            sharingSection
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

    // MARK: Sharing

    /// Who can see the ranking, and what is still on its way up.
    ///
    /// **This section is about an audience, not about a network.** The library
    /// syncs to the account regardless; a private account is not an unsynced
    /// one, so the footer says which is which.
    ///
    /// **It reports the rule rather than offering a second switch.** Visibility
    /// is `profiles.is_private` and nothing else — the same setting that governs
    /// the feed, the profile and follow requests — so the control lives once, in
    /// Edit Profile, and this section links to it. A separate "share my ranking"
    /// toggle here is exactly what was removed: two switches for one question
    /// left accounts invisible to each other with no visible reason why.
    ///
    /// The unpublishable count is stated rather than omitted on purpose: a
    /// screen that says "48 titles" to somebody with 51 in their library reads
    /// as a bug or a lie, and the truth — the catalog never gave those three an
    /// id — is a sentence long.
    @ViewBuilder
    private var sharingSection: some View {
        if let sync, session.isSignedIn {
            Section {
                LabeledContent("Your ranking", value: audience)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(isPrivateAccount
                                        ? "Your ranking is visible to your followers"
                                        : "Your ranking is visible to anyone on Binged")

                LabeledContent("Titles others can see", value: "\(sync.publishableCount)")

                if sync.unpublishableCount > 0 {
                    LabeledContent(
                        "Not on your account",
                        value: "\(sync.unpublishableCount)"
                    )
                }

                if sync.pendingCount > 0 {
                    LabeledContent("Waiting to sync", value: bucketsPhrase(sync.pendingCount))
                }

                // Named for what it changes rather than for where it goes:
                // "Edit Profile" already appears in the Account section, and a
                // second row with the same label reads as a duplicate rather
                // than as the answer to the row above it.
                NavigationLink("Account Privacy") { EditProfileView() }
            } header: {
                Text("Sharing")
            } footer: {
                Text(sharingFooter)
            }
        }
    }

    private var isPrivateAccount: Bool { session.profile?.isPrivate == true }

    private var audience: String {
        isPrivateAccount ? "Followers only" : "Anyone on Binged"
    }

    private var sharingFooter: String {
        let who = isPrivateAccount
            ? "Your account is private, so only people whose follow request you "
                + "have accepted can see your ranking."
            : "Your account is public, so anyone signed in to Binged can see your "
                + "ranking. Turn on Private account in Edit Profile to limit it to "
                + "followers you approve."
        // Said in both states, because "followers only" must not be heard as
        // "nothing is stored". The account holds the library either way; that is
        // what makes signing in on another device restore it.
        let base = who
            + " They see the title, its position and its list — a score appears "
            + "only once a list holds "
            + "\(MediaLibraryViewModel.minimumBucketSizeForScore) titles. Either "
            + "way your ranking is saved to your account, which is what restores "
            + "it when you sign in on another device."

        guard let sync, sync.unpublishableCount > 0 else { return base }
        let count = sync.unpublishableCount
        return base + (count == 1
            ? " 1 title stays on this device only — the catalog gave it no id."
            : " \(count) titles stay on this device only — the catalog gave them no id.")
    }

    /// What the account has given *back* to this device.
    ///
    /// Exists because a failed restore was previously invisible: `lastError` was
    /// set and rendered nowhere, so "we could not reach your account" looked
    /// exactly like "your account is empty" — the confusion
    /// `LibraryRestoreService` throws rather than returning `[]` to avoid, undone
    /// at the last step by having nowhere to say so.
    ///
    /// Only shown when there is something to report. A device that restored
    /// cleanly and can sync everything says nothing, because there is nothing a
    /// user needs to do.
    @ViewBuilder
    private var restoreSection: some View {
        if let restorer, session.isSignedIn, restorer.lastError != nil || restorer.unsyncableCount > 0 {
            Section {
                if let error = restorer.lastError {
                    Text(error)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await restorer.restore(force: true) } }
                }

                if restorer.unsyncableCount > 0 {
                    LabeledContent(
                        "Staying on this device",
                        value: "\(restorer.unsyncableCount) \(restorer.unsyncableCount == 1 ? "title" : "titles")"
                    )
                }
            } header: {
                Text("Your library")
            } footer: {
                // Two different things, deliberately not merged: one is a
                // failure the user can retry, the other is a permanent property
                // of titles the catalogue could not identify.
                Text(restorer.lastError != nil
                     ? "Your library on this device is unchanged. Nothing has been lost."
                     : "These titles have no catalogue entry, so they cannot be saved to "
                       + "your account and will not appear on your other devices.")
            }
        }
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
        await session.deleteAccount()
        if let error = session.lastError { errorMessage = error }
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
