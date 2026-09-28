import json
import time

import pytest

import local_shell_mcp.jobs as jobs_module
import local_shell_mcp.notification_runtime as notification_runtime
from local_shell_mcp import remote
from local_shell_mcp.settings import get_settings


@pytest.mark.asyncio
async def test_mobile_events_persist_poll_ack_and_deduplicate(tmp_path, monkeypatch):
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("LOCAL_SHELL_MCP_STATE_DIR", str(tmp_path / ".state"))
    get_settings.cache_clear()

    manager = remote.RemoteManager()
    manager._registry_loaded = True
    worker = remote.RemoteWorker(
        "iphone", "token-ios", capabilities=["mobile", "mobile.controller_events"]
    )
    manager.workers[worker.name] = worker
    manager.tokens[worker.token] = worker.name
    monkeypatch.setattr(manager, "_wake_is_configured", lambda _worker: False)

    queued = await manager.queue_mobile_event(
        event_id="event-one",
        event_type="notification",
        title="Test event",
        body="Delivered on the poll channel",
        machine="iphone",
    )
    assert queued["queued_machines"] == ["iphone"]

    polled = await manager.poll(worker.token, {"supports_self_update": False})
    assert polled["job"] is None
    assert [event["id"] for event in polled["events"]] == ["event-one"]

    acked = await manager.acknowledge_mobile_events(worker.token, ["event-one"])
    assert acked == {"acked": ["event-one"], "count": 1}
    assert worker.pending_events == []
    assert "event-one" in worker.recent_event_ids

    duplicate = await manager.queue_mobile_event(
        event_id="event-one",
        event_type="notification",
        title="Duplicate",
        body="Must not be redelivered",
        machine="iphone",
    )
    assert duplicate["queued_machines"] == []
    assert duplicate["duplicate_machines"] == ["iphone"]

    reloaded = remote.RemoteManager()
    reloaded.list_machines()
    restored = reloaded.workers["iphone"]
    assert restored.pending_events == []
    assert "event-one" in restored.recent_event_ids


@pytest.mark.asyncio
async def test_legacy_mobile_worker_pending_events_do_not_starve_jobs(tmp_path, monkeypatch):
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("LOCAL_SHELL_MCP_STATE_DIR", str(tmp_path / ".state"))
    get_settings.cache_clear()

    manager = remote.RemoteManager()
    manager._registry_loaded = True
    worker = remote.RemoteWorker("iphone", "token-ios", capabilities=["mobile"])
    manager.workers[worker.name] = worker
    manager.tokens[worker.token] = worker.name
    monkeypatch.setattr(manager, "_wake_is_configured", lambda _worker: False)

    await manager.queue_mobile_event(
        event_id="event-for-new-worker",
        event_type="notification",
        title="Deferred until upgrade",
        body="Legacy workers must keep receiving normal jobs.",
        machine="iphone",
    )
    worker.queue.put_nowait({"id": "job-battery", "tool": "mobile_action", "args": {}})

    polled = await manager.poll(worker.token, {"supports_self_update": False})

    assert polled["job"]["id"] == "job-battery"
    assert "events" not in polled
    assert [event["id"] for event in worker.pending_events] == ["event-for-new-worker"]


@pytest.mark.asyncio
async def test_worker_event_fans_out_only_to_mobile_and_records_source(tmp_path, monkeypatch):
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("LOCAL_SHELL_MCP_STATE_DIR", str(tmp_path / ".state"))
    get_settings.cache_clear()

    manager = remote.RemoteManager()
    manager._registry_loaded = True
    desktop = remote.RemoteWorker("desktop", "token-desktop", capabilities=["shell", "jobs"])
    iphone = remote.RemoteWorker("iphone", "token-ios", capabilities=["mobile"])
    manager.workers = {desktop.name: desktop, iphone.name: iphone}
    manager.tokens = {desktop.token: desktop.name, iphone.token: iphone.name}
    monkeypatch.setattr(manager, "_wake_is_configured", lambda _worker: False)

    result = await manager.submit_worker_event(
        desktop.token,
        {
            "id": "job-finish:1",
            "type": "job_completed",
            "title": "Render complete",
            "body": "succeeded · exit 0",
            "data": {"job_id": "job-1"},
        },
    )

    assert result["queued_machines"] == ["iphone"]
    assert desktop.pending_events == []
    assert iphone.pending_events[0]["data"]["source_machine"] == "desktop"


