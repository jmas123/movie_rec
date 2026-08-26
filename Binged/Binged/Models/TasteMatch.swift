//
//  TasteMatch.swift
//  Binged
//
//  Your ranking held against somebody else's.
//
//  **Why this exists at all.** The app's whole premise is that a score means
//  something because it came out of comparisons rather than a text field. That
//  makes two people's libraries genuinely comparable — the same 0–10 scale,
//  derived the same way, from the same buckets. So the useful question on
//  somebody else's profile is not "what have they ranked" (a list) but "what do
//  they think that I don't, and what should I watch next because of it".
//
//  Pure and synchronous, like `RankingEngine` and `LibraryMerge`: no SwiftData,
//  no network, no view. The caller flattens its library into `LibraryEntry`
//  values — which is also where score *visibility* is resolved, since that
//  depends on a bucket size only the library can see.
//

import Foundation

// MARK: - TasteMatch

struct TasteMatch: Equatable {

    // MARK: Inputs

    /// One title in the viewer's own library, reduced to what a comparison
    /// needs. Mirrors `LibraryMerge.LocalItem`: a struct, so the pure type
    /// never touches a `@Model`.
    struct LibraryEntry: Equatable {
        let externalId: String
        let mediaType: MediaType
        let status: WatchedStatus
        let sentiment: Sentiment?
        /// The stored score. Present for watched, ranked titles.
        let score: Double?
        /// The score the viewer's own screens are allowed to *show* — `nil`
        /// when the bucket has not earned a number (rule 6).
        let displayScore: Double?
        let dismissed: Bool

        init(
            externalId: String,
            mediaType: MediaType,
            status: WatchedStatus,
            sentiment: Sentiment? = nil,
            score: Double? = nil,
            displayScore: Double? = nil,
            dismissed: Bool = false
        ) {
            self.externalId = externalId
            self.mediaType = mediaType
            self.status = status
            self.sentiment = sentiment
            self.score = score
            self.displayScore = displayScore
            self.dismissed = dismissed
        }
    }

    // MARK: Overlap

    /// A title both people have ranked.
    struct Overlap: Identifiable, Equatable {

        let theirs: RankedItem
        let yourSentiment: Sentiment
        let yourScore: Double
        /// `nil` when *your* bucket has not earned a number. Rule 6 applies to
        /// your side of the comparison exactly as it does to theirs — a row
        /// that showed your unearned 8.4 next to their earned 7.1 would be
        /// inventing precision to make a contrast.
        let yourDisplayScore: Double?

        var id: String { theirs.id }

        /// Distance on the shared 0–10 scale.
        var gap: Double { abs(theirs.score - yourScore) }

        var agreesOnSentiment: Bool { theirs.sentiment == yourSentiment }

        /// Whether both sides have earned a number, and so whether the row may
        /// state the gap numerically.
        var isFullyScored: Bool {
            theirs.displayScore != nil && yourDisplayScore != nil
        }
    }

    // MARK: Stored

    /// Every title you have both ranked, closest agreement first.
    let overlaps: [Overlap]

    /// Titles they rated highly that you have not tracked at all — not watched,
    /// not queued, not dismissed. The recommendation this screen actually earns.
    let unseen: [RankedItem]

    /// Their titles already sitting in your watchlist. Not a suggestion (you
    /// have made it already), but worth saying: it is agreement about what is
    /// worth *watching*, before either of you has an opinion about it.
    let alreadyQueued: [RankedItem]

    /// Spearman's rho over the shared titles, `-1...1`, or `nil` when there is
    /// too little to correlate.
    let correlation: Double?

    /// Where the viewer stands on one of their titles, keyed by `RankedItem.id`.
    private let standings: [String: Standing]

    // MARK: - Standing

    /// What the viewer has already done about a title somebody else ranked.
    ///
    /// The distinction that earns its keep is `watched` versus `untracked`: a
    /// row must never offer "add to watchlist" for a title the viewer has
    /// already watched, because queueing clears the sentiment, the score and
    /// the rank — a one-tap way to destroy a ranking from somebody else's
    /// screen.
    enum Standing: Equatable {
        /// Watched and ranked, so there is a comparison to draw.
        case ranked(Overlap)
        /// Watched, but mid-ranking or otherwise without a position yet.
        case watched
        case queued
        case untracked
    }

    /// Where the viewer stands on `item`.
    func standing(for item: RankedItem) -> Standing {
        standings[item.id] ?? .untracked
    }

    // MARK: - Init

