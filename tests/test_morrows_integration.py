from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

import pytest
from starlette.testclient import TestClient

from local_shell_mcp.audit import audit, query_audit
from local_shell_mcp.auth import _CURRENT_PRINCIPAL, Principal
from local_shell_mcp.capabilities import issue_capability, resolve_capability, revoke_capability
from local_shell_mcp.execution_scope import execution_session
from local_shell_mcp.jobs import list_jobs, start_managed_job, tail_job
from local_shell_mcp.main import _build_mcp_http_app
from local_shell_mcp.session_runtime import SessionRuntimeManager, get_session_runtime_manager
from local_shell_mcp.settings import get_settings
from local_shell_mcp.shell_ops import read_shell, shell_owner, start_shell
from local_shell_mcp.tools import build_mcp


def _settings(tmp_path, monkeypatch):
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("LOCAL_SHELL_MCP_STATE_DIR", str(tmp_path / ".state"))
    monkeypatch.setenv("LOCAL_SHELL_MCP_AUDIT_LOG_PATH", str(tmp_path / "audit.jsonl"))
    monkeypatch.setenv("LOCAL_SHELL_MCP_AUTH_MODE", "none")
    monkeypatch.setenv("LOCAL_SHELL_MCP_PUBLIC_BASE_URL", "http://testserver")
    monkeypatch.setenv("LOCAL_SHELL_MCP_REMOTE_ENABLED", "false")
    get_settings.cache_clear()


def test_keyed_session_is_concurrent_durable_and_replayable_after_terminal_delete(tmp_path):
    state = tmp_path / ".state"
    first = SessionRuntimeManager(state)
    second = SessionRuntimeManager(state)
    with ThreadPoolExecutor(max_workers=2) as pool:
        one = pool.submit(first.manage, "shared", action="start", idempotency_key="external:42")
        two = pool.submit(second.manage, "shared", action="start", idempotency_key="external:42")
        ids = {one.result()["session_id"], two.result()["session_id"]}
    assert len(ids) == 1
    session_id = ids.pop()
    first.manage("shared", action="finish", session_id=session_id)
    assert second.manage("shared", action="start", idempotency_key="external:42")["session_id"] == session_id
    assert second.manage("other", action="start", idempotency_key="external:42")["session_id"] != session_id
    first.manage("shared", action="delete", session_id=session_id)
    assert second.manage("shared", action="start", idempotency_key="external:42")["session_id"] != session_id


def test_resolved_local_and_transfer_nodes_are_only_a_session_index(tmp_path):
    manager = SessionRuntimeManager(tmp_path / ".state")
    session_id = manager.manage("shared", action="start")["session_id"]
    manager.begin_tool_call(session_id, "call-1", subject="shared", execution_machines=["local"])
    manager.begin_tool_call(session_id, "call-2", subject="shared",
                            execution_machines=["local", "node-01", "node-02"])
    state = SessionRuntimeManager(tmp_path / ".state").get(session_id, subject="shared")
    assert state["machines_touched"] == ["local", "node-01", "node-02"]
    assert state["in_flight_calls"] == 2


def test_audit_query_filters_logical_session_not_shell_session(tmp_path, monkeypatch):
    _settings(tmp_path, monkeypatch)
    audit("mcp_tool_call_start", call_id="morrows-a", tool="run_shell",
          logical_session="s_one", session="shell_one")
    audit("mcp_tool_call_end", call_id="morrows-a", tool="run_shell",
          logical_session="s_one", session="shell_one", ok=True)
    audit("mcp_tool_call_start", call_id="morrows-b", tool="run_shell",
          logical_session="s_two", session="shell_two")
    found = query_audit(logical_session_id="s_one")
    assert len(found["entries"]) == 1
    assert found["entries"][0]["logical_session_id"] == "s_one"
    assert found["entries"][0]["session"] == "shell_one"


