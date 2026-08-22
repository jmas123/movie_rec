# Phase 13 — Prediction engine: technical plan

Written 2026-08-21, against the code as it stands after Phases 12 / 12a and the
measurements in [`FEATURE-SPACE.md`](./FEATURE-SPACE.md).

This plan **implements** [`ROADMAP.md` Phase 13](./ROADMAP.md#phase-13--prediction-engine-pure-logic-)
and **amends it in five places**. The amendments are in §3 and each one names the
measurement or the code that forced it. Everything else follows the roadmap.

It also amends **Phase 17** once — rank agreement replaces MAE as the primary
acceptance criterion (§7.1). That change is already written into `ROADMAP.md`.

> **Built 2026-08-21** — see `ROADMAP.md` Phase 13 for what implementation
> found, including the calibration formula in §4.5 that had to be corrected.
>
> **Revised 2026-08-21**, same day, after a design review. Three changes:
> the baseline range is bounded and is not the free parameter the usual
> harsh-rater framing assumes (§1); the muting in §3.4 is proved structural
> rather than tunable, which settles decision D1 as *ship it*; and Phase 17's
> evaluation moves to rank-first metrics (§7.1, §8.1).

---

## 1. What we are actually building

A content-based, single-user, cold-startable regressor with no training loop:

> Given a user's ranked library, estimate the score they *would* produce for an
> unwatched title, using only the overlap between that title's TMDB metadata and
> the metadata of what they have already ranked.

The estimator is a **shrunk residual mean per feature** — empirical-Bayes /
James-Stein in shape, the same family as a "Bayesian average" rating. It is not
a matrix factorisation (one user, nobody to factor against), not a gradient
model (no training data, no place to put weights), and not a nearest-neighbour
model (a 40-item library makes k-NN over 1200 candidates a coin flip).

### The target is a quantile, and that changes everything downstream

`RankingEngine.recomputeScores` gives item *i* of a bucket of *N*:

```
score[i] = upper - ((i + 0.5) / N) * (upper - lower)
```

Two facts fall out of that formula that the plan below depends on, both
verified numerically:

1. **A bucket's mean score is exactly its band midpoint, for every N.**
   Liked → 8.4, Fine → 5.05, Disliked → 1.65, at N = 1 and at N = 20 alike.
   Therefore `mean_t` — and so `baseline[t]` — is a **pure function of the
   user's sentiment mix for that type** and carries zero information about
   within-bucket ordering. The baseline is literally "how generous is this user
   with films / with television."

   **The baseline is therefore not a free parameter.** It is a convex
   combination of 8.4 / 5.05 / 1.65, so it can only ever land in
   **`[1.65, 8.4]`**. This app has no "naturally gives everything an 8" user in
   the sense a general 1–10 rating app does — it has an all-Liked user, sitting
   at exactly 8.4. Worth stating because the usual harsh-rater / generous-rater
   framing does not transfer here, and reasoning from it produces wrong
   intuitions about what the baseline term is doing.

   It has a consequence for who the engine serves well. A user who puts
   everything in Liked has residuals confined to that band's ±1.6 of positional
   spread, so **every feature effect they generate is small and their
   predictions cluster near 8.4**. Discrimination is best for users with
   sentiment diversity and worst for users who like everything — a user-mix
   artifact, not an algorithm defect, and Phase 17 should stratify its fixture
   libraries by sentiment mix rather than blame the model for it.

2. **Roughly 85% of a residual's magnitude is bucket membership, ~15% is
   position.** For a 20/12/8 film library, `baseline = 6.045`; the Liked band's
   midpoint sits +2.36 away, while position within Liked can move a score only
   ±1.6. So the engine is, in effect, **a shrunk sentiment classifier with an
   ordinal tiebreak**. Saying this out loud matters because it sets the ceiling:
   the feature effects are learning "does this feature co-occur with things you
   put in Liked", and the fine-grained ordering is a small correction on top.

3. **The null model is strong.** Always predicting `baseline[type]` gives
   MAE ≈ **2.39** on that same library. That is the number Phase 17 has to beat,
   and it is not a low bar — see the risk in §8.1.

### Non-stationary target (note for Phase 17)

Every insertion recomputes the whole bucket, so a title's stored score changes
without the user's opinion changing. Within a bucket the change is monotone, so
*ordering* is stable and prediction is unaffected — but Phase 17's MAE is
measured against a moving target, and matched prediction/actual pairs recorded
weeks apart are not strictly comparable. Record `predictedAt` (Phase 17 step 1
already does) and treat drift as noise, not signal.

---

## 2. What the code already gives us

| Thing | Where | State |
|---|---|---|
| Namespaced feature key space | `Models/Feature.swift` | Done. `family:id\|Display Name`, 10 families, parse-and-drop on garbage. |
| Features on the library | `MediaItem.features: [String]`, backfilled by `Services/FeatureProvider.swift` | Done. Library only, cached, one round trip per title. |
| Crowd score | `MediaItem.tmdbVoteAverage` | Done. Deliberately not a feature key. Phase 19's. |
| Purity precedent | `Services/RankingEngine.swift` | `import Foundation` only, stateless struct, comparator injected. Phase 13 mirrors this exactly. |
| Derived-value-type precedent | `ProfileStats` in `Views/Profile/ProfileView.swift` | `init(watched:)`, deterministic alphabetical tie-break. |
| Test idiom | `WatchRankTests/TestSupport.swift` | Swift Testing (`@Suite` / `@Test` / `#expect`), shared fixtures, `abs(a-b) < 0.0001` for floats. |

**One thing it does not give us**, and it is the finding with the largest blast
radius — see §3.1.

---

## 3. Five amendments to the roadmap's Phase 13 spec

### 3.1 Candidates arrive with **zero** features. The engine must be built for a two-stage pipeline.

`TMDBTitleDTO.makeMediaItem` (`Services/TMDBDTOs.swift:96`) constructs candidates
without passing `features:` at all, so every pool title has `features == []`.
That is not an oversight in the DTO — it is forced by the API. `/discover/movie`
and `/discover/tv` return `genre_ids`, `release_date`, `original_language`,
`popularity`, `vote_*` and nothing else: **no keywords, no credits, no runtime,
no `belongs_to_collection`.** `FeatureProvider`'s doc comment states the policy
plainly — features are fetched for the library only, because 1200 extra round
trips to enrich titles the user may never see is not a trade worth making.

Consequence if Phase 13 is built as written: `Σ effect[f] for f in F` over an
empty `F` is zero for every candidate, so **every prediction equals
`baseline[type]` and Discover ranks alphabetically by tie-break.** Phase 15's
acceptance criteria would all pass. The screen would be broken.

**The fix is retrieve-then-rerank**, the standard IR shape:

- **Stage 1 — retrieve.** Score all ~1200 candidates on the features derivable
  *without a network call*: `genre:` from `MediaItem.genres` (the vocabulary is
  already reconciled by `TMDBGenreVocabulary`) and `era:` from `MediaItem.year`.
  Keep the top ~60.
- **Stage 2 — rerank.** Fetch full features for those ~60 via the existing
  `FeatureProvider` / `CatalogCache` path, rescore, return the top 20.

Cost: ~60 requests on the first tap of a mood, ~0 once the cache is warm (the
same titles keep winning). That is affordable in a way that 1200 is not.

**What Phase 13 owes this design, and it is cheap:**

1. `predict` must be correct on a *partial* feature set — which the
   fixed-denominator aggregation in §4.3 already guarantees, by pulling a
   sparsely-described candidate toward the baseline rather than amplifying its
   few known features.
2. `PredictedScore` must report **which families were present**, so Stage 1 can
   tell the caller "this candidate has no credits or keywords yet" and Stage 2
   can be triggered on exactly the titles where reranking can change the answer.
3. A shared `RecommendationEngine.featureKeys(for: MediaItem) -> [String]` that
   returns `item.features` when non-empty and otherwise **derives**
   `genre:` + `era:` keys from `genres` / `year`. This is the Stage-1 feature
   extractor, and it doubles as the offline/legacy fallback: a library item
   whose backfill never ran (airplane mode, unmigrated IMDb id) currently
   contributes *no* feature evidence at all. `MockMediaService` already does
   exactly this derivation at its own boundary (`MockMediaService.swift:150`),
   so this is one implementation of a rule the codebase has already committed to.

Phases 14 and 15 own the pipeline; Phase 13 owns the three hooks. **Flag this
into the roadmap now** — it changes Phase 15 step 2 from one pass to two.

### 3.2 `Σ effect / |F|` must become a two-level, family-weighted average

The roadmap already flags this in prose ("a title with two genres and thirty
keywords should not be thirty-thirty-seconds keyword") but leaves the formula as
a flat mean. Make it concrete, because the flat mean has a second failure the
prose does not mention: with keywords capped at 10 and genres at ~3, a flat mean
is **77% keyword by construction** — the sparsest, least reliable family
outvoting the densest one three to one.

Two-level (§4.3): mean *within* each family, then a weighted sum *across*
families with fixed weights. This also makes the `/ |F|` denominator debate moot.

### 3.3 The confidence formula does not measure confidence

As specified:

```
evidence[c] = (Σ n_f for f in F) / |F|
```

`n_f` for `genre:Drama` in a 40-film library is ~7 (measured); for
`era:2010s` it is ~15–25; for `lang:en` it is ~35; for a keyword it is **1**
(measured, and flat at 1 up to library size 80). Averaging those is averaging
quantities with an order-of-magnitude spread in their natural scale, so the
result is driven by **which families happen to be present**, not by how much the
app knows. Worked example on a 40-film library:

| Candidate | Features | `evidence` | `confidence` |
|---|---|---|---|
| Fully enriched (3 genre, 10 kw, era, lang, dir, comp, 3 cast) | 20 | 4.3 | 0.54 |
| Same title, credits missing | 14 | 3.3 | 0.41 |
| Stage-1 (3 genre + era) | 4 | 9.0 | **1.00** |

The last row is the giveaway: the *least*-described candidate scores maximum
confidence, because `lang` and `era` have huge support and dominate the mean
when nothing else is there. **Confidence would be highest exactly where the app
knows least.**

Fix (§4.4): normalise support **per family** against a family-specific scale,
combine with the same weights used for prediction, and multiply by a **coverage**
term that penalises absent families. Then Stage-1 scoring is honestly reported
as low-confidence, and confidence can actually reach 1.

### 3.4 Predictions are muted by ~3 points relative to real scores, and Phase 16 will read as broken

Worked through on the 20/12/8 library above, with a genre the user loves
unanimously (all 8 entries in the top of Liked):

- `Σ residual = 26.52` over n = 8 → `genreEffect = 26.52 / (8 + 3) = **+2.41**`
- Candidate carries that genre plus two the user has never seen → within-family
  mean = `2.41 / 3 = 0.80`
- Genre family weight 0.30, no other family present → **predicted = 6.05 + 0.24 = 6.29**

So the app's single strongest recommendation displays **6.3** while the user's
own favourites display **9.9**. Under squared loss 6.3 is the *correct*
conditional expectation — but the user does not read it as an expectation, they
read it against their own scale, and "6.3" means "mediocre."

**The muting is structural, not a tuning artifact.** Because the family weights
sum to 1.0 and absent families contribute 0 (§4.3), the lift is a sub-convex
combination of the family effects:

```
value - baseline = Σ_fam w[fam] * familyEffect[fam]   ≤   max_fam familyEffect[fam]
```

**A prediction can never be lifted further than the single strongest family
effect, and any absent family drags it strictly below that.** No weight table
fixes this; it is what the two-level average is *for*. Sanity-checking against a
worked example built independently of this document: a candidate with *every*
family strongly positive — director +1.70, keywords +1.05, genre +0.85, cast
+0.45, era +0.10 — still lands at **+0.72**, or 7.52 against a 6.8 baseline. That
is a slam-dunk recommendation reading as a C+. The realistic ceiling on a
displayed prediction is roughly `baseline + 1`.

This is not a display bug to be papered over in Phase 16. It is a **scale
mismatch with a principled fix**: the user's score is a *quantile*, not a
measurement (§1). The right way to move a prediction onto a quantile scale is a
**quantile map**, and blending it by confidence keeps it honest:

```
displayValue = value + confidence * (quantileMapped - value)
```

where `quantileMapped` is the empirical score of the user's watched items of
that type at the candidate's percentile within the scored candidate set. At
confidence 0 the raw, muted, conservative number survives; at confidence 1 the
prediction speaks the user's own dialect. See §4.5 — it is a batch function,
still pure, ~20 lines.

**Recorded as decision D1 in §8, and the ceiling argument above settles it:
ship the calibration in Phase 13.** The original framing here — "defer it and
let Phase 16 lead with the qualitative band" — was written before the bound was
worked out. It does not survive it: deferring does not mean shipping a
conservative number, it means shipping a number whose maximum is `baseline + 1`
no matter how good the ranking underneath is. Phase 16 would then be gating a
display that cannot ever say what it needs to say.

### 3.5 Constants belong in an injectable struct, not bare `static let`s

Roadmap step 4 asks for "a single knob panel." Phase 17 step 5 asks for
per-user auto-tuning by minimising LOO error, and step 3 needs to sweep
`K_GENRE` in a test. Neither is possible against `static let`. A
`RecommendationTuning` **struct with a `static let standard`** satisfies both:
one place to look, and a value you can vary in a loop. This costs nothing now
and is a refactor of every call site later.

---

## 4. The algorithm, precisely

Notation: `t` = media type, `i` ranges over watched items, `f` over feature keys,
`fam` over families. All arithmetic `Double`.

### 4.1 Baselines (unchanged from the roadmap)

```
globalMean = mean(score_i)  over all watched items with a score   [= 5.0 if none]
baseline[t] = (n_t * mean_t + K_TYPE * globalMean) / (n_t + K_TYPE)   K_TYPE = 3
            = globalMean  when n_t = 0
```

`neutralScore = 5.0` is the value returned when the library is empty. It is the
midpoint of the 0–10 scale, not of any sentiment band.

### 4.2 Feature effects (shrinkage per family, plus a support floor)

```
residual_i   = score_i - baseline[type_i]
support[f]   = { i : f ∈ featureKeys(i) }            // a Set<UUID>
n_f          = |support[f]|
effect[f]    = (Σ residual_i for i ∈ support[f]) / (n_f + K[family(f)])
```

Included in the profile only if `n_f >= inclusionFloor[family(f)]`. Everything
below the floor is **absent**, not zero — it never enters a numerator and never
costs a denominator.

Effects are **pooled across media types** (roadmap open question 5), while
residuals are type-centred, so "I rate TV harshly" is not double-counted into
every TV genre. To let Phase 17 *test* the pooling decision without a schema
change, `TasteProfile` also carries `itemTypes: [UUID: MediaType]` — the
per-type split is then derivable from `featureSupport` at zero storage cost.

**Known limitation, state it and move on.** This is a naive per-feature mean, not
a regression. Features co-occur heavily (every Nolan film is also
`genre:Science Fiction`, also `composer:Hans Zimmer`), so `director:Nolan` and
`composer:Zimmer` are largely the same observation counted twice. Ridge
regression over the one-hot feature matrix is the principled fix, and is what
Phase 17 should reach for **only if** LOO says the naive estimator is losing to
the null. It is not the right v1.1 call: it needs a solver, it is O(features²)
where this is O(library × features), it degrades badly at n = 0, and — decisively
— it does not give Phase 19 a per-feature number it can put in a sentence. The
two-level averaging in §4.3 damps the double-counting enough for a ranking task.

### 4.3 Prediction (two-level, family-weighted)

```
F              = featureKeys(candidate)                  // §3.1: derived if empty
F_fam          = { f ∈ F : family(f) == fam }
familyEffect   = (Σ effect[f] for f ∈ F_fam, 0 for f not in profile) / |F_fam|
predicted      = baseline[t] + Σ_fam w[fam] * familyEffect[fam]
value          = clamp(predicted, 0.0 ... 10.0)
```

Three deliberate choices inside that:

- **Within-family denominator is `|F_fam|`, not the count found in the profile.**
  A candidate tagged `[Horror (+2.4), Comedy (unknown)]` gets `+1.2`, not
  `+2.4`. An unknown feature is evidence of nothing and should dilute.
- **Absent families contribute 0 against the full weight sum** — the denominator
  is `Σ_fam w[fam] = 1.0` always, never renormalised over present families. A
  sparsely-described candidate is therefore pulled toward its baseline. This is
  the Bayesian-correct prior ("no effect") and it is what makes Stage-1 scoring
  in §3.1 safe.
- **The cost of that choice, named:** it biases the top of the list toward
  metadata-rich titles, which correlates with popular / recent / Anglophone. The
  bias runs the same direction as the confidence gate, so the UI already hedges
  it — but expose the alternative as a tuning flag
  (`renormalizeOverPresentFamilies: Bool = false`) so Phase 17 can A/B it under
  LOO rather than argue about it. See risk §8.1.

### 4.4 Confidence (replaces the roadmap's formula — see §3.3)

```
familySupport[fam]     = mean(n_f for f ∈ F_fam)             // 0 for unknown f
familyConfidence[fam]  = min(1, familySupport[fam] / EVIDENCE_FULL[fam])

featureConfidence      = Σ_fam w[fam] * familyConfidence[fam]     // absent → 0
                                                                  // Σ w = 1.0
confidence             = featureConfidence * min(1, n_t / TYPE_EVIDENCE_FULL)
evidence               = Σ_fam w[fam] * familySupport[fam]        // reported raw
```

Because absent families contribute 0 to a denominator that is always 1.0, the
coverage penalty is built in rather than bolted on: the Stage-1 candidate in
§3.3's table now scores `0.30 * 1.0 + 0.05 * 1.0 = 0.35`, not 1.00.

`evidence` is retained on `PredictedScore` purely as a diagnostic. **Confidence
is a heuristic, not a calibrated probability**, and Phase 17 should prove or
disprove it the obvious way: bin LOO predictions by confidence decile and check
that MAE decreases monotonically. If it does not, confidence is decoration and
Phase 16 should not be gating on it. This is now a named acceptance criterion in
Phase 17 rather than a suggestion — see §7.1.

### 4.5 Calibration to the user's scale (decision D1 — required, §3.4)

> **Superseded 2026-08-21. The quantile map below was wrong and has been
> deleted from the code.** It mapped a candidate's percentile within its batch
> onto the user's score distribution, which handed the top of every mood's list
> the user's maximum score by arithmetic — 9.9 in every mood, regardless of the
> estimate behind it. Calibrating against a pool-wide reference instead does not
> fix it: quantile mapping assumes the candidates and the user's ratings
> describe the same population, and **the unwatched pool is by definition
> depleted of the user's favourites**, so the equivalence cannot hold.
>
> Replaced by a per-user affine calibration learned from leave-one-out error —
> `display = μ + s(raw − μ)`, `s` fitted from matched (predicted, actual) pairs,
> shrunk toward 1.0 and bounded. See `Models/RatingCalibration.swift` and the
> Phase 16 findings block in `ROADMAP.md`. The section below is kept for the
> reasoning it records, not as a specification.

```
func calibrate(_ scored: [PredictedScore], to profile: TasteProfile,
               type: MediaType) -> [PredictedScore]
```

Batch, pure, no new state. Sort by `value`; for each, take its percentile *p*
within the batch; look up the user's own watched scores for `type`, sorted, and
take the value at percentile *p*; then blend and clamp:

```
blend        = min(1, n_t / TYPE_EVIDENCE_FULL)        // profile-level, not per-candidate
displayValue = value + blend * (mapped - value)
```

> **Corrected during implementation.** This originally read
> `displayValue = value + confidence * (mapped - value)`, using each
> candidate's own confidence — and that **reorders the list**. A title with
> `value 7.0, confidence 0.9` overtakes one with `value 7.1, confidence 0.0`,
> which destroys the order-preserving property the entire decision rests on.
> The blend weight has to be constant across the batch to be monotone, and the
> type-evidence term is the right constant: how well the app knows this user's
> *scale* is a fact about the user, not about the candidate. Per-candidate
> `confidence` survives untouched on `PredictedScore` for Phase 16's display
> gate, which is what it was always for.

With a batch-constant blend the mapping is monotone by construction, so
**ordering is untouched** — this can be added or removed without changing which
titles Discover shows.

---

## 5. Constants

All in `RecommendationTuning`. Every number here is a **prior to be replaced by
Phase 17's LOO sweep**, not a measurement; the justification column says what it
is anchored to.

### Family weights `w` (sum = 1.00)

| Family | w | Why |
|---|---:|---|
| `genre` | 0.30 | Dense (median support 7 at n=40), reconciled vocabulary, the workhorse. |
| `keyword` | 0.24 | Sparse per key but ~10 per title, so the within-family mean is well-averaged. Carries tone, which genres cannot. |
| `director` | 0.10 | High precision when it fires; median ≥3-count is **0** below ~100 films, so it rarely fires. |
| `cast` | 0.09 | Densest credit family (3/title), but 50% nested inside directors — deliberately below `director` to avoid double-counting the same films. |
| `franchise` | 0.06 | Rare but near-deterministic when present. |
| `composer` | 0.05 | Repeats more than directors (8.2 vs 2.3 at 100 films) but is a weaker taste claim. |
| `era` | 0.05 | Confounded with the baseline — see §8.3. |
| `lang` | 0.05 | Real signal (a subtitle-tolerant user is a fact about them), very few distinct values. |
| `runtime` | 0.03 | Weak; mostly a proxy for format. |
| `network` | 0.03 | TV only, and "Netflix" is close to a synonym for "exists". |

### Shrinkage `K` — read as "support at which the estimate is taken at half face value"

| Family | K | Why |
|---|---:|---|
| `genre` | 3 | Roadmap's value, and the measurement backs it: median support 7 → 70% face value. |
| `keyword` | 1 | Roadmap's value. K=3 would leave a support-2 keyword at 40%, silencing the family while still costing denominator. |
| `director`, `composer`, `cast` | 2 | Sparse by construction; K=2 lets a twice-seen person speak at half weight. |
| `franchise` | 1 | Two films in a collection is a genuinely strong signal. |
| `era`, `runtime` | 8 | Near-universal, so support is large anyway; a high K guards against a lopsided library manufacturing an era effect. |
| `lang`, `network` | 4 | Middling density. |

### Inclusion floors — minimum support to enter the profile at all

| Family | Floor | Why |
|---|---:|---|
| `keyword` | **2** | Roadmap's rule. 66% of keywords appear on exactly one title; a support-1 keyword's "effect" is one film's residual and nothing else. |
| `cast` | **2** | Same argument — many-per-title, so support accumulates cheaply and a floor costs little. |
| everything else | 1 | One-per-title or dense families where 2 is either unattainable or automatic. |

Distinct from Phase 19's **display** floors, which are higher (≥3) and live in
this same struct so there is one panel, per roadmap step 4.

### Confidence scales

| Constant | Value |
|---|---:|
| `EVIDENCE_FULL[genre]` | 8 |
| `EVIDENCE_FULL[keyword]` | 3 |
| `EVIDENCE_FULL[director / composer / cast / franchise / network]` | 3 |
| `EVIDENCE_FULL[era / runtime / lang]` | 15 |
| `TYPE_EVIDENCE_FULL` | 10 |
| `K_TYPE` | 3 |
| `neutralScore` | 5.0 |

---

## 6. API surface, file by file

All four production files are `import Foundation` only. `TasteProfile`,
`PredictedScore`, `CandidateFeatures` and `RecommendationTuning` are `Sendable`
value types.

### `Models/RecommendationTuning.swift` *(new — not in the roadmap's file list)*

```swift
struct RecommendationTuning: Sendable {
    var typeShrinkage: Double                       // K_TYPE
    var typeEvidenceFull: Double
    var neutralScore: Double
    var weights: [Feature.Family: Double]           // Σ = 1.0
    var shrinkage: [Feature.Family: Double]         // K per family
    var inclusionFloor: [Feature.Family: Int]
    var evidenceFull: [Feature.Family: Double]
    var displayFloor: [Feature.Family: Int]         // Phase 19 parks here
    var renormalizeOverPresentFamilies: Bool        // §4.3, default false

    static let standard = RecommendationTuning(...)
}
```

Dictionary lookups fall back to a documented default so a **new
`Feature.Family` case cannot silently get weight 0** — the exact failure mode
`Feature.Family.carriesIdentity` is already written to avoid.

### `Models/TasteProfile.swift`

```swift
struct TasteProfile: Sendable {
    let globalMean: Double
    let baselinesByType: [MediaType: Double]
    let watchedCountsByType: [MediaType: Int]
    let featureEffects: [String: Double]
    let featureSupport: [String: Set<UUID>]
    let itemTypes: [UUID: MediaType]                // §4.2, for Phase 17
    let scoresByType: [MediaType: [Double]]         // sorted; §4.5 + Phase 19
    let tuning: RecommendationTuning

    var featureCounts: [String: Int] { featureSupport.mapValues(\.count) }
    var isEmpty: Bool { itemTypes.isEmpty }
    func baseline(for type: MediaType) -> Double
}
```

`featureCounts` is computed, not stored — the roadmap says the counts fall out
of the sets, so let them.

### `Models/PredictedScore.swift`

```swift
struct PredictedScore: Sendable {
    let value: Double                               // clamped 0...10
    let confidence: Double                          // 0...1
    let evidence: Double
    let familiesPresent: Set<Feature.Family>        // §3.1 hook 2
    let topContributingFeatures: [FeatureContribution]
    var displayValue: Double                        // == value until §4.5 runs
}

struct FeatureContribution: Sendable {
    let feature: Feature                            // not a String — §note
    let amount: Double                              // signed points of lift
}
```

**`Feature`, not `String`**, against the roadmap's `topContributingFeatures:
[String]`. `Feature` already exists, already round-trips, and already carries
`displayName` — Phase 16's "because you like slow-burn neo-noir" would otherwise
re-parse the key at the call site, which is the string surgery `Feature.swift`
was written to abolish. `amount` is the feature's **actual** contribution
(`w[fam] * effect[f] / |F_fam|`), so the numbers sum to the lift and can be
debugged. Ranked by `amount` descending, positive only, ties broken by
`feature.key` ascending — **determinism matters**, `featureEffects` is a
Dictionary and Phase 15 has an acceptance criterion about `Set` iteration order
leaking into output.

### `Models/CandidateFeatures.swift` *(new — not in the roadmap's file list)*

```swift
struct CandidateFeatures: Sendable, Hashable {
    let id: UUID
    let type: MediaType
    let keys: [String]

    init(_ item: MediaItem)      // uses RecommendationEngine.featureKeys(for:)
}
```

**Why this exists.** `MediaItem` is a SwiftData `@Model`; it is not `Sendable`
and must be touched on the actor that owns its context. If `predict` takes a
`MediaItem`, then scoring 1200 candidates is pinned to the main actor and Phase
18's "profile build + rank + diversity under 100 ms, off the main thread if not"
is unreachable without a refactor. Taking a value snapshot instead means
`buildProfile` runs once on the main actor and **all 1200 scorings can run
off-main**. Cheap now, structural later.

### `Services/RecommendationEngine.swift`

```swift
struct RecommendationEngine {
    var tuning: RecommendationTuning = .standard

    // Main actor: reads MediaItem.
    func buildProfile(from watched: [MediaItem]) -> TasteProfile

    // nonisolated, Sendable in and out. The hot path.
    func predict(_ candidate: CandidateFeatures, using profile: TasteProfile) -> PredictedScore

    // Convenience for tests and one-off call sites.
    func predict(_ item: MediaItem, using profile: TasteProfile) -> PredictedScore

    // §3.1 hook 3 — the Stage-1 extractor and the offline fallback.
    static func featureKeys(for item: MediaItem) -> [String]

    // §4.5, decision D1.
    func calibrate(_ scored: [PredictedScore], to profile: TasteProfile,
                   type: MediaType) -> [PredictedScore]
}
```

`buildProfile` filters to `watchedStatus == .watched` **and** `score != nil`
internally rather than trusting the caller — an item mid-comparison-session has
a provisional score (`MediaLibraryViewModel.markWatched` seats it at the bucket
midpoint before opening the session) and should not move a taste profile.

**No LOO API is needed.** `buildProfile(from: items.filter { $0.id != held })`
is O(n) per fold, so Phase 17's full sweep at n = 80 is 6,400 item-feature
passes — microseconds. Keep the surface small.

---

## 7. Test plan

`WatchRankTests/RecommendationEngineTests.swift` for prediction,
`WatchRankTests/TasteProfileTests.swift` for profile construction. Swift Testing,
store-free over hand-built `MediaItem`s, `abs(a - b) < 0.0001` for floats, new
shared fixtures added to `TestSupport.swift` per its own stated policy.

### Covering the roadmap's acceptance criteria

| Criterion | Test |
|---|---|
| Empty library → neutral midpoint, confidence 0, no NaN | `emptyLibrary…`, plus zero-member feature and empty-`F` candidate |
| Horror-loved / romance-hated fixture orders correctly, **with exact values** | `handBuiltFixtureMatchesArithmetic` — asserts the literal 6.29 from §3.4, so the whole pipeline is pinned, not just its sign |
| Shrinkage asserted directly, in the documented ratio | 1 item @ +2.0 → **0.5000**; 10 items @ +2.0 → **1.5385**; ratio 3.077 |
| Sparse keyword cannot outweigh a well-supported genre | Fixture drawn from `FEATURE-SPACE.md`: 10 support-1 keywords vs 1 support-7 genre |
| Predictions never escape `0...10` | Every watched item at a band boundary, both directions, under both aggregation modes. **The clamp turns out to be provably unreachable** — `lift <= max(score) - baseline` — so the test asserts the invariant rather than pretending the guard fires. |
| Movie and TV baselines independent | Harsh TV + generous film; assert `baseline[.movie]` unmoved when TV items are added |
| No `import SwiftData` / `SwiftUI` / `URLSession` | `grep` assertion over the source, same shape as the existing purity checks |

### Tests I would add beyond the roadmap

1. **Bucket mean is the band midpoint** (§1). `mean(bucket) == midpoint` at
   N = 1, 5, 20 for all three sentiments. Cheap, and it pins the fact the whole
   baseline argument rests on.
2. **Support-weighted effects sum to ~0 when `K_TYPE = 0`.** With type
   shrinkage off, residuals are exactly type-centred, so
   `Σ_f n_f * effect_f ≈ 0` up to per-family K scaling. Catches sign errors,
   baseline bugs, and "residual computed against the wrong type" in one
   assertion. Only expressible because tuning is injectable (§3.5).
3. **Keyword-flood test.** Two candidates, identical genres; one carries 30
   keywords of support 1. Assert the keyword family moves the prediction by at
   most `w[keyword]` points, i.e. that §3.2's two-level mean holds. This is the
   test that fails if someone "simplifies" back to a flat `/ |F|`.
4. **Missing-family conservatism.** A candidate with 3 genres and nothing else
   predicts strictly closer to baseline than the same 3 genres plus a
   well-supported director. Pins §4.3's fixed denominator.
5. **Confidence monotonicity and reachability.** Confidence is non-decreasing in
   support; a well-covered candidate on a 40-item library actually reaches
   > 0.8. This is the regression test for §3.3 — under the roadmap's formula it
   fails, which is the point.
6. **Stage-1 == Stage-2 when features are absent.** `featureKeys(for:)` on a
   pool candidate yields exactly its genre + era keys, and `predict` on that is
   the same as `predict` on an item whose `features` array holds those keys
   literally. Pins §3.1 hook 3.
7. **Determinism.** Same input must give a bit-identical profile, and
   `topContributingFeatures` must be **identical in order**, including a
   deliberate exact-tie fixture. Reversal-invariance is asserted only to float
   tolerance: `+=` over residuals is not associative, so a reversed library
   moves the last ulp. Demanding bit-equality across input orders would be
   demanding something floating point cannot give.
8. **Unknown family degrades, never crashes.** A `features` array containing
   `"quantum:42|Nonsense"` and `"garbage"` drops to zero features, not a trap —
   `Feature.init?(key:)` already returns `nil`; assert the engine honours it.
9. **Calibration is monotone.** `calibrate` never reorders a batch, and is the
   identity at `confidence == 0`. Monotonicity is what makes §7.1's rank metric
   measurable on either `value` or `displayValue`.
10. **A provisional mid-session item does not move the profile.** Uses the
    existing `driveSession(vm:steps:)` helper to reach the half-answered state.

### 7.1 What Phase 13 owes Phase 17's evaluation

Phase 13 ships no metrics — it ships the surface they are computed over. But the
metric choice was settled during this phase and is recorded here because it
changes what `predict` must guarantee.

**Rank agreement is Phase 17's primary gate, not MAE.** The reason is §1: a
stored score is a bucket quantile, so it moves whenever the bucket grows without
the user's opinion changing. MAE is measured against a drifting target;
Spearman ρ is invariant to exactly that drift. `ROADMAP.md` Phase 17 has been
amended — Spearman primary (ρ > 0.31 at n = 40, > 0.22 at n = 80), MAE against
**both** nulls secondary, Precision@10-over-Liked as a smoke test, and
confidence-decile monotonicity promoted from suggestion to criterion. NDCG@10
and hit rate are explicitly excluded until libraries exceed ~200 items.

Two obligations that lands on this phase, both already satisfied by the design
above but easy to lose in a refactor:

1. **`predict` must be a pure function of `(profile, candidate)`.** LOO rebuilds
   the profile n times; any hidden state or caching keyed on anything else makes
   the folds non-independent and quietly inflates the score.
2. **Ordering must be total and deterministic** (test 7). A rank correlation
   over a list with unstable ties is not reproducible, so the tie-break is part
   of the metric's validity, not just a nicety.

`buildProfile(from: items.filter { $0.id != held })` remains the whole LOO API —
no new surface, per §6.

### Performance sanity (a `@Test`, not an XCTest metric)

Build a profile over 100 items, score 1200 synthetic candidates, assert it
completes. Not a timing assertion — those are flaky in CI — but it makes Phase
18's budget observable now, and it forces the `CandidateFeatures` path to be
exercised at real scale before Phase 15 depends on it.

---

## 8. Risks and open decisions

### 8.1 The engine may not beat the null model (the real risk)

§1 puts the null MAE at ≈ 2.39 and §3.4 puts a strong genre effect's actual
contribution at ≈ +0.24 points. If the family weighting damps effects that
hard, LOO improvement will be in the second decimal place and **Phase 17's
headline acceptance criterion fails.**

That is not an argument for skipping the weighting — the alternatives are worse
(§3.2, §3.3). It is an argument for making the aggregation a **flag, not a
constant**, so Phase 17 can sweep `renormalizeOverPresentFamilies`, family
weights, and per-family K against real LOO error rather than relitigating this
document. Building that flag costs one `if` in §4.3. Not building it costs a
refactor at exactly the moment the project discovers it needs the answer.

Also worth knowing before Phase 17 runs: because ~85% of a residual is bucket
membership (§1), the honest comparison is against **two** nulls — always-baseline
(MAE ≈ 2.39) and always-predict-the-user's-modal-sentiment-midpoint. Beating
only the first is a weaker result than it looks.

**The metric change in §7.1 materially de-risks this.** Under an MAE-only gate,
the muting bound in §3.4 means the engine is trying to close a 2.39-point gap
with effects worth ~0.24 points, and it can be *directionally right about every
single title* while barely moving MAE. Spearman asks the question the product
actually cares about — is the top of the list better than the bottom — and it
is measurable at n = 40 where an MAE delta in the second decimal place is not.
This is not lowering the bar; it is pointing the bar at the claim Discover
makes. If ρ is also flat, the effects really are noise, and that is the honest
failure the phase is designed to surface.

### 8.2 Open question 13 (keyword support floor) gets sharper, not resolved

The floor of 2 discards the majority of a family whose median support is 1.
Phase 13 should **record the discard rate on the profile** — one `Int`, "keywords
seen but dropped below floor" — so Phase 17 is deciding from a number instead of
an argument. Zero cost, and it is the difference between the three resolutions
the roadmap lists.

### 8.3 `era` / `lang` / `runtime` are confounded with the baseline

If 70% of a library is 2010s, `era:2010s`'s residual is approximately the *mean*
residual, so it self-cancels — fine. But a mild real correlation (people rate
recent things they chose to watch more highly) gives every 2010s candidate the
same lift, flattening discrimination and biasing Discover toward new titles.
Mitigated here by high K (8) and low weight (0.05); the clean test is dropping
the family under LOO in Phase 17.

### 8.4 Decisions I need from you

| # | Decision | Recommendation |
|---|---|---|
| **D1** | Ship the §4.5 quantile calibration in Phase 13, or defer to 16/17? | **Settled: ship it**, behind `displayValue`. ~20 lines, provably order-preserving. Upgraded from "recommended" to required once the §3.4 ceiling was worked out: deferring does not ship a conservative number, it ships one that can never exceed `baseline + 1`. |
| **D2** | Two-stage retrieve-then-rerank (§3.1) — confirm it lands in Phases 14/15? | Confirm now and amend the roadmap. Phase 13 only owes the three hooks either way, but Phase 15 step 2 is currently written as a single pass. |
| **D3** | `topContributingFeatures` as `[FeatureContribution]` vs the roadmap's `[String]` | Contribution. Costs one small struct, saves string surgery in Phases 16 and 19. |
| **D4** | Pooled vs per-type feature effects (roadmap open question 5) | Keep pooled, as the roadmap says — but store `itemTypes` so Phase 17 can test the split without a schema change. |

---

## 9. Build order

Each step compiles and its tests pass before the next begins.

1. **`RecommendationTuning`** with `.standard` and the §5 tables. No logic.
   Test: weights sum to 1.0; every `Feature.Family` case resolves in every
   dictionary (a `CaseIterable` loop, so a new family fails CI rather than
   silently getting weight 0).
2. **`RecommendationEngine.featureKeys(for:)`** + `CandidateFeatures`. Test 6.
   Smallest useful unit and the thing §3.1 hangs on.
3. **`TasteProfile` + `buildProfile`.** Baselines, residuals, per-family
   shrinkage, inclusion floors, support sets, dropped-keyword counter.
   Tests 1, 2, 10 and the shrinkage-ratio criterion.
4. **`PredictedScore` + `predict`.** Two-level aggregation, clamping,
   contributions. Tests 3, 4, 7, 8 and the exact-value fixture.
5. **Confidence.** §4.4. Test 5 — write it first and watch it fail against the
   roadmap's formula, so §3.3 is demonstrated rather than asserted.
6. **Calibration** (D1, required — §3.4). Test 9, plus an assertion that
   `displayValue == value` when `confidence == 0`.
7. **Purity + scale checks.** The `grep` assertion and the 1200-candidate run.
8. **Update `ROADMAP.md`**: Phase 13 → ✅ with a findings block in the house
   style (the Phase 12 note is the template), the confidence-formula correction,
   the §3.1 amendment to Phase 15, and open questions 5, 7 and 13 annotated with
   what this phase pinned down. Phase 17's metric change is **already written
   in** — leave it alone.

### Definition of done

- Roadmap's seven acceptance criteria pass, with §7's ten additions.
- Whole existing suite still green (currently **171**; expect ~200).
- No test touches the network, no test needs a `ModelContainer` — the engine
  never sees SwiftData.
- No `!` in non-test code, per `CLAUDE.md`.
- No schema change, so **no simulator wipe this phase** — Part II's budget of
  two wipes total (Phase 12, Phase 17) is preserved.
