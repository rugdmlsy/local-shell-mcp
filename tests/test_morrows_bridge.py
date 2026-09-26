from __future__ import annotations

import time
from types import SimpleNamespace

import httpx
import jwt
from starlette.applications import Starlette
from starlette.testclient import TestClient

from local_shell_mcp import morrows_bridge
from local_shell_mcp.auth import AuthMiddleware
from local_shell_mcp.settings import Settings, get_settings, safe_settings_dump


class _FakeAsyncClient:
    calls: list[dict] = []

    def __init__(self, *args, **kwargs):  # noqa: ANN002, ANN003
        self.args = args
        self.kwargs = kwargs

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):  # noqa: ANN001
        return False

    async def request(self, method, url, headers=None, content=None):  # noqa: ANN001
        self.calls.append(
            {
                "method": method,
                "url": url,
                "headers": dict(headers or {}),
                "content": content,
            }
        )
        return httpx.Response(
            200,
            headers={
                "Content-Type": "application/json",
                "Mcp-Session-Id": "morrows-session-1",
            },
            content=b'{"jsonrpc":"2.0","id":1,"result":{"ok":true}}',
            request=httpx.Request(method, url),
        )


def _settings(**updates):
    values = {
        "morrows_bridge_url": "http://127.0.0.1:8787/mcp",
        "morrows_bridge_token": "mrw_agent_internal-secret",
        "morrows_bridge_agent_id": "4cf5e5ca-dad0-4ce5-a8f0-86dff8c302c9",
    }
    values.update(updates)
    return SimpleNamespace(**values)


def test_morrows_proxy_translates_lsm_oauth_to_internal_agent_credential(monkeypatch) -> None:
    _FakeAsyncClient.calls = []
    monkeypatch.setattr(morrows_bridge, "get_settings", lambda: _settings())
    monkeypatch.setattr(morrows_bridge.httpx, "AsyncClient", _FakeAsyncClient)

    app = Starlette(routes=morrows_bridge.morrows_bridge_routes())
    with TestClient(app) as client:
        response = client.post(
            "/morrows",
            headers={
                "Authorization": "Bearer lsm-oauth-token",
                "X-Agent-Instance-Id": "00000000-0000-0000-0000-000000000000",
                "Mcp-Protocol-Version": "2025-06-18",
                "Accept": "application/json, text/event-stream",
            },
            content=b'{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
        )

    assert response.status_code == 200
    assert response.headers["mcp-session-id"] == "morrows-session-1"
    assert len(_FakeAsyncClient.calls) == 1
    call = _FakeAsyncClient.calls[0]
    assert call["url"] == "http://127.0.0.1:8787/mcp"
    assert call["headers"]["Authorization"] == "Bearer mrw_agent_internal-secret"
    assert (
        call["headers"]["X-Agent-Instance-Id"]
        == "4cf5e5ca-dad0-4ce5-a8f0-86dff8c302c9"
    )
    assert "lsm-oauth-token" not in repr(call)
    assert "00000000-0000-0000-0000-000000000000" not in repr(call)
    assert call["headers"]["mcp-protocol-version"] == "2025-06-18"


def test_morrows_proxy_fails_closed_without_bridge_configuration(monkeypatch) -> None:
    monkeypatch.setattr(
        morrows_bridge,
        "get_settings",
        lambda: _settings(morrows_bridge_token=None),
    )
    app = Starlette(routes=morrows_bridge.morrows_bridge_routes())
    with TestClient(app) as client:
        response = client.post("/morrows", content=b"{}")
    assert response.status_code == 503


def test_morrows_proxy_refuses_non_loopback_upstream(monkeypatch) -> None:
    monkeypatch.setattr(
        morrows_bridge,
        "get_settings",
        lambda: _settings(morrows_bridge_url="https://example.com/mcp"),
    )
    app = Starlette(routes=morrows_bridge.morrows_bridge_routes())
    with TestClient(app) as client:
        response = client.post("/morrows", content=b"{}")
    assert response.status_code == 503
    assert "loopback" in response.json()["detail"]


def test_morrows_bridge_token_is_redacted_from_environment_diagnostics() -> None:
    settings = Settings(
        morrows_bridge_token="mrw_agent_hidden",
        morrows_bridge_agent_id="4cf5e5ca-dad0-4ce5-a8f0-86dff8c302c9",
    )
    dumped = safe_settings_dump(settings)
    assert dumped["morrows_bridge_token"] == "<redacted>"
    assert dumped["morrows_bridge_agent_id"] == "4cf5e5ca-dad0-4ce5-a8f0-86dff8c302c9"


def test_morrows_route_is_protected_by_lsm_oauth_before_proxy(tmp_path, monkeypatch) -> None:
    secret = "oauth-test-secret-that-is-more-than-32-bytes"
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path))
    monkeypatch.setenv("LOCAL_SHELL_MCP_STATE_DIR", str(tmp_path / ".state"))
    monkeypatch.setenv("LOCAL_SHELL_MCP_AUTH_MODE", "oauth")
    monkeypatch.setenv("LOCAL_SHELL_MCP_OAUTH_JWT_SECRET", secret)
    monkeypatch.setenv("LOCAL_SHELL_MCP_PUBLIC_BASE_URL", "http://testserver")
    monkeypatch.setenv("LOCAL_SHELL_MCP_MORROWS_BRIDGE_TOKEN", "mrw_agent_internal-secret")
    monkeypatch.setenv(
        "LOCAL_SHELL_MCP_MORROWS_BRIDGE_AGENT_ID",
        "4cf5e5ca-dad0-4ce5-a8f0-86dff8c302c9",
    )
    get_settings.cache_clear()
    monkeypatch.setattr(morrows_bridge.httpx, "AsyncClient", _FakeAsyncClient)

    app = Starlette(routes=morrows_bridge.morrows_bridge_routes())
    app.add_middleware(AuthMiddleware)
    with TestClient(app, base_url="http://testserver") as client:
        unauthenticated = client.post("/morrows", content=b"{}")
        assert unauthenticated.status_code == 401
        challenge = unauthenticated.headers["www-authenticate"]
        assert 'resource_metadata="http://testserver/.well-known/oauth-protected-resource"' in challenge

        now = int(time.time())
        token = jwt.encode(
            {
                "iat": now,
                "aud": "http://testserver",
                "iss": "http://testserver",
                "sub": "chatgpt-test",
                "scope": "shell:read",
            },
            secret,
            algorithm="HS256",
        )
        authenticated = client.post(
            "/morrows",
            headers={"Authorization": f"Bearer {token}"},
            content=b'{"jsonrpc":"2.0","id":1,"method":"tools/list"}',
        )
        assert authenticated.status_code == 200

    get_settings.cache_clear()
