# Functionality & PM gap audit

**Date:** 2026-08-22 · **Target assumed:** TestFlight / App Store · **Scope:** whole app, Parts I–III

> **Status, 2026-08-24.** **Sections 1 and 3 are closed**, Section 4 mostly, and Section 2 is closed but for four
> items in #14 (see its second-pass log). Section 1 (#1–#7) — see the log at the end of
> that section. Section 2 is partly closed by a parallel workstream: **#9 and #13 are
> done**, and **#13's premise is superseded** by `PART-IV-SYNC.md` (a signed-in library
> now syncs unconditionally; consent gates *visibility*, not upload). Findings are kept
> as written rather than edited away — the record of what was wrong is the reason the
> work happened.

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

> **On names.** The product was renamed twice on 2026-08-24 — WatchRank → Binge → Binged — by
> mechanical sweeps that rewrote this document along with the source. Paths and type names below
> therefore read `Binged…` even in findings recorded when the code said `WatchRank…`. That is
> deliberate: a citation's job is to help you find the code *now*. Where a sentence describes
> something historical, the name in it is the current one for the same thing.
>
> **On evidence.** Every finding below was verified directly against the working tree. Three
> claims raised during exploration were checked and **discarded as false**: a `rankings` vs
> `ranked_items` table mismatch, a `posts.author_id` column mismatch, and a nested
> `NavigationStack` in `HomeView`. None of them exist. They are recorded here only so nobody
> re-derives them.

---

## 1. Store rejection blockers ✅ closed 2026-08-23

| # | Finding | Evidence |
|---|---|---|
| 1 | **No app icon.** `AppIcon.appiconset/` contains only `Contents.json` — three 1024² slots declared, zero image files. Archive validation fails outright. `AccentColor` is likewise the unfilled stock template, so the app has no brand colour. | `Binged/Binged/Assets.xcassets/AppIcon.appiconset/` |
| 2 | **No `PrivacyInfo.xcprivacy`.** Mandatory for submission. The app collects email, a handle and user content, and touches required-reason file-timestamp APIs via `CatalogCache` / `LibraryExport`. | `find -name "*.xcprivacy"` → 0 hits |
| 3 | **Report and block are unreachable — Guideline 1.2.** `ReportSheet` exists only inside `PostDetailView`, which has **zero call sites**. `UserSearchViewModel.block(_:)` has **zero callers**. Meanwhile `SettingsView`'s Safety section is four lines of static text *describing* both capabilities: "Report content from any post, comment or profile", "Blocking someone hides them…". The app promises in prose what it does not expose in UI. | `PostDetailView.swift:142`; `UserSearchViewModel.swift:109`; `SettingsView.swift:104-107` |
| 4 | **No EULA / terms gate at sign-up.** The sign-up form has email, password, handle and a password-length footer. No checkbox, no link. Phase 28 step 2 is marked ✅. | `Views/Auth/SignInView.swift:67-104` |
| 5 | **Privacy-policy and support URLs are fictional and force-unwrapped.** `watchrank.app/privacy` and `support@watchrank.app` resolve to nothing, and these are the only three `!` in non-test code — against CLAUDE.md's own rule. | `SettingsView.swift:109,111,112` |
| 6 | **Version never moved.** `MARKETING_VERSION = 1.0` and `CURRENT_PROJECT_VERSION = 1` in all six build configurations, unchanged through Parts I, II and III. Settings will show a user "1.0" for what the docs call v2.0, and TestFlight requires a build bump per upload. | `project.pbxproj:412,427,443,458` |
| 7 | **No `VersionedSchema` / `SchemaMigrationPlan`, behind a `fatalError`.** CLAUDE.md defers migrations to v1.2 and says "delete the app from the simulator" — advice a shipped user cannot follow. Any non-lightweight `MediaItem` change turns an OTA update into an unrecoverable launch crash. The stakes changed at Phase 23 and the guidance did not: `PendingPublish` is the only record of what the device owes the server, and a store that fails to open loses it silently. **Cheapest to fix now, while V1 is the only version.** | 0 hits for either symbol; `BingedApp.swift:41-52` |

### Closure log — 2026-08-23

All seven verified in the built product, not just in source. Unit suite green at 499.

