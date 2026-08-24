#!/usr/bin/env python3
"""Copy compatible v3 state into an isolated v4.2 state directory."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path

DURABLE_FILES = (
    "oauth-jwt-secret",
    "oauth-clients.json",
    "remote-workers.json",
    "remote-workers.json.bak",
    "remote-workers.generation",
    "jobs.json",
    "jobs.json.bak",
    "downloads.json",
    "container-clients.json",
    "container-clients.json.bak",
)
DURABLE_DIRS = ("jobs", "downloads", "browser-profiles", "browser-artifacts")
LEGACY_FILES = ("todos.json", "task-artifacts.json", "task-artifacts.json.bak", "audit.jsonl")
LEGACY_DIRS = ("task-artifacts", "audit-payloads", "audit-archive")
JSON_FILES = frozenset(name for name in DURABLE_FILES + LEGACY_FILES if name.endswith(".json"))


@dataclass(frozen=True)
class Entry:
    source: str
    destination: str
    kind: str
    size: int
    sha256: str | None


def _resolved_directory(path: Path, *, must_exist: bool) -> Path:
    expanded = path.expanduser()
    if must_exist and not expanded.is_dir():
        raise ValueError(f"directory does not exist: {expanded}")
    resolved = expanded.resolve(strict=must_exist)
    if resolved == Path(resolved.anchor):
        raise ValueError("filesystem root is not a valid migration directory")
    return resolved


def _validate_source(path: Path) -> None:
    if path.is_symlink():
        raise ValueError(f"symlinks are not migrated: {path}")
    if path.name in JSON_FILES:
        with path.open("r", encoding="utf-8") as handle:
            json.load(handle)


def _digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def _tree_size(path: Path) -> int:
    return sum(child.stat().st_size for child in path.rglob("*") if child.is_file())


def _plan(source: Path, destination: Path, legacy_config: Path | None) -> list[Entry]:
    entries: list[Entry] = []
    for name in DURABLE_FILES:
        candidate = source / name
        if candidate.exists():
            _validate_source(candidate)
            entries.append(Entry(str(candidate), str(destination / name), "durable-file", candidate.stat().st_size, _digest(candidate)))
    for name in DURABLE_DIRS:
        candidate = source / name
        if candidate.exists():
            _validate_source(candidate)
            entries.append(Entry(str(candidate), str(destination / name), "durable-directory", _tree_size(candidate), None))

    legacy_root = destination / "legacy-v3"
    for name in LEGACY_FILES:
        candidate = source / name
        if candidate.exists():
            _validate_source(candidate)
            entries.append(Entry(str(candidate), str(legacy_root / name), "legacy-file", candidate.stat().st_size, _digest(candidate)))
    for name in LEGACY_DIRS:
        candidate = source / name
        if candidate.exists():
            _validate_source(candidate)
            entries.append(Entry(str(candidate), str(legacy_root / name), "legacy-directory", _tree_size(candidate), None))
    if legacy_config is not None and legacy_config.exists():
        _validate_source(legacy_config)
        entries.append(Entry(str(legacy_config), str(legacy_root / legacy_config.name), "legacy-config", legacy_config.stat().st_size, _digest(legacy_config)))
    return entries


def _copy_entry(entry: Entry) -> None:
    source = Path(entry.source)
    destination = Path(entry.destination)
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f"refusing to overwrite migration target: {destination}")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=False)
        for directory in (destination, *[p for p in destination.rglob("*") if p.is_dir()]):
            directory.chmod(0o700)
        for file_path in (p for p in destination.rglob("*") if p.is_file()):
            file_path.chmod(0o600)
    else:
        shutil.copy2(source, destination, follow_symlinks=False)
        destination.chmod(0o600)


def migrate(source: Path, destination: Path, *, apply: bool, legacy_config: Path | None = None) -> dict[str, object]:
    source = _resolved_directory(source, must_exist=True)
    destination = _resolved_directory(destination, must_exist=False)
    if source == destination or source in destination.parents:
        raise ValueError("destination must be separate from and outside the source state directory")
    if destination.exists() and any(destination.iterdir()):
        raise ValueError(f"destination must be absent or empty: {destination}")

    resolved_legacy = legacy_config.expanduser().resolve(strict=False) if legacy_config else None
    entries = _plan(source, destination, resolved_legacy)
    manifest: dict[str, object] = {
        "schema": 1,
        "mode": "apply" if apply else "dry-run",
        "source": str(source),
        "destination": str(destination),
        "created_at": datetime.now(UTC).isoformat(),
        "entries": [asdict(entry) for entry in entries],
        "excluded": [
            "oauth-codes.json and pending invitations",
            "temporary files and locks",
            "restart records and remote transfer scratch data",
            "legacy todo/task data from active v4.2 stores",
            "legacy external MCP registration from Dynamic MCP",
        ],
    }
    if apply:
        if destination.exists():
            destination.chmod(0o700)
        else:
            destination.mkdir(mode=0o700, parents=True)
        for entry in entries:
            _copy_entry(entry)
        manifest_path = destination / "migration-manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        manifest_path.chmod(0o600)
        os.sync()
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="existing v3 state directory")
    parser.add_argument("destination", type=Path, help="new, isolated v4.2 state directory")
    parser.add_argument("--legacy-config", type=Path, help="external-mcp.toml to archive without activating")
    parser.add_argument("--apply", action="store_true", help="perform the copy; default is a dry run")
    args = parser.parse_args(argv)
    try:
        manifest = migrate(args.source, args.destination, apply=args.apply, legacy_config=args.legacy_config)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"migration failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
