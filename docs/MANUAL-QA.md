# Manual QA checklist

Phase 11's remaining acceptance criterion is a manual smoke test. This is the
list — what a person still has to check, and **why automation cannot do it.**

Everything here has been verified to compile, and the suite is green (92 unit
tests plus the UI flow tests). None of that tells you the app looks right,
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
- [ ] **Drag to reorder** on the Ranking screen's All tab. Scores should
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
