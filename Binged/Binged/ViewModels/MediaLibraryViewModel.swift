//
//  MediaLibraryViewModel.swift
//  Binged
//
//  Bridges the pure `RankingEngine` with persisted `MediaItem`s in a SwiftData
//  `ModelContext`. The view model owns the comparison-session state machine,
//  so the UI just needs to read `pendingComparison`, call `applyComparisonChoice`,
//  and finally call `finalizeRanking`.
//

import Foundation
import SwiftData

// MARK: - ComparisonPair

/// One step in the pairwise comparison flow. The UI renders both items, asks
/// the user which they preferred, and reports back through
/// `MediaLibraryViewModel.applyComparisonChoice`.
///
/// `step` / `totalSteps` drive the "Comparison 2 of 4" progress affordance.
struct ComparisonPair: Identifiable {
    let id = UUID()
    let newItem: MediaItem
    let existingItem: MediaItem
    let step: Int
    let totalSteps: Int
}

// MARK: - MediaLibraryViewModel

/// Single source of truth for the user's library and the live comparison
/// session. `@Observable` so SwiftUI views can read `pendingComparison`
/// directly without a `@Published` wrapper.
///
/// Threading: pinned to the main actor because SwiftData's default
/// `ModelContext` is main-actor bound.
@Observable
@MainActor
final class MediaLibraryViewModel {

    // MARK: - Stored state

    /// The next pair the UI should display. `nil` when no comparison is in
    /// progress (either nothing has been marked watched yet, or the current
    /// session has resolved the new item's position).
    private(set) var pendingComparison: ComparisonPair?

    /// Bumped on every persisted mutation. The library's data lives in
    /// SwiftData, which `@Observable` can't see through a `fetch`, so the read
    /// APIs below touch this counter to register an observation dependency —
    /// without it a view that renders a bucket is never told to redraw when
    /// the ranking changes.
    private(set) var revision: Int = 0

    /// SwiftData context. `@ObservationIgnored` because the VM publishes
    /// changes through computed properties that re-read from the context;
    /// the context itself is not a useful observation target.
    @ObservationIgnored
    private let modelContext: ModelContext

    @ObservationIgnored
    private let engine = RankingEngine()

    /// Active binary-insertion session, or `nil` between markWatched calls.
    @ObservationIgnored
    private var session: ComparisonSession?

    /// Buckets mutated since the last `save()`.
    ///
    /// Collected here and flushed in one place rather than enqueued at each
    /// call site. Remembering to act at every bucket-mutating site is exactly
    /// what the vacated-bucket bug got wrong twice, so the same discipline
    /// applies: mark in the shared helpers, flush centrally.
    @ObservationIgnored
    private var dirtyBuckets: Set<String> = []

    // MARK: - Init

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Read APIs

    /// Every watched movie, sorted by score descending, capped at 10.
    var topMovies: [MediaItem] {
        watchedItems(of: .movie)
            .sorted { ($0.score ?? -.infinity) > ($1.score ?? -.infinity) }
            .prefix(10)
            .map { $0 }
    }

    /// Every watched TV show, sorted by score descending, capped at 10.
    var topShows: [MediaItem] {
        watchedItems(of: .tvShow)
            .sorted { ($0.score ?? -.infinity) > ($1.score ?? -.infinity) }
            .prefix(10)
            .map { $0 }
    }

    /// The five most recently watched titles across both media types.
    var recentlyWatched: [MediaItem] {
        allItems
            .filter { $0.watchedStatus == .watched }
            .sorted {
                ($0.dateWatched ?? .distantPast) > ($1.dateWatched ?? .distantPast)
            }
            .prefix(5)
            .map { $0 }
    }

    /// The five most recently added "want to watch" titles.
    /// The Home rail's five. See `allWantToWatch` for the whole queue.
    var wantToWatch: [MediaItem] {
        Array(allWantToWatch.prefix(5))
    }

