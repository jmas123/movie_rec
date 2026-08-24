//
//  FeedView.swift
//  Binged
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

    /// Kept so a tapped post can be opened. `PostDetailView` builds its own
    /// view model and needs both.
    private let service: FeedService?
    private let social: SocialService?
    /// Only used to decide whether tapping an author leads anywhere.
    private let rankings: RankingFeedService?
    private let viewerID: () -> UUID?

    @State private var openPost: FeedPost?
    @State private var openPerson: PersonRoute?
    @State private var reportTarget: ReportTarget?
    @State private var blockCandidate: FeedPost?

    init(
        service: FeedService?,
        social: SocialService?,
        rankings: RankingFeedService? = nil,
        isSignedIn: @escaping () -> Bool,
        viewerID: @escaping () -> UUID? = { nil },
        onFindPeople: @escaping () -> Void = {},
        onSignIn: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: FeedViewModel(
            service: service, social: social, isSignedIn: isSignedIn, viewerID: viewerID
        ))
        self.isSignedIn = isSignedIn
        self.service = service
        self.social = social
        self.rankings = rankings
        self.viewerID = viewerID
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
        .navigationDestination(item: $openPost) { post in
            if let service {
                PostDetailView(
                    post: post, service: service, viewerID: viewerID(), social: social
                )
            }
        }
        .navigationDestination(item: $openPerson) { route in
            if let social, let rankings {
                UserProfileView(handle: route.handle, social: social, rankings: rankings)
            }
        }
        .sheet(item: $reportTarget) { target in
            ReportSheet(target: target) { reason, note in
                Task { await viewModel.report(target, reason: reason, note: note) }
            }
        }
        .alert("Block this person?", isPresented: blockPrompt) {
            Button("Cancel", role: .cancel) { blockCandidate = nil }
            Button("Block", role: .destructive) {
                if let post = blockCandidate {
                    Task { await viewModel.block(post) }
                }
                blockCandidate = nil
            }
        } message: {
            Text("You will not see \(blockCandidate?.authorName ?? "them") again, "
                 + "and they will not see you. Any follow between you is removed.")
        }
        .alert("Something went wrong", isPresented: errorPrompt) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.lastError ?? "")
        }
    }

    // MARK: Alert bindings

    private var blockPrompt: Binding<Bool> {
        Binding(get: { blockCandidate != nil }, set: { if !$0 { blockCandidate = nil } })
    }

    private var errorPrompt: Binding<Bool> {
        Binding(get: { viewModel.lastError != nil }, set: { if !$0 { viewModel.clearError() } })
    }

    private var list: some View {
        List {
            ForEach(viewModel.posts) { post in
                FeedPostCard(
                    post: post,
                    onReact: { Task { await viewModel.toggleReaction(post) } },
                    // `onOpenActor` existed and was never supplied, so the
                    // header button disabled itself on every row ever drawn.
                    onOpenActor: rankings == nil ? nil : { openPerson = PersonRoute(handle: post.authorHandle) },
                    onOpenComments: { openPost = post }
                )
                // Report and block sit on the row itself, not only inside the
                // post. Guideline 1.2 wants them reachable wherever another
                // person's content appears, and the feed is that surface.
                .contextMenu {
                    Button { openPost = post } label: {
                        Label("Comments", systemImage: "bubble.right")
                    }
                    Button { reportTarget = .post(post.id) } label: {
                        Label("Report post", systemImage: "flag")
                    }
                    Button(role: .destructive) { blockCandidate = post } label: {
                        Label("Block \(post.authorName)", systemImage: "hand.raised")
                    }
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
            } else if viewModel.loadMoreFailed {
                // Otherwise a failed page reads as "you've reached the end".
                HStack {
                    Spacer()
                    VStack(spacing: Spacing.xs) {
                        Text("Couldn't load more posts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Try Again") { Task { await viewModel.retryLoadMore() } }
                            .font(.caption.weight(.semibold))
                    }
                    Spacer()
                }
            }
        }
        .listStyle(.plain)
    }
}
