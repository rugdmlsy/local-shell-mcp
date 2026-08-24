# Morrow production deployment

This directory defines the production shape for `mcp.xycdev.com`. GitHub is the
authoritative source, the Mac is the development checkout, and the VPS runs an
immutable tagged release:

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

For routine releases, commit and push a clean `morrow/v4.2` checkout, increment
the `4.2.0+morrow.N` version, then run:

```bash
./deploy/morrow/deploy-vps.sh --dry-run
./deploy/morrow/deploy-vps.sh
```

The command derives `morrow-v4.2.0-N` from `pyproject.toml`, creates and pushes
that tag when needed, builds the immutable VPS release, verifies its manifest
and icon, switches `current`, and performs local plus public health checks. Its
localhost MCP probe performs a real `environment_get` call, proving that local
execution remains enabled. A failed post-switch check automatically invokes
`rollback-release.sh`. Re-running the same release restarts it without replacing
the `previous` rollback link.

The defaults use the existing `ovh-vps` SSH alias and production paths. Override
them only when deliberately targeting a different environment with
`LSM_DEPLOY_SSH_HOST`, `LSM_DEPLOY_ROOT`, `LSM_DEPLOY_SERVICE`,
`LSM_DEPLOY_PUBLIC_BASE_URL`, `LSM_DEPLOY_EXPECTED_HOSTNAME`, or
`LSM_DEPLOY_UV_BIN`.

## Build a pinned release

Run `build-release.sh morrow-v4.2.0-4 <full-commit-sha>` as `morrow` on the VPS.
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
shown for local execution, remotes, Session/Plan, file state, and disabled Live
Workspace. Secrets stay in the existing mode-0600 `service.env`.

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