@pytest.mark.asyncio
async def test_independent_shell_owner_persists_and_rejects_other_session(tmp_path, monkeypatch):
    _settings(tmp_path, monkeypatch)

    async def fake_start(_cwd, _name, _command):
        return {"session_id": "shell-independent", "backend": "fake"}

    monkeypatch.setattr("local_shell_mcp.shell_ops._start_shell_unlocked", fake_start)
    with execution_session("s_one"):
        shell = await start_shell()
    assert shell["logical_session_id"] == "s_one"
    assert shell_owner("shell-independent")["logical_session_id"] == "s_one"
    with execution_session("s_two"), pytest.raises(PermissionError, match="different Logical Session"):
        await read_shell("shell-independent")


@pytest.mark.asyncio
async def test_managed_job_owner_is_persisted_without_manual_binding(tmp_path, monkeypatch):
    _settings(tmp_path, monkeypatch)
    monkeypatch.setattr("local_shell_mcp.jobs._launch_managed_job", lambda *_args: None)
    with execution_session("s_job"):
        job = await start_managed_job("transfer", {"source_path":"a", "destination_path":"b"})
        visible = await list_jobs()
    assert job["logical_session_id"] == "s_job"
    assert job["machine"] == "local"
    assert [row["job_id"] for row in visible["jobs"]] == [job["job_id"]]
    with execution_session("s_other"):
        assert (await list_jobs())["jobs"] == []
        with pytest.raises(PermissionError, match="different Logical Session"):
            await tail_job(job["job_id"])


@pytest.mark.asyncio
async def test_remote_resource_query_reports_partial_results(tmp_path, monkeypatch):
    _settings(tmp_path, monkeypatch)
    from local_shell_mcp import control_plane

    session_id = get_session_runtime_manager().manage("shared", action="start")["session_id"]
    get_session_runtime_manager().begin_tool_call(
        session_id, "remote-call", subject="shared", execution_machines=["local", "node-offline"]
    )

    class Offline:
        async def call(self, *_args, **_kwargs):
            raise RuntimeError("offline")

    monkeypatch.setattr(control_plane, "remote_manager", lambda: Offline())
    result = await control_plane._enumerate(session_id, "jobs")
    assert result["complete"] is False
    assert result["unreachable_machines"] == ["node-offline"]


@pytest.mark.asyncio
async def test_run_bound_agent_can_get_report_but_cannot_end_session(tmp_path, monkeypatch):
    _settings(tmp_path, monkeypatch)
    session_id = get_session_runtime_manager().manage("shared", action="start")["session_id"]
    principal = Principal(email=None, subject="shared", claims={"auth":"none","bound_session":session_id})
    token = _CURRENT_PRINCIPAL.set(principal)
    try:
        tool = build_mcp()._tool_manager._tools["session_manage"]
        with pytest.raises(PermissionError, match="lifecycle"):
            await tool.fn(action="finish", session_id=session_id)
        with pytest.raises(PermissionError, match="outside"):
            await tool.fn(action="get", session_id="s_old")
        result = await tool.fn(action="get", session_id=session_id)
        assert result["ok"] is True
    finally:
        _CURRENT_PRINCIPAL.reset(token)


