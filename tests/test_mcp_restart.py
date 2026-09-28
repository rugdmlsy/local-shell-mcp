"""Exercise a legacy client's cached transport ID against real new processes."""

import json
import os
import socket
import subprocess
import sys
import time
from contextlib import contextmanager

import httpx

from local_shell_mcp.auth import McpSessionLimitMiddleware
from local_shell_mcp.main import _build_mcp_http_app
from local_shell_mcp.oauth import ALL_OAUTH_SCOPES, issue_access_token
from local_shell_mcp.settings import get_settings
from local_shell_mcp.tools import build_mcp


def _payload(response):
    assert response.status_code == 200, response.text
    if response.headers.get("content-type", "").startswith("application/json"):
        return response.json()
    return json.loads(
        next(line[6:] for line in response.text.splitlines() if line.startswith("data: "))
    )


def test_stateless_http_has_no_sdk_session_limits(tmp_path, monkeypatch):
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path))
    get_settings.cache_clear()
    mcp = build_mcp()
    app = _build_mcp_http_app(mcp)
    assert mcp.settings.stateless_http is True
    assert mcp._session_manager.stateless is True
    assert mcp._session_manager.session_idle_timeout is None
    assert all(
        middleware.cls is not McpSessionLimitMiddleware for middleware in app.user_middleware
    )


def test_legacy_id_survives_upgrade_and_process_restart(tmp_path, monkeypatch):
    """Never reinitialize after legacy bootstrap; preserve auth and logical state.

    Each server is a fresh subprocess, sharing only the durable state directory.
    The old SDK-issued ID remains on every request, matching a client that does
    not respond to 404 by initializing a new transport. No request is replayed.
    """
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    settings = {
        "WORKSPACE_ROOT": str(tmp_path),
        "STATE_DIR": str(tmp_path / "state"),
        "AUDIT_LOG_PATH": str(tmp_path / "audit.jsonl"),
        "PUBLIC_BASE_URL": base,
        "HOST": "127.0.0.1",
        "PORT": str(port),
        "AUTH_MODE": "oauth",
        "AUTH_BYPASS_LOCALHOST": "false",
        "REMOTE_ENABLED": "false",
        "OAUTH_JWT_SECRET": "restart-test-secret-at-least-thirty-two-bytes",
        "MCP_MAX_SESSIONS": "1",
    }
    for key, value in settings.items():
        monkeypatch.setenv("LOCAL_SHELL_MCP_" + key, value)
    get_settings.cache_clear()
    token = issue_access_token(
        client_id="restart-test", scope=" ".join(ALL_OAUTH_SCOPES), resource=base, issuer=base
    )
    headers = {
        "accept": "application/json, text/event-stream",
        "mcp-protocol-version": "2025-06-18",
        "authorization": f"Bearer {token}",
    }
    code = """
import os
from local_shell_mcp.main import _build_mcp_http_app, _run_uvicorn
from local_shell_mcp.settings import get_settings
from local_shell_mcp.tools import build_mcp
mcp = build_mcp()
if os.environ['TEST_STATEFUL'] == '1':
    mcp.settings.stateless_http = False
_run_uvicorn(_build_mcp_http_app(mcp), get_settings())
"""

    @contextmanager
    def server(name, stateful=False):
        # Retain startup diagnostics while guaranteeing cleanup on assertion failure.
        environment = {**os.environ, "TEST_STATEFUL": "1" if stateful else "0"}
        with (tmp_path / f"{name}.log").open("w+") as log:
            process = subprocess.Popen(
                [sys.executable, "-c", code], env=environment, stdout=log, stderr=log
            )
            try:
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    assert process.poll() is None, f"{name} exited; see {log.name}"
                    try:
                        if httpx.get(base + "/healthz", timeout=0.5).status_code == 200:
                            break
                    except httpx.TransportError:
                        pass
                    time.sleep(0.05)
                else:
                    raise AssertionError(f"{name} startup timed out; see {log.name}")
                with httpx.Client(base_url=base, headers=headers, timeout=15) as client:
                    yield client
            finally:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

    def call(client, name, arguments):
        response = client.post(
            "/mcp",
            json={
                "jsonrpc": "2.0",
                "id": 10,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            },
        )
        result = _payload(response)["result"]
        assert not result.get("isError"), result
        return result["structuredContent"]

    with server("legacy", stateful=True) as client:
        initialized = client.post(
            "/mcp",
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "legacy-no-reinitialize", "version": "1"},
                },
            },
        )
        _payload(initialized)
        old_id = initialized.headers["mcp-session-id"]
        headers["mcp-session-id"] = old_id
        client.headers.update(headers)
        client.post("/mcp", json={"jsonrpc": "2.0", "method": "notifications/initialized"})
        logical_id = call(client, "session_manage", {"action": "start", "label": "restart test"})[
            "data"
        ]["session_id"]
        written = call(
            client,
            "file_write",
            {
                "path": "persist.txt",
                "content": "survives restart",
                "logical_session_id": logical_id,
            },
        )
        assert written["ok"]

    # A newly created stateful process reproduces the original failure.
    with server("stateful-restart", stateful=True) as client:
        response = client.post("/mcp", json={"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        assert response.status_code == 404
        assert "Session not found" in response.text

    for generation in ("upgrade", "stateless-restart"):
        with server(generation) as client:
            listed = client.post("/mcp", json={"jsonrpc": "2.0", "id": 3, "method": "tools/list"})
            assert "tools" in _payload(listed)["result"]
            assert "mcp-session-id" not in listed.headers
            # Stale transport IDs confer no authorization.
            anonymous = httpx.post(
                base + "/mcp",
                headers={key: value for key, value in headers.items() if key != "authorization"},
                json={"jsonrpc": "2.0", "id": 4, "method": "tools/list"},
            )
            assert anonymous.status_code == 401
            session = call(client, "session_manage", {"action": "get", "session_id": logical_id})
            assert session["data"]["session_id"] == logical_id
            read = call(
                client, "file_read", {"path": "persist.txt", "logical_session_id": logical_id}
            )
            assert read["ok"] and "survives restart" in str(read["data"])
            shell = call(
                client,
                "run_shell",
                {"command": "printf restart-ok", "logical_session_id": logical_id},
            )
            assert shell["ok"] and shell["data"]["stdout"] == "restart-ok"
    assert (tmp_path / "persist.txt").read_text() == "survives restart"
