#!/usr/bin/env bash
set -euo pipefail

readonly deploy_root=/home/morrow/lsm-controller
readonly config_root=/home/morrow/.config/local-shell-mcp

set -a
# shellcheck disable=SC1091
source "${config_root}/service.env"
set +a

# Publish only the LSM control API credential to an adjacent-service handoff
# file. This avoids copying it into another service's environment and never
# writes the value to stdout/stderr.
readonly control_key_file="${config_root}/control-api-key"
if [[ -n "${LOCAL_SHELL_MCP_CONTROL_API_KEY:-}" ]]; then
  umask 077
  control_key_tmp="$(mktemp "${control_key_file}.XXXXXX")"
  printf '%s\n' "${LOCAL_SHELL_MCP_CONTROL_API_KEY}" > "${control_key_tmp}"
  chmod 600 "${control_key_tmp}"
  mv -f "${control_key_tmp}" "${control_key_file}"
fi

# These values are for adjacent services, not child processes or LSM itself.
unset CLOUDFLARE_TUNNEL_TOKEN LOCAL_SHELL_MCP_PERSISTENT_CREDENTIALS

# Environment variables override YAML in LSM. Pin the safety-critical production
# shape here as well so an older service.env cannot silently enable remote-only,
# stateless, or full-container modes. Official v4.3 Live Workspace remains enabled.
export LOCAL_SHELL_MCP_HOST=127.0.0.1
export LOCAL_SHELL_MCP_PORT=8766
export LOCAL_SHELL_MCP_DISABLE_LOCAL=false
export LOCAL_SHELL_MCP_REMOTE_ENABLED=true
export LOCAL_SHELL_MCP_STATELESS_CONTROLLER=false
export LOCAL_SHELL_MCP_STATE_BACKEND=file
export LOCAL_SHELL_MCP_ALLOW_FULL_CONTAINER=false
export LOCAL_SHELL_MCP_LOGICAL_SESSIONS_ENABLED=true
export LOCAL_SHELL_MCP_LIVE_WORKSPACE_ENABLED=true

readonly executable="${deploy_root}/current/.venv/bin/local-shell-mcp"
test -x "${executable}"
exec "${executable}" --config "${config_root}/host-v4.2.yaml" --mode mcp
