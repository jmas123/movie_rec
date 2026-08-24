# Functionality & PM gap audit

**Date:** 2026-08-22 · **Target assumed:** TestFlight / App Store · **Scope:** whole app, Parts I–III

`ROADMAP.md` marks Phases 0–28 complete except Phase 11. The code backs that up on the
surface: **463 unit tests pass in 7.5s**, there are **zero** TODO/FIXME markers in app code,
and every service, view model and view the roadmap names exists on disk.

This audit found the opposite of what that implies. The *parts* are built and tested; the
*assembly* is not. Three Part III screens compile but have no call site, the publish outbox
is never drained, and **a fresh install cannot create an account at all**. Separately, the
App Store artifacts — icon, privacy manifest, EULA gate, version bump — are absent, and there
is no SwiftData migration plan behind data that is now supposed to leave the device.

Nothing here is a "the code is bad" finding. The code is unusually careful: no force-unwraps
outside three URL literals, documented failure paths, honest doc comments. The gap is between
what is *written* and what is *wired*, and it is invisible from inside any one file — which is
exactly why a green suite and a fully-ticked roadmap did not catch it.

> **On evidence.** Every finding below was verified directly against the working tree. Three
> claims raised during exploration were checked and **discarded as false**: a `rankings` vs
> `ranked_items` table mismatch, a `posts.author_id` column mismatch, and a nested
> `NavigationStack` in `HomeView`. None of them exist. They are recorded here only so nobody
> re-derives them.

---

## 1. Store rejection blockers

| # | Finding | Evidence |
|---|---|---|
| 1 | **No app icon.** `AppIcon.appiconset/` contains only `Contents.json` — three 1024² slots declared, zero image files. Archive validation fails outright. `AccentColor` is likewise the unfilled stock template, so the app has no brand colour. | `WatchRank/WatchRank/Assets.xcassets/AppIcon.appiconset/` |
| 2 | **No `PrivacyInfo.xcprivacy`.** Mandatory for submission. The app collects email, a handle and user content, and touches required-reason file-timestamp APIs via `CatalogCache` / `LibraryExport`. | `find -name "*.xcprivacy"` → 0 hits |
| 3 | **Report and block are unreachable — Guideline 1.2.** `ReportSheet` exists only inside `PostDetailView`, which has **zero call sites**. `UserSearchViewModel.block(_:)` has **zero callers**. Meanwhile `SettingsView`'s Safety section is four lines of static text *describing* both capabilities: "Report content from any post, comment or profile", "Blocking someone hides them…". The app promises in prose what it does not expose in UI. | `PostDetailView.swift:142`; `UserSearchViewModel.swift:109`; `SettingsView.swift:104-107` |
| 4 | **No EULA / terms gate at sign-up.** The sign-up form has email, password, handle and a password-length footer. No checkbox, no link. Phase 28 step 2 is marked ✅. | `Views/Auth/SignInView.swift:67-104` |
| 5 | **Privacy-policy and support URLs are fictional and force-unwrapped.** `watchrank.app/privacy` and `support@watchrank.app` resolve to nothing, and these are the only three `!` in non-test code — against CLAUDE.md's own rule. | `SettingsView.swift:109,111,112` |
| 6 | **Version never moved.** `MARKETING_VERSION = 1.0` and `CURRENT_PROJECT_VERSION = 1` in all six build configurations, unchanged through Parts I, II and III. Settings will show a user "1.0" for what the docs call v2.0, and TestFlight requires a build bump per upload. | `project.pbxproj:412,427,443,458` |
| 7 | **No `VersionedSchema` / `SchemaMigrationPlan`, behind a `fatalError`.** CLAUDE.md defers migrations to v1.2 and says "delete the app from the simulator" — advice a shipped user cannot follow. Any non-lightweight `MediaItem` change turns an OTA update into an unrecoverable launch crash. The stakes changed at Phase 23 and the guidance did not: `PendingPublish` is the only record of what the device owes the server, and a store that fails to open loses it silently. **Cheapest to fix now, while V1 is the only version.** | 0 hits for either symbol; `WatchRankApp.swift:41-52` |

---

## 2. The assembly gap — built, tested, not reachable

This is the headline. Each item below is working code with passing tests and no entry point.

