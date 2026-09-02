"""Load selfHosted/jellyfin/.env for watch-order scripts."""

from __future__ import annotations

import os
from pathlib import Path


def loadDotEnv() -> dict[str, str]:
    values = {key: value for key, value in os.environ.items()}
    envFile = Path(__file__).resolve().parent.parent / ".env"
    if not envFile.is_file():
        return values
    for raw in envFile.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


def mediaPath(dotEnv: dict[str, str]) -> str:
    return dotEnv.get("MEDIA_PATH", "/mnt/chitragupt/jellyfin/media").rstrip("/")


def jellyfinUrl(dotEnv: dict[str, str]) -> str:
    return dotEnv.get("JELLYFIN_URL", "http://127.0.0.1:8096")