@pytest.mark.asyncio
async def test_job_completion_notifications_are_stable_markable_and_not_retroactive(
    tmp_path, monkeypatch
):
    state_dir = tmp_path / ".state"
    state_dir.mkdir(parents=True)
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("LOCAL_SHELL_MCP_STATE_DIR", str(state_dir))
    get_settings.cache_clear()

    now = time.time()
    rows = [
        {
            "job_id": "job-new",
            "name": "New render",
            "status": "succeeded",
            "command": "render",
            "cwd": ".",
            "created_at": now - 10,
            "updated_at": now,
            "completed_at": now,
            "exit_code": 0,
            "attempts": 1,
            "notify_on_finish": True,
            "notify_title": "Render complete",
            "notify_delivery_version": 1,
        },
        {
            "job_id": "job-old",
            "name": "Historical job",
            "status": "succeeded",
            "command": "old",
            "cwd": ".",
            "created_at": now - 1000,
            "updated_at": now - 900,
            "completed_at": now - 900,
            "exit_code": 0,
            "attempts": 1,
            "notify_on_finish": True,
        },
    ]
    payload = json.dumps({"version": jobs_module.JOB_STORE_VERSION, "jobs": rows})
    (state_dir / jobs_module.JOB_STORE_FILE_NAME).write_text(payload, encoding="utf-8")
    (state_dir / jobs_module.JOB_STORE_BACKUP_FILE_NAME).write_text(payload, encoding="utf-8")

    async def no_shells():
        return {"sessions": []}

    monkeypatch.setattr(jobs_module, "list_shells", no_shells)

    first = await jobs_module.collect_pending_job_notifications()
    second = await jobs_module.collect_pending_job_notifications()
    assert len(first) == 1
    assert first[0]["id"] == second[0]["id"]
    assert first[0]["data"]["job_id"] == "job-new"
    assert first[0]["title"] == "Render complete"

    assert jobs_module.mark_job_notification_sent(first[0]["id"]) is True
    assert await jobs_module.collect_pending_job_notifications() == []


@pytest.mark.asyncio
async def test_session_watchdog_reports_goal_lease_expiry_without_claiming_exact_platform_timeout(
    monkeypatch,
):
    class FakeSessions:
        def list_sessions(self, *, subject):  # noqa: ARG002
            return [
                {
                    "session_id": "session-1",
                    "label": "Long task",
                    "status": "active",
                    "plan": {
                        "plan_id": "plan-1",
                        "status": "active",
                        "steps": [{"id": "work", "text": "work", "status": "active"}],
                        "last_agent_activity": 100.0,
                        "execution_lease_s": 1800,
                        "continuation_due_at": 1000.0,
                        "continuation_due": True,
                        "continuation_count": 0,
                        "auto_continue_exhausted": False,
                    },
                }
            ]

    calls = []

    class FakeRemote:
        async def queue_mobile_event(self, **kwargs):
            calls.append(kwargs)
            return {"accepted": True, "queued_machines": ["iphone"]}

    monkeypatch.setattr(notification_runtime, "get_session_runtime_manager", lambda: FakeSessions())
    monkeypatch.setattr(notification_runtime, "remote_manager", lambda: FakeRemote())

    await notification_runtime._dispatch_session_notifications()

    assert len(calls) == 1
    assert calls[0]["event_type"] == "agent_interrupted_or_expired"
    assert "30 min" in calls[0]["body"]
    assert "may have been interrupted" in calls[0]["body"]
    assert "platform timeout reached" not in calls[0]["body"].lower()


