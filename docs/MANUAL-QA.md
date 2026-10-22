# Manual QA checklist

Phase 11's remaining acceptance criterion is a manual smoke test. This is the
list — what a person still has to check, and **why automation cannot do it.**

Everything here has been verified to compile, and the suite is green (463 unit
tests as of 2026-08-23, plus the UI flow tests). None of that tells you the app looks right,
sounds right under VoiceOver, or behaves correctly to a human. Those are
different claims, and only the first has been established.

Run against the **iPhone 16 simulator, iOS 18.3**. Delete the app first, so you
start from an empty library.

---

## 1. Empty states — the parts I am least sure about

These changed most recently and have never been seen rendered.

- [ yes] **Fresh launch, Home tab.** All four rails are empty at once, and each now
      carries its own "Browse" button. **Does four identical buttons read as
      helpful or as clutter?** If it grates, the fix is to show the CTA on only
      the first empty rail, or drop it from rails entirely and let the floating
      "+" do that job. This is a judgement call I could not make without seeing it.
- [ yes] **Rail card proportions.** Each empty rail is a compact card with the
      button pushed to the right edge. Check the longest copy — "Rank some
      movies to see your top picks." — does not crowd the button on the
      narrowest device.
- [ gap between the filter list and Rankings header is huge] **Ranking tab, empty.** Shows a trophy, one line, and "Find something to
      watch". Tapping it should switch to the Search tab.
- [yes ] **Profile tab, empty.** Same pattern, same CTA behaviour.
- [ ] **Search, no results.** Type gibberish. Expect "No matches for ..." plus a
      "Clear search" button that actually clears the field.
- [ yes] **Search, before searching.** Deliberately has **no** CTA — a button under
      a visible search field is noise. Confirm you agree; this knowingly departs
      from the roadmap's "every empty state has a CTA".

## 2. VoiceOver — the actual acceptance criterion

> "VoiceOver can complete a Mark Watched → Compare → Ranking flow."

**The Simulator has no VoiceOver** — it is not in Settings, so this cannot be
checked the way the criterion implies. Use **Accessibility Inspector** instead
(Xcode → Open Developer Tool → Accessibility Inspector), point its target
selector at the simulator, and walk the flow reading each element's label,
traits, and hint. That covers everything below except the actual speech.

I reasoned about what it will announce but **never heard it**, so treat each
line as unverified.

- [ ] **Sentiment buttons** announce "Liked it" / "It was fine" / "Didn't like
      it" — **not** "hand thumbsup fill". This was genuinely broken before; it
      had a trait but no label, so the raw SF Symbol name was read out.
- [ ] The selected sentiment is announced as **selected**, and the hint
      distinguishes choosing from clearing.
- [ ] **Comparison progress** is spoken once as "Comparison 2 of 4" — not the
      text followed by a bare percentage from an unlabeled progress bar.
- [ ] **Compare cards** announce title, year, and "new item" for the one being
      placed, with the hint "Select if you preferred this".
- [ ] **Score on detail** announces "Score 8.4 out of 10, ranked number 2 in
      Liked it" — not "8.4, #2 in Liked it".
- [ ] **You can finish the whole flow** using only VoiceOver. This is the
      criterion; everything above is a means to it.

## 3. Dynamic Type

- [ yes] Settings → Accessibility → Larger Text, drag to maximum. Walk every screen.
- [ yes] The **detail score** scales. It was pinned at 48pt and ignored text size
      entirely; it now scales relative to `.largeTitle`. Check it does not
      collide with the rank line beneath it.
- [yes ] Nothing clips or truncates unreadably — especially the sentiment buttons
      and the compare cards, which pack an icon and text on one line.

## 4. Dark mode

There are **zero hardcoded colors** in the codebase, so this should be clean.
Worth a pass anyway, since "uses system colors" and "looks good" differ.

- [ yes] Every screen in dark mode: Home, Search, Detail, Compare, Ranking, Profile.
- [ yes] The sentiment buttons use green / amber / red fills — check contrast of
      white text on those in dark mode specifically.
- [ yes] Poster placeholders are generated gradients, not system colors. Check they
      still look deliberate against a dark background.

## 5. Ranking behaviour — does it feel right?

The maths is well covered by tests. Whether it *feels* correct is not.

