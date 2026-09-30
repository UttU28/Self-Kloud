#!/usr/bin/env python3
"""Identify unidentified movies in the Parvati Nambyar Jellyfin library.

YouTube downloads keep the video title as the filename. Jellyfin matches some of
those on its own. This script skips anything that already has an IMDb or TMDb id,
turns the remaining title into a movie name, and applies the Jellyfin remote match.

  python3 parvatiNambyarIdentify.py
  python3 parvatiNambyarIdentify.py --dry-run
  python3 parvatiNambyarIdentify.py --folder /path/to/new/movie
"""

from __future__ import annotations

import argparse
import fcntl
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from jellyfinScriptEnv import jellyfinGet, jellyfinPost, jellyfinUrl, loadDotEnv, mediaPath

LIBRARY_KEYS = {"parvatinambyar", "parvatinambiar", "parwatinambyar", "parwatinambiar"}
ID_KEYS = ("Imdb", "Tmdb", "Tvdb")
MIN_SCORE = 90
EXACT_SCORE = 100
COLLAPSE_SCORE = 94

CUT_RE = re.compile(
    r"""
    \(\s*hd\s*\) | \{\s*hd\s*\} | \[\s*hd\s*\] |
    \b(?:2160|1440|1080|720|480)p\b |
    \bfull\s+hd\b |
    \bhindi\s+full\b |
    \bhindi\s+movies?\b |
    \bhindi\s+comedy\b |
    \bcomedy\s+movies?\b |
    \bsuper\s*hit\b |
    \bblockbuster\b |
    \bwith\s+(?:english\s+)?subtitles\b |
    \boriginal\s+print\b |
    \bbollywood\b |
    \bbluray\b | \bwebrip\b | \buhd\b |
    \bhd\b |
    \bfull\b
    """,
    re.IGNORECASE | re.VERBOSE,
)
YEAR_RE = re.compile(r"\b(19\d{2}|20[0-3]\d)\b")
YOUTUBE_ID_RE = re.compile(r"\s*\[[A-Za-z0-9_-]{11}\]\s*$")
CAST_CACHE: dict[str, set[str]] = {}

HINT_DROP = {
    "a", "an", "and", "the", "of", "in", "on", "for", "to", "by", "with", "from",
    "full", "movie", "movies", "film", "films", "hindi", "comedy", "hd", "uhd",
    "bollywood", "best", "latest", "original", "print", "blockbuster", "superhit",
    "super", "hit", "subtitles", "english", "official", "review", "facts", "video",
    "youtube", "starring", "presents", "new", "all", "time", "classic", "emotional",
    "part", "parts", "uncut", "dubbed", "dual", "audio", "org", "originalprint",
}
GENERIC_WORDS = HINT_DROP | {"comedy", "drama", "action", "romance"}


