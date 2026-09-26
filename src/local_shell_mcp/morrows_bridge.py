from __future__ import annotations

import ipaddress
from urllib.parse import urlsplit
from uuid import UUID

import httpx
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from .settings import get_settings

_HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}
_REQUEST_STRIP = _HOP_BY_HOP | {
    "authorization",
    "content-length",
    "host",
    "x-agent-instance-id",
    "forwarded",
    "x-forwarded-for",
    "x-forwarded-host",
    "x-forwarded-proto",
    "x-real-ip",
}
_RESPONSE_STRIP = _HOP_BY_HOP | {
    "content-length",
    "content-encoding",
}


def _bridge_configuration(settings):  # noqa: ANN001
    token = str(settings.morrows_bridge_token or "").strip()
    agent_id = str(settings.morrows_bridge_agent_id or "").strip()
    upstream = str(settings.morrows_bridge_url or "").strip()
    if not token or not agent_id or not upstream:
        raise ValueError("Morrows OAuth bridge is not configured")
    if not token.startswith("mrw_agent_"):
        raise ValueError("Morrows bridge token must be an Agent credential")
    try:
        UUID(agent_id)
    except ValueError as exc:
        raise ValueError("Morrows bridge AgentInstance id is invalid") from exc

    parsed = urlsplit(upstream)
    if parsed.scheme != "http" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("Morrows bridge upstream must be a loopback HTTP URL")
    try:
        loopback = ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        loopback = parsed.hostname.lower() == "localhost"
    if not loopback or parsed.query or parsed.fragment:
        raise ValueError("Morrows bridge upstream must be a loopback HTTP URL without query/fragment")
    return upstream, token, agent_id


def _upstream_headers(request: Request, token: str, agent_id: str) -> dict[str, str]:
    headers: dict[str, str] = {}
    for name, value in request.headers.items():
        lower = name.lower()
        if lower in _REQUEST_STRIP or lower.startswith("x-morrows-bridge-"):
            continue
        headers[name] = value
    # The public LSM OAuth bearer never reaches Morrows. The edge translates it
    # to one explicitly provisioned Morrows bridge identity.
    headers["Authorization"] = f"Bearer {token}"
    headers["X-Agent-Instance-Id"] = agent_id
    return headers


async def morrows_mcp_proxy(request: Request) -> Response:
    settings = get_settings()
    try:
        upstream_url, token, agent_id = _bridge_configuration(settings)
    except ValueError as exc:
        return JSONResponse({"detail": str(exc)}, status_code=503)

    body = await request.body()
    headers = _upstream_headers(request, token, agent_id)
    try:
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(60.0),
            follow_redirects=False,
            trust_env=False,
        ) as client:
            upstream = await client.request(
                request.method,
                upstream_url,
                headers=headers,
                content=body,
            )
    except httpx.HTTPError:
        return JSONResponse({"detail": "Morrows MCP upstream unavailable"}, status_code=502)

    response = Response(content=upstream.content, status_code=upstream.status_code)
    for name, value in upstream.headers.multi_items():
        if name.lower() in _RESPONSE_STRIP:
            continue
        response.headers.append(name, value)
    return response


def morrows_bridge_routes() -> list[Route]:
    methods = ["GET", "POST", "DELETE", "OPTIONS"]
    return [
        Route("/morrows", morrows_mcp_proxy, methods=methods),
        Route("/morrows/", morrows_mcp_proxy, methods=methods),
    ]