    /// The entire watchlist, newest first.
    ///
    /// The rail's `prefix(5)` was the only watchlist surface in the app, so a
    /// sixth queued title was unreachable — there was no "see all", no count,
    /// and nothing to act on it with.
    var allWantToWatch: [MediaItem] {
        allItems
            .filter { $0.watchedStatus == .wantToWatch }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    /// Every watched item, regardless of type or sentiment. Used by Profile
    /// for aggregate stats (count, average, top-of-all-time, genre tallies).
    var allWatched: [MediaItem] {
        allItems.filter { $0.watchedStatus == .watched }
    }

    /// Sorted bucket for a given sentiment *and media type*, highest rank
    /// first. Exposed for the Ranking screen and for tests that need to verify
    /// post-mutation state without poking into SwiftData themselves.
    ///
    /// A bucket is identified by `(type, sentiment)`, not sentiment alone:
    /// films and shows are ranked against their own kind, so the user is never
    /// asked to decide whether a favourite film beats a favourite series.
    func bucket(for sentiment: Sentiment, type: MediaType) -> [MediaItem] {
        sortedBucket(for: sentiment, type: type)
    }

    // MARK: - Score visibility

    /// How many items a bucket needs before its scores are shown as numbers.
    ///
    /// A 0–10 score derived from one or two comparisons implies a precision the
    /// app has not earned: with a single item in a bucket, "8.4" is just the
    /// midpoint of the band wearing a decimal point. Below this threshold the
    /// UI shows position instead ("#2 in Liked it"), which is exactly as much
    /// as the data supports.
    ///
    /// The score is still computed and stored throughout — only its display is
    /// withheld — so it appears the moment a bucket grows past the threshold,
    /// with no recomputation and no special case in the ranking logic.
    static let minimumBucketSizeForScore = 5

    /// Whether a comparison session for `item` is still open.
    ///
    /// `markWatched` places the item at its bucket midpoint *before* opening
    /// the session, so it is never persisted watched-but-unscored. That means
    /// a real score and rank exist from the moment the sentiment is confirmed
    /// — values the user's comparisons are about to overwrite. Showing them in
    /// the meantime presents a rating that is about to change as though it were
    /// the answer, so the UI withholds it until the session resolves.
    func isRankingInProgress(for item: MediaItem) -> Bool {
        session?.newItem.id == item.id
    }

    /// Whether `item` has actually been *ranked* — placed against at least one
    /// other title in its bucket, with no comparison still outstanding.
    ///
    /// The first item into a bucket runs no comparisons: there is nothing to
    /// compare it to, so it is placed at the band midpoint and the flow ends
    /// immediately. Presenting that as a rating claims an judgement the user
    /// never made. Until a second title arrives and is genuinely compared, the
    /// UI shows the sentiment alone — no position, no number.
    ///
    /// Derived from bucket size rather than stored: once a bucket holds two or
    /// more items, some comparison has ordered them, so every item in it has a
    /// position that means something.
    func isRanked(_ item: MediaItem) -> Bool {
        guard item.watchedStatus == .watched, let sentiment = item.sentiment else { return false }
        guard !isRankingInProgress(for: item) else { return false }
        return sortedBucket(for: sentiment, type: item.type).count >= 2
    }

    /// `item`'s score if its bucket is large enough to justify showing a
    /// number, otherwise `nil`. Unwatched items never have one.
    func displayScore(for item: MediaItem) -> Double? {
        guard item.watchedStatus == .watched, let sentiment = item.sentiment else { return nil }
        guard !isRankingInProgress(for: item) else { return nil }
        let count = sortedBucket(for: sentiment, type: item.type).count
        guard count >= Self.minimumBucketSizeForScore else { return nil }
        return item.score
    }

    /// What a row may say about `item`: a number once the bucket has earned
    /// one, otherwise the position rule 6 asks for in its place, otherwise the
    /// sentiment alone.
    ///
    /// The three cases are the same ladder `MediaDetailView` walks, hoisted
    /// here so `MediaRow` can walk it too. Screens ask for this rather than
    /// reading `item.score` directly — score *visibility* is a library-level
    /// decision, because it depends on the size of a bucket a row cannot see.
    func scoreDisplay(for item: MediaItem) -> ScoreDisplay {
        if let score = displayScore(for: item) { return .score(score) }
        guard let sentiment = item.sentiment, item.watchedStatus == .watched else { return .none }
        guard isRanked(item), let rank = item.rankInBucket else { return .sentimentOnly(sentiment) }
        return .rank(position: rank + 1, sentiment: sentiment)
    }

    /// How many more items this item's bucket needs before its score appears.
    /// Zero once the score is visible.
    func itemsUntilScoreRevealed(for item: MediaItem) -> Int {
        guard item.watchedStatus == .watched, let sentiment = item.sentiment else { return 0 }
        let count = sortedBucket(for: sentiment, type: item.type).count
        return max(0, Self.minimumBucketSizeForScore - count)
    }

    // MARK: - Identity

    /// Returns the library's own copy of `item` when that catalog entry is
    /// already stored, otherwise `item` unchanged.
    ///
    /// A `MediaService` mints a brand-new `MediaItem` — with a brand-new
    /// `id` — on every call, so the same film searched twice produces two
    /// objects that `id` comparison treats as unrelated. Without resolving
    /// them, marking that film watched a second time inserts a duplicate row
    /// and the comparison flow can pit the film against itself.
    ///
    /// Identity is `externalId`, the catalog's own key. Items without one
    /// (hand-made entries, previews, tests) are always treated as distinct:
    /// matching on title and year instead could silently merge two genuinely
    /// different entries, and a wrong merge loses data while a duplicate is
    /// merely untidy.
    func canonicalItem(for item: MediaItem) -> MediaItem {
        // Already attached to the store — it *is* the library's copy.
        guard item.modelContext == nil else { return item }
        guard let externalId = item.externalId else { return item }

        // Canonicalised on both sides. A library written before the live
        // catalog stores bare `tt1375666` while `MockMediaService` now mints
        // `imdb:tt1375666`; raw string equality would read one title as two and
        // let the same film be ranked twice.
        let wanted = ExternalID.canonical(externalId)
        return allItems.first {
            guard let candidate = $0.externalId else { return false }
            return ExternalID.canonical(candidate) == wanted
        } ?? item
    }

    // MARK: - Write APIs

    /// Marks `item` as "want to watch". Inserts the item into the context if
    /// it isn't already attached (e.g., a fresh result from search). Clears
    /// any prior watched state so a previously watched item moved back to
    /// the queue doesn't keep its stale score.
    func addToWantToWatch(_ item: MediaItem) {
        insertIfNeeded(item)

        // Captured before the clear below, so a previously ranked item can pay
        // back the bucket it is leaving — see `recomputeBucket`.
        let vacatedSentiment = item.watchedStatus == .watched ? item.sentiment : nil

        item.watchedStatus = .wantToWatch
        item.sentiment = nil
        item.score = nil
        item.rankInBucket = nil
        item.dateWatched = nil
        // Moving to the queue is a bucket change like any other: the queue is a
        // bucket, not an absence of one.
        item.lastRankedAt = .now

        recomputeBucket(vacatedSentiment, type: item.type)
        // The queue owes a publish too, and this line is the fix for a
        // watchlist that never left the device. Marked *after* the recompute
        // above so both buckets are dirty when a title moves from a sentiment
        // into the queue: the one it left needs rescoring and republishing, and
        // the one it joined needs to exist on the server at all.
        markDirty(nil, type: item.type)
        recordPost(item, kind: .wantToWatch)
        save()
    }

    /// Records the "wants to watch" act, which belongs to no bucket.
    ///
    /// Queuing is not a ranking, so it has no `(type, sentiment)` to publish —
    /// but it is still something followers should see. Held separately and
    /// drained alongside the buckets.
    private func recordPost(_ item: MediaItem, kind: FeedPost.Kind) {
        // A title with no id cannot be published, so there is nothing for a
        // post to point at either.
        guard item.externalId != nil else { return }
        pendingPosts.append((itemID: item.id, kind: kind))
    }

    /// Acts the user has taken since the last drain, in order.
    ///
    /// **Deliberately not coalesced**, unlike the publish outbox. Publishing is
    /// per *bucket* — five rankings rewrite one bucket and owe it one upsert —
    /// but posting is per *act*, and five rankings are five things the user did.
    /// Folding them together would silently drop four of them from every
    /// follower's feed.
    private(set) var pendingPosts: [(itemID: UUID, kind: FeedPost.Kind)] = []

    func clearPendingPosts() { pendingPosts.removeAll() }

    func item(withID id: UUID) -> MediaItem? {
        allItems.first { $0.id == id }
    }

    /// Queues a title *and* records what the app guessed it would score.
    ///
    /// The guess is frozen here rather than re-derived later. Re-deriving it
    /// would score the model against a profile that had since seen more of the
    /// user's taste — including, eventually, this very title — which measures
    /// nothing. Holding the app to what it said at the time is the whole point.
    ///
    /// An existing prediction is never overwritten: the first guess is the one
    /// that gets graded.
    func addToWantToWatch(_ item: MediaItem, predicted: Double?) {
        addToWantToWatch(item)
        guard let predicted, item.predictedScore == nil else { return }
        item.predictedScore = predicted
        item.predictedAt = .now
        save()
    }

    /// "Not for me." Persisted, so the title stops being recommended.
    ///
    /// Deliberately not the same as marking it watched-and-disliked: the user
    /// has not seen it, so it must never enter a ranking bucket or move a
    /// score. It is a filter, not an opinion about quality.
    func dismiss(_ item: MediaItem) {
        insertIfNeeded(item)
        item.dismissed = true
        save()
    }

    func undismiss(_ item: MediaItem) {
        item.dismissed = false
        save()
    }

    /// Takes a title out of the library entirely.
    ///
    /// **The app had no destructive action at all** — no delete, no unwatch, no
    /// way off the watchlist — so a title added by a mis-tap was permanent and a
    /// title ranked into the wrong bucket could only ever be re-ranked, never
    /// withdrawn. There is no `modelContext.delete` for a `MediaItem` anywhere
    /// before this.
    ///
    /// The bucket it leaves is recomputed for the same reason every other exit
    /// path recomputes one: survivors would otherwise keep scores derived from
    /// the old `N` and leave a hole in `rankInBucket`. That is the vacated-bucket
    /// bug, and it has been got wrong twice already.
    func remove(_ item: MediaItem) {
        let vacatedSentiment = item.watchedStatus == .watched ? item.sentiment : nil
        let wasQueued = item.watchedStatus == .wantToWatch
        let type = item.type

        modelContext.delete(item)

        // Ordering matters: the row has to be gone before the bucket is
        // recomputed, or the deleted item is counted in its own replacement.
        recomputeBucket(vacatedSentiment, type: type)
        // A deleted queue entry owes the same debt a deleted ranking does.
        // Without this the title stays on the watchlist of every other device
        // the account has ever signed in on.
        if wasQueued { markDirty(nil, type: type) }
        save()
    }

    /// Returns a watched title to untracked, keeping it in the library.
    ///
    /// Distinct from `remove` and from `addToWantToWatch`: "I have not actually
    /// seen this" is a different statement from "forget this title" and from "I
    /// want to watch it". Only the first belongs to someone correcting a
    /// mis-tap on Mark Watched.
    ///
    /// The ranking is discarded rather than parked. A score is a position among
    /// things the user compared; there is nowhere to keep one for an item that
    /// is no longer in the comparison set, and re-watching re-ranks from
    /// scratch.
    func unwatch(_ item: MediaItem) {
        let vacatedSentiment = item.watchedStatus == .watched ? item.sentiment : nil

        item.watchedStatus = .untracked
        item.sentiment = nil
        item.score = nil
        item.rankInBucket = nil
        item.dateWatched = nil
        item.lastRankedAt = .now

        recomputeBucket(vacatedSentiment, type: item.type)
        save()
    }

    /// Matched pairs the app has earned the right to be graded on: a guess it
    /// recorded, and the score the user's own comparisons later produced.
    var matchedPredictions: [(predicted: Double, actual: Double)] {
        allItems.compactMap { item in
            guard item.watchedStatus == .watched,
                  let predicted = item.predictedScore,
                  let actual = item.score else { return nil }
            return (predicted: predicted, actual: actual)
        }
    }

    /// Starts a ranking session for `item`. The returned array contains the
    /// first `ComparisonPair` (or is empty if the target bucket is empty,
    /// meaning no comparison is needed). After every pair the UI shows, it
    /// should call `applyComparisonChoice`; when `pendingComparison`
    /// becomes `nil`, call `finalizeRanking(for:)`.
    @discardableResult
    func markWatched(_ item: MediaItem, sentiment: Sentiment) -> [ComparisonPair] {
        insertIfNeeded(item)

        // Captured before the reassignment below, so we can tell whether this
        // call is re-rating an item out of a bucket it was already ranked in.
        let vacatedSentiment = item.watchedStatus == .watched ? item.sentiment : nil
        let wasQueued = item.watchedStatus == .wantToWatch

        item.watchedStatus = .watched
        item.sentiment = sentiment
        item.dateWatched = .now
        // A deliberate choice of bucket, which is the only thing account sync
        // treats as a conflict worth resolving — see `MediaItem.lastRankedAt`.
        item.lastRankedAt = .now

        // The bucket the item is joining owes a publish however this call ends:
        // the empty-bucket path below never recomputes anything, and the session
        // path may be abandoned before `finalizeRanking` runs. Marking here
        // covers both, and repeats coalesce.
        markDirty(sentiment, type: item.type)
        // Ranking something off the watchlist empties its place in the queue,
        // and the server has to be told: without this the title stays queued on
        // every other device while being ranked on this one.
        if wasQueued { markDirty(nil, type: item.type) }
        recordPost(item, kind: .ranked)

        // Re-rating into a *different* bucket leaves the old one one item
        // short. Reading the bucket after the reassignment above means `item`
        // is already excluded from it.
        if vacatedSentiment != sentiment {
            recomputeBucket(vacatedSentiment, type: item.type)
        }

        // Build the bucket of OTHER watched items in the same sentiment. The
        // new item is intentionally excluded so the comparator never asks
        // the user to compare the item against itself.
        let bucket = sortedBucket(for: sentiment, type: item.type)
            .filter { $0.id != item.id }

        guard !bucket.isEmpty else {
            // Empty bucket: place at the midpoint per the spec and finish.
            item.rankInBucket = 0
            engine.recomputeScores(in: [item], range: sentiment.scoreRange)
            session = nil
            pendingComparison = nil
            save()
            return []
        }

        // Place the item provisionally at the bucket midpoint before opening the
        // session, so it is never persisted watched-but-unscored. If the flow
        // never finishes — the user navigates back out of the Detail screen, or
        // the app is killed mid-comparison — the item keeps a usable score
        // instead of sorting to the bottom via `rankInBucket ?? .max` and
        // rendering with no badge. `finalizeRanking` overwrites this with the
        // real position; `cancelRanking` re-applies the very same midpoint, so
        // abandoning the flow costs nothing extra.
        var provisional = bucket
        provisional.insert(item, at: bucket.count / 2)
        engine.recomputeScores(in: provisional, range: sentiment.scoreRange)
        save()

        let totalSteps = ceilLog2(bucket.count + 1)
        session = ComparisonSession(
            newItem: item,
            sentiment: sentiment,
            bucket: bucket,
            lo: 0,
            hi: bucket.count,
            step: 1,
            totalSteps: totalSteps,
            finalPosition: nil
        )

        let first = makeCurrentPair()
        pendingComparison = first
        return first.map { [$0] } ?? []
    }

    /// Records the user's choice for the current comparison and either
    /// advances `pendingComparison` to the next pair or closes the session.
    /// Mismatched winner/loser pairs (i.e., not the current pair) are
    /// ignored to keep the state machine robust against stale UI events.
    func applyComparisonChoice(winner: MediaItem, loser: MediaItem) {
        guard var current = session,
              let mid = midpointIndex(of: current),
              current.lo < current.hi
        else { return }

        let existing = current.bucket[mid]
        let preferLeft: Bool
        if winner.id == current.newItem.id, loser.id == existing.id {
            preferLeft = true
        } else if winner.id == existing.id, loser.id == current.newItem.id {
            preferLeft = false
        } else {
            // Stale or unexpected event — ignore rather than corrupt state.
            return
        }

        current.history.append((lo: current.lo, hi: current.hi))

        if preferLeft {
            current.hi = mid
        } else {
            current.lo = mid + 1
        }
        current.step += 1

        if current.lo >= current.hi {
            current.finalPosition = current.lo
            session = current
            pendingComparison = nil
        } else {
            session = current
            pendingComparison = makeCurrentPair()
        }
    }

    /// Whether the in-flight session has an answered comparison to take back.
    var canUndoComparison: Bool {
        guard let session else { return false }
        return !session.history.isEmpty
    }

    /// Reverses the most recent comparison, restoring the search bounds and
    /// re-presenting the pair the user just answered.
    ///
    /// The bisection cannot be inverted arithmetically — several different
    /// prior states collapse onto the same bounds — so the session keeps the
    /// bounds it had before each answer and this restores them.
    func undoLastComparison() {
        guard var current = session, let previous = current.history.popLast() else { return }
        current.lo = previous.lo
        current.hi = previous.hi
        current.step = max(1, current.step - 1)
        current.finalPosition = nil
        session = current
        pendingComparison = makeCurrentPair()
    }

    /// Records that the user could not separate the two titles.
    ///
    /// Rather than forcing an arbitrary answer, a tie ends the search and seats
    /// the new item immediately below the title it was compared against. The
    /// incumbent keeps the higher spot — it earned its position through earlier
    /// comparisons, and the user has just said this one is no better. Ending
    /// early is also why a tie costs fewer comparisons, not more.
    func applyComparisonTie() {
        guard var current = session,
              let mid = midpointIndex(of: current),
              current.lo < current.hi
        else { return }

        current.history.append((lo: current.lo, hi: current.hi))
        current.step += 1
        current.finalPosition = mid + 1
        current.lo = mid + 1
        current.hi = mid + 1
        session = current
        pendingComparison = nil
    }

    /// Inserts the new item at its resolved position, recomputes scores for
    /// the affected bucket, and tears down the session. Safe to call after
    /// an empty-bucket `markWatched` — that case just no-ops.
    func finalizeRanking(for item: MediaItem) {
        guard let current = session, current.newItem.id == item.id else {
            // Either there was no session (empty bucket case) or the caller
            // is finalizing a different item. Either way, nothing to do
            // here: scores were already set when `markWatched` ran.
            return
        }

        let position = current.finalPosition ?? current.lo
        var fullBucket = current.bucket
        let clamped = min(max(position, 0), fullBucket.count)
        fullBucket.insert(item, at: clamped)
        engine.recomputeScores(in: fullBucket, range: current.sentiment.scoreRange)
        markDirty(current.sentiment, type: item.type)

        session = nil
        pendingComparison = nil
        save()
    }

    /// Abandons the in-flight comparison for `item` by placing it at the
    /// midpoint of its sentiment bucket, so a user who dismisses the Compare
    /// modal early still ends up with a valid score instead of an unranked
    /// item. No-ops if the session already finished (e.g., the user completed
    /// every comparison before dismissing), which makes it safe to call from a
    /// sheet's `onDismiss` as a catch-all.
    func cancelRanking(for item: MediaItem) {
        guard let current = session, current.newItem.id == item.id else { return }

        var fullBucket = current.bucket
        let midpoint = fullBucket.count / 2
        fullBucket.insert(item, at: midpoint)
        engine.recomputeScores(in: fullBucket, range: current.sentiment.scoreRange)
        markDirty(current.sentiment, type: item.type)

        session = nil
        pendingComparison = nil
        save()
    }

    /// Drag-reorder hook for the Ranking screen. Mutates positions inside a
    /// single sentiment bucket and recomputes scores top-to-bottom. The
    /// `source` / `destination` semantics match SwiftUI's `onMove`: indices
    /// refer to the pre-move array, and `destination` is the target slot in
    /// that same pre-move indexing.
    func reorder(
        in sentiment: Sentiment,
        type: MediaType,
        from source: IndexSet,
        to destination: Int
    ) {
        var items = sortedBucket(for: sentiment, type: type)

        // Mirror SwiftUI's `Array.move(fromOffsets:toOffset:)` so we don't
        // have to import SwiftUI inside the view model.
        let moving = source.map { items[$0] }
        let countBeforeDestination = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) {
            items.remove(at: index)
        }
        items.insert(contentsOf: moving, at: destination - countBeforeDestination)

        engine.recomputeScores(in: items, range: sentiment.scoreRange)
        markDirty(sentiment, type: type)
        save()
    }

