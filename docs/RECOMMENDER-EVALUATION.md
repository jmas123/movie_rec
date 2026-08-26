# Recommender evaluation

**Written 2026-08-26.** This is the measurement that decided what
`HybridRecommendationEngine` does. Two designs that looked reasonable were
deleted because of it, and every constant that survived is here with the number
that justifies it.

Re-run it with `scripts/eval/run.sh` (see [§7](#7-reproducing-it)).

## 1. What is being measured

Whether the recommender can order titles a person has not seen the way that
person would order them after seeing them.

That is a ranking question, so the headline metric is **Spearman ρ** between the
predicted score and the user's own rating of held-out titles, computed per user
and averaged across users. Three others are reported alongside, because ρ over a
whole held-out set is not the thing the Discover screen shows:

| Metric | What it answers |
|---|---|
| **Spearman ρ** | Is the whole ordering right? |
| **NDCG@10** | Is the *top* of the list right — the only part a user reads? |
| **Precision@10** | What share of the top ten did the user actually rate 4★+? |
| **MAE** | How far off is the displayed 0–10 number? |

## 2. The data

Real ratings, real metadata, no synthetic taste.

- **MovieLens `ml-latest-small`** — 610 people, 100,836 ratings. Every user's
  ratings are their own, so the target is a real preference ordering rather than
  one generated from a model of taste (which would only ever confirm whichever
  candidate model resembled the generator).
- **TMDB** — the 1,996 most-rated films in that dataset, fetched through the
  *same* `/movie/{id}?append_to_response=credits,keywords` request the app uses,
  and passed through the app's own `TMDBDetailDTO.features(type:vocabulary:)`.
  The evaluation therefore sees the production feature key space, not a
  reconstruction of it.
- **478 users** clear the ≥ 30-rated-titles floor. Median library: 93 titles.

Star ratings become Binged buckets by the obvious reading of a five-star scale —
4★+ is *Liked it*, 3★–3.5★ is *It was fine*, ≤ 2.5★ is *Didn't like it* — and
within a bucket the order is by stars, ties broken deterministically. Scores come
from `RankingEngine.scores(count:range:)`, so the library the model trains on is
scored exactly as the app would score it.

A quarter of each user's library is held out. The model sees the rest.

## 3. What was under test

The harness compiles **the app's own engines** (`RecommendationEngine`,
`SentimentRecommendationEngine`, `HybridRecommendationEngine`) into a command-line
binary — it does not reimplement them. As a guard against the sweep and the app
drifting apart, every run also calls `HybridRecommendationEngine.predict` directly
and asserts it agrees with the swept recombination to 1e-9. **Parity failures: 0**
in every run reported here — so the `engine` row in the harness output is the
shipping model, not a description of it.

## 4. Results

478 users × 3 independent held-out splits (1,434 user-splits). The splits are
*confirmation* splits: the sweep chose the finalists on a different split, so
these numbers are not the ones the choice was made on.

| Model | ρ | NDCG@10 | P@10 | MAE |
|---|---|---|---|---|
| Always the modal band (null) | — | 0.570 | 0.571 | 2.083 |
| TMDB crowd score alone | 0.328 | 0.717 | 0.684 | 1.907 |
| **Content model — v1, shipped** | **0.252** | **0.701** | **0.675** | **1.897** |
| **Hybrid with semantic layer — v2** | **0.287** | **0.711** | **0.682** | **1.893** |
| Content + fixed crowd weight 0.35 | 0.382 | 0.750 | 0.709 | 1.851 |
| **Final: sentiment + content residual + learned crowd weight** | **0.389** | **0.755** | **0.713** | **1.829** |

Final model against the shipped v2 hybrid, paired per user-split:

| | Δ | 95% CI | direction |
|---|---|---|---|
| Spearman ρ | **+0.102** | +0.092 … +0.112 | better for 74% of user-splits |
| NDCG@10 | +0.044 | +0.039 … +0.050 | better for 66% |
| Precision@10 | +0.032 | +0.027 … +0.037 | worse for 12%, tied for 55% |
| MAE | **−0.064** | −0.072 … −0.055 | lower (better) for 76% |

## 5. The three findings that changed the code

### 5.1 The semantic layer made the model worse — delete it

The v2 hybrid learned position inside a sentiment band from similarity between
TMDB overviews (averaged `NLEmbedding` word vectors, k-nearest neighbours). It
does not help. It actively costs accuracy, at every setting tried:

| Semantic weight (everything else fixed) | 0 | 0.25 | 0.5 | 1.0 |
|---|---|---|---|---|
| ρ | 0.393 | 0.392 | 0.389 | 0.372 |

Every knob agreed. Widening the neighbourhood (k 12 → 50), raising the shrinkage
(3 → 12) and raising the similarity floor (0.5 → 0.7) all *improved* results —
all three weaken the semantic contribution. Pushing the gain up (1.5, 2.0, 3.0)
degraded it monotonically: ρ 0.238, 0.204, 0.155.

It also failed on its own stated ground. The layer existed to order titles
*inside* the Liked bucket; measured there, ρ inside Liked was **0.137** for the
content model and **0.082** with the semantic layer.

Deleted: `SemanticRecommendationEngine.swift`, `SemanticTasteProfile.swift`, and
the semantic term in the hybrid. An averaged word vector over a 40-word marketing
synopsis is a weak description of a film, and it was displacing a signal that
worked.

### 5.2 The crowd score was weighted far too low

At 0.10 the crowd term is almost decorative. The best *fixed* weight is around
0.30–0.35, and the curve is flat across 0.25–0.40:

| Fixed crowd weight | 0.15 | 0.20 | 0.25 | 0.30 | 0.35 | 0.40 | 0.50 | 0.60 |
|---|---|---|---|---|---|---|---|---|
| ρ | 0.373 | 0.385 | 0.392 | **0.396** | 0.393 | 0.391 | 0.383 | 0.372 |

Worth stating plainly: the crowd score *on its own* (ρ 0.328) beat both shipped
personal models. That is not an argument for shipping a popularity list — the
combination beats either part — but it is the reason the weight is no longer
small.

### 5.3 How much the crowd is worth is a per-user fact — so learn it

Agreement between a user's own ranking and TMDB's averages, measured on their
library alone, varies enormously: median ρ 0.45, but the 10th percentile is 0.16
and some users are negative. Scaling the crowd weight by that agreement beats the
best fixed weight (ρ +0.007, CI +0.001…+0.013; MAE −0.022, CI −0.027…−0.016), and
the gain is concentrated exactly where a fixed weight serves people worst:

| Users grouped by agreement with the crowd | low third | middle third | top third |
|---|---|---|---|
| No crowd term | 0.242 | 0.234 | 0.283 |
| Fixed weight 0.35 | 0.279 | 0.399 | 0.502 |
| **Learned weight** | **0.308** | **0.401** | **0.510** |

Negative agreement floors at zero rather than inverting: "you like what the crowd
dislikes" is not a claim a few dozen titles can support, and acting on it would
recommend by contrarianism.

Below `CrowdAgreement.minimumSample` (8 rated titles carrying a crowd score) the
estimate is noise, so a new library uses `fallbackCrowdWeight` — 0.35, the best
fixed weight measured.

The statistic itself is `CrowdAgreement`, shared with the Profile screen's
"Your ranking loosely tracks the crowd" sentence. One definition on purpose:
computed twice, the number the user is shown could drift away from the number the
model acts on.

### 5.4 What the final model is

```
personal = sentimentBandExpectation(features)
         + (contentModel(features) − contentBaseline(type))
crowdWeight = clamp(agreement(library), 0 … 1)
value    = (1 − crowdWeight) · personal + crowdWeight · shrunkCrowdScore
```

Which band and where inside it are separate questions, so they get separate
terms; adding the content model's *residual* rather than its value is what keeps
the band expectation from being counted twice. Keeping the sentiment layer over
the content model alone is worth little on ranking (ρ +0.000) but a real amount
on the displayed number (MAE −0.018, CI −0.022…−0.015), which is why it stays.

## 6. What this evaluation does not establish

Read these before quoting a number from §4 anywhere.

1. **No television.** MovieLens is films. Everything here is measured on movies;
   TV behaviour is inherited by construction, not verified.
2. **Stars are not comparisons.** Binged's within-bucket order comes from pairwise
   comparisons and is finer than a five-star scale can express. Bucket assignment
   here comes from thresholds, and within-bucket order from stars with ties broken
   arbitrarily, so within-bucket metrics are noisier than the app's real data
   would be — and the semantic layer's failure in §5.1 was measured against that
   noisier target. It failed by a wide enough margin, and consistently enough
   across knobs, that this is unlikely to be the explanation.
3. **Popular titles only.** The pool is the 2,000 most-rated films, which are
   heavily voted on TMDB, so the vote-count shrinkage (`crowdPriorVotes = 500`)
   is barely exercised. The sweep is indifferent to it between 0 and 1,000; it was
   kept at 500 on the argument the data cannot test — an 8.8 from twelve votes is
   not an 8.8 from twelve thousand.
4. **Both crowds are internet film raters.** MovieLens users and TMDB voters are
   different populations but similar kinds of people, which may flatter the crowd
   term relative to a genuinely niche taste. The learned weight in §5.3 is the
   hedge, and it is a per-user hedge.
5. **Random split, not a temporal one.** Taste drift is not measured.
6. **Libraries of ≥ 30 titles.** The cold-start case — the first handful of
   rankings — is not measured here at all.
7. **Selection over ~40 configurations.** The finalists were chosen on one split
   and confirmed on three others; §4 reports the confirmation splits only. The
   sweep numbers in §5 come from the selection split and are the weaker evidence.

## 7. Reproducing it

```bash
export TMDB_READ_TOKEN=...        # or leave it in Binged/Config/Secrets.xcconfig
scripts/eval/run.sh               # fetch fixture, build, evaluate, draw figures
```

It needs network access once (MovieLens and TMDB) and caches both under `.eval/`,
which is git-ignored and about 100 MB. The Swift harness is
`scripts/eval/recommender_eval.swift`, compiled against the app sources with
`swiftc`; the figures come from `scripts/eval/report.py`.

**One part is not reproducible from `main`:** §5.1's semantic runs were made
against `SemanticRecommendationEngine`, which that finding deleted. Reproducing
them means checking out the commit before the deletion. Everything else in §4 and
§5 comes out of the checked-in harness.
