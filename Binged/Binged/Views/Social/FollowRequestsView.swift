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

import SwiftUI

// MARK: - FollowRequestsView

struct FollowRequestsView: View {

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
                EmptyStateView(
                    systemImage: "tray",
                    message: "No requests waiting.",
                    style: .inline
                )
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
#Preview {
    NavigationStack {
        FollowRequestsView(service: MockSocialService(people: [
            UserProfile(id: UUID(), handle: "sam", displayName: "Sam", bio: nil,
                        avatarURL: nil, isPrivate: false, createdAt: .now),
        ]))
    }
}
#endif
