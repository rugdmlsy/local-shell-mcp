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
  if curl -fsS --max-time 2 http://127.0.0.1:8766/healthz >/dev/null; then
    break
  fi
  test "${attempt}" -lt 30
  sleep 1
done
systemctl is-active --quiet "${service_name}"
test "$(basename "$(readlink -f "${deploy_root}/current")")" = "${release_name}"
test "$("${deploy_root}/current/.venv/bin/local-shell-mcp" --version)" = "${version}"
IFS=$'\t' read -r authorized_release authorized_sha < "${deploy_root}/AUTHORIZED_RELEASE"
test "${authorized_release}" = "${release_name}"
test "${authorized_sha}" = "$(cat "${deploy_root}/current/READY")"
set -a
. "${service_env}"
set +a
"${deploy_root}/current/.venv/bin/python" \
  "${deploy_root}/current/scripts/probe-mcp.py" \
  http://127.0.0.1:8766 \
  --pin-env LOCAL_SHELL_MCP_OAUTH_ADMIN_PIN

curl -fsS --max-time 2 \
  -H 'Host: mcp.xycdev.com' \
  http://127.0.0.1:8765/healthz >/dev/null

# The public Morrows MCP must enter through LSM OAuth rather than reaching the
# Morrows Agent credential middleware directly.
morrows_headers="$(mktemp)"
trap 'rm -f "${morrows_headers}"' EXIT
morrows_status="$(curl -sS --max-time 2 -o /dev/null -D "${morrows_headers}" -w '%{http_code}' \
  -H 'Host: mcp.xycdev.com' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"release-probe","version":"1"}}}' \
  http://127.0.0.1:8765/morrows)"
test "${morrows_status}" = 401
grep -Eiq '^www-authenticate: Bearer .*resource_metadata=' "${morrows_headers}"
rm -f "${morrows_headers}"
trap - EXIT

pid="$(systemctl show "${service_name}" -p MainPID --value)"
test -n "${pid}"
test "${pid}" != 0
tr '\0' '\n' < "/proc/${pid}/environ" | grep -q '^LOCAL_SHELL_MCP_CONTROL_API_KEY=.'

systemctl show "${service_name}" -p ActiveState -p SubState -p MainPID -p NRestarts --no-pager
