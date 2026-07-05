#!/usr/bin/env python3
"""Copy recent SD-card media into a local test fixture.

This intentionally uses filesystem modification time for the safety copy window.
The app itself validates capture metadata with ImageIO/AVFoundation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path


MEDIA_EXTENSIONS = {".jpg", ".jpeg", ".heif", ".heic", ".mov", ".raf"}


@dataclass
class CopiedFile:
    relative_path: str
    size_bytes: int
    mtime: str
    sha256: str


def iso_from_timestamp(value: float) -> str:
    return datetime.fromtimestamp(value, tz=timezone.utc).isoformat()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def existing_hashes(destination: Path) -> dict[str, dict[str, object]]:
    manifest_path = destination / "copy_manifest.json"
    if not manifest_path.exists():
        return {}
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    existing: dict[str, dict[str, object]] = {}
    for item in payload.get("files", []):
        if isinstance(item, dict) and isinstance(item.get("relative_path"), str):
            existing[item["relative_path"]] = item
    return existing


def nearest_existing_parent(path: Path) -> Path:
    candidate = path
    while not candidate.exists() and candidate != candidate.parent:
        candidate = candidate.parent
    return candidate


def path_contains(parent: Path, child: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def validate_destination(source: Path, destination: Path) -> None:
    if source == destination or path_contains(source, destination):
        raise ValueError(f"destination must not be inside the source tree: {destination}")
    if path_contains(destination, source):
        raise ValueError(f"source must not be inside the destination tree: {source}")

    parent = nearest_existing_parent(destination)
    if str(source).startswith("/Volumes/") and parent.exists():
        try:
            if source.stat().st_dev == parent.stat().st_dev:
                raise ValueError(
                    "destination must not be on the same mounted volume as the source card: "
                    f"{destination}"
                )
        except OSError:
            pass


def recent_media_files(source: Path, hours: float) -> list[Path]:
    cutoff = datetime.now(tz=timezone.utc).timestamp() - (hours * 3600)
    files: list[Path] = []
    for root, _, names in os.walk(source):
        for name in names:
            path = Path(root) / name
            if path.name.startswith("._"):
                continue
            if path.suffix.lower() not in MEDIA_EXTENSIONS:
                continue
            try:
                if path.stat().st_mtime >= cutoff:
                    files.append(path)
            except OSError:
                continue
    return sorted(files, key=lambda item: str(item.relative_to(source)).lower())


def remove_stale_media(destination: Path, expected_relative_paths: set[Path]) -> list[str]:
    dcim = destination / "DCIM"
    if not dcim.exists():
        return []

    removed: list[str] = []
    for root, _, names in os.walk(dcim):
        for name in names:
            path = Path(root) / name
            if path.suffix.lower() not in MEDIA_EXTENSIONS:
                continue
            relative = path.relative_to(destination)
            if relative not in expected_relative_paths:
                path.unlink()
                removed.append(str(relative))

    for root, dirs, _ in os.walk(dcim, topdown=False):
        for dirname in dirs:
            candidate = Path(root) / dirname
            try:
                candidate.rmdir()
            except OSError:
                pass
    return sorted(removed)


def write_reproduction(
    destination: Path,
    source: Path,
    hours: float,
    manifest: list[CopiedFile],
) -> None:
    total_size = sum(item.size_bytes for item in manifest)
    lines = [
        "SD-card copied test fixture",
        "",
        f"Created at: {datetime.now(tz=timezone.utc).isoformat()}",
        f"Source: {source}",
        f"Destination: {destination}",
        f"Window: files with filesystem mtime in the last {hours:g} hours",
        f"Copied files: {len(manifest)}",
        f"Copied bytes: {total_size}",
        "",
        "Recreate:",
        (
            "python3 scripts/copy_last_24h_media.py "
            f"--source {source} --destination {destination} --hours {hours:g}"
        ),
        "",
        "Safety:",
        "- Source files were opened read-only and copied into this directory.",
        "- The application should be tested against this destination, not the SD card.",
        "- The app's scanner uses capture metadata; this helper only defines the safety copy window.",
    ]
    (destination / "reproduction.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--hours", default=24.0, type=float)
    parser.add_argument("--allow-empty", action="store_true")
    args = parser.parse_args()

    source = args.source.expanduser().resolve()
    destination = args.destination.expanduser().resolve()

    if not source.exists() or not source.is_dir():
        print(f"source directory does not exist: {source}", file=sys.stderr)
        return 2
    try:
        validate_destination(source, destination)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 4

    files = recent_media_files(source, args.hours)
    if not files and not args.allow_empty:
        print(f"no recent media files found under {source}", file=sys.stderr)
        return 3

    destination.mkdir(parents=True, exist_ok=True)
    expected_relative_paths = {Path("DCIM") / path.relative_to(source) for path in files}
    removed_stale = remove_stale_media(destination, expected_relative_paths)

    previous_hashes = existing_hashes(destination)
    manifest: list[CopiedFile] = []
    for source_file in files:
        relative = source_file.relative_to(source)
        destination_file = destination / "DCIM" / relative
        destination_file.parent.mkdir(parents=True, exist_ok=True)
        source_stat = source_file.stat()
        should_copy = True
        if destination_file.exists():
            destination_stat = destination_file.stat()
            should_copy = not (
                destination_stat.st_size == source_stat.st_size
                and abs(destination_stat.st_mtime - source_stat.st_mtime) < 0.001
            )
        if should_copy:
            shutil.copy2(source_file, destination_file)
        stat = destination_file.stat()
        relative_path = str(Path("DCIM") / relative)
        mtime = iso_from_timestamp(stat.st_mtime)
        previous = previous_hashes.get(relative_path)
        if (
            previous
            and previous.get("size_bytes") == stat.st_size
            and previous.get("mtime") == mtime
            and isinstance(previous.get("sha256"), str)
        ):
            digest = previous["sha256"]
        else:
            digest = sha256_file(destination_file)
        manifest.append(
            CopiedFile(
                relative_path=relative_path,
                size_bytes=stat.st_size,
                mtime=mtime,
                sha256=digest,
            )
        )

    manifest_payload = {
        "source": str(source),
        "destination": str(destination),
        "hours": args.hours,
        "created_at": datetime.now(tz=timezone.utc).isoformat(),
        "file_count": len(manifest),
        "removed_stale_files": removed_stale,
        "total_bytes": sum(item.size_bytes for item in manifest),
        "files": [asdict(item) for item in manifest],
    }
    (destination / "copy_manifest.json").write_text(
        json.dumps(manifest_payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_reproduction(destination, source, args.hours, manifest)
    print(json.dumps(manifest_payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
