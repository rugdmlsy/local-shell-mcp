# Morrow production deployment

This directory defines the production shape for `mcp.xycdev.com`. GitHub is the
authoritative source, the Mac is the development checkout, and the VPS runs an
immutable tagged release. The production network shape is also owned here:

```text
Cloudflare Tunnel
       |
       v
Caddy 127.0.0.1:8765
  |-- /morrows* -> Morrows 127.0.0.1:8787
  '-- everything else -> Local Shell MCP 127.0.0.1:8766
```

Cloudflared continues to target `127.0.0.1:8765`. Caddy is the only process
that owns that edge port. Local Shell MCP must never bind 8765 in production.
The canonical router is `mcp-router.caddy`; the deployment command installs it,
the production launcher, and the systemd unit before every release restart.
The same deploy command owns the private LSM control-plane credential:
`ensure-production-secrets.sh` generates `LOCAL_SHELL_MCP_CONTROL_API_KEY`
inside the existing mode-0600 `service.env` when it is missing. The value is
never printed, and a dry-run never creates or changes secrets.

```text
/home/morrow/lsm-controller/
  releases/<tag>-<sha>/
  candidate -> releases/<tag>-<sha>
  current   -> releases/<tag>-<sha>
  previous  -> releases/<older-tag>-<sha>
```

The first v4.2 rollout deliberately uses a new
`/home/morrow/.config/local-shell-mcp/state-v4.2` directory. The existing v3
state and launcher remain untouched for the rollback drill.

## One-command deployment from the Mac

For routine releases, commit and push a clean `morrow/v4.3` checkout, increment
the `4.3.2+morrow.N` version, then run:

```bash
./deploy/morrow/deploy-vps.sh --dry-run
./deploy/morrow/deploy-vps.sh
```

The command derives `morrow-v4.3.2-N` from `pyproject.toml`, creates and pushes
that tag when needed, builds the immutable VPS release, verifies its manifest
and icon, stages the canonical launcher/systemd/Caddy topology, switches
`current`, activates the shared edge, and performs direct-controller,
edge-routed, and public health checks. Its localhost MCP probe talks directly
to LSM on port 8766 and performs a real `environment_get` call, proving that
local execution remains enabled. Post-switch verification also requires the
running LSM process to have loaded the private control-plane credential. The
probe reads the OAuth admin PIN from the private
service environment, exchanges it for an ephemeral token, and never places the
PIN or token in the command line or logs. A post-switch check that reaches the VPS and proves the release unhealthy
automatically invokes `rollback-release.sh`. A pure SSH transport failure is not
health evidence: post-switch checks keep the established ControlMaster as the
primary path (to avoid VPS SSH connection throttling), but every session has a
hard local deadline plus ServerAlive probes. A transport-only failure gets one
independent-connection fallback. If repeated rounds cannot establish either SSH
path, deployment exits as indeterminate and preserves `current` instead of
blindly rolling back through a control path that is itself unhealthy.
Re-running the same release restarts it without replacing the `previous` rollback
link. Do not hand-edit the production LSM port, Caddy import, launcher, or unit
as a normal deployment procedure. Change the files in this directory first and
deploy through `deploy-vps.sh`. In particular, never stop or rewire the LSM
control path from an agent that depends on that same path unless an independent
OOB recovery path is already proven.

Service restarts are queued with non-interactive `sudo`; the command waits
for a changed systemd PID whose interpreter belongs to the target release before
it accepts the deployment. Before cutover it still reuses one SSH ControlMaster
connection so VPS connection throttling cannot strand a verified candidate.

The defaults use the existing `ovh-vps` SSH alias and production paths. Override
them only when deliberately targeting a different environment with
`LSM_DEPLOY_SSH_HOST`, `LSM_DEPLOY_ROOT`, `LSM_DEPLOY_SERVICE`,
`LSM_DEPLOY_PUBLIC_BASE_URL`, `LSM_DEPLOY_EXPECTED_HOSTNAME`, or
`LSM_DEPLOY_UV_BIN`. `LSM_DEPLOY_SERVICE_ENV` can point to an equivalent private
service environment when testing a separate deployment. The post-switch SSH
wall-clock deadline defaults to 45 seconds per attempt and can be adjusted with
`LSM_DEPLOY_POST_SWITCH_SSH_DEADLINE_S` when diagnosing unusually slow links.

## Build a pinned release

Run `build-release.sh morrow-v4.3.2-1 <full-commit-sha>` as `morrow` on the VPS.
The script fetches that exact public tag, verifies the commit, runs
`uv lock --check` and `uv sync --frozen`, writes `release-manifest.json`, and
only then updates `candidate`. It does not touch `current` or restart production.

## Migrate state

Run the migration without `--apply` first:

```bash
candidate/.venv/bin/python scripts/migrate-morrow-state.py \
  /home/morrow/.config/local-shell-mcp/state \
  /home/morrow/.config/local-shell-mcp/state-v4.2 \
  --legacy-config /home/morrow/.config/local-shell-mcp/external-mcp.toml
```

After reviewing the JSON plan, repeat with `--apply`. OAuth/JWT material,
remote registrations, jobs/download metadata, and Container Client sessions
are copied. Old todos, task artifacts, audit evidence, and the unused Vault MCP
configuration are placed under `legacy-v3/`; they are never activated as v4.2
Session/Plan or Dynamic MCP state.

## Candidate and cutover

Copy `host.yaml.example` to the private `host-v4.2.yaml`, retaining the values
shown for local execution, remotes, Session/Plan, file state, and the official
v4.3 Live Workspace. Live Workspace owns the upstream Goal/Plan continuation
path again; do not delegate continuation to Morrow Chat. Secrets stay in the
existing mode-0600 `service.env`.

Start the candidate on a loopback-only alternate port with a copied config and
an isolated state directory. Do not point a production worker identity at both
controllers. Use a temporary worker identity for candidate remote tests.

For the first cutover, archive the current unit, launcher, private config, and
v3 state; install `run-host-vps.sh` atomically; point `current` at the accepted
release; and restart only `local-shell-mcp.service`. Subsequent releases can use
`switch-release.sh`. `rollback-release.sh` restores the prior immutable release;
the first v4.2 rollback instead restores the archived v3 launcher/config and
restarts the same unit.

Never delete the old staging tree during rollout. Move it to a read-only legacy
location only after 24 hours of observation, retain it for at least 30 days,
and obtain separate approval before deletion.
