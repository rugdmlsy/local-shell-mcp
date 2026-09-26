#!/usr/bin/env bash
set -euo pipefail

rotate_control_key=false
if test "${1:-}" = "--rotate-control-key"; then
  rotate_control_key=true
  shift
fi

test "$#" -eq 1 || {
  echo "usage: $0 [--rotate-control-key] <service-env>" >&2
  exit 64
}

service_env="$1"
test -f "$service_env"
test -r "$service_env"
test -w "$service_env"

if ! ${rotate_control_key} && grep -Eq '^LOCAL_SHELL_MCP_CONTROL_API_KEY=.+$' "$service_env"; then
  chmod 600 "$service_env"
  echo "LSM control credential already configured"
  exit 0
fi

control_key="$(
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
test -n "$control_key"

tmp="$(mktemp "${service_env}.XXXXXX")"
cleanup() {
  rm -f "$tmp"
  unset control_key
}
trap cleanup EXIT

awk '!/^LOCAL_SHELL_MCP_CONTROL_API_KEY=/' "$service_env" > "$tmp"
printf 'LOCAL_SHELL_MCP_CONTROL_API_KEY=%s\n' "$control_key" >> "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$service_env"
trap - EXIT
unset control_key

if ${rotate_control_key}; then
  echo "LSM control credential rotated"
else
  echo "LSM control credential generated"
fi