@pytest.mark.asyncio
async def test_tracked_job_terminal_has_independent_idempotent_mobile_and_morrows_consumers(
    tmp_path, monkeypatch
):
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("LOCAL_SHELL_MCP_STATE_DIR", str(tmp_path / ".state"))
    get_settings.cache_clear()

    manager = remote.RemoteManager()
    manager._registry_loaded = True
    desktop = remote.RemoteWorker("desktop", "token-desktop", capabilities=["shell", "jobs"])
    iphone = remote.RemoteWorker(
        "iphone", "token-ios", capabilities=["mobile", "mobile.controller_events"]
    )
    manager.workers = {desktop.name: desktop, iphone.name: iphone}
    manager.tokens = {desktop.token: desktop.name, iphone.token: iphone.name}
    monkeypatch.setattr(manager, "_wake_is_configured", lambda _worker: False)

    morrows_deliveries: list[str] = []

    async def fake_morrows_delivery(event):
        morrows_deliveries.append(str(event["id"]))

    monkeypatch.setattr(manager, "_deliver_job_event_to_morrows", fake_morrows_delivery)

    payload = {
        "id": "job-finish:tracked:1",
        "type": "tracked_job_terminal",
        "title": "Experiment complete",
        "body": "succeeded · exit 0",
        "data": {
            "job_id": "job-tracked",
            "logical_session_id": "s_morrows",
            "attempt": 1,
            "status": "succeeded",
            "exit_code": 0,
            "completed_at": 123.0,
            "terminal_reason": "process exited successfully",
            "summary_ref": "work/report.json",
            "result": {"records": 147},
            "notify_on_finish": True,
        },
    }

    first = await manager.submit_worker_event(desktop.token, payload)
    assert first["accepted"] is True
    assert first["duplicate"] is False
    assert morrows_deliveries == ["job-finish:tracked:1"]
    assert [event["id"] for event in iphone.pending_events] == ["job-finish:tracked:1"]
    assert iphone.pending_events[0]["type"] == "job_completed"

    second = await manager.submit_worker_event(desktop.token, payload)
    assert second["accepted"] is True
    assert second["duplicate"] is True
    assert morrows_deliveries == ["job-finish:tracked:1"]
    assert [event["id"] for event in iphone.pending_events] == ["job-finish:tracked:1"]

    saved = next(event for event in manager.job_events if event["id"] == "job-finish:tracked:1")
    assert saved["mobile_delivered_at"]
    assert saved["morrows_delivered_at"]


def test_job_event_retention_never_prunes_undelivered_events(tmp_path, monkeypatch):
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("LOCAL_SHELL_MCP_STATE_DIR", str(tmp_path / ".state"))
    get_settings.cache_clear()
    monkeypatch.setattr(remote, "MAX_REMOTE_JOB_EVENTS", 2)

    manager = remote.RemoteManager()
    manager.job_events = [
        {
            "id": "delivered-old",
            "mobile_delivered_at": 1.0,
            "morrows_delivered_at": 1.0,
        },
        {
            "id": "pending-morrows",
            "mobile_delivered_at": 1.0,
            "morrows_delivered_at": None,
        },
        {
            "id": "pending-mobile",
            "mobile_delivered_at": None,
            "morrows_delivered_at": 1.0,
        },
    ]
    manager._prune_job_events_locked()

    assert [event["id"] for event in manager.job_events] == [
        "pending-morrows",
        "pending-mobile",
    ]

    manager.job_events.append(
        {
            "id": "pending-both",
            "mobile_delivered_at": None,
            "morrows_delivered_at": None,
        }
    )
    manager._prune_job_events_locked()
    assert [event["id"] for event in manager.job_events] == [
        "pending-morrows",
        "pending-mobile",
        "pending-both",
    ]


@pytest.mark.asyncio
async def test_morrows_job_event_push_reuses_lsm_control_key(tmp_path, monkeypatch):
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("LOCAL_SHELL_MCP_STATE_DIR", str(tmp_path / ".state"))
    monkeypatch.setenv("LOCAL_SHELL_MCP_CONTROL_API_KEY", "shared-control-key")
    monkeypatch.setenv(
        "LOCAL_SHELL_MCP_MORROWS_JOB_EVENT_URL",
        "http://127.0.0.1:8787/api/internal/lsm/job-events",
    )
    get_settings.cache_clear()

    captured = {}

    def fake_post(url, payload, headers, timeout):
        captured["url"] = url
        captured["headers"] = dict(headers)
        captured["json"] = dict(payload)
        captured["timeout"] = timeout

    monkeypatch.setattr(remote, "_post_json_without_environment", fake_post)

    manager = remote.RemoteManager()
    await manager._deliver_job_event_to_morrows(
        {
            "id": "job-finish:auth:1",
            "data": {
                "job_id": "job-auth",
                "source_machine": "morrow-node-01",
                "logical_session_id": "s_auth",
                "attempt": 1,
                "status": "succeeded",
                "exit_code": 0,
                "completed_at": 123.0,
                "terminal_reason": "process exited successfully",
            },
        }
    )

    assert captured["url"].endswith("/api/internal/lsm/job-events")
    assert captured["headers"] == {"X-LSM-Control-Key": "shared-control-key"}
    assert captured["timeout"] == 20.0
    assert captured["json"]["event_id"] == "job-finish:auth:1"
    assert captured["json"]["logical_session_id"] == "s_auth"
    assert captured["json"]["completed_at"] == "1970-01-01T00:02:03Z"
