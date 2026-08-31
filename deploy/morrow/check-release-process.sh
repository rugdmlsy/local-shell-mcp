#!/usr/bin/env bash
set -u

test "$#" -eq 4 || exit 64
deploy_root="$1"
release_name="$2"
service_name="$3"
old_pid="$4"

pid="$(systemctl show "${service_name}" -p MainPID --value 2>/dev/null || true)"
test -n "${pid}" && test "${pid}" != 0 && test "${pid}" != "${old_pid}" || exit 1
systemctl is-active --quiet "${service_name}" || exit 1
test -r "/proc/${pid}/cmdline" || exit 1
tr '\0' '\n' < "/proc/${pid}/cmdline" \
  | grep -Fxq "${deploy_root}/releases/${release_name}/.venv/bin/python" \
  || exit 1
printf '%s' "${pid}"
