from __future__ import annotations

import httpx
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

_MORROWS_UPSTREAM = "http://127.0.0.1:8787/mcp"
_LSM_OAUTH_VERIFIED_HEADER = "X-Morrows-LSM-OAuth-Verified"

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


def _upstream_headers(request: Request) -> dict[str, str]:
    headers: dict[str, str] = {}
    for name, value in request.headers.items():
        lower = name.lower()
        if lower in _REQUEST_STRIP or lower.startswith("x-morrows-"):
            continue
        headers[name] = value
    # AuthMiddleware has already validated the public LSM OAuth bearer. Never
    # forward that bearer to Morrows; only assert the trusted loopback handoff.
    headers[_LSM_OAUTH_VERIFIED_HEADER] = "1"
    return headers


async def morrows_mcp_proxy(request: Request) -> Response:
    body = await request.body()
    headers = _upstream_headers(request)
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