- [ ] Rank 5–6 titles into "Liked it". Do the comparisons asked of you feel
      sensible, or does it ask something obviously redundant?
- [ ] Final order matches the preferences you actually expressed.
- [ ] Scores sit inside the right bands — Liked 6.8–10.0, Fine 3.4–6.7,
      Disliked 0.0–3.3 — and no item sits exactly on a boundary.
- [ ] A single item in a bucket lands at that bucket's midpoint.
- [ ] Comparison count stays small: 7 items should never need more than 3
      comparisons, 15 never more than 4.

## 6. Two bug fixes that need confirming by hand

Both are covered by unit tests, but both were originally missed *because* the
tests were green.

- [ ] **Duplicate identity.** Search a film, mark it watched. Search the *same*
      film again. You should see your ranked copy — with its score — not a
      fresh unranked duplicate. Mark it watched again: it must **not** offer to
      compare the film against itself.
- [ ] **Change Rating.** Rank three titles into "Liked it", then change the
      middle one to "It was fine". The two left behind must renumber to #1 and
      #2 with **recalculated** scores. Before the fix they kept scores computed
      for three items and left a gap in the ranks.

## 7. Edge cases the tests avoid

Named because the suite genuinely does not cover them.

- [ ] **Abandon a comparison.** Start ranking a title into a non-empty bucket,
      then swipe the modal away mid-comparison. The title should still end up
      with a sensible score, not sit unranked or scoreless. Tests always drive
      comparison sessions to completion, so this path is unvisited.
- [ ] **Drag to reorder** on the Ranking screen's Movies or TV tab (the All
      tab interleaves two rankings, so it offers no Edit button). Scores should
      recompute immediately and stay inside the bucket's band.
- [ ] **Cross-bucket drag is blocked** — you should not be able to drag an item
      from one sentiment section into another.
- [ ] **Persistence.** Rank several titles, force-quit, relaunch. Everything
      should return exactly as left. Tests assert against the same in-memory
      context they wrote to, so nothing has ever round-tripped through the
      on-disk store.
- [ ] **Search debounce.** Type quickly and delete quickly. Results should
      settle on what you actually typed. Unit tests pass `debounce: .zero`, so
      the real keystroke path is never exercised.

## 8. Changes made after your first pass

New behaviour from your feedback. None of it has been seen running.

### Fixed from your notes
- [ ] **Search text no longer persists.** Type a search, switch to another tab,
      come back — the field and results should be empty. Pushing into a title's
      detail and coming back should *not* clear it; only leaving the tab does.
- [ ] **Ranking empty-state gap.** The empty state was hugging the type filter
      with a void beneath. It should now sit centred in the space below it.

### Films and shows are ranked separately
A bucket is now `(media type, sentiment)`.

- [ ] Rank a few **films** as "Liked it", then rank a **show** as "Liked it".
      The show must be placed with **no comparisons at all** — its own bucket is
      empty. You should never be asked to compare a show against a film.
- [ ] Both a film and a show can be **#1** at the same time, each in its own list.
- [ ] **Reorder moved tabs.** Drag-to-reorder now works on the **Movies** and
      **TV** tabs, and is disabled on **All**. This is the reverse of before:
      All now interleaves two independent rankings for browsing, so it is not a
      single list a drag could resolve against. Confirm this reads sensibly —
      it is the part of the change most likely to feel wrong in the hand.

### A score is withheld until a bucket has 5 items
- [ ] Rank your first film. You should see **"#1 in Liked it"** and a line
      saying how many more are needed — **no number**.
- [ ] Keep going. At the **fifth** film in that bucket the number appears, on
      the detail screen and as row badges, without you doing anything else.
- [ ] The count is **per list**: five films does not reveal scores for shows.
- [ ] Check the copy reads well — "Rank 3 more films in this list to see a
      score." Singular/plural and film/show wording both switch.
- [ ] **Does this feel better than the old behaviour?** It was your objection
      that a rating appeared immediately off thin data. Whether 5 is the right
      number is a judgement only you can make — it is one constant
      (`MediaLibraryViewModel.minimumBucketSizeForScore`) if you want it moved.

### No rating until the ranking is finished
- [ ] Tap **Rank it** on a title going into a bucket that already has entries.
      Between the sentiment sheet closing and the comparison modal appearing,
      the detail screen must show **no score and no position**. It previously
      flashed a provisional rating that your comparisons then overwrote.
