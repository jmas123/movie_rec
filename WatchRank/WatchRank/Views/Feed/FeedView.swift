//
//  FeedView.swift
//  WatchRank
//
//  What the people you follow have been ranking.
//

import SwiftUI

// MARK: - FeedView

struct FeedView: View {

    @State private var viewModel: FeedViewModel
    var onFindPeople: () -> Void = {}
    var onSignIn: () -> Void = {}

    /// Kept, not just handed to the view model, so the load can be keyed on it.
    private let isSignedIn: () -> Bool

    init(
        service: FeedService?,
        social: SocialService?,
        isSignedIn: @escaping () -> Bool,
        viewerID: @escaping () -> UUID? = { nil },
        onFindPeople: @escaping () -> Void = {},
        onSignIn: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: FeedViewModel(
            service: service, social: social, isSignedIn: isSignedIn, viewerID: viewerID
        ))
        self.isSignedIn = isSignedIn
        self.onFindPeople = onFindPeople
        self.onSignIn = onSignIn
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .loading:
                ProgressView()
                    .accessibilityLabel("Loading your feed")
            case .signedOut:
                EmptyStateView(
                    systemImage: "person.crop.circle.badge.plus",
                    message: "Sign in to see what the people you follow are ranking.",
                    actionTitle: "Sign In",
                    action: onSignIn
                )
            case .followingNobody:
                EmptyStateView(
                    systemImage: "person.2",
                    message: "You're not following anyone yet.",
                    actionTitle: "Find People",
                    action: onFindPeople
                )
            case .quiet:
                EmptyStateView(
                    systemImage: "moon.zzz",
                    message: "Nothing new from the people you follow. Check back later."
                )
            case .error(let message):
                EmptyStateView(systemImage: "exclamationmark.triangle", message: message)
            case .posts:
                list
            }
        }
        // Keyed on the session, not fired once. Sign-in is restored
        // asynchronously at launch, so a feed loaded a moment too early answers
        // for a signed-out reader and would otherwise sit there telling a
        // signed-in user to sign in until they thought to pull to refresh.
        .task(id: isSignedIn()) { await viewModel.refresh() }
        .refreshable { await viewModel.refresh() }
    }

    private var list: some View {
        List {
            ForEach(viewModel.posts) { post in
                FeedPostCard(post: post) {
                    Task { await viewModel.toggleReaction(post) }
                }
                .onAppear {
                    if post.id == viewModel.posts.last?.id {
                        Task { await viewModel.loadMore() }
                    }
                }
            }
            if viewModel.isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .accessibilityLabel("Loading more posts")
            }
        }
        .listStyle(.plain)
    }
}
