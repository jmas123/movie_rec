# TMDB feature space

Measured 2026-08-21 by `scripts/measure_feature_space.py` (400 titles per type, 842 API calls). Roadmap Phase 12, step 9.

This exists so Phase 13 can pick shrinkage constants from data rather than from intuition. Re-run the script to refresh it; do not hand-edit the numbers.

## Film

- Titles sampled: **400** (most popular first)
- Genres in TMDB's `movie` vocabulary: **19**
- Genres per title (median): **3.0**
- Keywords per title (median / mean): **17.0 / 17.7**
- Titles with ≥ 5 keywords: **97.8%**
  - popular half: 97.5%, tail half: 98.0%
- Distinct keywords seen: **1705**, of which **66.4%** appear on exactly one title

### Genre distribution

| Genre | Titles | Share |
|---|---:|---:|
| Action | 170 | 42.5% |
| Adventure | 163 | 40.8% |
| Science Fiction | 120 | 30.0% |
| Thriller | 107 | 26.8% |
| Drama | 96 | 24.0% |
| Comedy | 90 | 22.5% |
| Fantasy | 77 | 19.2% |
| Family | 70 | 17.5% |
| Animation | 67 | 16.8% |
| Crime | 55 | 13.8% |
| Horror | 51 | 12.8% |
| Romance | 38 | 9.5% |
| Mystery | 26 | 6.5% |
| War | 10 | 2.5% |
| History | 8 | 2.0% |
| Music | 4 | 1.0% |
| Western | 4 | 1.0% |
| TV Movie | 1 | 0.2% |

### Keyword coverage by era

| Era | Titles | ≥ 5 keywords | Coverage |
|---|---:|---:|---:|
| 1990-2009 | 90 | 90 | 100.0% |
| 2010+ | 283 | 274 | 96.8% |
| pre-1990 | 27 | 27 | 100.0% |

### Most common keywords

`sequel` (106), `based on novel or book` (83), `superhero` (65), `based on comic` (61), `aftercreditsstinger` (55), `duringcreditsstinger` (47), `villain` (42), `new york city` (31), `magic` (27), `friendship` (25), `dystopia` (23), `supernatural` (22), `hero` (20), `witch` (20), `marvel cinematic universe (mcu)` (20), `loss of loved one` (16), `martial arts` (16), `survival` (15), `musical` (15), `secret identity` (14)

## Television

- Titles sampled: **400** (most popular first)
- Genres in TMDB's `tv` vocabulary: **16**
- Genres per title (median): **3.0**
- Keywords per title (median / mean): **9.0 / 10.9**
- Titles with ≥ 5 keywords: **84.3%**
  - popular half: 84.5%, tail half: 84.0%
- Distinct keywords seen: **1390**, of which **64.1%** appear on exactly one title

### Genre distribution

| Genre | Titles | Share |
|---|---:|---:|
| Drama | 249 | 62.3% |
| Comedy | 133 | 33.2% |
| Action & Adventure | 120 | 30.0% |
| Sci-Fi & Fantasy | 113 | 28.2% |
| Crime | 103 | 25.8% |
| Animation | 78 | 19.5% |
| Mystery | 75 | 18.8% |
| Family | 35 | 8.8% |
| Kids | 21 | 5.2% |
| Talk | 16 | 4.0% |
| Reality | 15 | 3.8% |
| Soap | 11 | 2.8% |
| War & Politics | 8 | 2.0% |
| News | 6 | 1.5% |
| Western | 4 | 1.0% |
| Documentary | 3 | 0.8% |

### Keyword coverage by era

| Era | Titles | ≥ 5 keywords | Coverage |
|---|---:|---:|---:|
| 1990-2009 | 161 | 133 | 82.6% |
| 2010+ | 197 | 171 | 86.8% |
| pre-1990 | 42 | 33 | 78.6% |

### Most common keywords

`based on novel or book` (39), `sitcom` (29), `police` (28), `friendship` (28), `new york city` (27), `detective` (23), `romance` (23), `alien` (22), `magic` (21), `dysfunctional family` (20), `based on comic` (20), `superhero` (19), `spin off` (19), `family` (18), `based on manga` (18), `police procedural` (17), `los angeles, california` (17), `supernatural` (16), `anime` (16), `police detective` (15)

## Feature support in a real library

Median number of the user's own watched titles supporting a typical feature. This is the number a shrinkage constant has to be scaled against: a constant of K means a feature needs roughly K observations before its measured effect is taken at close to face value.

| Type | Library size | Median genre support | Median keyword support |
|---|---:|---:|---:|
| movie | 20 | 4.0 | 1.0 |
| movie | 40 | 7.0 | 1.0 |
| movie | 80 | 13.0 | 1.0 |
| tv | 20 | 4.0 | 1.0 |
| tv | 40 | 6.0 | 1.0 |
| tv | 80 | 9.0 | 1.0 |

If the two support columns differ by a large factor, a single shrinkage constant cannot serve both families and Phase 13 must namespace features by family and give each its own constant.

## Credit density

Distinct people appearing in a library of each size, and how many are seen at least three times. The second number is the one that matters for Phase 19: a "you like this director" claim needs a person the user has actually seen several times, so a family whose floor-clearing count is near zero feeds prediction but can never be displayed.

| Type | Library | Directors | ≥3 | Composers | ≥3 | Cast | ≥3 |
|---|---:|---:|---:|---:|---:|---:|---:|
| movie | 20 | 21.5 | 0.0 | 21.0 | 0.3 | 57.1 | 0.1 |
| movie | 50 | 51.5 | 0.4 | 47.2 | 2.3 | 135.8 | 1.7 |
| movie | 100 | 95.5 | 2.3 | 81.7 | 8.2 | 251.0 | 9.2 |
| tv | 20 | 27.6 | 0.0 | 33.1 | 0 | 59.7 | 0 |
| tv | 50 | 67.7 | 0.2 | 87.2 | 0.2 | 148.6 | 0 |
| tv | 100 | 130.2 | 0.9 | 136.7 | 0.8 | 294.5 | 0.1 |

### Cast nesting inside directors

For actors seen more than once, the median share of their appearances that fall under a single director. A high share means "you like this actor" and "you like this director" are largely the same observation counted twice, and Phase 19 has to suppress one of them.

| Type | Distinct actors | Seen 2+ times | Median share under one director |
|---|---:|---:|---:|
| movie | 741 | 202 | 50% |
| tv | 1123 | 70 | 50% |

