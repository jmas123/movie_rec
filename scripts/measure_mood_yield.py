#!/usr/bin/env python3
"""
Measure per-mood candidate yield — roadmap Phase 14, step 0.

docs/FEATURE-SPACE.md establishes that 84.3% of TV series carry >= 5 keywords.
That is keyword *coverage*, and it is not the statistic Phase 14 needs. Phase 14
needs per-mood *yield*: how many titles carry the specific keywords a given mood
is defined by, after deduplication and after the user's own watched titles are
excluded. Open question 12 flags exactly this gap -- "coverage is not the same
as usefulness".

It matters because TMDB's TV genre vocabulary has no Thriller, no Horror and no
Romance, so seven of the ten starting moods have no TV genre to stand on and
must be carried by keywords alone. A mood that returns 11 series is a bad mood
definition, not an engineering failure -- and the fix is a different keyword set
or dropping the mood, which is a decision to make from numbers rather than from
how good the mood sounds.

It answers four questions:

  1. How many titles does each (mood, media type) yield, split by whether the
     yield comes from a genre basis or a keyword basis?
  2. Which individual keywords actually carry volume, and which are dead? A
     mood is only as good as its best keyword.
  3. What survives exclusion? Yield is measured against simulated watched
     libraries of 20 / 50 / 100 titles drawn from the popularity head, because
     that is what a real library looks like.
  4. How much do moods overlap? Overlap costs storage rather than coverage --
     but it makes exclusions *correlated*, so watching the top thrillers
     depletes `dark`, `thriller` and `mindBending` at once.

Usage:

    export TMDB_READ_TOKEN=...            # or leave it in Config/Secrets.xcconfig
    python3 scripts/measure_mood_yield.py [--pages 3] [--out docs/MOOD-YIELD.md]

Standard library only, same as measure_feature_space.py. Deliberately a separate
script writing a separate document: re-running the Phase 12 sweep to obtain
Phase 14 numbers would cost 842 calls and would rewrite measurements that other
phases already cite.
"""

from __future__ import annotations

import argparse
import json
import random
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API = "https://api.themoviedb.org/3"
REPO = Path(__file__).resolve().parent.parent
SECRETS = REPO / "Binged" / "Config" / "Secrets.xcconfig"
TYPES = ("movie", "tv")

# Reuse the credential handling and HTTP client from the Phase 12 script rather
# than growing a second copy that can drift.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from measure_feature_space import Client, read_token, genre_tables  # noqa: E402


# --------------------------------------------------------------------------- #
# Mood definitions under test
# --------------------------------------------------------------------------- #
#
# These are *candidates*, not the shipping taxonomy -- deciding the taxonomy is
# what this script exists for. Genres are named, not id'd: the ids are resolved
# from the live tables, so a mood naming a genre that does not exist in a type's
# vocabulary shows up as an explicit gap rather than as a silent empty query.
#
# A note on TMDB query semantics that shapes every definition here: within one
# parameter, `|` means OR and `,` means AND -- but two *different* parameters are
# AND-ed together. So `with_genres=27&with_keywords=9714` means "horror AND
# supernatural", never "horror OR supernatural". A mood wanting the union of a
# genre basis and a keyword basis therefore needs two queries whose results are
# unioned client-side, which is exactly how the pool builder will have to work.

