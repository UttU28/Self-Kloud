#!/usr/bin/env python3
"""
List Immich albums with archive status, then toggle archive on selected albums.

Archive applies to assets inside an album (not the album itself). An album is
shown as archived / not archived / partial based on its assets.

Usage:
  export IMMICH_API_KEY="your-key"
  python3 ~/Desktop/toggleImmichAlbumArchive.py

  # non-interactive toggle (album numbers from the list)
  python3 ~/Desktop/toggleImmichAlbumArchive.py --select 1,3
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

DEFAULT_IMMICH_URL = "http://127.0.0.1:2283"
DEFAULT_BATCH_SIZE = 500


@dataclass
class AlbumArchiveSummary:
    albumId: str
    albumName: str
    assetCount: int
    archivedCount: int

    @property
    def archiveStatus(self) -> str:
        if self.assetCount == 0:
            return "empty"
        if self.archivedCount == 0:
            return "not archived"
        if self.archivedCount == self.assetCount:
            return "archived"
        return "partial"

    @property
    def toggleAction(self) -> str:
        if self.archiveStatus == "archived":
            return "unarchive"
        return "archive"


class ImmichClient:
    def __init__(self, immichUrl: str, apiKey: str) -> None:
        self.immichUrl = immichUrl.rstrip("/")
        self.apiKey = apiKey

    def _request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
    ) -> Any:
        url = f"{self.immichUrl}{path}"
        data = None
        headers = {
            "x-api-key": self.apiKey,
            "Accept": "application/json",
        }
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"

        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                raw = response.read().decode("utf-8")
                if not raw:
                    return None
                return json.loads(raw)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} failed ({exc.code}): {detail}") from exc

    def getAlbums(self) -> list[dict[str, Any]]:
        owned = self._request("GET", "/api/albums") or []
        shared = self._request("GET", "/api/albums?shared=true") or []
        if not isinstance(owned, list):
            owned = []
        if not isinstance(shared, list):
            shared = []

        seenIds: set[str] = set()
        merged: list[dict[str, Any]] = []
        for album in owned + shared:
            albumId = album.get("id")
            if albumId and albumId not in seenIds:
                seenIds.add(albumId)
                merged.append(album)
        return merged

    def getAlbum(self, albumId: str) -> dict[str, Any]:
        result = self._request("GET", f"/api/albums/{albumId}")
        if not isinstance(result, dict):
            raise RuntimeError(f"Unexpected album response for {albumId}")
        return result

    def setAssetVisibility(self, assetIds: list[str], visibility: str) -> None:
        self._request("PUT", "/api/assets", {"ids": assetIds, "visibility": visibility})


def isAssetArchived(asset: dict[str, Any]) -> bool:
    if asset.get("isArchived") is True:
        return True
    return asset.get("visibility") == "archive"


def summarizeAlbum(client: ImmichClient, album: dict[str, Any]) -> AlbumArchiveSummary:
    details = client.getAlbum(album["id"])
    assets = details.get("assets", [])
    if not isinstance(assets, list):
        assets = []

    archivedCount = sum(1 for asset in assets if isAssetArchived(asset))
    return AlbumArchiveSummary(
        albumId=album["id"],
        albumName=album.get("albumName", "Untitled"),
        assetCount=len(assets),
        archivedCount=archivedCount,
    )


def chunkList(items: list[str], chunkSize: int) -> list[list[str]]:
    return [items[i : i + chunkSize] for i in range(0, len(items), chunkSize)]


def toggleAlbumArchive(
    client: ImmichClient,
    summary: AlbumArchiveSummary,
    batchSize: int,
    dryRun: bool,
) -> None:
    details = client.getAlbum(summary.albumId)
    assets = details.get("assets", [])
    if not isinstance(assets, list) or not assets:
        print(f"  Skipping '{summary.albumName}' — no assets.")
        return

    targetVisibility = "timeline" if summary.archiveStatus == "archived" else "archive"
    action = "Unarchive" if targetVisibility == "timeline" else "Archive"

    assetIds = [asset["id"] for asset in assets if "id" in asset]
    if targetVisibility == "archive":
        assetIds = [asset["id"] for asset in assets if "id" in asset and not isAssetArchived(asset)]
    else:
        assetIds = [asset["id"] for asset in assets if "id" in asset and isAssetArchived(asset)]

    if not assetIds:
        print(f"  '{summary.albumName}' — nothing to change.")
        return

    print(f"  {action} {len(assetIds)} asset(s) in '{summary.albumName}'...")
    if dryRun:
        print("  [dryRun] no changes sent")
        return

    for index, batch in enumerate(chunkList(assetIds, batchSize), start=1):
        client.setAssetVisibility(batch, targetVisibility)
        print(f"    batch {index}: updated {len(batch)} asset(s)")
        time.sleep(0.15)


def printAlbumList(summaries: list[AlbumArchiveSummary]) -> None:
    print()
    print(f"{'#':<4} {'Album':<28} {'Assets':<8} {'Archived':<10} Status")
    print("-" * 72)
    for index, summary in enumerate(summaries, start=1):
        archivedLabel = f"{summary.archivedCount}/{summary.assetCount}"
        print(
            f"{index:<4} {summary.albumName[:28]:<28} "
            f"{summary.assetCount:<8} {archivedLabel:<10} {summary.archiveStatus}"
        )
    print()


def parseSelection(rawInput: str, maxIndex: int) -> list[int]:
    rawInput = rawInput.strip().lower()
    if not rawInput or rawInput in {"q", "quit", "exit"}:
        return []

    selections: list[int] = []
    for part in rawInput.split(","):
        part = part.strip()
        if not part:
            continue
        if not part.isdigit():
            raise ValueError(f"Invalid selection: {part!r}")
        index = int(part)
        if index < 1 or index > maxIndex:
            raise ValueError(f"Out of range: {index} (use 1-{maxIndex})")
        if index not in selections:
            selections.append(index)
    return selections


def parseArgs() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="List Immich albums and toggle archive on selected albums."
    )
    parser.add_argument(
        "--immichUrl",
        default=os.environ.get("IMMICH_URL", DEFAULT_IMMICH_URL),
        help=f"Immich base URL (default: {DEFAULT_IMMICH_URL})",
    )
    parser.add_argument(
        "--apiKey",
        default=os.environ.get("IMMICH_API_KEY", ""),
        help="Immich API key (or set IMMICH_API_KEY)",
    )
    parser.add_argument(
        "--select",
        default="",
        help="Comma-separated album numbers to toggle (e.g. 1,3). Skips prompt.",
    )
    parser.add_argument(
        "--batchSize",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help=f"Assets per API batch (default: {DEFAULT_BATCH_SIZE})",
    )
    parser.add_argument(
        "--dryRun",
        action="store_true",
        help="Show what would change without calling Immich",
    )
    return parser.parse_args()


def main() -> int:
    args = parseArgs()

    if not args.apiKey:
        print(
            "Missing API key. Set IMMICH_API_KEY or pass --apiKey.\n"
            "Create one: Immich → profile icon → Account Settings → API Keys",
            file=sys.stderr,
        )
        return 1

    client = ImmichClient(args.immichUrl, args.apiKey)

    print(f"Immich: {args.immichUrl}")
    print("Loading albums...")

    albums = client.getAlbums()
    if not albums:
        print("No albums found.")
        return 0

    summaries = [summarizeAlbum(client, album) for album in albums]
    summaries.sort(key=lambda item: item.albumName.lower())

    printAlbumList(summaries)

    if args.select:
        selectionInput = args.select
    else:
        print("Enter album number(s) to toggle archive (e.g. 1 or 1,3,4).")
        print("Press Enter or q to quit.")
        try:
            selectionInput = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0

    try:
        selectedIndexes = parseSelection(selectionInput, len(summaries))
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1

    if not selectedIndexes:
        print("No albums selected.")
        return 0

    print("Toggling:")
    for index in selectedIndexes:
        summary = summaries[index - 1]
        print(f"- [{index}] {summary.albumName} ({summary.archiveStatus}) → {summary.toggleAction}")
        toggleAlbumArchive(client, summary, args.batchSize, args.dryRun)

    print()
    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