def test_control_credential_and_agent_capability_are_separate_http_paths(tmp_path, monkeypatch):
    _settings(tmp_path, monkeypatch)
    monkeypatch.setenv("LOCAL_SHELL_MCP_CONTROL_API_KEY", "trusted-control-key")
    monkeypatch.setenv("LOCAL_SHELL_MCP_REQUIRE_SESSION_CAPABILITY", "true")
    get_settings.cache_clear()
    with TestClient(_build_mcp_http_app(build_mcp()), base_url="http://testserver") as client:
        assert client.post("/api/control/sessions", json={"subject":"shared"}).status_code == 401
        headers = {"X-LSM-Control-Key":"trusted-control-key"}
        created = client.post("/api/control/sessions", headers=headers,
            json={"subject":"shared","idempotency_key":"morrows:run:test"})
        assert created.status_code == 200
        session_id = created.json()["session"]["session_id"]
        issued = client.post(f"/api/control/sessions/{session_id}/capabilities", headers=headers,
            json={"subject":"shared"})
        assert issued.status_code == 200
        capability = issued.json()["capability"]
        assert resolve_capability(capability)["session_id"] == session_id
        initialize = {"jsonrpc":"2.0","id":1,"method":"initialize",
            "params":{"protocolVersion":"2025-06-18","capabilities":{},
                      "clientInfo":{"name":"test","version":"1"}}}
        assert client.post("/mcp", json=initialize,
            headers={"accept":"application/json, text/event-stream",
                     "content-type":"application/json"}).status_code == 401
        agent_headers = {"accept":"application/json, text/event-stream",
                         "content-type":"application/json",
                         "X-LSM-Session-Capability":capability}
        initialized = client.post("/mcp", json=initialize, headers=agent_headers)
        assert initialized.status_code == 200
        agent_headers["mcp-session-id"] = initialized.headers["mcp-session-id"]
        agent_headers["mcp-protocol-version"] = "2025-06-18"
        allowed = client.post("/mcp", json={"jsonrpc":"2.0","id":2,"method":"tools/call",
            "params":{"name":"session_manage","arguments":{"action":"get","session_id":session_id}}},
            headers=agent_headers)
        assert allowed.status_code == 200
        assert session_id in allowed.text
        denied = client.post("/mcp", json={"jsonrpc":"2.0","id":3,"method":"tools/call",
            "params":{"name":"session_manage","arguments":{"action":"finish","session_id":session_id}}},
            headers=agent_headers)
        assert denied.status_code == 200
        assert "Run-bound Agent cannot change Session lifecycle" in denied.text
        old_session = client.post("/mcp", json={"jsonrpc":"2.0","id":4,"method":"tools/call",
            "params":{"name":"session_manage","arguments":{"action":"get","session_id":"s_old"}}},
            headers=agent_headers)
        assert old_session.status_code == 200
        assert "outside the bound Logical Session" in old_session.text
        rotated = client.post(f"/api/control/sessions/{session_id}/capabilities", headers=headers,
            json={"subject":"shared"})
        assert rotated.status_code == 200
        assert resolve_capability(capability) is None
        assert resolve_capability(rotated.json()["capability"]) is not None
        revoke_capability(issued.json()["capability_id"])
        assert resolve_capability(capability) is None


def test_control_cleanup_wait_is_bounded_and_never_reports_false_cancel(tmp_path, monkeypatch):
    _settings(tmp_path, monkeypatch)
    monkeypatch.setenv("LOCAL_SHELL_MCP_CONTROL_API_KEY", "trusted-control-key")
    get_settings.cache_clear()
    manager = get_session_runtime_manager()
    session_id = manager.manage("shared", action="start")["session_id"]
    lease = manager.begin_tool_call(session_id, "ordinary-call", subject="shared")
    capability = issue_capability(session_id, "shared")
    headers = {"X-LSM-Control-Key":"trusted-control-key"}
    with TestClient(_build_mcp_http_app(build_mcp()), base_url="http://testserver") as client:
        pending = client.post(f"/api/control/sessions/{session_id}/cleanup", headers=headers,
            json={"subject":"shared","wait_seconds":0})
        assert pending.status_code == 200
        assert pending.json()["complete"] is False
        assert pending.json()["session"]["status"] == "active"
        assert resolve_capability(capability["capability"]) is None
        manager.finish_tool_call(lease, "tool.completed")
        cleaned = client.post(f"/api/control/sessions/{session_id}/cleanup", headers=headers,
            json={"subject":"shared","wait_seconds":0})
        assert cleaned.status_code == 200
        assert cleaned.json()["complete"] is True
        assert cleaned.json()["session"]["status"] == "cancelled"
