#!/usr/bin/env python3
"""Compare local parvatiNambyar quality to the best YouTube format (yt-dlp, same as Apeksha).

  python3 parvatiNambyarQualityCompare.py
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

import yt_dlp

CATALOG = Path(__file__).resolve().parent / "parvatiNambyar.json"


def heightToQuality(height: int | None) -> str | None:
    if not isinstance(height, int) or height <= 0:
        return None
    if height >= 2160:
        return "2160p"
    if height >= 1440:
        return "1440p"
    if height >= 1080:
        return "1080p"
    if height >= 720:
        return "720p"
    if height >= 480:
        return "480p"
    if height >= 360:
        return "360p"
    return f"{height}p"


def qualityToHeight(quality: str | None) -> int:
    if not quality or not quality.endswith("p"):
        return 0
    try:
        return int(quality[:-1])
    except ValueError:
        return 0


def ytOptions() -> dict:
    opts: dict = {
        "noplaylist": True,
        "skip_download": True,
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "socket_timeout": 30,
        "proxy": "",
        "extractor_args": {
            "youtube": {
                "player_client": ["default", "web", "ios", "android"],
            }
        },
    }
    deno = shutil.which("deno")
    if deno:
        opts["js_runtimes"] = {"deno": {"path": deno}}
    return opts


def bestFromFormats(formats: list[dict]) -> dict:
    bestAny = 0
    for fmt in formats:
        if not isinstance(fmt, dict):
            continue
        if fmt.get("vcodec") in (None, "none"):
            continue
        height = fmt.get("height")
        if not isinstance(height, int):
            continue
        bestAny = max(bestAny, height)
    quality = heightToQuality(bestAny or None)
    return {
        "bestAvailableHeight": bestAny or None,
        "bestAvailableQuality": quality,
        "bestToolHeight": bestAny or None,
        "bestToolQuality": quality,
    }


def compareOne(url: str) -> dict:
    with yt_dlp.YoutubeDL(ytOptions()) as ydl:
        info = ydl.extract_info(url, download=False)
    if not info:
        raise RuntimeError("no info")
    return bestFromFormats(list(info.get("formats") or []))


def verdict(have: int, available: int) -> str:
    if not have or not available:
        return "unknown"
    if have >= available:
        return "have_best"
    return "youtube_better"


def main() -> int:
    if not CATALOG.is_file():
        print(f"missing {CATALOG}", file=sys.stderr)
        return 1
    payload = json.loads(CATALOG.read_text(encoding="utf-8"))
    videos = payload.get("videos") or []
    print(f"{'local':6} {'yt-best':7}  {'status':14}  title", flush=True)
    worse: list[str] = []
    errors = 0
    for row in videos:
        url = row.get("youtubeUrl")
        title = str(row.get("title") or "")[:52]
        haveQ = row.get("quality")
        haveH = int(row.get("height") or qualityToHeight(haveQ))
        if not url:
            row["youtubeCompare"] = {"status": "no_url"}
            print(f"{haveQ or '?':6} {'?':7}  {'no_url':14}  {title}", flush=True)
            continue
        try:
            cmp = compareOne(url)
        except Exception as exc:
            errors += 1
            row["youtubeCompare"] = {"status": "error", "error": str(exc)[:200]}
            print(f"{haveQ or '?':6} {'err':7}  {'error':14}  {title}", flush=True)
            continue
        availableH = int(cmp.get("bestAvailableHeight") or 0)
        status = verdict(haveH, availableH)
        row["bestAvailableQuality"] = cmp.get("bestAvailableQuality")
        row["bestAvailableHeight"] = cmp.get("bestAvailableHeight")
        row["bestToolQuality"] = cmp.get("bestToolQuality")
        row["bestToolHeight"] = cmp.get("bestToolHeight")
        row["youtubeCompare"] = {
            "status": status,
            "toolStatus": status,
        }
        print(
            f"{haveQ or '?':6} {cmp.get('bestAvailableQuality') or '?':7}  {status:14}  {title}",
            flush=True,
        )
        if status == "youtube_better":
            worse.append(
                f"{haveQ} → {cmp.get('bestAvailableQuality')}: {row.get('title')}"
            )

    CATALOG.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("", flush=True)
    print(f"updated {CATALOG}", flush=True)
    if worse:
        print(f"{len(worse)} below YouTube best:", flush=True)
        for line in worse:
            print(f"  {line}", flush=True)
    elif errors:
        print("Could not compare (YouTube lookup failed).", flush=True)
    else:
        print("All local files match or beat the best YouTube format found.", flush=True)
    if errors:
        print(f"{errors} lookup errors", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
