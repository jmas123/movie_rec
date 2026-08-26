//
//  FeedPayloadTests.swift
//  BingedTests
//
//  What a post carries into somebody else's feed.
//
//  Three of these guard things that were silently absent rather than wrong,
//  which is the failure mode this payload invites: it is denormalised, built in
//  one place, and every field is optional, so a field nobody populates looks
//  exactly like a field nobody has data for. `reviewExcerpt` was hardcoded
//  `nil` at the only site that builds it — the review reached the server's
//  `ranked_items` row and never the feed — and no test noticed, because there
//  was nothing asserting that a review the user wrote comes out the other end.
//

import Foundation
import SwiftData
import Testing

@testable import Binged

@Suite("Feed payload")
struct FeedPayloadTests {

    // MARK: - Excerpts

    @Test("A review travels as written when it is short enough")
    func shortReviewIsIntact() {
        let review = "Astonishing, and the politics finally land."
        #expect(FeedPost.excerpt(from: review) == review)
    }

    @Test("Nothing to say stays nothing")
    func emptyReviewIsNil() {
        #expect(FeedPost.excerpt(from: nil) == nil)
        #expect(FeedPost.excerpt(from: "") == nil)
        #expect(FeedPost.excerpt(from: "   \n  ") == nil)
    }

    @Test("A long review is cut on a word boundary, and says it was cut")
    func longReviewIsTruncated() throws {
        let review = String(repeating: "word ", count: 200)
        let excerpt = try #require(FeedPost.excerpt(from: review))

        #expect(excerpt.count <= FeedPost.reviewExcerptLimit + 1) // +1 for the ellipsis
        #expect(excerpt.hasSuffix("…"))
        // Cut between words, never through one.
        #expect(!excerpt.contains("wor…"))
    }

    @Test("A single unbroken token is cut hard rather than sent whole")
    func unbrokenTokenIsCut() throws {
        let excerpt = try #require(
            FeedPost.excerpt(from: String(repeating: "x", count: 500))
        )
        #expect(excerpt.count == FeedPost.reviewExcerptLimit + 1)
    }

    // MARK: - Poster

    @Test("A payload with a poster path renders a URL; one without renders none")
    func posterURL() {
        let withArt = payload(posterPath: "/abc.jpg")
        let without = payload(posterPath: nil)

        #expect(withArt.posterURL?.hasSuffix("/abc.jpg") == true)
        #expect(without.posterURL == nil)
    }

    @Test("A post written before poster_path existed still decodes")
    func legacyPayloadDecodes() throws {
        // `payload` is jsonb, so the key is simply absent on older rows. That
        // has to be "no artwork", never a decode failure that drops the post.
        let json = """
        {"external_id":"tmdb:movie:1","title":"Dune","year":2021,
         "media_type":"movie","sentiment":"liked","rank_in_bucket":0,
         "bucket_size":9,"review_excerpt":null}
        """
        let decoded = try JSONDecoder().decode(
            FeedPost.Payload.self, from: Data(json.utf8)
        )

        #expect(decoded.posterPath == nil)
        #expect(decoded.posterURL == nil)
        #expect(decoded.title == "Dune")
    }

    // MARK: - Navigation

    @Test("A payload and a ranked row project onto the same navigable identity")
    func referencesAgree() {
        let ranked = RankedItem(
            externalId: "tmdb:movie:1", mediaType: .movie, sentiment: .liked,
            title: "Dune", year: 2021, score: 9.1, rankInBucket: 0,
            bucketSize: 9, posterPath: "/abc.jpg"
        )
        let posted = payload(posterPath: "/abc.jpg")

        // The point of `TitleReference`: two different social surfaces push the
        // same value, so one destination serves both.
        #expect(ranked.reference == posted.reference)
    }

    private func payload(posterPath: String?) -> FeedPost.Payload {
        FeedPost.Payload(
            externalId: "tmdb:movie:1", title: "Dune", year: 2021,
            mediaType: .movie, sentiment: .liked, rankInBucket: 0,
            bucketSize: 9, reviewExcerpt: nil, posterPath: posterPath
        )
    }
}

// MARK: - Emission

@Suite("Review posts")
@MainActor
struct ReviewPostTests {

    private func makeLibrary() throws -> MediaLibraryViewModel {
        MediaLibraryViewModel(modelContext: try makeContext())
    }

    private func item(_ id: String = "tmdb:movie:1", review: String? = nil) -> MediaItem {
        MediaItem(
            externalId: id, title: "Dune", year: 2021, type: .movie, review: review
        )
    }

    @Test("Writing a review for the first time is an act worth posting")
    func firstReviewPosts() throws {
        let library = try makeLibrary()
        let film = item()
        library.markWatched(film, sentiment: .liked)
        library.clearPendingPosts()

        library.updateReview(film, to: "Astonishing.")

        #expect(library.pendingPosts.count == 1)
        #expect(library.pendingPosts.first?.kind == .reviewed)
        #expect(library.pendingPosts.first?.itemID == film.id)
    }

    @Test("Editing one is not — a typo fix is not news")
    func editsAreSilent() throws {
        let library = try makeLibrary()
        let film = item(review: "Astonishing.")
        library.markWatched(film, sentiment: .liked)
        library.clearPendingPosts()

        library.updateReview(film, to: "Astonishing, actually.")

        #expect(library.pendingPosts.isEmpty)
    }

    @Test("Clearing one is not either")
    func clearingIsSilent() throws {
        let library = try makeLibrary()
        let film = item(review: "Astonishing.")
        library.markWatched(film, sentiment: .liked)
        library.clearPendingPosts()

        library.updateReview(film, to: "")

        #expect(film.review == nil)
        #expect(library.pendingPosts.isEmpty)
    }

    @Test("A review written before the ranking rides on the ranking post")
    func reviewBeforeRankingCostsNoExtraPost() throws {
        // The order `MediaDetailView.confirmSentiment` uses: review first, then
        // mark watched. One post, carrying both — which is why writing a review
        // in the sentiment sheet does not double-post.
        let library = try makeLibrary()
        let film = item("tmdb:movie:2")

        library.updateReview(film, to: "Quietly devastating.")
        library.markWatched(film, sentiment: .liked)

        #expect(library.pendingPosts.count == 1)
        #expect(library.pendingPosts.first?.kind == .ranked)
        #expect(film.review == "Quietly devastating.")
    }

    @Test("A title with no catalog id posts nothing, review or not")
    func noExternalIdNoPost() throws {
        // Nothing for a post to point at, the same rule `recordPost` applies to
        // a ranking.
        let library = try makeLibrary()
        let film = MediaItem(title: "Home video", year: 2020, type: .movie)
        library.markWatched(film, sentiment: .liked)
        library.clearPendingPosts()

        library.updateReview(film, to: "Ours.")

        #expect(library.pendingPosts.isEmpty)
    }
}
