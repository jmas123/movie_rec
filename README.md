# Binged

An iOS app for ranking the movies and TV shows you've watched, inspired by Beli's pairwise comparison flow. You never type a number — you pick a coarse sentiment ("Liked it", "It was fine", "Didn't like it"), then the app walks you through a short series of "which did you prefer?" comparisons to slot the new title into your personal ranking. A 0–10 score is derived from where it lands.

**On your data.** Through v1.1 everything stayed on the device. From v2.0 (the
social layer) you can create an account and *publish* your ranking under a
handle — at which point your published rankings, reviews, profile and comments
live on a server. What never leaves the device: anything at all while you are
signed out, untracked titles, and titles the catalog could not identify.
Publishing is opt-in and never silent, and deleting your account removes what
you published while leaving your library on the device intact.

The MVP is offline-first (SwiftData) and single-user. Two things are built on top of it: **recommendations** (v1.1 — a live TMDB catalog and a prediction engine trained on your own rankings) and a **social layer** (v2.0 — accounts, follows, an activity feed, and comments, backed by Supabase). Both are code-complete; neither has shipped. The app stays fully usable offline and signed out either way, and the ranking mechanic never changes: scores are always derived from bucket position, never typed, and never computed on a server.

See [`docs/ROADMAP.md`](./docs/ROADMAP.md) for per-phase status and [`docs/PART-III-SOCIAL.md`](./docs/PART-III-SOCIAL.md) for the social architecture.

## Prerequisites

- macOS with **Xcode 15+**
- **iOS 17.0+ deployment target**; QA runs on iPhone 16, iOS 18.3
- Xcode 16 toolchain, Swift 5 language mode

No package manager, no `pod install`, no `swift package resolve` — the project has zero third-party dependencies.

## Build

Open `Binged/Binged.xcodeproj` in Xcode and press ⌘B, or from the command line:

```bash
xcodebuild -scheme Binged \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```

## Test

```bash
xcodebuild -scheme Binged \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

Two test plans are checked in. `Binged` (the default) runs everything;
`BingedUnit` runs the unit target alone and finishes in a few seconds:

```bash
xcodebuild -scheme Binged -testPlan BingedUnit \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

Both plans set `parallelizable: false`. Parallel UI testing clones the
simulator per target, which on an 8 GB machine can spawn hundreds of processes
and starve the simulator until it is killed mid-run — a failure that looks
exactly like a code bug. Leave it off.

UI tests (`BingedUITests/RankingFlowUITests.swift`, XCTest) cover the cold launch and the golden path — search → Mark Watched → sentiment → pairwise comparison → the title on Ranking. They launch the app with `-uiTestingInMemoryStore` so each run starts from an empty library and never touches the on-disk store.

Unit tests use the Swift Testing framework (`import Testing`, `@Test`, `#expect`) and cover the engine, services, and view models: `RankingEngine` (binary-insertion position + score recomputation), `MockMediaService` (bundle load + search), `MediaLibraryViewModel` (comparison sessions, reorder, cross-bucket moves, review edits, Home rails), `SearchViewModel`, `CompareViewModel` (decision-count bound, placement, cancellation), `RankingViewModel`, and `ProfileStats`.

## Project layout

See [`CLAUDE.md`](./CLAUDE.md) for the full file structure, ranking rules, and coding conventions, and [`docs/ROADMAP.md`](./docs/ROADMAP.md) for per-phase status.

## Features

- **Search** the live TMDB catalog (or the bundled mock, offline) and open a title's detail.
- **Mark Watched** → pick a sentiment → a binary-insertion "which did you prefer?" comparison flow places the title in its bucket. Scores (0–10) are derived from bucket position, never typed.
- **Ranking** screen: browse by sentiment, filter by media type, collapse sections, and drag-to-reorder (on the Movies or TV tab, where the list *is* one bucket) with live score recomputation.
- **Home** rails (top movies, top TV, recently watched, want to watch) and a **Profile** with totals, average score, all-time top 5, and top genres.
- A score is withheld until its bucket holds five titles; below that every surface shows **position** ("#2") instead, because a number from one comparison implies a precision the app has not earned.
- **Discover** (v1.1): pick a type and a mood, get unwatched titles carrying a *predicted* score computed locally from your own rankings — outlined, never filled, so a guess never borrows the look of an earned score.
- **Social** (v2.0): create an account, publish your ranking under a handle, follow people, read a feed, comment and react. Opt-in and never silent; signed out, the app is unchanged.
- Persists locally via SwiftData across launches.

## Status

**Phases 0–10 (the ranking MVP), 12–19 (recommendations) and 20–28 (the social layer) are code-complete**, with the full unit suite green: **466 tests in ~7s** on the iPhone 16 simulator.

Phase 11 (polish & QA) is in progress:

| Step | Status |
|---|---|
| Empty states | ✅ 22 `EmptyStateView` sites across 13 screens; every empty surface explains itself and most offer a call to action |
| Accessibility | ✅ VoiceOver labels across Mark Watched → Compare → Ranking; every spinner says what it is loading |
| Dynamic Type | ✅ every font that carries information scales; the two that do not are documented in place — a decorative glyph inside a fixed-size poster, and the predicted badge, which is capped at `accessibility1` and duplicates its content in the row's spoken label |
| Dark mode | ✅ no hardcoded colors anywhere — system colors throughout |
| Spacing | 🟡 shared scale in `Components/Spacing.swift`, adopted for every on-grid value; a handful of deliberate off-grid values (3, 5, 6, 10, 14pt) remain inside components |
| Manual smoke test | ⬜ **outstanding** — see [`docs/MANUAL-QA.md`](./docs/MANUAL-QA.md) |

Everything above has been verified to compile and to leave the suite green. **None of it has been verified by eye or by ear.** That is a different claim, and `docs/MANUAL-QA.md` lists exactly what a human still has to check and why automation cannot.

Before any release, read [`docs/GAP-AUDIT.md`](./docs/GAP-AUDIT.md). It records what is built-but-not-wired, and its findings — an app icon that does not exist, a missing privacy manifest, report and block being unreachable from the UI — are store blockers, not polish.

## Known limitations

- Recommendations and the social layer are code-complete but unreleased, and the manual QA pass for both is outstanding.
- Publishing is opt-in, but reporting and blocking are not yet reachable from the UI — see `docs/GAP-AUDIT.md`.
- No app icon and no privacy manifest, so the project cannot be submitted as it stands.
- No SwiftData migration plan during development: if `MediaItem`'s shape changes, delete the app from the simulator before relaunching.
