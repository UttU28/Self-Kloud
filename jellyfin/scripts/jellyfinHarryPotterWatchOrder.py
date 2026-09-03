#!/usr/bin/env python3
"""Wizarding World watch order in Movies (for a collection you create).

Sets Forced Sort Names (HP 01 … HP 11) on titles in media/0movies.
Does not create a Harry Potter folder, library, or collection.

After you make the collection in the dashboard, sort it by Name / Sort title.

Dry run:
  python3 scripts/jellyfinHarryPotterWatchOrder.py

Apply:
  python3 scripts/jellyfinHarryPotterWatchOrder.py --apply
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
import urllib.parse
import urllib.request

from jellyfinScriptEnv import jellyfinGet, jellyfinPost, jellyfinUrl, loadDotEnv, mediaPath

STOPWORDS = {"the", "a", "an", "and"}
VIDEO_EXT = {".mkv", ".mp4", ".m4v", ".avi", ".m2ts"}

# order, title, sortTitle, year, diskTokens, jellyfinAliases
BUILTIN_PLAYLIST = [
    (1, "Fantastic Beasts and Where to Find Them", "HP 01 - Fantastic Beasts and Where to Find Them", 2016, "fantastic beasts where find", ""),
    (2, "Fantastic Beasts: The Crimes of Grindelwald", "HP 02 - Fantastic Beasts The Crimes of Grindelwald", 2018, "crimes grindelwald", ""),
    (3, "Fantastic Beasts: The Secrets of Dumbledore", "HP 03 - Fantastic Beasts The Secrets of Dumbledore", 2022, "secrets dumbledore", ""),
    (4, "Harry Potter and the Sorcerer's Stone", "HP 04 - Harry Potter and the Sorcerer's Stone", 2001, "sorcerer stone", "Harry Potter and the Philosopher's Stone"),
    (5, "Harry Potter and the Chamber of Secrets", "HP 05 - Harry Potter and the Chamber of Secrets", 2002, "chamber secrets", ""),
    (6, "Harry Potter and the Prisoner of Azkaban", "HP 06 - Harry Potter and the Prisoner of Azkaban", 2004, "prisoner azkaban", ""),
    (7, "Harry Potter and the Goblet of Fire", "HP 07 - Harry Potter and the Goblet of Fire", 2005, "goblet fire", ""),
    (8, "Harry Potter and the Order of the Phoenix", "HP 08 - Harry Potter and the Order of the Phoenix", 2007, "order phoenix", ""),
    (9, "Harry Potter and the Half-Blood Prince", "HP 09 - Harry Potter and the Half-Blood Prince", 2009, "half blood prince", ""),
    (10, "Harry Potter and the Deathly Hallows: Part 1", "HP 10 - Harry Potter and the Deathly Hallows Part 1", 2010, "deathly hallows part 1", ""),
    (11, "Harry Potter and the Deathly Hallows: Part 2", "HP 11 - Harry Potter and the Deathly Hallows Part 2", 2011, "deathly hallows part 2", ""),
]


def normalize(title: str) -> str:
    t = title.lower()
    t = t.replace("&", " and ")
    t = t.replace("*", " ")
    t = re.sub(r"[:'\-.,!()\[\]]", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    words = [w for w in t.split() if w not in STOPWORDS]
    return " ".join(words)


def hasPlayableVideoFile(path: str) -> bool:
    name = path.lower()
    return (not name.endswith(".part")) and os.path.splitext(name)[1] in VIDEO_EXT


def isMovieFolder(path: str) -> bool:
    if os.path.isfile(path):
        return hasPlayableVideoFile(path)
    if not os.path.isdir(path):
        return False
    for name in os.listdir(path):
        full = os.path.join(path, name)
        if os.path.isfile(full) and hasPlayableVideoFile(full):
            return True
    return False


def rowFromFields(order, title, sortTitle, year, diskTokens, aliases) -> dict:
    return {
        "order": int(order),
        "title": title.strip(),
        "sort": sortTitle.strip(),
        "year": int(year),
        "norm": normalize(title),
        "diskTokens": normalize(diskTokens).split(),
        "aliases": [
            normalize(alias.strip())
            for alias in aliases.split("|")
            if alias.strip()
        ],
    }


def loadPlaylist(csvPath: str | None) -> list[dict]:
    if not csvPath:
        return [rowFromFields(*row) for row in BUILTIN_PLAYLIST]
    rows = []
    with open(csvPath, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            rows.append(
                rowFromFields(
                    row["Order"],
                    row["Movie Title"],
                    row["Sort Title"],
                    row["Year"],
                    row.get("Disk Tokens") or row["Movie Title"],
                    row.get("Jellyfin Aliases") or "",
                )
            )
    return rows


def jellyfinNames(row: dict) -> set[str]:
    names = {row["norm"], *row["aliases"]}
    return names


def pickJellyfin(row: dict, movies: list[dict]) -> dict | None:
    wanted = jellyfinNames(row)
    hits = [
        movie
        for movie in movies
        if movie["norm"] in wanted and movie["year"] == row["year"]
    ]
    if hits:
        return hits[0]
    return None


def listDiskEntries(directories: list[str]) -> list[dict]:
    entries = []
    seen = set()
    for directory in directories:
        if not os.path.isdir(directory):
            continue
        for root, _dirs, _files in os.walk(directory):
            if not isMovieFolder(root):
                continue
            path = os.path.abspath(root)
            if path in seen:
                continue
            seen.add(path)
            name = os.path.basename(root)
            entries.append(
                {
                    "name": name,
                    "path": path,
                    "dir": os.path.dirname(path),
                    "norm": normalize(name),
                }
            )
    return entries


def pickDisk(row: dict, entries: list[dict]) -> dict | None:
    year = str(row["year"])
    tokens = row["diskTokens"]
    hits = []
    for entry in entries:
        if year not in entry["name"]:
            continue
        if all(token in entry["norm"] for token in tokens):
            hits.append(entry)
    if not hits:
        return None
    hits.sort(key=lambda item: len(item["norm"]))
    return hits[0]


def fetchMovies(url, apiKey, userId) -> list[dict]:
    items = jellyfinGet(
        url,
        apiKey,
        f"/Users/{userId}/Items",
        {
            "IncludeItemTypes": "Movie",
            "Recursive": "true",
            "Fields": "Path,SortName,ForcedSortName,ProductionYear",
        },
    ).get("Items", [])
    movies = []
    for item in items:
        movies.append(
            {
                "id": item["Id"],
                "name": item["Name"],
                "year": item.get("ProductionYear"),
                "path": item.get("Path", ""),
                "norm": normalize(item["Name"]),
            }
        )
    return movies


def main() -> int:
    dotEnv = loadDotEnv()
    hostMedia = mediaPath(dotEnv)
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default=None, help="Optional override; built-in HP list is used by default")
    parser.add_argument("--url", default=jellyfinUrl(dotEnv))
    parser.add_argument("--apiKey", default=dotEnv.get("JELLYFIN_API_KEY"))
    parser.add_argument("--userId", default=dotEnv.get("JELLYFIN_USER_ID"))
    parser.add_argument("--moviesDir", default=f"{hostMedia}/0movies")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    if not args.apiKey:
        print("Set JELLYFIN_API_KEY in selfHosted/jellyfin/.env", file=sys.stderr)
        return 1

    wanted = loadPlaylist(args.csv)
    diskEntries = listDiskEntries([args.moviesDir])

    print("DISK MATCHES (in 0movies/):")
    onDisk = []
    diskMissing = []
    for row in wanted:
        hit = pickDisk(row, diskEntries)
        if not hit:
            diskMissing.append(row)
            print(f"  {row['order']:02d}. {row['title']} ({row['year']})  ->  NOT ON DISK")
            continue
        onDisk.append(hit)
        print(f"  {row['order']:02d}. {row['title']}  ->  {hit['name']}")

    users = jellyfinGet(args.url, args.apiKey, "/Users")
    userId = args.userId or users[0]["Id"]
    movies = fetchMovies(args.url, args.apiKey, userId)

    print()
    print("JELLYFIN TITLE MATCHES (exact name/alias + year):")
    matched = []
    for row in wanted:
        hit = pickJellyfin(row, movies)
        if hit:
            matched.append({**row, "jellyfin": hit})
            print(f"  {row['order']:02d}. {row['title']}  ->  {hit['name']} ({hit['year']})")
        else:
            print(f"  {row['order']:02d}. {row['title']}  ->  not identified yet")

    print()
    print(f"CSV titles: {len(wanted)}")
    print(f"On disk in 0movies/: {len(onDisk)}")
    print(f"Not on disk: {len(diskMissing)} ({', '.join(item['title'] for item in diskMissing) or 'none'})")
    print(f"Jellyfin exact matches now: {len(matched)}")

    if not args.apply:
        print()
        print("Dry run only. Re-run with --apply to set sort names in Movies.")
        return 0

    expected = len(onDisk)
    if expected and len(matched) < expected:
        print("Refreshing Movies library...")
        jellyfinPost(args.url, args.apiKey, "/Library/Refresh")
        print("Waiting for Jellyfin to identify titles...")
        deadline = time.time() + 180
        while time.time() < deadline:
            movies = fetchMovies(args.url, args.apiKey, userId)
            matched = []
            for row in wanted:
                hit = pickJellyfin(row, movies)
                if hit:
                    matched.append({**row, "jellyfin": hit})
            print(f"  identified {len(matched)}/{expected}")
            if len(matched) >= expected:
                break
            time.sleep(5)

    if not matched:
        print("Scan finished but no titles matched.", file=sys.stderr)
        return 1

    for row in matched:
        try:
            item = jellyfinGet(
                args.url,
                args.apiKey,
                f"/Users/{userId}/Items/{row['jellyfin']['id']}",
            )
        except urllib.error.HTTPError as exc:
            print(f"  skip ({exc.code}): {row['title']}")
            continue
        item["ForcedSortName"] = row["sort"]
        item["SortName"] = row["sort"]
        try:
            jellyfinPost(args.url, args.apiKey, f"/Items/{row['jellyfin']['id']}", body=item)
        except urllib.error.HTTPError as exc:
            print(f"  skip save ({exc.code}): {row['title']}")
            continue
        print(f"  sort name -> {row['sort']}")

    stillMissing = [
        row["title"]
        for row in wanted
        if row["order"] not in {item["order"] for item in matched}
        and row["order"] not in {item["order"] for item in diskMissing}
    ]
    if stillMissing:
        print("Still not identified:", ", ".join(stillMissing))

    print("\nDone. Make (or open) your Harry Potter collection and sort by Name / Sort title.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except urllib.error.HTTPError as exc:
        print(exc.read().decode(), file=sys.stderr)
        raise
