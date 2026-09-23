# Session control API

LSM exposes a trusted HTTP API at `/api/control` for orchestrators that create, observe, and end Logical Sessions. Agent execution continues through `/mcp`. Control observation does not create Agent Session activity; operational cleanup may still create audit entries.

For a local integration, bind LSM to loopback and configure:

```env
LOCAL_SHELL_MCP_HOST=127.0.0.1
LOCAL_SHELL_MCP_AUTH_MODE=none
LOCAL_SHELL_MCP_CONTROL_API_KEY=<random control credential>
LOCAL_SHELL_MCP_REQUIRE_SESSION_CAPABILITY=true
```

Start LSM in MCP service mode (`local-shell-mcp --mode mcp`). The compatibility `--mode http` service does not mount `/mcp` or `/api/control`.

Every control request sends `X-LSM-Control-Key`. The control key grants lifecycle authority and must stay outside Agent processes. A controller creates a Session with `POST /api/control/sessions` and a generic `subject` and `idempotency_key`. `(subject, idempotency_key)` maps to one durable Session. Repeating the request returns that Session even after it is completed or cancelled. A keyed Session is not automatically pruned; explicit terminal `delete` removes its record and releases the key.

The controller issues a capability with `POST /api/control/sessions/{session_id}/capabilities`. Issuing a new capability revokes older capabilities for that Session. An MCP request sends `X-LSM-Session-Capability`; when capability enforcement is enabled, a missing or revoked capability is rejected. The bound Agent must pass the pinned `logical_session_id` for ordinary tools. A different ID, or a Job/shell owned by a different Session, is rejected. The bound Agent may only use `session_manage(get/report)` and cannot manage LSM Goal Plans or global LSM services.

The capability limits the connection to one Session. It is available in the Agent process environment when supplied through Codex `env_http_headers`; it is not a secret from code that Agent can execute. Deployments that need that stronger boundary should inject the header through a trusted local proxy.

| Endpoint | Purpose |
|---|---|
| `GET /sessions/{id}` | Session state, including `in_flight_calls` and `machines_touched` |
| `GET /sessions/{id}/jobs` | Jobs persisted with that Session ID |
| `GET /sessions/{id}/shells` | Independent and Job-created persistent shells with that Session ID |
| `GET /sessions/{id}/audit` | Bounded live audit filtered by Logical Session ID |
| `GET /sessions/{id}/jobs/{job_id}/tail?machine=...` | Scoped Job output |
| `POST /capabilities/{capability_id}/revoke` | Stop future MCP requests using one capability |
| `POST /sessions/{id}/cleanup` | Stop scoped Jobs and shells, wait up to 30 seconds for ordinary calls, then finish or cancel the Session |
| `POST /sessions/{id}/lifecycle` | Trusted finish, cancel, or delete |

`machines_touched` stores normalized execution node identities only. It is updated before dispatch, including the default `local` node and the actual transfer controller/source/destination nodes. It is an index for resource enumeration and cleanup; audit keeps call history and timing. Cross-node enumeration only queries this set and returns `complete: false` with `unreachable_machines` if any node cannot be read.

Jobs and persistent shells each persist `logical_session_id`, their own resource ID, and machine identity. The Job's `shell_session_id` is a separate identifier. LSM hot Job and audit views have retention limits; old audit may remain in compressed archive. An orchestrator should persist semantic state, object IDs, and necessary summaries without assuming that every raw entry stays online forever.
