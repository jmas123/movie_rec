# WatchRank

A local-only iOS app for ranking the movies and TV shows you've watched, inspired by Beli's pairwise comparison flow. You never type a number — you pick a coarse sentiment ("Liked it", "It was fine", "Didn't like it"), then the app walks you through a short series of "which did you prefer?" comparisons to slot the new title into your personal ranking. A 0–10 score is derived from where it lands.

The MVP is offline-first (SwiftData) and single-user. Two things are being built on top of it: **recommendations** (v1.1, in progress — a live TMDB catalog and a prediction engine trained on your own rankings) and a **social layer** (v2.0, planned — accounts, follows, an activity feed, and comments, backed by Supabase). The app stays fully usable offline and signed out either way, and the ranking mechanic never changes: scores are always derived from bucket position, never typed, and never computed on a server.

See [`docs/ROADMAP.md`](./docs/ROADMAP.md) for per-phase status and [`docs/PART-III-SOCIAL.md`](./docs/PART-III-SOCIAL.md) for the social architecture.

## Prerequisites

- macOS with **Xcode 15+**
- **iOS 17 simulator** (Xcode → Settings → Platforms)
- Swift 5.9+ (bundled with Xcode 15)

No package manager, no `pod install`, no `swift package resolve` — the project has zero third-party dependencies.

## Build

Open `WatchRank/WatchRank.xcodeproj` in Xcode and press ⌘B, or from the command line:

```bash
xcodebuild -scheme WatchRank \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```

## Test

```bash
xcodebuild -scheme WatchRank \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

Two test plans are checked in. `WatchRank` (the default) runs everything;
`WatchRankUnit` runs the unit target alone and finishes in a few seconds:

```bash
xcodebuild -scheme WatchRank -testPlan WatchRankUnit \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

Both plans set `parallelizable: false`. Parallel UI testing clones the
simulator per target, which on an 8 GB machine can spawn hundreds of processes
and starve the simulator until it is killed mid-run — a failure that looks
exactly like a code bug. Leave it off.

UI tests (`WatchRankUITests/RankingFlowUITests.swift`, XCTest) cover the cold launch and the golden path — search → Mark Watched → sentiment → pairwise comparison → the title on Ranking. They launch the app with `-uiTestingInMemoryStore` so each run starts from an empty library and never touches the on-disk store.

Unit tests use the Swift Testing framework (`import Testing`, `@Test`, `#expect`) and cover the engine, services, and view models: `RankingEngine` (binary-insertion position + score recomputation), `MockMediaService` (bundle load + search), `MediaLibraryViewModel` (comparison sessions, reorder, cross-bucket moves, review edits, Home rails), `SearchViewModel`, `CompareViewModel` (decision-count bound, placement, cancellation), `RankingViewModel`, and `ProfileStats`.

## Project layout

See [`CLAUDE.md`](./CLAUDE.md) for the full file structure, ranking rules, and coding conventions, and [`docs/ROADMAP.md`](./docs/ROADMAP.md) for per-phase status.

## Features

- **Search** the bundled mock catalog and open a title's detail.
- **Mark Watched** → pick a sentiment → a binary-insertion "which did you prefer?" comparison flow places the title in its bucket. Scores (0–10) are derived from bucket position, never typed.
- **Ranking** screen: browse by sentiment, filter by media type, collapse sections, and drag-to-reorder (All tab) with live score recomputation.
- **Home** rails (top movies, top TV, recently watched, want to watch) and a **Profile** with totals, average score, all-time top 5, and top genres.
- Persists locally via SwiftData across launches.

## Status

MVP feature-complete (Phases 0–10): all screens built and wired behind a tab bar, verified on the iPhone 16 simulator with the full suite green (92 unit tests plus the UI flow tests).

Phase 11 (polish & QA) is largely done:

| Step | Status |
|---|---|
| Empty states | ✅ every empty surface uses `EmptyStateView` and offers a call to action |
| Accessibility | ✅ VoiceOver labels across the Mark Watched → Compare → Ranking flow; Dynamic Type honoured |
| Dark mode | ✅ no hardcoded colors — system colors throughout |
| Spacing | ✅ shared scale in `Components/Spacing.swift`; section rhythm consistent across screens |
| Manual smoke test | ⬜ **outstanding** — see [`docs/MANUAL-QA.md`](./docs/MANUAL-QA.md) |

The accessibility and visual work has been verified to compile and to leave the
suite green, but **not** verified by eye or by ear on a device. `docs/MANUAL-QA.md`
lists exactly what a human still needs to check and why automation cannot.

## Known limitations

- Catalog is a bundled JSON mock — no TMDB / network (a future swap behind `MediaService`).
- No accounts, sync, social features, or recommendations.
- No SwiftData migration plan during development: if `MediaItem`'s shape changes, delete the app from the simulator before relaunching.
