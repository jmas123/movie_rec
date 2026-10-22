//
//  CastMemberViewModel.swift
//  Binged
//
//  An actor's filmography, narrowed to what the people you follow liked.
//
//  Two sources, and neither one can answer alone. The catalog knows who was in
//  what and nothing about anybody's opinion; the server knows every opinion and
//  nothing about who was in what — `ranked_items` stores a title, not a cast
//  list. So the join happens here: TMDB names the credits, the RPC says which
//  of those ids the viewer's followees put in their Liked bucket, and this
//  matches them up on `externalId`.
//
//  Which also fixes the direction of the request. Asking the server "what has
//  Tilda Swinton been in that my friends liked" is not a query it could answer
//  without a cast table it has no reason to carry; asking it "which of these
//  eighty ids did my friends like" is one indexed read.
//

import Foundation
import Observation

// MARK: - CastMemberViewModel

@MainActor
@Observable
final class CastMemberViewModel {

    /// One title of theirs, and the people who liked it.
    ///
    /// The credit is carried whole rather than as an id: the row draws a
    /// poster, a title and a year, and the screen that pushes onward needs a
    /// `MediaItem` anyway. Never inserted into the store — these come off the
    /// catalog detached, and the detail screen resolves the viewer's own copy
    /// through `canonicalItem(for:)` when there is one.
    struct LikedCredit: Identifiable {
        let item: MediaItem
        let people: [TitleWatcher]

        /// The catalog id. Non-optional by construction — a credit without one
        /// could not have been matched against an opinion in the first place.
        let externalId: String

        var id: String { externalId }

        /// The best opinion anybody had of it, for ordering. `nil` only when
        /// nobody's bucket has earned a number, which sorts last rather than
        /// pretending to be zero.
        var bestScore: Double? {
            people.compactMap(\.score).max()
        }
    }

    /// What the screen is showing.
    ///
    /// `noCredits` and `empty` are separate on purpose: "the catalog has
    /// nothing for this person" and "your people have not seen any of it" are
    /// different answers, and collapsing them would tell a user their friends
    /// were unadventurous when the truth is that TMDB has a bare page.
    enum Phase: Equatable {
        case loading
        case loaded
        /// Credits exist; none of them landed with anybody the viewer follows.
        case empty
        /// The catalog knows nothing about this person.
        case noCredits
        /// Signed out, so there is nobody to have an opinion.
        case signedOut
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var credits: [LikedCredit] = []

    /// How many credits were considered, for the caption under the count.
    private(set) var creditsConsidered = 0

    /// How many titles were asked about in one request. The RPC slices its
    /// array at 300; this stays well inside it, and the catalog caps its own
    /// list lower still.
    static let pageSize = 200

    // MARK: Loading

    func load(
        personID: String,
        catalog: MediaService?,
        rankings: RankingFeedService?,
        isSignedIn: Bool
    ) async {
        guard let catalog else {
            phase = .noCredits
            return
        }
        guard isSignedIn, let rankings else {
            // Asked before the catalog, because a signed-out viewer gets the
            // same answer whatever TMDB says and the request would be spent
            // building a list nothing can be matched against.
            phase = .signedOut
            return
        }

        phase = .loading
        let filmography = await catalog.personCredits(id: personID)
        creditsConsidered = filmography.count

        guard !filmography.isEmpty else {
            phase = .noCredits
            return
        }

        let ids = filmography.compactMap(\.externalId)
        guard !ids.isEmpty else {
            phase = .noCredits
            return
        }

        do {
            let likes = try await rankings.likes(externalIDs: ids, limit: Self.pageSize)
            credits = Self.group(likes, over: filmography)
            phase = credits.isEmpty ? .empty : .loaded
        } catch {
            // Unlike the friends section on a title, this screen *is* the
            // answer — there is nothing else on it to be worth keeping. So a
            // failure says so and offers to try again, rather than rendering as
            // "nobody liked anything", which is a different and wrong claim.
            AppLog.network.error(
                "Cast member likes failed: \(ErrorMessage.text(for: error), privacy: .public)"
            )
            credits = []
            phase = .failed(ErrorMessage.text(for: error))
        }
    }

    // MARK: Grouping

    /// Folds one opinion per row into one row per title.
    ///
    /// Ordered by how many people liked it first, and only then by the best
    /// score. Three friends at 7.5 is a stronger signal than one at 9.6, and
    /// scores are within-bucket positions rather than absolute verdicts — so
    /// sorting on the number first is the honest reading of what the app
    /// actually stores. Ties fall back to the catalog's own order, which is
    /// popularity, so an actor's best-known work leads.
    static func group(_ likes: [TitleLike], over filmography: [MediaItem]) -> [LikedCredit] {
        var peopleByTitle: [String: [TitleWatcher]] = [:]
        for like in likes {
            peopleByTitle[like.externalId, default: []].append(like.person)
        }

        let credits = filmography.enumerated().compactMap {
            index, item -> (offset: Int, credit: LikedCredit)? in
            guard let externalId = item.externalId,
                  let people = peopleByTitle[externalId], !people.isEmpty else { return nil }

            // Best first within a title, so the row's leading avatar and score
            // belong to the same person.
            let ordered = people.sorted { ($0.score ?? -1) > ($1.score ?? -1) }
            return (index, LikedCredit(item: item, people: ordered, externalId: externalId))
        }

        return credits.sorted { left, right in
            if left.credit.people.count != right.credit.people.count {
                return left.credit.people.count > right.credit.people.count
            }
            let leftBest = left.credit.bestScore ?? -1
            let rightBest = right.credit.bestScore ?? -1
            if leftBest != rightBest { return leftBest > rightBest }
            return left.offset < right.offset
        }
        .map(\.credit)
    }
}
