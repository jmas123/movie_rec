//
//  UserSearchView.swift
//  Binged
//
//  Finding people by handle or name.
//

import SwiftUI

// MARK: - UserSearchView

struct UserSearchView: View {

    @Environment(SessionViewModel.self) private var session
    @State private var viewModel: UserSearchViewModel

    /// - Parameter rankings: needed only to build the profile this screen
    ///   pushes to. Optional so the screen still renders — and still lets you
    ///   follow people — on a build that has the graph but not the ranking feed.
    init(service: SocialService, rankings: RankingFeedService? = nil) {
        _viewModel = State(initialValue: UserSearchViewModel(service: service))
        self.rankings = rankings
    }

    private let rankings: RankingFeedService?

    var body: some View {
        @Bindable var viewModel = viewModel

        List {
            switch viewModel.phase {
            case .prompt:
                EmptyStateView(
                    systemImage: "person.2",
                    message: "Search for someone by their handle or name.",
                    style: .inline
                )
            case .searching:
                HStack { Spacer(); ProgressView(); Spacer() }
                    .accessibilityLabel("Searching for people")
            case .noResults:
                EmptyStateView(
                    systemImage: "person.fill.questionmark",
                    message: "Nobody matches “\(viewModel.query)”.",
                    style: .inline
                )
            case .error(let message):
                Text(message).font(.callout).foregroundStyle(.red)
            case .results:
                ForEach(viewModel.results) { person in
                    UserRow(
                        profile: person,
                        state: viewModel.state(for: person),
                        onToggle: { Task { await viewModel.toggleFollow(person) } },
                        // Only when there is a profile worth opening. A row
                        // that pushes a screen which cannot load its ranking
                        // is a worse answer than a row that does not push.
                        route: rankings == nil ? nil : PersonRoute(handle: person.handle)
                    )
                }
            }
        }
        .searchable(text: $viewModel.query, prompt: "Handle or name")
        .navigationTitle("Find People")
    }
}

// MARK: - UserRow

struct UserRow: View {

    let profile: UserProfile
    var state: FollowState = .none
    var onToggle: (() -> Void)?
    /// Where tapping the person's name goes, or `nil` for a row that only
    /// offers Follow.
    var route: PersonRoute?

    var body: some View {
        HStack(spacing: Spacing.md) {
            // The identity is the link and the button is the button. Wrapping
            // the whole row in a NavigationLink would swallow Follow, which is
            // the action people came here to press.
            identity
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(profile.name), @\(profile.handle)")

            Spacer(minLength: Spacing.sm)

            if let onToggle, state.isActionable {
                Button(state.actionTitle, action: onToggle)
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel("\(state.actionTitle) \(profile.name)")
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    @ViewBuilder
    private var identity: some View {
        if let route {
            NavigationLink(value: route) { identityLabel }
                .buttonStyle(.plain)
                .accessibilityHint("Opens their profile")
        } else {
            identityLabel
        }
    }

    private var identityLabel: some View {
        HStack(spacing: Spacing.md) {
            PosterView(title: profile.name, posterURL: profile.avatarURL)
                .frame(width: 40, height: 40)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.body.weight(.semibold))
                Text("@\(profile.handle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    NavigationStack {
        UserSearchView(service: MockSocialService(people: [
            UserProfile(id: UUID(), handle: "alex", displayName: "Alex", bio: nil,
                        avatarURL: nil, isPrivate: false, createdAt: .now),
            UserProfile(id: UUID(), handle: "sam", displayName: "Sam", bio: nil,
                        avatarURL: nil, isPrivate: true, createdAt: .now),
        ]))
        .environment(SessionViewModel(service: MockAuthService()))
    }
}
#endif