| # | What shipped | Verified by |
|---|---|---|
| 1 | Three 1024² icon variants from a checked-in generator, `tools/make-app-icon.swift`. Light variant written with `noneSkipLast` — App Store rejects a primary icon carrying an alpha channel, and "opaque pixels" is not the same claim. `AccentColor` given light + dark values. | `sips -g hasAlpha` → `no`; 7 AppIcon entries in `Assets.car` |
| 2 | `Binged/Binged/PrivacyInfo.xcprivacy`. **`NSPrivacyAccessedAPITypes` is empty because it should be** — the app uses no required-reason API (no file timestamps; `KeychainTokenStore` exists so no `UserDefaults`). Declares email, handle, name, user content — linked, non-tracking. Already covers Part IV's unconditional library sync; no change needed there. | present in the built `.app` |
| 3 | The comment bubble was a decorative `Label`; it is now a button that pushes `PostDetailView`, which makes the whole thread and both report surfaces reachable for the first time. Added a feed-row context menu (Comments / Report / Block), block on the post-author menu, and block as a comment swipe action. `FeedPostCard`'s `.accessibilityElement(children: .combine)` was flattening the footer and would have hidden all of it from VoiceOver — changed to `.contain`. | 9 new tests in `SafetyReachabilityTests.swift` |
| 4 | Required terms toggle on sign-up, links inline, gating `canSubmit`. | `SignInView.termsSection` |
| 5 | `Models/SupportLinks.swift`, links rendered only if they resolve. Zero force-unwraps left in non-test code. | `grep 'URL(string:.*)!'` → comments only |
| 6 | `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` moved to `Base.xcconfig` — one source of truth instead of four duplicated pbxproj entries — and bumped. | built bundle reports **2.0 (1)** |
| 7 | `BingedSchemaV1` + `BingedMigrationPlan`; the `fatalError` is replaced by `StoreRecoveryView`. That screen deliberately tells the user **not** to delete the app: falling back to an empty library would invite re-ranking on top of data still on disk, which is worse than crashing. | one `fatalError` left, on the unreachable in-memory fallback |

**Still requires a human, and cannot be closed in code:**

1. **`watchrank.app` does not exist.** `SupportLinks` centralises the URLs but cannot make them
   real — a syntactically valid URL to a dead domain is invisible to code. App Review checks the
   privacy-policy link.
2. **Bump `CURRENT_PROJECT_VERSION` per TestFlight upload.** No automation exists.
3. **App Store Connect metadata and privacy nutrition labels** — outside the repo entirely.
4. **Two reserved-handle migrations are written but not pushed** — added 2026-08-24. The chain is
   `20260821210000_social.sql` (`watchrank`, applied), `20260824000000_reserve_binge_handle`
   (`+ binge`) and `20260824010000_reserve_binged_handle` (`+ binged`). **Only the first is live**,
   so in the hosted database `@binge` and `@binged` are claimable by anyone this minute. The client
   half is form validation, and `PART-III-SOCIAL.md` §4 is explicit that a rule the client enforces
   and the database does not is a rule that does not exist. Pushing them is the fix; until then it is
   a live exposure, not housekeeping.

**Adjacent blocker this section does not cover.** `Config/Base.xcconfig`'s own comment says the
TMDB token ships extractable in the bundle and calls that "not acceptable for distribution".
`supabase/functions/tmdb-proxy/index.ts` exists and is unused. Routing catalog calls through an
edge function is its own phase — it has its own caching and rate-limit questions — and it is
currently owned by nobody.

---

## 2. The assembly gap — built, tested, not reachable ◐ mostly closed 2026-08-23

This is the headline. Each item below is working code with passing tests and no entry point.

