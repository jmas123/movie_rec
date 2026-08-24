//
//  FeedPostCard.swift
//  Binged
//
//  One thing somebody did.
//
//  The card renders the post's frozen payload and nothing live. A post that
//  re-read the current ranking would rewrite itself every time the author
//  ranked something else, and the comments underneath would end up answering a
//  sentence that no longer exists.
//

import SwiftUI

// MARK: - FeedPostCard

struct FeedPostCard: View {

    let post: FeedPost
    var onReact: (() -> Void)?
    var onOpenActor: (() -> Void)?
    var onOpenComments: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            header

            HStack(alignment: .top, spacing: Spacing.md) {
                PosterPlaceholder(title: post.payload.title)
                    .frame(width: 52, height: 78)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(post.payload.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)

                    Text("\(String(post.payload.year)) · \(post.payload.mediaType.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let rank = post.rankDescription {
                        // The *earned* rank. This is the thing that makes the
                        // feed worth reading — a feed of numbers people typed
                        // would be worthless; these came from comparisons.
                        Text(rank)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                    if let excerpt = post.payload.reviewExcerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            // Combined here rather than over the whole card. `.combine` on the
            // container flattened the footer into it, which left Like and
            // Comment — and so the whole comment thread, with the report
            // controls inside it — unreachable under VoiceOver.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(post.sentence)

            footer
        }
        .padding(.vertical, Spacing.sm)
        .accessibilityElement(children: .contain)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                onOpenActor?()
            } label: {
                HStack(spacing: Spacing.sm) {
                    PosterView(title: post.authorName, posterURL: post.authorAvatarURL)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                    Text(post.authorName).font(.subheadline.weight(.semibold))
                    Text(post.verb).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(onOpenActor == nil)

            Spacer(minLength: Spacing.xs)

            Text(post.createdAt, format: .relative(presentation: .numeric))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Spacing.lg) {
            Button {
                onReact?()
            } label: {
                Label(
                    post.reactionCount > 0 ? "\(post.reactionCount)" : "Like",
                    systemImage: post.viewerHasReacted ? "heart.fill" : "heart"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(post.viewerHasReacted ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(onReact == nil)
            .accessibilityLabel(post.viewerHasReacted ? "Remove like" : "Like")

            Button {
                onOpenComments?()
            } label: {
                Label(
                    post.commentCount > 0 ? "\(post.commentCount)" : "Comment",
                    systemImage: "bubble.right"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(onOpenComments == nil)
            .accessibilityLabel(
                post.commentCount > 0
                    ? "\(post.commentCount) comments"
                    : "Comment"
            )
            .accessibilityHint("Opens the post and its comments")

            Spacer()
        }
    }
}

// MARK: - Previews

#if DEBUG
private func previewPost(kind: FeedPost.Kind = .ranked, bucketSize: Int? = 8) -> FeedPost {
    FeedPost(
        id: UUID(), authorID: UUID(), kind: kind, createdAt: Date().addingTimeInterval(-3600),
        authorHandle: "alex", authorDisplayName: "Alex", authorAvatarURL: nil,
        payload: .init(
            externalId: "tmdb:movie:1", title: "Dune: Part Two", year: 2024,
            mediaType: .movie, sentiment: kind == .ranked ? .liked : nil,
            rankInBucket: kind == .ranked ? 0 : nil, bucketSize: bucketSize,
            reviewExcerpt: nil
        ),
        commentCount: 3, reactionCount: 12, viewerHasReacted: false
    )
}

#Preview {
    List {
        FeedPostCard(post: previewPost())
        FeedPostCard(post: previewPost(kind: .wantToWatch, bucketSize: nil))
        // A bucket of one earns no rank line — rule 6, in the feed.
        FeedPostCard(post: previewPost(bucketSize: 1))
    }
}
#endif