| # | Finding | Evidence |
|---|---|---|
| 8 | **A fresh install cannot create an account.** `ProfileView` renders its empty state *instead of* `statsList` when the library is empty — and `accountSection` lives inside `statsList`. The fallback path is worse: Profile → gear → Settings shows a dead `Text("Not signed in.")` with no button beside it. Sign-in therefore appears only after the user has ranked something. The entire v2.0 social layer is gated behind Part I engagement by accident. | `ProfileView.swift:33-41,76,89-98`; `SettingsView.swift:58-69` |
| 9 | **Nothing is ever published.** `SyncEngine` has **zero references in the app target** outside its own file — never instantiated, and `SocialStack` doesn't hold one. The producer side is live: `markDirty` enqueues a `PendingPublish` row on every ranking write. So the outbox grows monotonically forever and is never read, no post is ever created, and the Following feed can only ever be empty. Phase 23 "Publishing the library ✅". | `grep SyncEngine` → own file only; `MediaLibraryViewModel.swift:617-643` |
| 10 | **Three screens have no call site.** `UserProfileView` (0), `PostDetailView` (0), `UserSearchView` (its own `#Preview` only). That takes down public profiles, follow/unfollow, all comment read/write/delete, and both report surfaces. The feed's comment-count bubble is a plain `Label`, not a button. | verified by grep across all views |
| 11 | **"Find People" is a dead end.** The feed's `followingNobody` empty state calls `onFindPeople`, which `RootTabView` binds to `selection = .search` — the **movie** search tab. There is no people-search entry point anywhere in the app, so following anyone is impossible. | `FeedView.swift:47-50` → `RootTabView.swift:49` |
| 12 | **`RootTabView.rankingFeedService` is stored and never read** in `body`. `WatchRankApp` builds and passes it; the whole ranking-feed feature is inert. | `RootTabView.swift:36` vs `:40-73` |
| 13 | **No publish opt-in control**, which CLAUDE.md and `PART-III-SOCIAL.md` §13 both promise ("Publishing must be a decision, not a default"). The claim is vacuously true today because nothing publishes — and becomes **false the moment #9 is fixed**, since dirty-bucket enqueueing is automatic on every rank. Build the toggle *before* the wiring, not after. There is also no unpublish; `deleteBucket` exists at the transport layer with no UI, so the only way to remove published data is Delete Account. | no publish UI in `Views/`; `SyncEngine.swift:30,196` |
| 14 | **Missing outright**, with service methods already written and zero callers: followers list, following list, pending-request inbox (a private account can never approve a follower), unblock / blocked-users list, report a *profile*, edit a comment, password reset, email-verification handling, avatar upload, edit-own-profile, and notifications of any kind. | `SocialService.swift:33-42`; `AuthService.swift:39`; `FeedService.swift:20` |

**Why this slipped through.** No test asserts that any screen is reachable. The unit suite
covers view models and services thoroughly and stops exactly at the wiring layer, which is
where all of the above lives. The UI tests can't help either: they launch with
`-uiTestingInMemoryStore`, which makes `makeSocialStack` return `nil`, so Part III is
unreachable *from the tests by construction*.

---

## 3. Correctness bugs on paths users can actually reach

| # | Finding | Evidence |
|---|---|---|
| 15 | **Discover creates duplicate library rows.** `DiscoverView` hands a freshly-minted detached `MediaItem` to `MediaDetailView` without calling `canonicalItem(for:)` — which `SearchView` *does* call. Queued titles are deliberately kept in Discover, so tapping one opens a detail screen reporting `.untracked`; marking it watched inserts a second row. This is precisely the failure `canonicalItem`'s own doc comment warns about, including "the comparison flow can pit the film against itself." | `DiscoverView.swift:104`; `SearchView.swift:101`; `MediaLibraryViewModel.swift:205-231,672-676` |
| 16 | **`followers_of` / `following_of` RPCs are called but defined in no migration.** This sits on a live path: `FeedViewModel.emptyPhase` probes `following(of:limit:1)` whenever a feed page comes back empty, so against a real backend an empty feed renders `.error(…)` instead of the `followingNobody` / `quiet` states Phase 26 was built around. | `SupabaseSocialService.swift:190,194`; absent from all three migrations |
| 17 | **Every ranking write can fail silently.** `try? modelContext.save()` is the single write path for ranking, reorder, sentiment change and review. On failure the UI keeps its in-memory state and the user believes it saved. Three more unchecked `try? save()` elsewhere; fetches degrade to `?? []`, making a failed read indistinguishable from an empty library. | `MediaLibraryViewModel.swift:682`, `:579,633,651` |
| 18 | **Raw Swift error dumps shown to users.** `String(describing: error)` in `FeedViewModel:69`, `SessionViewModel:118,140`, `PostViewModel:68,100,126` — while `UserSearchViewModel` and `UserProfileViewModel` correctly prefer `.description`. Offline, the feed shows the user literally `transport("Could not reach the server.")`. The codebase disagrees with itself. | verified |
| 19 | **`PostViewModel.lastError` is set in four places and read by no view.** A failed comment, delete, report — or a rate-limit rejection from the new triggers — produces silence. Phase 28's criterion "a rate-limited action fails with a clear message, not a silent no-op" is unmeetable. | `PostViewModel.swift:20,68,88,100,126` |
| 20 | **Pagination failures are swallowed as end-of-list** (`catch { hasMore = false }`), so a transient 500 is indistinguishable from having reached the end. Optimistic updates also revert with no explanation. | `FeedViewModel.swift:105-107,127-129`; `UserProfileViewModel.swift:94-96` |