| # | Finding | Evidence |
|---|---|---|
| 8 | ✅ **Closed 2026-08-23.** **A fresh install cannot create an account.** `ProfileView` renders its empty state *instead of* `statsList` when the library is empty — and `accountSection` lives inside `statsList`. The fallback path is worse: Profile → gear → Settings shows a dead `Text("Not signed in.")` with no button beside it. Sign-in therefore appears only after the user has ranked something. The entire v2.0 social layer is gated behind Part I engagement by accident. | `ProfileView.swift:33-41,76,89-98`; `SettingsView.swift:58-69` |
| 9 | ✅ **Closed 2026-08-23** (parallel workstream: four drain triggers wired). **Nothing is ever published.** `SyncEngine` has **zero references in the app target** outside its own file — never instantiated, and `SocialStack` doesn't hold one. The producer side is live: `markDirty` enqueues a `PendingPublish` row on every ranking write. So the outbox grows monotonically forever and is never read, no post is ever created, and the Following feed can only ever be empty. Phase 23 "Publishing the library ✅". | `grep SyncEngine` → own file only; `MediaLibraryViewModel.swift:617-643` |
| 10 | ✅ **Closed 2026-08-23.** **Three screens have no call site.** `UserProfileView` (0), `PostDetailView` (0), `UserSearchView` (its own `#Preview` only). That takes down public profiles, follow/unfollow, all comment read/write/delete, and both report surfaces. The feed's comment-count bubble is a plain `Label`, not a button. | verified by grep across all views |
| 11 | ✅ **Closed 2026-08-23.** **"Find People" is a dead end.** The feed's `followingNobody` empty state calls `onFindPeople`, which `RootTabView` binds to `selection = .search` — the **movie** search tab. There is no people-search entry point anywhere in the app, so following anyone is impossible. | `FeedView.swift:47-50` → `RootTabView.swift:49` |
| 12 | ✅ **Closed 2026-08-23.** **`RootTabView.rankingFeedService` is stored and never read** in `body`. `BingedApp` builds and passes it; the whole ranking-feed feature is inert. | `RootTabView.swift:36` vs `:40-73` |
| 13 | ✅ **Closed 2026-08-23**, and its premise superseded by `PART-IV-SYNC.md` — sync is now unconditional and consent gates who can *see* the ranking. **No publish opt-in control**, which CLAUDE.md and `PART-III-SOCIAL.md` §13 both promise ("Publishing must be a decision, not a default"). The claim is vacuously true today because nothing publishes — and becomes **false the moment #9 is fixed**, since dirty-bucket enqueueing is automatic on every rank. Build the toggle *before* the wiring, not after. There is also no unpublish; `deleteBucket` exists at the transport layer with no UI, so the only way to remove published data is Delete Account. | no publish UI in `Views/`; `SyncEngine.swift:30,196` |
| 14 | ◐ **Partly closed 2026-08-23** — follower/following lists and the follow-request inbox now exist. **Missing outright**, with service methods already written and zero callers: followers list, following list, pending-request inbox (a private account can never approve a follower), unblock / blocked-users list, report a *profile*, edit a comment, password reset, email-verification handling, avatar upload, edit-own-profile, and notifications of any kind. | `SocialService.swift:33-42`; `AuthService.swift:39`; `FeedService.swift:20` |

### Closure log — 2026-08-23

Unit suite green at **531**. Everything below was reachable-in-principle code with no entry point;
almost none of it needed new logic, only assembly.

| # | What shipped |
|---|---|
| 8 | `ProfileView` rendered its empty state *instead of* `statsList`, and `accountSection` lived inside `statsList` — so a fresh install had no sign-in anywhere. The empty branch now carries its own sign-in CTA, and `SettingsView`'s dead `Text("Not signed in.")` is a button. Two independent routes, because Settings is reachable from a fresh install when a populated Profile is not. |
| 10 | `UserProfileView`, `UserSearchView` and `PostDetailView` all have call sites now. New: `Views/Social/FollowListView.swift` (the Phase 24 screen never written) and `Views/Social/FollowRequestsView.swift` + its view model. |
| 11 | "Find People" routed to the **movie** search tab. People search now lives inside the feed's own navigation stack, reachable from the empty state and from a toolbar menu. |
| 12 | `rankingFeedService` is consumed — `RootTabView` → `HomeTabView` → profile pushes. It was stored and ignored. |
| 14 | Follower and following counts on a profile were inert text; they are links now. The follow-request inbox closes a genuine trap: `isPrivate` was a one-way door, since `pendingRequests`/`acceptRequest`/`rejectRequest` had no caller and a private account could collect requests it could never answer. |

**A launch crash was found and fixed in the process.** A `MigrationStage.lightweight` had been added
between two `VersionedSchema` versions whose `models` both returned the same live types. Identical
types compute identical checksums, and `NSLightweightMigrationStage` throws when from == to — inside
`BingedApp.init()`, so the app died with SIGABRT before drawing a frame, and every test run failed
at bootstrap. Note `StoreRecoveryView` could **not** catch this: it guards `ModelContainer` creation,
and this threw one line earlier while building the plan. Collapsed to a single version. A real second
version needs a *frozen copy* of each changed model, which is the actual price of a schema version and
is not worth paying before a build ships.

