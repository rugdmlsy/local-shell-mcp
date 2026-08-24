from __future__ import annotations

import asyncio
import json
import os
import time
from pathlib import Path

import jwt
import pytest
from starlette.exceptions import HTTPException
from starlette.requests import Request

import local_shell_mcp.human_ui as human_ui
from local_shell_mcp.auth import Principal, _is_public_path
from local_shell_mcp.container_client import (
    ContainerClientManager,
    container_client_routes,
    reset_container_client_manager,
)
from local_shell_mcp.oauth import ALL_OAUTH_SCOPES, issue_access_token
from local_shell_mcp.settings import get_settings
from local_shell_mcp.tools import build_mcp


def _configure(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKSPACE_ROOT", str(tmp_path / "workspace"))
    monkeypatch.setenv("LOCAL_SHELL_MCP_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("LOCAL_SHELL_MCP_AUDIT_LOG_PATH", str(tmp_path / "audit.jsonl"))
    monkeypatch.setenv("LOCAL_SHELL_MCP_AUTH_MODE", "oauth")
    monkeypatch.setenv("LOCAL_SHELL_MCP_AUTH_BYPASS_LOCALHOST", "false")
    monkeypatch.setenv("LOCAL_SHELL_MCP_PUBLIC_BASE_URL", "http://testserver")
    monkeypatch.setenv(
        "LOCAL_SHELL_MCP_OAUTH_JWT_SECRET",
        "container-client-test-secret-that-is-at-least-32-bytes",
    )
    monkeypatch.setenv("LOCAL_SHELL_MCP_REMOTE_ENABLED", "false")
    (tmp_path / "workspace").mkdir()
    get_settings.cache_clear()
    reset_container_client_manager()


@pytest.mark.asyncio
async def test_invite_is_single_use_and_registry_never_stores_bearer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _configure(tmp_path, monkeypatch)
    manager = ContainerClientManager()
    invitation = await manager.create_invite(base_url="http://testserver")

    async def consume():  # noqa: ANN202
        return await manager.register(
            invitation["invite"],
            base_url="http://testserver",
            client_version="1.0.0",
        )

    results = await asyncio.gather(consume(), consume(), return_exceptions=True)
    successful = [item for item in results if isinstance(item, tuple)]
    assert len(successful) == 1
    session, token = successful[0]
    claims = jwt.decode(token, options={"verify_signature": False})
    assert claims["sub"] == f"container-client:{session.session_id}"
    assert claims["scope"] == " ".join(ALL_OAUTH_SCOPES)
    assert claims["token_kind"] == "container-client"
    assert 86_395 <= claims["exp"] - claims["iat"] <= 86_405

    registry_text = manager.registry_path.read_text(encoding="utf-8")
    assert token not in registry_text
    assert json.loads(registry_text)["sessions"][0]["jti"] == session.jti
    if os.name != "nt":
        assert manager.registry_path.stat().st_mode & 0o777 == 0o600


@pytest.mark.asyncio
async def test_revoked_session_is_rejected_after_manager_restart(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _configure(tmp_path, monkeypatch)
    manager = ContainerClientManager()
    invitation = await manager.create_invite(base_url="http://testserver")
    session, token = await manager.register(
        invitation["invite"], base_url="http://testserver", client_version="1.0.0"
    )
    claims = jwt.decode(token, options={"verify_signature": False})
    principal = Principal(email=None, subject=claims["sub"], claims=claims)
    manager.begin_call(principal)
    manager.end_call(session.session_id)
    manager.revoke(session.session_id)

    recovered = ContainerClientManager(manager.state_dir)
    with pytest.raises(HTTPException, match="revoked"):
        recovered.begin_call(principal)


def test_client_bootstrap_routes_are_public_but_call_route_is_protected(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _configure(tmp_path, monkeypatch)
    mcp = build_mcp()
    paths = {route.path for route in container_client_routes(mcp)}
    assert paths == {
        "/client/install.sh",
        "/client/v1/manifest.json",
        "/client/v1/lsm",
        "/client/v1/register",
        "/client/v1/call",
    }
    assert _is_public_path("/client/install.sh")
    assert _is_public_path("/client/v1/register")
    assert not _is_public_path("/client/v1/call")


def test_standard_oauth_clients_share_the_single_user_subject(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _configure(tmp_path, monkeypatch)
    tokens = [
        issue_access_token(
            client_id=client_id,
            scope=" ".join(ALL_OAUTH_SCOPES),
            resource="http://testserver",
            issuer="http://testserver",
        )
        for client_id in ("chatgpt", "morrow-chat-bridge")
    ]

    claims = [jwt.decode(token, options={"verify_signature": False}) for token in tokens]
    assert {item["sub"] for item in claims} == {"local-user"}
    assert {item["client_id"] for item in claims} == {"chatgpt", "morrow-chat-bridge"}


def test_expired_invite_is_rejected(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _configure(tmp_path, monkeypatch)
    manager = ContainerClientManager()
    invitation = asyncio.run(manager.create_invite(base_url="http://testserver"))
    manager.invites[invitation["invite"]].expires_at = int(time.time()) - 1
    with pytest.raises(ValueError, match="expired"):
        asyncio.run(
            manager.register(
                invitation["invite"],
                base_url="http://testserver",
                client_version="1.0.0",
            )
        )


def _ui_request(method: str, *, path_params: dict[str, str] | None = None) -> Request:
    async def receive():  # noqa: ANN202
        return {"type": "http.request", "body": b"{}", "more_body": False}

    return Request(
        {
            "type": "http",
            "http_version": "1.1",
            "method": method,
            "scheme": "http",
            "path": "/api/ui/container-clients",
            "raw_path": b"/api/ui/container-clients",
            "query_string": b"",
            "headers": [],
            "client": ("127.0.0.1", 1),
            "server": ("testserver", 80),
            "path_params": path_params or {},
        },
        receive,
    )


@pytest.mark.asyncio
async def test_authenticated_ui_can_create_list_and_revoke_container_clients(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _configure(tmp_path, monkeypatch)
    manager = ContainerClientManager()
    monkeypatch.setattr(human_ui, "container_client_manager", lambda: manager)
    monkeypatch.setattr(human_ui, "_require_ui_scopes", lambda *args, **kwargs: None)

    invitation_response = await human_ui.api_container_clients(_ui_request("POST"))
    invitation = json.loads(invitation_response.body)["data"]
    session, _ = await manager.register(
        invitation["invite"],
        base_url="http://testserver",
        client_version="1.0.0",
    )
    listed_response = await human_ui.api_container_clients(_ui_request("GET"))
    listed = json.loads(listed_response.body)["data"]["sessions"]
    assert listed[0]["client_id"] == session.session_id
    assert listed[0]["active"] is True

    revoked_response = await human_ui.api_container_client_revoke(
        _ui_request("POST", path_params={"client_id": session.session_id})
    )
    revoked = json.loads(revoked_response.body)["data"]
    assert revoked["active"] is False
