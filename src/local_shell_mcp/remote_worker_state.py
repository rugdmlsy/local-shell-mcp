from __future__ import annotations

import contextlib
import json
import os
import shlex
import shutil
import stat
import sys
import time
from pathlib import Path
from typing import Any

_CONFIG_FILE_NAME = "config.json"
_PATH_MARKER = "# local-shell-mcp"


def _is_windows() -> bool:
    return os.name == "nt"


def user_home() -> Path:
    configured = os.getenv("HOME") or os.getenv("USERPROFILE")
    return Path(configured).expanduser() if configured else Path.home()


def worker_state_dir() -> Path:
    configured = os.getenv("LOCAL_SHELL_MCP_WORKER_STATE_DIR")
    if configured:
        return Path(configured).expanduser()
    xdg_state_home = os.getenv("XDG_STATE_HOME")
    if xdg_state_home:
        return Path(xdg_state_home).expanduser() / "local-shell-mcp-worker"
    return user_home() / ".local" / "state" / "local-shell-mcp-worker"


def worker_runtime_dir() -> Path:
    return worker_state_dir() / "runtime"


def worker_previous_runtime_dir() -> Path:
    return worker_state_dir() / "runtime.previous"


def worker_pending_upgrade_path() -> Path:
    return worker_state_dir() / "pending-upgrade.json"


def worker_previous_config_path() -> Path:
    return worker_state_dir() / "config.previous.json"


def worker_bootstrap_path() -> Path:
    return worker_state_dir() / "worker-bootstrap.py"


def worker_config_path() -> Path:
    return worker_state_dir() / _CONFIG_FILE_NAME


def worker_log_path() -> Path:
    return worker_state_dir() / "worker.log"


def worker_pid_path() -> Path:
    return worker_state_dir() / "worker.pid"


def worker_lock_path() -> Path:
    return worker_state_dir() / "worker.lock"


def worker_launcher_path() -> Path:
    configured = os.getenv("LOCAL_SHELL_MCP_WORKER_BIN_DIR")
    root = Path(configured).expanduser() if configured else user_home() / ".local" / "bin"
    name = "local-shell-mcp.cmd" if _is_windows() else "local-shell-mcp"
    return root / name