MOODS = {
    "crime": {
        "movie": {"genres": ["Crime"], "keywords": []},
        "tv": {"genres": ["Crime"], "keywords": []},
    },
    "thriller": {
        "movie": {"genres": ["Thriller"], "keywords": []},
        "tv": {"genres": ["Mystery"], "keywords": ["thriller", "suspense"]},
    },
    "dark": {
        "movie": {"genres": [], "keywords": ["neo-noir", "dystopia", "psychological thriller", "nihilism"]},
        "tv": {"genres": [], "keywords": ["neo-noir", "dystopia", "psychological thriller", "dark comedy"]},
    },
    "horror": {
        "movie": {"genres": ["Horror"], "keywords": []},
        "tv": {"genres": [], "keywords": ["horror", "supernatural", "zombie", "haunting", "vampire"]},
    },
    "romance": {
        "movie": {"genres": ["Romance"], "keywords": []},
        "tv": {"genres": [], "keywords": ["romance", "love triangle", "romcom"]},
    },
    "comedy": {
        "movie": {"genres": ["Comedy"], "keywords": []},
        "tv": {"genres": ["Comedy"], "keywords": []},
    },
    "mindBending": {
        "movie": {"genres": [], "keywords": ["time travel", "memory", "nonlinear timeline", "time loop"]},
        "tv": {"genres": [], "keywords": ["time travel", "parallel world", "memory", "time loop"]},
    },
    "feelGood": {
        "movie": {"genres": [], "keywords": ["friendship", "coming of age", "small town"]},
        "tv": {"genres": [], "keywords": ["friendship", "coming of age", "workplace comedy"]},
    },
    "trueStory": {
        "movie": {"genres": [], "keywords": ["based on true story", "biography"]},
        "tv": {"genres": [], "keywords": ["based on true story", "biography"]},
    },
    "epic": {
        "movie": {"genres": ["Adventure"], "keywords": ["sword and sorcery", "quest"]},
        "tv": {"genres": ["Sci-Fi & Fantasy"], "keywords": ["sword and sorcery"]},
    },
}

# Keywords tried and rejected, with the volume that condemned them. Kept in the
# file rather than deleted so a later session does not re-propose them, and so
# the report can show the pruning rather than only its result.
RETIRED = {
    "feel good": "0 / 0 — a 2023-era tag nobody applies. `feel-good` is the same id 379696.",
    "heartwarming": "2 / 1 — same story. `small town` (196 / 58) carries the mood instead.",
    "alternate reality": "0 / 0 — `parallel world` (25 / 33) is the live tag in that space.",
    "wholesome": "0 / 0 — probed as a replacement, equally dead.",
    "mind bending": "0 / 0 — the mood's own name is not a usable tag.",
    "dream": "3 / 1 — replaced by `time loop` (28 / 9).",
    "epic": "3 / 1 — the mood's namesake keyword is dead; it stands on its genre basis.",
    "epic fantasy": "4 / 0 — probed as a replacement, also dead.",
    "based on mythology": "unresolved — no such keyword.",
    "romantic comedy": "1 / 0 — replaced by `romcom` (139 / 99).",
    "historical event": "5 / 3 — `trueStory` stands on `based on true story` + `biography`.",
    "based on a true story": "duplicate of `based on true story` (both id 9672).",
}

VOTE_FLOOR = {"movie": 300, "tv": 100}

# Keywords measured for volume but not wired into any mood: replacement
# candidates for whichever definitions above turn out to rest on a dead tag.
# Two calls each, and it turns "this mood is broken" into "use these instead".
PROBE_KEYWORDS = sorted(set(RETIRED) | {
    "feel-good", "uplifting", "found family", "parallel universe", "multiverse",
    "alternate timeline", "simulated reality", "sword and sandal",
    "dream sequence", "twist ending", "unreliable narrator", "love",
})


# --------------------------------------------------------------------------- #
# Keyword resolution
# --------------------------------------------------------------------------- #

def resolve_keywords(client: Client, names: list[str]) -> dict[str, int | None]:
    """Maps keyword names to TMDB ids via /search/keyword.

    An unresolvable name returns None and is reported rather than dropped: a
    mood silently missing a third of its basis would look like the mood being
    narrow, when the truth is a typo.
    """
    resolved: dict[str, int | None] = {}
    for name in sorted(set(names)):
        payload = client.get("search/keyword", query=name)
        results = payload.get("results", [])
        # Prefer an exact case-insensitive match; TMDB's search is fuzzy and
        # "romance" returns "romance novel" ahead of "romance" often enough to
        # matter.
        exact = [r for r in results if r.get("name", "").lower() == name.lower()]
        chosen = (exact or results)
        resolved[name] = chosen[0]["id"] if chosen else None
        print(f"  {name!r} -> {resolved[name]}")

    by_id: dict[int, list[str]] = {}
    for name, kid in resolved.items():
        if kid is not None:
            by_id.setdefault(kid, []).append(name)
    for kid, names in by_id.items():
        if len(names) > 1:
            print(f"  NOTE: {names} all resolve to id {kid} — one of them is redundant")
    return resolved


