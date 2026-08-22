# Mood yield

Measured 2026-08-22 by `scripts/measure_mood_yield.py` (5 pages per query, 296 API calls). Roadmap Phase 14, step 0.

This exists so the mood taxonomy is chosen from numbers rather than from how good a mood sounds. Re-run the script to refresh it; do not hand-edit the numbers.

Companion to [`FEATURE-SPACE.md`](./FEATURE-SPACE.md), which measures keyword *coverage*. This measures per-mood *yield*, which is the different and harder question — see roadmap open question 12.

**Target:** every supported (mood, type) pair must clear **30 eligible candidates** after exclusions. `pages` caps each query, so a `union` at the cap means the true catalogue yield is higher — what matters is whether the *post-exclusion* number clears the bar.

## Yield by mood and type

`genre` and `keyword` are the two query bases, unioned client-side because TMDB AND-s different `/discover` parameters. `catalogue` is TMDB's own `total_results` for the larger basis — the ceiling, not what we fetched.

| Mood | Type | basis | **catalogue** | cached | after 20 watched | after 50 | after 100 | verdict |
|---|---|---|---:|---:|---:|---:|---:|---|
| `crime` | movie | genre | **1774** | 100 | 97.0 | 93.0 | 86.0 | ok |
| `crime` | tv | genre | **786** | 100 | 95.0 | 86.0 | 71.0 | ok |
| `thriller` | movie | genre | **3015** | 100 | 95.0 | 87.0 | 74.0 | ok |
| `thriller` | tv | genre+keyword | **737** | 186 | 182.0 | 176.0 | 166.0 | ok |
| `dark` | movie | keyword | **543** | 100 | 98.0 | 94.0 | 88.0 | ok |
| `dark` | tv | keyword | **233** | 100 | 99.0 | 97.0 | 93.0 | ok |
| `horror` | movie | genre | **1691** | 100 | 98.0 | 94.0 | 88.0 | ok |
| `horror` | tv | keyword | **356** | 100 | 99.0 | 97.0 | 93.0 | ok |
| `romance` | movie | genre | **1862** | 100 | 99.0 | 96.0 | 92.0 | ok |
| `romance` | tv | keyword | **487** | 100 | 99.0 | 98.0 | 95.0 | ok |
| `comedy` | movie | genre | **4048** | 100 | 96.0 | 90.0 | 80.0 | ok |
| `comedy` | tv | genre | **1554** | 100 | 93.0 | 84.0 | 68.0 | ok |
| `mindBending` | movie | keyword | **239** | 100 | 99.0 | 98.0 | 96.0 | ok |
| `mindBending` | tv | keyword | **134** | 100 | 99.0 | 98.0 | 96.0 | ok |
| `feelGood` | movie | keyword | **747** | 100 | 98.0 | 95.0 | 91.0 | ok |
| `feelGood` | tv | keyword | **332** | 100 | 98.0 | 95.0 | 90.0 | ok |
| `trueStory` | movie | keyword | **799** | 100 | 99.0 | 98.0 | 96.0 | ok |
| `trueStory` | tv | keyword | **94** | 94 | 94.0 | 94.0 | 93.0 | ok |
| `epic` | movie | genre+keyword | **1811** | 168 | 161.0 | 151.0 | 133.0 | ok |
| `epic` | tv | genre+keyword | **1332** | 116 | 110.0 | 102.0 | 87.0 | ok |

**Read `catalogue`, not `cached`.** `catalogue` is TMDB's own `total_results` — exact, and the number that decides whether a mood is viable. `cached` is capped at `--pages × 20` and describes how deep this run paged, not how many titles exist; a mood sitting exactly at the cap has more titles behind it. The post-exclusion columns are computed over `cached`, so they answer "how much of the pool we would actually hold survives", which is the operative question for a fixed-size cache.

## Keyword volume

Titles above the vote floor carrying each keyword, from TMDB's `total_results`. A mood is only as strong as its best keyword; a keyword at 0 is a typo or a dead tag and should be replaced, not kept for completeness.

Rows marked `·` are **probe candidates** — measured but not currently wired into any mood, so a dead definition above has a costed replacement rather than only a diagnosis.

