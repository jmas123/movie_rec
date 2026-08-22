//
//  ProfileView.swift
//  WatchRank
//
//  Personal stats over the user's watched library: totals, a movie/TV split,
//  average score, all-time top 5, and top genres. Per the roadmap this screen
//  has no view model — the numbers are derived by the pure `ProfileStats` value
//  type (testable on its own) from a `MediaLibraryViewModel` query.
//

import SwiftUI

// MARK: - ProfileView

struct ProfileView: View {

    @Environment(MediaLibraryViewModel.self) private var library

    /// Sends the user to Search from the empty state. Optional so previews and
    /// tests can build the screen without wiring up navigation.
    var onBrowse: (() -> Void)?

    private var stats: ProfileStats {
        ProfileStats(watched: library.allWatched)
    }

    var body: some View {
        NavigationStack {
            Group {
                if stats.isEmpty {
                    EmptyStateView(
                        systemImage: "person.crop.circle",
                        message: "Watch and rank something to start building your stats.",
                        actionTitle: onBrowse == nil ? nil : "Find something to watch",
                        action: onBrowse
                    )
                } else {
                    statsList
                }
            }
            .navigationTitle("Profile")
        }
    }

    // MARK: List

    private var statsList: some View {
        List {
            Section("Summary") {
                LabeledContent("Watched", value: "\(stats.totalWatched)")
                LabeledContent("Movies", value: "\(stats.movieCount)")
                LabeledContent("TV Shows", value: "\(stats.tvCount)")
                LabeledContent("Average Score", value: averageText)
            }

            if !stats.topFive.isEmpty {
                Section("Top 5 of All Time") {
                    ForEach(stats.topFive, id: \.id) { item in
                        MediaRow(item: item, score: library.displayScore(for: item))
                    }
                }
            }

            if !stats.topGenres.isEmpty {
                Section("Top Genres") {
                    ForEach(stats.topGenres, id: \.genre) { entry in
                        LabeledContent(entry.genre, value: "\(entry.count)")
                    }
                }
            }
        }
    }

    private var averageText: String {
        guard let average = stats.averageScore else { return "—" }
        return MediaRow.scoreFormatter.string(from: average as NSNumber) ?? "—"
    }
}

// MARK: - ProfileStats

/// Pure, view-agnostic aggregate of a set of watched items. Kept a value type
/// (not a view model) so it can be unit-tested directly against a fixture.
struct ProfileStats {

    let totalWatched: Int
    let movieCount: Int
    let tvCount: Int
    /// Mean score across items that have one; `nil` when none do.
    let averageScore: Double?
    /// Highest-scored items, best first, up to five.
    let topFive: [MediaItem]
    /// Most frequent genres, up to three, ties broken alphabetically.
    let topGenres: [(genre: String, count: Int)]

    init(watched items: [MediaItem]) {
        totalWatched = items.count
        movieCount = items.filter { $0.type == .movie }.count
        tvCount = items.filter { $0.type == .tvShow }.count

        let scores = items.compactMap(\.score)
        averageScore = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)

        topFive = items
            .sorted { ($0.score ?? -.infinity) > ($1.score ?? -.infinity) }
            .prefix(5)
            .map { $0 }

        var counts: [String: Int] = [:]
        for item in items {
            for genre in item.genres {
                counts[genre, default: 0] += 1
            }
        }
        topGenres = counts
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .prefix(3)
            .map { (genre: $0.key, count: $0.value) }
    }

    var isEmpty: Bool { totalWatched == 0 }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func profilePreviewLibrary() -> MediaLibraryViewModel {
    let library = MediaLibraryViewModel.previewInMemory()

    func watched(_ title: String, _ type: MediaType, _ sentiment: Sentiment, _ genres: [String]) {
        let item = MediaItem(title: title, year: 2018, type: type, genres: genres)
        library.markWatched(item, sentiment: sentiment)
        while let pair = library.pendingComparison {
            library.applyComparisonChoice(winner: pair.existingItem, loser: pair.newItem)
        }
        library.finalizeRanking(for: item)
    }

    watched("Parasite", .movie, .liked, ["Drama", "Thriller"])
    watched("Inception", .movie, .liked, ["Sci-Fi", "Thriller"])
    watched("Breaking Bad", .tvShow, .liked, ["Drama", "Crime"])
    watched("The Office", .tvShow, .fine, ["Comedy"])
    watched("Some Flop", .movie, .disliked, ["Drama"])

    return library
}

#Preview {
    ProfileView()
        .environment(profilePreviewLibrary())
}

#Preview("Empty") {
    ProfileView()
        .environment(MediaLibraryViewModel.previewInMemory())
}
#endif