---

## 4. Product gaps a PM would flag

**Destructive actions do not exist.** There is no delete-item, no unwatch, no
remove-from-watchlist — no `modelContext.delete` for a `MediaItem` anywhere in the codebase.
A mis-ranked or wrongly-added title is permanent. The nearest thing, `addToWantToWatch`,
*does* correctly clear watched state and rescore the vacated bucket, but the button that calls
it is only offered on `.untracked` items, so a watched item can never reach it. "Not for me"
on Discover is likewise irreversible in UI — `undismiss` exists and only tests call it.

**The watchlist is a read-only 5-item rail.** No full screen, no count, no "see all", and
nothing you can do from it except open a detail view whose only action is Mark Watched.

**Real poster art appears on exactly one screen.** `PosterView` renders artwork only in
`RecommendationRow`. Home cards, Ranking rows, the Detail hero and Compare cards all draw the
gradient `PosterPlaceholder`, despite `posterURL` being fetched, stored and available. For a
product whose SPEC asks for a "clean, premium feel" and calls Ranking "the hero", this is the
largest perceived-quality gain per unit of effort in the app — four call sites.

**No onboarding of any kind.** No first-run flag exists (`UserDefaults`/`AppStorage`/TipKit:
zero hits). The only explanation of the comparison mechanic — a genuinely well-written
`RankingExplainerView` — is buried at Profile → gear → About. A new user is asked "Which did
you prefer?" with no explanation of why, and is never told a score is being withheld until the
bucket holds five.

**Discover always opens empty.** Mood is plain `@State`, not persisted, with no default.

**No search, filter or sort within the ranked library**, and no pagination in Search or
Discover (search returns page 1 only; Discover is a fixed 20). The only infinite scroll in the
app is the social feed.

**The prediction feedback loop is invisible.** The app freezes its guess when you queue a
title, then never tells you "we said 8.1, you scored 7.4". That comparison is the single most
compelling thing a taste-prediction product can show a user, and it exists in the data. Only an
aggregate correlation line on Profile surfaces it, gated at n ≥ 8.

**Zero logging or telemetry** — no `OSLog`, no `MetricKit`, not one `print`. Combined with #17,
a production save failure is invisible to the user *and* to you. `OSLog` + an
`MXMetricManagerSubscriber` are both system frameworks and fit the no-dependencies rule exactly.

**Accessibility is thin and lopsided**: 23 labels, 4 hints, 0 values, 0 identifiers.
`CompareView` is genuinely good. `SearchView`, `SignInView`, `SettingsView` and `FeedView` have
**none** — including the destructive Delete Account button, and the sign-up handle-availability
indicator, which conveys its state purely visually. README claims "✅ VoiceOver labels across
the Mark Watched → Compare → Ranking flow"; `MANUAL-QA.md` §2 is explicit that the Simulator has
no VoiceOver and every line is unverified. The README overstates what is known.

**No localization**, though the build settings are already primed (`SWIFT_EMIT_LOC_STRINGS`,
`LOCALIZATION_PREFERS_STRING_CATALOGS`). Two things will bite: hand-rolled English plural
ternaries (`DiscoverView`, `TasteAnalysisView`, `PostComment.swift:72`) and multi-line string
concatenation that produces unextractable fragments.

