//
//  WelcomeView.swift
//  Binged
//
//  The first thirty seconds.
//
//  **Why this exists.** The app had no onboarding of any kind — no first-run
//  flag anywhere in the codebase — and the only explanation of its central
//  mechanic lived in `RankingExplainerView`, at Profile → gear → About → "How
//  ranking works". A new user was asked "Which did you prefer?" with no
//  explanation of why they were being asked, and was never told that a score is
//  deliberately withheld until a list holds five titles.
//
//  The roadmap called this "onboarding-by-emptiness" and it does not survive
//  contact with the comparison flow: empty states can explain *that* there is
//  nothing here, but not *why the app refuses to let you type an 8.4*.
//
//  Deliberately three screens and skippable. This is a ranking app, not a
//  course; anyone who wants to get on with it should be able to.
//

import SwiftUI

// MARK: - WelcomeView

struct WelcomeView: View {

    /// Set once the user has been through — or skipped — this.
    @AppStorage("onboarding.hasSeenWelcome") private var hasSeenWelcome = false

    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private static let pages: [Page] = [
        Page(
            systemImage: "arrow.left.arrow.right",
            title: "You compare. We do the maths.",
            body: "Binged never asks you to invent a number. You say whether "
                + "you liked something, then answer a few “which did you prefer?” "
                + "questions. The score comes out of your answers."
        ),
        Page(
            systemImage: "list.number",
            title: "Films and shows are ranked apart",
            body: "A film is only ever compared against other films, and a show "
                + "against other shows. Each gets its own number one — because "
                + "“is this film better than that series?” is not a question "
                + "worth making you answer."
        ),
        Page(
            systemImage: "lock.open",
            title: "Scores are earned, not given",
            body: "A number from one comparison would be a guess wearing a "
                + "decimal point. Until a list holds "
                + "\(MediaLibraryViewModel.minimumBucketSizeForScore) titles you'll "
                + "see your position instead — “#2 in Liked it” — and the score "
                + "appears once it means something."
        ),
    ]

    private struct Page: Identifiable {
        let systemImage: String
        let title: String
        let body: String
        var id: String { title }
    }

    var body: some View {
        VStack(spacing: Spacing.section) {
            TabView(selection: $page) {
                ForEach(Array(Self.pages.enumerated()), id: \.element.id) { index, item in
                    pageView(item).tag(index)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button(page == Self.pages.count - 1 ? "Start Ranking" : "Next") {
                if page == Self.pages.count - 1 {
                    finish()
                } else {
                    withAnimation { page += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, Spacing.section)

            Button("Skip") { finish() }
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.section)
        .interactiveDismissDisabled()
    }

    private func pageView(_ item: Page) -> some View {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: 0)
            Image(systemName: item.systemImage)
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(item.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(item.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.section)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title). \(item.body)")
    }

    private func finish() {
        hasSeenWelcome = true
        dismiss()
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    WelcomeView()
}
#endif