def keyword_volume(client: Client, kind: str, keyword_id: int) -> int:
    """How many titles of `kind` carry this keyword, above the vote floor."""
    payload = client.get(
        f"discover/{kind}",
        sort_by="popularity.desc",
        include_adult="false",
        page=1,
        with_keywords=str(keyword_id),
        **{"vote_count.gte": VOTE_FLOOR[kind]},
    )
    return int(payload.get("total_results", 0))


# --------------------------------------------------------------------------- #
# Paging
# --------------------------------------------------------------------------- #

def discover_ids(client: Client, kind: str, pages: int, **params) -> tuple[list[int], int]:
    """Pages /discover, returning (ids in popularity order, total_results)."""
    ids: list[int] = []
    total = 0
    for page in range(1, pages + 1):
        payload = client.get(
            f"discover/{kind}",
            sort_by="popularity.desc",
            include_adult="false",
            page=page,
            **{"vote_count.gte": VOTE_FLOOR[kind]},
            **params,
        )
        total = int(payload.get("total_results", total))
        results = payload.get("results", [])
        if not results:
            break
        ids.extend(int(r["id"]) for r in results)
        if page >= int(payload.get("total_pages", 1)):
            break
    return ids, total


def mood_yield(client, kind, definition, genre_ids, keyword_ids, pages):
    """Union of a mood's genre basis and keyword basis.

    Two queries rather than one, because different /discover parameters are
    AND-ed. Unioning client-side is the only way to express "horror OR
    supernatural", and it is what CandidatePoolBuilder will have to do.
    """
    genre_names = definition["genres"]
    missing = [g for g in genre_names if g not in genre_ids]
    present = [genre_ids[g] for g in genre_names if g in genre_ids]

    kw_ids = [keyword_ids[k] for k in definition["keywords"] if keyword_ids.get(k)]

    genre_hits, genre_total = ([], 0)
    if present:
        genre_hits, genre_total = discover_ids(
            client, kind, pages, with_genres="|".join(str(i) for i in present)
        )

    keyword_hits, keyword_total = ([], 0)
    if kw_ids:
        keyword_hits, keyword_total = discover_ids(
            client, kind, pages, with_keywords="|".join(str(i) for i in kw_ids)
        )

    union = list(dict.fromkeys(genre_hits + keyword_hits))
    return {
        "genre_basis": sorted(set(genre_hits)),
        "keyword_basis": sorted(set(keyword_hits)),
        "union": union,
        "genre_total": genre_total,
        "keyword_total": keyword_total,
        "missing_genres": missing,
    }


# --------------------------------------------------------------------------- #
# Exclusion simulation
# --------------------------------------------------------------------------- #

def popularity_head(client: Client, kind: str, pages: int) -> list[int]:
    """What people have actually watched, approximated by what is popular."""
    ids, _ = discover_ids(client, kind, pages)
    return ids


def simulate_exclusion(mood_ids, head, sizes, trials=300, seed=4242):
    """Median surviving yield after removing a simulated watched library.

    The library is drawn from the popularity head rather than uniformly from the
    catalog, because that is what a real library looks like -- and it is the
    assumption that makes exclusions bite. A uniform sample would barely touch a
    mood's popular head and would report a reassuring number that no real user
    would ever see.

    The head must be *deep* relative to the library size, or this measures the
    instrument: with a 120-title head and a 60-title mood pool, most draws miss
    the pool entirely and every mood looks untouched.
    """
    rng = random.Random(seed)
    mood_set = set(mood_ids)
    out = {}
    for size in sizes:
        if size > len(head):
            out[size] = None
            continue
        survivors = []
        for _ in range(trials):
            watched = set(rng.sample(head, size))
            survivors.append(len(mood_set - watched))
        out[size] = statistics.median(survivors)
    return out