- [ ] Finish the comparisons — the rating appears only now.
- [ ] Swipe the comparison modal away mid-flow. The item should resolve to a
      sensible rating rather than staying blank forever.

### Undo and "Too close to call"
- [ ] **Undo** (top right of the comparison modal) is greyed out on the first
      comparison, and enabled once you have answered one.
- [ ] Answer a comparison, tap Undo — the *same pair* comes back and the
      "Comparison 2 of 4" counter rewinds.
- [ ] Answer it the other way. The next pair should differ from what you saw
      the first time, proving the search really rewound rather than replaying.
- [ ] Undo repeatedly back to the first comparison.
- [ ] **"Too close to call"** ends the comparisons immediately and seats the new
      title **directly below** the one on screen. Check that placement reads
      right to you — the incumbent keeping the higher spot is a judgement call.
- [ ] A tie can be undone too.

### Bigger catalog
- [ ] Search returns far more now — **126 titles**, 78 films and 48 shows,
      1942–2023. Enough to fill a bucket past the score threshold without
      running out of things to rank.

---

## If something looks wrong

Note the screen and what you expected. For anything in section 1, it is almost
certainly my judgement rather than a bug — those were design calls made without
seeing the result.

**Before trusting any failing UI test**, check the machine is idle
(`uptime`, `sysctl vm.swapusage`). Simulator starvation produces failures that
read exactly like code regressions — dead simulators, apps that "fail to
launch", elements that never appear — and it cost several hours of misdiagnosis
on 2026-08-21. One unchanged UI test gave PASS, FAIL, FAIL on three consecutive
runs purely from load.

---

## Journey 6 — Discover (v1.1)

Added in Phase 18. Assumes a build with a TMDB token; without one the Discover
tab is deliberately absent.

### 6a. Cold start

1. Fresh install, no ranked titles. Open **Discover**.
2. Pick Movies, tap any mood.
3. **Expect:** an empty state naming the exact shortfall — "Rank 10 more titles
   and we can start predicting…" — with a CTA into Search. Not a spinner, not an
   empty list.
4. Rank fewer than 3 titles of one type, then ask for that type.
   **Expect:** the copy names *that type* ("2 more shows"), because the
   baselines are per-type and a film library says nothing about television.

### 6b. Recommendations

