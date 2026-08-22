# WatchRank

## Project summary

WatchRank is a local-only iOS MVP for ranking movies and TV shows in the style of Beli. Instead of asking the user to type a numeric rating, the app captures a coarse sentiment (Liked / Fine / Disliked) and then runs a pairwise binary-insertion comparison flow against existing items in the same sentiment bucket. A 0–10 score is derived from each item's final position within its bucket — scores are never entered by the user. The v1.0 MVP has no backend, no auth, no social features, and no recommendations. **v1.1 (Part II) adds recommendations; v2.0 (Part III) adds the social layer — accounts, follows, an activity feed, comments — and lifts the local-only constraint.** See [`docs/PART-III-SOCIAL.md`](./docs/PART-III-SOCIAL.md) for the architecture and [`docs/ROADMAP.md`](./docs/ROADMAP.md) Phases 20–28 for the plan. The ranking mechanic below is unchanged by any of it.

## Tech stack

- SwiftUI (UI)
- MVVM (architecture)
- SwiftData (persistence, local-only)
- iOS 17+ deployment target
- Swift 5.9+
- Zero third-party dependencies
- TMDB for catalog metadata (Part II) and Supabase for accounts and the social graph (Part III) — both reached through a hand-rolled `URLSession` client behind a protocol in `Services/`, so neither adds a Swift Package

## File structure

```
WatchRank/
  App/
    WatchRankApp.swift
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
    MediaService.swift        // protocol
    MockMediaService.swift
    RankingEngine.swift       // binary insertion + score recomputation
  Resources/
    MockMedia.json
```

## Ranking rules (Beli-style — do not deviate)

1. **Buckets are `(media type, sentiment)`** — after a user marks an item as watched, they pick one sentiment. A bucket is that sentiment *for that media type*: films are ranked against films, shows against shows. The user is never asked whether a favourite film beats a favourite series, and each type has its own #1. Each sentiment owns a fixed range on the 0–10 scale, applied independently within each type:

   | Sentiment       | Score range  |
   |-----------------|--------------|
   | Liked it        | 6.8 – 10.0   |
   | It was fine     | 3.4 – 6.7    |
   | Didn't like it  | 0.0 – 3.3    |

2. **Pairwise comparison** — immediately after sentiment selection, enter a modal that compares the new item against items already in the same bucket (same sentiment **and** same media type). The prompt is always "Which did you prefer?" Show progress ("Comparison 2 of 4").

3. **Binary insertion sort** — pick the median item in the bucket (same type, same sentiment), compare, recurse into the correct half. Worst case is ≤ `ceil(log2(N + 1))` comparisons for a bucket of N items (e.g., N = 7 → 3 comparisons, N = 15 → 4). Empty bucket: skip comparison entirely and place the new item at the midpoint of the range.

4. **Score is derived, never entered** — after every insertion (and after any drag-to-reorder), recompute the 0–10 score of every item in the affected `(type, sentiment)` bucket from its position. Any write that moves an item *out* of a bucket owes that bucket a recompute too, or survivors keep scores computed for the old N and a gap in `rankInBucket`. The current implementation uses a quantile-style inset: `score[i] = range.upperBound - ((i + 0.5) / N) * (range.upperBound - range.lowerBound)`. A single item lands at the midpoint of its range, and no item ever sits exactly on a bucket boundary. The user never sees or edits the numeric score directly.

5. **Reorder is offered on a type tab, not the All tab** — the Ranking screen's All tab interleaves two independent rankings by score for browsing, so it is not a bucket and cannot be reordered. Selecting Movies or TV shows exactly one bucket, which is where drag-to-reorder is enabled. (This is the reverse of the pre-type-separation rule.)

6. **A score is not shown until its bucket holds 5 items** — a 0–10 number derived from one or two comparisons implies precision the app has not earned; with a single item, "8.4" is just the band midpoint wearing a decimal point. Below the threshold the UI shows position instead ("#2 in Liked it") plus how many more titles are needed. The score is still computed and stored throughout — only its *display* is withheld — so it appears as soon as the bucket grows, with no recomputation and no special case in the ranking logic. The threshold is `MediaLibraryViewModel.minimumBucketSizeForScore`, and it applies per `(type, sentiment)` bucket.

