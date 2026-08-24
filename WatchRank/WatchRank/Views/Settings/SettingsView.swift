//
//  SettingsView.swift
//  WatchRank
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

    @State private var exportURL: URL?
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            accountSection
            dataSection
            safetySection
            aboutSection
        }
        .navigationTitle("Settings")
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
                    Button("Sign Out") { Task { await session.signOut() } }
                    Button("Delete Account", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                    .disabled(isDeleting)
                } else {
                    Text("Not signed in.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Deleting your account removes everything you published. "
                     + "It does not touch the rankings stored on this device.")
            }
        }
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

    private var safetySection: some View {
        Section {
            Text("Report content from any post, comment or profile. Reports are "
                 + "reviewed within 24 hours and content that breaks the rules is "
                 + "removed.")
            Text("Blocking someone hides them from you and you from them, "
                 + "immediately.")
            Link("Contact us", destination: URL(string: "mailto:support@watchrank.app")!)
            Link("Terms of Use (EULA)",
                 destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            Link("Privacy Policy", destination: URL(string: "https://watchrank.app/privacy")!)
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
                     + "a fact about two films. WatchRank asks which of two titles "
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