### #14 second pass — 2026-08-23, later

Suite green at **539**. Four more closed:

- **Unblock, and a blocked-accounts list.** Needed a migration, not just UI:
  `profiles_select` is `using (… not app.blocked_with(id))`, so blocking is mutual invisibility and
  **a blocked person's profile stops being readable by the blocker too**. A client-side join on
  `blocks` therefore returns bare UUIDs — which is why the app has had `block`/`unblock` since Phase 24
  and no way to see or undo one. Added `supabase/migrations/20260823230000_blocked_accounts.sql`, a
  `SECURITY DEFINER` function scoped to `blocker_id = auth.uid()` that discloses only what the caller
  already knew. UI at Settings → Safety → Blocked Accounts; unblock is not optimistic.
- **Edit profile, including the `isPrivate` toggle.** `updateProfile` had no caller, and `isPrivate`
  had a column, a policy, and no control anywhere — so the follow-request inbox was a queue that could
  only ever be empty. The handle is deliberately not editable here: renaming across every post and
  mention that already names it is its own feature.
- **Password reset**, via `/auth/v1/recover`. The form confirms with "if there's an account for X, a
  reset link is on its way" rather than "sent" — saying "sent" would make it an oracle for which
  addresses are registered.
- **Email-confirmation handling.** `signUp` assumed a non-nil session, so on a project with
  confirmation enabled every sign-up died with `underlying("No session returned")` — a bug message for
  a normal state. Now `AuthError.emailConfirmationRequired`, which says to go and click the link.

**Still open in #14:**

1. **A handle is lost when email confirmation is on.** The handle is claimed with the session, so a
   confirmed-by-email account arrives holding the trigger's placeholder and the chosen handle is gone.
   Needs a claim-on-first-sign-in path. Found while fixing the error above.
2. **Avatar upload.** `avatarURL` is read-only everywhere; needs a Supabase Storage client.
3. **Comment editing.** The database permits it (`app.guard_comment_update`); no service method, no UI.
4. **Notifications of any kind.** No schema, no APNs, no in-app inbox.

---

## 3. Correctness bugs on paths users can actually reach ✅ closed 2026-08-23

| # | Finding | Evidence |
|---|---|---|
| 15 | ✅ **Closed 2026-08-23.** **Discover creates duplicate library rows.** `DiscoverView` hands a freshly-minted detached `MediaItem` to `MediaDetailView` without calling `canonicalItem(for:)` — which `SearchView` *does* call. Queued titles are deliberately kept in Discover, so tapping one opens a detail screen reporting `.untracked`; marking it watched inserts a second row. This is precisely the failure `canonicalItem`'s own doc comment warns about, including "the comparison flow can pit the film against itself." | `DiscoverView.swift:104`; `SearchView.swift:101`; `MediaLibraryViewModel.swift:205-231,672-676` |
| 16 | ✅ **Closed** — the `followers_of` / `following_of` migration landed. **`followers_of` / `following_of` RPCs are called but defined in no migration.** This sits on a live path: `FeedViewModel.emptyPhase` probes `following(of:limit:1)` whenever a feed page comes back empty, so against a real backend an empty feed renders `.error(…)` instead of the `followingNobody` / `quiet` states Phase 26 was built around. | `SupabaseSocialService.swift:190,194`; absent from all three migrations |
| 17 | ✅ **Closed 2026-08-23.** **Every ranking write can fail silently.** `try? modelContext.save()` is the single write path for ranking, reorder, sentiment change and review. On failure the UI keeps its in-memory state and the user believes it saved. Three more unchecked `try? save()` elsewhere; fetches degrade to `?? []`, making a failed read indistinguishable from an empty library. | `MediaLibraryViewModel.swift:682`, `:579,633,651` |
| 18 | ✅ **Closed 2026-08-23.** **Raw Swift error dumps shown to users.** `String(describing: error)` in `FeedViewModel:69`, `SessionViewModel:118,140`, `PostViewModel:68,100,126` — while `UserSearchViewModel` and `UserProfileViewModel` correctly prefer `.description`. Offline, the feed shows the user literally `transport("Could not reach the server.")`. The codebase disagrees with itself. | verified |
| 19 | ✅ **Closed 2026-08-23** — `PostDetailView` now presents it. **`PostViewModel.lastError` is set in four places and read by no view.** A failed comment, delete, report — or a rate-limit rejection from the new triggers — produces silence. Phase 28's criterion "a rate-limited action fails with a clear message, not a silent no-op" is unmeetable. | `PostViewModel.swift:20,68,88,100,126` |
| 20 | ✅ **Closed 2026-08-23.** **Pagination failures are swallowed as end-of-list** (`catch { hasMore = false }`), so a transient 500 is indistinguishable from having reached the end. Optimistic updates also revert with no explanation. | `FeedViewModel.swift:105-107,127-129`; `UserProfileViewModel.swift:94-96` |

