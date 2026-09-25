#!/usr/bin/env bash
set -euo pipefail

test "$#" -eq 3 || {
  echo "usage: $0 <staged-launcher> <staged-unit> <staged-router>" >&2
  exit 64
}

launcher="$1"
unit="$2"
router="$3"
config_root=/home/morrow/.config/local-shell-mcp
caddyfile=/etc/caddy/Caddyfile
router_target=/etc/caddy/morrows-router.caddy

test "$(id -un)" = morrow
test -f "$launcher"
test -f "$unit"
test -f "$router"
command -v caddy >/dev/null
sudo -n true
systemctl is-active --quiet caddy.service

install -m 0755 "$launcher" "$config_root/run-host-vps.sh"
sudo -n install -m 0644 "$unit" /etc/systemd/system/local-shell-mcp.service
sudo -n install -m 0644 "$router" "$router_target"

if ! sudo -n grep -Fxq 'import /etc/caddy/morrows-router.caddy' "$caddyfile"; then
  printf '\n# Local Shell MCP / Morrows loopback edge\nimport /etc/caddy/morrows-router.caddy\n' |
    sudo -n tee -a "$caddyfile" >/dev/null
fi

sudo -n caddy fmt --overwrite "$router_target"
sudo -n caddy validate --config "$caddyfile"
sudo -n systemctl daemon-reload

rm -f "$launcher" "$unit" "$router"
echo "production topology staged"
