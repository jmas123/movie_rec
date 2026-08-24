# WatchRank Roadmap

The path from "foundation done" to "MVP shippable" — one phase per screen or service so each future session has a single, unambiguous goal.

- **Product spec:** [`SPEC.md`](./SPEC.md) — what we're building and why. Source of truth for behavior.
- **Conventions:** [`../CLAUDE.md`](../CLAUDE.md) — coding standards, "do not" list, build commands.

## How to read this roadmap

- Phases run **roughly in order**. Earlier phases unblock later ones; the few that could swap are noted inline.
- Each phase is sized for **one Claude Code session**.
- **Part I (Phases 0–11)** is the ranking MVP. **Part II (Phases 12–19)** is the v1.1 recommendation system; it starts only once Part I ships, and it opens with the live TMDB catalog because the data layer decides what the predictor can be built from. **Part III (Phases 20–28)** is the v2.0 social layer — accounts, follows, a feed, comments — and it lifts the project’s local-only constraint; it starts after Phase 19 and is designed in [`PART-III-SOCIAL.md`](./PART-III-SOCIAL.md).
- Every phase lists: a one-line **Goal**, ordered **Steps**, **Acceptance criteria** ("done when…"), and **Files created / modified**.
- ~~After every phase that adds new files, drag them into the Xcode target manually — Claude will not edit `project.pbxproj`.~~ **No longer needed:** the project now uses `PBXFileSystemSynchronizedRootGroup`, so files added on disk are picked up by the target automatically.

> **✅ Build blocker (resolved):** empty folders carry a `.gitkeep`, and the synchronized group used to copy all of them to the same `WatchRank.app/.gitkeep` path, failing with *"Multiple commands produce …/.gitkeep."* Fixed by setting `EXCLUDED_SOURCE_FILE_NAMES = .gitkeep` on the app target (both Debug and Release) in `project.pbxproj`, which keeps every `.gitkeep` out of the bundle regardless of folder. The markers can now safely stay, so empty folders remain tracked in git.
>
> **✅ Runtime blocker (resolved 2026-08-21):** iOS 18.3 is installed and the **iPhone 16** simulator is the destination for every build/test command (the docs previously said iPhone 15, which does not exist on this machine). The full suite now *runs*: 61 tests, 0 failures.

## Status legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Done |
| 🟡 | In progress |
| ⬜ | Not started |

---

## Phase 0 — Foundation ✅

**Goal:** Data models, pure ranking logic, and a unit-test scaffold — no UI, no services.

### Steps (all complete)
1. Author `CLAUDE.md` and `README.md` at repo root.
2. Create the `WatchRank/WatchRank/` folder tree from `SPEC.md` with `.gitkeep` markers in empty folders.
3. Implement enums: `MediaType`, `WatchedStatus`, `Sentiment` (with `scoreRange: ClosedRange<Double>`).
4. Implement `MediaItem` as a SwiftData `@Model`.
5. Implement `RankingEngine` (binary insertion + score recomputation, `import Foundation` only).
6. Write `RankingEngineTests.swift` using Swift Testing (`@Suite`, `@Test`, `#expect`).

### Acceptance criteria
- ✅ All foundation files exist on disk.
- ✅ `xcodebuild … test` passes (first green run 2026-08-21; the synchronized group means there is no manual drag step).

### Files created / modified
- `/CLAUDE.md`, `/README.md`
- `WatchRank/WatchRank/Models/MediaItem.swift`
- `WatchRank/WatchRank/Models/MediaType.swift`
- `WatchRank/WatchRank/Models/WatchedStatus.swift`
- `WatchRank/WatchRank/Models/Sentiment.swift`
- `WatchRank/WatchRank/Services/RankingEngine.swift`
- `WatchRank/WatchRankTests/RankingEngineTests.swift`
- `.gitkeep` markers under `App/`, `Views/**`, `Components/`, `ViewModels/`, `Resources/`

---

## Phase 1 — Media service + mock data ✅

**Goal:** A pluggable catalog source with 25+ seed titles, so search has something to return without a backend.

### Steps
1. Define `Services/MediaService.swift` as a protocol. Async API: `search(query:) async throws -> [MediaItem]` and `item(externalId:) async throws -> MediaItem?`. Keep the surface tight so a TMDB swap is a one-class replacement.
2. Build `Resources/MockMedia.json` with **25+ titles** mixing movies and TV across at least 6 genres. Each entry has `externalId`, `title`, `year`, `type`, `overview`, `genres`. No `posterURL` (the UI uses gradient placeholders per SPEC).
3. Implement `Services/MockMediaService.swift` that loads `MockMedia.json` from the bundle at init, holds the catalog in memory, and supports case-insensitive substring search across `title`.
4. Add `MockMediaServiceTests.swift`: bundle loads, search returns expected count for known queries, empty query returns empty results.

### Acceptance criteria
- `MockMediaService().search(query: "the")` returns a non-empty list and finishes in <50 ms.
- Switching to a future TMDB implementation requires touching only one class (no call-site changes elsewhere).
- Tests pass.

### Files created / modified
- `WatchRank/WatchRank/Services/MediaService.swift`
- `WatchRank/WatchRank/Services/MockMediaService.swift`
- `WatchRank/WatchRank/Resources/MockMedia.json`
- `WatchRank/WatchRankTests/MockMediaServiceTests.swift`

---

## Phase 2 — `MediaLibraryViewModel` (SwiftData bridge) ✅

**Goal:** The single layer that owns the bridge between `RankingEngine` (pure) and `MediaItem` (persisted).

### Steps
1. Create `ViewModels/MediaLibraryViewModel.swift`. Use the `@Observable` macro (per CLAUDE.md). Holds a SwiftData `ModelContext` injected from the App layer.
2. Public operations:
   - `addToWantToWatch(_ item: MediaItem)`
   - `markWatched(_ item: MediaItem, sentiment: Sentiment)` — sets `dateWatched`, returns the comparison plan (the bucket to compare against).
   - `applyComparisonResult(newItem:, position:)` — inserts at the position chosen by the engine, then triggers `recomputeBucket`.
   - `reorderBucket(items:, sentiment:, type:)` — for drag-to-reorder on `RankingView`.
   - `recomputeBucket(sentiment:, type:)` — calls `RankingEngine.recomputeScores` with the right range.
   - `bucket(sentiment:, type:)` — sorted query of items in a bucket.
3. Tests in `MediaLibraryViewModelTests.swift` using an **in-memory `ModelContainer`** (`.init(isStoredInMemoryOnly: true)`):
   - Marking an item watched and applying a comparison result puts it in the correct bucket with the correct score.
   - Reordering recomputes scores monotonically across the bucket.
   - Switching an item's sentiment moves it between buckets and recomputes both.

### Acceptance criteria
- View models for screens (Phases 4–9) only need to call methods on this VM — they never touch `ModelContext` or `RankingEngine` directly.
- All tests pass in an in-memory store; no on-disk side effects between tests.

### Files created / modified
- `WatchRank/WatchRank/ViewModels/MediaLibraryViewModel.swift`
- `WatchRank/WatchRankTests/MediaLibraryViewModelTests.swift`

---

## Phase 3 — Shared components ✅

**Goal:** The small SwiftUI building blocks each screen reuses. Building these first prevents per-screen drift.

### Steps
1. `Components/PosterPlaceholder.swift` — gradient card with the title initial. Param: `title: String`, `size: CGSize` (or aspect via modifier).
2. `Components/MediaCard.swift` — vertical card (poster placeholder + title + year). Used on Home rails.
3. `Components/MediaRow.swift` — horizontal row (placeholder + title/year/type + optional trailing score). Used in Search, Ranking, Profile.
4. `Components/EmptyStateView.swift` — SF Symbol + one-line copy + CTA closure. Used everywhere per SPEC's empty-state rule.
5. `Components/SentimentPicker.swift` — three-button picker over `Sentiment.allCases`. Bound via `Binding<Sentiment?>`. No raw numeric input.
6. Add `#Preview` blocks for each component covering at least one populated state and one edge case (e.g., very long title).

### Acceptance criteria
- All five components render cleanly in Xcode previews in both light and dark mode.
- No component knows about `ModelContext` or `RankingEngine` — they take plain data.
- No third-party imports.

### Files created / modified
- `WatchRank/WatchRank/Components/PosterPlaceholder.swift`
- `WatchRank/WatchRank/Components/MediaCard.swift`
- `WatchRank/WatchRank/Components/MediaRow.swift`
- `WatchRank/WatchRank/Components/EmptyStateView.swift`
- `WatchRank/WatchRank/Components/SentimentPicker.swift`

---

## Phase 4 — Search screen ✅

> Files written and type-check clean against the iOS SDK. `SearchViewModelTests` is written but not yet *run* (no simulator runtime installed at the time of writing).


**Goal:** A user can find a title and tap into Detail.

### Steps
1. `ViewModels/SearchViewModel.swift` — `@Observable`, holds `query`, debounced search state, and `results: [MediaItem]`. Depends on `MediaService` (protocol, not the concrete mock).
2. `Views/Search/SearchView.swift` — search bar (`.searchable`), list of `MediaRow`s, `EmptyStateView` for no-results and pre-query states. Tapping a row navigates to `MediaDetailView`.
3. Wire `MediaLibraryViewModel` in via environment so "Add to Want to Watch" works inline if exposed.
4. Tests: `SearchViewModelTests.swift` against a stub `MediaService` (empty, partial-match, exact-match).

### Acceptance criteria
- Typing a query updates results live (debounced ~300 ms).
- Empty query shows pre-query empty state, not a flicker of "no results."
- VM has zero SwiftUI imports.

### Files created / modified
- `WatchRank/WatchRank/ViewModels/SearchViewModel.swift`
- `WatchRank/WatchRank/Views/Search/SearchView.swift`
- `WatchRank/WatchRankTests/SearchViewModelTests.swift`

---

## Phase 5 — Detail screen ✅

> `MediaDetailView` written and type-checks clean; replaces the temporary search-result stub. Added `MediaLibraryViewModel.updateReview(_:to:)` (covered by a new test). The Mark Watched → Compare hop currently opens a clearly-marked `ComparePlaceholderSheet` that finalizes the ranking on dismiss — Phase 6 replaces it with the real comparison modal.


**Goal:** The full picture for one title plus the two state-changing actions (Mark Watched, Want to Watch).

### Steps
1. `Views/Detail/MediaDetailView.swift` — title, year, type, gradient `PosterPlaceholder`, overview, genre chips.
2. Action buttons:
   - **Mark Watched** → presents a `SentimentPicker` sheet; on selection, calls `MediaLibraryViewModel.markWatched(...)`, then presents `CompareView` (Phase 6) if the target bucket isn't empty.
   - **Want to Watch** → calls `addToWantToWatch`.
   - **Edit Review** → small sheet with a `TextEditor` bound to `MediaItem.review`.
3. If `watchedStatus == .watched`, render current `score` and `rankInBucket` prominently.
4. No view model required for this screen — it's a pure read-and-dispatch surface over `MediaLibraryViewModel`.

### Acceptance criteria
- The Detail screen handles all three watched states (watched / want / untracked) with no force-unwraps.
- The Mark Watched flow ends with either: (a) Compare modal presented, or (b) item placed at midpoint when the bucket was empty.
- Review edits persist via SwiftData.

### Files created / modified
- `WatchRank/WatchRank/Views/Detail/MediaDetailView.swift`

---

## Phase 6 — Compare flow ✅

> `CompareViewModel` + `CompareView` written and type-check clean; the Detail screen now opens the real modal instead of the placeholder. Design note: the binary search already lives in `MediaLibraryViewModel`, so `CompareViewModel` is a thin presentation adapter over that session rather than a second implementation — this keeps the `ceil(log2(N+1))` bound proven in one place. Added `MediaLibraryViewModel.cancelRanking(for:)` (midpoint placement) to satisfy the cancellation rule. `CompareViewModelTests` written (decision-count bound, top/bottom/midpoint placement, empty-bucket, progress) but not yet *run* pending a simulator runtime.


**Goal:** The pairwise comparison modal — the moment that defines the product.

### Steps
1. `ViewModels/CompareViewModel.swift` — `@Observable`. Holds `newItem`, the current sorted bucket, lo/hi indices for the in-flight binary search, and a derived `progress` ("Comparison X of Y" where Y = `ceil(log2(bucket.count + 1))`).
2. `Views/Compare/CompareView.swift` — modal sheet showing the new item and the current pivot side-by-side ("Which did you prefer?"). Two large tappable cards. Progress indicator at top.
3. After each tap, advance lo or hi; once `lo == hi`, dismiss the modal and call `MediaLibraryViewModel.applyComparisonResult(newItem:, position: lo)`.
4. Tests: `CompareViewModelTests.swift` — drive a full comparison sequence with a deterministic comparator, assert correct final position and that the VM made at most `ceil(log2(N+1))` decisions.

### Acceptance criteria
- The number of decisions a user must make is provably `≤ ceil(log2(N+1))` for a bucket of size N.
- The new item ends up at exactly the position the engine computes.
- The modal handles cancellation (dismiss without choosing) by leaving the item in its sentiment bucket at the midpoint, so the user is never blocked.

### Files created / modified
- `WatchRank/WatchRank/ViewModels/CompareViewModel.swift`
- `WatchRank/WatchRank/Views/Compare/CompareView.swift`
- `WatchRank/WatchRankTests/CompareViewModelTests.swift`

---

## Phase 7 — Ranking screen ✅

> `RankingViewModel` + `RankingView` written and type-check clean. Segmented All/Movies/TV tab; three collapsible sentiment sections; rows are `MediaRow`s (trailing score) that push to `MediaDetailView`; screen-level + per-section empty states. **Resolves open question #3 (cross-bucket drag):** drag-to-reorder is enabled only on the All tab (where the visible list maps 1:1 onto the full bucket the engine rescore) — **later inverted**, see below and is confined to a single sentiment section (each is its own `ForEach`), so drags never cross buckets and filtered-tab subsets are never reordered ambiguously. `RankingViewModelTests` written (filtering, empty state, reorder gate, move delegation) but not yet *run* pending a runtime.


**Goal:** The hero screen. Browse, collapse, and reorder your ranked items.

### Steps
1. `ViewModels/RankingViewModel.swift` — `@Observable`. Holds the selected `MediaType` filter tab (Movies / TV / All) and, for each `Sentiment`, an array of items sorted by score descending. Backed by `MediaLibraryViewModel` queries.
2. `Views/Ranking/RankingView.swift` — top-level segmented `Picker` over the three tabs. Below: three `DisclosureGroup`s (Liked / Fine / Disliked) each containing a `List` of `MediaRow`s with trailing score.
3. Enable drag-to-reorder inside each section via `.onMove`. On move, call `MediaLibraryViewModel.reorderBucket(...)`. The recompute step is implicit via the library VM.
4. Empty state per section using `EmptyStateView`.

### Acceptance criteria
- Reordering within a bucket immediately updates the visible scores and persists across app relaunches (verifiable via SwiftData store).
- Drag-to-reorder is constrained to within a single sentiment section. Cross-section drags are blocked or, alternatively, treated as a sentiment change (decide during this phase; document in the screen file).
- Switching the type tab does not flicker scores.

### Files created / modified
- `WatchRank/WatchRank/ViewModels/RankingViewModel.swift`
- `WatchRank/WatchRank/Views/Ranking/RankingView.swift`

---

## Phase 8 — Home screen ✅

> `HomeView` written and type-checks clean. Four horizontal rails (top movies, top TV, recently watched, want to watch) read straight off `MediaLibraryViewModel` via the environment (no new VM); per-rail empty states; cards push to `MediaDetailView`; a floating "+" presents `SearchView` modally. Added rail-accessor tests to `MediaLibraryViewModelTests` (score-desc ordering, 10/5 caps, status filtering) — written, not yet *run* pending a runtime.


**Goal:** The landing experience: top items by type, recent activity, queue, and a floating add button.

### Steps
1. `Views/Home/HomeView.swift` — four rails:
   - Top 10 ranked movies (horizontal `ScrollView` of `MediaCard`s, sorted by score desc).
   - Top 10 ranked TV shows.
   - Recently watched (5, sorted by `dateWatched` desc).
   - Want to watch (5, sorted by `dateAdded` desc).
2. Empty state per rail.
3. Floating "+" button (overlay) presenting `SearchView` modally.
4. No new view model — query `MediaLibraryViewModel` directly via environment.

### Acceptance criteria
- Each rail shows its empty state when no data is present.
- Tapping a card or the "+" button navigates correctly.
- Rails update live when ranking changes (validated by adding an item via Compare and watching it appear).

### Files created / modified
- `WatchRank/WatchRank/Views/Home/HomeView.swift`

---

## Phase 9 — Profile screen ✅

> `ProfileView` written and type-checks clean. No view model: the math lives in a pure `ProfileStats` value type (totals, movie/TV split, average score, all-time top 5, top-3 genres) computed from `MediaLibraryViewModel.allWatched` (new accessor); the view just renders it, and the empty state shows when nothing is watched. `ProfileStatsTests` verifies every field against a hand-built fixture (incl. genre tie-break) — written, not yet *run* pending a runtime.


**Goal:** Personal stats: scope creep risk, so keep it small.

### Steps
1. `Views/Profile/ProfileView.swift`:
   - Total watched count.
   - Breakdown by `MediaType` (movie vs. TV count).
   - Average score (across watched items only).
   - Top 5 of all time (across both types, by score desc).
   - Top 3 genres by count (flatten `genres` arrays from watched items).
2. All stats computed in the view from `MediaLibraryViewModel` queries — no separate VM unless the screen grows.

### Acceptance criteria
- Stats are correct against a hand-constructed fixture in an in-memory store.
- Profile renders an empty state when the user has zero watched items.

### Files created / modified
- `WatchRank/WatchRank/Views/Profile/ProfileView.swift`

---

## Phase 10 — App shell & wiring ✅ (verified on the iPhone 16 simulator, 2026-08-21)

> `RootTabView` (Home / Search / Ranking / Profile, each with its own NavigationStack so Compare presents over the active tab) written and type-checks clean. `WatchRankApp` now owns an on-disk `ModelContainer`, builds the shared `MediaLibraryViewModel` over its main context, injects the VM via `.environment` and the `MediaService` by init, and shows `RootTabView` instead of `ContentView`. **`ContentView.swift` left in place** (now dead code) pending user confirmation to delete — open question #4.
>
> **Verification (2026-08-21):** cold launch on iPhone 16 is clean — tab bar renders, all four Home rails show their empty states. The end-to-end loop is now covered by `WatchRankUITests/RankingFlowUITests.swift`, which launches with `-uiTestingInMemoryStore` (a new `WatchRankApp` hook that swaps the on-disk store for a throwaway one) and drives search → Mark Watched → sentiment → comparison → Ranking.
>
> **Bug found and fixed by that test:** every read on `MediaLibraryViewModel` goes through an untracked `modelContext.fetch`, which `@Observable` cannot see — so Ranking, Home, and Profile rendered once and never redrew after a ranking change (the newly ranked title simply never appeared on Ranking). Fixed with a `revision` counter bumped in `save()` and read by `allItems`, which gives every screen a real observation dependency. Regression test: `MediaLibraryViewModelTests.bucketReadIsObservable`.


