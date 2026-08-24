//
//  PublishConsentView.swift
//  Binged
//
//  The question asked once per account: **can other people see this?**
//
//  **It is not a question about uploading, and must never be mistaken for
//  one.** A signed-in user's ranking syncs to their own account either way —
//  that is what makes signing in on a new phone restore it — so an earlier
//  draft of this sheet, which said "nothing has been uploaded yet" and offered
//  "keep it on this device", would now be telling the user something false to
//  win a yes. Sync is disclosed at account creation, where the user decides
//  whether to have an account at all. This screen decides one narrower thing:
//  the audience.
//
//  **It is a question, not an announcement.** Refusing is a full-width button
//  directly under the other one, not a grey link in a corner, and it costs the
//  same single tap. The affirmative keeps the prominent style because it is the
//  action the sheet is *about* — but a sheet whose second option is hard to
//  find is a dialog pretending to be a choice, and this is not that.
//
//  It states a *count*, not a category. "Your library" is a word for something
//  the user cannot check; "51 titles" is a number they can hold against what
//  they remember ranking, which is what makes the answer informed.
//
//  **Swiping it away is allowed**, and records nothing — the sheet returns next
//  launch. Blocking the app until a sharing question is answered would make
//  ranking a film wait on the social layer, which is the one thing Part III is
//  not allowed to do. Nothing is visible to anybody without a yes either way,
//  so refusing to answer is as safe as answering no.
//

import SwiftUI

// MARK: - PublishConsentView

struct PublishConsentView: View {

    /// Watched titles that would be published.
    let publishableCount: Int

    /// Watched titles that cannot be, because they carry no catalog id. Stated
    /// rather than omitted — a count that quietly disagrees with the library
    /// looks like a bug in the app or a lie about the data.
    let unpublishableCount: Int

    /// `true` to publish, `false` to keep everything local.
    let onDecision: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    visibility
                    Divider()
                    reassurance
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { buttons }
            .navigationTitle("Let followers see your ranking?")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titleLine)
                .font(.title3.weight(.semibold))
            Text("Until you say yes, your ranking is visible to you and nobody "
                 + "else. You can change this at any time in Settings.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleLine: String {
        publishableCount == 1
            ? "1 title would become visible to your followers."
            : "\(publishableCount) titles would become visible to your followers."
    }

    private var visibility: some View {
        VStack(alignment: .leading, spacing: 16) {
            row(
                systemImage: "eye",
                title: "What followers see",
                detail: followersDetail
            )
            row(
                systemImage: "eye.slash",
                title: "What nobody else sees",
                detail: stayHereDetail
            )
        }
    }

    /// Built as a `String` rather than inline, so the concatenation is not
    /// part of a view builder the type checker has to solve all at once.
    private var followersDetail: String {
        let threshold = MediaLibraryViewModel.minimumBucketSizeForScore
        let first = "The title, where it sits in its list, and which list — "
        let second = "Liked it, It was fine, Didn't like it. "
        let third = "A score appears only once that list holds \(threshold) titles, "
        let fourth = "the same rule your own screen follows."
        return first + second + third + fourth
    }

    private var stayHereDetail: String {
        let base = "Anything you have not marked as watched. Your account keeps "
            + "your whole library so you can sign in on another device — that "
            + "part is between you and your account."
        guard unpublishableCount > 0 else { return base }
        let extra: String = unpublishableCount == 1
            ? " 1 title never leaves this device at all — the catalog gave it no id."
            : " \(unpublishableCount) titles never leave this device at all — the catalog gave them no id."
        return base + extra
    }

    private var reassurance: some View {
        VStack(alignment: .leading, spacing: 16) {
            row(
                systemImage: "arrow.uturn.backward",
                title: "You can change your mind",
                detail: "Settings can hide everything again, without deleting "
                      + "your account and without losing your ranking."
            )
            row(
                systemImage: "trophy",
                title: "Ranking works either way",
                detail: "Comparing titles never waits on the network, and every "
                      + "screen in the app works signed out."
            )
        }
    }

    private func row(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Buttons

    private var buttons: some View {
        VStack(spacing: 12) {
            Button { onDecision(true) } label: {
                Text("Show my followers").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button { onDecision(false) } label: {
                Text("Keep it private").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Everything publishable") {
    PublishConsentView(publishableCount: 51, unpublishableCount: 0) { _ in }
}

#Preview("Some titles have no id") {
    PublishConsentView(publishableCount: 48, unpublishableCount: 3) { _ in }
}
#endif
