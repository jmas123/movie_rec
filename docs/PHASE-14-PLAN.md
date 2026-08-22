# Phase 14 — Moods and the candidate pool: technical plan

Written 2026-08-21, against the code as it stands after Phase 13, and
incorporating a design review of the roadmap's original Phase 14 text.

This plan **implements** [`ROADMAP.md` Phase 14](./ROADMAP.md#phase-14--moods-and-the-candidate-pool-)
and changes two of its acceptance criteria (§2). It also caused a fix to
**Phase 15 step 4**, already written into `ROADMAP.md` and explained in §6.3.

> **Built 2026-08-21 — 250 unit tests pass, up from 219.** Step 0's measurement
> is in [`MOOD-YIELD.md`](./MOOD-YIELD.md); what implementation found on top of
> it is recorded in `ROADMAP.md` Phase 14. The plan below is the design as
> shipped.

---

## 1. What this phase is for

Phase 13 built something that answers *"how much would this user like this
specific title?"*. It cannot answer *"what should we show them?"*, because
nothing produces **candidates**.

Phase 14 produces two things, which are easy to conflate and are not the same:

| | **The pool** | **A mood** |
|---|---|---|
| What it is | ~1000–1500 unwatched titles, cached on device | A word the user taps: `crime`, `dark`, `horror` |
| What it answers | "What is there to recommend at all?" | "Which slice do you want right now?" |
| Job in the pipeline | The set the engine sweeps | **Filters** the set before ranking |
| Refresh | Weekly TTL | Never — it is a definition, not data |

**Why a local pool at all, when Phase 12 made the catalog live.** Prediction is
not search. Ranking recommendations means scoring *every* candidate against the
taste profile and sorting — a full pass over the candidate set. There is no TMDB
endpoint for "score these against my local model", and re-fetching a thousand
titles on every mood tap would be slow and abusive to the API. The pool is the
set that full pass runs over, and it is cached so the pass is instant and so
Discover works with the network off (Part II design constraint 5).

**Why moods, when the engine already knows the user likes horror.** The taste
profile knows *who the user is*; it does not know *what they want tonight*.
Without a mood, Discover returns the same list every time it opens — a static
personal leaderboard rather than a browsing surface. Mood and taste are two jobs
over the same TMDB metadata: one queries it, one models it.

---

## 2. Two changes to the roadmap's acceptance criteria

### 2.1 Pool size is an output, not a target

The original criterion was *"cached pool reaches ~1200 distinct titles"*. It is
dropped, because it is neither necessary nor sufficient for the criterion that
actually matters — **≥ 30 eligible candidates per (mood, type)** — and because
it invites the wrong implementation.

The wrong implementation is: sweep the global popularity head until you have
1200 titles, then filter by mood. That fails on the measured data. The
popularity head is blockbuster-shaped — Action 42.5%, Adventure 40.8%, but
Romance **9.5%**, Horror 12.8%, Crime 13.8% — so narrow moods scrape a thin
slice of it, and the situation is worse for television, where Drama alone is
62.3%.

The right implementation is what roadmap step 3 already says: **page each mood's
own query.** `/discover/movie?with_genres=10749` returns 60 romance films in
three pages regardless of what is globally popular. Once the pool is built this
way, two things follow:

- **Per-mood coverage is guaranteed by construction.** You stop paging a mood
  when it clears its bar.
- **Query overlap costs storage, never coverage.** Fetching 300 `dark` and 300
  `thriller` titles that overlap heavily yields a union well under 600 — but it
  still yields 300 of each. Deduplication saves disk; it cannot starve a mood.

So the pool's size is whatever the deduplicated union comes to. ~1200 survives
only as a **budget** for cache footprint and refresh cost. Asymmetric pools per
type are expected, not a smell: the two genre vocabularies are shaped
differently, so they need different depths to clear the same bar.

> Worth being precise, because an earlier framing of this got it wrong: the
> "9.5% of 600 films is 57 romance titles" arithmetic only holds under *global*
> popularity sampling. Under per-mood paging, 9.5% describes how skewed the
> union will be — not what any individual mood can reach.

### 2.2 Yield is measured after exclusions, against a realistic library

This is the version of the overlap concern that actually bites, and it is not in
the roadmap's original text.

Overlap is harmless for coverage on an empty library. It is **not** harmless for
a real one, because **exclusions are correlated across moods**. `dark`,
`thriller`, and `mindBending` resolve to largely the same popular titles, so a
user who has watched and ranked the top 40 thrillers depletes all three
simultaneously. A mood that comfortably clears 30 against a fresh install can be
near-empty for precisely the user most likely to open Discover — someone with a
large, opinionated library.

So the test fixture is a realistic watched library, and moods that overlap
heavily need deeper paging than their standalone counts suggest.

---

## 3. Measure before fixing the taxonomy

Roadmap Phase 12 step 9 is the precedent: measure the data before designing
against it, and write the result down. The same applies here, and there is a
specific gap to close.

`FEATURE-SPACE.md` establishes that **84.3% of TV series carry ≥ 5 keywords**.
That is *keyword coverage*, and it is not the statistic this phase needs.
The statistic this phase needs is **per-mood yield**: how many titles carry a
keyword that a *specific* mood is defined by. Open question 12 flags exactly this
gap — "coverage is not the same as usefulness."

It matters because of how the moods split by type. TMDB's TV vocabulary has no
Thriller, no Horror, and no Romance, so of the ten starting moods, **seven have
no TV genre to stand on** and must be carried by keywords alone:

| Mood | Movie basis | TV basis |
|---|---|---|
| `crime` | genre Crime (13.8%) | genre Crime (25.8%) |
| `comedy` | genre Comedy (22.5%) | genre Comedy (33.2%) |
| `horror` | genre Horror (12.8%) | **keywords only** |
| `thriller` | genre Thriller (26.8%) | **keywords + Mystery** |
| `romance` | genre Romance (9.5%) | **keywords only** |
| `dark`, `mindBending`, `feelGood`, `trueStory`, `epic` | **keywords** | **keywords only** |

**Step 0 ran 2026-08-21** and produced [`MOOD-YIELD.md`](./MOOD-YIELD.md) — 296 API
calls, script-generated by `scripts/measure_mood_yield.py`. It is a separate
script and a separate document deliberately: re-running the Phase 12 sweep to
obtain Phase 14 numbers would cost 842 calls and would rewrite measurements
other phases already cite.

### What it found

**No mood is starved. The risk this phase was organised around did not
materialise.** Every one of the twenty (mood, type) pairs clears the ≥ 30 bar
with room to spare. The two thinnest are `trueStory`/tv at **94** catalogue
titles and `mindBending`/tv at **134**; the widest is `comedy`/movie at 4048.
Keyword-only TV moods are viable, and the reason is visible in the data: the
`thriller` keyword returns 7 films but **132 series**, and `horror` returns 58
films but **127 series**. Because TMDB's TV vocabulary lacks those *genres*,
taggers reach for the keyword instead — so the substitution strategy is not a
workaround, it is how the TV catalogue is actually annotated.

**The real finding was dead keywords: 7 of the 32 candidates were unusable.**
Not narrow — dead, at ≤ 5 titles across both types:

| Retired | Volume (movie / tv) | Replaced by |
|---|---|---|
| `feel good`, `feel-good` | 0 / 0 | `small town` (196 / 58) |
| `heartwarming` | 2 / 1 | — |
| `alternate reality` | 0 / 0 | `parallel world` (25 / 33) |
| `mind bending` | 0 / 0 | — |
| `epic` | 3 / 1 | genre basis alone |
| `dream` | 3 / 1 | `time loop` (28 / 9) |
| `romantic comedy` | 1 / 0 | `romcom` (139 / 99) |
| `historical event` | 5 / 3 | — |
| `based on a true story` | duplicate of `based on true story` (both id 9672) | — |

The pattern is worth carrying forward: **TMDB keyword ids above ~300000 are
recently-minted tags almost nobody has applied.** `feel good` (379696),
`romantic comedy` (380334), `epic` (377433), `mind bending` (362567),
`wholesome` (335803) are all at or near zero, while low-id tags — `love triangle`
(128), `nihilism` (1541), `vampire` (3133), `time travel` (4379) — carry real
volume. The exceptions are TV-substitution tags like `thriller` (316362) and
`horror` (315058), which are recent *and* heavily used precisely because the
genre does not exist for TV. **A mood resting on an intuitive-sounding tag is
resting on nothing until its volume is checked**, and the most on-the-nose
keyword for a mood is often the deadest — three moods named themselves after a
tag that does not exist in practice.

After pruning, every mood improved or held: `feelGood`/movie 567 → **747**,
`mindBending`/movie 223 → **239**, `romance`/tv 465 → **487**. The shipping
definitions are pinned in `MOODS` in the script, with the rejects and their
volumes recorded in `RETIRED` so a later session does not re-propose them.

**Overlap is far lower than argued, which weakens §2.2.** The correlated-exclusion
concern was real but small: the highest Jaccard between any two mood pools is
**0.18** (`crime` ∩ `thriller`, 31 shared titles), and most pairs sit below 0.10.
Simulating watched libraries drawn from the popularity head, the worst
post-exclusion survival at 100 watched titles is `comedy`/tv dropping 100 → 68.
Nothing approaches the bar. The criterion stays as written — measuring against a
realistic library costs nothing and is the honest formulation — but it is no
longer a live risk, and Phase 14 should not spend design effort on it.

**Pool size lands where the budget assumed.** Paging 5 pages per mood-query
yields **804 distinct films and 795 distinct series** — ~1600 total, with dedupe
saving 25–27% against the sum of the mood pools. The ~1200 budget was the right
order of magnitude. It remains an output.

### One API constraint that shapes the builder

Within a single `/discover` parameter, `|` is OR and `,` is AND — but **two
different parameters are AND-ed together**. `with_genres=27&with_keywords=9714`
means "horror AND supernatural", never "horror OR supernatural". So a mood with
both a genre basis and a keyword basis — `thriller`/tv and `epic`, in the
shipping set — needs **two queries unioned client-side**. `CandidatePoolBuilder`
must page per *query component*, not per mood. This is not documented in the
roadmap and is easy to get silently wrong: the AND form returns a plausible
non-empty result, just a much smaller and differently-shaped one.

---

## 4. What the code already gives us

| Thing | Where | State |
|---|---|---|
| TTL disk cache in Application Support | `Services/CatalogCache.swift` | Done. 1-week `defaultTTL`, `Hit.isStale`, `nil` directory disables it for tests. |
| Cache key namespace | `CatalogCacheKey` | Has `popular(type:page:)`. **Needs mood-scoped keys.** |
| Genre id → canonical name | `Services/TMDBGenreVocabulary.swift` | Done, both vocabularies reconciled. |
| Pool paging primitive | `MediaService.popularTitles(type:page:)` | Done, with a default returning `[]` so search-only test stubs compile. |
| Discover endpoint | `TMDBEndpoint.discover(type:page:)` | **Popularity sweep only** — carries `sort_by`, `vote_count.gte`, `include_adult`. No `with_genres`, no `with_keywords`. |
| Keyword id resolution | — | **Missing.** `/search/keyword` has no endpoint. |

### Two gaps worth naming

**`TMDBEndpoint.discover` cannot express a mood.** It hardcodes a plain
popularity sweep. It needs to take a query descriptor carrying `with_genres`
and `with_keywords`. The existing vote floor logic (300 for film, 100 for TV, on
the stated grounds that television accumulates far fewer votes) is kept as-is.

**`MediaService` is the wrong protocol to widen.** Adding a mood-shaped method
to it would force it on the seven search-only test stubs, and moods are not
something every catalog has an opinion about. `FeatureProvider` set the
precedent with `FeatureSource`: a narrow protocol, conformed by
`TMDBMediaService` in one line, testable against a stub that implements nothing
else. Phase 14 does the same with `CandidateSource`.

---

## 5. Design

### 5.1 `Models/Mood.swift`

```swift
struct MoodQuery: Sendable, Equatable {
    var genreIds: [Int]        // OR-ed via `with_genres`
    var keywordIds: [Int]      // OR-ed via `with_keywords`
    var minimumVotes: Int?     // nil → the endpoint's per-type default
}

enum Mood: String, CaseIterable, Identifiable, Sendable {
    case crime, thriller, dark, horror, romance
    case comedy, mindBending, feelGood, trueStory, epic

    var displayName: String { … }
    var symbolName: String { … }           // SF Symbol, per SPEC's UX rules

    /// Per-type, because TMDB's TV vocabulary has no Thriller, Horror or
    /// Romance. A mood that returns nothing for one type is a broken feature,
    /// not a sparse one.
    func query(for type: MediaType) -> MoodQuery

    /// How well a candidate matches, `0...1`.
    ///
    /// v1 returns 1.0 for a pool member and 0.0 otherwise — moods are a hard
    /// filter, which is far easier to validate. The signature is a `Double`
    /// rather than a `Bool` so grading later is a function body rather than a
    /// refactor through `Recommendation`, `RecommendationViewModel` and
    /// `DiscoverView`. See §6.3 for what has to be true before grading is safe.
    func relevance(for candidate: CandidateFeatures) -> Double
}
```

**Keyword ids are resolved once and cached.** `/search/keyword?query=neo-noir`
returns an id; the mood definitions store ids, not strings, because a keyword
name is not stable and a string match against `keywords` would be a different
and worse query. Resolution is a build-time-ish concern with a long TTL — a
resolution failure degrades a mood to its genre basis rather than failing it.

### 5.2 `Services/CandidateSource.swift`

```swift
protocol CandidateSource: Sendable {
    func discover(type: MediaType, query: MoodQuery, page: Int) async throws -> [MediaItem]
    func resolveKeywordId(_ name: String) async -> Int?
}

extension TMDBMediaService: CandidateSource {}
```

### 5.3 `Services/CandidatePoolBuilder.swift`

```swift
actor CandidatePoolBuilder {
    /// Pages each (mood, type) until it clears `targetPerMood`, or until
    /// `maxPagesPerMood` is spent. Returns the deduplicated union.
    func build(moods: [Mood], types: [MediaType]) async -> CandidatePool

    /// Serves cache immediately; refreshes behind the caller when stale.
    func pool() async -> CandidatePool
}

struct CandidatePool: Codable, Sendable {
    let titles: [PooledTitle]                 // deduped by externalId
    let moodMembership: [String: Set<String>] // mood.rawValue → externalIds
    let builtAt: Date
}
```

Four properties this has to have:

1. **Dedupe by `externalId`**, which Phase 12a made unambiguous
   (`tmdb:movie:27205`). Membership is stored as id sets per mood, so a title in
   four moods is stored once and listed four times — which is the shape that
   makes overlap cost storage rather than coverage.
2. **Never block a mood tap on a rebuild.** Serve stale, refresh behind it.
   A cold pool is the only case that waits, and it gets a loading state.
3. **Off the main thread.** An `actor`, and `MediaItem` construction stays at
   the boundary — the same discipline `FeatureProvider` uses, for the same
   reason (`@Model` is not `Sendable`).
4. **Bounded.** `maxPagesPerMood` caps a mood that can never clear its bar, and
   **logs what it dropped**. A silent cap reads as "covered everything" when it
   did not.

### 5.4 Stopping rule

Page a `(mood, type)` until **eligible** count ≥ `targetPerMood` (30) with
headroom, not until raw count ≥ 30. Eligible means: not watched, not dismissed
(Phase 17), and de-duplicated. Headroom exists because the pool is built once a
week and the user keeps watching things during it — a pool that exactly clears
30 on build day is under 30 by Wednesday.

---

## 6. Risks and decisions

### 6.1 ~~A keyword-only TV mood may be undefinable~~ — measured, and it is not

Retired by §3. The predicted failures — `feelGood` and `mindBending` on TV —
came in at 332 and 134 catalogue titles, comfortably clear. What the measurement
found instead was a different failure one level down: the moods were fine, but
seven of the *keywords* defining them were dead tags. That is a better problem
to have found in a script than in a UI, and it is the argument for E1 in
miniature.

The ≥30 test still ships and still fails CI, because the risk it guards is a
*future* mood added without measurement, and TMDB's tag volumes drift.

### 6.2 The vote floor interacts with narrow moods

`vote_count.gte` = 300 for film exists to keep junk out of a popularity sort.
For a broad mood that is free. For a narrow one it may be the binding
constraint — there are far fewer romance films with 300+ votes than action
films. `MoodQuery.minimumVotes` exists so a starved mood can lower its own
floor rather than forcing a global loosening that would degrade every other
mood. Any such override is recorded in `FEATURE-SPACE.md` alongside the yield
that motivated it.

### 6.3 Graded moods are architected for, deliberately not built

`relevance(for:) -> Double` returning 1.0/0.0 keeps the door open. Before
walking through it, one thing must be true, and it now is:

**Ranking must apply relevance to the taste *lift*, not to the predicted
value.** `predicted.value * moodWeight` — the roadmap's original Phase 15 step 4
— scales the baseline, which is ~90% of the number and identical for every
candidate of a type. On the Phase 13 fixture (`baseline = 6.045`):

| | Taste lift | `moodWeight` | `value * weight` | `baseline + lift * weight` |
|---|---:|---:|---:|---:|
| A | +0.70 | 0.9 | 6.07 | **6.68** |
| B | +0.20 | 1.0 | **6.25** | 6.25 |

B wins under the original formula despite fitting the user's taste 3.5× better,
because a 0.1 relevance difference was multiplied against six points of
uninformative baseline. **Relevance does not merely contribute — it drowns taste
out.**

The bug is invisible while relevance is binary and activates the moment it is
graded. Fixed in `ROADMAP.md` Phase 15 step 4 now, while it is still prose.

### 6.4 Decisions needed

| # | Decision | Recommendation |
|---|---|---|
| **E1** | Run §3's yield measurement before or during the phase? | **Settled — ran 2026-08-21.** See §3. It found seven dead keywords the taxonomy was resting on, which is exactly the class of thing that would have shipped as "this mood feels empty". |
| **E2** | What happens to a mood with no viable TV definition? | **Moot — there is no such mood.** All ten support both types. The contingency (movie-only, chip hidden for TV) is unused; keep it in mind only if a mood is added later. |
| **E3** | Is `targetPerMood = 30` right? | Keep 30 as the floor but page to ~45 for headroom against a week of watching. |
| **E4** | Does the pool store `MediaItem`s or a slimmer record? | A slimmer `PooledTitle`. `MediaItem` is a `@Model`; the pool is disposable cache and must not touch the store — the same reason Phase 12 kept the cache out of SwiftData. |

---

## 7. Build order

1. ~~**Measure per-mood yield** and decide the taxonomy from the output.~~
   **Done 2026-08-21** — `scripts/measure_mood_yield.py`, `docs/MOOD-YIELD.md`.
2. `Models/Mood.swift` — port the ten definitions verbatim from `MOODS` in
   `scripts/measure_mood_yield.py`, which now holds the measured, pruned
   taxonomy. `relevance` binary. **Keyword ids are already known** (they are in
   the report), so the resolver in step 4 is a refresh mechanism rather than a
   cold-start dependency.
3. `TMDBEndpoint.discover(type:query:page:)` — `with_genres`, `with_keywords`,
   overridable vote floor. Keep the existing per-type defaults.
4. `TMDBEndpoint.searchKeyword(_:)` + `CatalogCacheKey.keyword(_:)` + the
   resolver, with genre-basis fallback on failure.
5. `Services/CandidateSource.swift`; conform `TMDBMediaService`; give
   `MockMediaService` a real implementation so the offline path is thinner, not
   broken — the pattern Phase 12 used for `popularTitles`.
6. `Services/CandidatePoolBuilder.swift` — paging, dedupe, membership sets, TTL,
   serve-stale-refresh-behind, bounded with logging.
7. `WatchRankTests/MoodTests.swift` — every mood resolves to a non-empty query
   for both types; the ≥30 eligible test against a **realistic watched library**
   fixture and recorded page fixtures.
8. `WatchRankTests/CandidatePoolBuilderTests.swift` — dedupe across overlapping
   moods; membership survives a round trip; TTL staleness; a stale pool is
   served rather than awaited; the page cap logs what it dropped.
9. Update `ROADMAP.md` Phase 14 → ✅ with a findings block, and annotate open
   questions 6 and 12 with what the yield measurement settled.

### Definition of done

- Every mood clears ≥ 30 eligible candidates for every type it claims to
  support, against a realistic library — or is explicitly movie-only.
- Pool survives relaunch; Discover-relevant paths work with the network off.
- No test touches the network.
- Per-mood yield numbers are in `FEATURE-SPACE.md`, script-generated.
- No schema change, so **no simulator wipe** — Part II's budget of two total
  (Phase 12, Phase 17) still holds.