**Goal:** Stitch the screens into a tab bar and bring the app up.

### Steps
1. `App/RootTabView.swift` — `TabView` with Home, Search, Ranking, Profile tabs (SF Symbol icons). Make sure Compare presents over the active tab rather than replacing it.
2. **Touch `WatchRankApp.swift`** for the first time: wire the SwiftData `ModelContainer` (with a `MediaItem` schema) and inject `MediaLibraryViewModel` into the environment. Replace `ContentView()` with `RootTabView()`.
3. Delete or repurpose `ContentView.swift` (Xcode-template artifact). Confirm with user before deleting.
4. Verify a cold launch on the iPhone 16 simulator: the tab bar renders, an empty Home screen shows empty states, Search returns mock results, and a full Mark Watched → Compare → Ranking loop completes.

### Acceptance criteria
- App launches on the iPhone 16 simulator with no warnings or crashes.
- Cold-launch → search → mark watched → compare → see item in Ranking works end-to-end.
- SwiftData persists across simulator relaunches.

### Files created / modified
- `WatchRank/WatchRank/App/RootTabView.swift`
- `WatchRank/WatchRank/WatchRankApp.swift` (modified)
- `WatchRank/WatchRank/ContentView.swift` (deleted or replaced — confirm with user)
- `WatchRank/WatchRankUITests/RankingFlowUITests.swift` (added during verification)

---

## Phase 11 — Polish & QA 🟡

> **Started 2026-08-23**, long after Parts II and III landed. An audit against this phase's
> own steps found three of them effectively already satisfied by later work — there are **no
> hardcoded colours anywhere** in the app, and 22 `EmptyStateView` sites across 13 screens
> cover step 1 more thoroughly than it asks. The VoiceOver path this phase is judged on
> (Mark Watched → Compare → Ranking) already carries combined labels and hints throughout.
>
> **What the audit found instead** — and what this pass fixed:
>
> 1. **Ranking rule 6 was only half implemented.** The rule says a withheld score is replaced
>    by a position ("#2 in Liked it"); that fallback existed on `MediaDetailView` and nowhere
>    else. On Ranking, Search and Profile a row in a sub-five bucket rendered a *blank*
>    trailing area — a watched, ranked title looked exactly like an unwatched search result,
>    for the whole of a new user's first session. Fixed with `Models/ScoreDisplay.swift` and
>    `MediaLibraryViewModel.scoreDisplay(for:)`: one resolver, four honest cases, three tests.
>    `MediaRow` now takes a `ScoreDisplay` rather than a `Double?`, because an optional could
>    only ever express "number" or "silence".
> 2. **`RankingView`'s file header described the inverse of the shipped rule** (see
>    `GAP-AUDIT.md` §5). Corrected, along with the same claim in `README.md`, `MANUAL-QA.md`
>    and this file.
> 3. **Five view files lived one directory too deep**, in a stray
>    `WatchRank/WatchRank/WatchRank/Views/`. Moved; the synchronized root group needed no
>    `.pbxproj` edit and the suite stayed green.
>
> **466 unit tests green** after the change, up from 463.
>
> **A second pass the same day** closed the rest of what the audit found:
>
> 4. **`Spacing` was written and then not adopted.** Discover and the social screens used it;
>    every Part I screen still carried literals. 25 values converted — but *only* those already
>    exactly on the 4-point scale, which makes them pure renames with no visual change. The
>    off-grid values (3, 5, 6, 10, 14pt) were left alone on purpose: they are the typographic
>    fine-tuning `Spacing.swift`'s own doc comment excludes, and nudging them to the nearest
>    step would silently restyle screens nobody has rendered yet.
> 5. **Two 9-point fonts that never scaled** in `RecommendationRow`'s predicted badge, now
>    `.caption2` with a `@ScaledMetric` minimum width. The badge is capped at
>    `accessibility1` — a trailing pill that keeps growing eats the title it belongs to — which
>    costs nothing, because it is hidden from VoiceOver and every word in it is already spoken
>    by the row's own label. `EmptyStateView`'s 44pt symbol now scales with `@ScaledMetric`:
>    an empty state is exactly where a user at a large text size is being asked to read.
>    `PosterPlaceholder`'s fixed glyph stays fixed, and now says why in place.
> 6. **Seven bare `ProgressView()`s** announced "in progress" and nothing else. Each now says
>    what it is loading. `SettingsView`'s zero accessibility modifiers turned out to be a false
>    alarm — it is a `List` of standard controls, which VoiceOver handles natively.
> 7. **`MANUAL-QA.md` gained Journey 7 (social)** — signed-out completeness, publishing consent,
>    follow/feed/comment, privacy and safety, and the check that rule 6 still holds on a foreign
>    profile. `README.md`'s status table and known-limitations list were rewritten against what
>    is actually true, including a pointer to `GAP-AUDIT.md`'s store blockers.
>
> **What remains is step 5, and it cannot be automated:** none of this has been seen rendered
> or heard under VoiceOver. The phase stays 🟡 until someone walks `MANUAL-QA.md` on a device.

**Goal:** Take the app from "works" to "feels premium" per the SPEC's UX bullets.

### Steps
1. **Empty states audit** — every empty state has illustration (SF Symbol), one line of copy, a CTA. Walk the app and fix gaps.
2. **Accessibility pass** — VoiceOver labels on `PosterPlaceholder`, `SentimentPicker`, Compare cards. Dynamic Type honored on all text.
3. **Dark mode verification** — visit every screen in dark mode; replace any hardcoded colors with system colors.
4. **Spacing pass** — generous padding per SPEC; consistent across screens.
5. **Manual smoke test** — full user journey on iPhone 16 simulator, plus a fresh-install run to confirm onboarding-by-emptiness works.
6. **README update** — mark MVP complete; note known limitations (no TMDB, no auth, no sync).

### Acceptance criteria
- VoiceOver can complete a Mark Watched → Compare → Ranking flow.
- No hardcoded colors remain (`Color(.systemBackground)` family only).
- Manual smoke test produces no crashes, no console errors, no missing empty states.

### Files created / modified
- Touch-ups across many files; no new screens.
- `/README.md` updated.

---

# Part II — Recommendations (v1.1)

**Scope change:** `SPEC.md` says "no recommendations in this MVP" and `CLAUDE.md` forbids network code "in this MVP" while explicitly allowing a later TMDB swap-in behind `MediaService`. Part II is that later. These phases start **after Phase 11 ships**; nothing here blocks or reorders Phases 0–11, and no phase below is allowed to change the ranking mechanic.

**Three decisions were made up front (2026-08-21) and everything below follows from them:**

1. **The catalog goes live.** TMDB is queried at runtime rather than the app shipping a hand-written JSON. `MockMediaService` is *not* deleted — it becomes the offline fallback, the preview fixture, and the source of truth for tests, which must never touch the network.
2. **The data layer comes before the algorithm.** TMDB decides what features exist, so it ships first (Phase 12) and the predictor is designed against measured feature distributions rather than assumed ones (Phase 13). The cost of the reverse order is building the engine twice.
3. **The recommendation candidate pool is ~1200 titles, cached on device.** A live API does not remove the need for a local pool: predicting a score means scoring every candidate against the user's taste profile, and doing that over the network per mood tap is both slow and rude to the API. The app keeps a refreshed local pool of popular titles per type and recommends out of it.

## The feature in one paragraph

The user picks a **media type** (movie or TV show), then picks a **mood** (crime, thriller, dark, horror, romance, …). The app returns **unwatched** titles, each carrying a **predicted score** on the same 0–10 scale the ranking system produces. The prediction is computed **locally** from the user's own ranked library — TMDB supplies catalog metadata, never a recommendation. There is no collaborative filtering (a single-user local app has nobody to collaborate with) and no model download. This is **content-based prediction**: the only signal is the overlap between a candidate's metadata and the metadata of what the user has already ranked.

## Design constraints inherited from the ranking system

Non-negotiable; every phase below respects them:

1. **Scores are bucket-relative, not absolute.** An item's score is a quantile within its `(type, sentiment)` bucket. A user's top film scores ~9.7 whether they merely liked it or consider it the best ever made. The coarse signal is *which sentiment bucket it landed in*; the fine signal is *where inside that bucket*. A predictor must treat a score as an ordinal position expressed on a 0–10 scale, not an absolute measurement of quality.
2. **Movies and TV are separate scales.** Rule 1 in `CLAUDE.md` keeps the types in independent buckets, each using the full 0–10 range. Averaging film scores with TV scores produces a meaningless number. Every baseline is computed **per type**; cross-type transfer is an explicit, documented decision — see open question 5.
3. **Sparse data is the normal case.** A user with 40 ranked titles might have three horror entries. A raw per-genre mean over n = 3 is noise wearing a decimal point. Shrinkage toward a baseline is mandatory, not an optimization.
4. **A number the app has not earned is not displayed.** Rule 6 withholds a *real* score until its bucket holds 5 items. A *predicted* score is weaker evidence, so it inherits the discipline: below a confidence floor the UI shows a qualitative band, not "7.4". See open question 7.
5. **Prediction stays local and offline-capable.** TMDB is a metadata source only. Every screen must render something useful with the network down, from the cached pool. No third-party Swift packages — `URLSession` and `Codable` only.

---

## Phase 12 — TMDB service and feature extraction ✅

> **Built 2026-08-21.** Steps 1–8 and 10 are done and covered: **154 unit tests pass, up from 92**, the whole pre-existing suite still green, and no test touches the network. `TMDBMediaService` satisfies the `verifyMediaServiceContract` helper `TestSupport.swift` has carried since Phase 1 in anticipation of exactly this swap.
>
> **Step 9 ran 2026-08-21** against the live API — 800 titles, 842 calls — and wrote [`FEATURE-SPACE.md`](./FEATURE-SPACE.md). It is script-generated: re-run `scripts/measure_feature_space.py` to refresh it, and do not hand-edit the numbers. What it found is recorded in the phases it affects (13, 14, 19) rather than in the data file.
>
> **The measurement contradicted three things this roadmap assumed**, which is the entire reason for running it before designing the engine:
>
> - **Keyword coverage is excellent, not thin.** 97.8% of films and 84.3% of series carry ≥ 5 keywords; the median film has 17. Open question 12 assumed this was the risk — it is not.
> - **Coverage does not decay with age.** Pre-1990 films are at 100%, 2010+ at 96.8%. The predicted fall-off is not there. One caveat kept honest: the sample is the popularity-ordered top 400, so its "tail half" is still popular. Obscurity is untested, and Phase 14's pool reaches further down than this measurement did.
> - **Cast is not the sparsest credit family.** The expectation stated in step 9 was that cast would be sparsest. It is the *densest* — three per title against one director means three times the chances to repeat. Directors are the sparse family.
>
> **Three findings worth carrying forward:**
>
> 1. **`INFOPLIST_KEY_*` cannot carry a custom key.** Step 1 specified injecting the token that way. Xcode maps only a fixed allow-list of Apple-defined keys and drops custom ones **silently** — `-showBuildSettings` shows `INFOPLIST_KEY_TMDBReadToken` resolving correctly, the build succeeds, and the key still never reaches the bundle. Fixed with a partial `Config/Info.plist` (`INFOPLIST_FILE`) that `GENERATE_INFOPLIST_FILE` merges its synthesised keys on top of. Both paths verified against the built `.app`: token present when configured, key absent when not.
> 2. **TMDB ids needed namespacing by type, not just by source.** Phase 12a specifies `tmdb:27205`, but TMDB ids are unique only *within* a type — movie 1396 and TV 1396 are unrelated titles, and `canonicalItem(for:)` dedupes on `externalId` alone. The shipped format is `tmdb:movie:27205`; a test asserts the un-namespaced form does not parse. **Phase 12a should be updated to match.**
> 3. **A plain detail fetch must not share a cache key with a feature fetch.** Both hit `/movie/{id}`, differing only by `append_to_response`. One key would let a search tap's credit-free response satisfy a later feature request, yielding a title with silently no cast or director — a wrong answer that looks like sparse metadata. `CatalogCacheKey.features` is separate, with a regression test.
>
> Adding `MediaItem.features` / `tmdbVoteAverage` is a schema change: the suite fails with a CoreData migration error until the app is deleted (`./scripts/deploy.sh --clean`), exactly as `CLAUDE.md` warns.

**Goal:** Replace the bundled catalog with the live TMDB API, behind the existing `MediaService` protocol, without the rest of the app noticing — and establish the **feature vocabulary** the predictor will be built on.

**Why this is first.** The prediction engine consumes features, and TMDB decides what features exist. Designing the engine against eight mock genre strings and then meeting real TMDB data — ~19 movie genres, a different TV genre list, and thousands of sparse user-contributed keywords — means designing it twice. Ship the data layer first, measure what it actually returns, and the engine gets built once against real distributions.

**Honest scoping note:** `CLAUDE.md` promises the TMDB swap is "a single-class replacement." That remains true *at the call site* — nothing outside `Services/` changes — but the class arrives with a support cast: key configuration, DTO mapping, a genre-vocabulary translation, a disk cache, and offline fallback. Budget a full session for this phase and expect it to be the largest in Part II.

### Steps

1. **API key handling.** TMDB v4 read token in a `Secrets.xcconfig` that is **gitignored**, surfaced to the app via an `Info.plist` key and read at launch. Commit a `Secrets.xcconfig.example` documenting the variable. A missing key must produce a clear, non-crashing "catalog unavailable" state that falls through to the cached pool — not a force-unwrap, per `CLAUDE.md`.
2. `Services/TMDBMediaService.swift` — conforms to `MediaService`. `URLSession` only. Endpoints: `/search/multi` for search, `/movie/{id}` + `/tv/{id}` for fetch, `/discover/movie` + `/discover/tv` for the Phase 14 pool, `/genre/movie/list` + `/genre/tv/list` for the vocabulary.
3. **Fetch the genre lists at runtime; do not hardcode the id tables.** They are small, cacheable, and hardcoding them bakes in a guess that silently rots.
4. `Services/TMDBDTOs.swift` — `Decodable` structs mirroring the API shape, mapped to `MediaItem` at the boundary. TMDB fields differ by type in ways that bite: movies use `title` / `release_date`, TV uses `name` / `first_air_date`. Both need a year parsed out of a `YYYY-MM-DD` string that is sometimes empty. `/search/multi` also returns `person` results, which must be dropped, not mapped to a broken `MediaItem`.
5. **Genre vocabulary translation.** The existing catalog says `"Sci-Fi"`; TMDB says `"Science Fiction"`. Worse, TMDB's TV vocabulary is *not* the movie vocabulary: TV has no Thriller, no Horror, and no Romance, and folds sci-fi into "Sci-Fi & Fantasy" and action into "Action & Adventure". Normalize both into one internal vocabulary at the DTO boundary, so `TasteProfile` never sees two spellings of one concept — a split vocabulary silently halves the evidence behind every genre effect.
6. **Disk cache.** Cache responses (and the Phase 14 pool) as JSON in Application Support with a TTL, **not** in the SwiftData store — the store holds the user's library, and mixing a disposable cache into it makes eviction a data-loss risk. Serve from cache when offline.
7. **`MockMediaService` stays.** Repoint it as the offline/preview/test implementation. Every existing test keeps passing against it, unchanged.
8. **Extract the full feature set for the user's watched items, in one pass.** A single request per watched title — `/movie/{id}?append_to_response=credits,keywords` and `/tv/{id}?append_to_response=aggregate_credits,keywords` — carries keywords, credits, and the cheap scalar metadata together. Fetch for the library only, not the whole pool, and cache the results.

   **`aggregate_credits`, not `credits`, for TV.** It rolls roles up across episodes with `total_episode_count`, which is the only sane basis for a TV cast credit; plain `/tv/{id}/credits` returns a snapshot that misrepresents who is actually in the show.

   Store everything as **one namespaced array**, `MediaItem.features: [String]` — not four parallel properties. This is the same key space Phase 13's `featureEffects: [String: Double]` uses, so the engine consumes it without translation and a future feature family costs a dictionary insert rather than a schema change. Families:

   | Key form | Source |
   |---|---|
   | `genre:Horror` | normalized per step 5 |
   | `keyword:1721\|neo-noir` | `keywords`, capped at 10 per title |
   | `era:2010s` | derived from `year` — no network call |
   | `runtime:epic` | `runtime` / `episode_run_time`, banded |
   | `lang:ja` | `original_language` |
   | `director:525\|Christopher Nolan` | crew `job == "Director"`; TV uses `created_by`, since episode directors vary but the showrunner does not |
   | `composer:947\|Hans Zimmer` | crew `job == "Original Music Composer"` |
   | `cast:6193\|Leonardo DiCaprio` | top 3 by `order`; TV top 3 by `total_episode_count` |
   | `franchise:86311\|The Avengers` | `belongs_to_collection`, movies only |
   | `network:213\|Netflix` | `networks.first`, TV only |

   `Models/Feature.swift` parses and formats the `family:id|Display Name` form, so the model keeps one `[String]` while call sites get `feature.family` / `feature.displayName` instead of string surgery. **Ids carry identity, names carry display** — person-name collisions are real, and an id alone cannot render a sentence.

   Cap cast at 3 and keywords at 10 so the array stays bounded; a TV `aggregate_credits` response runs to hundreds of people, so parse and discard rather than storing it.

   Also add `MediaItem.tmdbVoteAverage: Double?`. It is deliberately **not** a feature key — it is a scalar, used for the crowd-agreement statistic in Phase 19.

   This is a SwiftData schema change: delete the app from the simulator. Extracting every family here, rather than adding credits back in a later phase, is what keeps it a *single* change — Part II then costs exactly two simulator wipes total, this one and Phase 17's, instead of one per feature family someone thinks of.
