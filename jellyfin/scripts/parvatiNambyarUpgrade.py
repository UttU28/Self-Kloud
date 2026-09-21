#!/usr/bin/env python3
"""Replace below-best parvatiNambyar copies with YouTube's best quality.

Scan the catalog JSON, delete local files that are below YouTube best, then
download missing ones one by one. Catalog entries are never removed — only
updated in place and saved after each movie so a crash can resume.

Same yt-dlp strategy as Apeksha (uncapped best video+audio, merge mkv).

  python3 parvatiNambyarUpgrade.py --dry-run
  python3 parvatiNambyarUpgrade.py --yes
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import sys
from pathlib import Path

import yt_dlp

from jellyfinScriptEnv import loadDotEnv, mediaPath
from parvatiNambyarCatalog import VIDEO_SUFFIXES, pickVideo, probeVideo
from parvatiNambyarQualityCompare import (
    CATALOG,
    compareOne,
    heightToQuality,
    qualityToHeight,
    verdict,
)

# Keep in sync with Apeksha/backend/utils/youtubeDownloader.py BEST_YOUTUBE_FORMAT.
BEST_YOUTUBE_FORMAT = (
    "bestvideo*[protocol^=http]+bestaudio[protocol^=http]/"
    "bestvideo*+bestaudio/"
    "best[protocol^=http]/"
    "best"
)

JUNK_SUFFIXES = {".aria2", ".ytdl", ".m4a"}
LOCK_PATH = Path(__file__).resolve().parent / "parvatiNambyarUpgrade.lock"


def saveCatalog(payload: dict) -> None:
    CATALOG.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def libraryRoot(payload: dict) -> Path:
    return Path(payload.get("path") or (Path(mediaPath(loadDotEnv())) / "parvatiNambyar"))


def folderFor(row: dict, root: Path) -> Path:
    name = str(row.get("folder") or "").strip()
    if name:
        return root / name
    youtubeId = str(row.get("youtubeId") or "unknown")
    title = str(row.get("title") or "YouTube")[:80].rstrip()
    return root / f"{title} [{youtubeId}]"


def isRemovableMedia(path: Path) -> bool:
    if not path.is_file():
        return False
    suffix = path.suffix.lower()
    name = path.name
    if ".part" in name:
        return True
    if suffix in VIDEO_SUFFIXES or suffix in JUNK_SUFFIXES:
        return True
    return False


def listRemovable(folder: Path) -> list[Path]:
    if not folder.is_dir():
        return []
    return sorted(path for path in folder.iterdir() if isRemovableMedia(path))


def applyProbe(row: dict, folder: Path) -> None:
    video = pickVideo(folder)
    incomplete = False
    if folder.is_dir():
        incomplete = any(path.suffix == ".aria2" or ".part" in path.name for path in folder.iterdir())
    row["incomplete"] = incomplete
    row["folder"] = folder.name
    if not video:
        row["file"] = None
        row["quality"] = None
        row["width"] = None
        row["height"] = None
        row["codec"] = None
        row["durationSec"] = None
        row["sizeBytes"] = None
        row["probeError"] = "no video"
        return
    info = probeVideo(video)
    row["file"] = video.name
    row["quality"] = info.get("quality")
    row["width"] = info.get("width")
    row["height"] = info.get("height")
    row["codec"] = info.get("codec")
    row["durationSec"] = info.get("durationSec")
    row["sizeBytes"] = info.get("sizeBytes")
    if info.get("error"):
        row["probeError"] = info["error"]
    else:
        row.pop("probeError", None)


def localHeight(row: dict, folder: Path) -> int:
    video = pickVideo(folder)
    if video:
        info = probeVideo(video)
        height = info.get("height")
        if isinstance(height, int) and height > 0:
            return height
    return int(row.get("height") or qualityToHeight(row.get("quality")) or 0)


def refreshYoutubeBest(row: dict) -> str | None:
    url = row.get("youtubeUrl")
    if not url:
        row.setdefault("youtubeCompare", {})["status"] = "no_url"
        return "no_url"
    try:
        cmp = compareOne(url)
    except Exception as exc:
        row["youtubeCompare"] = {"status": "error", "error": str(exc)[:200]}
        return str(exc)
    bestHeight = int(cmp.get("bestAvailableHeight") or 0)
    row["bestAvailableQuality"] = cmp.get("bestAvailableQuality")
    row["bestAvailableHeight"] = cmp.get("bestAvailableHeight")
    row["bestToolQuality"] = cmp.get("bestToolQuality")
    row["bestToolHeight"] = cmp.get("bestToolHeight")
    have = int(row.get("height") or 0)
    row["youtubeCompare"] = {"status": verdict(have, bestHeight), "toolStatus": verdict(have, bestHeight)}
    return None


def needsUpgrade(row: dict, folder: Path) -> bool:
    bestHeight = int(row.get("bestAvailableHeight") or 0)
    if bestHeight <= 0:
        return False
    video = pickVideo(folder)
    have = localHeight(row, folder)
    if video is None:
        return True
    return have < bestHeight


def setUpgrade(row: dict, status: str, **extra: object) -> None:
    payload = dict(row.get("upgrade") or {})
    payload["status"] = status
    payload.update(extra)
    row["upgrade"] = payload


def ytDownloadOptions(workDir: Path) -> dict:
    opts: dict = {
        "noplaylist": True,
        "retries": 15,
        "fragment_retries": 15,
        "file_access_retries": 5,
        "concurrent_fragment_downloads": 16,
        "buffersize": 1024 * 1024,
        "http_chunk_size": 10 * 1024 * 1024,
        "socket_timeout": 30,
        "proxy": "",
        "extractor_args": {
            "youtube": {
                "player_client": ["default", "web", "ios", "android"],
            }
        },
        "outtmpl": str(workDir / "%(title)s [%(id)s].%(ext)s"),
        "format": BEST_YOUTUBE_FORMAT,
        "restrictfilenames": False,
        "ignoreerrors": False,
        "merge_output_format": "mkv",
        "writethumbnail": True,
        "overwrites": True,
        "continuedl": True,
        "paths": {"home": str(workDir)},
        "postprocessors": [{"key": "EmbedThumbnail"}],
        "noprogress": False,
        "quiet": False,
        "no_warnings": False,
    }
    deno = shutil.which("deno")
    if deno:
        opts["js_runtimes"] = {"deno": {"path": deno}}
    return opts


def acquireLock():
    handle = open(LOCK_PATH, "a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(
            f"Another parvatiNambyarUpgrade.py is already running ({LOCK_PATH}). "
            "Do not start a second --yes; it races the same .part files.",
            file=sys.stderr,
        )
        handle.close()
        raise SystemExit(2)
    handle.seek(0)
    handle.truncate()
    handle.write(f"{os.getpid()}\n")
    handle.flush()
    return handle


def finishProbe(row: dict, folder: Path) -> str | None:
    applyProbe(row, folder)
    have = int(row.get("height") or 0)
    best = int(row.get("bestAvailableHeight") or 0)
    row["youtubeCompare"] = {
        "status": verdict(have, best) if best else "unknown",
        "toolStatus": verdict(have, best) if best else "unknown",
    }
    if not pickVideo(folder):
        return "download finished but no video file"
    return None


def downloadBest(row: dict, folder: Path) -> str | None:
    url = row.get("youtubeUrl")
    if not url:
        return "no_url"
    folder.mkdir(parents=True, exist_ok=True)
    try:
        with yt_dlp.YoutubeDL(ytDownloadOptions(folder)) as ydl:
            ydl.download([url])
    except Exception as exc:
        applyProbe(row, folder)
        if not needsUpgrade(row, folder):
            print(f"yt-dlp error but file is already at best quality: {exc}", flush=True)
            return None
        return str(exc)
    return finishProbe(row, folder)


def parseArgs() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upgrade parvatiNambyar files to YouTube best quality")
    parser.add_argument("--yes", action="store_true", help="delete below-best files and download replacements")
    parser.add_argument("--dry-run", action="store_true", help="print the plan without deleting or downloading")
    return parser.parse_args()


def main() -> int:
    args = parseArgs()
    dryRun = not args.yes
    if args.dry_run:
        dryRun = True
    if not CATALOG.is_file():
        print(f"missing {CATALOG}", file=sys.stderr)
        return 1
    payload = json.loads(CATALOG.read_text(encoding="utf-8"))
    videos = payload.get("videos") or []
    root = libraryRoot(payload)
    if not root.is_dir():
        print(f"missing library: {root}", file=sys.stderr)
        return 1

    lockHandle = None
    if not dryRun:
        lockHandle = acquireLock()

    mode = "DRY RUN" if dryRun else "LIVE"
    print(f"{mode}: {len(videos)} catalog entries in {root}", flush=True)
    print("Catalog entries are never removed; JSON is saved after each movie.\n", flush=True)

    planned: list[dict] = []
    for row in videos:
        title = str(row.get("title") or row.get("youtubeId") or "?")
        folder = folderFor(row, root)
        applyProbe(row, folder)
        err = refreshYoutubeBest(row)
        if err == "no_url":
            print(f"skip  no YouTube URL  {title}", flush=True)
            continue
        if err:
            print(f"skip  youtube lookup failed ({err[:80]})  {title}", flush=True)
            if not dryRun:
                saveCatalog(payload)
            continue
        best = int(row.get("bestAvailableHeight") or 0)
        have = int(row.get("height") or 0)
        if not needsUpgrade(row, folder):
            print(
                f"ok    {heightToQuality(have) or '?':6} = {heightToQuality(best) or '?':6}  {title[:60]}",
                flush=True,
            )
            continue
        removable = listRemovable(folder)
        planned.append(row)
        haveLabel = heightToQuality(have) if pickVideo(folder) else "missing"
        print(
            f"need  {haveLabel:6} → {heightToQuality(best) or '?':6}  "
            f"({len(removable)} files to delete)  {title[:52]}",
            flush=True,
        )

    if dryRun:
        print(f"\n{len(planned)} would be deleted then re-downloaded. Re-run with --yes.", flush=True)
        return 0

    saveCatalog(payload)
    print(f"\n--- delete below-best ({len(planned)}) ---", flush=True)
    for row in planned:
        folder = folderFor(row, root)
        title = str(row.get("title") or "")[:60]
        video = pickVideo(folder)
        have = localHeight(row, folder)
        best = int(row.get("bestAvailableHeight") or 0)
        alreadyDownloading = (row.get("upgrade") or {}).get("status") == "downloading"
        if alreadyDownloading:
            print(f"keep   in-progress download  {title}", flush=True)
            continue
        if video is None:
            setUpgrade(row, "deleted", reason="already_missing")
            saveCatalog(payload)
            print(f"keep   already missing  {title}", flush=True)
            continue
        if have >= best:
            print(f"keep   already best  {title}", flush=True)
            continue
        deleted = []
        for path in listRemovable(folder):
            path.unlink()
            deleted.append(path.name)
        applyProbe(row, folder)
        setUpgrade(row, "deleted", deleted=deleted)
        saveCatalog(payload)
        print(f"deleted {len(deleted)} files  {title}", flush=True)

    print(f"\n--- download missing one by one ({len(planned)}) ---", flush=True)
    errors = 0
    for index, row in enumerate(planned, start=1):
        folder = folderFor(row, root)
        title = str(row.get("title") or "")[:60]
        if not needsUpgrade(row, folder):
            setUpgrade(row, "done")
            saveCatalog(payload)
            print(f"[{index}/{len(planned)}] already best  {title}", flush=True)
            continue
        print(
            f"[{index}/{len(planned)}] downloading {row.get('bestAvailableQuality')}  {title}",
            flush=True,
        )
        setUpgrade(row, "downloading")
        saveCatalog(payload)
        error = downloadBest(row, folder)
        if error:
            errors += 1
            setUpgrade(row, "error", error=error[:300])
            saveCatalog(payload)
            print(f"[{index}/{len(planned)}] ERROR {error[:160]}  {title}", flush=True)
            continue
        setUpgrade(row, "done")
        saveCatalog(payload)
        print(
            f"[{index}/{len(planned)}] done {row.get('quality')}  {title}",
            flush=True,
        )

    print(f"\nupdated {CATALOG}", flush=True)
    if errors:
        print(f"{errors} download errors — re-run with --yes to continue the rest.", flush=True)
        return 1
    print("All planned upgrades finished.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