def compact(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


def collapsed(value: str) -> str:
    return re.sub(r"(.)\1+", r"\1", compact(value))


def short(value: str, limit: int = 78) -> str:
    text = re.sub(r"\s+", " ", value).strip()
    if len(text) <= limit:
        return text
    return text[: limit - 3].rstrip() + "..."


def sourceTitle(item: dict) -> str:
    path = str(item.get("Path") or "")
    name = path.rsplit("/", 1)[-1]
    stem = re.sub(r"\.[A-Za-z0-9]{1,5}$", "", name)
    return stem or str(item.get("Name") or "")


def parseTitle(raw: str) -> tuple[str, int | None, str]:
    text = YOUTUBE_ID_RE.sub("", raw)
    text = text.replace("｜", "|").replace("：", ":").replace("…", " ")
    text = re.sub(r"#\w+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()

    cut = len(text)
    match = CUT_RE.search(text)
    if match:
        cut = min(cut, match.start())
    pipe = text.find("|")
    if pipe != -1:
        cut = min(cut, pipe)

    head = text[:cut]
    tail = text[cut:]
    year = None
    yearMatch = YEAR_RE.search(head)
    if yearMatch:
        year = int(yearMatch.group(1))
        head = f"{head[:yearMatch.start()]} {head[yearMatch.end():]}"

    head = re.sub(r"[\u0900-\u097F]+", " ", head)
    head = re.sub(r"[^\w\s:'&-]", " ", head, flags=re.UNICODE)
    head = re.sub(r"\s+", " ", head).strip(" -:_|&")
    if not re.search(r"\bthe movie$", head, re.IGNORECASE):
        head = re.sub(r"\s+movies?$", "", head, flags=re.IGNORECASE).strip()
    return head, year, tail


def usableName(name: str) -> bool:
    words = [word for word in re.findall(r"[A-Za-z0-9]+", name) if word]
    if len("".join(words)) < 3:
        return False
    return any(word.lower() not in GENERIC_WORDS for word in words)


def hintText(tail: str) -> str:
    tail = re.sub(r"[\u0900-\u097F]+", " ", tail)
    kept: list[str] = []
    for word in re.findall(r"[A-Za-z][A-Za-z.']*", tail):
        word = re.sub(r"'s$", "", word, flags=re.IGNORECASE)
        if word.lower() in HINT_DROP or len(word) < 3:
            continue
        kept.append(word)
    return " ".join(kept[:8])


def namesMatch(left: str, right: str) -> bool:
    if not left or not right:
        return False
    if compact(left) == compact(right):
        return True
    return collapsed(left) == collapsed(right)


def titleScore(query: str, candidate: str) -> int:
    if compact(query) == compact(candidate):
        return EXACT_SCORE
    if collapsed(query) == collapsed(candidate):
        return COLLAPSE_SCORE
    return 0


def alreadyIdentified(item: dict) -> bool:
    providerIds = item.get("ProviderIds") or {}
    return any(providerIds.get(key) for key in ID_KEYS)


def findLibrary(url: str, apiKey: str) -> dict:
    folders = jellyfinGet(url, apiKey, "/Library/MediaFolders") or {}
    for item in folders.get("Items") or []:
        key = re.sub(r"[^a-z0-9]", "", str(item.get("Name") or "").lower())
        path = re.sub(r"[^a-z0-9]", "", str(item.get("Path") or "").lower())
        if key in LIBRARY_KEYS or "parvatinambyar" in path or "parwatinambyar" in path:
            return item
    raise SystemExit("Parvati Nambyar library was not found in Jellyfin.")


def libraryMovies(url: str, apiKey: str, libraryId: str) -> list[dict]:
    data = jellyfinGet(
        url,
        apiKey,
        "/Items",
        {
            "ParentId": libraryId,
            "Recursive": "true",
            "IncludeItemTypes": "Movie",
            "Fields": "ProviderIds,Path,ProductionYear",
            "Limit": "1000",
        },
    ) or {}
    movies = list(data.get("Items") or [])
    movies.sort(key=lambda item: sourceTitle(item).lower())
    return movies


def searchMovies(url: str, apiKey: str, name: str) -> list[dict]:
    body = {"SearchInfo": {"Name": name, "ProviderIds": {}}, "IncludeDisabledProviders": False}
    results = jellyfinPost(url, apiKey, "/Items/RemoteSearch/Movie", body=body) or []
    return [result for result in results if result.get("Name")]


def loadTmdbKey() -> str:
    path = Path(__file__).resolve().parents[2] / (
        "jellyfin-packaging/jellyfin-server/MediaBrowser.Providers/Plugins/Tmdb/TmdbUtils.cs"
    )
    if not path.is_file():
        return ""
    match = re.search(r'ApiKey = "([0-9a-f]{32})"', path.read_text(encoding="utf-8"))
    return match.group(1) if match else ""


def tmdbGet(tmdbKey: str, path: str, params: dict | None = None) -> dict:
    query = dict(params or {})
    query["api_key"] = tmdbKey
    request = urllib.request.Request(
        "https://api.themoviedb.org/3" + path + "?" + urllib.parse.urlencode(query),
        headers={"Accept": "application/json", "User-Agent": "parvatiNambyarIdentify/1.0"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode())


def tmdbIdFor(tmdbKey: str, result: dict) -> str:
    providerIds = result.setdefault("ProviderIds", {})
    tmdbId = str(providerIds.get("Tmdb") or "")
    if tmdbId or not tmdbKey:
        return tmdbId
    imdbId = str(providerIds.get("Imdb") or "")
    if not imdbId:
        return ""
    try:
        found = tmdbGet(tmdbKey, f"/find/{imdbId}", {"external_source": "imdb_id"})
    except (urllib.error.URLError, TimeoutError, OSError):
        return ""
    movies = found.get("movie_results") or []
    if not movies:
        return ""
    tmdbId = str(movies[0].get("id") or "")
    if tmdbId:
        providerIds["Tmdb"] = tmdbId
    return tmdbId


def castTokens(tmdbKey: str, tmdbId: str) -> set[str]:
    if tmdbId in CAST_CACHE:
        return CAST_CACHE[tmdbId]
    try:
        credits = tmdbGet(tmdbKey, f"/movie/{tmdbId}/credits")
    except (urllib.error.URLError, TimeoutError, OSError):
        CAST_CACHE[tmdbId] = set()
        return CAST_CACHE[tmdbId]
    tokens: set[str] = set()
    for person in (credits.get("cast") or [])[:12]:
        tokens.update(word.lower() for word in re.findall(r"[A-Za-z]{3,}", person.get("name") or ""))
    CAST_CACHE[tmdbId] = tokens
    return tokens


def hintTokens(hint: str) -> set[str]:
    return {word.lower() for word in hint.split() if len(word) >= 3}


def peopleFromHint(hint: str) -> list[str]:
    words = hint.split()
    return [f"{words[index]} {words[index + 1]}" for index in range(0, len(words) - 1, 2)]


def movieFromPeople(tmdbKey: str, hint: str) -> dict | None:
    people = peopleFromHint(hint)
    if len(people) < 2 or not tmdbKey:
        return None
    shared: set[int] | None = None
    movies: dict[int, dict] = {}
    for person in people[:3]:
        try:
            found = tmdbGet(tmdbKey, "/search/person", {"query": person}).get("results") or []
            if not found:
                return None
            credits = tmdbGet(tmdbKey, f"/person/{found[0]['id']}/movie_credits")
        except (urllib.error.URLError, TimeoutError, OSError, KeyError):
            return None
        ids: set[int] = set()
        for movie in credits.get("cast") or []:
            movieId = movie.get("id")
            if not isinstance(movieId, int):
                continue
            ids.add(movieId)
            movies[movieId] = movie
        shared = ids if shared is None else shared & ids
    if not shared or len(shared) != 1:
        return None
    movie = movies[shared.pop()]
    release = str(movie.get("release_date") or "")
    year = int(release[:4]) if len(release) >= 4 and release[:4].isdigit() else None
    return {
        "Name": movie.get("title") or movie.get("original_title"),
        "ProductionYear": year,
        "ProviderIds": {"Tmdb": str(movie.get("id"))},
        "SearchProviderName": "TheMovieDb",
    }


def pickByCast(tmdbKey: str, hint: str, results: list[dict]) -> tuple[dict | None, str]:
    tokens = hintTokens(hint)
    if len(tokens) < 2 or not tmdbKey:
        return None, ""
    scored: list[tuple[int, dict]] = []
    for result in results:
        tmdbId = tmdbIdFor(tmdbKey, result)
        overlap = len(tokens & castTokens(tmdbKey, tmdbId)) if tmdbId else 0
        scored.append((overlap, result))
    scored.sort(key=lambda pair: pair[0], reverse=True)
    best = scored[0][0]
    second = scored[1][0] if len(scored) > 1 else 0
    if best >= 2 and best >= second + 2:
        return scored[0][1], f"cast {best}"
    return None, ""


def movieKey(result: dict) -> tuple[str, int | None]:
    return compact(result.get("Name") or ""), result.get("ProductionYear")


def preferDated(results: list[dict]) -> list[dict]:
    datedNames = {compact(result.get("Name") or "") for result in results if result.get("ProductionYear")}
    kept = [
        result
        for result in results
        if result.get("ProductionYear") or compact(result.get("Name") or "") not in datedNames
    ]
    return kept or results


def gatherCandidates(url: str, apiKey: str, name: str) -> list[dict]:
    results = searchMovies(url, apiKey, name)
    folded = collapsed(name)
    if folded and folded != compact(name):
        spaced = re.sub(r"(.)\1+", r"\1", name, flags=re.IGNORECASE)
        if spaced.lower() != name.lower():
            results = results + searchMovies(url, apiKey, spaced)
    seen: set[tuple[str, int | None, str]] = set()
    unique: list[dict] = []
    for result in results:
        key = (compact(result.get("Name") or ""), result.get("ProductionYear"), str((result.get("ProviderIds") or {}).get("Tmdb") or (result.get("ProviderIds") or {}).get("Imdb") or ""))
        if key in seen:
            continue
        seen.add(key)
        unique.append(result)
    return unique


def chooseMatch(url: str, apiKey: str, tmdbKey: str, name: str, year: int | None, hint: str) -> tuple[dict | None, str]:
    candidates = gatherCandidates(url, apiKey, name)
    if year:
        dated = [result for result in candidates if result.get("ProductionYear") == year]
        if not dated:
            return None, f'no match for "{name}" ({year})'
        candidates = dated

    scored = [(titleScore(name, result.get("Name") or ""), result) for result in candidates]
    scored = [(score, result) for score, result in scored if score >= MIN_SCORE]
    if not scored:
        return None, f'no close match for "{name}"'

    best = max(score for score, _result in scored)
    top = preferDated([result for score, result in scored if score == best])
    distinct = []
    seenKeys: set[tuple[str, int | None]] = set()
    for result in top:
        key = movieKey(result)
        if key in seenKeys:
            continue
        seenKeys.add(key)
        distinct.append(result)

    if len(distinct) > 1:
        winner, note = pickByCast(tmdbKey, hint, distinct)
        if winner is None:
            options = ", ".join(describe(result) for result in distinct)
            return None, f"several matches: {options}"
        distinct = [winner]
    else:
        note = ""

    winner = distinct[0]
    sameMovie = [
        result
        for result in top
        if result.get("ProductionYear") == winner.get("ProductionYear") and namesMatch(result.get("Name") or "", winner.get("Name") or "")
    ]
    return mergeProviders(sameMovie or [winner]), note


def describe(result: dict) -> str:
    year = result.get("ProductionYear")
    name = result.get("Name") or "?"
    return f"{name} ({year})" if year else name


def mergeProviders(results: list[dict]) -> dict:
    ordered = sorted(results, key=lambda result: 0 if "moviedb" in str(result.get("SearchProviderName") or "").lower() else 1)
    chosen = dict(ordered[0])
    providerIds: dict[str, str] = {}
    for result in ordered:
        for key, value in (result.get("ProviderIds") or {}).items():
            if value and key not in providerIds:
                providerIds[key] = str(value)
    chosen["ProviderIds"] = providerIds
    return chosen


def applyMatch(url: str, apiKey: str, itemId: str, match: dict) -> None:
    jellyfinPost(
        url,
        apiKey,
        f"/Items/RemoteSearch/Apply/{itemId}",
        params={"replaceAllImages": "true"},
        body=match,
    )


def confirmMatch(url: str, apiKey: str, itemId: str) -> dict | None:
    # GET /Items/{id} throws "Guid can't be empty" for an API key with no user.
    data = jellyfinGet(
        url,
        apiKey,
        "/Items",
        {"Ids": itemId, "Fields": "ProviderIds,ProductionYear", "Limit": "1"},
    ) or {}
    updated = (data.get("Items") or [None])[0]
    if not updated or not alreadyIdentified(updated):
        return None
    return updated


def jellyfinFolderPath(hostPath: str, dotEnv: dict[str, str]) -> str:
    root = Path(mediaPath(dotEnv)).resolve()
    path = Path(hostPath)
    try:
        relative = path.resolve().relative_to(root)
    except ValueError:
        return hostPath
    return "/media/" + relative.as_posix()


def notifyJellyfin(url: str, apiKey: str, jellyfinPath: str) -> None:
    jellyfinPost(
        url,
        apiKey,
        "/Library/Media/Updated",
        body={"Updates": [{"Path": jellyfinPath, "UpdateType": "Created"}]},
    )


def waitForFolder(url: str, apiKey: str, libraryId: str, jellyfinPath: str, timeoutSec: float = 90) -> bool:
    needle = jellyfinPath.rstrip("/")
    folderName = Path(needle).name
    deadline = time.time() + timeoutSec
    notifiedRefresh = False
    while time.time() < deadline:
        for item in libraryMovies(url, apiKey, libraryId):
            path = str(item.get("Path") or "")
            if path == needle or path.startswith(needle + "/") or folderName in path:
                return True
        if not notifiedRefresh and deadline - time.time() < timeoutSec - 20:
            notifiedRefresh = True
            try:
                jellyfinPost(url, apiKey, "/Library/Refresh")
            except urllib.error.HTTPError:
                pass
        time.sleep(3)
    return False


def holdLock():
    handle = open("/tmp/parvatiNambyarIdentify.lock", "a", encoding="utf-8")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    return handle


def report(status: str, message: str) -> None:
    print(f"{status:<8} {message}", flush=True)


def identifyItem(url: str, apiKey: str, tmdbKey: str, item: dict, dryRun: bool) -> str:
    title = sourceTitle(item)
    if alreadyIdentified(item):
        year = item.get("ProductionYear")
        label = item.get("Name") or title
        shown = f"{label} ({year})" if year else str(label)
        report("SKIP", f"{shown}  already identified")
        return "skip"

    name, year, tail = parseTitle(title)
    hint = hintText(tail)
    castNote = ""
    match = None
    note = ""
    if not usableName(name):
        match = movieFromPeople(tmdbKey, hint)
        if match is None:
            report("FAIL", f"{short(title)}  could not read a movie name")
            return "fail"
        castNote = "cast lookup"
    else:
        try:
            match, note = chooseMatch(url, apiKey, tmdbKey, name, year, hint)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")[:180]
            report("FAIL", f"{short(title)}  search failed ({exc.code} {detail})")
            return "fail"

    if match is None:
        report("FAIL", f"{short(name or title)}  {note}")
        return "fail"

    matched = describe(match)
    extra = "  ".join(part for part in (castNote, note) if part)
    suffix = f"  {extra}" if extra else ""
    if dryRun:
        report("SUCCESS", f"{matched}  <=  {short(title)}{suffix}")
        return "success"

    try:
        applyMatch(url, apiKey, item["Id"], match)
        updated = confirmMatch(url, apiKey, item["Id"])
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:180]
        report("FAIL", f"{matched}  Jellyfin rejected the match ({exc.code} {detail})")
        return "fail"

    if updated is None:
        report("FAIL", f"{matched}  Jellyfin did not keep an id")
        return "fail"

    saved = describe(updated)
    report("SUCCESS", f"{saved}  <=  {short(title)}{suffix}")
    return "success"


def main() -> int:
    parser = argparse.ArgumentParser(description="Identify unidentified Parvati Nambyar movies in Jellyfin")
    parser.add_argument("--dry-run", action="store_true", help="Print matches without saving them")
    parser.add_argument(
        "--folder",
        help="Host path of a movie that just finished downloading; wait until Jellyfin lists it",
    )
    args = parser.parse_args()

    dotEnv = loadDotEnv()
    apiKey = (dotEnv.get("JELLYFIN_API_KEY") or "").strip()
    if not apiKey:
        print("Set JELLYFIN_API_KEY in jellyfin/.env", file=sys.stderr)
        return 1
    url = jellyfinUrl(dotEnv)
    tmdbKey = loadTmdbKey()
    lock = holdLock()
    library = findLibrary(url, apiKey)
    if args.folder:
        jellyfinPath = jellyfinFolderPath(args.folder, dotEnv)
        print(f"waiting for Jellyfin to see {jellyfinPath}", flush=True)
        try:
            notifyJellyfin(url, apiKey, jellyfinPath)
        except urllib.error.HTTPError as exc:
            print(f"could not notify Jellyfin ({exc.code})", flush=True)
        if waitForFolder(url, apiKey, library["Id"], jellyfinPath):
            print(f"Jellyfin listed {Path(jellyfinPath).name}", flush=True)
        else:
            print(f"Jellyfin has not listed {Path(jellyfinPath).name} yet", flush=True)
    movies = libraryMovies(url, apiKey, library["Id"])
    mode = "dry run" if args.dry_run else "identify"
    print(f"Parvati Nambyar — {mode} — {len(movies)} movies", flush=True)

    counts = {"success": 0, "fail": 0, "skip": 0}
    for item in movies:
        try:
            status = identifyItem(url, apiKey, tmdbKey, item, args.dry_run)
        except Exception as exc:
            report("FAIL", f"{short(sourceTitle(item))}  {exc}")
            status = "fail"
        counts[status] += 1

    print(
        f"done — success {counts['success']}, fail {counts['fail']}, skip {counts['skip']}",
        flush=True,
    )
    fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    lock.close()
    return 1 if counts["fail"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
