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

    /// Where a tapped author and a tapped post go.
    ///
    /// **This screen no longer registers navigation destinations of its own.**
    /// It sits inside the Home tab's stack, and a stack keeps one destination
    /// per data type: the `PersonRoute` destination declared here shadowed the
    /// one at the stack's root, which killed every `NavigationLink(value:)`
    /// push in people search, follower lists and follow requests. The owner of
    /// the stack owns the routing; this screen just says what was tapped.
    private let onOpenPerson: ((PersonRoute) -> Void)?
    private let onOpenPost: (FeedPost) -> Void
    /// Where a tapped *title* goes. Same contract as the two above: the stack
    /// that owns the routing decides, and `nil` means the card draws its title
    /// block as plain text instead of a button to nowhere.
    private let onOpenTitle: ((TitleReference) -> Void)?
    private let viewerID: () -> UUID?

    /// The reader's own handle, for the empty screen's "invite a friend" copy.
    /// A closure, like the other session reads on this screen: the profile
    /// arrives asynchronously after launch, so a value captured at init would
    /// be nil for the rest of the session.
    private let viewerHandle: () -> String?

    @State private var reportTarget: ReportTarget?
    @State private var blockCandidate: FeedPost?

    init(
        service: FeedService?,
        social: SocialService?,
        rankings: RankingFeedService? = nil,
        isSignedIn: @escaping () -> Bool,
        viewerID: @escaping () -> UUID? = { nil },
        viewerHandle: @escaping () -> String? = { nil },
        onOpenPerson: ((PersonRoute) -> Void)? = nil,
        onOpenPost: @escaping (FeedPost) -> Void = { _ in },
        onOpenTitle: ((TitleReference) -> Void)? = nil,
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
        self.onOpenPerson = onOpenPerson
        self.onOpenPost = onOpenPost
        self.onOpenTitle = onOpenTitle
        self.viewerHandle = viewerHandle
        self.onFindPeople = onFindPeople
        self.onSignIn = onSignIn
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .loading:
                ProgressView()
                    .accessibilityLabel("Loading your feed")
            // One screen for all three, because they differ in what they ask
            // the reader to do rather than in kind — see `FeedStarterView`,
            // which also restores pull-to-refresh here: `.refreshable` needs a
            // scrollable descendant, and the empty states used not to have one.
            case .signedOut:
                starter(.signedOut)
            case .followingNobody:
                starter(.followingNobody)
            case .quiet:
                starter(.quiet)
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

    private func starter(_ reason: FeedStarterView.Reason) -> some View {
        FeedStarterView(
            reason: reason,
            handle: viewerHandle(),
            followees: viewModel.followees,
            onFindPeople: onFindPeople,
            onSignIn: onSignIn,
            // Reuses the destination the post list already registers, so a
            // profile opens the same way from either.
            onOpenPerson: { person in
                onOpenPerson?(PersonRoute(handle: person.handle))
            }
        )
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
                    onOpenActor: onOpenPerson.map { open in
                        { open(PersonRoute(handle: post.authorHandle)) }
                    },
                    onOpenComments: { onOpenPost(post) },
                    onOpenTitle: onOpenTitle.map { open in
                        { open(post.payload.reference) }
                    }
                )
                // Report and block sit on the row itself, not only inside the
                // post. Guideline 1.2 wants them reachable wherever another
                // person's content appears, and the feed is that surface.
                .contextMenu {
                    if let onOpenTitle {
                        Button { onOpenTitle(post.payload.reference) } label: {
                            Label(post.payload.title, systemImage: "film")
                        }
                    }
                    Button { onOpenPost(post) } label: {
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
