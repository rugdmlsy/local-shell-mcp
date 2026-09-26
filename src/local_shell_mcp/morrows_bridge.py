from __future__ import annotations

import httpx
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from .auth import current_principal
from .oauth import oauth_client_name

_MORROWS_UPSTREAM = "http://127.0.0.1:8787/mcp"
_LSM_OAUTH_VERIFIED_HEADER = "X-Morrows-LSM-OAuth-Verified"
_LSM_OAUTH_CLIENT_ID_HEADER = "X-Morrows-LSM-OAuth-Client-Id"
_LSM_OAUTH_CLIENT_NAME_HEADER = "X-Morrows-LSM-OAuth-Client-Name"

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


def _safe_header_text(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip()
    if not value or any(ord(ch) < 32 or ord(ch) > 126 for ch in value):
        return None
    return value


def _validated_oauth_provenance() -> tuple[str, str | None] | None:
    principal = current_principal()
    if principal is None:
        return None
    raw_client_id = principal.claims.get("client_id")
    if not isinstance(raw_client_id, str):
        return None
    client_id = _safe_header_text(raw_client_id)
    if client_id is None:
        return None
    return client_id, _safe_header_text(oauth_client_name(client_id))


def _upstream_headers(
    request: Request,
    *,
    client_id: str,
    client_name: str | None,
) -> dict[str, str]:
    headers: dict[str, str] = {}
    for name, value in request.headers.items():
        lower = name.lower()
        if lower in _REQUEST_STRIP or lower.startswith("x-morrows-"):
            continue
        headers[name] = value
    # AuthMiddleware already validated the public LSM OAuth bearer. Never
    # forward that bearer or any caller-supplied Morrows identity. Only forward
    # provenance derived from the validated OAuth principal and registry.
    headers[_LSM_OAUTH_VERIFIED_HEADER] = "1"
    headers[_LSM_OAUTH_CLIENT_ID_HEADER] = client_id
    if client_name:
        headers[_LSM_OAUTH_CLIENT_NAME_HEADER] = client_name
    return headers


async def morrows_mcp_proxy(request: Request) -> Response:
    provenance = _validated_oauth_provenance()
    if provenance is None:
        return JSONResponse(
            {"detail": "Validated OAuth client identity required"},
            status_code=401,
        )
    client_id, client_name = provenance
    body = await request.body()
    headers = _upstream_headers(
        request,
        client_id=client_id,
        client_name=client_name,
    )
    try:
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(60.0),
            follow_redirects=False,
            trust_env=False,
        ) as client:
            upstream = await client.request(
                request.method,
                _MORROWS_UPSTREAM,
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