### Closure log — 2026-08-23

Suite green at **546**, with regression tests for the two that could be reproduced.

| # | What changed |
|---|---|
| 15 | `DiscoverView` now canonicalises before pushing detail **and** before queueing or dismissing — the same thing `SearchView` already did. Three tests pin it, including one that asserts the *bug* still reproduces without the call, so nobody "simplifies" it away. |
| 16 | Already closed by the `followers_of` / `following_of` migration. `FollowListView` is built on it. |
| 17 | `MediaLibraryViewModel.save()` records the error instead of `try?`-ing it away, and `RootTabView` presents it app-wide — a save can fail from Detail, Compare or Ranking. The message deliberately does not clear on the next successful save: the user still needs to know an earlier change did not land. |
| 18 | Every `String(describing: error)` in `ViewModels/` is gone; all four now use `ErrorMessage.text(for:)`. |
| 19 | `PostViewModel.lastError` was set in four places and read in none; the thread presents it. |
| 20 | A failed page no longer masquerades as the end of the list. Both `FeedViewModel` and `UserProfileViewModel` carry `loadMoreFailed`, and both surfaces offer Try Again. This matters more on a profile than in a feed: the reader is looking at an *ordering*, and a silently missing tail changes what it says. |

**Also fixed, found while working:** `SearchViewModel.phase` reads `errorMessage` first, and nothing
cleared it when a new search was scheduled — so a stale failure stayed on screen through the whole
debounce while the user typed a good query. Clearing the error alone would have fallen through to
"No matches for …" *before* the search ran, so `isSearching` is raised in the same breath.

**Deliberately not fixed — no home for the report yet.** Three background `try? save()` calls remain
(`MediaItem.swift:194`, `ExternalIDMigration.swift:144`, `FeatureProvider.swift:106`). These are
maintenance passes with no user waiting on them, and an alert would be noise. The right answer is a
log line, which the app has nowhere to put — see Section 4, "zero logging or telemetry". A silent
`FeatureProvider` failure is the one with teeth: features never populate, and recommendations quietly
get worse with nothing to show for it.

**Untested:** #17's failure path. Forcing a SwiftData save to fail in a unit test is not worth the
scaffolding; the recording and presentation are straightforward, and the alternative was discarding
the error entirely.

---

## 4. Product gaps a PM would flag ◐ mostly closed 2026-08-24

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

### Closure log — 2026-08-24

Suite green at **565**.

| Gap | What changed |
|---|---|
| **Poster art on Part I screens** | `PosterView` was used on exactly one screen while Home cards, Ranking rows, the Detail hero and Compare cards drew gradients over a `posterURL` the app had already fetched and stored. Swapped at the `MediaRow`/`MediaCard` convenience initialisers, so every screen that builds from a `MediaItem` got it at once. `PosterView` already falls back to the gradient on a nil URL or a failed load, so this is never worse than what it replaced. |
| **No destructive action anywhere** | Added `remove` and `unwatch` to `MediaLibraryViewModel` (there was no `modelContext.delete` for a `MediaItem` in the codebase), plus Remove from Library, Remove from Watchlist, and "I haven't watched this" on Detail. Both new paths recompute the bucket they leave — the vacated-bucket bug has been got wrong twice here, so each exit path has its own test. |
| **The watchlist was a five-item rail** | `allWantToWatch` plus `Views/Home/WatchlistView.swift`, reachable via "See all". A sixth queued title was previously unreachable from anywhere. Swipe to remove. |
| **"Not for me" was irreversible** | `undismiss` had existed since Phase 17 with only tests calling it. Discover now keeps a one-item undo bar. |
| **Discover always opened empty** | Mood and type were plain `@State` with no default, so the first frame was an empty state every launch however many times the same mood was picked. Both now persist in `@AppStorage`. |
| **The prediction feedback loop was invisible** | The app froze a guess when a title was queued and never mentioned it again. Detail now says "We guessed 8.1 — you scored 7.4", with a verdict line that is plain about being wrong. Shown only once the real score is shown, or it would leak a number rule 6 is deliberately withholding. |
| **Zero logging** | `Services/AppLog.swift` — `OSLog`, five categories, no dependency. The four background `try? save()` calls that Section 3 left alone now have somewhere to report to, including `FeatureProvider`, whose silent failure made recommendations quietly worse with nothing to show for it. Interpolation redaction is left at the default: titles, handles and review text must never be marked `public`. |

