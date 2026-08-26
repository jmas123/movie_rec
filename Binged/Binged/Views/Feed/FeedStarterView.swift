//
//  FeedStarterView.swift
//  Binged
//
//  What the Following tab shows when it has no posts to show.
//
//  **Why this is not an `EmptyStateView`.** Everywhere else in the app, an
//  empty state is temporary and self-clearing: the watchlist fills the first
//  time you tap Want to Watch, Ranking fills the first time you rank something.
//  The feed is the one surface that cannot fill itself. It is fed entirely by
//  `public.feed`, which is `follows where follower_id = auth.uid()` and nothing
//  else — so a reader who follows nobody sees an empty tab no matter how much
//  they use the app, and the only exit is knowing a handle to search for.
//
//  A symbol and one line of copy is the right treatment for "nothing here yet".
//  It is the wrong treatment for "this feature does not start working until you
//  do a specific thing we have not explained". So this screen does three jobs
//  the one-liner could not:
//
//  1. **Says what will appear here**, concretely, so following someone is a
//     decision with a known payoff rather than a leap.
//  2. **Gives both halves of the bootstrap.** Finding people is only half of
//     it — a graph with no suggestions also needs the reader to be findable, so
//     their own handle is on screen and shareable. Nothing else in the app
//     surfaces it at the moment it is useful.
//  3. **Distinguishes "you follow nobody" from "the people you follow are
//     quiet"**, and shows *who* in the second case — an unexplained empty feed
//     reads as a follow that silently failed.
//
//  It is a `ScrollView` rather than a static stack for a reason that is not
//  layout: `.refreshable` attaches to the nearest scrollable descendant, so the
//  old empty states could not be pulled to refresh. A reader waiting for a
//  friend's first post had no way to ask again.
//

import SwiftUI

// MARK: - FeedStarterView

struct FeedStarterView: View {

    /// Why the feed is empty. Three states with three different fixes — sign
    /// in, follow somebody, or simply wait — which is the whole reason they are
    /// not one "no posts" case.
    enum Reason: Equatable {
        case signedOut
        case followingNobody
        case quiet
    }

    let reason: Reason

    /// The reader's own handle, for the line that tells them what to give a
    /// friend. `nil` signed out, and while the profile is still loading.
    var handle: String?

    /// Who the reader follows. Only populated for `.quiet` — in the other two
    /// states there is nobody to draw.
    var followees: [UserProfile] = []

