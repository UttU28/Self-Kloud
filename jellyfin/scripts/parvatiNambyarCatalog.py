#!/usr/bin/env python3
"""Scan parvatiNambyar movie folders and write title / YouTube URL / quality JSON.

  python3 parvatiNambyarCatalog.py
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

from jellyfinScriptEnv import loadDotEnv, mediaPath

ID_RE = re.compile(r"\[([A-Za-z0-9_-]{11})\]\s*$")
VIDEO_SUFFIXES = {".mp4", ".mkv", ".webm", ".m4v"}
KEEP_FIELDS = (
    "youtubeCompare",
    "bestAvailableQuality",
    "bestAvailableHeight",
    "bestToolQuality",
    "bestToolHeight",
    "upgrade",
)


def pickVideo(folder: Path) -> Path | None:
    candidates = [
        path
        for path in folder.iterdir()
        if path.is_file()
        and path.suffix.lower() in VIDEO_SUFFIXES
        and ".part" not in path.name
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_size)


def probeVideo(path: Path) -> dict:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height,codec_name",
        "-show_entries",
        "format=duration,size",
        "-of",
        "json",
        str(path),
    ]
    try:
        raw = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=30)
        data = json.loads(raw)
    except Exception as exc:
        return {"quality": None, "error": str(exc)}
    stream = (data.get("streams") or [{}])[0]
    fmt = data.get("format") or {}
    height = stream.get("height")
    quality = None
    if isinstance(height, int):
        if height >= 2160:
            quality = "2160p"
        elif height >= 1440:
            quality = "1440p"
        elif height >= 1080:
            quality = "1080p"
        elif height >= 720:
            quality = "720p"
        elif height >= 480:
            quality = "480p"
        elif height >= 360:
            quality = "360p"
        else:
            quality = f"{height}p"
    duration = fmt.get("duration")
    try:
        durationSec = round(float(duration), 1) if duration is not None else None
    except (TypeError, ValueError):
        durationSec = None
    size = fmt.get("size")
    try:
        sizeBytes = int(size) if size is not None else path.stat().st_size
    except (TypeError, ValueError):
        sizeBytes = path.stat().st_size
    return {
        "width": stream.get("width"),
        "height": height,
        "quality": quality,
        "codec": stream.get("codec_name"),
        "durationSec": durationSec,
        "sizeBytes": sizeBytes,
    }


def cleanTitle(stem: str, youtubeId: str | None) -> str:
    title = stem
    if youtubeId:
        title = re.sub(rf"\s*\[{re.escape(youtubeId)}\]\s*$", "", title)
    return title.replace("｜", "|").replace("：", ":").strip()


def main() -> int:
    root = Path(mediaPath(loadDotEnv())) / "parvatiNambyar"
    if not root.is_dir():
        print(f"missing library: {root}", file=sys.stderr)
        return 1

    outPath = Path(__file__).resolve().parent / "parvatiNambyar.json"
    existingPayload: dict = {}
    if outPath.is_file():
        try:
            existingPayload = json.loads(outPath.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            existingPayload = {}
    existingVideos = list(existingPayload.get("videos") or [])
    existingById = {
        str(row.get("youtubeId")): row for row in existingVideos if row.get("youtubeId")
    }
    existingByFolder = {
        str(row.get("folder")): row for row in existingVideos if row.get("folder")
    }

    entries: list[dict] = []
    seenKeys: set[str] = set()
    for folder in sorted(root.iterdir(), key=lambda p: p.name.lower()):
        if not folder.is_dir():
            continue
        video = pickVideo(folder)
        match = ID_RE.search(video.stem if video else folder.name) or ID_RE.search(folder.name)
        youtubeId = match.group(1) if match else None
        title = cleanTitle(video.stem if video else folder.name, youtubeId)
        info = probeVideo(video) if video else {"quality": None, "error": "no video"}
        incomplete = any(p.suffix == ".aria2" or ".part" in p.name for p in folder.iterdir())
        row = {
            "title": title,
            "youtubeId": youtubeId,
            "youtubeUrl": f"https://www.youtube.com/watch?v={youtubeId}" if youtubeId else None,
            "quality": info.get("quality"),
            "width": info.get("width"),
            "height": info.get("height"),
            "codec": info.get("codec"),
            "durationSec": info.get("durationSec"),
            "sizeBytes": info.get("sizeBytes"),
            "folder": folder.name,
            "file": video.name if video else None,
            "incomplete": incomplete,
        }
        if info.get("error"):
            row["probeError"] = info["error"]
        old = (existingById.get(youtubeId) if youtubeId else None) or existingByFolder.get(folder.name)
        if old:
            for key in KEEP_FIELDS:
                if key in old:
                    row[key] = old[key]
        entries.append(row)
        seenKeys.add(youtubeId or folder.name)
        print(f"{row.get('quality') or '?':6} {title}", flush=True)

    for old in existingVideos:
        key = str(old.get("youtubeId") or old.get("folder") or "")
        if key and key not in seenKeys:
            entries.append(old)
            seenKeys.add(key)

    payload = {
        "library": "parvatiNambyar",
        "path": str(root),
        "count": len(entries),
        "videos": entries,
    }
    outPath.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {outPath} ({len(entries)} videos)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