9. **Measure the feature space before anyone designs against it.** Produce a one-off written record — checked into `docs/` — of what TMDB actually returns for a realistic library: genre frequency per type, keyword coverage (what fraction of titles have ≥ 5 keywords, and how that varies with popularity and release year), and the keyword sparsity curve. This is a half-hour of work that decides three things at once: whether tone moods are viable at all (open question 12), whether keywords are a real feature family or noise, and what shrinkage constants Phase 13 needs. Do not skip it and infer from vibes.

   **Measure credit density in the same pass**, because it is what decides whether a "favourite director" or "favourite actor" claim is displayable at all in Phase 19:

   - distinct directors / composers / cast members per N watched titles, per type
   - how many of each clear a support floor of 3, at library sizes of 20 / 50 / 100
   - how far cast members are *nested* inside directors — the share of an actor's appearances that fall under a single director (Phase 19's suppression rule depends on this)

   The expected shape, worth stating so the measurement can contradict it: cast is by far the sparsest family — ~10 billed actors per title means ~500 distinct people across 50 films, nearly all singletons — while composers repeat more than intuition suggests, because a composer spans directors. If that holds, cast feeds prediction but may never clear a display floor.
10. `WatchRankTests/TMDBMediaServiceTests.swift` — a `URLProtocol` stub serving **recorded JSON fixtures**. No test may hit the network: tests would then fail on a plane, fail in CI, and fail when TMDB has an incident.

### Acceptance criteria

- Search returns live TMDB results for both movies and TV, deduped, with `person` results excluded.
- Airplane mode: search and Discover both degrade to the cached pool with a visible but non-blocking "offline" indication. No spinner that never resolves.
- A missing or invalid API key produces a clear message, not a crash.
- No API key appears in any committed file — verified by `git grep` for the token pattern before the phase closes.
- Every test passes with the network disabled.
- `"Sci-Fi"` and `"Science Fiction"` cannot both reach a `TasteProfile` — asserted directly.
- Feature fetches are cached and never re-requested for an unchanged library.
- Every key written into `MediaItem.features` round-trips through `Feature`; an unrecognised family is dropped at the boundary, never crashed on.
- A title missing credits, keywords, runtime, or a collection still yields a valid — merely shorter — feature array. Sparse metadata is the normal case, not an error case.
- The feature-space measurement exists as a written artifact, not as something someone remembers running.

### Files created / modified

**As built:**

- `Services/TMDBMediaService.swift` — the service; `features(type:tmdbId:)` returns `ExtractedFeatures`
- `Services/TMDBDTOs.swift` — payload mirrors, `MediaItem` mapping, feature extraction, `TMDBIdentifier`
- `Services/TMDBGenreVocabulary.swift` — the two-vocabulary reconciliation
- `Services/TMDBConfiguration.swift` — credential loading, `TMDBEndpoint`, `TMDBError`
- `Services/CatalogCache.swift` — TTL disk cache + `CatalogCacheKey`
- `Services/FeatureProvider.swift` — library backfill + `FeatureSource`
- `Services/MediaService.swift` — adds `popularTitles(type:page:)` with a default implementation, so the seven existing test stubs keep compiling
- `Services/MockMediaService.swift` — real `popularTitles`; derives genre features so the offline path is thinner, not broken
- `Models/Feature.swift` — the `family:id|Display Name` key space
- `Models/MediaItem.swift` — adds `features`, `tmdbVoteAverage`
- `WatchRankApp.swift` — `makeService(isUITesting:)`, pinning UI tests to the mock
- `WatchRank/Config/{Base.xcconfig, Secrets.xcconfig.example, Info.plist}`, `.gitignore`, `project.pbxproj`
- `WatchRankTests/{TMDBTestSupport, TMDBMediaServiceTests, CatalogCacheTests}.swift`
- `scripts/measure_feature_space.py` — step 9, awaiting the key
- `docs/FEATURE-SPACE.md` — **not yet written** (step 9 output)

---

## Phase 12a — externalId migration ✅

> **Built 2026-08-21. 171 unit tests pass**, up from 154, whole suite green.
>
> **The id format is `tmdb:movie:27205`, not the `tmdb:27205` step 1 specified.** TMDB ids are unique only *within* a media type, so the un-namespaced form would let a film and a series collide in `canonicalItem(for:)` — the precise failure this phase exists to prevent, reintroduced by its own fix. `ExternalIDMigrationTests.typeMismatchDoesNotResolve` covers it, and `resolveIMDbID(_:expecting:)` constrains every `/find` lookup to the expected type rather than reading whichever result array happens to be non-empty.
>
> **Both id vocabularies are now namespaced.** `MockMediaService` mints `imdb:tt1375666`, and `ExternalID.canonical` collapses the historical bare `tt…` form onto it, so a library written before this change still dedupes against the bundled catalog. Identity comparisons in `canonicalItem(for:)` canonicalise both sides.
>
> **A bug the persistence test caught, in code written for Phase 12.** Both this migration and `FeatureProvider` saved the `ModelContext` they were *handed* rather than the one that owns the items. A `@Model` belongs to exactly one context, so when a caller holds a different context on the same container — normal, and what the test fixtures do — `save()` succeeds and writes nothing. Every in-memory assertion passes and the work vanishes at relaunch. Fixed with `Sequence<MediaItem>.saveOwningContexts()`, which saves through the objects; the injected context remains as the fallback for detached items. This is the second time in this project a green in-memory assertion has hidden a broken write — see the round-trip discipline in `PersistenceTests`.
>
> **Verified against the live API**: `/find` returns all five result arrays always (`movie_results`, `tv_results`, `person_results`, `tv_episode_results`, `tv_season_results`), an unknown id returns them all empty rather than a 404, and **12 of 12** sampled `MockMedia.json` ids resolve into TMDB. Recorded as fixtures, so the service path is tested rather than only the stub.
>
> **Known limitation, accepted:** a migrated library no longer dedupes against the *bundled* catalog, since an offline result cannot know its TMDB id. Marking an already-ranked film watched again while offline can still create a duplicate. The mock is a fallback only, so this trades a rare offline edge case for the common online one.

**Goal:** Stop the live catalog from orphaning the library the user already built. **Small, but it must land with or before Phase 12** — shipping the live catalog without it silently breaks dedupe.

> **Correction to step 1 below, as built:** the shipped format is `tmdb:movie:27205`, not `tmdb:27205`. See the note above.

`MediaLibraryViewModel.canonicalItem(for:)` identifies items by `externalId`, and today those are IMDb-style strings from the mock catalog (`tt1375666`). TMDB returns numeric ids (`27205`). Without a migration, a user who ranked Inception before the upgrade will see it as untracked in TMDB search, can mark it watched a second time, and can be asked to compare Inception against Inception in the comparison modal.

### Steps

1. Namespace the identifier — store `externalId` as a qualified string (`"tmdb:27205"`, `"imdb:tt1375666"`) so the source is never ambiguous.
2. One-time migration at launch: for each library item with a legacy `tt…` id, resolve it via TMDB's `/find/{imdb_id}?external_source=imdb_id` endpoint and rewrite the id. Items that fail to resolve keep their old id and still work — they simply will not dedupe against TMDB results, which is the pre-existing behavior, not a regression.
3. Make the migration idempotent and safe to run on every launch.

### Acceptance criteria

- A library built against `MockMedia.json` before the upgrade still dedupes correctly against TMDB search afterward — asserted with a fixture library.
- The comparison modal can never pit an item against itself.
- Running the migration twice changes nothing the second time.

### Files created / modified

**As built:**

- `Services/ExternalIDMigration.swift` — `ExternalID`, `IMDbResolver`, the migration
- `Services/TMDBMediaService.swift` — `resolveIMDbID(_:expecting:)`
- `Services/TMDBConfiguration.swift` — `TMDBEndpoint.find(imdbID:)`
- `Services/TMDBDTOs.swift` — `TMDBFindDTO`
- `Services/CatalogCache.swift` — `CatalogCacheKey.find(imdbID:)`
- `Services/MockMediaService.swift` — mints and accepts namespaced IMDb ids
- `Services/FeatureProvider.swift` — same context-save fix
- `Models/MediaItem.swift` — `saveOwningContexts()`
- `ViewModels/MediaLibraryViewModel.swift` — canonicalised id comparison; `allItems` now internal
- `WatchRankApp.swift` — `runStartupMaintenance()`, migration then backfill
- `WatchRankTests/{ExternalIDMigrationTests, TMDBMediaServiceTests, TMDBTestSupport, MockMediaServiceTests}.swift`

---

## Phase 13 — Prediction engine (pure logic) ✅

> **Built 2026-08-21. 219 unit tests pass**, up from 171, whole suite green. No schema change, so no simulator wipe. Implemented to [`PHASE-13-PLAN.md`](./PHASE-13-PLAN.md), whose five amendments to the spec below all survived contact with the code.
>
> **The plan's calibration formula was wrong, and the test written to prove it is why the phase caught it.** §4.5 specified `displayValue = value + confidence * (mapped - value)` using each candidate's *own* confidence. That reorders the list: a title with value 7.0 and confidence 0.9 overtakes one with value 7.1 and confidence 0.0, so the "provably order-preserving" property the whole decision rested on does not hold. Fixed by making the blend weight a property of the **profile** — the type-evidence term `min(1, n_t / TYPE_EVIDENCE_FULL)` — which is constant across a batch and therefore monotone. It is also the better reading: how well the app knows a user's *scale* is a fact about the user, not about the candidate.
>
> **The 0–10 clamp is provably unreachable, and a test asserting it fires would assert a falsehood.** A baseline is a mean of scores so it lies in `[0, 10]`; a shrunk effect with `K >= 0` is bounded by the largest residual; the family mix is a weighted average. Therefore `lift <= max(score) - baseline`, so `value <= max(score)`. Scaling a family weight does not break it either, because the prediction divides by `totalWeight` and the weight cancels. The clamp stays as a NaN guard; the test asserts the *invariant* over extreme fixtures rather than pretending the guard fires.
>
> **Reversal-invariance was the wrong determinism property to demand.** `+=` over residuals is not associative, so building a profile from a reversed library moves the last ulp (`-0.7577142857142859` vs `...52`). What Phase 17's rank correlation actually needs is same-input reproducibility and a *total* output ordering — both asserted exactly, with reversal checked to float tolerance.
>
> **`buildProfile` does not exclude an item mid-comparison.** `markWatched` seats a new item at its bucket midpoint *before* opening the session, so a provisional item is watched and scored and therefore indistinguishable from a settled one at this layer. The engine is pure and has no notion of a session. The effect is benign — a band midpoint is a fair prior for an item whose position is still being decided — but **Phase 15 owns the decision** and should filter on `isRankingInProgress` if it wants them out.
>
> **House note for future test-writing:** `#expect` does not handle rethrowing calls. `allSatisfy`, `contains`, and `sorted(by:)` inside the macro fail to compile with "call can throw, but it is not marked with 'try'". Hoist them into a local `let` first.

**Goal:** A `RecommendationEngine` that turns a user's ranked library into a taste profile and scores an arbitrary candidate against it. Zero UI, zero SwiftData, zero networking, `import Foundation` only — the same shape as `RankingEngine`, and testable the same way.

**Ordering note:** this phase follows Phase 12 deliberately. The engine itself has no external dependency and *could* be built first, but its feature space, its shrinkage constants, and its tests are only meaningful against the real feature distributions Phase 12 measures. Build it first only if the TMDB API key is blocked — and expect to revisit the constants once real data arrives.

### The algorithm

Written out so the implementing session does not have to re-derive it.

**Step 1 — Per-type baseline.** For type `t`, let `n_t` be the count of watched items of that type and `mean_t` their mean score. Shrink toward the overall watched mean `globalMean`:

```
baseline[t] = (n_t * mean_t + K_TYPE * globalMean) / (n_t + K_TYPE)     // K_TYPE = 3
```

With a healthy library this is just `mean_t`; with two ranked shows it mostly falls back to the global mean instead of swinging wildly.

**Step 2 — Genre effects as shrunk residuals.** For each watched item `i`: `residual_i = score_i - baseline[type_i]`. Residuals — not raw means — keep genre effects independent of the type baseline, so "I rate TV harshly" is not double-counted into every TV genre. For genre `g`:

```
genreEffect[g] = (Σ residual_i for watched items carrying g) / (n_g + K_GENRE)     // K_GENRE = 3
```

The denominator is `n_g + K_GENRE`, not `n_g` — that is the shrinkage. One horror film rated 2.1 above baseline yields +0.53, not +2.1. Ten of them yield +1.6. Evidence has to accumulate before it moves the number.

**Step 3 — Predict.** For candidate `c` of type `t` with feature set `F` (TMDB genres and keywords, both supplied by Phase 12):

```
predicted[c] = baseline[t] + Σ(effect[f] for f in F) / |F|
```

Clamp to `0.0...10.0`. The mean over `F` (rather than a sum) stops a title tagged with six features from accumulating six times the lift of one tagged with a single feature.

**Step 4 — Confidence.** Separate from the point estimate, and the thing the UI gates on:

```
evidence[c]   = (Σ n_f for f in F) / |F|                       // mean per-feature support
confidence[c] = min(1, evidence[c] / EVIDENCE_FULL)            // EVIDENCE_FULL = 8
                * min(1, n_t / TYPE_EVIDENCE_FULL)             // TYPE_EVIDENCE_FULL = 10
```

Two independent ways to be ignorant — "I know nothing about your taste in this genre" and "I know nothing about your taste in this media type" — and both must be satisfied before a prediction is called confident.

**The measured numbers, from [`FEATURE-SPACE.md`](./FEATURE-SPACE.md).** In a 40-title film library the median genre is supported by **7** watched titles and the median keyword by **1** — and that keyword figure stays at 1 at every library size measured, up to 80. Across 400 films, **66% of keywords appear on exactly one title**. Two consequences fall straight out:

- **`K_GENRE = 3` is about right; the same constant applied to keywords would silence them.** A keyword with support 1 under `K = 3` keeps a quarter of its residual. Since nearly every keyword has support 1, the whole family would contribute almost nothing while still diluting the Step 3 mean — the worst of both. Start at `K_KEYWORD = 1` and let Phase 17's cross-validation move it.
- **A support floor is needed as well as shrinkage.** Shrinkage handles a feature seen twice; it does not help a feature seen once, where the "effect" is one title's residual and nothing else. Drop keywords with library support < 2 from the profile entirely rather than shrinking them toward zero and paying for them in the denominator.

**Shrinkage must be per feature *family*, not one constant.** This is the concrete payoff of building the data layer first. Genres are dense — a 40-item library might have 20 dramas — while TMDB keywords are sparse, with any given keyword appearing on two or three watched items if it appears at all. A single `K = 3` that behaves sensibly for genres will let almost every keyword effect collapse to near-zero, and a `K` small enough to let keywords speak will let a two-item genre swing the prediction wildly. Namespace features by family (`genre:crime`, `keyword:neo-noir`) and give each family its own constant, chosen from the sparsity curve Phase 12 measured. Weight families in the Step 3 mean too: a title with two genres and thirty keywords should not be thirty-thirty-seconds keyword.

**Design the feature space as `[String: Double]` from day one**, not as a genre-specific type — Phase 17 may add era or runtime bands, and those should be dictionary inserts, not refactors.

**The engine consumes `MediaItem.features` verbatim as that key space.** Phase 12 already writes namespaced keys (`genre:`, `keyword:`, `director:`, `era:`, …), so `RecommendationEngine` never branches per family — it shrinks residuals over whatever strings it is handed. That indifference is what makes Phase 19 a presentation phase with no new math, and what lets a future family be added without touching this file.

### Steps

1. `Services/RecommendationEngine.swift` — a pure namespace, no stored state, mirroring `RankingEngine`.
2. `Models/TasteProfile.swift` — value type: `baselinesByType`, `featureEffects: [String: Double]`, `featureCounts: [String: Int]`, `featureSupport: [String: Set<UUID>]`, `watchedCountsByType`, `globalMean`. Built once by `buildProfile(from: [MediaItem])` and reused for every candidate in a request — building it per candidate is O(library × pool) for no reason. `featureSupport` records *which* items back each feature, not just how many; the counts fall out of it, and Phase 19's nesting rule needs the sets themselves.
3. `Models/PredictedScore.swift` — `value`, `confidence`, `evidence`, `topContributingFeatures: [String]` (for the "because you liked crime dramas" line in Phase 16). Keywords make this line much better than genres alone could: "because you like slow-burn neo-noir" is a sentence a user recognises.
4. Tuning constants — one per feature family — as named `static let`s in one place, so Phase 17's calibration work has a single knob panel.
5. `WatchRankTests/RecommendationEngineTests.swift`.

### Acceptance criteria

- An empty library yields predictions at exactly the neutral midpoint with confidence `0` — no crash, no `NaN`, no division by zero (library size 0, feature with 0 members, candidate with an empty feature set).
- A library where every horror entry is top-of-Liked and every romance entry is bottom-of-Disliked predicts a horror candidate above a romance one, with exact expected values asserted against a hand-built fixture.
- Shrinkage is asserted directly: the same +2.0 residual from 1 item vs. 10 produces effects in the documented ratio, so a refactor cannot quietly drop the `+ K`.
- A sparse-keyword fixture drawn from the real distributions in `docs/FEATURE-SPACE.md` does not let a single-occurrence keyword move a prediction more than a well-supported genre does.
- Predictions never escape `0.0...10.0`, including a fixture where every watched item sits at a range boundary.
- Movie and TV baselines are independent — harshly-rated TV does not contaminate generously-rated film.
- No `import SwiftData`, no `import SwiftUI`, no `URLSession`.

### Files created / modified

**As built** — two more files than planned, both justified in `PHASE-13-PLAN.md` §6:

- `Services/RecommendationEngine.swift` — `featureKeys(for:)`, `buildProfile`, `predict`, `calibrate`
- `Models/TasteProfile.swift` — effects, support sets, `itemTypes`, `droppedBelowFloor`
- `Models/PredictedScore.swift` — plus `FeatureContribution`, which carries `Feature` rather than the `[String]` originally specified, so Phase 16 renders a name instead of re-parsing a key
- `Models/RecommendationTuning.swift` — the knob panel, a struct rather than `static let`s so Phase 17 can sweep it
- `Models/CandidateFeatures.swift` — the `Sendable` snapshot that keeps scoring off the main actor
- `WatchRankTests/{RecommendationEngineTests, TasteProfileTests, RecommendationTuningTests}.swift`
- `WatchRankTests/TestSupport.swift` — `makeScored`, `bucketScores`, `makePlanFixtureLibrary`

---

## Phase 14 — Moods and the candidate pool ✅