1. With >= 10 ranked titles and >= 3 of the chosen type, pick a mood.
2. **Expect:** up to 20 rows, each with a poster, a rationale line ("Because you
   like ..."), and an **outlined** predicted badge.
3. **Check the badge is not mistakable for a real score.** Put Discover and
   Ranking side by side: the earned score is a filled pill, the prediction is
   outlined and labelled "predicted".
4. Switch moods. **Expect:** re-ranks with no visible hang, and the top of one
   mood should differ from another.

### 6c. Feedback loop

1. Swipe a row -> **Want to Watch**. The row shows "In your list".
2. Swipe another -> **Not for me**. It disappears.
3. Switch to every other mood. **Expect:** the dismissed title never reappears.
4. Mark a queued title watched and rank it.
5. Open **Profile**. **Expect:** a Predictions section once enough titles are
   ranked — and it should say "Not enough ranked titles yet" when the rank
   correlation is not significant, rather than quoting an error figure.

### 6d. Detail screen prediction

1. Tap any title you have **not** watched.
2. **Expect:** a predicted score in an outlined box, quieter than the earned
   score on a watched title, with "Predicted score" beneath it — or a
   qualitative band when confidence is low.
3. Tap a title you **have** watched. **Expect:** the real score, and **no**
   prediction anywhere.

### 6e. Airplane mode

Turn the network off and walk every screen.

1. **Discover, pool already built:** results still appear, from cache.
2. **Discover, pool never built:** an offline empty state that says so and
   suggests pull-to-refresh. Never an endless spinner.
3. **Detail:** the prediction still renders — it is computed locally — though
   less confidently, because the feature fetch cannot run.
4. **Search:** degrades to cached results with no crash.
5. **Home, Ranking, Profile, Compare:** fully functional. These have never
   needed the network and must not start now.

### 6f. Accessibility

1. VoiceOver: pick type -> pick mood -> add to queue, unaided.
2. A recommendation row must read **"predicted 8.2 out of 10"** — never a bare
   number, which is indistinguishable from an earned score.
3. Mood chips must announce their name and selected state. They are the primary
   control on the screen and must never be symbol-only.
4. Posters must be silent. They are decorative and the row already names the
   title.
5. Largest accessibility text size: the mood chip grid is what breaks first.

---

## Journey 7 — Social (v2.0)

Added 2026-08-23. Assumes a build with Supabase configured; without it the
social surfaces are absent by design and every screen below should simply not
appear — which is itself worth confirming once.

> **Read `GAP-AUDIT.md` first.** It records that sign-up may be unreachable on a
> fresh install. If you cannot create an account, that is the known finding, not
> a new one — stop and fix that before running the rest of this journey.

> **Deploy the schema before you start.** `supabase db push` — the RPCs the app
> calls (`feed_page`, `author_posts`, the follow lists) live in migrations that
> postdate the Phase 20 run. If they are missing, the feed fails and the app
> renders the failure as an error, which reads as a client bug and is not one.

> **Two accounts are not optional.** The feed is drawn from people you follow
> and `follows_no_self` forbids following yourself, so a single account can
> never see anything in its own Following tab. Sign out and back in on one
> simulator, or run two.

### 7a. Signed out is a complete app

The rule the whole architecture rests on: everything that worked in v1.0 still
works with no account.

1. Fresh install, do not sign in. Rank five films end to end.
2. **Expect:** Home, Ranking, Search, Compare, Profile and Discover all behave
   exactly as in Journeys 1–6. No sign-in wall, no disabled controls, no empty
   state that reads as an error.
3. The Home tab's Yours/Following switcher must be **absent**, not present and
   empty — offering a half with nothing in it advertises the feature as broken
   rather than as optional.

### 7b. Account creation

1. Sign up. Watch the handle field as you type: taken and available states must
   both render, and neither may be conveyed by colour alone.
2. **Expect:** a terms/EULA link before the account is created. Its absence is a
   store rejection, not a nitpick.
3. Force-quit and relaunch. **Expect:** still signed in, and the feed does not
   flash its signed-out empty state on the way — sign-in is restored
   asynchronously, and `FeedView` keys its load on the session for this reason.

### 7c. Who can see it is the account's privacy setting

**Read this distinction before running the steps, because the pass/fail flips
on it** (`PART-IV-SYNC.md` §3 and the amendment atop that file). A signed-in
user's library goes to *their own account* unconditionally — that is what makes
signing in on a second device restore it. Who **else** can read it is decided by
one thing and one thing only: whether the account is private.

| Account | Who sees the ranking |
|---|---|
| public (`is_private = false`, the default for a new account) | any signed-in user |
| private | accounts whose follow request the owner has **accepted** |

So "did anything upload?" is the wrong question. The right ones are "can a
second account see it?" and "did my own library survive?".

> **Rewritten 2026-08-27.** This section used to script a separate publish
> opt-in — a sharing sheet at first sign-in, **Show My Followers** and **Hide My
> Ranking** buttons in Settings, and a per-bucket `is_published` column. All of
> it was deleted (`20260826020000_visibility_follows_account_privacy.sql`,
> applied to the hosted project the same day). **If you find any of those
> controls in a build, that build predates the change** — it is not a pass and
> not a fail, it is the wrong binary.
>
> Why it went: the sheet was gated on `publishableCount > 0`, so an account
> created before it ranked anything — which is every new account — was never
> asked, and two real test accounts ended up unable to see each other with
> nothing on screen to explain it.

Two accounts, A and B, neither following the other yet.

1. **A new account is public and says so.** Sign up as A. **Expect:** the
   sign-up footer states both halves — that rankings are saved to the account,
   *and* that new accounts are public. A screen that mentions only the first is
   a silent publication and is a bug.
2. **No sheet.** Nothing asks permission to share, at sign-in or afterwards.
   "Nothing happened" is the pass.
3. **Rank, then look from outside.** With A signed in, rank at least five films
   so a bucket has earned a score. From B, open A's profile by handle.
   **Expect:** the ranking is there — with no action taken by A beyond ranking.
   Scores appear only for buckets holding
   `minimumBucketSizeForScore` titles; smaller buckets show a position instead.
4. **Settings reports the rule, and does not offer a second switch.** On A,
   Settings → Sharing reads **Your ranking: Anyone on Binged**, a count of
   titles others can see, and a link to **Account Privacy**. There is no
   publish/hide button. The footer must not claim anything "stays on this
   device" while signed in.
5. **Private closes it.** On A: Edit Profile → Private account → Save. From B,
   reload A's profile. **Expect:** the padlock state — "This account is private.
   Follow to see their ranking." Settings on A now reads **Followers only**.
6. **A pending follow grants nothing.** From B, tap Follow. **Expect:**
   `Requested`, and A's ranking still hidden. Approval is the gate, not the
   request (pinned by `rls_test.sql` assertion 8).
7. **Approval opens it.** On A, accept the request from the follow-requests
   inbox. From B, reload. **Expect:** the whole ranking, including titles ranked
   before the follow existed.
8. **Going private hid rows; it did not delete them.** In the Supabase
   dashboard, A's `ranked_items` rows are all still present through steps 5–7.
   Hiding that deletes rows is a data-loss bug, not a tidy implementation.
9. **The backup is unconditional.** Sign A out and back in on a second
   simulator; the ranking restores. This must hold in *both* privacy states —
   privacy governs other people's access, never whether the account keeps a
   copy.
10. **Titles with no `externalId` are absent, and Settings says so.** Check the
    count in words against what is missing from B's view.
11. **Mid-comparison is not sent.** Start ranking a title into a non-empty
    bucket and leave the comparison modal open. Nothing should sync while it is
    open; finishing it should send the whole bucket at once. This is the one
    case where "nothing happened" is the pass.
12. **Offline.** Airplane mode, rank a title. The comparison flow runs at local
    speed. Turn the network back on without touching the app: the sync should
    drain on its own.

### 7d. Follow, feed, comment

1. From account A, find account B by handle and follow.
2. Rank something on B. **Expect:** it appears in A's Following feed.
3. Comment and react from A. **Expect:** both appear on the post, and the count
   on the card matches the detail screen.

   > **This step is a regression check now, not a formality.** Until 2026-08-25
   > `addComment` inserted a column named `author_id` into a table whose column
   > is `user_id`, and decoded an insert's bare row as a `PostComment`, which
   > needs three joined author fields. Either fault alone is fatal, so **posting
   > a comment had never once worked against a real database** — invisible to
   > the suite, because `MockFeedService` builds its return value in memory and
   > so cannot disagree with a column name. It now goes through the
   > `add_comment` RPC. Confirm the comment appears **with the author's handle
   > and display name on it**: a comment that posts but renders nameless means
   > the join, not the insert, is what broke.
4. Edit your own comment from A. **Expect:** the new text, an "edited" marker,
   and no Edit action offered on anybody else's comment — including on a post A
   owns, where A may delete a comment but must never be able to rewrite it.
5. Scroll the feed past one page. **Expect:** more posts load, and the loading
   row announces itself to VoiceOver rather than sitting silent.

### 7e. Privacy and safety

1. Make B private. **Expect:** A, unfollowed, sees a private state and no
   content — and a *blocked* account is indistinguishable from one that never
   existed.
2. **Report and block must be reachable from the UI.** `SettingsView` promises
   both in prose. If you cannot reach them by tapping, that is Guideline 1.2 and
   the app cannot ship.
3. Delete the account. **Expect:** published content is gone; the library on the
   device is untouched and still fully usable signed out. This is the
   distinction the Settings copy makes, and it must be true.

### 7f. Score rules survive the network

The ranking mechanic is not allowed to change because a social layer exists.

1. A foreign profile's top five must obey rule 6 exactly as your own does: a
   number only once that bucket holds five, otherwise a position.
2. Airplane mode: Home, Ranking, Search, Compare and Profile stay fully
   functional. The feed and profiles degrade to an explained empty state — never
   an endless spinner.

### 7g. Accessibility

1. VoiceOver: sign in -> find a person -> follow -> read a feed post, unaided.
2. Every spinner announces what it is loading, not a bare "in progress".
3. Largest accessibility text size across the feed card and the profile header.

### 7h. The five-minute version, with no server at all

Not a substitute for the walk above — it proves nothing about the schema or the
policies, which is the entire point of running against a real project. It is
for looking at the screens.

```bash
xcrun simctl launch --terminate-running-process booted Jude.WatchRank -uiTestingMockSocial
```

Comes up signed in as `@you` against `MockSocialFixture`: four people, seven
posts across all three kinds, a comment thread containing a deleted comment,
reactions, and three published libraries that straddle the five-title score
threshold. Publishing goes to `MockPublishTransport` and reaches nothing.

1. Home → **Following**: a populated feed. Every card renders, the bucket-of-one
   post shows no position, and counts are non-zero.
2. Open a post: the thread, "Comment deleted" in place, and a working composer.
3. Tap through to a profile: Mina's shows scores, Devon's shows positions only,
   Sasha's reads as private.
4. Settings → Sharing renders against your real library: the audience your
   account's privacy setting implies, a real count of titles others can see, and
   a link to Account Privacy. **No sheet appears at launch** — the publish
   opt-in was removed on 2026-08-26, and a build that still asks is the wrong
   binary. The fixture's transport reaches nothing, so this proves the copy and
   the wiring, never the schema.

### 7i. Two devices — the thing Part IV exists for

**This is the journey nothing else covers.** Every automated test merges against
a mock; the merge has never met a real second device, a real network, or a real
`updated_at`. Run it last, and run it on a quiet machine — a simulator starved
of CPU produces failures indistinguishable from real ones.

You need two simulators, or one simulator and a delete-and-reinstall between
steps. Call them A and B.

**Setup.** On A: sign in, rank at least five films so a bucket has earned a
score, and queue two more. Confirm they reach the account (7c).

1. **Restore onto an empty device.** Install fresh on B and sign in with the
   same account. **Expect:** the library appears — ranked titles in the right
   sentiment buckets, in the right order, and the queue too. Scores are
   *recomputed locally*, so check they sit inside the right band rather than
   expecting the exact numbers from A.

   **Count the watchlist explicitly, against A.** It shipped unsynced until
   2026-08-27 — the outbox could not name a bucket with no sentiment, so the
   queue never left the device while everything around it worked — and this step
   read as passing throughout, because the ranked titles it names *did* come
   back. A watchlist that is short by any number is a regression of that bug.
2. **Un-rank a title, then check B again.** On A, move a ranked title back to
   the watchlist. **Expect:** on B it appears on the watchlist. It must not
   vanish: before the fix the bucket it left was republished without it and
   nothing re-added it, so un-ranking deleted the title from the account
   outright.
3. **Nothing was lost on the way.** Count titles on B against A. A title that
   never had an `externalId` will be missing, and the app should **say so**
   rather than leave a silent gap — that is `unsyncableCount` surfacing. A gap
   with no explanation is a bug; a stated one is the design.
4. **Merge, not replace.** On B, before signing in, rank two films A has never
   seen. *Then* sign in. **Expect:** B ends with both libraries. Nothing from
   either side is discarded. This is the single most important assertion in this
   journey — the failure it guards is a device quietly overwriting an account.
5. **Position disagreements resolve silently.** Reorder a bucket on A, let it
   sync, then foreground B. **Expect:** B follows, with no prompt. Position is
   derived, never chosen (rule 4), so there is nothing to ask about.
6. **Sentiment disagreements take the newest deliberate act.** Re-rate one film
   Liked → Fine on B. Then, on A *without* letting it sync first, re-rate the
   same film Liked → Didn't like it. Foreground both. **Expect:** the later
   re-rate wins on both devices. A stale device must not overwrite a newer
   decision — that is `lastRankedAt` against the row's `updated_at`.
7. **Both buckets rescore.** After step 6, check the bucket the film *left* as
   well as the one it joined. Scores in the vacated bucket must have recomputed
   for its new size. This is the vacated-bucket bug with a network in the
   middle, and it is the one most likely to be wrong.
8. **An unreachable account is not an empty one.** Put B in airplane mode and
   sign in. **Expect:** an explicit "could not reach your account" message and
   an **unchanged** local library. What must never happen: B treating the
   failure as an empty account and pushing itself over A's library. If B ends up
   with fewer titles than it started with, stop and report it.
9. **Visibility survives a merge.** Rank a title in a bucket B has never sent
   before. **Expect:** a second account sees it, with no further step. This used
   to be the test of a per-bucket publication flag adopting the account's
   standing answer; since that flag was removed there is nothing for a new
   bucket to adopt or fail to adopt, and the assertion is simply that a merged
   bucket is as visible as any other. The failure mode it still guards —
   "sometimes my shows don't show up" — would now mean the bucket never
   published at all.
