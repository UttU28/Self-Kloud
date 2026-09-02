#!/usr/bin/env python3
"""MCU watch order for Jellyfin, plus Sony/Spider-Verse films at the end.

MCU titles use MCU 01, MCU 02, ... so new sequels stay in sequence.
Non-MCU Spider-Man films use ZZ 01, ZZ 02, ... so they always sort last
when the Marvel library is ordered by Sort title.

Playlist is built in (no CSV). Skips incomplete .part files.

Dry run:
  python3 scripts/jellyfinMarvelWatchOrder.py

Apply:
  python3 scripts/jellyfinMarvelWatchOrder.py --apply
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from jellyfinScriptEnv import jellyfinUrl, loadDotEnv, mediaPath

STOPWORDS = {"the", "a", "an", "and"}
VIDEO_EXT = {".mkv", ".mp4", ".m4v", ".avi", ".m2ts"}

# order, title, sortTitle, year, diskTokens, jellyfinAliases
# ZZ* sorts after every MCU NN title, even after MCU 38/39 are added later.
BUILTIN_PLAYLIST = [
    (1, "Captain America: The First Avenger", "MCU 01 - Captain America The First Avenger", 2011, "first avenger", ""),
    (2, "Captain Marvel", "MCU 02 - Captain Marvel", 2019, "captain marvel", ""),
    (3, "Iron Man", "MCU 03 - Iron Man", 2008, "iron man", ""),
    (4, "Iron Man 2", "MCU 04 - Iron Man 2", 2010, "iron man 2", ""),
    (5, "The Incredible Hulk", "MCU 05 - The Incredible Hulk", 2008, "incredible hulk", ""),
    (6, "Thor", "MCU 06 - Thor", 2011, "thor", ""),
    (7, "The Avengers", "MCU 07 - The Avengers", 2012, "avengers", ""),
    (8, "Iron Man 3", "MCU 08 - Iron Man 3", 2013, "iron man 3", ""),
    (9, "Thor: The Dark World", "MCU 09 - Thor The Dark World", 2013, "thor dark world", ""),
    (10, "Captain America: The Winter Soldier", "MCU 10 - Captain America The Winter Soldier", 2014, "winter soldier", ""),
    (11, "Guardians of the Galaxy", "MCU 11 - Guardians of the Galaxy", 2014, "guardians galaxy", ""),
    (12, "Guardians of the Galaxy Vol. 2", "MCU 12 - Guardians of the Galaxy Vol. 2", 2017, "guardians galaxy vol 2", ""),
    (13, "Avengers: Age of Ultron", "MCU 13 - Avengers Age of Ultron", 2015, "age of ultron", ""),
    (14, "Ant-Man", "MCU 14 - Ant-Man", 2015, "ant man", ""),
    (15, "Captain America: Civil War", "MCU 15 - Captain America Civil War", 2016, "civil war", ""),
    (16, "Black Widow", "MCU 16 - Black Widow", 2021, "black widow", ""),
    (17, "Spider-Man: Homecoming", "MCU 17 - Spider-Man Homecoming", 2017, "homecoming", ""),
    (18, "Black Panther", "MCU 18 - Black Panther", 2018, "black panther", ""),
    (19, "Doctor Strange", "MCU 19 - Doctor Strange", 2016, "doctor strange", ""),
    (20, "Thor: Ragnarok", "MCU 20 - Thor Ragnarok", 2017, "ragnarok", ""),
    (21, "Ant-Man and the Wasp", "MCU 21 - Ant-Man and the Wasp", 2018, "ant man wasp", ""),
    (22, "Avengers: Infinity War", "MCU 22 - Avengers Infinity War", 2018, "infinity war", ""),
    (23, "Avengers: Endgame", "MCU 23 - Avengers Endgame", 2019, "endgame", ""),
    (24, "Spider-Man: Far From Home", "MCU 24 - Spider-Man Far From Home", 2019, "far from home", ""),
    (25, "Eternals", "MCU 25 - Eternals", 2021, "eternals", ""),
    (26, "Shang-Chi and the Legend of the Ten Rings", "MCU 26 - Shang-Chi and the Legend of the Ten Rings", 2021, "shang chi", ""),
    (27, "Spider-Man: No Way Home", "MCU 27 - Spider-Man No Way Home", 2021, "no way home", ""),
    (28, "Doctor Strange in the Multiverse of Madness", "MCU 28 - Doctor Strange in the Multiverse of Madness", 2022, "multiverse of madness", ""),
    (29, "Thor: Love and Thunder", "MCU 29 - Thor Love and Thunder", 2022, "love and thunder", ""),
    (30, "Black Panther: Wakanda Forever", "MCU 30 - Black Panther Wakanda Forever", 2022, "wakanda forever", ""),
    (31, "Ant-Man and the Wasp: Quantumania", "MCU 31 - Ant-Man and the Wasp Quantumania", 2023, "quantumania", ""),
    (32, "Guardians of the Galaxy Vol. 3", "MCU 32 - Guardians of the Galaxy Vol. 3", 2023, "guardians galaxy vol 3", ""),
    (33, "The Marvels", "MCU 33 - The Marvels", 2023, "marvels", ""),
    (34, "Deadpool & Wolverine", "MCU 34 - Deadpool & Wolverine", 2024, "deadpool wolverine", ""),
    (35, "Captain America: Brave New World", "MCU 35 - Captain America Brave New World", 2025, "brave new world", ""),
    (36, "Thunderbolts*", "MCU 36 - Thunderbolts", 2025, "thunderbolts", "Thunderbolts"),
    (37, "The Fantastic Four: First Steps", "MCU 37 - The Fantastic Four First Steps", 2025, "fantastic 4 first steps", "The Fantastic 4: First Steps"),
    (38, "Spider-Man: Brand New Day", "MCU 38 - Spider-Man Brand New Day", 2026, "brand new day", ""),
    (39, "Avengers: Doomsday", "MCU 39 - Avengers Doomsday", 2026, "doomsday", ""),
    (40, "Spider-Man", "ZZ 01 - Spider-Man", 2002, "spider man", ""),
    (41, "Spider-Man 2", "ZZ 02 - Spider-Man 2", 2004, "spider man 2", ""),
    (42, "Spider-Man 3", "ZZ 03 - Spider-Man 3", 2007, "spider man 3", ""),
    (43, "The Amazing Spider-Man", "ZZ 04 - The Amazing Spider-Man", 2012, "amazing spider man", ""),
    (44, "The Amazing Spider-Man 2", "ZZ 05 - The Amazing Spider-Man 2", 2014, "amazing spider man 2", ""),
    (45, "Spider-Man: Into the Spider-Verse", "ZZ 06 - Spider-Man Into the Spider-Verse", 2018, "into spider verse", ""),
    (46, "Spider-Man: Across the Spider-Verse", "ZZ 07 - Spider-Man Across the Spider-Verse", 2023, "across spider verse", ""),
]


def normalize(title: str) -> str:
    t = title.lower()
    t = t.replace("&", " and ")
    t = t.replace("*", " ")
    t = re.sub(r"[:'\-.,!()\[\]]", " ", t)
    t = re.sub(r"\bfour\b", "4", t)
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


def jellyfinRequest(url, apiKey, path, method="GET", params=None, body=None):
    query = urllib.parse.urlencode(params or {}, doseq=True)
    full = f"{url.rstrip('/')}{path}" + (f"?{query}" if query else "")
    data = None if body is None else json.dumps(body).encode()
    headers = {"X-Emby-Token": apiKey, "Accept": "application/json"}
    if data is not None or method != "GET":
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(full, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req) as resp:
        raw = resp.read()
        if not raw:
            return None
        return json.loads(raw.decode())


def jellyfinGet(url, apiKey, path, params=None):
    return jellyfinRequest(url, apiKey, path, "GET", params)


def jellyfinPost(url, apiKey, path, params=None, body=None):
    return jellyfinRequest(url, apiKey, path, "POST", params, body)


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


def pickJellyfin(row: dict, movies: list[dict], preferFragment: str = "/media/marvel") -> dict | None:
    wanted = jellyfinNames(row)
    hits = [
        movie
        for movie in movies
        if movie["norm"] in wanted and movie["year"] == row["year"]
    ]
    if not hits:
        return None
    prefer = [movie for movie in hits if preferFragment in (movie["path"] or "")]
    return (prefer or hits)[0]


def pickDisk(row: dict, entries: list[dict], preferDir: str | None = None) -> dict | None:
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
    preferAbs = os.path.abspath(preferDir) if preferDir else None

    def score(entry: dict) -> tuple:
        inPrefer = 0 if preferAbs and os.path.abspath(entry["dir"]) == preferAbs else 1
        return (inPrefer, len(entry["norm"]))

    hits.sort(key=score)
    return hits[0]


def listDiskEntries(directories: list[str]) -> list[dict]:
    entries = []
    seen = set()
    libraryRoots = {os.path.abspath(path) for path in directories}

    def addEntry(path: str, name: str) -> None:
        path = os.path.abspath(path)
        if path in seen:
            return
        seen.add(path)
        entries.append(
            {
                "name": name,
                "path": path,
                "dir": os.path.dirname(path),
                "norm": normalize(name),
            }
        )

    for directory in directories:
        if not os.path.isdir(directory):
            continue
        for root, _dirs, files in os.walk(directory):
            absRoot = os.path.abspath(root)
            if absRoot in libraryRoots:
                for filename in files:
                    full = os.path.join(absRoot, filename)
                    if hasPlayableVideoFile(full):
                        addEntry(full, filename)
                continue
            if isMovieFolder(absRoot):
                addEntry(absRoot, os.path.basename(absRoot))
    return entries


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


def removeEmptyParents(path: str, stopDir: str) -> None:
    current = os.path.abspath(path)
    stop = os.path.abspath(stopDir)
    while current.startswith(stop) and current != stop:
        try:
            os.rmdir(current)
        except OSError:
            return
        current = os.path.dirname(current)


def main() -> int:
    dotEnv = loadDotEnv()
    hostMedia = mediaPath(dotEnv)
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", default=None, help="Unused; playlist is built in")
    parser.add_argument("--url", default=jellyfinUrl(dotEnv))
    parser.add_argument("--apiKey", default=dotEnv.get("JELLYFIN_API_KEY"))
    parser.add_argument("--userId", default=dotEnv.get("JELLYFIN_USER_ID"))
    parser.add_argument("--moviesDir", default=f"{hostMedia}/movies")
    parser.add_argument(
        "--marvelDir",
        default=f"{hostMedia}/marvel",
    )
    parser.add_argument(
        "--jellyfinMarvelPath",
        default="/media/marvel",
        help="Path inside the Jellyfin container",
    )
    parser.add_argument("--libraryName", default="Marvel")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    if not args.apiKey:
        print("Set JELLYFIN_API_KEY in selfHosted/jellyfin/.env", file=sys.stderr)
        return 1

    wanted = loadPlaylist(None)
    os.makedirs(args.marvelDir, exist_ok=True)
    diskEntries = listDiskEntries([args.moviesDir, args.marvelDir])

    print("DISK MATCHES (move plan):")
    moves = []
    already = []
    diskMissing = []
    for row in wanted:
        hit = pickDisk(row, diskEntries, preferDir=args.marvelDir)
        if not hit:
            diskMissing.append(row)
            print(f"  {row['order']:02d}. {row['title']} ({row['year']})  ->  NOT ON DISK")
            continue
        dest = os.path.join(args.marvelDir, hit["name"])
        if os.path.abspath(os.path.dirname(hit["path"])) == os.path.abspath(args.marvelDir):
            already.append(hit)
            print(f"  {row['order']:02d}. {row['title']}  ->  already in marvel/{hit['name']}")
        else:
            moves.append((hit["path"], dest, row))
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

    folders = jellyfinGet(args.url, args.apiKey, "/Library/VirtualFolders") or []
    libraryExists = any(
        folder.get("Name") == args.libraryName
        or args.jellyfinMarvelPath in (folder.get("Locations") or [])
        for folder in folders
    )

    print()
    print(f"CSV titles: {len(wanted)}")
    print(f"On disk (will use): {len(moves) + len(already)}")
    print(f"Would move: {len(moves)}")
    print(f"Already in marvel/: {len(already)}")
    print(f"Not on disk: {len(diskMissing)} ({', '.join(item['title'] for item in diskMissing) or 'none'})")
    print(f"Jellyfin exact matches now: {len(matched)}")
    print(f"Marvel library exists: {libraryExists}")

    if not args.apply:
        print()
        print("Dry run only. Re-run with --apply to move files, add the library, and set sort names.")
        return 0

    for src, dest, _row in moves:
        print(f"Moving {os.path.basename(src)}")
        shutil.move(src, dest)
        removeEmptyParents(os.path.dirname(src), args.moviesDir)

    if not libraryExists:
        print(f"Adding Jellyfin library '{args.libraryName}' -> {args.jellyfinMarvelPath}")
        jellyfinPost(
            args.url,
            args.apiKey,
            "/Library/VirtualFolders",
            params={
                "name": args.libraryName,
                "collectionType": "movies",
                "paths": args.jellyfinMarvelPath,
                "refreshLibrary": "true",
            },
        )
    elif moves:
        print("Refreshing library after moves.")
        jellyfinPost(args.url, args.apiKey, "/Library/Refresh")

    expected = len(moves) + len(already)
    print("Waiting for Jellyfin to identify Marvel movies...")
    deadline = time.time() + 180
    while time.time() < deadline:
        movies = fetchMovies(args.url, args.apiKey, userId)
        matched = []
        for row in wanted:
            hit = pickJellyfin(row, movies)
            if hit:
                matched.append({**row, "jellyfin": hit})
        onMarvel = sum(
            1
            for row in matched
            if "/marvel/" in (row["jellyfin"]["path"] or "")
        )
        print(f"  identified {len(matched)}/{expected} ({onMarvel} in /media/marvel)")
        if len(matched) >= expected and onMarvel >= expected:
            break
        time.sleep(5)

    movies = fetchMovies(args.url, args.apiKey, userId)
    matched = []
    for row in wanted:
        hit = pickJellyfin(row, movies)
        if hit:
            matched.append({**row, "jellyfin": hit})

    if not matched:
        print("Scan finished but no titles matched.", file=sys.stderr)
        return 1

    for row in matched:
        itemId = row["jellyfin"]["id"]
        try:
            item = jellyfinGet(
                args.url,
                args.apiKey,
                f"/Users/{userId}/Items/{itemId}",
            )
        except urllib.error.HTTPError as exc:
            movies = fetchMovies(args.url, args.apiKey, userId)
            hit = pickJellyfin(row, movies)
            if not hit:
                print(f"  skip ({exc.code}): {row['title']}")
                continue
            itemId = hit["id"]
            try:
                item = jellyfinGet(
                    args.url,
                    args.apiKey,
                    f"/Users/{userId}/Items/{itemId}",
                )
            except urllib.error.HTTPError as exc2:
                print(f"  skip ({exc2.code}): {row['title']}")
                continue
        item["ForcedSortName"] = row["sort"]
        item["SortName"] = row["sort"]
        try:
            jellyfinPost(args.url, args.apiKey, f"/Items/{itemId}", body=item)
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

    print("\nDone. Open the Marvel library and sort by Name / Sort title.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except urllib.error.HTTPError as exc:
        print(exc.read().decode(), file=sys.stderr)
        raise