> **Built 2026-08-21. 250 unit tests pass**, up from 219, whole suite green. No schema change, so no simulator wipe.
>
> **Three things implementation found on top of the measurement:**
>
> 1. **`RequestLog` recorded only `url.path`**, so it could not tell two `/discover/movie` calls apart — and the entire difference between a mood's genre component and its keyword component lives in the query string. A test asserting the two are cached separately could never have passed. Extended additively with `urls` / `count(inQuery:)`; `paths` is untouched.
> 2. **`TMDBGenreVocabulary` only mapped id → name.** Moods name genres in TMDB's spelling because a mood is a *query*, so the reverse lookup `tmdbGenreId(named:type:)` was added. It returns `nil` for a genre a type does not have, which is the normal case (television has no Thriller, Horror or Romance) rather than an error — that `nil` is what makes the keyword fallback automatic instead of hand-maintained.
> 3. **A stale comment in `TMDBMediaService` named a `KeywordProvider` that has never existed** — it meant `FeatureProvider`. Fixed in passing.
>
> **`MoodQueryComponent` is the shape that matters.** A mood is not one query: TMDB AND-s different `/discover` parameters, so `with_genres` + `with_keywords` asks for "genre AND keyword" and returns a plausible, non-empty, silently wrong result. Modelling a mood as a *list of components* puts that in the type system rather than in a comment. `thriller`/tv and `epic` are the two moods that span both bases, and `MoodTests` asserts they produce exactly two components each.
>
> **The page cap is recorded, never silent** — but only when it fires while a mood is still short. A component that stopped because the mood was already full was not truncated in any sense the caller cares about, and reporting it would make `truncated` noise instead of signal.
>
> **Planned in [`PHASE-14-PLAN.md`](./PHASE-14-PLAN.md); step 0 measured 2026-08-21.** Two acceptance criteria changed: pool size is an output rather than a target, and per-mood yield is measured after exclusions against a realistic library. Phase 15 step 4's ranking formula was fixed at the same time.
>
> **The measurement is in [`MOOD-YIELD.md`](./MOOD-YIELD.md)** — 296 API calls via `scripts/measure_mood_yield.py`, and it contradicted what this phase was organised around.
>
> **No mood is starved.** All twenty (mood, type) pairs clear ≥ 30 comfortably; the thinnest are `trueStory`/tv at **94** and `mindBending`/tv at **134**. Keyword-only TV moods are not a compromise — the `thriller` keyword returns 7 films but **132 series** and `horror` returns 58 films but **127 series**, because TMDB's TV vocabulary lacks those genres and taggers reach for the keyword instead. Open question 12's surviving caveat is answered: keyword *usefulness*, not just coverage, holds up.
>
> **The real defect was one level down — 7 of 32 candidate keywords were dead tags**, at ≤ 5 titles across both types: `feel good`, `heartwarming`, `alternate reality`, `mind bending`, `epic`, `dream`, `romantic comedy`, plus `historical event` and a duplicate (`based on a true story` and `based on true story` are both id 9672). **Three moods had named themselves after a tag that does not exist in practice.** The pattern: TMDB keyword ids above ~300000 are recently-minted and largely unapplied, while low-id tags carry the volume — the exceptions being TV-substitution tags like `thriller` (316362) and `horror` (315058), which are recent *and* heavily used precisely because the genre is missing for TV. **Check a keyword's volume before a mood rests on it**; the most on-the-nose tag is often the deadest.
>
> **Overlap is much lower than the correlated-exclusion argument assumed.** Highest Jaccard between any two mood pools is **0.18** (`crime` ∩ `thriller`), most below 0.10, and the worst post-exclusion survival at 100 watched titles is `comedy`/tv at 100 → 68. The criterion stays as written — it costs nothing and is the honest formulation — but it is no longer a live risk worth design effort.
>
> **A TMDB query constraint the roadmap does not mention:** within one `/discover` parameter `|` is OR and `,` is AND, but **two different parameters are AND-ed**. `with_genres=27&with_keywords=9714` means "horror AND supernatural", never "OR". Moods with both a genre and a keyword basis — `thriller`/tv and `epic` — need **two queries unioned client-side**, so `CandidatePoolBuilder` pages per *query component*, not per mood. Getting this wrong returns a plausible non-empty result, just a much smaller one.
>
> **Pool size lands at ~1600** (804 distinct films, 795 series) at 5 pages per query, with dedupe saving 25–27%. The ~1200 budget was the right order of magnitude.
>
> The shipping taxonomy is pinned in `MOODS` in `scripts/measure_mood_yield.py`, with rejects and their volumes in `RETIRED` so a later session does not re-propose them. `Models/Mood.swift` should port it verbatim.

**Goal:** Turn the words a user picks ("dark", "crime") into a concrete, cached set of candidates.

### Steps

1. `Models/Mood.swift` — `CaseIterable` enum with `displayName`, SF Symbol, and a **per-type** query definition: TMDB genre ids *and* keyword ids, with weights. Starting set: `crime`, `thriller`, `dark`, `horror`, `romance`, `comedy`, `mindBending`, `feelGood`, `trueStory`, `epic`.
2. **Per-type mood strategies are mandatory, not a nicety.** Phase 12 measured keyword coverage and it is ample — 97.8% of films and 84.3% of series carry ≥ 5 keywords — so tone moods are viable and TV moods can genuinely lean on keywords rather than being cut. TMDB's TV genre list has no Thriller, Horror, or Romance. A mood picker that offers "horror" and returns nothing for TV is a broken feature, so TV moods lean on keywords (`with_keywords`) and adjacent genres (Mystery, Drama) where the genre does not exist. Resolve keyword ids via `/search/keyword` once and cache them.
3. **Stratify the pool by genre — a pure popularity sort will not fill the narrow moods.** The measurement found the popularity-ordered film catalog is blockbuster-shaped: Action 42.5% and Adventure 40.8%, but Romance **9.5%**, Horror 12.8%, Crime 13.8%. Scaled to 1200 titles that is ~114 romance films, which clears the ≥ 30-per-mood-per-type bar — but only because the pool is large, and it leaves no margin once watched titles are excluded. Page each mood's genres explicitly rather than taking the global popularity head and hoping. Television is worse-shaped, not better: Drama alone is 62.3%.
4. **Pool builder.** Page `/discover/movie` and `/discover/tv` by `popularity.desc` with a `vote_count.gte` floor (a popularity sort with no vote floor surfaces junk), across the union of mood genres, until ~1200 distinct titles are cached — roughly 60 pages of 20, split across types in proportion to the catalog split. Store via Phase 12's `CatalogCache`.
5. **Refresh policy.** Rebuild the pool on a TTL (weekly is ample — the popular-title set does not churn daily) or on explicit pull-to-refresh. Never block a Discover tap on a pool rebuild; serve stale and refresh behind it.
6. Tests: mood definitions are total (every mood resolves to a non-empty pool for **both** types); pool builder dedupes across overlapping mood queries; TTL logic; all against recorded fixtures.

### Acceptance criteria

- Every mood in `Mood.allCases` yields **≥ 30 *eligible* candidates for each media type** from the cached pool, measured **after deduplication and after exclusions**, against a **realistic watched library** rather than an empty one — asserted in a test, so adding a mood with no TV coverage fails CI instead of shipping an empty screen. This is the criterion that the old 126-title catalog could not have met.

  **Against a realistic library, not a fresh one**, because exclusions are *correlated across moods*: `dark`, `thriller` and `mindBending` are largely the same popular titles, so a user who has watched the top 40 thrillers depletes all three at once. A mood that clears 30 on an empty library can be empty for exactly the user most likely to open Discover.
- **Pool size is an output, not a target.** The old criterion — "reaches ~1200 distinct titles" — is dropped: it is neither necessary nor sufficient for the yield criterion above, and it measures the wrong thing. Because the pool is paged **per mood** (step 3), per-mood coverage is guaranteed by construction and query overlap costs only storage, never coverage. Page each `(mood, type)` until it clears its bar; whatever the deduplicated union comes to is the pool. ~1200 survives as a **budget** for cache footprint and refresh cost, and asymmetric pools per type are expected rather than a smell — the two genre vocabularies are shaped differently.
- The cached pool survives an app relaunch.
- Building the pool costs no more than one paged sweep per `(mood, type)` per refresh, and never runs on the main thread.
- Discover works fully with the network off once the pool has been built once.

### Files created / modified

**As built:**

- `Models/Mood.swift` — ten moods, per-type genre and keyword bases, `MoodQueryComponent`, `MoodKeyword`, binary `relevance`
- `Services/CandidatePoolBuilder.swift` — an `actor`; `CandidatePool`, `PooledTitle`, paging/dedupe/TTL/serve-stale
- `Services/CandidateSource.swift` — the narrow protocol, following `FeatureSource`'s precedent rather than widening `MediaService`
- `Services/TMDBConfiguration.swift` — `discover(type:component:page:)`, `searchKeyword(_:)`, `defaultVoteFloor(for:)`
- `Services/TMDBMediaService.swift` — `CandidateSource` conformance, `genreVocabulary()`, `resolveKeywordId(_:)`
- `Services/TMDBGenreVocabulary.swift` — `tmdbGenreId(named:type:)` reverse lookup
- `Services/TMDBDTOs.swift` — `TMDBKeywordSearchDTO`
- `Services/CatalogCache.swift` — `pool(type:component:page:)`, `keyword(_:)`, `candidatePool`
- `Services/MockMediaService.swift` — `CandidateSource` conformance; genre components only, so offline Discover is thinner rather than broken
- `WatchRankTests/{MoodTests, CandidatePoolBuilderTests}.swift`
- `WatchRankTests/TestSupport.swift` — `makeFullGenreVocabulary`, `StubCandidateSource`, `makeFullStubSource`
- `WatchRankTests/TMDBTestSupport.swift` — `RequestLog.urls` / `count(inQuery:)`
- `scripts/measure_mood_yield.py`, `docs/MOOD-YIELD.md` — step 0

---

## Phase 15 — `RecommendationViewModel` ✅

> **Built 2026-08-21. 271 unit tests pass**, up from 250, whole suite green. No schema change.
>
> **The two-stage pipeline from `PHASE-13-PLAN.md` §3.1 landed here**, and step 2's single-pass signature was the right thing to amend. Stage 1 scores the whole mood pool on `genre:` + `era:` derived by `RecommendationEngine.featureKeys(for:)`; stage 2 fetches full features for the top `rerankDepth` (60) only and rescores. Stage 2 is **best-effort**: with no `FeatureSource`, offline, or on a failed fetch, the stage-1 ranking stands, so Discover degrades to a coarser list rather than an empty one.
>
> **The genre diversity cap is soft, and it has to be.** Step 5 says cap at ~40% and backfill — but those two goals are arithmetically incompatible on a narrow pool: at `limit = 20` and `cap = 8`, titles spread over two genres can only fill 16 slots. The cap is what gives, because eight rows on a browsing screen is worse than a concentrated twenty and the deferred candidates are the next-best ones anyway. Where the pool has the breadth, the cap holds exactly. Both behaviours have their own test.
>
> **Three fixture bugs worth recording, because each one made a test pass for the wrong reason:**
>
> 1. **Stub pool ids must parse as TMDB ids.** `tmdb:movie:pool0` is not a TMDB id, so `TMDBIdentifier.parse` returned `nil` and stage 2 silently never ran — the exact failure mode the two-stage design exists to prevent, reproduced inside its own test.
> 2. **A single-genre, single-sentiment fixture is degenerate for the predictor.** If every watched item shares one genre in one bucket, that genre's residuals sum to exactly zero by construction, its effect is zero, and no test asserting that a feature moves a prediction can ever pass. `makeRankedLibrary` now spreads items across all three sentiments and three genres.
> 3. **Exclusion must canonicalise both sides.** The library ids were run through `ExternalID.canonical` and the pool ids were not — the precise mismatch Phase 12a exists to prevent, failing the quiet way: an already-ranked title reappears as a recommendation.
>
> **The step 4 ranking fix cannot be caught through the public API today.** `moodWeight` is binary, so `value * weight` and `lift * weight` induce the *same* order; the bug only appears once moods are graded. `RecommendationViewModel.rankingScore(value:baseline:moodWeight:)` is therefore extracted and tested directly, with the counterexample asserted both ways.

**Goal:** The layer between the pure engine and the screen: assemble candidates, exclude what the user has dealt with, apply the mood, rank, hand back a display-ready list.

### Steps

1. `ViewModels/RecommendationViewModel.swift`, `@Observable`, depending on the candidate pool (Phase 14) and `MediaLibraryViewModel` (library + its `revision` counter).
2. `func recommendations(type: MediaType, mood: Mood, limit: Int = 20) async -> RecommendationResult`, where each `Recommendation` pairs a `MediaItem` with its `PredictedScore` and mood-match strength.
3. **Exclusions.** Drop `watchedStatus == .watched`. Keep `.wantToWatch` but flag it as already-queued — the user asked for *unwatched* titles, and a queued title is unwatched. Drop dismissals once Phase 17 adds them.
4. **Ranking.** Sort by `(predicted.value - baseline) * moodWeight` — **the lift, not the value** — tie-broken deterministically by title so the list does not reshuffle between renders. Do **not** sort by confidence: a confident 5.0 is a worse recommendation than a shaky 8.5, and confidence belongs in the display layer.

   **Why the lift and not the value.** `predicted.value * moodWeight` scales the *baseline* along with everything else, and the baseline is ~90% of the number while carrying zero discriminative information — it is identical for every candidate of a type. On the Phase 13 fixture (`baseline = 6.045`):

   | | Taste lift | `moodWeight` | `value * weight` | `baseline + lift * weight` |
   |---|---:|---:|---:|---:|
   | A | +0.70 | 0.9 | 6.07 | **6.68** |
   | B | +0.20 | 1.0 | **6.25** | 6.25 |

   Under the original formula **B wins**, though A fits the user's taste 3.5× better, because a 0.1 difference in mood weight was multiplied against 6.045 points of baseline that say nothing about either title. Mood relevance does not merely contribute — it drowns taste out.

   The bug is invisible while `moodWeight` is binary (every surviving candidate multiplies by 1.0) and activates the moment moods become graded, which is a direction Phase 14 deliberately leaves open. Fixed here while it is still prose.
5. **Diversity.** Cap any single genre at ~40% of the returned list; backfill from the next-best candidates. With a 1200-title pool this finally has room to work.
6. **Cold start.** `static let minimumLibraryForRecommendations = 10` watched overall and ≥ 3 of the requested type. Below that return `.needsMoreRankings(have:need:)` rather than confidently-wrong numbers — rule 6's instinct, one layer up.
7. **Caching.** Build the `TasteProfile` once per request; cache against `MediaLibraryViewModel.revision` so switching moods does not rebuild it. Invalidate when `revision` changes.
8. `WatchRankTests/RecommendationViewModelTests.swift` — in-memory `ModelContainer`, stub pool.

### Acceptance criteria

- No watched item ever appears — asserted where the top-predicted title is one the user already ranked.
- Below the cold-start threshold, `.needsMoreRankings`, never a populated list.
- Two identical requests return identical order (no `Set` iteration leaking into output).
- The diversity cap holds on a profile that heavily favours one genre.
- Profile built once per request, not once per candidate — asserted with a counting stub. Over 1200 candidates this is the difference between an instant screen and a visible hang.

### Files created / modified

**As built:**

- `ViewModels/RecommendationViewModel.swift` — `@Observable`, the two-stage pipeline, exclusions, cold start, soft genre cap, revision-keyed profile cache, `profileRebuilds` diagnostic
- `Models/Recommendation.swift` — `Recommendation` (item, prediction, `moodWeight`, `isQueued`, `lift`) and `RecommendationResult` (`.ready` / `.needsMoreRankings(have:need:type:)` / `.noCandidates(poolIsEmpty:)`)
- `WatchRankTests/RecommendationViewModelTests.swift`
- `WatchRankTests/TestSupport.swift` — `makeRankedLibrary`, genre support on `StubCandidateSource`

`needsMoreRankings` carries a `type` the roadmap did not specify, so the UI can name the **binding** constraint — "rank 2 more shows" rather than a number that does not match what the user is looking at.

---

## Phase 16 — Discover screen ✅

> **Built 2026-08-21. 288 unit tests pass**, up from 271, whole suite green. Installed and launched on the iPhone 16 simulator: five tabs, Discover present, no crash on launch.
>
> **A calibration bug that would have inverted the list.** `RecommendationEngine.calibrate` ranked by value with ties broken by *array position*, so a batch already sorted best-first handed its top candidate the lowest percentile and its bottom candidate the highest — calibration reversed exactly the list it exists never to reorder. Ties are not an edge case here: pool candidates routinely share every feature the first pass can see, so a whole batch tying is the normal path. Fixed with **midranks** — a run of equal values shares one percentile — which also makes the obvious guarantee true, that two titles the model cannot tell apart display the same number.
>
> **Phase 15 shipped without calling `calibrate` at all.** Decision D1 required it and nothing wired it up, so `displayValue` was always the muted raw estimate. Now applied in `RecommendationViewModel` **after** the diversity cap, so a title is mapped at its position in the list the user actually sees rather than against candidates that were never shown.
>
> **`PredictionDisplay` is a value type, not view logic.** Confidence gating is a product decision with thresholds in it — the rule that decides whether the app claims precision it has not earned — so it lives in `Models/` and is tested without rendering anything. Bands read the **lift**, not the value: at low confidence the absolute number sits near the baseline and says almost nothing, while its direction still does.
>
> **Not verified here, deliberately deferred to Phase 18:** dark mode, Dynamic Type, and the VoiceOver pass. `osascript` lacks assistive access in this environment, so the running screen could not be driven; the launch confirms the tab is wired and does not crash, and the screen's four states, the display rule and the calibration are covered by unit tests. Phase 18 already owns all three as explicit steps.
>
> **One real issue found and left for Phase 18 step 4.** A cold pool builds the *whole* sweep — every mood × every type × every component, up to ~150 requests — before the first mood tap can answer. It is once a week and behind a loading state, so it is not a correctness bug, but it belongs with the network-manners work rather than being silently expanded into this phase.

