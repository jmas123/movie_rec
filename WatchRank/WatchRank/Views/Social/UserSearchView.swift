//
//  UserSearchView.swift
//  WatchRank
//
//  Finding people by handle or name.
//

import SwiftUI

// MARK: - UserSearchView

struct UserSearchView: View {

    @Environment(SessionViewModel.self) private var session
    @State private var viewModel: UserSearchViewModel

    init(service: SocialService) {
        _viewModel = State(initialValue: UserSearchViewModel(service: service))
    }

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
                        onToggle: { Task { await viewModel.toggleFollow(person) } }
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

    var body: some View {
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

            Spacer(minLength: Spacing.sm)

            if let onToggle, state.isActionable {
                Button(state.actionTitle, action: onToggle)
                    .buttonStyle(.bordered)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name), @\(profile.handle), \(state.actionTitle)")
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