    /// - Parameters:
    ///   - theirs: the other person's published ranking, as loaded. Paging
    ///     means this may be a prefix of their library; every count derived
    ///     here therefore describes *what was loaded*, which is why the UI
    ///     always shows the sample size next to the percentage.
    ///   - yours: the viewer's library, flattened.
    init(theirs: [RankedItem], yours: [LibraryEntry]) {
        // Identity is `(canonical external id, media type)` — the same key the
        // library uses, and the same one the server upserts on. Type is part of
        // it because a film and a series can share an id namespace.
        var mine: [Key: LibraryEntry] = [:]
        for entry in yours {
            mine[Key(entry.externalId, entry.mediaType)] = entry
        }

        var overlaps: [Overlap] = []
        var unseen: [RankedItem] = []
        var queued: [RankedItem] = []
        var standings: [String: Standing] = [:]

        for item in theirs {
            let entry = mine[Key(item.externalId, item.mediaType)]

            switch entry?.status {
            case .watched:
                guard let entry, let sentiment = entry.sentiment, let score = entry.score else {
                    // Watched but mid-ranking: no position to compare yet, and
                    // emphatically not a title to offer queueing.
                    standings[item.id] = .watched
                    continue
                }
                let overlap = Overlap(
                    theirs: item,
                    yourSentiment: sentiment,
                    yourScore: score,
                    yourDisplayScore: entry.displayScore
                )
                overlaps.append(overlap)
                standings[item.id] = .ranked(overlap)
            case .wantToWatch:
                queued.append(item)
                standings[item.id] = .queued
            case .untracked, .none:
                standings[item.id] = .untracked
                // A dismissed title is a standing "not for me". Re-suggesting
                // it because a friend liked it ignores an answer the user has
                // already given.
                if entry?.dismissed != true, item.sentiment == .liked {
                    unseen.append(item)
                }
            }
        }

        self.overlaps = overlaps.sorted { $0.gap < $1.gap }
        self.unseen = unseen.sorted { $0.score > $1.score }
        self.alreadyQueued = queued.sorted { $0.score > $1.score }
        self.standings = standings
        self.correlation = overlaps.count >= Self.minimumSharedForPercentage
            ? Ranks.spearman(overlaps.map(\.theirs.score), overlaps.map(\.yourScore))
            : nil
    }

    // MARK: - Sample

    /// How many shared titles a percentage needs before it is worth stating.
    ///
    /// Five, matching `MediaLibraryViewModel.minimumBucketSizeForScore` in
    /// spirit rather than by coincidence: below it, one title's disagreement
    /// swings the number by tens of points, and a figure that volatile is
    /// decoration. Under the threshold the screen says how many titles you
    /// share instead, which is the whole of what is known.
    static let minimumSharedForPercentage = 5

    var sharedCount: Int { overlaps.count }

    var isEmpty: Bool { overlaps.isEmpty && unseen.isEmpty && alreadyQueued.isEmpty }

    // MARK: - Headline

    /// Agreement as a 0–100 percentage, or `nil` when the sample is too small
    /// or nothing varies.
    ///
    /// **Rank correlation, not score distance.** A stored score is a quantile
    /// over its bucket, so it moves whenever that bucket grows — without either
    /// person's opinion changing. Two people with identical taste but libraries
    /// of different sizes would score as disagreeing under a distance measure.
    /// What survives the drift is the *order*, which is the thing the app
    /// actually asked them both for.
    ///
    /// Mapped from `-1...1` onto `0...100`, so 50 means "no relationship" and
    /// not "half agreement". The label beneath it says so in words.
    var percentage: Int? {
        guard let correlation else { return nil }
        return Int((((correlation + 1) / 2) * 100).rounded())
    }

    /// A phrase for the number, so a reader who does not think in correlations
    /// still gets the point.
    var verdict: String? {
        guard let percentage else { return nil }
        switch percentage {
        case 80...:  return "You rank things almost the same way"
        case 65..<80: return "Mostly aligned"
        case 55..<65: return "Some common ground"
        case 45..<55: return "No real pattern either way"
        default:      return "You tend to disagree"
        }
    }

    /// What the screen says when there is no percentage to show.
    var sampleNote: String {
        switch sharedCount {
        case 0:  return "Nothing you've both ranked yet."
        case 1:  return "One title you've both ranked — not enough to compare taste."
        default: return "\(sharedCount) titles you've both ranked — "
            + "\(Self.minimumSharedForPercentage) needed to compare taste."
        }
    }

    // MARK: - Slices

    /// Shared titles you both put in "Liked it", strongest first. The
    /// conversation starters.
    var bothLoved: [Overlap] {
        overlaps
            .filter { $0.theirs.sentiment == .liked && $0.yourSentiment == .liked }
            .sorted { min($0.theirs.score, $0.yourScore) > min($1.theirs.score, $1.yourScore) }
    }

    /// Where you part company: a different sentiment outright, or the same one
    /// with a wide gap inside it. Widest first.
    var disagreements: [Overlap] {
        overlaps
            .filter { !$0.agreesOnSentiment || $0.gap >= Self.notableGap }
            .sorted { $0.gap > $1.gap }
    }

    /// Points apart, within one sentiment, before a difference is worth
    /// pointing at. A liked bucket spans 3.2 points, so 1.5 is roughly half a
    /// bucket — enough that the two of you ordered it very differently.
    static let notableGap: Double = 1.5

    // MARK: - Key

    private struct Key: Hashable {
        let externalId: String
        let mediaType: MediaType

        init(_ externalId: String, _ mediaType: MediaType) {
            // Canonicalised on both sides: a library written before the
            // namespaced form stores `tt1375666` where the server has
            // `imdb:tt1375666`, and raw equality would read one film as two.
            self.externalId = ExternalID.canonical(externalId)
            self.mediaType = mediaType
        }
    }
}