def jaccard(a: set, b: set) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


# --------------------------------------------------------------------------- #
# Report
# --------------------------------------------------------------------------- #

TARGET = 30

# A keyword at or below this is a dead tag, not a narrow one.
DEAD_KEYWORD = 5


def write_report(report, path: Path, calls: int, pages: int) -> None:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    L: list[str] = []
    add = L.append

    add("# Mood yield")
    add("")
    add(f"Measured {now} by `scripts/measure_mood_yield.py` "
        f"({pages} pages per query, {calls} API calls). Roadmap Phase 14, step 0.")
    add("")
    add("This exists so the mood taxonomy is chosen from numbers rather than from how good "
        "a mood sounds. Re-run the script to refresh it; do not hand-edit the numbers.")
    add("")
    add("Companion to [`FEATURE-SPACE.md`](./FEATURE-SPACE.md), which measures keyword "
        "*coverage*. This measures per-mood *yield*, which is the different and harder question — "
        "see roadmap open question 12.")
    add("")
    add(f"**Target:** every supported (mood, type) pair must clear **{TARGET} eligible candidates** "
        "after exclusions. `pages` caps each query, so a `union` at the cap means the true "
        "catalogue yield is higher — what matters is whether the *post-exclusion* number clears the bar.")
    add("")

    # --- headline table -----------------------------------------------------
    add("## Yield by mood and type")
    add("")
    add("`genre` and `keyword` are the two query bases, unioned client-side because TMDB "
        "AND-s different `/discover` parameters. `catalogue` is TMDB's own `total_results` "
        "for the larger basis — the ceiling, not what we fetched.")
    add("")
    add("| Mood | Type | basis | **catalogue** | cached | after 20 watched | after 50 | after 100 | verdict |")
    add("|---|---|---|---:|---:|---:|---:|---:|---|")

    for mood in MOODS:
        for kind in TYPES:
            entry = report["moods"][mood][kind]
            ex = entry["after_exclusion"]
            cat = entry["catalogue"]

            bases = []
            if entry["genre_basis"]:
                bases.append("genre")
            if entry["keyword_basis"]:
                bases.append("keyword")

            # The verdict is judged on `catalogue`, which is exact, never on
            # `cached`, which is capped by --pages and therefore measures the
            # flag rather than the mood.
            if cat >= TARGET * 3:
                verdict = "ok"
            elif cat >= TARGET:
                verdict = "**thin**"
            else:
                verdict = "**FAILS**"

            add("| `{}` | {} | {} | **{}** | {} | {} | {} | {} | {} |".format(
                mood, kind, "+".join(bases) or "—",
                cat or 0, len(entry["union"]),
                ex.get(20, "—"), ex.get(50, "—"), ex.get(100, "—"),
                verdict,
            ))
    add("")
    add("**Read `catalogue`, not `cached`.** `catalogue` is TMDB's own `total_results` — "
        "exact, and the number that decides whether a mood is viable. `cached` is capped at "
        "`--pages × 20` and describes how deep this run paged, not how many titles exist; a "
        "mood sitting exactly at the cap has more titles behind it. The post-exclusion columns "
        "are computed over `cached`, so they answer \"how much of the pool we would actually "
        "hold survives\", which is the operative question for a fixed-size cache.")
    add("")

    gaps = report["missing_genres"]
    if gaps:
        add("### Moods naming a genre their type's vocabulary does not have")
        add("")
        for (mood, kind), names in sorted(gaps.items()):
            add(f"- `{mood}` / {kind}: {', '.join(names)} — carried by keywords alone")
        add("")

    # --- keyword volume -----------------------------------------------------
    add("## Keyword volume")
    add("")
    add("Titles above the vote floor carrying each keyword, from TMDB's `total_results`. "
        "A mood is only as strong as its best keyword; a keyword at 0 is a typo or a dead tag "
        "and should be replaced, not kept for completeness.")
    add("")
    in_use = report["keywords_in_use"]
    dead = [n for n in in_use
            if max(report["keyword_volume"].get(n, {}).get("movie", 0),
                   report["keyword_volume"].get(n, {}).get("tv", 0)) <= DEAD_KEYWORD]
    if dead:
        add(f"**{len(dead)} of {len(in_use)} keywords currently in a mood definition are "
            f"effectively dead** (<= {DEAD_KEYWORD} titles on both types): "
            + ", ".join(f"`{n}`" for n in sorted(dead)) + ".")
        add("")
        add("These are recently-minted tags almost nobody has applied. A mood resting on one is "
            "resting on nothing, and the fix is a different keyword rather than more paging.")
        add("")

    add("Rows marked `·` are **probe candidates** — measured but not currently wired into "
        "any mood, so a dead definition above has a costed replacement rather than only a "
        "diagnosis.")
    add("")
    add("| Keyword | id | movie | tv |")
    add("|---|---:|---:|---:|")
    for name in sorted(report["keyword_volume"], key=lambda n: -max(
            report["keyword_volume"][n].get("movie", 0),
            report["keyword_volume"][n].get("tv", 0))):
        vol = report["keyword_volume"][name]
        kid = report["keyword_ids"].get(name)
        used = name in report["keywords_in_use"]
        label = f"`{name}`" if used else f"`{name}` ·"
        add(f"| {label} | {kid if kid else '**unresolved**'} | "
            f"{vol.get('movie', 0)} | {vol.get('tv', 0)} |")
    add("")

    add("### Retired during this phase")
    add("")
    add("Tried, measured, and rejected. Recorded so a later session does not re-propose them.")
    add("")
    add("| Keyword | Why |")
    add("|---|---|")
    for name, why in sorted(RETIRED.items()):
        add(f"| `{name}` | {why} |")
    add("")

    # --- overlap ------------------------------------------------------------
    add("## Mood overlap")
    add("")
    add("Jaccard similarity between mood pools of the same type. Overlap costs storage "
        "rather than coverage — the pool is paged per mood, so a shared title is stored once "
        "and listed twice. What it *does* cost is **correlated exclusion**: watching the "
        "titles in one mood's head depletes every mood that shares them, which is why the "
        "post-exclusion columns above are the ones that matter.")
    add("")
    for kind in TYPES:
        pairs = report["overlap"][kind]
        if not pairs:
            continue
        add(f"### {kind}")
        add("")
        add("| Pair | Jaccard | shared titles |")
        add("|---|---:|---:|")
        for (a, b), (score, shared) in sorted(pairs.items(), key=lambda kv: -kv[1][0])[:12]:
            add(f"| `{a}` ∩ `{b}` | {score:.2f} | {shared} |")
        add("")

    # --- pool size ----------------------------------------------------------
    add("## Resulting pool size")
    add("")
    add("The deduplicated union of every mood pool — the number the old "
        "\"~1200 distinct titles\" criterion was trying to name. It is an **output**, "
        "not a target: coverage is guaranteed by per-mood paging, so this figure is a "
        "cache-footprint budget and nothing more.")
    add("")
    add("| Type | Distinct titles | Sum of mood pools | Storage saved by dedupe |")
    add("|---|---:|---:|---:|")
    for kind in TYPES:
        distinct = report["pool"][kind]["distinct"]
        total = report["pool"][kind]["sum"]
        saved = f"{100 * (1 - distinct / total):.0f}%" if total else "—"
        add(f"| {kind} | **{distinct}** | {total} | {saved} |")
    add("")

    path.write_text("\n".join(L) + "\n")


