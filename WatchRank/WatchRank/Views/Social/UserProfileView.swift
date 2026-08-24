//
//  UserProfileView.swift
//  WatchRank
//
//  Somebody else's ranking, rendered with the same care as your own — and with
//  none of the affordances that would let you edit it.
//

import SwiftUI

// MARK: - UserProfileView

struct UserProfileView: View {

    let handle: String
    @State private var viewModel: UserProfileViewModel
    @State private var type: MediaType = .movie

    init(handle: String, social: SocialService, rankings: RankingFeedService) {
        self.handle = handle
        _viewModel = State(initialValue: UserProfileViewModel(social: social, rankings: rankings))
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .loading:
                ProgressView()
                    .accessibilityLabel("Loading profile")
            case .notFound:
                EmptyStateView(
                    systemImage: "person.fill.questionmark",
                    message: "No account with that handle."
                )
            case .privateAccount:
                privateState
            case .error(let message):
                EmptyStateView(systemImage: "exclamationmark.triangle", message: message)
            case .loaded:
                content
            }
        }
        .navigationTitle(viewModel.profile.map { "@\($0.handle)" } ?? handle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load(handle: handle) }
    }

    // MARK: States

    private var privateState: some View {
        VStack(spacing: Spacing.lg) {
            header
            EmptyStateView(
                systemImage: "lock",
                message: "This account is private. Follow to see their ranking.",
                style: .inline
            )
        }
        .padding()
    }

    // MARK: Content

    private var content: some View {
        List {
            Section { header }

            if viewModel.items.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "trophy",
                        message: "Hasn't ranked anything yet.",
                        style: .inline
                    )
                }
            } else {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(MediaType.allCases) { Text($0.displayName + "s").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                ForEach(viewModel.items.bucketed(type: type), id: \.sentiment) { bucket in
                    Section(bucket.sentiment.displayName) {
                        ForEach(bucket.items) { item in
                            RankedItemRow(item: item)
                                .onAppear {
                                    if item.id == viewModel.items.last?.id {
                                        Task { await viewModel.loadMore() }
                                    }
                                }
                        }
                    }
                }
            }
        }
        // No `.onDelete`, no `.onMove`, no edit button: this ranking is not the
        // viewer's to change, and the absence is deliberate rather than pending.
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let profile = viewModel.profile {
                HStack(spacing: Spacing.md) {
                    PosterView(title: profile.name, posterURL: profile.avatarURL)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).font(.headline)
                        Text("@\(profile.handle)")
                            .font(.caption).foregroundStyle(.secondary)
                        if viewModel.relationship.followsViewer {
                            Text("Follows you")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if viewModel.relationship.state.isActionable {
                        Button(viewModel.relationship.state.actionTitle) {
                            Task { await viewModel.toggleFollow() }
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.caption.weight(.semibold))
                    }
                }

                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio).font(.callout)
                }

                HStack(spacing: Spacing.lg) {
                    stat("\(viewModel.relationship.counts.followers)", "Followers")
                    stat("\(viewModel.relationship.counts.following)", "Following")
                    stat("\(viewModel.stats.total)", "Ranked")
                }
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

// MARK: - RankedItemRow

/// A foreign ranked title.
///
/// **Rule 6 applies here exactly as it does locally.** Below the bucket-size
/// threshold the position is shown and the number is withheld — showing a
/// stranger's "8.4" from a bucket of one would be the same unearned precision,
/// published.
struct RankedItemRow: View {

    let item: RankedItem

    var body: some View {
        HStack(spacing: Spacing.md) {
            PosterPlaceholder(title: item.title)
                .frame(width: 40, height: 60)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                Text("\(String(item.year)) · \(item.mediaType.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: Spacing.sm)

            if let score = item.displayScore {
                Text(ScoreDisplay.formatter.string(from: score as NSNumber) ?? "—")
                    .font(.callout.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
            } else {
                Text(item.positionDescription)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var label = "\(item.title), \(String(item.year))"
        if let score = item.displayScore {
            label += ", scored \(ScoreDisplay.formatter.string(from: score as NSNumber) ?? "")"
        } else {
            label += ", \(item.positionDescription)"
        }
        return label
    }
}
