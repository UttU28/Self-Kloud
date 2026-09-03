"""Load selfHosted/jellyfin/.env for watch-order scripts."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
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


def jellyfinAuthHeaders(apiKey: str) -> dict[str, str]:
    # Jellyfin 12 ignores X-Emby-Token unless EnableLegacyAuthorization is on.
    token = apiKey.strip()
    auth = (
        'MediaBrowser Client="selfHosted", Device="watch-order", '
        'DeviceId="selfhosted-watch-order", Version="1.0.0", '
        f'Token="{token}"'
    )
    return {
        "Authorization": auth,
        "Accept": "application/json",
    }


def jellyfinRequest(url, apiKey, path, method="GET", params=None, body=None):
    query = urllib.parse.urlencode(params or {}, doseq=True)
    full = f"{url.rstrip('/')}{path}" + (f"?{query}" if query else "")
    data = None if body is None else json.dumps(body).encode()
    headers = jellyfinAuthHeaders(apiKey)
    if data is not None or method != "GET":
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(full, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            if not raw:
                return None
            return json.loads(raw.decode())
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            raise SystemExit(
                "Jellyfin 401 Unauthorized. Create a new API key in Dashboard → API Keys "
                "and set JELLYFIN_API_KEY in jellyfin/.env"
            ) from exc
        raise


def jellyfinGet(url, apiKey, path, params=None):
    return jellyfinRequest(url, apiKey, path, "GET", params)


def jellyfinPost(url, apiKey, path, params=None, body=None):
    return jellyfinRequest(url, apiKey, path, "POST", params, body)