**iPad is shipped and adapted for nothing.** `TARGETED_DEVICE_FAMILY = "1,2"`, with zero
`horizontalSizeClass` reads and zero `NavigationSplitView` in 18 `NavigationStack`s. Either
build the split-view layout or drop family 2. Dark mode, by contrast, holds up — no hardcoded
colours anywhere.

---

## 5. Documentation drift and process risk

- **Phase 28 is ✅ but fails four of its own acceptance criteria** (#3, #9, #19 above).
- ~~`MANUAL-QA.md` cites "92 unit tests"; there are **463**.~~ **Fixed 2026-08-23** (466 now).
- Deployment target is **18.2**; CLAUDE.md, SPEC.md and README all say iOS 17+. `SWIFT_VERSION`
  is 5.0 against a documented 5.9+.
- `MANUAL-VERIFICATION.md` blocker 1 is stale (resolved), and it omits the third migration,
  `20260822010000_client_rpcs.sql`.
- ~~**`RankingView.swift:8-13` documents drag-to-reorder as the exact inverse of shipped
  behaviour.**~~ **Fixed 2026-08-23.** The view header now matches `RankingViewModel.canReorder`
  and `CLAUDE.md` rule 5. The same inverted claim was also corrected in `README.md`,
  `MANUAL-QA.md`, and the Phase 7 / open-question-3 notes in `ROADMAP.md`, which had
  propagated it.
- **The tested ranking algorithm is not the shipping one.** `RankingEngine.insertionPosition` —
  what `RankingEngineTests` proves — is never called by the app. `MediaLibraryViewModel`
  reimplements the bisection inline for the resumable session. There is a legitimate reason
  (the interactive flow needs to pause on user input), but two implementations of the mechanic
  the whole product rests on is a standing risk, and the tests guard the wrong one.
- **Structural:** ~~a stray triple-nested `WatchRank/WatchRank/WatchRank/Views/{Feed,Post,Settings}`
  holds five live files.~~ **Fixed 2026-08-23:** the three folders were moved up into the real
  `Views/`, leaving one `Views/` root again. No `.pbxproj` edit was needed and the suite stayed
  green, confirming the synchronized root group picked the new paths up on its own. Still open:
  `ReportSheet` is buried inside `PostDetailView.swift`, against the one-type-per-file rule.
- **Only two commits** (`Initial commit`, `first it`) against 20+ modified and ~40 untracked
  files. Phases 12–28 are essentially uncommitted, so "when did this screen stop being
  reachable?" cannot currently be answered by `git`. This is the cheapest risk on the list to
  retire.

---

## Recommended order of work

1. **Fix the fresh-install sign-in dead end (#8).** One screen's structure. Everything in
   Part III is inaccessible to a new user until this lands, which makes it the highest
   leverage item in the audit regardless of ship target.
2. **Store blockers (#1–#7).** Each is an outright rejection and most are mechanical: icon,
   privacy manifest, real URLs, EULA checkbox, version bump. `VersionedSchema` (#7) is the one
   with real design content — and it is far cheaper now than after a v1 store build exists.
3. **Wire up what already exists (#9–#13).** Push `PostDetailView` from `FeedPostCard`,
   present `UserSearchView` from "Find People", construct `UserProfileView` from `onOpenActor`,
   add block to the profile, instantiate `SyncEngine` + `SupabasePublishTransport`. This is
   assembly, not new code. **#13 (publish opt-in) must land before or with #9** — the moment
   the engine runs, publishing becomes silent and automatic, and the docs' promise breaks.
4. **Correctness (#15–#20).** #15 corrupts the library and should jump the queue if Discover
   sees real use. Then one shared error presenter — `.description` never
   `String(describing:)`, a retry CTA on every surface, and surface `PostViewModel.lastError` —
   and make `save()` non-silent.
5. **`OSLog` + `MetricKit`.** Two system frameworks that convert every remaining silent
   failure into something observable. Do this before, not after, a TestFlight round.
6. **Posters, onboarding, delete/unwatch.** The three product gaps with the best
   effort-to-perceived-quality ratio.
7. **Decide on iPad**, move the stray folders, and reconcile the docs — including unticking
   Phase 28.

## Not covered here

Visual/VoiceOver verification on device (see `MANUAL-QA.md`), Supabase deployment state, and
performance under a large library. This audit is static: it establishes what is wired and what
is not, not how any of it looks or feels.
