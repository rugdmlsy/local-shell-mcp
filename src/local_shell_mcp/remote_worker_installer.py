from __future__ import annotations

import hashlib
import importlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from . import __version__
from .remote_worker_bundle import verify_extracted_worker_runtime
from .remote_worker_state import (
    read_worker_config,
    update_runtime_metadata,
    worker_config_path,
    worker_pending_upgrade_path,
    worker_previous_config_path,
    worker_previous_runtime_dir,
    worker_runtime_dir,
    worker_state_dir,
    write_pending_upgrade_marker,
)

_WORKER_MANIFEST_PATH = "/remote/worker-bundle.tgz?manifest=1"
_WINDOWS_PTY_REQUIREMENT = "pywinpty>=2.0.13"


def worker_dependency_dir() -> Path:
    python_tag = f"py{sys.version_info.major}{sys.version_info.minor}"
    return worker_state_dir() / "dependencies" / python_tag


def _activate_worker_dependency_dir(path: Path) -> None:
    value = str(path.resolve())
    if value not in sys.path:
        sys.path.insert(0, value)
    current = [entry for entry in os.environ.get("PYTHONPATH", "").split(os.pathsep) if entry]
    if value not in current:
        os.environ["PYTHONPATH"] = os.pathsep.join([value, *current])


def ensure_platform_dependencies() -> dict[str, Any]:
    path = worker_dependency_dir()
    _activate_worker_dependency_dir(path)
    if sys.platform != "win32":
        return {"available": True, "installed": False, "path": str(path)}
    try:
        module = importlib.import_module("winpty")
    except (ImportError, OSError):
        module = None
    if module is not None and hasattr(module, "PtyProcess"):
        return {"available": True, "installed": False, "path": str(path)}

    path.mkdir(parents=True, exist_ok=True)
    argv = [
        sys.executable,
        "-m",
        "pip",
        "install",
        "--disable-pip-version-check",
        "--no-input",
        "--retries",
        "1",
        "--timeout",
        "5",
        "--target",
        str(path),
        _WINDOWS_PTY_REQUIREMENT,
    ]
    try:
        completed = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {
            "available": False,
            "installed": False,
            "path": str(path),
            "error": str(exc),
        }
    importlib.invalidate_caches()
    try:
        module = importlib.import_module("winpty")
    except (ImportError, OSError):
        module = None
    available = module is not None and hasattr(module, "PtyProcess")
    result: dict[str, Any] = {
        "available": available,
        "installed": available and completed.returncode == 0,
        "path": str(path),
    }
    if not available:
        result["error"] = (
            completed.stderr.strip()
            or completed.stdout.strip()
            or f"pip exited with code {completed.returncode}"
        )
    return result


def _fetch_bytes(url: str, timeout: float = 60) -> bytes:
    request = urllib.request.Request(
        url,
        headers={
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "User-Agent": f"local-shell-mcp-worker/{__version__}",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
        return response.read()


def fetch_manifest(server: str) -> dict[str, Any]:
    url = server.rstrip("/") + _WORKER_MANIFEST_PATH
    data = json.loads(_fetch_bytes(url).decode("utf-8"))
    if not isinstance(data, dict) or data.get("schema_version") not in {1, 2}:
        raise ValueError("invalid remote worker manifest")
    digest = str(data.get("sha256") or "")
    bundle_url = str(data.get("url") or "")
    if len(digest) != 64 or not bundle_url:
        raise ValueError("remote worker manifest is incomplete")
    data["url"] = urllib.parse.urljoin(server.rstrip("/") + "/", bundle_url)
    return data


def _safe_extract(archive: Path, destination: Path) -> None:
    destination_resolved = destination.resolve()
    with tarfile.open(archive, mode="r:gz") as tar:
        for member in tar.getmembers():
            target = (destination / member.name).resolve()
            if target != destination_resolved and destination_resolved not in target.parents:
                raise ValueError(f"unsafe worker bundle path: {member.name}")
            if member.issym() or member.islnk():
                raise ValueError(f"worker bundle links are not supported: {member.name}")
        tar.extractall(destination)  # noqa: S202


def install_or_update_runtime(server: str, *, force: bool = False) -> dict[str, Any]:
    manifest = fetch_manifest(server)
    digest = str(manifest["sha256"])
    version = str(manifest.get("bundle_version") or "")
    runtime = worker_runtime_dir()
    try:
        current = read_worker_config()
    except (FileNotFoundError, ValueError):
        current = {}
    if not force and runtime.is_dir() and current.get("runtime_digest") == digest:
        return {"updated": False, "sha256": digest, "version": version, "runtime": str(runtime)}

    state_dir = worker_state_dir()
    state_dir.mkdir(parents=True, exist_ok=True)
    payload = _fetch_bytes(str(manifest["url"]), timeout=120)
    actual = hashlib.sha256(payload).hexdigest()
    if actual != digest:
        raise ValueError(f"worker bundle checksum mismatch: expected {digest}, got {actual}")

    with tempfile.TemporaryDirectory(prefix="runtime-install-", dir=state_dir) as temporary:
        temporary_path = Path(temporary)
        archive = temporary_path / "worker.tgz"
        extracted = temporary_path / "runtime"
        archive.write_bytes(payload)
        extracted.mkdir()
        _safe_extract(archive, extracted)
        if not (extracted / "local_shell_mcp").is_dir():
            raise ValueError("worker bundle does not contain local_shell_mcp")
        verify_extracted_worker_runtime(extracted)

        staged = state_dir / f"runtime.next.{os.getpid()}"
        previous = worker_previous_runtime_dir()
        pending = worker_pending_upgrade_path()
        previous_config = worker_previous_config_path()
        had_runtime = runtime.exists()
        if pending.exists():
            raise RuntimeError(
                f"cannot activate another worker runtime while an upgrade is pending: {pending}"
            )
        shutil.rmtree(staged, ignore_errors=True)
        if previous.exists():
            shutil.rmtree(previous)
        previous_config.unlink(missing_ok=True)
        shutil.copytree(extracted, staged)
        if had_runtime and worker_config_path().exists():
            shutil.copy2(worker_config_path(), previous_config)
        try:
            if had_runtime:
                runtime.replace(previous)
            staged.replace(runtime)
            if current:
                update_runtime_metadata(digest, version)
            if had_runtime:
                write_pending_upgrade_marker(
                    old_digest=str(current.get("runtime_digest") or ""),
                    old_version=str(current.get("runtime_version") or ""),
                    new_digest=digest,
                    new_version=version,
                )
        except Exception:
            pending.unlink(missing_ok=True)
            if had_runtime and previous.exists():
                if runtime.exists():
                    shutil.rmtree(runtime)
                previous.replace(runtime)
            if previous_config.exists():
                previous_config.replace(worker_config_path())
            raise
        finally:
            shutil.rmtree(staged, ignore_errors=True)
            if not had_runtime:
                previous_config.unlink(missing_ok=True)
    return {"updated": True, "sha256": digest, "version": version, "runtime": str(runtime)}
