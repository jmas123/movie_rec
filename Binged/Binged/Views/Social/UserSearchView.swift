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

        UserSearchResults(viewModel: viewModel, rankings: rankings)
            // `.always`, not the default `.automatic`. Automatic sets
            // `hidesSearchBarWhenScrolling`, which starts the field off screen
            // and waits for a scroll to reveal it — and the screen you arrive
            // on is a prompt with nothing to scroll, so on a search screen it
            // hides the one control the screen exists for. The Search tab has
            // always passed `.always`; this one did not.
            .searchable(
                text: $viewModel.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Handle or name"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Find People")
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - UserSearchResults

/// The phase switch and the results list, without a search field of its own.
///
/// Split out because the Search tab's People scope renders exactly this under
/// its own `.searchable`, and two copies of a five-case phase switch would
/// drift — one of them would keep the inline empty states that made this screen
/// look broken, or miss the next state added to the view model.
///
/// Only `.results` is a list. The other phases are whole-screen states, and
/// rendering them as a single `List` row put a grey inline card and a bare
/// spinner inside an inset list with separators.
struct UserSearchResults: View {

    let viewModel: UserSearchViewModel
    /// Needed only to build the profile a row pushes to. Without it rows still
    /// offer Follow, they just do not push.
    var rankings: RankingFeedService?

    var body: some View {
        switch viewModel.phase {
        case .prompt:
            EmptyStateView(
                systemImage: "person.2",
                message: "Search for someone by their handle or name."
            )
            .frame(maxHeight: .infinity)

        case .searching:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Searching for people")

        case .noResults:
            EmptyStateView(
                systemImage: "person.fill.questionmark",
                message: "Nobody matches \u{201C}\(viewModel.query)\u{201D}."
            )
            .frame(maxHeight: .infinity)

        case .error(let message):
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                message: message,
                actionTitle: "Try again",
                action: { viewModel.retry() }
            )
            .frame(maxHeight: .infinity)

        case .results:
            List(viewModel.results) { person in
                UserRow(
                    profile: person,
                    state: viewModel.state(for: person),
                    // Inert until the real relationship has been read. The
                    // button used to say "Follow" for everyone the instant
                    // results landed, including people already followed and
                    // requests already sent.
                    isStateKnown: viewModel.isStateKnown(for: person),
                    onToggle: { Task { await viewModel.toggleFollow(person) } },
                    // Only when there is a profile worth opening. A row that
                    // pushes a screen which cannot load its ranking is a worse
                    // answer than a row that does not push.
                    route: rankings == nil ? nil : PersonRoute(handle: person.handle)
                )
            }
            .listStyle(.plain)
            // Runs when the list appears and again every time it comes back,
            // which is what a push and a pop are. Without it a row kept the
            // state it was seeded with, so following somebody from *their
            // profile* — a different screen, a different view model — left this
            // row still offering Follow after the pop.
            .task { await viewModel.refreshStates() }
        }
    }
}

// MARK: - UserRow

struct UserRow: View {

    let profile: UserProfile
    var state: FollowState = .none

    /// Whether `state` is a read answer rather than a placeholder. Defaults to
    /// true for the callers that have no asynchronous state to wait for — the
    /// follow-request inbox and the follower lists, which are handed a
    /// relationship along with the person.
    var isStateKnown: Bool = true

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
                    .disabled(!isStateKnown)
                    .opacity(isStateKnown ? 1 : 0.4)
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