> **Corrected again 2026-08-21 — the cross-validation harness was measuring an artefact. 309 unit tests pass.**
>
> Diagnosed against a real 41-title library read out of the simulator's store. Two findings, and the second invalidates a chunk of Phase 17's premise.
>
> **Why the numbers looked clamped: the library is single-bucket.** All 41 watched titles are `liked`. A bucket's mean is its band midpoint for every N, so both type baselines are **exactly 8.400**; residuals are confined to the band half-width (±1.548); the strongest genre effect (0.378) contributes 0.114 after weighting and family averaging; and a stage-1 candidate carrying only genre and era has a raw spread of **0.095**, displaying as 8.37–8.44. Plan §1 predicted this exact case. It also means the ~85% of residual magnitude that comes from *bucket membership* does not exist for this user — only the noisy within-bucket ordering remains. No algorithm change creates that signal back.
>
> **The LOO harness was measuring itself.** Cross-validation reported the model as significantly *anti*-predictive: correlation −0.394, fitted slope −4.602. Raising support floors made it worse (−0.38 → −0.72) and so did more shrinkage, which ruled out sparse features and pointed at the baseline. It was: **the LOO baseline alone correlated −0.885 with the held-out score**, because removing a high scorer lowers the mean of what remains, and residuals sum to exactly zero inside a bucket. Its spread (0.258) matched the entire feature signal's, so it dominated.
>
> **The fix is to re-derive the fold, not to freeze the baseline.** A score is a *quantile over its bucket*, not an independent observation, so removing a title changes every remaining title's score. Recompute them and the bucket still averages its midpoint, so the baseline cannot move — verified exactly: `8.400000` on all 41 folds, spread `0.00e+00`. Freezing the full-library baseline instead, which was the first fix proposed here, papers over the artefact and leaks the held-out item; re-deriving removes it at the source. Corrected, the model measures **+0.187** — below the n=41 significance threshold of 0.31, so not yet demonstrably better than nothing, but not backwards.
>
> **Sample size alone is the wrong thing to shrink a calibration slope by.** On the corrected pairs the fitted slope is 2.557; size-only shrinkage keeps 2.047 and clamps to the 1.75 ceiling. But the model explains 3.5% of the variance, so that slope is almost entirely noise. Shrinking by explained variance as well — `λ = ρ² · n/(n+K)` — gives **1.037**, very nearly the identity it should be. The two rules disagree completely on real data, and the size-only one would have made the app look far more certain than it has earned.
>
> **`recomputingScores()` iterated a dictionary**, which left fold ordering hash-dependent and moved the last ulp of the profile's sums between two identical calls. Bucket order is now sorted, restoring the bit-determinism the engine is tested for elsewhere.
>
> **The general invariant, since the strong one does not hold for mixed libraries:** a fold's baseline may depend on the held-out item's *bucket* — losing a Liked title really does leave a harsher library — but never on its individual score. Single-sentiment libraries get the strong form for free. Both are asserted.
>
> **Corrected 2026-08-21 — the displayed rating was inflated, and the fix replaced the whole calibration approach. 304 unit tests pass.**
>
> **Symptom:** the top three of *every* mood displayed 9.9 / 9.6 / 9.3. Reproduced across five moods, and the tell was that the raw estimate behind them was **identical** — 6.652 in each — while the displayed number varied only with rank.
>
> **Cause: quantile mapping from candidate rank.** `calibrate` took a candidate's percentile *within its batch* and looked up the user's score at that percentile. The top of a 20-item batch is percentile 1.0, so it was handed the user's maximum score by arithmetic, in every mood, regardless of what the model thought.
>
> **The obvious repair does not work**, which is the part worth recording. Calibrating against a pool-wide reference instead of the batch still produced 9.32, because the flaw is quantile mapping itself: it assumes the candidates and the user's ratings describe the same population. They do not, in a way that guarantees inflation — **the unwatched pool is by definition depleted of the user's favourites, because they have already watched them.** Mapping the pool's top decile onto the user's top decile claims an equivalence that cannot hold. Stated at its starkest: with a library that is 50% "Liked", quantile mapping displays half of all popular unwatched titles as things the user would like — reproducing a hit rate they achieved by *curating*, on a set they did not curate.
>
> **My first proposed fix — drop numbers, show bands only — was an overcorrection**, and a design review caught it. The failure was candidate-set percentile specifically, not numeric prediction.
>
> **The replacement is a per-user affine calibration learned from leave-one-out error**: `display = μ + s(raw − μ)`, with `s` fitted from matched (predicted, actual) pairs over the user's own library, shrunk toward 1.0 by `n / (n + 20)` and bounded to `0.75...1.75`. A candidate's rating now depends only on what the model thinks of *it* — never on what it was listed beside. Verified end to end: the same fixture that displayed 9.9 now displays **7.04** against a raw of 6.65.
>
> **The null result is slope 1.0, and it is meaningful.** If `raw` is a well-calibrated conditional expectation then `E[actual | raw] = raw`, so the fitted slope is one and calibration correctly does nothing. `var(raw) = r²·var(actual)` besides — **a conditional expectation is under-dispersed by construction, so a compressed range is not evidence of miscalibration.** A slope above one is a finding about over-shrinkage, not an assumption to design around. Which makes `.identity` the correct default rather than a placeholder: with no evidence, the honest display is the raw estimate.
>
> **The 0–10 clamp is no longer unreachable.** The Phase 13 note proving it could never fire assumed lift bounded by the strongest family effect. At slope 1.75 and a centre of 6, an input of 10 maps to 13, so the clamp is now live and tested.
>
> **A guard that looked right and was not.** "Raw carries no information" is variance about **mean(raw)**, not about the pinned centre. A constant raw sitting off-centre produced a non-zero denominator, and least squares dutifully answered "slope 0" — compressing every title onto the user's average. Correct as an answer to "raw has no predictive power", wrong as an answer to "we have not learned anything yet". Caught by a test written from the doc comment.
>
> **Deleted:** both `calibrate` overloads, `Models/PredictionReference.swift`, and `CandidatePoolBuilder.cachedPool()`'s only consumer. The single-title path no longer needs a reference distribution at all — the same calibration serves one title and twenty.
>
> **Extended 2026-08-21 — predicted scores on the Detail screen. 298 unit tests pass**, up from 288.
>
> Discover was not the only place a user meets an unwatched title. Tapping any title they have not seen — from Search, from Home's queue, from anywhere — now shows what the app thinks they would score it, with the same confidence gate, the same band fallback and the same rationale line.
>
> **Calibrating one title needed a new reference.** `calibrate` maps a candidate's percentile *within its batch*, and a batch of one always sits at its own median — so every standalone prediction would have displayed the identical number. `PredictionReference` supplies the missing distribution: the engine's own predictions across the cached pool. "Above 85% of what we could recommend you" is a claim with something behind it, and it maps onto the user's own 85th-percentile score exactly as the batch path does.
>
> **A detail tap must never build the pool.** `CandidatePoolBuilder.cachedPool()` reads without building, so tapping a search result cannot trigger a ~150-request sweep. With no pool there is no reference, calibration is skipped, and the UI shows a band — honest rather than invented.
>
> **Detail enriches before predicting**, which Discover cannot afford per candidate: one detail fetch for one title while the user is looking at it, turning a guess resting on two genres into one resting on keywords, cast and a director.
>
> **A latent pool-corruption bug, found through a fixture that lied.** `build()` keys titles by `externalId` across both type passes and never checked that a returned title matched the type requested. Production is safe — Phase 12a namespaces ids (`tmdb:movie:X` vs `tmdb:tv:X`) so they cannot collide — but the test stub handed both passes the *same* ids, the TV pass overwrote every movie entry, and the movie reference distribution came back empty. The stub now namespaces by type as reality does, and `build()` carries the guard regardless: a mismatched title would otherwise vanish from its own type's pool without a sound.

**Goal:** The UI: pick a type, pick a mood, see unwatched titles with predicted ratings.

### Steps

1. `Views/Discover/DiscoverView.swift` — two-step surface. Step one: segmented `Picker` for Movie / TV, then a grid of mood chips from `Mood.allCases`. Step two: results.
2. `Views/Discover/RecommendationRow.swift` — reuses `MediaRow`'s language with a trailing **predicted** badge that is visually distinct from a real score (outlined, not filled; the word "predicted" for VoiceOver). Confusing a prediction with an earned score would undermine the ranking system's whole claim to precision.
3. **Confidence-gated display**, mirroring rule 6: above the floor show the number; below it a qualitative band ("Likely a hit" / "Worth a shot" / "Probably not for you"). The number is always computed — only its display is withheld.
4. One-line rationale per row from `topContributingFeatures` — "because you rate crime thrillers highly". Cheap, and the difference between a number the user trusts and one they ignore.
5. Row tap pushes `MediaDetailView`; inline "＋ Want to Watch" so the screen closes its own loop.
6. States: cold start (`EmptyStateView`, copy naming the exact number of rankings still needed, CTA into Search); no candidates for this mood+type; loading; **offline-and-pool-empty**.
7. Add **Discover** as a fifth tab in `App/RootTabView.swift` with its own `NavigationStack`.
8. **Real posters, now that TMDB supplies them.** `poster_path` is available and `MediaItem.posterURL` already exists. Load with `AsyncImage`, falling back to the existing `PosterPlaceholder` gradient on failure or while loading — so the gradient stays the offline and error state rather than being deleted. SPEC's "gradient placeholder" rule is amended, not abandoned.

### Acceptance criteria

- Fresh install shows the cold-start state with an accurate count — not an empty list, not a spinner.
- Predicted badges are never mistakable for real scores — verified in light and dark mode, and by VoiceOver reading "predicted 8.2".
- Switching moods re-ranks with no visible hang over the full 1200-title pool.
- Every empty state has symbol, one line of copy, and a CTA, per SPEC.
- Adding a recommendation to Want to Watch updates the Home rail with no manual refresh (the `revision` observation path from Phase 10).
- A poster that fails to load leaves a gradient placeholder, never a blank box.

### Files created / modified

**As built:**

- `Views/Discover/DiscoverView.swift` — type picker, mood grid, four states, `MoodChip`
- `Views/Discover/RecommendationRow.swift` — outlined predicted badge, rationale line, queue swipe
- `Models/PredictionDisplay.swift` — the confidence gate and the qualitative bands
- `Models/RecommendationTuning.swift` — `confidenceFloorForDisplay`, so the knob panel stays one place
- `Components/PosterPlaceholder.swift` — adds `PosterView`; every non-success `AsyncImagePhase` falls back to the gradient
- `ViewModels/RecommendationViewModel.swift` — calibration wired in after the diversity cap
- `Services/RecommendationEngine.swift` — midrank tie handling in `calibrate`
- `App/RootTabView.swift` — fifth tab, `recommender` optional so a tokenless build has no Discover tab rather than one that can never answer
- `WatchRankApp.swift` — `makeRecommender(service:library:)`
- `WatchRankTests/PredictionDisplayTests.swift`, plus calibration suites in `RecommendationEngineTests` and `RecommendationViewModelTests`

**Detail-screen predictions (same phase, added after):**

- ~~`Models/PredictionReference.swift`~~ — deleted by the calibration correction below
- `Models/TitlePrediction.swift` — one title's prediction, lift, and whether it was enriched
- `Models/RatingCalibration.swift` — the learned affine mapping, shrunk by explained variance as well as sample size
- `Models/RankedSnapshot.swift` — value-space library, so a fold can be simulated without rewriting the user's real scores
- `Services/RankingEngine.swift` — `scores(count:range:)` extracted, one definition of the quantile inset
- `Services/RecommendationEngine.swift` — `leaveOneOutPairs(for:)` and `calibration(for:)`
- `Services/CandidatePoolBuilder.swift` — `cachedPool()`, plus the requested-type guard in `build()`
- `ViewModels/RecommendationViewModel.swift` — `prediction(for:)`, reference cache keyed on `revision`
- `Views/Detail/MediaDetailView.swift` — the predicted section, quieter than the earned score by design
- `WatchRankApp.swift` — recommender into the environment, so pushed detail views can reach it

---

## Phase 17 — Calibration & feedback ✅

> **Built 2026-08-21. 326 unit tests pass**, up from 309.
>
> **The gate passes — on the fixture and on a real library.** Cross-validation over the user's actual 49-title library: **Spearman ρ = +0.366** against a threshold of 0.283, MAE 1.102 beating both nulls (baseline 1.165, modal 1.164), Precision@10 = 1.00 against a base rate of 0.86. The feature effects are signal, not noise.
>
> **That result arrived because the library gained a second bucket.** Measured the day before at 41 titles all `liked`: ρ = +0.187, not significant, prediction range 8.37–8.44. At 49 titles with 7 marked "It was fine": ρ = +0.366, significant, range **7.50–8.46**. Seven ratings in a second bucket roughly doubled the correlation and widened the output tenfold — direct confirmation that ~85% of the signal is bucket membership, and that the binding constraint on prediction quality is *sentiment diversity*, not tuning.
>
> **`MediaItem`'s schema change did not need a simulator wipe, contrary to `CLAUDE.md`.** `predictedScore` and `predictedAt` are optional and `dismissed` is defaulted, so SwiftData lightweight-migrated in place: all 50 items survived, the three columns appeared, no crash. The blanket rule is right for renames, type changes and relationships and **too conservative for purely additive optional/defaulted properties**. The library was exported to a gitignored backup first regardless, which is the discipline worth keeping.
>
> **The accuracy line refuses to speak when the correlation is not significant.** "Predictions land within 1.1 points" reads as a result and is one only if the ordering holds up; below threshold Profile says so instead. Quoting an error without a rank test would dress a number as a finding.
>
> **Step 5 (auto-tuning constants) was not built, deliberately.** It was conditional on cross-validation showing that constant choice matters, and the evidence points elsewhere: the calibration slope is already shrunk by explained variance, and on the real library it lands near identity. Tuning `K_GENRE` against ρ = 0.37 at n = 49 would be fitting noise. Revisit past ~150 ranked titles.

**Goal:** Find out whether the predictions are any good, and let the user correct them. Phases 12–16 ship a plausible algorithm; this is what makes it an accountable one.

### Steps

1. **Record the prediction.** When a recommended item is added to Want to Watch, persist `predictedScore` and `predictedAt` on the `MediaItem`. (Schema change — delete the app from the simulator.) When it is later watched and ranked, the app holds a matched pair: what it guessed, and what the user's own comparisons produced.
2. **Accuracy surface.** Mean absolute error over matched pairs plus a hit rate. Show it as one honest line on Profile — "predictions are landing within 1.3 points" — or behind a debug toggle if it reads as too inside-baseball. Decide during the phase.
3. **Leave-one-out cross-validation as a test.** Hold out each watched item, build the profile from the rest, predict the held-out item, and report **rank agreement first, error second**. Runs against a fixture library in `WatchRankTests` and is the only honest way to tune `K_GENRE` / `K_TYPE` without shipping a guess.

   **Rank agreement is the primary metric, not MAE** — a correction to what this phase originally assumed, and it follows from [`PHASE-13-PLAN.md`](./PHASE-13-PLAN.md) §1. A stored score is a *quantile within its bucket*, so it changes whenever the bucket grows, without the user's opinion changing. MAE is measured against a target that moves under it; Spearman is invariant to exactly that drift. Report, in this order:

   | Metric | Role | Notes |
   |---|---|---|
   | **Spearman ρ** — LOO-predicted order vs. actual order | **Primary gate** | One number, drift-invariant, and it has a real significance threshold: ρ > 0.31 at n = 40, ρ > 0.22 at n = 80. Sharpens as the library grows, which is the right direction for a gate. |
   | **MAE vs. the null models** | Secondary gate | Keep — it is the interpretable number Profile displays in step 2. |
   | **Precision@10 over the Liked bucket** | Sanity check | Answers "does the top of the list hold things they'd actually love". Weak baseline (≈ 0.50 when half the library is Liked), so read it as a smoke test, not evidence. |
   | **Calibration by confidence decile** | Diagnostic | Bin LOO predictions by confidence and check MAE decreases monotonically. If it does not, `confidence` is decoration and Phase 16 must not gate on it. |

   NDCG@10 and hit rate are deliberately **not** on this list. At n = 40 an NDCG over a single 40-item list is one number with no variance estimate, and hit rate needs a "loved" threshold that would have to be invented. Revisit both once real libraries exceed ~200 items.

   **Two null models, not one.** Because roughly 85% of a residual's magnitude is bucket membership rather than within-bucket position (`PHASE-13-PLAN.md` §1), always-predict-`baseline[type]` (MAE ≈ 2.39 on a 20/12/8 library) is the easy null and always-predict-the-modal-sentiment-midpoint is the hard one. Beating only the first is a weaker result than it looks.
4. **Dismissal.** "Not for me" swipe on a recommendation row, persisted so the title stops appearing. The only *negative* signal available without asking the user to rate something unseen.
5. **Optional, only if step 3 justifies it:** auto-tune shrinkage constants per user by minimising LOO error over their own library. Build it if and only if cross-validation shows constant choice actually matters at realistic library sizes.

### Acceptance criteria

- LOO cross-validation over a realistic fixture library (≥ 40 items, varied genres) achieves **Spearman ρ above the n-appropriate significance threshold** (0.31 at n = 40) against the user's actual score order. **This is the phase's real deliverable** — the number itself is the acceptance criterion. If it fails, the feature effects are noise and the algorithm needs rethinking, which is exactly what the test is for.
- The same fixture beats **both** null models on MAE — always-baseline and always-modal-sentiment-midpoint. Secondary to the rank criterion above, because the target drifts as buckets grow.
- Confidence deciles are monotone in LOO error, or `confidence` is demoted from a display gate to a diagnostic and Phase 16 is amended.
- Matched prediction/actual pairs survive relaunch.
- A dismissed title never reappears under any mood.
- Tuning constants live in exactly one place.

### Files created / modified

**As built:**

- `Models/MediaItem.swift` — `predictedScore`, `predictedAt`, `dismissed`
- `Models/PredictionAccuracy.swift` — the metric suite plus `Ranks` (midranks, Pearson, Spearman)
- `Services/RecommendationEngine.swift` — `accuracy(for:)`, confidence deciles, both nulls
- `ViewModels/MediaLibraryViewModel.swift` — `addToWantToWatch(_:predicted:)`, `dismiss`, `undismiss`, `matchedPredictions`
- `ViewModels/RecommendationViewModel.swift` — dismissals join the exclusion set
- `Views/Profile/ProfileView.swift` — the accuracy section, plus `RevisionCache` so cross-validation never runs in a `body` evaluation
- `Views/Discover/{RecommendationRow, DiscoverView}.swift` — "Not for me", and the guess frozen on queue
- `WatchRankTests/RecommendationAccuracyTests.swift`

---

## Phase 18 — Discover polish & QA ✅ (code complete; visual/VoiceOver pass is manual)