def _atomic_write_text(
    path: Path,
    content: str,
    mode: int = 0o600,
    *,
    preserve_existing_mode: bool = False,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    effective_mode = mode
    if preserve_existing_mode:
        with contextlib.suppress(OSError):
            effective_mode = stat.S_IMODE(path.stat().st_mode)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    with contextlib.suppress(OSError):
        temporary.chmod(effective_mode)
    temporary.replace(path)


def read_worker_config() -> dict[str, Any]:
    path = worker_config_path()
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("version") != 1:
        raise ValueError(f"unsupported or invalid worker config: {path}")
    if not str(data.get("server") or ""):
        raise ValueError(f"worker config does not contain a server: {path}")
    return data


def write_worker_config(
    *,
    server: str,
    name: str,
    workdir: str,
    runtime_digest: str = "",
    runtime_version: str = "",
) -> dict[str, Any]:
    data = {
        "version": 1,
        "server": server.rstrip("/"),
        "name": name,
        "workdir": workdir,
        "runtime_digest": runtime_digest,
        "runtime_version": runtime_version,
    }
    _atomic_write_text(worker_config_path(), json.dumps(data, indent=2, sort_keys=True) + "\n")
    return data


def update_runtime_metadata(digest: str, version: str) -> dict[str, Any]:
    data = read_worker_config()
    data["runtime_digest"] = digest
    data["runtime_version"] = version
    _atomic_write_text(worker_config_path(), json.dumps(data, indent=2, sort_keys=True) + "\n")
    return data


def write_pending_upgrade_marker(
    *,
    old_digest: str,
    old_version: str,
    new_digest: str,
    new_version: str,
) -> dict[str, Any]:
    marker = {
        "schema_version": 1,
        "old_digest": old_digest,
        "old_version": old_version,
        "new_digest": new_digest,
        "new_version": new_version,
        "activated_at": time.time(),
        "launch_attempted_at": None,
    }
    _atomic_write_text(
        worker_pending_upgrade_path(),
        json.dumps(marker, indent=2, sort_keys=True) + "\n",
    )
    return marker


def commit_runtime_upgrade() -> bool:
    pending = worker_pending_upgrade_path()
    if not pending.exists():
        return False
    shutil.rmtree(worker_previous_runtime_dir(), ignore_errors=True)
    worker_previous_config_path().unlink(missing_ok=True)
    pending.unlink(missing_ok=True)
    return True


def rollback_pending_runtime_upgrade() -> bool:
    pending = worker_pending_upgrade_path()
    previous = worker_previous_runtime_dir()
    if not pending.exists():
        return False
    if not previous.is_dir():
        raise RuntimeError(f"pending worker upgrade has no rollback runtime: {previous}")
    runtime = worker_runtime_dir()
    failed = worker_state_dir() / f"runtime.failed.{os.getpid()}"
    shutil.rmtree(failed, ignore_errors=True)
    if runtime.exists():
        runtime.replace(failed)
    previous.replace(runtime)
    previous_config = worker_previous_config_path()
    if previous_config.exists():
        previous_config.replace(worker_config_path())
    pending.unlink(missing_ok=True)
    shutil.rmtree(failed, ignore_errors=True)
    return True


def _worker_bootstrap_script() -> str:
    state_home = str(worker_state_dir().resolve())
    return f'''from __future__ import annotations

import json
import os
import shutil
import sys
import time
from pathlib import Path

STATE_HOME = Path({state_home!r})
RUNTIME = STATE_HOME / "runtime"
PREVIOUS = STATE_HOME / "runtime.previous"
PENDING = STATE_HOME / "pending-upgrade.json"
CONFIG = STATE_HOME / "config.json"
PREVIOUS_CONFIG = STATE_HOME / "config.previous.json"


def atomic_write_json(path, payload):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\\n", encoding="utf-8")
    os.replace(temporary, path)


# Only a worker process launch consumes the single candidate attempt. Management
# commands may inspect a pending upgrade without changing rollback state.
worker_run = sys.argv[1:3] == ["worker", "run"]
if worker_run and PENDING.exists():
    marker = json.loads(PENDING.read_text(encoding="utf-8"))
    if marker.get("launch_attempted_at"):
        if not PREVIOUS.is_dir():
            raise RuntimeError(f"pending worker upgrade has no rollback runtime: {{PREVIOUS}}")
        failed = STATE_HOME / f"runtime.failed.{{os.getpid()}}"
        shutil.rmtree(failed, ignore_errors=True)
        if RUNTIME.exists():
            os.replace(RUNTIME, failed)
        os.replace(PREVIOUS, RUNTIME)
        if PREVIOUS_CONFIG.exists():
            os.replace(PREVIOUS_CONFIG, CONFIG)
        PENDING.unlink(missing_ok=True)
        shutil.rmtree(failed, ignore_errors=True)
    else:
        marker["launch_attempted_at"] = time.time()
        atomic_write_json(PENDING, marker)

if not (RUNTIME / "local_shell_mcp").is_dir():
    raise SystemExit(f"local-shell-mcp worker runtime is not installed: {{RUNTIME}}")

vendor = RUNTIME / "vendor"
existing_pythonpath = os.environ.get("PYTHONPATH")
runtime_pythonpath = os.pathsep.join((str(RUNTIME), str(vendor)))
os.environ["PYTHONPATH"] = (
    runtime_pythonpath
    if not existing_pythonpath
    else runtime_pythonpath + os.pathsep + existing_pythonpath
)
sys.path[:0] = [str(RUNTIME), str(vendor)]

from local_shell_mcp.main import main

main(sys.argv[1:])
'''


def install_launcher() -> Path:
    launcher = worker_launcher_path()
    bootstrap = worker_bootstrap_path()
    python = str(Path(sys.executable).resolve())
    _atomic_write_text(bootstrap, _worker_bootstrap_script(), 0o600)
    if _is_windows():
        script = f'''@echo off
setlocal
"{python}" "{bootstrap}" %*
exit /b %ERRORLEVEL%
'''
    else:
        script = f'''#!/bin/sh
set -eu
exec {shlex.quote(python)} {shlex.quote(str(bootstrap))} "$@"
'''
    _atomic_write_text(launcher, script, 0o755)
    return launcher


def _append_path_line(path: Path, line: str) -> bool:
    try:
        existing = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        existing = ""
    if _PATH_MARKER in existing:
        return False
    separator = "" if not existing or existing.endswith("\n") else "\n"
    _atomic_write_text(
        path,
        existing + separator + line + "\n",
        0o644,
        preserve_existing_mode=True,
    )
    return True


def _ensure_windows_user_path(bin_dir: Path) -> None:
    import winreg

    with winreg.CreateKeyEx(
        winreg.HKEY_CURRENT_USER,
        "Environment",
        0,
        winreg.KEY_QUERY_VALUE | winreg.KEY_SET_VALUE,
    ) as key:
        try:
            value, value_type = winreg.QueryValueEx(key, "Path")
        except FileNotFoundError:
            value, value_type = "", winreg.REG_EXPAND_SZ
        entries = [entry for entry in str(value).split(os.pathsep) if entry]
        normalized = {os.path.normcase(os.path.normpath(entry)) for entry in entries}
        candidate = str(bin_dir)
        if os.path.normcase(os.path.normpath(candidate)) not in normalized:
            entries.insert(0, candidate)
            winreg.SetValueEx(key, "Path", 0, value_type, os.pathsep.join(entries))


def ensure_user_bin_on_path(shell: str | None = None) -> list[Path]:
    bin_dir = worker_launcher_path().parent
    current = os.environ.get("PATH", "").split(os.pathsep)
    if str(bin_dir) not in current:
        os.environ["PATH"] = str(bin_dir) + os.pathsep + os.environ.get("PATH", "")

    if _is_windows():
        _ensure_windows_user_path(bin_dir)
        return []

    home = user_home()
    default_bin = home / ".local" / "bin"
    posix_bin = '"$HOME/.local/bin"' if bin_dir == default_bin else shlex.quote(str(bin_dir))
    fish_bin = '"$HOME/.local/bin"' if bin_dir == default_bin else shlex.quote(str(bin_dir))
    shell_name = Path(shell or os.getenv("SHELL") or "sh").name
    targets: list[tuple[Path, str]] = [
        (home / ".profile", f"export PATH={posix_bin}:$PATH {_PATH_MARKER}")
    ]
    if shell_name == "bash":
        targets.append((home / ".bashrc", f"export PATH={posix_bin}:$PATH {_PATH_MARKER}"))
    elif shell_name == "zsh":
        targets.append((home / ".zshrc", f"export PATH={posix_bin}:$PATH {_PATH_MARKER}"))
    elif shell_name == "fish":
        targets.append(
            (
                home / ".config" / "fish" / "config.fish",
                f"fish_add_path --prepend {fish_bin} {_PATH_MARKER}",
            )
        )

    changed = []
    for path, line in targets:
        if _append_path_line(path, line):
            changed.append(path)
    return changed
