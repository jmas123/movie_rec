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

    /// Opens the title itself. `nil` where there is nowhere to go — the same
    /// convention `onOpenActor` uses, so a card rendered without a navigation
    /// stack draws the block as plain text rather than as a dead button.
    var onOpenTitle: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            header

            // The title block is the tap target, poster included: a feed is
            // read by scanning artwork, so the picture is the thing a reader
            // aims at, not a link on the words beside it.
            Button {
                onOpenTitle?()
            } label: {
                titleBlock
            }
            .buttonStyle(.plain)
            .disabled(onOpenTitle == nil)
            // Combined here rather than over the whole card. `.combine` on the
            // container flattened the footer into it, which left Like and
            // Comment — and so the whole comment thread, with the report
            // controls inside it — unreachable under VoiceOver.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(post.sentence)
            .accessibilityHint(onOpenTitle == nil ? "" : "Opens \(post.payload.title)")

            if let review = post.payload.reviewExcerpt, !review.isEmpty {
                reviewBlock(review)
            }

            footer
        }
        .padding(.vertical, Spacing.sm)
        .accessibilityElement(children: .contain)
    }

    // MARK: Title

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            // Real artwork where the post carries a path, and the same gradient
            // as before where it does not — which is every post written before
            // `poster_path` was added to the payload.
            PosterView(title: post.payload.title, posterURL: post.payload.posterURL)
                .frame(width: 52, height: 78)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(post.payload.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)

                Text("\(String(post.payload.year)) · \(post.payload.mediaType.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let rank = post.rankDescription {
                    // The *earned* rank. This is the thing that makes the feed
                    // worth reading — a feed of numbers people typed would be
                    // worthless; these came from comparisons.
                    Text(rank)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            Spacer(minLength: 0)

            if onOpenTitle != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Review

    /// The author's own words, given their own block under the title rather
    /// than a third caption squeezed beside the poster.
    ///
    /// It is the only part of a post that is *writing* rather than a derived
    /// fact, so it reads as a quotation: full width, its own type, and a rule
    /// down the side marking where the app stops talking and the author starts.
    private func reviewBlock(_ review: String) -> some View {
        Text(review)
            .font(.callout)
            .foregroundStyle(.primary)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Spacing.md)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: 3)
            }
            .padding(.top, Spacing.xs)
            .accessibilityLabel("\(post.authorName) wrote: \(review)")
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
private func previewPost(
    kind: FeedPost.Kind = .ranked,
    bucketSize: Int? = 8,
    review: String? = nil
) -> FeedPost {
    FeedPost(
        id: UUID(), authorID: UUID(), kind: kind, createdAt: Date().addingTimeInterval(-3600),
        authorHandle: "alex", authorDisplayName: "Alex", authorAvatarURL: nil,
        payload: .init(
            externalId: "tmdb:movie:1", title: "Dune: Part Two", year: 2024,
            mediaType: .movie, sentiment: kind == .ranked ? .liked : nil,
            rankInBucket: kind == .ranked ? 0 : nil, bucketSize: bucketSize,
            reviewExcerpt: review,
            posterPath: nil
        ),
        commentCount: 3, reactionCount: 12, viewerHasReacted: false
    )
}

#Preview {
    List {
        FeedPostCard(post: previewPost(), onOpenTitle: {})
        FeedPostCard(
            post: previewPost(
                review: "The desert stuff is astonishing and the politics finally "
                      + "land. Second half drags a little."
            ),
            onOpenTitle: {}
        )
        FeedPostCard(post: previewPost(kind: .wantToWatch, bucketSize: nil))
        // A bucket of one earns no rank line — rule 6, in the feed.
        FeedPostCard(post: previewPost(bucketSize: 1))
    }
    .listStyle(.plain)
}
#endif
