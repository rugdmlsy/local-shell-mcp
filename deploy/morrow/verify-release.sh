#!/usr/bin/env bash
set -euo pipefail

test "$#" -eq 5 || {
  echo "usage: $0 <deploy-root> <release-name> <service-name> <version> <service-env>" >&2
  exit 64
}

deploy_root="$1"
release_name="$2"
service_name="$3"
version="$4"
service_env="$5"

for attempt in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8765/healthz >/dev/null; then
    break
  fi
  test "${attempt}" -lt 30
  sleep 1
done
systemctl is-active --quiet "${service_name}"
test "$(basename "$(readlink -f "${deploy_root}/current")")" = "${release_name}"
test "$("${deploy_root}/current/.venv/bin/local-shell-mcp" --version)" = "${version}"
set -a
. "${service_env}"
set +a
"${deploy_root}/current/.venv/bin/python" \
  "${deploy_root}/current/scripts/probe-mcp.py" \
  http://127.0.0.1:8765 \
  --pin-env LOCAL_SHELL_MCP_OAUTH_ADMIN_PIN
systemctl show "${service_name}" -p ActiveState -p SubState -p MainPID -p NRestarts --no-pager
