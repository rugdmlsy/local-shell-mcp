from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

import local_shell_mcp.restart_ops as restart
from local_shell_mcp.settings import get_settings


def _configure(tmp_path, monkeypatch):
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path / "workspace"))
    monkeypatch.setenv("LOCAL_SHELL_MCP_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LOCAL_SHELL_MCP_AUTH_MODE", "none")
    get_settings.cache_clear()


def test_schedule_systemd_restart_is_one_shot_and_rate_limited(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    calls = []
    monkeypatch.setattr(restart, "_target", lambda role: ("systemd", "user", "lsm.service"))
    monkeypatch.setattr(restart, "_launcher", lambda role: ["/usr/bin/lsm"])

    def fake_run(command, **kwargs):
        calls.append(command)
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    monkeypatch.setattr(restart, "_run", fake_run)
    first = restart.schedule_restart("controller", delay_s=1, health_timeout_s=999, reason="test")

    assert first["status"] == "scheduled"
    assert first["delay_s"] == restart.MIN_DELAY_S
    assert first["health_timeout_s"] == restart.MAX_HEALTH_TIMEOUT_S
    command = calls[-1]
    assert "--property=Type=oneshot" in command
    assert "--property=Restart=no" in command
    assert "--collect" in command
    assert "--no-block" in command
    assert not any("KeepAlive" in item for item in command)

    with pytest.raises(RuntimeError, match="already scheduled"):
        restart.schedule_restart("controller")


def test_launchd_restart_plist_never_uses_keepalive(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    monkeypatch.setattr(restart, "_target", lambda role: ("launchd", "user", "gui/501/lsm"))
    monkeypatch.setattr(restart, "_launcher", lambda role: ["/usr/local/bin/lsm"])
    calls = []

    def fake_run(command, **kwargs):
        calls.append(command)
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    monkeypatch.setattr(restart, "_run", fake_run)
    result = restart.schedule_restart("controller")
    plist = next((tmp_path / "state" / "restarts").glob("*.plist"))
    import plistlib

    with plist.open("rb") as handle:
        payload = plistlib.load(handle)
    assert payload["RunAtLoad"] is True
    assert payload["KeepAlive"] is False
    assert payload["ExitTimeOut"] == 5
    assert calls[-1][:3] == ["launchctl", "bootstrap", f"gui/{__import__('os').getuid()}"]
    assert result["supervisor"].startswith("com.fwerkor.local-shell-mcp.restart.")


def test_supervisor_restarts_once_and_records_health_success(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    path = tmp_path / "restart.json"
    path.write_text(
        json.dumps({"restart_id": "abc", "role": "controller", "status": "scheduled"}),
        encoding="utf-8",
    )
    calls = []
    monkeypatch.setattr(restart.time, "sleep", lambda seconds: None)
    monkeypatch.setattr(restart, "_restart_target", lambda *args: calls.append(args))
    monkeypatch.setattr(restart, "_manager_active", lambda *args: True)
    pids = iter([101, 202])
    monkeypatch.setattr(restart, "_manager_pid", lambda *args: next(pids))
    monkeypatch.setattr(restart, "_controller_healthy", lambda port: True)
    args = SimpleNamespace(
        status_path=str(path),
        restart_id="abc",
        role="controller",
        manager="systemd",
        scope="system",
        target="lsm.service",
        delay_s=3,
        health_timeout_s=30,
        health_port=8765,
        maintenance_label=None,
        maintenance_plist=None,
    )

    assert restart.run_supervisor(args) == 0
    assert calls == [("systemd", "system", "lsm.service")]
    record = json.loads(path.read_text(encoding="utf-8"))
    assert record["status"] == "succeeded"
    assert record["attempts"] == 1
    assert record["previous_pid"] == 101
    assert record["current_pid"] == 202


def test_supervisor_health_timeout_does_not_retry_restart(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    path = tmp_path / "restart.json"
    path.write_text(json.dumps({"restart_id": "abc", "role": "worker"}), encoding="utf-8")
    restart_calls = []
    ticks = iter([0.0, 0.0, 10.0, 10.0])
    monkeypatch.setattr(restart.time, "sleep", lambda seconds: None)
    monkeypatch.setattr(restart.time, "monotonic", lambda: next(ticks, 10.0))
    monkeypatch.setattr(restart, "_restart_target", lambda *args: restart_calls.append(args))
    monkeypatch.setattr(restart, "_manager_active", lambda *args: False)
    monkeypatch.setattr(restart, "_manager_pid", lambda *args: 101)
    args = SimpleNamespace(
        status_path=str(path),
        restart_id="abc",
        role="worker",
        manager="systemd",
        scope="user",
        target="local-shell-mcp-worker.service",
        delay_s=3,
        health_timeout_s=1,
        health_port=8765,
        maintenance_label=None,
        maintenance_plist=None,
    )

    assert restart.run_supervisor(args) == 1
    assert len(restart_calls) == 1
    assert json.loads(path.read_text(encoding="utf-8"))["status"] == "failed"


def test_systemd_restart_target_is_nonblocking(monkeypatch):
    calls = []

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    monkeypatch.setattr(restart, "_run", fake_run)
    restart._restart_target("systemd", "system", "lsm.service")  # noqa: SLF001
    assert calls == [
        (["systemctl", "--no-block", "restart", "lsm.service"], {"timeout": 5})
    ]


def test_write_record_preserves_existing_owner(tmp_path, monkeypatch):
    path = tmp_path / "record.json"
    path.write_text('{"status":"scheduled"}', encoding="utf-8")
    stat = path.stat()
    calls = []
    original_chown = restart.os.chown

    def tracked_chown(target, uid, gid):
        calls.append((uid, gid))
        original_chown(target, uid, gid)

    monkeypatch.setattr(restart.os, "chown", tracked_chown)
    restart._write_record(path, {"status": "succeeded"})  # noqa: SLF001

    assert calls == [(stat.st_uid, stat.st_gid)]
    assert json.loads(path.read_text(encoding="utf-8"))["status"] == "succeeded"


def test_restart_status_returns_latest_record(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    directory = tmp_path / "state" / "restarts"
    directory.mkdir(parents=True)
    aid = "a" * 32
    bid = "b" * 32
    (directory / f"{aid}.json").write_text(
        json.dumps({"restart_id": aid, "created_at": 1, "status": "succeeded"})
    )
    (directory / f"{bid}.json").write_text(
        json.dumps({"restart_id": bid, "created_at": 2, "status": "failed"})
    )

    assert restart.restart_status("controller")["restart_id"] == bid
    assert restart.restart_status("controller", "a" * 32)["status"] == "succeeded"


def test_restart_status_rejects_path_traversal_id(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    with pytest.raises(ValueError, match="32-character lowercase hex"):
        restart.restart_status("controller", "../../escape")
