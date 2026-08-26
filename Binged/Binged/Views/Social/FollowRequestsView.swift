//
//  FollowRequestsView.swift
//  Binged
//
//  Requests to follow a private account.
//
//  **Why this is not optional polish.** `UserProfile.isPrivate` exists, RLS
//  enforces it, `follow` returns `.pending` against a private account, and
//  `pendingRequests` / `acceptRequest` / `rejectRequest` were all implemented
//  and had no caller anywhere in the app. The effect was that a private account
//  could accumulate requests it could never answer — the privacy setting was a
//  one-way door that locked the owner out of their own follower list.
//
//  **Why the empty state names the account's privacy setting.** A follow
//  request only exists for a private account: `app.force_follow_state` reads
//  `profiles.is_private` and writes `active` for everybody else, so on a public
//  account nobody ever asks and this list is empty *by design and forever*. The
//  screen used to answer both situations with "No requests waiting", which is
//  the same sentence for "nobody has asked yet" and "nobody will ever ask,
//  because of a setting two screens away". Somebody waiting on a request that
//  the server decided never to create has no way to tell those apart, and the
//  natural conclusion is that the feature is broken.
//

import SwiftUI

// MARK: - FollowRequestsView

struct FollowRequestsView: View {

    /// Read for one thing: whether this account is private, which decides
    /// whether an empty inbox is a wait or a permanent state.
    @Environment(SessionViewModel.self) private var session

    @State private var viewModel: FollowRequestsViewModel
    let rankings: RankingFeedService?

    init(service: SocialService?, rankings: RankingFeedService? = nil) {
        _viewModel = State(initialValue: FollowRequestsViewModel(service: service))
        self.rankings = rankings
    }

    var body: some View {
        List {
            switch viewModel.phase {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }
                    .accessibilityLabel("Loading follow requests")
            case .empty:
                emptyState
            case .error(let message):
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    message: message,
                    style: .inline,
                    actionTitle: "Try again",
                    action: { Task { await viewModel.load() } }
                )
            case .requests:
                ForEach(viewModel.requests) { person in
                    row(for: person)
                }
            }
        }
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load() }
        .alert("Something went wrong", isPresented: errorPrompt) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.lastError ?? "")
        }
        .task { await viewModel.load() }
    }

    /// Two different emptinesses, told apart by the one setting that decides
    /// whether a request can exist at all.
    @ViewBuilder
    private var emptyState: some View {
        if session.profile?.isPrivate == true {
            EmptyStateView(
                systemImage: "tray",
                message: "No requests waiting. You'll see people here when they "
                       + "ask to follow you.",
                style: .inline
            )
        } else {
            VStack(alignment: .leading, spacing: Spacing.md) {
                EmptyStateView(
                    systemImage: "lock.open",
                    message: "Your account is public, so nobody has to ask — "
                           + "people can follow you straight away.",
                    style: .inline
                )
                // The setting is two screens away and is the only thing that
                // makes this list capable of filling. Offer it here rather than
                // describing where it lives.
                NavigationLink {
                    EditProfileView()
                } label: {
                    Label("Turn on Private account", systemImage: "lock")
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    private func row(for person: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            UserRow(
                profile: person,
                route: rankings == nil ? nil : PersonRoute(handle: person.handle)
            )

            HStack(spacing: Spacing.md) {
                Spacer()
                Button("Decline") { Task { await viewModel.reject(person) } }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Decline \(person.name)")

                Button("Accept") { Task { await viewModel.accept(person) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Accept \(person.name)")
            }
            .font(.caption.weight(.semibold))
            .disabled(viewModel.inFlight.contains(person.id))
        }
        .padding(.vertical, Spacing.xs)
    }

    private var errorPrompt: Binding<Bool> {
        Binding(
            get: { viewModel.lastError != nil },
            set: { if !$0 { viewModel.clearError() } }
        )
    }
}

// MARK: - Previews

#if DEBUG
#Preview("With requests") {
    NavigationStack {
        FollowRequestsView(service: MockSocialService(people: [
            UserProfile(id: UUID(), handle: "sam", displayName: "Sam", bio: nil,
                        avatarURL: nil, isPrivate: false, createdAt: .now),
        ]))
    }
    .environment(SessionViewModel(service: MockAuthService()))
}

#Preview("Empty, public account") {
    NavigationStack {
        FollowRequestsView(service: MockSocialService())
    }
    .environment(SessionViewModel(service: MockAuthService()))
}
#endif
