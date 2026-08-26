Build an iOS app MVP called "Binged": a Beli-style ranking app for movies and TV shows.
Stack

SwiftUI, MVVM
iOS 17.0+ deployment target (was 18.2 until 2026-08-24; see CLAUDE.md)
Swift 5 language mode
SwiftData for persistence (local-only through v1.1)
No third-party dependencies
No authentication, no social features, no recommendations in this MVP

> **Superseded for v1.1 as well.** Recommendations shipped in Part II: TMDB is
> the live catalog (metadata only), and predicted ratings are computed **on
> device** from the user's own rankings. No user data leaves the device in v1.1.
> The algorithm in three sentences: each watched title contributes a residual
> against its media type's baseline; those residuals are averaged per metadata
> feature and shrunk toward zero by how little evidence supports them; a
> candidate's prediction is its type baseline plus a family-weighted mean of its
> features' effects, mapped onto the user's own scale by a calibration learned
> from leave-one-out error.
>
> **Superseded for v2.0.** The last line describes the v1.0 MVP and still holds for it. v1.1 adds recommendations (roadmap Part II) and v2.0 adds accounts, follows, an activity feed and comments (roadmap Part III), which lifts the local-only constraint: a user's published ranking leaves the device. The ranking mechanic below is unchanged by both — scores stay derived from bucket position and the engine stays pure and local. See `PART-III-SOCIAL.md`.

Core ranking system (critical, do not deviate)
This is the product's central mechanic. Do NOT let users pick a numeric rating directly.

After marking an item as watched, prompt the user to pick a sentiment: Liked it, It was fine, or Didn't like it. These map to score ranges: 6.8 to 10.0, 3.4 to 6.7, and 0.0 to 3.3.
Immediately enter pairwise comparison mode. Show the new item alongside another watched item from the same sentiment bucket. Ask: "Which did you prefer?"
Use binary insertion sort: pick the median item in the bucket, compare, then recurse into the correct half. Continue until the new item's position is fully determined. Worst case is ceil(log2(N + 1)) comparisons for a bucket of size N.
After insertion, recompute the 0-10 score of every item in the bucket based on its position within the bucket's score range. Scores are distributed using a quantile-style inset (`score[i] = upper - ((i + 0.5) / N) * (upper - lower)`), so no item ever lands exactly on a bucket boundary.
If the bucket is empty, skip comparison and place the item at the midpoint of the range.

Data model
MediaItem (SwiftData @Model):

id: UUID
externalId: String?
title: String
year: Int
type: MediaType (movie, tvShow)
overview: String
posterURL: String?
genres: [String]
watchedStatus: WatchedStatus (watched, wantToWatch, untracked)
sentiment: Sentiment? (liked, fine, disliked)
score: Double? (0.0 to 10.0, derived, never user-entered)
rankInBucket: Int?
review: String?
dateAdded: Date
dateWatched: Date?

Screens

Home: Top 10 ranked movies, top 10 ranked TV shows, recently watched (5), want to watch (5). Empty states for each. Floating add button.
Search: Search bar, results list. Use a MediaService protocol with a MockMediaService implementation seeded with 25+ titles. Make adding a TMDB implementation later a one-class change.
Detail: Title, year, type, poster placeholder, overview, genres. Buttons for Mark Watched, Want to Watch, Edit Review. If watched, show current score and rank in bucket.
Ranking: Tabs for Movies / TV Shows / All. Within each, three collapsible sections (Liked, Fine, Disliked) ordered by score descending. Drag-to-reorder is allowed and triggers score recomputation.
Compare flow: Modal that walks the user through pairwise comparisons after a new watched item is added. Show progress (e.g., "Comparison 2 of 4").
Profile: Total watched, breakdown by type, average score, top 5 of all time, top 3 genres by count.

File structure
Binged/
  App/
    BingedApp.swift
    RootTabView.swift
  Models/
    MediaItem.swift
    MediaType.swift
    WatchedStatus.swift
    Sentiment.swift
  Views/
    Home/HomeView.swift
    Search/SearchView.swift
    Detail/MediaDetailView.swift
    Ranking/RankingView.swift
    Compare/CompareView.swift
    Profile/ProfileView.swift
  Components/
    MediaCard.swift
    MediaRow.swift
    PosterPlaceholder.swift
    EmptyStateView.swift
    SentimentPicker.swift
  ViewModels/
    MediaLibraryViewModel.swift
    SearchViewModel.swift
    RankingViewModel.swift
    CompareViewModel.swift
  Services/
    MediaService.swift  // protocol
    MockMediaService.swift
    RankingEngine.swift  // binary insertion + score recomputation
  Resources/
    MockMedia.json
Build order

Models and enums
RankingEngine with unit tests covering insertion and score recomputation
MockMediaService with seed JSON (25+ titles, mixed movies/TV, varied genres)
MediaLibraryViewModel with SwiftData integration
Components, then screens in this order: Search, Detail, Compare, Ranking, Home, Profile
RootTabView wiring everything together

UX

Clean, premium feel. Generous spacing, SF Symbols, system colors so dark mode works automatically.
Poster placeholders are gradient cards with the title initial.
Ranking screen is the hero. Items should feel weighty and tappable.
All empty states have illustration (SF Symbol), one line of copy, and a CTA.