#!/usr/bin/env python3
"""
Measure the TMDB feature space — roadmap Phase 12, step 9.

Phase 13 designs a predictor whose shrinkage constants depend on how much
support a feature actually gets in a real user's library. Genres are dense;
keywords are sparse; a single constant cannot serve both. This script measures
the difference instead of guessing it, and writes docs/FEATURE-SPACE.md.

It answers four questions:

  1. What genres exist, and how are they distributed across film and television?
  2. How well are titles covered by keywords, and does coverage fall off with
     age or obscurity? (If it does, tone moods like "dark" are not viable.)
  3. In a library of N ranked titles, how many titles support a typical genre
     versus a typical keyword? This sets the per-family shrinkage constants.
  4. How dense are credits — directors, composers, cast — and how many clear a
     support floor of 3 in a realistic library? This decides whether a
     "favourite director" claim is displayable at all in Phase 19, and whether
     cast is prediction-only.

Usage:

    export TMDB_READ_TOKEN=...            # or leave it in Config/Secrets.xcconfig
    python3 scripts/measure_feature_space.py [--titles 400] [--out docs/FEATURE-SPACE.md]

Reads the token from $TMDB_READ_TOKEN, falling back to parsing
WatchRank/Config/Secrets.xcconfig. Standard library only — this is dev tooling
that runs on the Mac, not app code, so it does not touch the "no dependencies"
rule for the app itself.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

API = "https://api.themoviedb.org/3"
REPO = Path(__file__).resolve().parent.parent
SECRETS = REPO / "WatchRank" / "Config" / "Secrets.xcconfig"

# TMDB's own segment names, matching TMDBIdentifier.segment(for:) in the app.
TYPES = ("movie", "tv")


# --------------------------------------------------------------------------- #
# Credentials
# --------------------------------------------------------------------------- #

def read_token() -> str:
    token = os.environ.get("TMDB_READ_TOKEN", "").strip()
    if token:
        return token

    if SECRETS.exists():
        for line in SECRETS.read_text().splitlines():
            # xcconfig assignment, ignoring // comment lines.
            if line.strip().startswith("//"):
                continue
            match = re.match(r"\s*TMDB_READ_TOKEN\s*=\s*(.+?)\s*$", line)
            if match:
                value = match.group(1).strip()
                if value and value != "paste_your_tmdb_v4_read_access_token_here":
                    return value

    sys.exit(
        "No TMDB token.\n"
        "  Either: export TMDB_READ_TOKEN=...\n"
        f"  Or create {SECRETS.relative_to(REPO)} from the .example file."
    )


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #

class Client:
    def __init__(self, token: str):
        self.token = token
        self.calls = 0

    def get(self, path: str, **params) -> dict:
        url = f"{API}/{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)

        request = urllib.request.Request(url)
        request.add_header("Authorization", f"Bearer {self.token}")
        request.add_header("Accept", "application/json")

        for attempt in range(5):
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    self.calls += 1
                    return json.load(response)
            except urllib.error.HTTPError as error:
                if error.code == 401:
                    sys.exit("TMDB rejected the token (401). Check TMDB_READ_TOKEN.")
                if error.code == 429:
                    # Rate limited: back off and retry rather than losing the run.
                    time.sleep(2 ** attempt)
                    continue
                if error.code == 404:
                    return {}
                raise
            except (urllib.error.URLError, TimeoutError):
                time.sleep(1 + attempt)
        return {}


# --------------------------------------------------------------------------- #
# Collection
# --------------------------------------------------------------------------- #

def genre_tables(client: Client) -> dict[str, dict[int, str]]:
    tables = {}
    for kind in TYPES:
        payload = client.get(f"genre/{kind}/list")
        tables[kind] = {g["id"]: g["name"] for g in payload.get("genres", [])}
    return tables


def popular_titles(client: Client, kind: str, wanted: int) -> list[dict]:
    """Pages /discover the same way CandidatePoolBuilder will in Phase 14."""
    vote_floor = 300 if kind == "movie" else 100
    titles, page = [], 1

    while len(titles) < wanted and page <= 500:
        payload = client.get(
            f"discover/{kind}",
            sort_by="popularity.desc",
            include_adult="false",
            page=page,
            **{"vote_count.gte": vote_floor},
        )
        results = payload.get("results", [])
        if not results:
            break
        for index, result in enumerate(results):
            result["_rank"] = len(titles) + index
        titles.extend(results)
        page += 1
        print(f"  {kind}: {len(titles)}/{wanted} titles", end="\r", flush=True)

    print(f"  {kind}: {len(titles)} titles          ")
    return titles[:wanted]


# Mirrors the caps in TMDBDetailDTO, so the measurement describes what the app
# actually stores rather than everything TMDB offers.
CAST_CAP = 3
KEYWORD_CAP = 10


def fetch_features(client: Client, kind: str, titles: list[dict], workers: int) -> dict[int, dict]:
    """One request per title, matching what the app does.

    `append_to_response` folds credits and keywords into the detail call, so
    this costs one round trip per title rather than three — and measures the
    same payload TMDBDetailDTO.features() parses.

    Television needs `aggregate_credits`, not `credits`: the latter is an
    episode-level snapshot, the former rolls roles up across the run.
    """
    credits_key = "credits" if kind == "movie" else "aggregate_credits"
    out: dict[int, dict] = {}

    def one(title: dict) -> tuple[int, dict]:
        payload = client.get(
            f"{kind}/{title['id']}", append_to_response=f"{credits_key},keywords"
        )
        if not payload:
            return title["id"], {}

        keyword_block = payload.get("keywords") or {}
        keywords = keyword_block.get("keywords") or keyword_block.get("results") or []

        credits = payload.get(credits_key) or {}
        crew = credits.get("crew") or []
        cast = credits.get("cast") or []

        def holds(entry: dict, job: str) -> bool:
            if entry.get("job") == job:
                return True
            return any(j.get("job") == job for j in entry.get("jobs") or [])

        # Television credits the creator, not the episode director — episode
        # directors vary week to week and would be pure noise.
        if kind == "tv":
            directors = [(p["id"], p["name"]) for p in payload.get("created_by") or []]
        else:
            directors = [(c["id"], c["name"]) for c in crew if holds(c, "Director")]

        composers = [(c["id"], c["name"]) for c in crew if holds(c, "Original Music Composer")]

        if kind == "movie":
            ranked = sorted(cast, key=lambda c: c.get("order", 10**6))
        else:
            ranked = sorted(cast, key=lambda c: -(c.get("total_episode_count") or 0))

        return title["id"], {
            "keywords": [k["name"] for k in keywords[:KEYWORD_CAP]],
            "keywords_available": len(keywords),
            "directors": directors,
            "composers": composers,
            "cast": [(c["id"], c["name"]) for c in ranked[:CAST_CAP]],
            "cast_available": len(cast),
        }

    with ThreadPoolExecutor(max_workers=workers) as pool:
        for done, (title_id, features) in enumerate(pool.map(one, titles), start=1):
            out[title_id] = features
            if done % 25 == 0:
                print(f"  {kind}: features for {done}/{len(titles)}", end="\r", flush=True)

    print(f"  {kind}: features for {len(titles)} titles      ")
    return out


def credit_density(titles, features, sizes=(20, 50, 100), trials=200, seed=99, floor=3):
    """Distinct people per library size, and how many clear a support floor.

    Phase 19 wants to say "you rate Nolan films highly". That claim needs a
    person the user has actually seen several times. This measures how many such
    people exist at realistic library sizes — the difference between a feature
    that is displayable and one that only ever feeds the prediction.
    """
    rng = random.Random(seed)
    families = ("director", "composer", "cast")
    rows = []

    for size in sizes:
        if size > len(titles):
            continue
        totals = {family: [] for family in families}
        clearing = {family: [] for family in families}

        for _ in range(trials):
            sample = rng.sample(titles, size)
            counters = {family: Counter() for family in families}
            for title in sample:
                data = features.get(title["id"]) or {}
                for person_id, _ in data.get("directors", []):
                    counters["director"][person_id] += 1
                for person_id, _ in data.get("composers", []):
                    counters["composer"][person_id] += 1
                for person_id, _ in data.get("cast", []):
                    counters["cast"][person_id] += 1

            for family, counter in counters.items():
                totals[family].append(len(counter))
                clearing[family].append(sum(1 for c in counter.values() if c >= floor))

        row = {"library_size": size, "floor": floor}
        for family in families:
            row[f"{family}_distinct"] = round(statistics.mean(totals[family]), 1)
            row[f"{family}_clearing_floor"] = round(statistics.mean(clearing[family]), 1)
        rows.append(row)

    return rows


def cast_nesting(titles, features):
    """How much of an actor's presence is really one director's presence.

    If every DiCaprio title in a library is also a Scorsese title, then "you
    like DiCaprio" and "you like Scorsese" are one observation counted twice,
    and Phase 19 must suppress one. Reports, for actors seen more than once, the
    median share of appearances under their single most common director.
    """
    appearances: dict[int, list[frozenset]] = {}

    for title in titles:
        data = features.get(title["id"]) or {}
        directors = frozenset(pid for pid, _ in data.get("directors", []))
        for person_id, _ in data.get("cast", []):
            appearances.setdefault(person_id, []).append(directors)

    shares = []
    for director_sets in appearances.values():
        if len(director_sets) < 2:
            continue
        counter = Counter()
        for directors in director_sets:
            for director in directors:
                counter[director] += 1
        if counter:
            shares.append(counter.most_common(1)[0][1] / len(director_sets))

    return {
        "distinct_actors": len(appearances),
        "actors_seen_twice_or_more": sum(1 for s in appearances.values() if len(s) >= 2),
        "median_share_under_one_director": (
            round(statistics.median(shares), 3) if shares else None
        ),
    }


# --------------------------------------------------------------------------- #
# Analysis
# --------------------------------------------------------------------------- #

def year_of(title: dict) -> int | None:
    raw = title.get("release_date") or title.get("first_air_date") or ""
    return int(raw[:4]) if len(raw) >= 4 and raw[:4].isdigit() else None


def simulate_library(titles, keywords, table, size, trials=200, seed=12345):
    """How much support a typical feature gets in a library of `size` titles.

    This is the measurement Phase 13's shrinkage constants come from. A constant
    K means "a feature needs roughly K observations before its effect is taken
    at face value", so the right K depends on how many observations a feature
    actually gets — and that differs by an order of magnitude between genres
    and keywords.
    """
    rng = random.Random(seed)
    genre_supports, keyword_supports = [], []

    for _ in range(trials):
        sample = rng.sample(titles, min(size, len(titles)))

        genre_counts = Counter()
        keyword_counts = Counter()
        for title in sample:
            for gid in title.get("genre_ids", []):
                if gid in table:
                    genre_counts[table[gid]] += 1
            for keyword in (keywords.get(title["id"]) or {}).get("keywords", []):
                keyword_counts[keyword] += 1

        if genre_counts:
            genre_supports.append(statistics.median(genre_counts.values()))
        if keyword_counts:
            keyword_supports.append(statistics.median(keyword_counts.values()))

    median = lambda xs: round(statistics.median(xs), 2) if xs else 0.0
    return {
        "library_size": size,
        "median_genre_support": median(genre_supports),
        "median_keyword_support": median(keyword_supports),
    }


def analyse(titles_by_type, keywords_by_type, tables) -> dict:
    report = {"types": {}, "simulations": {}}

    for kind in TYPES:
        titles = titles_by_type[kind]
        keywords = keywords_by_type[kind]
        table = tables[kind]

        genre_counts = Counter()
        for title in titles:
            for gid in title.get("genre_ids", []):
                if gid in table:
                    genre_counts[table[gid]] += 1

        per_title = [
            (keywords.get(t["id"]) or {}).get("keywords_available", 0) for t in titles
        ]
        covered = sum(1 for n in per_title if n >= 5)

        # Coverage against obscurity: the pool is popularity-ordered, so the
        # later half is the less popular half.
        half = max(1, len(titles) // 2)
        top_cov = sum(1 for n in per_title[:half] if n >= 5) / half
        tail_cov = sum(1 for n in per_title[half:] if n >= 5) / max(1, len(titles) - half)

        # Coverage against age.
        by_era = {}
        for title, count in zip(titles, per_title):
            year = year_of(title)
            if year is None:
                continue
            era = "2010+" if year >= 2010 else ("1990-2009" if year >= 1990 else "pre-1990")
            bucket = by_era.setdefault(era, [0, 0])
            bucket[0] += 1
            if count >= 5:
                bucket[1] += 1

        keyword_frequency = Counter()
        for title in titles:
            for keyword in (keywords.get(title["id"]) or {}).get("keywords", []):
                keyword_frequency[keyword] += 1

        singletons = sum(1 for c in keyword_frequency.values() if c == 1)

        report["types"][kind] = {
            "titles": len(titles),
            "genres_total": len(table),
            "genre_counts": genre_counts.most_common(),
            "genres_per_title_median": statistics.median(
                [len(t.get("genre_ids", [])) for t in titles] or [0]
            ),
            "keywords_per_title_median": statistics.median(per_title or [0]),
            "keywords_per_title_mean": round(statistics.mean(per_title or [0]), 1),
            "coverage_5plus": round(covered / max(1, len(titles)), 3),
            "coverage_5plus_popular_half": round(top_cov, 3),
            "coverage_5plus_tail_half": round(tail_cov, 3),
            "coverage_by_era": {
                era: {"titles": n, "covered": c, "fraction": round(c / n, 3)}
                for era, (n, c) in sorted(by_era.items())
            },
            "distinct_keywords": len(keyword_frequency),
            "keyword_singleton_fraction": round(singletons / max(1, len(keyword_frequency)), 3),
            "top_keywords": keyword_frequency.most_common(20),
        }

        report["simulations"][kind] = [
            simulate_library(titles, keywords, table, size) for size in (20, 40, 80)
        ]
        report.setdefault("credits", {})[kind] = credit_density(titles, keywords)
        report.setdefault("nesting", {})[kind] = cast_nesting(titles, keywords)

    return report


# --------------------------------------------------------------------------- #
# Report
# --------------------------------------------------------------------------- #

def write_report(report: dict, path: Path, calls: int, sampled: int) -> None:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines: list[str] = []
    add = lines.append

    add("# TMDB feature space")
    add("")
    add(f"Measured {now} by `scripts/measure_feature_space.py` "
        f"({sampled} titles per type, {calls} API calls). Roadmap Phase 12, step 9.")
    add("")
    add("This exists so Phase 13 can pick shrinkage constants from data rather than "
        "from intuition. Re-run the script to refresh it; do not hand-edit the numbers.")
    add("")

    for kind in TYPES:
        data = report["types"][kind]
        label = "Film" if kind == "movie" else "Television"
        add(f"## {label}")
        add("")
        add(f"- Titles sampled: **{data['titles']}** (most popular first)")
        add(f"- Genres in TMDB's `{kind}` vocabulary: **{data['genres_total']}**")
        add(f"- Genres per title (median): **{data['genres_per_title_median']}**")
        add(f"- Keywords per title (median / mean): **{data['keywords_per_title_median']} / "
            f"{data['keywords_per_title_mean']}**")
        add(f"- Titles with ≥ 5 keywords: **{data['coverage_5plus']:.1%}**")
        add(f"  - popular half: {data['coverage_5plus_popular_half']:.1%}, "
            f"tail half: {data['coverage_5plus_tail_half']:.1%}")
        add(f"- Distinct keywords seen: **{data['distinct_keywords']}**, of which "
            f"**{data['keyword_singleton_fraction']:.1%}** appear on exactly one title")
        add("")

        add("### Genre distribution")
        add("")
        add("| Genre | Titles | Share |")
        add("|---|---:|---:|")
        for name, count in data["genre_counts"]:
            add(f"| {name} | {count} | {count / max(1, data['titles']):.1%} |")
        add("")

        add("### Keyword coverage by era")
        add("")
        add("| Era | Titles | ≥ 5 keywords | Coverage |")
        add("|---|---:|---:|---:|")
        for era, stats in data["coverage_by_era"].items():
            add(f"| {era} | {stats['titles']} | {stats['covered']} | {stats['fraction']:.1%} |")
        add("")

        add("### Most common keywords")
        add("")
        add(", ".join(f"`{k}` ({n})" for k, n in data["top_keywords"]))
        add("")

    add("## Feature support in a real library")
    add("")
    add("Median number of the user's own watched titles supporting a typical feature. "
        "This is the number a shrinkage constant has to be scaled against: a constant "
        "of K means a feature needs roughly K observations before its measured effect "
        "is taken at close to face value.")
    add("")
    add("| Type | Library size | Median genre support | Median keyword support |")
    add("|---|---:|---:|---:|")
    for kind in TYPES:
        for sim in report["simulations"][kind]:
            add(f"| {kind} | {sim['library_size']} | {sim['median_genre_support']} "
                f"| {sim['median_keyword_support']} |")
    add("")
    add("If the two support columns differ by a large factor, a single shrinkage "
        "constant cannot serve both families and Phase 13 must namespace features "
        "by family and give each its own constant.")
    add("")

    add("## Credit density")
    add("")
    add("Distinct people appearing in a library of each size, and how many are seen "
        "at least three times. The second number is the one that matters for Phase 19: "
        "a \"you like this director\" claim needs a person the user has actually seen "
        "several times, so a family whose floor-clearing count is near zero feeds "
        "prediction but can never be displayed.")
    add("")
    add("| Type | Library | Directors | ≥3 | Composers | ≥3 | Cast | ≥3 |")
    add("|---|---:|---:|---:|---:|---:|---:|---:|")
    for kind in TYPES:
        for row in report.get("credits", {}).get(kind, []):
            add(f"| {kind} | {row['library_size']} "
                f"| {row['director_distinct']} | {row['director_clearing_floor']} "
                f"| {row['composer_distinct']} | {row['composer_clearing_floor']} "
                f"| {row['cast_distinct']} | {row['cast_clearing_floor']} |")
    add("")

    add("### Cast nesting inside directors")
    add("")
    add("For actors seen more than once, the median share of their appearances that "
        "fall under a single director. A high share means \"you like this actor\" and "
        "\"you like this director\" are largely the same observation counted twice, "
        "and Phase 19 has to suppress one of them.")
    add("")
    add("| Type | Distinct actors | Seen 2+ times | Median share under one director |")
    add("|---|---:|---:|---:|")
    for kind in TYPES:
        nesting = report.get("nesting", {}).get(kind, {})
        share = nesting.get("median_share_under_one_director")
        add(f"| {kind} | {nesting.get('distinct_actors', 0)} "
            f"| {nesting.get('actors_seen_twice_or_more', 0)} "
            f"| {'—' if share is None else f'{share:.0%}'} |")
    add("")

    path.write_text("\n".join(lines) + "\n")


# --------------------------------------------------------------------------- #

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--titles", type=int, default=400,
                        help="titles to sample per media type (default 400)")
    parser.add_argument("--workers", type=int, default=8,
                        help="concurrent keyword requests (default 8)")
    parser.add_argument("--out", type=Path, default=REPO / "docs" / "FEATURE-SPACE.md")
    parser.add_argument("--json", type=Path, default=None,
                        help="also write the raw measurements as JSON")
    args = parser.parse_args()

    client = Client(read_token())

    print("Fetching genre tables...")
    tables = genre_tables(client)
    for kind in TYPES:
        print(f"  {kind}: {len(tables[kind])} genres")

    titles_by_type, keywords_by_type = {}, {}
    for kind in TYPES:
        print(f"Fetching popular {kind} titles...")
        titles_by_type[kind] = popular_titles(client, kind, args.titles)
        print(f"Fetching {kind} features ({len(titles_by_type[kind])} requests)...")
        keywords_by_type[kind] = fetch_features(
            client, kind, titles_by_type[kind], args.workers
        )

    print("Analysing...")
    report = analyse(titles_by_type, keywords_by_type, tables)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    write_report(report, args.out, client.calls, args.titles)
    print(f"Wrote {args.out.relative_to(REPO)} ({client.calls} API calls)")

    if args.json:
        args.json.write_text(json.dumps(report, indent=2))
        print(f"Wrote {args.json}")


if __name__ == "__main__":
    main()