> **Built 2026-08-21. 331 unit tests pass**, up from 326.
>
> **Request coalescing was genuinely missing** and is the one substantive gap this phase found. `TMDBMediaService` had no in-flight deduplication, so a cold pool build — where overlapping moods ask for the same `/discover` page within milliseconds — issued a separate round trip per caller. Now keyed by URL, with the check-and-insert under one lock so two callers arriving together cannot both miss. Retries were already absent, which is the right posture: a failed call falls back to a stale cache entry rather than turning one outage into several.
>
> **Posters are now decorative.** `PosterPlaceholder` carried its own "Poster for Dune" label, so VoiceOver read every title twice — once as artwork, once as the row. Containers already name the title; the artwork is silent.
>
> **The remaining polish is inherently manual and is logged, not claimed.** Dark mode, Dynamic Type at accessibility sizes, and the VoiceOver walkthrough cannot be driven from this environment (`osascript` has no assistive access). `docs/MANUAL-VERIFICATION.md` item 2 carries them, and `MANUAL-QA.md` Journey 6 is the script to follow — cold start, recommendations, the feedback loop, the Detail prediction, airplane mode, and accessibility.
>
> **Performance is bounded by a test rather than measured on device.** Ten mood requests over a full pool with a 100-title library, asserting the profile is built once and the whole sweep stays well inside a loose ceiling. A deliberate non-goal: a tight millisecond gate would be flaky in CI and would fail for reasons unrelated to the code.

**Goal:** What Phase 11 does for the MVP, applied to the recommendation surface and the network layer.

### Steps

1. Accessibility pass on mood chips (the primary control — must not be symbol-only to VoiceOver), predicted badges, dismissal swipes, and poster images (decorative, so they should not be announced).
2. Dark mode and Dynamic Type across `DiscoverView` at the largest accessibility sizes — mood chip grids break first.
3. Performance: profile build + rank + diversity over the full 1200-title pool, under 100 ms, off the main thread if not. Also check memory — 1200 cached entries plus poster images is the first time this app has had a real footprint.
4. **Network manners:** request coalescing, cancellation on view dismissal, no retry storms on a failing endpoint, and a check that the app is not re-fetching the pool on every launch.
5. Extend `docs/MANUAL-QA.md` with a Discover journey: cold start → rank 10 → Discover returns sensible results → add to queue → watch and rank → accuracy recorded. Plus an **airplane-mode pass** over every screen.
6. Update `README.md` and `docs/SPEC.md`: "no recommendations" becomes "recommendations shipped in v1.1"; "no network" becomes "TMDB for catalog metadata, local-only for user data"; the algorithm summarised in three sentences.

### Acceptance criteria

- VoiceOver completes pick-type → pick-mood → add-to-queue unaided.
- No hardcoded colors; system colors only.
- Airplane-mode pass produces no crashes, no infinite spinners, no empty screens without explanation.
- Manual QA journey passes on iPhone 16 with no console errors.

### Files created / modified

- Touch-ups across the Discover and TMDB files
- `docs/MANUAL-QA.md`, `README.md`, `docs/SPEC.md`

---

## Phase 19 — Taste analysis ✅

> **Measured 2026-08-21, and the news is bad for the headline feature.** From [`FEATURE-SPACE.md`](./FEATURE-SPACE.md), the number of people seen **at least three times** in a library of a given size:
>
> | Library | Film directors | Film composers | Film cast | TV directors | TV cast |
> |---:|---:|---:|---:|---:|---:|
> | 20 | 0.0 | 0.3 | 0.1 | 0.0 | 0.0 |
> | 50 | 0.4 | 2.3 | 1.7 | 0.2 | 0.0 |
> | 100 | 2.3 | 8.2 | 9.2 | 0.9 | 0.1 |
>
> **A "your favourite director" card is empty below roughly 100 watched films, and is empty at every measured size for television.** Design this phase around that rather than discovering it in the UI: either gate credit claims behind a support floor and show nothing until it is cleared — the same discipline as ranking rule 6 — or drop the director card and lead with composers and cast, which clear the floor three to four times more often. Credits still feed *prediction* at any library size; what the measurement rules out is *displaying* them early.
>
> Two secondary findings: **composers repeat more than directors** (8.2 vs 2.3 at 100 films), because a composer spans directors — the hunch in Phase 12 step 9 was right. And **cast nesting is 50%**: for actors seen more than once, half their appearances fall under a single director, so "you like this actor" and "you like this director" are substantially one observation counted twice. The suppression rule this phase assumes is justified.

> **Built 2026-08-21. 341 unit tests pass.** Part II is complete.
>
> **No new mathematics, as promised.** Every number on the screen comes from the profile the recommender already builds, so what the app *says* about the user and what it *recommends* to them cannot disagree. The phase is selection, suppression and presentation.
>
> **`ProfileStats.topGenres` is removed rather than left alongside.** It ranked by count — "what do you watch most" — which is a duller question than the taste screen's effect-ranked claims *and* would visibly contradict them on the same screen. Two lists disagreeing about one library is worse than one fewer list. Its coverage moved to `TasteAnalysisTests.rankedByEffect`.
>
> **Nesting suppression is per-claim-set, not per-family.** A feature whose supporting titles are ≥ 80% contained in an already-shown, higher-effect feature is dropped. The 80% floor is anchored to the measurement: for actors seen more than once, the median share of appearances under a single director is 50%, so 80% suppresses genuine restatement without hiding an actor the user follows *across* directors. Both directions are asserted.
>
> **Crowd agreement stays a sentence, not a coefficient.** Spearman over the user's score order against TMDB's `vote_average` order — never a mean difference, which would be meaningless given bucket-relative quantiles. But "0.41" is inside-baseball and "you are a contrarian" is a characterisation the app would be putting in the user's mouth, so it renders as "Your ranking loosely tracks the crowd." The test that matters proves it is rank-based: invariant under any monotone rescaling of the user's scores.
>
> **A Swift-specific snag worth noting:** the headline contrast built with inline string interpolation defeated the type checker outright ("unable to type-check this expression in reasonable time"). Built as a plain `String` first, then handed to `Text`.

**Goal:** Turn the `TasteProfile` the engine already builds into a legible portrait of the user's taste — what they gravitate toward, what they actually rate highly, and where those two disagree.

**Why this is last.** Phase 17's leave-one-out cross-validation is the only evidence that feature effects are signal rather than noise. A *prediction* the user disagrees with is dismissible — it is a guess about a film they have not seen. A stated fact about their own taste that is wrong is not: "your favourite director is X" reads as the app not knowing them, and it costs trust the ranking mechanic spent 18 phases earning. Build this once the harness says the effects hold up.

**No new math.** Phase 13 already computes shrunk residual effects over a namespaced feature space, and Phase 12 already populates it. This phase is selection, suppression, and presentation.

### Steps

1. `Models/TasteAnalysis.swift` — a pure value type, `init(profile: TasteProfile, watched: [MediaItem])`. No SwiftData, no SwiftUI, no networking. Same shape as `ProfileStats` in `Views/Profile/ProfileView.swift`, which is the house precedent for view-agnostic derived stats and the reason they are trivially testable.
2. **Rank by effect, not by count.** Features come from `profile.featureEffects` sorted descending, with the deterministic alphabetical tie-break `ProfileStats` already uses. A count-ranked list answers "what do you watch most", which is a different and far less interesting question — and one the user can already answer themselves.
3. **Per-family support floors.** A feature is displayable only once `profile.featureCounts[f]` clears its family's floor. Many-per-title families (genre, keyword, cast) accumulate support faster per title watched than one-per-title families (director, composer, franchise, network), so the floors differ; the values come from the credit-density measurement in `docs/FEATURE-SPACE.md`, not from taste. Constants live in the Phase 13 knob panel, not scattered at call sites. This is rule 6's instinct — *no number the app has not earned* — one layer further out.
4. **Nesting suppression.** Suppress a feature whose supporting item set is ≥ 80% contained in that of an already-displayed, higher-effect feature. This is what stops "favourite actor: Leonardo DiCaprio" from being a restatement of "favourite director: Martin Scorsese". The shrunk residual credits both features fully for the same films, which is harmless inside a prediction — the `/ |F|` averaging damps it — but misleading as a displayed claim about the person. Pure set logic over `profile.featureSupport`, directly testable.
5. **Show count and effect together; the disagreement is the headline.** "You have watched 22 Dramas — they land on your baseline. Your 6 Sci-Fis run +1.4 above it." Either number alone is duller and less honest than the pair. This supersedes `ProfileStats.topGenres`, which is removed rather than left to contradict the new screen.
6. **Crowd agreement is a rank correlation, never a score difference.** Design constraint 1 above says scores are bucket-relative quantiles: a user's top film scores ~9.7 whether they merely liked it or consider it the best ever made. So `mean(userScore − tmdbVoteAverage)` measures nothing, and "you rate 1.2 points harsher than the crowd" would be a fabrication dressed as a statistic. Compute **Spearman rank correlation** between the user's score order and TMDB's `vote_average` order across watched items carrying both. "Your ranking agrees with the crowd about two thirds of the time" is a claim this data actually supports.
7. `Views/Profile/TasteAnalysisView.swift` — `List` + `Section` + `LabeledContent` per existing Profile conventions. Sections: headline contrasts, genres and keywords by effect, people (director / composer / cast, each appearing only if it clears its floor and survives suppression), era & runtime & language, crowd agreement.
8. `Views/Profile/ProfileView.swift` — replace the Top Genres section with a compact "Your taste" teaser card showing the top two contrasts, behind a `NavigationLink` into `TasteAnalysisView`. Profile already owns its own `NavigationStack`, and the tab bar is full at five after Phase 16.
9. **Cold start.** Below a minimum library, `EmptyStateView` naming the exact number of rankings still needed plus a CTA into Search — the pattern `ProfileView` and Phase 15's `minimumLibraryForRecommendations` already use. Never a screen of features at n = 1.
10. **Cache against `revision`.** `ProfileStats` is rebuilt on every body evaluation, which is fine at its cost but not for a multi-pass feature tally plus set-containment checks. Build the analysis once per `MediaLibraryViewModel.revision` change. Any new library accessor must route through `allItems` or touch `revision`, or the screen renders once and never updates — the Phase 10 observation bug, which has a regression test for exactly this reason.
11. `WatchRankTests/TasteAnalysisTests.swift` — Swift Testing (`@Suite` / `@Test` / `#expect`), store-free over hand-built `MediaItem`s, mirroring `ProfileStatsTests`. Float comparisons use the existing `abs(a - b) < 0.0001` idiom.

### Acceptance criteria

- A feature below its family's support floor never appears, at any library size — asserted directly, per family.
- Nesting suppression asserted with a fixture where an actor appears only in one director's films: the director surfaces, the actor does not. Asserted again with an actor spread across three directors: both surface.
- Ranking is by effect, not count: a fixture whose most-watched genre is *not* its highest-rated must render them as two distinct claims, never conflated into one.
- Crowd agreement is invariant under any monotonic rescaling of the user's scores — the test that proves it is a rank correlation and not a mean difference in disguise.
- Empty library, a single watched item, and an item with an empty feature array each produce a valid analysis: no crash, no `NaN`, no division by zero.
- The screen renders fully with the network off, from the store alone. Taste analysis is about data the user generated; it must never depend on a live catalog.
- No `import SwiftData` and no `import SwiftUI` in `TasteAnalysis.swift`.

### Files created / modified

**As built:**

- `Models/TasteAnalysis.swift` — `Claim`, `Contrast`, floors, nesting suppression, crowd agreement
- `Views/Profile/TasteAnalysisView.swift` — headline, genres, themes, people, context, crowd
- `Views/Profile/ProfileView.swift` — "Your taste" link; `topGenres` removed
- `WatchRankTests/TasteAnalysisTests.swift`, `ProfileStatsTests.swift` (coverage moved)

---

# Part III — Social (v2.0)

> **Architecture, schema, trust model and design rationale live in [`PART-III-SOCIAL.md`](./PART-III-SOCIAL.md).** Read it before starting any phase below — the phases implement decisions made there, and several acceptance criteria below only make sense against them (the bucket-as-sync-unit rule, the public anon key, one-post-per-session).

**Part III starts after Phase 19.** Part II finishes first; nothing here changes Phases 14–19.

**The founding constraint is lifted.** "Local-only, no backend, no auth, no social" held through v1.1. From Phase 20 the user's ranked library is publishable, identity is a server-side account, and there is user-generated content. What does *not* change is the ranking mechanic: `RankingEngine` stays pure and local, scores stay derived from bucket position, the comparison flow never waits on a network, and the whole app stays usable signed out (`PART-III-SOCIAL.md` §2).

**Backend:** Supabase — PostgREST + GoTrue over a hand-rolled `URLSession` client, behind protocols, in `Services/`. Zero SPM dependencies, matching the TMDB precedent exactly.

---

## Phase 20 — Supabase project, schema, and RLS ✅ (27/27 RLS tests green, 2026-08-21)

> **Done 2026-08-21.** Migration applied and the pgTAP suite run against a local Postgres (`supabase start` with the other twelve containers excluded, on an 8 GB machine shared with a concurrent Part II session). Three defects were found by running it that reading it had missed — see *What running it caught* below. Remaining user action: create the hosted project and paste the URL + anon key into `Config/Secrets.xcconfig`.

### What running it caught

1. **`language sql` bodies are name-resolved at creation.** All five policy helpers referenced tables declared later in the file, so `supabase start` failed on the first one. The file is now sectioned in dependency order — enums → tables → helpers → policies → triggers → indexes → feed → grants — and grouping each table with its own policies, which reads better, does not work.
2. **The grant block was decoration.** Supabase's default privileges hand `anon` *and* `authenticated` the full privilege set on every new table, so the minimal per-table grants added nothing. Most seriously that included **TRUNCATE, which RLS does not filter** — any authenticated user could have erased `posts` wholesale without a single policy being evaluated. Fixed by revoking from both roles before granting; asserted by tests 13–14.
3. **The feed query did not scale.** `where user_id in (select followee_id …) order by created_at desc` cannot use `posts_feed_idx` for the ordering, and read 2101 rows to return 20 on a 6000-row table. Rewritten as a lateral merge of one indexed stream per followee: 400 rows for a 20-post page, verified at 50,000 posts.

**Goal:** A database that is correct and safe before a single line of Swift talks to it.

### Steps

1. Create the Supabase project. Record the project URL and anon key; add `SUPABASE_URL` / `SUPABASE_ANON_KEY` to `Config/Secrets.xcconfig.example` and surface them through `Config/Info.plist` the same way `TMDB_READ_TOKEN` is — Xcode drops custom `INFOPLIST_KEY_*` keys silently, so the partial plist is mandatory, not stylistic.
2. Write the migration: `profiles`, `follows`, `ranked_items`, `posts`, `comments`, `reactions`, `blocks`, `reports`, plus the `media_type` / `sentiment` / `post_kind` / `follow_state` enums. Schema sketch in `PART-III-SOCIAL.md` §5.
3. **Enable RLS on every table and write the policies** (§6). A table with RLS off is a table anyone can read with the anon key and `curl`.
4. Triggers: create a placeholder `profiles` row on `auth.users` insert; maintain `posts.comment_count` and `posts.reaction_count`. Counts are trigger-maintained precisely because the client must not be able to write them.
5. Indexes for the feed query: `posts (user_id, created_at desc, id desc)` — `id` is in the index because the cursor pages on `(created_at, id)`, so the tiebreak has to be orderable too — plus `follows (follower_id) where state = 'active'` and `ranked_items (user_id, media_type, score desc)`.
6. Handle constraints: 3–20 chars, `[a-z0-9_]`, plus a reserved-word list (`admin`, `watchrank`, `support`, …). **Built with plain `text unique`, not `citext`:** the format check already forbids uppercase, so the handle is lowercase by construction and an ordinary unique constraint is case-insensitive for free — no extension, and no `extensions`-schema qualification on the column type.
7. `supabase/tests/rls_test.sql` — a SQL test script run against a local `supabase start`.

### Acceptance criteria

- **The negative cases pass, asserted in SQL, because they are the ones that matter:** an anonymous caller reads nothing from any table; a signed-in user cannot read a non-follower's `ranked_items`; a blocked user cannot read the blocker's posts; a client cannot insert a post with someone else's `user_id`; a client cannot update `comment_count`; a client cannot update another user's `profiles` row.
- Deleting an `auth.users` row cascades to every table that references it — no orphaned comments, follows, or posts.
- The feed query (§9) is a single indexed query with no sequential scan on `posts`, verified with `explain`.
- A fresh checkout with no `Secrets.xcconfig` still builds and runs, signed out, social disabled.

### Files created / modified

- `supabase/migrations/20260821210000_social.sql` — 8 tables, 4 enums, 5 policy helpers, 24 policies, 8 triggers, 6 indexes, the `feed()` RPC (the CLI orders migrations by the leading timestamp, so the planned `0001_` name would not have been picked up by `db reset`)
- `supabase/tests/rls_test.sql` — 27 pgTAP assertions, 23 of them negative
- `supabase/config.toml`, `supabase/.gitignore` (from `supabase init`)
- `WatchRank/Config/Secrets.xcconfig.example`, `WatchRank/Config/Info.plist`, `WatchRank/Config/Base.xcconfig`
- `docs/PART-III-SOCIAL.md` (record any schema deviations)

---

## Phase 21 — Networking foundation ✅

> **Built 2026-08-21. 359 unit tests pass**, up from 341. No test touches the network.
>
> **Single-flight refresh is the whole reason this is an `actor`**, and it is verified: ten concurrent 401s produce **exactly one** refresh call. Supabase rotates refresh tokens, so refreshing per-401 would invalidate all but one and sign the user out on the busiest screen — which is the screen that fires concurrent requests in the first place.
>
> **A stale 401 is not a second failure.** A request that set off before someone else's refresh completed will 401 through no fault of the new token. `sessionGeneration` catches that: seeing the generation has already moved, the client returns the current session rather than spending another refresh and rotating a token that was just replaced.
>
> **403 is deliberately not 401.** An RLS denial is the expected outcome of asking for a row you cannot see, and treating it as a dead session would sign a user out for browsing a profile they do not follow. Asserted directly, including that the session survives.
>
> **Two date shapes, one decoder.** Postgres `timestamptz` returns ISO-8601 with fractional seconds sometimes and without them other times; a decoder handling one fails on real data. Both are tried, and a test pins that they agree to the millisecond.
>
> **The anon key is in the bundle on purpose.** It identifies the project and carries no privilege — row-level security is the entire authorisation boundary. Signed out, it is sent as *both* `apikey` and bearer, which is what lets policies written against `anon` serve public reads with no session at all.
>
> **Local Supabase was deliberately not started.** The machine is an 8 GB M1 Air already sitting at 3.2 GB of swap, and the full stack is six containers. Phase 21 is stub-tested by design, so nothing was blocked — but every phase in Part III now carries the same caveat, logged in `docs/MANUAL-VERIFICATION.md`: **none of this has been run against a real Supabase project.**

**Goal:** One HTTP client every social service is built on: auth headers, token refresh, typed errors, and a stub-friendly seam.

### Steps

