# Binged

## Project summary

Binged is an iOS app for ranking movies and TV shows in the style of Beli, local-first and — from Part IV — account-backed. Instead of asking the user to type a numeric rating, the app captures a coarse sentiment (Liked / Fine / Disliked) and then runs a pairwise binary-insertion comparison flow against existing items in the same sentiment bucket. A 0–10 score is derived from each item's final position within its bucket — scores are never entered by the user. The v1.0 MVP has no backend, no auth, no social features, and no recommendations. **v1.1 (Part II) adds recommendations; v2.0 (Part III) adds the social layer — accounts, follows, an activity feed, comments — and lifts the local-only constraint; Part IV makes the account the user's library, syncing it unconditionally while signed in so a second device restores it.** See [`docs/PART-III-SOCIAL.md`](./docs/PART-III-SOCIAL.md) and [`docs/PART-IV-SYNC.md`](./docs/PART-IV-SYNC.md) for the architecture, and [`docs/ROADMAP.md`](./docs/ROADMAP.md) Phases 20–29 for the plan. The ranking mechanic below is unchanged by any of it.

## Tech stack

- SwiftUI (UI)
- MVVM (architecture)
- SwiftData (persistence; the device's copy, and the one the ranking flow reads and writes)
- iOS 17.0+ deployment target (`IPHONEOS_DEPLOYMENT_TARGET = 17.0`). Lowered from
  18.2 on 2026-08-24: nothing in the app needs 18, and 18.2 excluded a great many
  devices for no gain. **Compiled and unit-tested at 17.0; not yet run on a 17
  runtime** — only 18.3 is installed locally.
- Swift 5 language mode (`SWIFT_VERSION = 5.0`), Xcode 16 toolchain
- Zero third-party dependencies
- TMDB for catalog metadata (Part II) and Supabase for accounts and the social graph (Part III) — both reached through a hand-rolled `URLSession` client behind a protocol in `Services/`, so neither adds a Swift Package

## File structure

```
Binged/Binged/
  BingedApp.swift        // composition root: container, catalog, social stack, sync
  App/RootTabView.swift
  Models/          (27)  MediaItem, MediaType, Sentiment, WatchedStatus,
                         ScoreDisplay, PredictionDisplay, TasteProfile,
                         FeedPost, UserProfile, PendingPublish, BingedSchema, …
  Views/           (17)  Home, Search, Detail, Ranking, Compare, Profile,
                         Discover, Auth, Social, Feed, Post, Settings, Recovery
  Components/       (6)  MediaCard, MediaRow, PosterPlaceholder,
                         EmptyStateView, SentimentPicker, Spacing
  ViewModels/      (11)  MediaLibrary, Search, Ranking, Compare, Recommendation,
                         Session, Feed, Post, UserProfile, UserSearch
  Services/        (29)  RankingEngine (pure), MediaService + TMDB*,
                         RecommendationEngine, CandidatePoolBuilder,
                         AuthService, SocialService, FeedService,
                         SyncEngine + PublishConsent, LibraryMerge (pure),
                         LibraryRestoreService, LibraryRestorer,
                         Supabase/ (5), and a Mock… sibling for every protocol
  Resources/             MockMedia.json
  PrivacyInfo.xcprivacy
supabase/
  migrations/       (7)  social, moderation, client_rpcs, follow_list_rpcs,
                         library_sync, fix_is_published_privileges, blocked_accounts
  tests/rls_test.sql     33 pgTAP assertions, mostly negative
```

**Not exhaustive — 85 Swift files and growing.** The shape is what matters:
one primary type per file, every protocol in `Services/` has a `Mock…` sibling
so no test touches the network, and the two files with genuinely tricky logic —
`RankingEngine` and `LibraryMerge` — are pure, synchronous and free of
SwiftData, which is why their tests need no container.


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
- **No force unwraps** (`!`) in non-test code. Use `guard let`, `if let`, nil-coalescing, or fail loudly with a thrown error. Force-unwraps are tolerated inside `BingedTests` only.
- **Prefer value types** (structs, enums) for everything that isn't a SwiftData `@Model` or doesn't need reference semantics.
- **Use the `@Observable` macro** for view models — not `ObservableObject` + `@Published`.
- **SwiftUI view names are descriptive.** `MediaDetailView`, `SentimentPicker`, `EmptyStateView` — never bare `DetailView` or `Picker`.

## Build commands

```bash
# Build
xcodebuild -scheme Binged -destination 'platform=iOS Simulator,name=iPhone 16' build

# Test
xcodebuild -scheme Binged -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## Do not

- Do not add third-party libraries or Swift Package Manager dependencies.
- **Network code lives behind a protocol in `Services/`, always.** TMDB is the live catalog (Part II, Phase 12) behind `MediaService`; Supabase is auth and the social graph (Part III, Phases 20+) behind `AuthService` and `SocialService`, and library sync (Part IV) behind `PublishTransport`. Nothing outside `Services/` may know a URL exists, and every one of them has a `Mock…` sibling so no test touches the network.
- ~~User data stays local-only and never leaves the device.~~ ~~No longer true from Phase 23: *published* data goes to Supabase.~~ **Rewritten again for Part IV — read this one carefully, because the previous two versions are the kind of stale privacy copy that gets repeated into a privacy policy.**

  **While signed in, the whole ranked library goes to the user's own account — always, with no opt-in.** That is what makes signing in on a second device restore it. Consent does *not* gate whether data reaches the server; it gates `is_published`, which decides whether anybody **else** can see it. The two questions are different and must never be worded as one (`docs/PART-IV-SYNC.md` §3).

  So the honest inventory is:
  - **Never leaves the device, ever:** items with a nil `externalId` (nothing to key them to), and everything at all while signed out.
  - **Goes to the user's own account, unconditionally, once signed in:** every watched, ranked item with an `externalId`.
  - **Visible to other people only after an explicit yes:** the same rows, once `is_published` is true. Default false, per bucket, all-or-nothing.

  Two consequences for anything you write. **Never tell the user their ranking "stays on this device" when they are signed in** — it is false, and a consent sheet that says it is trading a false statement for a yes. Sync is disclosed at account creation instead. And **withdrawing consent hides rows; it never deletes them** — deleting would destroy the backup the user did not ask to lose.
- **Do not let the social layer touch the ranking mechanic.** `RankingEngine` stays pure, synchronous and local; scores stay derived from bucket position; the comparison flow never awaits a network call; and the entire app stays usable signed out. These are invariants, not preferences (`PART-III-SOCIAL.md` §2).
- **Do not trust the client for authorisation.** The Supabase anon key ships in the bundle by design and carries no privilege — row-level security in Postgres is the whole security boundary. Any rule the app enforces must also exist as a policy, or it does not exist.
- Do not let the user enter a numeric rating directly. Scores are derived from bucket position.
- The project uses `PBXFileSystemSynchronizedRootGroup`, so files added on disk are picked up by the target automatically — no manual drag-into-Xcode step. Editing `project.pbxproj` is allowed when a build-level change genuinely requires it (e.g., the `EXCLUDED_SOURCE_FILE_NAMES = .gitkeep` rule that keeps empty-folder markers out of the app bundle).
- ~~Do not modify `BingedApp.swift` or `ContentView.swift` until the UI phase.~~ **Spent — the UI phase was Phase 10.** `BingedApp` is now where the catalog, the recommender, the social stack and the sync engine are assembled, and it is edited routinely. What replaces the rule: it is a *wiring* file, so composition belongs there and logic does not. If something in it needs a test, it is in the wrong file. Concurrent sessions edit it often — re-read before editing rather than working from a copy in context.

## SwiftData schema changes during dev

~~The MVP does not implement a migration plan.~~ **It does now** — `Models/BingedSchema.swift` defines `BingedSchemaV1` and `BingedMigrationPlan`, and `BingedApp` opens the store through it.

Additive changes (a new optional property, a new `@Model` entity) lightweight-migrate and need nothing. **Renames, type changes and deletions still need a new `VersionedSchema` plus a migration stage** — and until you have written one, deleting the app from the simulator remains the fastest way to get moving again during development. What is no longer acceptable is adding a property and hoping: the plan exists, so the shape change belongs in it.

**Do not add a second `VersionedSchema` that lists the same live model types.** Two versions both naming `MediaItem.self` describe the same shape, compute the same version checksum, and `NSLightweightMigrationStage` throws when `from == to`. That throw happens inside `BingedApp.init()`, so the app aborts with SIGABRT before drawing a frame, and `StoreRecoveryView` cannot catch it — it guards `ModelContainer` creation, and this fails one line earlier. A real version needs a **frozen copy** of each changed model (a `MediaItemV1` `@Model` carrying the old property list), with only the newest version referring to the live type. That is worth paying the moment a build ships and not before. This crashed the app on 2026-08-23; the full write-up is in `Models/BingedSchema.swift`.

**The unit suite cannot catch that class of bug.** No test calls `BingedApp.init()`, so the entire composition root — container, schema, service wiring — is unexercised by 539 green tests. After touching the schema or app startup, run the app or the full test plan, not `-testPlan BingedUnit`.

## Current scope

Part I (Phases 0–10) ships: models, `RankingEngine`, services, view models, and all screens, wired and verified on the iPhone 16 simulator. Part II is mid-stream — Phases 12, 12a and 13 (TMDB catalog, feature extraction, prediction engine) are done; **Phases 14–19 are the current work**.

**Part III (social) starts after Phase 19** and is planned, not started. Do not begin social work while Part II is open unless explicitly asked.

**Amended 2026-08-23:** Part III shipped through Phase 28, and Phase 29 wired the publish loop into the running app. Part IV (unconditional library sync, restore on a second device) is in progress across concurrent sessions — see `docs/PART-IV-SYNC.md` for the split.
