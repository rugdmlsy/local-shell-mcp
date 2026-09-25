#!/usr/bin/env bash
set -euo pipefail

test "$#" -eq 1 || {
  echo "usage: $0 <service-name>" >&2
  exit 64
}
service_name="$1"

systemctl is-active --quiet "$service_name"
systemctl is-active --quiet caddy.service
systemctl is-active --quiet local-shell-mcp-cloudflared.service

for attempt in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8766/healthz >/dev/null; then
    break
  fi
  test "$attempt" -lt 30
  sleep 1
done

sudo -n systemctl reload caddy.service

for attempt in $(seq 1 15); do
  if curl -fsS --max-time 2     -H 'Host: mcp.xycdev.com'     http://127.0.0.1:8765/healthz >/dev/null; then
    break
  fi
  test "$attempt" -lt 15
  sleep 1
done

echo "production edge active: Caddy :8765 -> Local Shell MCP :8766"