7. **"Too close to call" ends the search early** — the comparison modal offers a tie alongside the two titles. A tie ends the bisection immediately and seats the new item directly *below* the title it was weighed against: the incumbent earned its place through earlier comparisons, and the user has just said the newcomer is no better. Forcing a coin-flip answer instead would record a preference the user never expressed. A tie costs fewer comparisons than a normal answer, never more.

8. **Comparisons are undoable** — the modal offers Undo while a session is open. `ComparisonSession` keeps the search bounds from before each answer and `undoLastComparison` pops them; the bisection cannot be inverted arithmetically, since several prior states collapse onto the same bounds. Undo rewinds the progress counter too, and a tie is undoable like any other answer. Undo is user-initiated, so a session may exceed the `ceil(log2(N + 1))` bound in total taps — the bound still holds for the underlying search.

## Coding conventions

- **One primary type per file.** A file named `Foo.swift` defines `Foo`. Small helpers tightly coupled to that type are fine in the same file.
- **Section headers** use `// MARK: - Section Name`.
- **No force unwraps** (`!`) in non-test code. Use `guard let`, `if let`, nil-coalescing, or fail loudly with a thrown error. Force-unwraps are tolerated inside `WatchRankTests` only.
- **Prefer value types** (structs, enums) for everything that isn't a SwiftData `@Model` or doesn't need reference semantics.
- **Use the `@Observable` macro** for view models — not `ObservableObject` + `@Published`.
- **SwiftUI view names are descriptive.** `MediaDetailView`, `SentimentPicker`, `EmptyStateView` — never bare `DetailView` or `Picker`.

## Build commands

```bash
# Build
xcodebuild -scheme WatchRank -destination 'platform=iOS Simulator,name=iPhone 16' build

# Test
xcodebuild -scheme WatchRank -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Do not

- Do not add third-party libraries or Swift Package Manager dependencies.
- **Network code lives behind a protocol in `Services/`, always.** TMDB is the live catalog (Part II, Phase 12) behind `MediaService`; Supabase is auth and the social graph (Part III, Phases 20+) behind `AuthService` and `SocialService`. Nothing outside `Services/` may know a URL exists, and every one of them has a `Mock…` sibling so no test touches the network.
- ~~User data stays local-only and never leaves the device.~~ **No longer true from Phase 23.** A user's *published* ranking, reviews, profile and comments go to Supabase under an account. What still never leaves the device: untracked items, items with a nil `externalId`, and anything at all while the user is signed out. Publishing is opt-in and never silent — see `docs/PART-III-SOCIAL.md` §8 and §13.
- **Do not let the social layer touch the ranking mechanic.** `RankingEngine` stays pure, synchronous and local; scores stay derived from bucket position; the comparison flow never awaits a network call; and the entire app stays usable signed out. These are invariants, not preferences (`PART-III-SOCIAL.md` §2).
- **Do not trust the client for authorisation.** The Supabase anon key ships in the bundle by design and carries no privilege — row-level security in Postgres is the whole security boundary. Any rule the app enforces must also exist as a policy, or it does not exist.
- Do not let the user enter a numeric rating directly. Scores are derived from bucket position.
- The project uses `PBXFileSystemSynchronizedRootGroup`, so files added on disk are picked up by the target automatically — no manual drag-into-Xcode step. Editing `project.pbxproj` is allowed when a build-level change genuinely requires it (e.g., the `EXCLUDED_SOURCE_FILE_NAMES = .gitkeep` rule that keeps empty-folder markers out of the app bundle).
- Do not modify `WatchRankApp.swift` or `ContentView.swift` until the UI phase. The foundation phase leaves the existing app entry point untouched.

## SwiftData schema changes during dev

The MVP does not implement a migration plan. Whenever `MediaItem`'s shape changes — added/removed/renamed properties, type changes, new relationships — **delete the app from the iOS simulator before running again**. SwiftData will otherwise fail to open the existing store and the app will crash on launch. Real migrations are a v1.2 concern; do not invest in them now.

## Current scope

Part I (Phases 0–10) ships: models, `RankingEngine`, services, view models, and all screens, wired and verified on the iPhone 16 simulator. Part II is mid-stream — Phases 12, 12a and 13 (TMDB catalog, feature extraction, prediction engine) are done; **Phases 14–19 are the current work**.

**Part III (social) starts after Phase 19** and is planned, not started. Do not begin social work while Part II is open unless explicitly asked.