    var onFindPeople: () -> Void = {}
    var onSignIn: () -> Void = {}
    var onOpenPerson: (UserProfile) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.section) {
                hero
                primaryActions
                if reason == .quiet, !followees.isEmpty { followeeRow }
                if reason != .signedOut { howItWorks }
                if reason == .followingNobody { privateAccountNote }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.section)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text(headline)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)

            Text(subhead)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Spacing.sm)
    }

    private var symbol: String {
        switch reason {
        case .signedOut:       return "person.crop.circle.badge.plus"
        case .followingNobody: return "person.2"
        case .quiet:           return "moon.zzz"
        }
    }

    private var headline: String {
        switch reason {
        case .signedOut:       return "See what your friends are ranking"
        case .followingNobody: return "Your feed starts with one follow"
        case .quiet:           return "Nothing new yet"
        }
    }

    private var subhead: String {
        switch reason {
        case .signedOut:
            return "Sign in to follow people and see the titles they rank, "
                 + "in the order they ranked them."
        case .followingNobody:
            return "This tab shows the people you follow — nothing else goes in "
                 + "it, so it stays empty until you follow somebody."
        case .quiet:
            let count = followees.count
            guard count > 0 else {
                return "Nobody you follow has ranked anything recently."
            }
            return "You follow \(count) \(count == 1 ? "person" : "people"). "
                 + "Their rankings land here as they make them."
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var primaryActions: some View {
        VStack(spacing: Spacing.md) {
            switch reason {
            case .signedOut:
                Button("Sign In", action: onSignIn)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

            case .followingNobody:
                Button {
                    onFindPeople()
                } label: {
                    Label("Find People", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                inviteLink

            case .quiet:
                Button {
                    onFindPeople()
                } label: {
                    Label("Find More People", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                inviteLink
            }
        }
    }

    /// The other half of the bootstrap.
    ///
    /// Shares text rather than a link on purpose: there is no public web
    /// profile to point at — `binged.app` is not a registered domain
    /// (`SupportLinks`) — and a share sheet offering a URL that resolves to
    /// nothing is worse than one that plainly says "look me up under this
    /// name". If a profile page ever exists, this is the one place to change.
    @ViewBuilder
    private var inviteLink: some View {
        if let handle, !handle.isEmpty {
            ShareLink(item: "I'm @\(handle) on Binged. Follow me and see what I'm ranking.") {
                Label("Invite a Friend", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            // Stated as well as shareable: half the time the reader is sitting
            // next to the person they want to be found by, and reading a handle
            // aloud beats opening a share sheet.
            Text("You're @\(handle)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel("Your handle is at \(handle)")
        }
    }

    // MARK: Who you follow

    /// Proof the follows happened. An empty feed with no explanation reads as a
    /// follow that silently failed, and the fix for that is showing the graph
    /// rather than describing it.
    private var followeeRow: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("You follow")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.lg) {
                    ForEach(followees) { person in
                        Button {
                            onOpenPerson(person)
                        } label: {
                            VStack(spacing: Spacing.sm) {
                                PosterView(title: person.name, posterURL: person.avatarURL)
                                    .frame(width: 56, height: 56)
                                    .clipShape(Circle())
                                Text(person.name)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 72)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(person.name), at \(person.handle)")
                        .accessibilityHint("Opens their profile")
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Explainer

    /// What lands here, in the app's own vocabulary. "Ranked #3 of 22 in Liked
    /// it" is the thing this feed can show that a star-rating feed cannot, so
    /// it is worth spelling out before somebody decides the tab is pointless.
    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("What shows up here")
                .font(.headline)

            explainerRow(
                symbol: "trophy",
                title: "Rankings, with their place",
                detail: "Not just a score — where a title landed in their list, "
                      + "and how big that list is."
            )
            explainerRow(
                symbol: "bookmark",
                title: "What they want to watch",
                detail: "Titles they queue up, before they've seen them."
            )
            explainerRow(
                symbol: "bubble.left.and.bubble.right",
                title: "Reactions and comments",
                detail: "React to anything in the feed, or open a post to argue "
                      + "about it properly."
            )
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func explainerRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The one silence this screen cannot otherwise account for.
    ///
    /// `following_of` returns only `state = 'active'` edges, so a request sent
    /// to a private account is invisible to this screen: the reader followed
    /// somebody and still lands on "you follow nobody". Until there is a way to
    /// list outgoing requests, saying so is better than letting it read as a
    /// tap that did not register.
    private var privateAccountNote: some View {
        Text("Asked to follow a private account? Their rankings appear here "
             + "once they accept.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Following nobody") {
    NavigationStack {
        FeedStarterView(reason: .followingNobody, handle: "jude")
            .navigationTitle("Binged")
    }
}

#Preview("Quiet") {
    NavigationStack {
        FeedStarterView(
            reason: .quiet,
            handle: "jude",
            followees: [
                UserProfile(id: UUID(), handle: "amal", displayName: "Amal", isPrivate: false),
                UserProfile(id: UUID(), handle: "rae", displayName: "Rae Ellis", isPrivate: false),
                UserProfile(id: UUID(), handle: "kwan", displayName: "Kwan", isPrivate: true),
            ]
        )
        .navigationTitle("Binged")
    }
}

#Preview("Signed out") {
    NavigationStack {
        FeedStarterView(reason: .signedOut)
            .navigationTitle("Binged")
    }
}
#endif
