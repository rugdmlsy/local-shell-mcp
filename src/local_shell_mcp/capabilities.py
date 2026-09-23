"""Durable, revocable capabilities pinned to one Logical Session."""

from __future__ import annotations

import hashlib
import json
import secrets
from typing import Any

from .state_store import get_state_store


def _key(capability_id: str) -> str:
    if len(capability_id) != 64 or any(ch not in "0123456789abcdef" for ch in capability_id):
        raise ValueError("invalid capability id")
    return f"session-capabilities/{capability_id}.json"


def issue_capability(session_id: str, subject: str) -> dict[str, str]:
    token = secrets.token_urlsafe(48)
    capability_id = hashlib.sha256(token.encode("utf-8")).hexdigest()
    record = {"session_id": session_id, "subject": subject}
    get_state_store().write_bytes(
        _key(capability_id), json.dumps(record, separators=(",", ":")).encode("utf-8")
    )
    return {"capability": token, "capability_id": capability_id, **record}


def resolve_capability(token: str | None) -> dict[str, Any] | None:
    if not token:
        return None
    capability_id = hashlib.sha256(token.encode("utf-8")).hexdigest()
    raw = get_state_store().read_bytes(_key(capability_id))
    if raw is None:
        return None
    record = json.loads(raw)
    return {**record, "capability_id": capability_id} if isinstance(record, dict) else None


def revoke_capability(capability_id: str) -> None:
    get_state_store().delete(_key(capability_id))


def revoke_session_capabilities(session_id: str) -> int:
    store = get_state_store()
    revoked = 0
    for key in store.list_keys("session-capabilities/"):
        raw = store.read_bytes(key)
        if raw is None:
            continue
        try:
            record = json.loads(raw)
        except (ValueError, TypeError):
            continue
        if isinstance(record, dict) and record.get("session_id") == session_id:
            store.delete(key)
            revoked += 1
    return revoked
