#!/usr/bin/env python3
"""
Build an offline evaluation fixture for the Binged recommender.

Real ratings (MovieLens ml-latest-small: 610 users, 100k ratings) joined to real
TMDB metadata, so the evaluation measures the recommender against what actual
people preferred rather than against a taste model we invented ourselves.

Writes two files:
  titles.json  { "<tmdbId>": <raw TMDB detail response with credits+keywords> }
  users.json   [ { "user": 1, "ratings": [[tmdbId, stars], ...] }, ... ]
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

API = "https://api.themoviedb.org/3"


def read_token() -> str:
    token = os.environ.get("TMDB_READ_TOKEN")
    if token:
        return token.strip()
    secrets = Path("Binged/Config/Secrets.xcconfig")
    if secrets.exists():
        for line in secrets.read_text().splitlines():
            m = re.match(r"\s*TMDB_READ_TOKEN\s*=\s*(\S+)", line)
            if m:
                return m.group(1).strip()
    sys.exit("no TMDB_READ_TOKEN in env or Binged/Config/Secrets.xcconfig")


def fetch(tmdb_id: int, token: str, attempts: int = 4) -> dict | None:
    url = f"{API}/movie/{tmdb_id}?append_to_response=credits,keywords"
    request = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {token}", "Accept": "application/json"}
    )
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            time.sleep(1.5 * (attempt + 1))
        except Exception:
            time.sleep(1.5 * (attempt + 1))
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--titles", type=int, default=2000)
    parser.add_argument("--min-user-ratings", type=int, default=30)
    parser.add_argument("--data", default="ml-latest-small")
    parser.add_argument("--out", default=".")
    args = parser.parse_args()

    data = Path(args.data)
    out = Path(args.out)

    counts: Counter[int] = Counter()
    rows: list[tuple[int, int, float]] = []
    with open(data / "ratings.csv", newline="") as handle:
        for row in csv.DictReader(handle):
            movie = int(row["movieId"])
            counts[movie] += 1
            rows.append((int(row["userId"]), movie, float(row["rating"])))

    keep = {movie for movie, _ in counts.most_common(args.titles)}

    links: dict[int, int] = {}
    with open(data / "links.csv", newline="") as handle:
        for row in csv.DictReader(handle):
            movie = int(row["movieId"])
            if movie in keep and row["tmdbId"]:
                links[movie] = int(row["tmdbId"])

    token = read_token()
    ids = sorted(set(links.values()))
    print(f"fetching {len(ids)} titles from TMDB…", flush=True)

    titles: dict[str, dict] = {}
    cache = out / "titles.json"
    if cache.exists():
        titles = json.loads(cache.read_text())
        print(f"  {len(titles)} already cached", flush=True)

    todo = [i for i in ids if str(i) not in titles]
    done = 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        for tmdb_id, payload in zip(todo, pool.map(lambda i: fetch(i, token), todo)):
            done += 1
            if payload:
                titles[str(tmdb_id)] = payload
            if done % 200 == 0:
                print(f"  {done}/{len(todo)}", flush=True)
    cache.write_text(json.dumps(titles))

    available = {int(k) for k in titles}
    by_user: dict[int, list[tuple[int, float]]] = defaultdict(list)
    for user, movie, stars in rows:
        tmdb_id = links.get(movie)
        if tmdb_id in available:
            by_user[user].append((tmdb_id, stars))

    users = [
        {"user": user, "ratings": sorted(pairs)}
        for user, pairs in sorted(by_user.items())
        if len(pairs) >= args.min_user_ratings
    ]
    (out / "users.json").write_text(json.dumps(users))

    sizes = sorted(len(u["ratings"]) for u in users)
    print(f"titles: {len(titles)}  users: {len(users)}")
    print(
        "library size — min %d  median %d  max %d"
        % (sizes[0], sizes[len(sizes) // 2], sizes[-1])
    )


if __name__ == "__main__":
    main()