| Keyword | id | movie | tv |
|---|---:|---:|---:|
| `based on a true story` · | 9672 | 629 | 74 |
| `based on true story` | 9672 | 629 | 74 |
| `romance` | 9840 | 133 | 443 |
| `biography` | 5565 | 352 | 29 |
| `friendship` | 6054 | 351 | 215 |
| `love` · | 9673 | 271 | 52 |
| `dystopia` | 4565 | 265 | 55 |
| `coming of age` | 10683 | 248 | 106 |
| `dark comedy` | 10123 | 232 | 105 |
| `supernatural` | 6152 | 208 | 218 |
| `small town` | 1415 | 196 | 58 |
| `neo-noir` | 207268 | 173 | 30 |
| `time travel` | 4379 | 165 | 101 |
| `zombie` | 12377 | 141 | 31 |
| `romcom` | 9799 | 139 | 99 |
| `thriller` | 316362 | 7 | 132 |
| `horror` | 315058 | 58 | 127 |
| `vampire` | 3133 | 114 | 60 |
| `psychological thriller` | 12565 | 110 | 52 |
| `suspense` | 288394 | 17 | 80 |
| `love triangle` | 128 | 77 | 61 |
| `workplace comedy` | 210605 | 6 | 47 |
| `memory` | 10937 | 41 | 4 |
| `quest` | 207372 | 39 | 8 |
| `sword and sorcery` | 234213 | 36 | 19 |
| `parallel world` | 33465 | 25 | 33 |
| `time loop` | 10854 | 28 | 9 |
| `haunting` | 10224 | 27 | 6 |
| `nihilism` | 1541 | 21 | 1 |
| `dream sequence` · | 160840 | 20 | 0 |
| `nonlinear timeline` | 157171 | 19 | 3 |
| `alternate timeline` · | 186760 | 14 | 8 |
| `found family` · | 248927 | 7 | 13 |
| `parallel universe` · | 243230 | 8 | 12 |
| `multiverse` · | 336874 | 10 | 3 |
| `unreliable narrator` · | 174089 | 8 | 1 |
| `simulated reality` · | 3972 | 7 | 0 |
| `historical event` · | 159289 | 5 | 3 |
| `epic fantasy` · | 375250 | 4 | 0 |
| `sword and sandal` · | 317728 | 4 | 4 |
| `dream` · | 346773 | 3 | 1 |
| `epic` · | 377433 | 3 | 1 |
| `heartwarming` · | 319357 | 2 | 1 |
| `twist ending` · | 326438 | 2 | 0 |
| `uplifting` · | 334465 | 2 | 0 |
| `romantic comedy` · | 380334 | 1 | 0 |
| `alternate reality` · | 291176 | 0 | 0 |
| `based on mythology` · | **unresolved** | 0 | 0 |
| `feel good` · | 379696 | 0 | 0 |
| `feel-good` · | 379696 | 0 | 0 |
| `mind bending` · | 362567 | 0 | 0 |
| `wholesome` · | 335803 | 0 | 0 |

### Retired during this phase

Tried, measured, and rejected. Recorded so a later session does not re-propose them.

| Keyword | Why |
|---|---|
| `alternate reality` | 0 / 0 — `parallel world` (25 / 33) is the live tag in that space. |
| `based on a true story` | duplicate of `based on true story` (both id 9672). |
| `based on mythology` | unresolved — no such keyword. |
| `dream` | 3 / 1 — replaced by `time loop` (28 / 9). |
| `epic` | 3 / 1 — the mood's namesake keyword is dead; it stands on its genre basis. |
| `epic fantasy` | 4 / 0 — probed as a replacement, also dead. |
| `feel good` | 0 / 0 — a 2023-era tag nobody applies. `feel-good` is the same id 379696. |
| `heartwarming` | 2 / 1 — same story. `small town` (196 / 58) carries the mood instead. |
| `historical event` | 5 / 3 — `trueStory` stands on `based on true story` + `biography`. |
| `mind bending` | 0 / 0 — the mood's own name is not a usable tag. |
| `romantic comedy` | 1 / 0 — replaced by `romcom` (139 / 99). |
| `wholesome` | 0 / 0 — probed as a replacement, equally dead. |

## Mood overlap

Jaccard similarity between mood pools of the same type. Overlap costs storage rather than coverage — the pool is paged per mood, so a shared title is stored once and listed twice. What it *does* cost is **correlated exclusion**: watching the titles in one mood's head depletes every mood that shares them, which is why the post-exclusion columns above are the ones that matter.

### movie

| Pair | Jaccard | shared titles |
|---|---:|---:|
| `crime` ∩ `thriller` | 0.18 | 31 |
| `thriller` ∩ `dark` | 0.16 | 27 |
| `crime` ∩ `dark` | 0.14 | 24 |
| `thriller` ∩ `horror` | 0.14 | 24 |
| `comedy` ∩ `feelGood` | 0.09 | 17 |
| `comedy` ∩ `epic` | 0.09 | 21 |
| `romance` ∩ `feelGood` | 0.07 | 13 |
| `crime` ∩ `comedy` | 0.06 | 12 |
| `feelGood` ∩ `epic` | 0.06 | 14 |
| `romance` ∩ `comedy` | 0.05 | 10 |
| `dark` ∩ `mindBending` | 0.05 | 9 |
| `crime` ∩ `trueStory` | 0.04 | 8 |

### tv

| Pair | Jaccard | shared titles |
|---|---:|---:|
| `crime` ∩ `thriller` | 0.17 | 42 |
| `comedy` ∩ `epic` | 0.11 | 22 |
| `comedy` ∩ `feelGood` | 0.10 | 19 |
| `horror` ∩ `epic` | 0.10 | 20 |
| `thriller` ∩ `horror` | 0.10 | 25 |
| `horror` ∩ `romance` | 0.09 | 17 |
| `romance` ∩ `feelGood` | 0.08 | 15 |
| `mindBending` ∩ `epic` | 0.08 | 16 |
| `feelGood` ∩ `epic` | 0.08 | 16 |
| `dark` ∩ `horror` | 0.08 | 14 |
| `thriller` ∩ `dark` | 0.07 | 18 |
| `horror` ∩ `feelGood` | 0.06 | 12 |

## Resulting pool size

The deduplicated union of every mood pool — the number the old "~1200 distinct titles" criterion was trying to name. It is an **output**, not a target: coverage is guaranteed by per-mood paging, so this figure is a cache-footprint budget and nothing more.

| Type | Distinct titles | Sum of mood pools | Storage saved by dedupe |
|---|---:|---:|---:|
| movie | **804** | 1068 | 25% |
| tv | **795** | 1096 | 27% |

