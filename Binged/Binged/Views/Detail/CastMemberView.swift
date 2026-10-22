//
//  CastMemberView.swift
//  Binged
//
//  An actor tapped in the cast strip, answered with the people you follow.
//
//  "Is that the one with Tilda Swinton?" was the question the cast strip
//  answered. This is the one it provoked: *what else has she been in that
//  anyone I trust actually rated?* TMDB can list two hundred credits and rank
//  them by a popularity number nobody asked for; the app can do something TMDB
//  cannot, which is to hand back the four of them your friends liked.
//
//  **A sheet, not a push.** `MediaDetailView` is reached six different ways —
//  Home, Ranking, Watchlist, Discover, Search, and a title lifted off somebody
//  else's ranking — and several of those arrive through a closure-based
//  `NavigationLink` inside a path-driven stack, where a `NavigationLink(value:)`
//  from the pushed screen resolves against a path that does not contain it and
//  does nothing at all (see `FollowListRoute`). A sheet carries its own
//  `NavigationStack` and behaves identically from all six, with no destination
//  to register in each of them and no way for two registrations to shadow each
//  other.
//

import SwiftUI

// MARK: - CastMemberView

struct CastMemberView: View {

    /// Carried whole from the strip that was tapped, so the header can draw the
    /// face and the name before the first request lands. The `id` is TMDB's own
    /// person id — the whole reason the strip stores it as an identifier rather
    /// than looking the actor up again by name, which two people can share.
    let person: TitleDetails.Person

    @Environment(\.mediaService) private var catalog
    @Environment(\.rankingFeedService) private var rankings
    @Environment(SessionViewModel.self) private var session: SessionViewModel?
    @Environment(MediaLibraryViewModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = CastMemberViewModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(person.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await load() }
    }

    private func load() async {
        await viewModel.load(
            personID: person.id,
            catalog: catalog,
            rankings: rankings,
            isSignedIn: session?.isSignedIn ?? false
        )
    }

    // MARK: Phases

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Looking through \(person.name)’s films")

        case .loaded:
            List {
                Section {
                    ForEach(viewModel.credits) { credit in
                        creditRow(credit)
                    }
                } header: {
                    header
                }
            }
            .listStyle(.plain)

        case .empty:
            state(
                systemImage: "person.2.slash",
                message: "Nobody you follow has liked anything with \(person.name) in it yet."
            )

        case .noCredits:
            state(
                systemImage: "film.stack",
                message: "The catalog has nothing listed for \(person.name)."
            )

        case .signedOut:
            state(
                systemImage: "person.crop.circle.badge.questionmark",
                message: "Sign in to see what the people you follow liked."
            )

        case .failed(let message):
            state(
                systemImage: "exclamationmark.triangle",
                message: message,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        }
    }

    private func state(
        systemImage: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: Spacing.section) {
            portrait
            EmptyStateView(
                systemImage: systemImage,
                message: message,
                actionTitle: actionTitle,
                action: action
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.lg)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            portrait
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
        // A `List` header is upper-cased and pinned by default, which is right
        // for "LIKED IT" and wrong for a face and a sentence.
        .textCase(nil)
        .listRowInsets(EdgeInsets())
    }

    private var portrait: some View {
        VStack(spacing: Spacing.sm) {
            PosterView(title: person.name, posterURL: person.imageURL)
                .frame(width: 88, height: 88)
                .clipShape(Circle())
            if let role = person.role, !role.isEmpty {
                Text("as \(role)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(person.role.map { "\(person.name), \($0)" } ?? person.name)
    }

    /// Says what the list is, and — quietly — what it is not: a filmography
    /// with four rows on it invites "is that all she did?", and the count of
    /// what was looked through answers it before it is asked.
    private var subtitle: String {
        let liked = viewModel.credits.count
        let considered = viewModel.creditsConsidered
        let titles = liked == 1 ? "title" : "titles"
        return "\(liked) \(titles) people you follow liked, of \(considered) credits"
    }

    // MARK: One credit

    private func creditRow(_ credit: CastMemberViewModel.LikedCredit) -> some View {
        NavigationLink {
            // The viewer's own copy when they have one, so their sentiment and
            // score are on the screen they land on rather than a stranger's
            // husk of the same film.
            MediaDetailView(item: library.canonicalItem(for: credit.item))
        } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                PosterView(title: credit.item.title, posterURL: credit.item.posterURL)
                    .frame(width: 46, height: 69)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(credit.item.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)

                    Text(secondaryLine(for: credit))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LikedByRow(people: credit.people)
                }
            }
            .padding(.vertical, Spacing.xs)
        }
        .accessibilityLabel(accessibilityLabel(for: credit))
    }

    /// "Movie · 2019" — the year is omitted when the catalog has none rather
    /// than printed as a zero.
    private func secondaryLine(for credit: CastMemberViewModel.LikedCredit) -> String {
        let type = credit.item.type.displayName
        guard credit.item.year > 0 else { return type }
        return "\(type) · \(String(credit.item.year))"
    }

    private func accessibilityLabel(for credit: CastMemberViewModel.LikedCredit) -> String {
        let names = credit.people.map(\.name)
        return "\(credit.item.title), \(secondaryLine(for: credit)). Liked by \(ListFormatter.localizedString(byJoining: names))"
    }
}

// MARK: - LikedByRow

/// The faces of the people who liked it, and their names in words.
///
/// Both, deliberately. Avatars alone are a row of thumbnails a viewer has to
/// recognise; names alone throw away the one thing that makes this different
/// from a critics' aggregate. Three faces is where the row stops being a row.
private struct LikedByRow: View {

    let people: [TitleWatcher]

    static let facesShown = 3

    var body: some View {
        HStack(spacing: Spacing.sm) {
            HStack(spacing: -8) {
                ForEach(people.prefix(Self.facesShown)) { person in
                    PosterView(title: person.name, posterURL: person.avatarURL)
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                }
            }

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityHidden(true)   // the row's own label says all of this
    }

    /// "Alex liked it", "Alex and Sam liked it", "Alex, Sam and 2 others".
    private var summary: String {
        let names = people.map(\.name)
        switch names.count {
        case 0:  return ""
        case 1:  return "\(names[0]) liked it"
        case 2:  return "\(names[0]) and \(names[1]) liked it"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) others"
        }
    }
}