    /// Persists an edited free-text review for `item`. Centralized here so the
    /// Detail screen never touches the `ModelContext` directly. An empty or
    /// whitespace-only string clears the review back to `nil`.
    func updateReview(_ item: MediaItem, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadNone = (item.review ?? "").isEmpty
        item.review = trimmed.isEmpty ? nil : trimmed

        // **First write only, and only once the title is watched.**
        //
        // `FeedPost.Kind.reviewed` existed from the start and nothing ever
        // emitted it, so a review written after the ranking post had already
        // gone out reached the server and stopped there. Writing one is an act
        // worth a post, the same way ranking is.
        //
        // Edits are deliberately silent: a review is a thing people go back and
        // fix typos in, and re-posting on every save would put one person's
        // second thoughts through every follower's feed several times over. The
        // feed is a record of acts, and correcting a sentence is not a new one.
        //
        // A review written *during* the mark-watched flow costs no extra post
        // either: the title is not `.watched` yet at that point, so this stays
        // quiet and the `.ranked` post that follows carries the text.
        if hadNone, !trimmed.isEmpty, item.watchedStatus == .watched {
            recordPost(item, kind: .reviewed)
        }
        save()
    }

    // MARK: - Internals

    /// Every stored item, tracked or not.
    ///
    /// Internal rather than private because startup maintenance — the id
    /// migration and the feature backfill — operates on the whole library,
    /// including queued items, and the app layer must not reach past this view
    /// model into `ModelContext` to get it.
    var allItems: [MediaItem] {
        _ = revision // observation dependency — see `revision`
        let descriptor = FetchDescriptor<MediaItem>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func watchedItems(of type: MediaType) -> [MediaItem] {
        allItems.filter { $0.watchedStatus == .watched && $0.type == type }
    }

    /// One bucket: watched items of `type` carrying `sentiment`, best first.
    /// `rankInBucket` is a position *within this pair*, so the type filter is
    /// part of the bucket's identity rather than a view-level convenience.
    private func sortedBucket(for sentiment: Sentiment, type: MediaType) -> [MediaItem] {
        allItems
            .filter {
                $0.watchedStatus == .watched
                    && $0.sentiment == sentiment
                    && $0.type == type
            }
            .sorted { ($0.rankInBucket ?? .max) < ($1.rankInBucket ?? .max) }
    }

    /// Rescores an entire sentiment bucket from its current order.
    ///
    /// Every write that takes an item *out* of a bucket owes that bucket this
    /// call, or the survivors keep scores computed for the old N and a gap in
    /// `rankInBucket` (0, 2, …). That reads as slightly-wrong numbers rather
    /// than an obvious break, and the next insertion silently heals it, so the
    /// bug hides well — it has now been introduced twice. Passing `nil` (the
    /// item wasn't ranked to begin with) is a deliberate no-op so callers don't
    /// have to branch before calling.
    private func recomputeBucket(_ sentiment: Sentiment?, type: MediaType) {
        guard let sentiment else { return }
        engine.recomputeScores(
            in: sortedBucket(for: sentiment, type: type),
            range: sentiment.scoreRange
        )
        markDirty(sentiment, type: type)
    }

    // MARK: - Taste comparison

    /// The device's side of a taste comparison, reduced to what `TasteMatch`
    /// reasons about.
    ///
    /// Score *visibility* is resolved here rather than in the pure type: it
    /// depends on the size of the bucket a title sits in, which only the
    /// library can see. Titles with no `externalId` are dropped — there is
    /// nothing to key them to somebody else's ranking with.
    func tasteEntries() -> [TasteMatch.LibraryEntry] {
        allItems.compactMap { item in
            guard let externalId = item.externalId else { return nil }
            return TasteMatch.LibraryEntry(
                externalId: externalId,
                mediaType: item.type,
                status: item.watchedStatus,
                sentiment: item.sentiment,
                score: item.score,
                displayScore: displayScore(for: item),
                dismissed: item.dismissed
            )
        }
    }

    // MARK: - Account sync

    /// The device's side of a merge, reduced to what `LibraryMerge` reasons
    /// about. Only titles the account can key on: a nil `externalId` has nothing
    /// to match against, so it is counted separately rather than included.
    func localItemsForMerge() -> [LibraryMerge.LocalItem] {
        allItems.compactMap { item in
            guard let externalId = item.externalId,
                  item.watchedStatus != .untracked else { return nil }
            return LibraryMerge.LocalItem(
                externalId: externalId,
                mediaType: item.type,
                sentiment: item.sentiment,
                rankInBucket: item.rankInBucket,
                lastRankedAt: item.lastRankedAt
            )
        }
    }

    /// Tracked titles the account can never hold, because the catalog gave them
    /// no id. Surfaced so the UI can say "3 titles stay on this device" rather
    /// than leaving a silent gap when the user signs in elsewhere.
    var unsyncableCount: Int {
        allItems.filter { $0.externalId == nil && $0.watchedStatus != .untracked }.count
    }

    /// Applies a merge plan.
    ///
    /// **Scores are recomputed, never imported.** The plan carries positions and
    /// sentiments; every bucket it disturbs is rescored locally afterwards. Two
    /// reasons, both load-bearing: merging changes N, and a bucket whose size
    /// moved without a recompute leaves survivors holding scores computed for
    /// the old N — the vacated-bucket bug with a network in the middle. And
    /// Part III invariant 1 says the server never computes a score; writing the
    /// remote value here would mean it had.
    ///
    /// - Returns: how many titles the account contributed that this device did
    ///   not have.
    @discardableResult
    func apply(_ plan: LibraryMerge.Plan, remote: [RemoteRankedItem]) -> Int {
        let remoteByID = Dictionary(remote.map { ($0.externalId, $0) }, uniquingKeysWith: { first, _ in first })
        var restored = 0

        for resolution in plan.resolutions {
            switch resolution {
            case .insertLocally(let row):
                insertRestored(row)
                restored += 1

            case .resolvedConflict(let externalId, let winner, let sentiment):
                // Only a remote win changes anything locally; a local win is
                // already what the store says, and owes the server a push,
                // which the dirty-bucket marking below arranges.
                guard winner == .remote,
                      let item = allItems.first(where: { $0.externalId == externalId }) else { break }
                item.sentiment = sentiment
                item.watchedStatus = sentiment == nil ? .wantToWatch : .watched
                if sentiment == nil {
                    item.score = nil
                    item.rankInBucket = nil
                } else {
                    item.rankInBucket = remoteByID[externalId]?.rankInBucket
                }

            case .pushToServer, .alreadyAgreed:
                break // nothing local to change; the push is arranged below
            }
        }

        // Every disturbed bucket, including ones an item *left*. Recompute
        // first so the payload a drain builds is already correct, then mark.
        for bucket in plan.bucketsNeedingRecompute {
            recomputeBucket(bucket.sentiment, type: bucket.mediaType)
            markDirty(bucket.sentiment, type: bucket.mediaType)
        }

        save()
        return restored
    }

    /// Inserts a title the account knows about and this device does not.
    ///
    /// `lastRankedAt` is seeded from the server's `updatedAt` rather than left
    /// nil or set to now: it records when the decision was made, and a restored
    /// row must not be able to win a later conflict merely by having arrived
    /// recently.
    private func insertRestored(_ row: RemoteRankedItem) {
        let item = MediaItem(
            externalId: row.externalId,
            title: row.title,
            year: row.year,
            type: row.mediaType,
            // Rebuilt rather than stored: the server keeps TMDB's path, so the
            // image host and size stay this build's choice instead of whatever
            // the publishing device happened to use.
            posterURL: TMDBImage.posterURL(path: row.posterPath),
            watchedStatus: row.sentiment == nil ? .wantToWatch : .watched,
            sentiment: row.sentiment,
            rankInBucket: row.rankInBucket,
            review: row.review,
            lastRankedAt: row.updatedAt
        )
        modelContext.insert(item)
    }

    /// Records that a bucket owes the server a publish.
    ///
    /// Safe to call for a bucket that is about to be recomputed or has just
    /// been: the outbox row is keyed by bucket, so repeats coalesce.
    /// `nil` is the want-to-watch queue, **not** "nothing to do".
    ///
    /// This used to `guard let sentiment else { return }`, which is the reason
    /// the watchlist never reached the account: every path that queues a title
    /// calls this with nil, so every one of them returned here and no outbox row
    /// was ever written for the queue. The restore path, the merge, the schema
    /// and `PART-IV-SYNC.md` §7 were all built for queued rows; only this half
    /// was missing, so nothing wrote them and nothing read them back.
    private func markDirty(_ sentiment: Sentiment?, type: MediaType) {
        dirtyBuckets.insert(PendingPublish.key(mediaType: type, sentiment: sentiment))
    }

    /// Turns the dirty set into outbox rows. Called from `save()`, so no
    /// mutation path can persist without also recording what it owes.
    private func flushDirtyBuckets() {
        guard !dirtyBuckets.isEmpty else { return }
        let keys = dirtyBuckets
        dirtyBuckets.removeAll()

        let existing = Set((try? modelContext.fetch(FetchDescriptor<PendingPublish>()))?
            .map(\.key) ?? [])

        for key in keys where !existing.contains(key) {
            let parts = key.split(separator: "|")
            guard parts.count == 2,
                  let type = MediaType(rawValue: String(parts[0])) else { continue }

            let raw = String(parts[1])
            // Three cases, and the middle one is the queue. A raw value that is
            // neither a sentiment nor the marker is a key this build cannot
            // parse, and enqueuing it would put a row in the outbox that the
            // drain can only ever discard.
            let sentiment: Sentiment?
            if raw == PendingPublish.queueMarker {
                sentiment = nil
            } else if let parsed = Sentiment(rawValue: raw) {
                sentiment = parsed
            } else {
                continue
            }
            modelContext.insert(PendingPublish(mediaType: type, sentiment: sentiment))
        }
    }

    /// Whether a comparison session is open right now.
    ///
    /// Read by `SyncEngine`: a bucket mid-rewrite holds the provisional
    /// midpoint `markWatched` assigns, not a position the user has settled on,
    /// and publishing it would show followers a rank that is about to change.
    var isRankingInProgress: Bool { session != nil }

    /// Buckets currently awaiting publication, oldest debt first.
    var pendingPublishes: [PendingPublish] {
        _ = revision
        let descriptor = FetchDescriptor<PendingPublish>(
            sortBy: [SortDescriptor(\.enqueuedAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// The full, current contents of a bucket, ready to send.
    ///
    /// Built here rather than in the sync engine because the bucket is a
    /// library concept — and because a payload assembled from anything other
    /// than the live bucket is the vacated-bucket bug again.
    func publishPayload(mediaType: MediaType, sentiment: Sentiment?) -> PublishPayload {
        PublishPayload(
            mediaType: mediaType,
            sentiment: sentiment,
            bucket: bucketContents(sentiment, type: mediaType)
        )
    }

    /// A bucket's live contents — a sentiment's ranked titles, or the queue.
    ///
    /// The queue has no order to preserve: `rankInBucket` is null for every
    /// queued row by constraint, so sorting it would be inventing a position
    /// the user never chose. Sorted by title only so a payload is stable
    /// between drains and a diff of two requests is readable.
    private func bucketContents(_ sentiment: Sentiment?, type: MediaType) -> [MediaItem] {
        guard let sentiment else {
            return wantToWatch
                .filter { $0.type == type }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return sortedBucket(for: sentiment, type: type)
    }

    func clearPendingPublish(_ pending: PendingPublish) {
        modelContext.delete(pending)
        save()
    }

    /// Set when a write to the store failed, and cleared when the user
    /// acknowledges it. Presented app-wide by `RootTabView` rather than by each
    /// screen: the ranking flow spans Detail, Compare and Ranking, and a save
    /// can fail from any of them.
    ///
    /// Deliberately not reset by the next successful save. The user still needs
    /// to be told that an earlier change did not land.
    var lastSaveError: String?

    private func insertIfNeeded(_ item: MediaItem) {
        if item.modelContext == nil {
            modelContext.insert(item)
        }
    }

    private func save() {
        flushDirtyBuckets()
        // SwiftData autosaves on context teardown, but explicit saves keep
        // tests and exports deterministic.
        //
        // Was `try? modelContext.save()`. This is the single write path for
        // every ranking, reorder, sentiment change and review, so a discarded
        // error meant the app kept its in-memory state, carried on drawing the
        // new ranking, and let the user believe it had been stored. A ranking
        // that silently did not save is the worst failure this app has, because
        // the whole product is the ordering.
        do {
            try modelContext.save()
        } catch {
            AppLog.persistence.error("save failed: \(error)")
            lastSaveError = ErrorMessage.text(for: error)
        }
        revision &+= 1
    }

    private func midpointIndex(of session: ComparisonSession) -> Int? {
        guard session.lo < session.hi else { return nil }
        return (session.lo + session.hi) / 2
    }

    private func makeCurrentPair() -> ComparisonPair? {
        guard let session, let mid = midpointIndex(of: session) else { return nil }
        return ComparisonPair(
            newItem: session.newItem,
            existingItem: session.bucket[mid],
            step: session.step,
            totalSteps: session.totalSteps
        )
    }

    /// `ceil(log2(n))` for `n >= 1`. Matches the bound that
    /// `RankingEngineTests` proves for `insertionPosition`, so the value the
    /// UI shows for "of N" matches what the engine will actually do.
    private func ceilLog2(_ n: Int) -> Int {
        precondition(n >= 1, "log2 undefined for n < 1")
        var value = n - 1
        var bits = 0
        while value > 0 {
            value >>= 1
            bits += 1
        }
        return bits
    }
}

// MARK: - ComparisonSession

/// Snapshot of an in-flight binary-insertion search. Lives entirely in memory:
/// if the app is terminated mid-comparison we drop the session rather than
/// trying to persist it.
private struct ComparisonSession {
    let newItem: MediaItem
    let sentiment: Sentiment
    /// Sorted snapshot of the bucket at the moment `markWatched` ran. The
    /// session captures this so subsequent reorders or moves do not shift
    /// the indices being binary-searched.
    let bucket: [MediaItem]
    var lo: Int
    var hi: Int
    var step: Int
    let totalSteps: Int
    var finalPosition: Int?

    /// Search bounds before each answered comparison, newest last. Undo pops
    /// this rather than trying to invert the bisection, which is not reversible
    /// from the bounds alone.
    var history: [(lo: Int, hi: Int)] = []
}
