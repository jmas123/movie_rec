//
//  FollowListView.swift
//  Binged
//
//  Who follows somebody, and who they follow.
//
//  Listed in roadmap Phase 24 and never written, which left
//  `SocialService.followers(of:limit:)` and `following(of:limit:)` implemented
//  with no caller and the counts on a profile rendered as inert text. A number
//  you cannot tap is a worse answer than no number, because it looks like a
//  control that is broken rather than information that is complete.
//
//  Not paginated. Both service methods take a `limit` and the RPCs behind them
//  return a single page; a follower list long enough to need a cursor is a
//  problem this app does not have yet, and pretending otherwise would mean
//  building a keyset cursor with nothing to test it against.
//

import SwiftUI

// MARK: - FollowListRoute

/// A push to somebody's follower or following list.
///
/// A value rather than a `NavigationLink` with a destination closure, and that
/// is not a style preference. A closure-based link inside a path-driven
/// `NavigationStack` pushes a screen the path does not know about, and the next
/// `NavigationLink(value:)` from *inside* that screen — every row of this list
/// — resolves against a path that does not contain it and does nothing at all.
/// One mechanism per stack, all the way down.
struct FollowListRoute: Hashable {
    let direction: FollowListView.Direction
    let subject: UserProfile
}

// MARK: - FollowListView

struct FollowListView: View {

    enum Direction: Hashable {
        case followers, following

        var title: String {
            switch self {
            case .followers: return "Followers"
            case .following: return "Following"
            }
        }

        /// Written from the subject's point of view, because the reader may be
        /// looking at their own list or at somebody else's.
        func emptyMessage(for name: String) -> String {
            switch self {
            case .followers: return "Nobody follows \(name) yet."
            case .following: return "\(name) isn't following anyone yet."
            }
        }
    }

    let direction: Direction
    let subject: UserProfile
    let service: SocialService
    /// Passed through so a row can open the person it names.
    let rankings: RankingFeedService?

    @State private var people: [UserProfile] = []
    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading, loaded, empty
        case error(String)
    }

    static let pageLimit = 200

    var body: some View {
        List {
            switch phase {
            case .loading:
                HStack { Spacer(); ProgressView(); Spacer() }
                    .accessibilityLabel("Loading \(direction.title.lowercased())")
            case .empty:
                EmptyStateView(
                    systemImage: "person.2",
                    message: direction.emptyMessage(for: subject.name),
                    style: .inline
                )
            case .error(let message):
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    message: message,
                    style: .inline,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )
            case .loaded:
                ForEach(people) { person in
                    // No follow button here. This screen answers "who are
                    // they?", and a Follow control would need a per-row
                    // relationship lookup — one request per row — to know what
                    // to say. Their profile knows, and is one tap away.
                    UserRow(
                        profile: person,
                        route: rankings == nil ? nil : PersonRoute(handle: person.handle)
                    )
                }
            }
        }
        .navigationTitle(direction.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            let found = direction == .followers
                ? try await service.followers(of: subject.id, limit: Self.pageLimit)
                : try await service.following(of: subject.id, limit: Self.pageLimit)
            people = found
            phase = found.isEmpty ? .empty : .loaded
        } catch {
            phase = .error(ErrorMessage.text(for: error))
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview {
    let alex = UserProfile(
        id: UUID(), handle: "alex", displayName: "Alex", bio: nil,
        avatarURL: nil, isPrivate: false, createdAt: .now
    )
    return NavigationStack {
        FollowListView(
            direction: .followers,
            subject: alex,
            service: MockSocialService(people: [alex]),
            rankings: nil
        )
    }
}
#endif
