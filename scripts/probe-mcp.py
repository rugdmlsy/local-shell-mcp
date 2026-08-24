#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import os
import secrets
from urllib.parse import parse_qs, urlparse

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


def _pkce_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


async def oauth_token(base_url: str, pin: str) -> str:
    redirect_uri = "https://example.com/local-shell-mcp-probe"
    verifier = secrets.token_urlsafe(48)
    async with httpx.AsyncClient(follow_redirects=False, timeout=20) as client:
        registered = await client.post(
            f"{base_url}/oauth/register",
            json={"redirect_uris": [redirect_uri], "client_name": "local-shell-mcp-probe"},
        )
        registered.raise_for_status()
        client_id = registered.json()["client_id"]

        authorized = await client.post(
            f"{base_url}/oauth/authorize",
            data={
                "response_type": "code",
                "client_id": client_id,
                "redirect_uri": redirect_uri,
                "scope": "shell:read shell:write shell:execute browser:use remote:use",
                "code_challenge": _pkce_challenge(verifier),
                "code_challenge_method": "S256",
                "pin": pin,
            },
        )
        if authorized.status_code not in {302, 303, 307, 308}:
            authorized.raise_for_status()
        code = parse_qs(urlparse(authorized.headers["location"]).query)["code"][0]

        token = await client.post(
            f"{base_url}/oauth/token",
            data={
                "grant_type": "authorization_code",
                "code": code,
                "client_id": client_id,
                "redirect_uri": redirect_uri,
                "code_verifier": verifier,
            },
        )
        token.raise_for_status()
        return token.json()["access_token"]


async def list_tools(mcp_url: str, token: str | None = None) -> list[str]:
    headers = {"Authorization": f"Bearer {token}"} if token else None
    async with streamablehttp_client(
        mcp_url,
        headers=headers,
        timeout=20,
        sse_read_timeout=20,
    ) as (read, write, _), ClientSession(read, write) as session:
        await session.initialize()
        tools = await session.list_tools()
        return [tool.name for tool in tools.tools]


async def call_environment_get(mcp_url: str, token: str | None = None) -> bool:
    headers = {"Authorization": f"Bearer {token}"} if token else None
    async with streamablehttp_client(
        mcp_url,
        headers=headers,
        timeout=20,
        sse_read_timeout=20,
    ) as (read, write, _), ClientSession(read, write) as session:
        await session.initialize()
        result = await session.call_tool("environment_get", {})
        if result.isError:
            return False
        structured = result.structuredContent
        return not (isinstance(structured, dict) and structured.get("ok") is False)


async def main() -> None:
    parser = argparse.ArgumentParser(description="Probe a local-shell-mcp remote endpoint.")
    parser.add_argument("base_url", help="Public base URL, for example https://mcp.example.com")
    pin_source = parser.add_mutually_exclusive_group()
    pin_source.add_argument("--pin", help="OAuth admin PIN. If set, also tests an authenticated tool call.")
    pin_source.add_argument(
        "--pin-env",
        metavar="NAME",
        help="Read the OAuth admin PIN from this environment variable instead of the command line.",
    )
    parser.add_argument(
        "--call-environment",
        action="store_true",
        help="Call environment_get after discovery; useful for localhost auth-bypass deployment checks.",
    )
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    mcp_url = f"{base_url}/mcp"
    pin = args.pin
    if args.pin_env:
        pin = os.environ.get(args.pin_env)
        if not pin:
            parser.error(f"environment variable {args.pin_env} is empty or missing")

    async with httpx.AsyncClient(timeout=20) as client:
        for path in ("/healthz", "/.well-known/oauth-protected-resource", "/.well-known/oauth-authorization-server"):
            response = await client.get(f"{base_url}{path}")
            print(f"{path}: {response.status_code}")
            response.raise_for_status()

    token = await oauth_token(base_url, pin) if pin else None
    tools = await list_tools(mcp_url, token)
    authentication = "authenticated" if token else "unauthenticated"
    print(f"{authentication} initialize/list_tools: ok ({len(tools)} tools)")
    print("first tools:", ", ".join(tools[:8]))

    if pin or args.call_environment:
        if "environment_get" not in tools:
            raise RuntimeError("environment_get is missing from the advertised MCP tool surface")
        ok = await call_environment_get(mcp_url, token)
        print(f"{authentication} environment_get call: {'ok' if ok else 'failed'}")
        if not ok:
            raise RuntimeError(f"{authentication} environment_get call failed")


if __name__ == "__main__":
    asyncio.run(main())