# --------------------------------------------------------------------------- #

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pages", type=int, default=5,
                        help="pages per query, 20 titles each (default 3)")
    parser.add_argument("--head-pages", type=int, default=15,
                        help="pages of popularity head for the exclusion simulation")
    parser.add_argument("--out", type=Path, default=REPO / "docs" / "MOOD-YIELD.md")
    parser.add_argument("--json", type=Path, default=None)
    args = parser.parse_args()

    client = Client(read_token())

    print("Fetching genre tables...")
    tables = genre_tables(client)
    genre_ids = {
        kind: {name: gid for gid, name in tables[kind].items()} for kind in TYPES
    }
    for kind in TYPES:
        print(f"  {kind}: {len(tables[kind])} genres")

    every_keyword = sorted({
        k for mood in MOODS.values() for spec in mood.values() for k in spec["keywords"]
    } | set(PROBE_KEYWORDS))
    print(f"Resolving {len(every_keyword)} keywords...")
    keyword_ids = resolve_keywords(client, every_keyword)

    print("Measuring keyword volume...")
    keyword_volume_map = {}
    for name, kid in keyword_ids.items():
        keyword_volume_map[name] = {}
        if kid is None:
            continue
        for kind in TYPES:
            keyword_volume_map[name][kind] = keyword_volume(client, kind, kid)

    print("Fetching popularity head for exclusion simulation...")
    head = {kind: popularity_head(client, kind, args.head_pages) for kind in TYPES}
    for kind in TYPES:
        print(f"  {kind}: {len(head[kind])} titles")

    print("Measuring mood yield...")
    moods_report: dict = {}
    missing_genres: dict = {}
    for mood, per_type in MOODS.items():
        moods_report[mood] = {}
        for kind in TYPES:
            result = mood_yield(
                client, kind, per_type[kind], genre_ids[kind], keyword_ids, args.pages
            )
            if result["missing_genres"]:
                missing_genres[(mood, kind)] = result["missing_genres"]
            result["catalogue"] = max(result["genre_total"], result["keyword_total"])
            result["after_exclusion"] = simulate_exclusion(
                result["union"], head[kind], sizes=(20, 50, 100)
            )
            moods_report[mood][kind] = result
            print(f"  {mood}/{kind}: union {len(result['union'])}, "
                  f"after 100 watched {result['after_exclusion'].get(100)}")

    overlap = {}
    pool = {}
    for kind in TYPES:
        sets = {m: set(moods_report[m][kind]["union"]) for m in MOODS}
        pairs = {}
        names = list(MOODS)
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                score = jaccard(sets[a], sets[b])
                if score > 0:
                    pairs[(a, b)] = (score, len(sets[a] & sets[b]))
        overlap[kind] = pairs
        union_all = set().union(*sets.values()) if sets else set()
        pool[kind] = {"distinct": len(union_all), "sum": sum(len(s) for s in sets.values())}

    report = {
        "keywords_in_use": sorted({
            k for mood in MOODS.values() for spec in mood.values() for k in spec["keywords"]
        }),
        "moods": moods_report,
        "keyword_ids": keyword_ids,
        "keyword_volume": keyword_volume_map,
        "missing_genres": missing_genres,
        "overlap": overlap,
        "pool": pool,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    write_report(report, args.out, client.calls, args.pages)
    print(f"\nWrote {args.out.relative_to(REPO)} ({client.calls} API calls)")

    if args.json:
        dumpable = dict(report)
        dumpable["overlap"] = {
            kind: {f"{a}|{b}": list(v) for (a, b), v in pairs.items()}
            for kind, pairs in report["overlap"].items()
        }
        dumpable["missing_genres"] = {
            f"{mood}|{kind}": names for (mood, kind), names in report["missing_genres"].items()
        }
        args.json.write_text(json.dumps(dumpable, indent=2, default=str))
        print(f"Wrote {args.json}")


if __name__ == "__main__":
    main()