1. `Services/Supabase/SupabaseConfiguration.swift` — URL + anon key from `Info.plist`, with an `isConfigured` flag. Mirrors `TMDBConfiguration`.
2. `Services/Supabase/SupabaseClient.swift` — `URLSession`-based, injectable session (so `StubURLProtocol` works), `apikey` + `Authorization` headers, JSON encode/decode with a shared date strategy, and PostgREST specifics: `Prefer: return=representation`, `Range` for pagination, `on_conflict` for upserts.
3. `Services/Supabase/KeychainTokenStore.swift` — access + refresh token in the Keychain. Never `UserDefaults`.
4. **Single-flight refresh.** An actor serialises refresh; concurrent 401s await one refresh and retry, rather than firing N refreshes and invalidating N−1 of them. A feed screen makes parallel requests, so this is the common case, not the edge case.
5. Typed errors: `.unauthorized`, `.forbidden` (an RLS denial — distinct from unauthorized and must not trigger a sign-out loop), `.conflict`, `.transport`, `.decoding`, `.notConfigured`.
6. Tests against `StubURLProtocol` (reused from `TMDBTestSupport.swift`).

### Acceptance criteria

- A 401 refreshes once and retries once; a second 401 after refresh signs out rather than looping.
- Ten concurrent requests hitting 401 together produce **exactly one** refresh call — asserted with a counting stub.
- A 403 does **not** sign the user out. RLS denials are an expected outcome of asking for something you cannot see.
- Tokens survive relaunch; sign-out clears the Keychain.
- No test touches the network.

### Files created / modified

- `WatchRank/WatchRank/Services/Supabase/{SupabaseClient,SupabaseConfiguration,KeychainTokenStore}.swift`
- `WatchRank/WatchRankTests/SupabaseClientTests.swift`, `SupabaseTestSupport.swift`

---

## Phase 22 — Accounts, handles, and the signed-out app ✅

> **Built 2026-08-21. 378 unit tests pass**, up from 359.
>
> **The invariant is asserted, not assumed.** `SignedOutInvariantTests` ranks two films end to end through the real comparison flow with `SessionViewModel(service: nil)`, and does the same for Discover and taste analysis. If the social layer ever reaches into ranking, that test fails rather than the app quietly requiring a login.
>
> **`.unavailable` is a distinct state from `.signedOut`.** A build with no Supabase credentials has nothing to sign in *to*, so offering a form that cannot work would be worse than explaining. The Profile account section disappears entirely rather than offering a dead button.
>
> **A taken handle is decided by the 409, not the probe.** Two people can pass an availability check for the same handle in the same second and only one insert wins, so `claimHandle` catches the conflict and the pre-check is explicitly advisory. The sign-up form will *not* block submission on a stale "taken" result for the same reason — a handle that just freed up must remain claimable.
>
> **Sign-up rolls back rather than stranding a half-account.** The handle is claimed after the account exists, because it needs the user id; if that insert fails the client signs back out, so a retry starts clean instead of leaving a signed-in session with no profile.
>
> **The mock enforces the same rules as the real service** — handle validation, taken handles, password length, duplicate email — so a passing test is testing the app rather than the stub's leniency. Both are driven through one contract suite.
>
> **Sign in with Apple (step 5) was not built.** It is a system framework with no dependency cost, but it needs an entitlement, a configured Services ID, and a real device to verify — none of which an autonomous session can do. Logged in `docs/MANUAL-VERIFICATION.md` rather than half-built.

**Goal:** Sign up, sign in, sign out, claim a handle, edit a profile — and prove the app is still whole without any of it.

### Steps

1. `Services/AuthService.swift` (protocol), `SupabaseAuthService`, `MockAuthService`. GoTrue `/auth/v1/signup` and `/auth/v1/token`.
2. `ViewModels/SessionViewModel.swift`, `@Observable`, publishing `.signedOut | .signedIn(UserProfile)` — placed in the environment at the app root.
3. `Views/Auth/` — `SignInView`, `SignUpView`, `HandleClaimView`. Handle availability check debounced against `profiles`; the unique constraint is the real arbiter, so handle the 409 rather than trusting the check.
4. Profile edit: display name, bio, avatar, `is_private`.
5. **Sign in with Apple** via `AuthenticationServices` if it fits the phase (system framework, no dependency). Not a compliance requirement until a third-party provider is offered.
6. **Signed-out rendering everywhere.** Social entry points show a sign-in prompt; nothing else changes.

### Acceptance criteria

- **The existing 219 tests pass unchanged, with no session.** This is the phase's most important criterion: if ranking a movie now needs a login, invariant 3 is broken.
- Search → Mark Watched → sentiment → compare → Ranking works end to end, signed out, offline.
- A taken handle fails cleanly on the server's 409, not only on the client's pre-check.
- Sign-out clears tokens and every cached remote object; the next launch is signed out.
- An unconfigured build (no `Secrets.xcconfig`) shows social as unavailable rather than crashing or hanging.

### Files created / modified

- `WatchRank/WatchRank/Services/{AuthService,SupabaseAuthService,MockAuthService}.swift`
- `WatchRank/WatchRank/Models/UserProfile.swift`
- `WatchRank/WatchRank/ViewModels/SessionViewModel.swift`
- `WatchRank/WatchRank/Views/Auth/*.swift`, `App/WatchRankApp.swift`, `App/RootTabView.swift`
- `WatchRank/WatchRankTests/{AuthServiceTests,SessionViewModelTests}.swift`

---

## Phase 23 — Publishing the library ✅

> **Built 2026-08-22. 395 unit tests pass**, up from 378.
>
> **The outbox marks centrally rather than at each call site**, because "remember to enqueue everywhere" is precisely what the vacated-bucket bug got wrong twice. Mutations mark a dirty `(type, sentiment)` key; `save()` flushes the set into rows. The unique key makes coalescing free — rank five films and the queue holds one row, so it grows with buckets touched, never with how fast the user ranks.
>
> **And the first version still missed two paths, which the tests caught.** `recomputeBucket` covers re-rating, but a title entering an *empty* bucket never recomputes anything, and an abandoned comparison session never reaches `finalizeRanking`. Both went unpublished. Fixed by marking the joining bucket in `markWatched` itself, where every path passes. The trap is real enough to have caught the fix for it.
>
> **A payload is always the whole bucket.** Every score in a bucket is a quantile over its current size, so publishing one row would strand the survivors on the server with scores computed for the old N — the vacated-bucket bug with a network in the middle. Asserted directly, and `bucket_size` travels on every row so a *viewer* can apply rule 6 rather than trusting the sender to have counted.
>
> **A failed publish never touches local state.** The ranking is the user's; the server holds a copy. The row stays, `attempts` increments, and a test pins that the local scores are byte-identical after a failed drain.
>
> **Titles with no `externalId` are counted, not dropped.** The bundled catalog and unresolved migrations produce them, and `SyncEngine.unpublishableCount` exists so the UI can say "3 titles are not published" rather than quietly omitting them.
>
> **An emptied bucket is a delete, not an empty upsert**, or an un-watched title stays visible to followers. The upsert path also deletes anything the server still holds for that bucket which is no longer in it, so a title that changed sentiment cannot appear in two buckets at once.
>
> **The schema change needed no wipe.** Adding a whole new `@Model` entity lightweight-migrated exactly as the additive properties did in Phase 17: `ZPENDINGPUBLISH` appeared, all 51 items survived, no crash. `CLAUDE.md`'s warning remains right for renames and type changes.

**Goal:** The local ranking reaches the server, in whole buckets, without ever blocking the ranking flow.

### Steps

1. `Models/PendingPublish.swift` — a SwiftData `@Model` outbox row keyed by `(mediaType, sentiment)`.
2. **Enqueue at every bucket-mutating site**, which is the same set of call sites the vacated-bucket fix identified: insertion, reorder, sentiment change, un-watch, delete. An item leaving a bucket owes the *old* bucket a publish as well as the new one.
3. `Services/SyncEngine.swift` — coalesce duplicate rows, drain on a background task, on foreground, and on connectivity return. Batch upsert a whole bucket per request (`on_conflict=user_id,media_type,external_id`).
4. **Items with a nil `externalId` never publish.** The mock catalog and unresolved migrations produce them; they stay local, and the UI states plainly that N titles are not published rather than dropping them silently.
5. Publish `bucket_size` alongside rank, so rule 6 is enforceable by any viewer.
6. First-run consent: an existing local library is **not** uploaded silently on sign-in. The user is told what becomes visible and opts in.
7. Tests: outbox coalescing, whole-bucket payloads, retry idempotence, offline queueing, and that a failed publish never mutates local state.

### Acceptance criteria

- **A publish payload always contains every item in the affected bucket** — asserted directly. Publishing only the touched item is the vacated-bucket bug with a network in the middle: survivors keep scores computed for the old N.
- Ranking a title with the network off completes at local latency and the publish drains later, unchanged.
- Killing the app mid-publish loses nothing; the outbox survives relaunch.
- Re-running a drained queue is a no-op (the payload is the full bucket).
- Un-watching an item removes its server row **and** republishes the bucket it left.

### Files created / modified

- `WatchRank/WatchRank/Models/PendingPublish.swift`
- `WatchRank/WatchRank/Services/SyncEngine.swift`
- `WatchRank/WatchRank/ViewModels/MediaLibraryViewModel.swift`
- `WatchRank/WatchRankTests/{SyncEngineTests,PublishPayloadTests}.swift`
- SwiftData schema change — **no wipe needed**, verified: a new entity lightweight-migrates.

---

## Phase 24 — The social graph ✅

> **Built 2026-08-22. 414 unit tests pass**, up from 395.
>
> **Blocking is one `FollowState` case, not two.** A blocked person must not be able to tell which direction the block went, so the client never holds that information — and a blocked account raises `notFound` rather than anything more specific, making it indistinguishable from an account that does not exist.
>
> **A block severs both edges.** Leaving them would keep the blocked person's activity arriving in a feed built from follow rows, which is how a block "works" everywhere except the one place the user would notice. Asserted by blocking, unblocking, and checking the edge is gone.
>
> **The server decides `active` versus `pending`, always.** Only it knows whether the target is private, so the optimistic guess is replaced by whatever comes back rather than trusted. The optimistic state rolls back on failure — a phantom follow would survive until the next refresh and mislead everything downstream that reads the graph.
>
> **`relationship(with:)` is one RPC, not three requests.** Edge state plus both counts arrive together, so the follow button never renders half-populated and then jumps.
>
> **The client filters nothing that matters.** Every visibility rule — private libraries, blocks — is enforced by row-level security. What the client does is ask; what it receives is already filtered. A client-side check would be a weaker second copy of the policy that drifts from it.

**Goal:** Find people, follow them, and see who follows you.

### Steps

1. `Services/SocialService.swift` (protocol) + `SupabaseSocialService` + `MockSocialService`. This phase defines the graph half; Phases 26–27 extend it.
2. User search by handle and display name, debounced, paginated.
3. Follow / unfollow / cancel request / accept request, with `is_private` producing `pending` rather than `active`.
4. `Views/Social/UserSearchView.swift`, `FollowListView.swift`; follower and following counts on profiles.
5. Block and unblock land here rather than in the moderation phase — the graph is where a block has to be enforced, and building it later means retrofitting every visibility check.
6. Optimistic follow-state UI with rollback on failure.

### Acceptance criteria

- Following a private account yields `pending`, and the follower sees nothing of that account's library until it is accepted.
- Blocking is mutually invisible — asserted against the RLS policy, not the client filter.
- You cannot follow yourself (DB check constraint, not a UI guard).
- Optimistic state rolls back on a failed request; no phantom follows.

### Files created / modified

- `WatchRank/WatchRank/Services/{SocialService,SupabaseSocialService,MockSocialService}.swift`
- `WatchRank/WatchRank/Models/FollowState.swift`
- `WatchRank/WatchRank/ViewModels/UserSearchViewModel.swift`
- `WatchRank/WatchRank/Views/Social/*.swift`
- `WatchRank/WatchRankTests/{SocialServiceTests,UserSearchViewModelTests}.swift`

---

## Phase 25 — Public profiles ✅

> **Built 2026-08-22. 426 unit tests pass**, up from 414.
>
> **Rule 6 travels with the data, not with the renderer.** Every published row carries `bucket_size`, so the *viewer* decides whether a score has been earned rather than trusting the sender to have counted. `RankedItem.displayScore` applies `MediaLibraryViewModel.minimumBucketSizeForScore` — the same constant the owner's device uses — and a test pins that the two cannot diverge. If they ever did, one of the two screens would be lying about the same title.
>
> **`RankedItem` is deliberately not `MediaItem`.** One is the user's own persisted, mutable library row; the other is a read-only copy of a stranger's ranking. Keeping them distinct is what makes "no edit affordance on a foreign profile" structural rather than a matter of remembering to leave the modifier off.
>
> **Step 3 decided: taste analysis is *not* shown for other people.** It is computed locally from a `TasteProfile` the viewer does not have and could not verify, and Phase 19 exists precisely because a wrong stated fact about someone's taste costs more trust than a wrong prediction. Publishing enough to compute it for a stranger would also publish more than the ranking itself does.
>
> **Private and blocked both render as absence**, and the emptiness comes from row-level security rather than a client filter — the mock hides libraries the same way the policy does, so the test exercises the real shape.

**Goal:** Someone else's ranking, rendered with the same care as your own.

### Steps

1. `ViewModels/UserProfileViewModel.swift` — fetch a profile plus a page of `ranked_items`, sectioned by sentiment and type exactly as `RankingView` is.
2. Reuse `MediaRow` / `MediaCard`; a foreign ranking should look like a ranking, not like a list.
3. Stats parity with your own Profile: totals, breakdown by type, top 5. Taste analysis (Phase 19) is *yours*, computed locally — decide explicitly whether it is shown for others rather than defaulting either way.
4. **Rule 6 applies to foreign items**, using the published `bucket_size`: below 5 in bucket, show position, never a number.
5. Empty and private states: "this account is private", "hasn't ranked anything yet", "N titles not published".

### Acceptance criteria

- A foreign item from a bucket of fewer than 5 shows a position and no score, on every surface it appears on.
- A private, unfollowed account renders the private state and its `ranked_items` request returns nothing (RLS, not client filtering).
- Profiles paginate; a 500-title library does not fetch in one request.
- No drag-to-reorder and no edit affordance on a foreign profile.

### Files created / modified

- `WatchRank/WatchRank/ViewModels/UserProfileViewModel.swift`
- `WatchRank/WatchRank/Views/Social/UserProfileView.swift`
- `WatchRank/WatchRankTests/UserProfileViewModelTests.swift`

---

## Phase 26 — The activity feed ✅

> **Built 2026-08-22. 439 unit tests pass**, up from 426.
>
> **Step 7 resolved — Home and the feed share one tab.** A sixth tab does not become a sixth tab on iOS; it becomes a "More" list, which is where features go to be forgotten. Neither could be cut: Home is the dashboard the whole app feeds, and a social app whose feed is buried is not one. But they answer the same question — "what's going on?" — for two different subjects, so `HomeTabView` offers *Yours* / *Following*. The switcher appears only when signed in; offering an empty half would advertise the feature as missing rather than optional.
>
> **The first design coalesced posts along with publishes, and that was wrong.** The outbox is keyed by bucket, so five rankings collapse into one row — correct for *publishing*, since five rankings rewrite one bucket and owe it one upsert. Attaching the post to that row meant five acts produced **one** post, silently dropping four from every follower's feed. Split: publishing coalesces per bucket, posting does not coalesce at all. A single insertion still yields exactly one post because the *act* is one, not because the bucket is.
>
> **The flooding test is the phase's real deliverable** and it caught the opposite bug on the way: ranking a tenth title into a bucket of ten emits exactly one post, and a reorder — which rewrites all ten scores — emits none while still publishing.
>
> **Payloads are frozen.** A post says what it said forever; reading through to the live ranking would rewrite history under a reader whenever the author ranked anything else, and would leave comments answering a sentence that no longer exists. Rule 6 applies here too — "#1 of 1" is not a ranking, so a bucket of one gets no rank line at all.
>
> **Keyset cursor, not `OFFSET`.** Posts landing mid-scroll shift every offset underneath the reader, so an offset page repeats rows it has shown and skips rows it has not. A duplicate-id guard backs it up, because a duplicated row in a feed is very visible when the cursor misbehaves.
>
> **Three empty states, not one.** Signed out, following nobody, and following people who are quiet need three different actions — telling someone to find people they have already found is useless.

**Goal:** The tab that makes it a social app.

### Steps

1. **Post creation: one post per ranking session, not one per changed score.** A single insertion rewrites a whole bucket; the user performed one act. Emit `ranked`, `want_to_watch`, `reviewed`, with a denormalised `payload` (§9) so a post never rewrites itself when the underlying ranking moves.
2. `ViewModels/FeedViewModel.swift` — cursor pagination on `(created_at, id)`. Not `OFFSET`: new posts landing mid-scroll make offset paging duplicate and skip.
3. `Views/Feed/FeedView.swift` + `FeedPostCard.swift` — poster, actor, verb, subject, the earned rank ("#1 in Liked it"), relative time, counts.
4. Pull to refresh; prepend new posts without losing scroll position.
5. Empty states: signed out → sign-in prompt; signed in with no followees → find-people CTA; followees with no activity → a distinct third state.
6. Tapping a post opens the title's detail; tapping the actor opens their profile.
7. Tab bar restructure (§11, open question 1) — resolve before building.

### Acceptance criteria

- **Ranking one title produces exactly one post**, asserted against a bucket of 10 — the flooding bug is caught by a test, not by looking at the feed.
- A post's text is stable forever: re-ranking the same title later does not alter an existing post.
- Paging across a page boundary while new posts arrive shows no duplicates and skips nothing.
- Unfollowing removes that user's posts from the feed on the next fetch.
- The feed is one request per page, counts included — no N+1.

### Files created / modified

- `WatchRank/WatchRank/Models/FeedPost.swift`
- `WatchRank/WatchRank/ViewModels/FeedViewModel.swift`
- `WatchRank/WatchRank/Views/Feed/*.swift`, `App/RootTabView.swift`
- `WatchRank/WatchRank/Services/SyncEngine.swift` (post emission)
- `WatchRank/WatchRankTests/FeedViewModelTests.swift`

---

## Phase 27 — Comments and reactions ✅

> **Built 2026-08-22. 453 unit tests pass**, up from 439.
>
> **Reporting is on the content, not in Settings.** Every comment row and every post carries it, because a report flow the user has to go looking for is a report flow that does not get used — and guideline 1.2 asks for the former. `ReportReason` is a closed list rather than free text: free-text-only reports are unactionable at any volume.
>
> **Deletion is soft.** The row keeps its place and loses its content, so a thread does not lose its shape and the counts stay consistent. A comment that vanished entirely would leave the surrounding replies answering nothing.
>
> **A failed send gives the text back.** Losing a typed comment to a network blip is a small betrayal users remember, so the draft is restored rather than cleared optimistically.
>
> **Reactions deduplicate in the database, not the client.** The `(post_id, user_id)` primary key does it; the mock uses a `Set` for the same reason, so the test exercises the real shape rather than a client-side guard that production does not have.
>
> **`canDelete` is advisory and says so.** The policy decides; the client only avoids offering a control that would fail. Asserted both ways — your own comment, and any comment on your own post.