**Still open in Section 4:**

1. **No onboarding.** Still no first-run flag of any kind. The only explanation of the comparison
   mechanic is `RankingExplainerView`, three taps deep in Settings. A new user is asked "Which did you
   prefer?" with no explanation of why.
2. **Accessibility.** New controls got labels and hints as they were built, but the original finding
   stands: `SearchView`, `SignInView` and `SettingsView` have almost none, and Phase 11's VoiceOver
   criterion has never actually been walked.
3. **No search, filter or sort within the ranked library**, and no pagination in Search or Discover.
4. **No localization.** Build settings are primed; nothing is extracted. Hand-rolled English plural
   ternaries will need rework.
5. **iPad.** `TARGETED_DEVICE_FAMILY = "1,2"` with zero size-class handling. Adapt or drop family 2.
6. **`MetricKit`.** `OSLog` covers "what happened on this device"; nothing yet reports crashes or hangs
   back to you.

**Not fixable client-side:** posters on *other people's* rankings and on feed posts. Neither
`RankedItem` nor `FeedPost.Payload` carries a poster URL — they are denormalised server payloads, so
artwork there means adding a column, not changing a view.

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
- **Structural:** ~~a stray triple-nested `Binged/Binged/Binged/Views/{Feed,Post,Settings}`
  holds five live files.~~ **Fixed 2026-08-23:** the three folders were moved up into the real
  `Views/`, leaving one `Views/` root again. No `.pbxproj` edit was needed and the suite stayed
  green, confirming the synchronized root group picked the new paths up on its own. Still open:
  `ReportSheet` is buried inside `PostDetailView.swift`, against the one-type-per-file rule.
- **Only two commits** (`Initial commit`, `first it`) against 20+ modified and ~40 untracked
  files. Phases 12–28 are essentially uncommitted, so "when did this screen stop being
  reachable?" cannot currently be answered by `git`. This is the cheapest risk on the list to
  retire.

---

## 6. The composition root is untested — added 2026-08-23

Not in the original audit, and it is the single best explanation for Section 2.

**No test constructs `BingedApp`.** The unit suite builds its own `ModelContainer`s and view models
directly, so `BingedApp.init()` — which resolves the schema, the migration plan, the catalog, the
social stack and the sync engine — is executed only when a human launches the app.

Two things this session prove the cost. First, a `MigrationStage.lightweight` between two schema
versions with identical checksums made the app abort on launch **while the suite reported 531 tests
green**, because nothing in the suite reaches that code. Second, every Section 2 finding — three
screens with no call site, a service accepted and never read, a "Find People" button wired to the
wrong tab — lives in exactly the same untested layer: wiring, not logic.

The suite tests the parts. Nothing tests the assembly.

Cheapest useful coverage, roughly in order:

1. A launch smoke test that actually calls `BingedApp.init()` and asserts it returns — it would have
   caught the abort in milliseconds.
2. A test asserting `BingedMigrationPlan.stages` is constructible, which is the specific thing that
   threw.
3. Reachability assertions: for each screen, that something constructs it. Awkward in XCTest, but a
   grep-based check in CI would have caught all of #10.
4. UI tests that visit the social surfaces. They currently cannot — `-uiTestingInMemoryStore` makes
   `makeSocialStack` return `nil`, so Part III is unreachable *from the tests by construction*.

**Why this slipped through.** No test asserts that any screen is reachable. The unit suite
covers view models and services thoroughly and stops exactly at the wiring layer, which is
where all of the above lives. The UI tests can't help either: they launch with
`-uiTestingInMemoryStore`, which makes `makeSocialStack` return `nil`, so Part III is
unreachable *from the tests by construction*.

---

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