**Goal:** Conversation on a post, and the safety rails that user-generated content requires from the first commit.

### Steps

1. `Models/PostComment.swift` (not `Comment` — it reads as a keyword), `ViewModels/PostViewModel.swift`, `Views/Post/PostDetailView.swift` + `CommentComposer.swift`.
2. Flat threading. One reply level is a schema change and a much larger UI; flat is the correct v1.
3. Reactions: one kind, deduped by `primary key (post_id, user_id)`. Optimistic toggle with rollback.
4. Counts come from the trigger-maintained columns; the client displays them and never writes them.
5. Delete: your own comment, or any comment on your own post. Soft delete via `deleted_at` so a thread does not lose its shape.
6. **Report and block from the comment surface**, wired to `reports` / `blocks`. Reporting has to exist wherever content appears, not only in Settings.
7. Length limit (1000) enforced by the DB check constraint, mirrored in the composer.

### Acceptance criteria

- A comment cannot be posted as another user, or on a post the author cannot read — enforced by policy and asserted in the SQL tests.
- Reacting twice is one reaction; the PK does the deduplication, not the client.
- Counts on the feed match the post detail after a comment is added or deleted.
- A blocked user's comments are invisible to the blocker and vice versa.
- Optimistic reaction state rolls back on failure.

### Files created / modified

- `WatchRank/WatchRank/Models/PostComment.swift`
- `WatchRank/WatchRank/ViewModels/PostViewModel.swift`
- `WatchRank/WatchRank/Views/Post/*.swift`
- `WatchRank/WatchRank/Services/SupabaseSocialService.swift`
- `WatchRank/WatchRankTests/PostViewModelTests.swift`, `supabase/tests/rls_test.sql`

---

## Phase 28 — Moderation, privacy, and release readiness ✅ (code complete; deployment is manual)

> **Built 2026-08-22. 463 unit tests pass**, up from 453. Part III is code-complete.
>
> **Amended 2026-08-23: code-complete is not the same as wired.** `SyncEngine` turns out to have no production call site, so nothing the running app does ever reaches `ranked_items` or `posts`, and the first-run publish consent from Phase 23 step 6 was never built. See **Phase 29**.
>
> **Account and data are different things, and the code says so.** Deleting the account removes everything published and leaves the local library untouched and usable signed out — asserted by ranking a film *after* deletion. App Store 5.1.1(v) asks for in-app deletion; it does not ask for the user's own device data to go with it, and taking it would be a second deletion nobody requested.
>
> **Deletion is one statement, server-side.** `delete_account()` removes the `auth.users` row and lets `on delete cascade` run the whole way down. A client deleting its own rows table by table would leave orphans the first time someone added a table and forgot.
>
> **Rate limiting is a trigger, not a client guard.** RLS authorises; it does not throttle, so without this one account writes as fast as the network allows. Comments 30/hour, follows 100/hour, raised as a named error so the client can say what happened rather than failing generically or silently doing nothing.
>
> **The TMDB proxy is an allow-list, not a forwarder.** An open proxy attached to someone's API key is a gift to whoever finds it, so only the six path shapes the app actually calls are permitted. **Written but not deployed** — see the manual list.
>
> **Reports are write-only.** Anyone signed in may file one; nobody may read the queue back. A reporter who could see it would learn whether the person they reported had been actioned, which is not theirs to know.
>
> **`README.md` corrected.** It still opened with "A local-only iOS app", which stopped being true at Phase 23. Stale privacy copy is worse than none.

**Goal:** The things that are not polish. An app with accounts and user-generated content cannot ship without these.

### Steps

1. **In-app account deletion** (App Store guideline 5.1.1(v)) — a button, not an email address. `on delete cascade` throughout the schema makes it one statement; verify nothing is orphaned.
2. **Guideline 1.2 set for UGC:** report content, block users, filter objectionable material, published contact info, and a stated commitment to act on reports within 24 hours. Plus a EULA / terms acceptance at signup.
3. Data export ("download my data") and a clear account-vs-local-data distinction — deleting the account must not silently wipe the local library, and the user must be told which is which.
4. Privacy policy and App Store nutrition labels: email, handle, user content, linked to identity. **Correct the "never leaves the device" language in `README.md`, `CLAUDE.md` and `SPEC.md`** — it is now false, and stale privacy copy is worse than none.
5. Rate limiting (open question 6): per-account limits on comments, follows and posts. RLS authorises; it does not throttle.
6. Move the **TMDB token behind an edge function**, closing roadmap open question 11 — the bundle no longer needs the credential once a backend exists.
7. `docs/MANUAL-QA.md`: signed-out journey, signup, publish, follow, feed, comment, block, report, delete account.

### Acceptance criteria

- Account deletion removes every server row for that user and leaves the local library intact and usable signed out.
- Report and block are reachable from every surface that shows another user's content.
- No shipped doc claims user data stays on the device.
- A rate-limited action fails with a clear message, not a silent no-op.
- The full manual QA script passes on the iPhone 16 simulator.

### Files created / modified

- `WatchRank/WatchRank/Views/Settings/*.swift`, `Views/Social/ReportSheet.swift`
- `supabase/migrations/0002_moderation.sql`, `supabase/functions/tmdb-proxy/`
- `docs/MANUAL-QA.md`, `README.md`, `CLAUDE.md`, `docs/SPEC.md`

---

## Phase 29 — Closing the publish loop 🔴 not started

> **Why this phase exists.** Phases 23–27 are marked ✅ and their unit tests are green, but the loop they describe cannot be walked in the running app. Three gaps, found 2026-08-23:
>
> **`SyncEngine` has no production call site.** It is constructed in `SyncEngineTests` and `FeedViewModelTests` and nowhere else — `WatchRankApp.makeSocialStack` builds auth, graph, feed and rankings, but never the engine that drains the outbox. So `drain()` and `emitPosts()` never run outside a test: ranking a title marks a `PendingPublish` row that nothing ever reads, no bucket reaches `ranked_items`, and no row is ever inserted into `posts`. Phase 23 built the engine; nobody turned the key.
>
> **Nothing a solo user does can appear in their own feed, by design.** `public.feed` selects strictly from active followees, and `follows_no_self` forbids following yourself. That is correct behaviour — a feed of your own activity is the *Yours* half of `HomeTabView` — but it means the feed cannot be exercised, at all, without two accounts. Any manual QA script that says "publish, then check the feed" is describing something that cannot happen.
>
> **The last three migrations are not confirmed deployed.** `feed_page` and `author_posts` — the two RPCs `SupabaseFeedService` actually calls — live in `20260822010000_client_rpcs.sql`, which postdates the Phase 20 run. If they are absent from the hosted project, every feed load fails and the app renders the failure as `.error`, which reads as a bug in the client.
>
> Consent is also outstanding: Phase 23 step 6 asked that an existing local library not upload silently on first sign-in, and no consent surface was built. That step must land *before* the drain is wired, not after — wiring the drain first means the first person to sign in with a populated library publishes it without being asked.

**Goal:** What Phases 23–27 built becomes reachable from the running app. Ranking a title publishes its bucket and emits one post; a follower sees it; and the whole social surface is drivable on the simulator without a server.

### Steps

1. **Consent first.** `Views/Auth/PublishConsentView.swift` — shown once per account on first sign-in with a non-empty library, stating exactly what becomes visible (title, position, sentiment, and the score only once its bucket holds `minimumBucketSizeForScore`) and what never does (untracked items, anything with a nil `externalId`, everything while signed out). Store the answer **keyed by user id**, not per device, so a second account on the same phone is asked again. Until it is granted `drain()` returns 0 and the outbox accrues — which is already its normal signed-out behaviour, so this adds a condition rather than a code path.
2. **Build the engine in the app.** Add `SupabasePublishTransport` to `WatchRankApp.SocialStack`, construct `SyncEngine(library:transport:feed:currentUserID:)` with `currentUserID: { session.profile?.id }`, and hold it as `@State` beside the other view models — it is `@MainActor`, like them.
3. **Drain on four triggers:** sign-in completes, `scenePhase` becomes `.active`, `finalizeRanking` returns, and connectivity returns (`NWPathMonitor` behind a protocol in `Services/`, so tests never touch the real network). `drain()` is idempotent and `@discardableResult` by contract — the payload is always the whole bucket — so an extra trigger costs a no-op request, never a wrong write. The ranking flow calls it *after* finalize and never awaits it: Part III invariant 2.
4. **Say what is and is not published.** Settings shows the pending count and `SyncEngine.unpublishableCount` in words ("3 titles are not published — the catalog gave them no id"), which is the whole reason that property exists. Revoking consent stops future publishes and offers to remove what is already there.
5. **Deploy the schema.** `supabase db push` for `20260822000000_moderation`, `20260822010000_client_rpcs` and `20260822020000_follow_list_rpcs`, then re-run `supabase/tests/rls_test.sql` against the hosted project. Until this is done, no client-side result means anything.
6. **`-uiTestingMockSocial` launch flag.** `makeSocialStack` returns `MockAuthService` / `MockFeedService` / `MockSocialService` seeded with posts, mirroring how `-uiTestingInMemoryStore` and `makeService` already pin UI tests to the bundled catalog and for the same reason. This is what makes the feed, post detail, comments and reactions inspectable on the simulator with no server and no second account — and what makes UI tests of the social surface possible at all.
7. **The two-account walk, on the real project.** Sign up A and B; B ranks titles and publishes; A follows B; A's *Following* tab shows B's posts, reacts and comments. Script it in `docs/MANUAL-QA.md`. This is the first time the schema, the RLS policies and the client are proven to agree with each other rather than each being tested against a stub of the other two.

### Acceptance criteria

- Ranking a title while signed in and consented produces **exactly one** `posts` row and one whole-bucket upsert in `ranked_items`, with no user action beyond the ranking itself.
- Signing in with an existing library publishes **nothing** until the user says yes; declining leaves the app fully usable and the outbox intact.
- The comparison flow's latency is unchanged with the network off, measured in the app rather than in a test, and the outbox drains on the next foreground.
- A post by B appears in A's feed within one pull-to-refresh of B creating it.
- `-uiTestingMockSocial` renders a populated feed, and comments and reactions respond, with the device in airplane mode.
- Killing the app mid-drain loses nothing; re-running the drained queue is a no-op.
- `MANUAL-VERIFICATION.md` blocker 5 ("Part III has never run against a real Supabase project") can be struck.

### Files created / modified

- `WatchRank/WatchRank/WatchRankApp.swift` — the engine, the mock-social flag, the drain triggers
- `WatchRank/WatchRank/Views/Auth/PublishConsentView.swift` *(new)*
- `WatchRank/WatchRank/Services/SyncEngine.swift` — the consent gate
- `WatchRank/WatchRank/Services/Connectivity.swift` *(new)* — `NWPathMonitor` behind a protocol
- `WatchRank/WatchRank/Views/Settings/SettingsView.swift` — pending and unpublishable counts
- `WatchRank/WatchRankTests/SyncEngineTests.swift` — consent gating, trigger idempotence
- `docs/MANUAL-QA.md` — the two-account walk; `docs/MANUAL-VERIFICATION.md` — blocker 5

---

## Open questions (re-surface each session)

1. **Comparator-count bound wording.** SPEC says "Cap at log2(N) comparisons"; the foundation tests assert the tighter, true bound `ceil(log2(N + 1))`. Both agree in practice for all N ≥ 1, but `CLAUDE.md` and `CompareViewModel`'s progress label use the test bound. If product wants the SPEC wording in user-facing copy, change `CompareViewModel.progress` accordingly.
2. ~~**Score distribution within a bucket.**~~ **Resolved:** the shipped implementation uses the quantile-style inset, not the endpoint-inclusive interpolation this question described. `RankingEngine.recomputeScores` computes `score[i] = upper - ((i + 0.5) / N) * (upper - lower)`, so a single item lands at its range midpoint and no item ever sits exactly on a bucket boundary — the top of "Liked" is 10.0 - (0.5/N) * 3.2 rather than exactly 10.0. `CLAUDE.md` documents this as the rule; this entry was stale.
3. ~~**Cross-bucket drag in Ranking.**~~ **Resolved in Phase 7, then inverted when buckets gained a media type:** drags are still blocked from crossing sentiment sections (each section is its own `ForEach`), but reorder is now offered only on the **Movies and TV** tabs, where the visible list *is* the `(type, sentiment)` bucket. The All tab interleaves two independent rankings, so it is not a bucket and has no Edit button — see `RankingViewModel.canReorder` and `CLAUDE.md` rule 5. Cross-bucket sentiment changes go through the Detail screen's Change Rating and the shared bucket recompute, not drag.
4. **`ContentView.swift` deletion.** The Xcode template's `ContentView.swift` becomes dead code in Phase 10. Confirm with user before deleting vs. leaving as a placeholder.
5. **Does a user's film taste predict their TV taste?** Phase 13 keeps the two baselines separate, but genre *effects* are currently pooled across both types — "you like crime" is treated as one fact about the user, not two. The alternative is per-type genre effects, which doubles the data required before anything is confident. Pooling is the default because sparse data is the binding constraint; revisit if Phase 17's cross-validation shows the pooled effects are worse than per-type ones on TV.
6. **Moods vs. genres as the primary control.** "Dark" is a tone and "crime" is a genre, and the user named both in the same breath — which is the honest signal that people do not think in taxonomies. Phase 14 handles this with per-type mood definitions over TMDB genres *and* keywords, and Phase 13 models the taste profile as a generic `[String: Double]` feature space for exactly this reason. The open part is which feature family carries the signal — Phase 12's measurement answers it before either the moods or the engine are designed.
7. **Should a predicted number be shown at all?** Rule 6 withholds real scores until a bucket holds 5 items on the grounds that a number implies precision the app has not earned. A prediction is strictly weaker evidence. Phase 16 gates on confidence and falls back to a qualitative band, which is the compromise — but "Likely a hit" for everything is also a defensible v1.1, and it cannot be wrong in a way the user will notice and resent.

   **Sharpened by [`PHASE-13-PLAN.md`](./PHASE-13-PLAN.md) §3.4:** the choice is not between a number and a band, because the *raw* number cannot say what the screen needs it to say. Family weights sum to 1.0, so a prediction's lift is bounded by the strongest single family effect and sits well under `baseline + 1` in practice — the best recommendation for a user whose favourites read 9.9 would display ≈ 6.3. So the live options are a **calibrated** number (the confidence-blended quantile map, which is order-preserving and therefore safe) or a band. A raw predicted number is off the table.
8. **Recency weighting.** Taste drifts. Weighting residuals by a half-life on `dateWatched` is a two-line change to Phase 13, but it needs the cross-validation harness from Phase 17 to justify a half-life value rather than inventing one. Deliberately deferred to Phase 17 rather than guessed at in Phase 13.
9. ~~**Catalog size ceiling.**~~ **Resolved 2026-08-21:** the 126-title mock catalog is replaced by the live TMDB API (Phase 12) with a ~1200-title cached candidate pool (Phase 14). `MockMediaService` survives as the offline fallback, preview fixture, and test source.
10. **What happens to `MockMedia.json` long-term?** It is now a test fixture and offline seed, not the catalog. It should probably shrink to a curated ~40 titles chosen to exercise the predictor (dense genre coverage, both types, a full sentiment spread) rather than remain 126 titles pretending to be a catalog. Decide during Phase 12.
11. **Does the API key ship in the binary?** For a local, unsubmitted MVP an xcconfig-injected key is fine. If this ever goes to TestFlight or the App Store, a key in the bundle is extractable — that would need a proxy, which means a backend, which the project does not have. Worth knowing before anyone talks about shipping.
12. ~~**Are TMDB keywords good enough for tone moods?**~~ **Resolved twice, both times yes.** Coverage 2026-08-21 (below); *usefulness* 2026-08-21 by [`MOOD-YIELD.md`](./MOOD-YIELD.md), which measured per-mood yield and found all twenty (mood, type) pairs clearing the bar, the thinnest at 94 titles. The surviving caveat named at the end of this entry is therefore also closed — with the amendment that the risk was never the family, it was individual dead *tags*: 7 of 32 candidate keywords returned ≤ 5 titles. Original coverage finding: 97.8% of films and 84.3% of series carry ≥ 5 keywords, the median film carries 17, and coverage does not decay with age (pre-1990 films are at 100%). Tone moods are viable and no hand-curated tone list is needed. Two caveats survive: the sample was the popularity-ordered top 400, so genuine obscurity is untested and Phase 14's pool reaches further down than this did; and coverage is not the same as *usefulness* — 66% of keywords appear on exactly one title, which is a problem for the predictor (see Phase 13's support floor) even though it is not a problem for filtering.
13. **Does a keyword support floor throw away the tone signal it was added for?** Phase 13 drops keywords with library support < 2, because a feature seen once carries one title's residual and nothing else. But the measurement says the median keyword *has* support 1 — so the floor may discard most of the family. The tension resolves one of three ways and only cross-validation can say which: the surviving high-support keywords carry enough signal on their own; or keywords need grouping into coarser tone clusters before they are counted; or keywords earn their place in filtering (Phase 14) while contributing nothing to prediction. Decide in Phase 17, not by argument.

13. **Is "favourite actor" displayable at all?** It rests entirely on the credit density Phase 12 step 9 measures. If nearly every cast member is a singleton at realistic library sizes, the honest options are dropping the cast family from *display* — it can still feed prediction, where sparse features are damped rather than asserted — or raising its floor until it almost never fires, which is the same outcome with more code. Decide from the measurement, not from how good "your favourite actor is…" sounds.
14. **Does crowd agreement belong on Profile at all?** A Spearman coefficient is defensible but inside-baseball, and the interesting version of it ("you are a contrarian") is a characterisation the app would be putting in the user's mouth. It may read better as a one-line qualitative label than as a number — the same compromise Phase 16 makes for predicted scores, and for the same reason.
15. **Recency weighting now has two callers.** Open question 8 defers recency to Phase 17 for prediction. Taste *analysis* has the stronger case for it — "what you liked five years ago" is arguably a different claim from "what you like" — but Phase 19 should reuse whatever half-life Phase 17's cross-validation justifies rather than inventing a second one. Two decay constants tuned independently would be a bug wearing a feature's clothes.
