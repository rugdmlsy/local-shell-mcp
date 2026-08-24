#!/usr/bin/env bash
set -euo pipefail

test "$#" -ge 1 && test "$#" -le 3 || {
  echo "usage: $0 <release-name> [deploy-root] [service-name]" >&2
  exit 64
}

readonly release_name="$1"
readonly deploy_root="${2:-/home/morrow/lsm-controller}"
readonly service_name="${3:-local-shell-mcp.service}"
readonly release_dir="${deploy_root}/releases/${release_name}"

[[ "${release_name}" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || {
  echo "invalid release name" >&2
  exit 64
}
test -f "${release_dir}/READY"
test -x "${release_dir}/.venv/bin/local-shell-mcp"

if test -L "${deploy_root}/current"; then
  current_target="$(readlink "${deploy_root}/current")"
  previous_link="${deploy_root}/.previous.${$}"
  ln -s "${current_target}" "${previous_link}"
  mv -Tf "${previous_link}" "${deploy_root}/previous"
fi

current_link="${deploy_root}/.current.${$}"
ln -s "releases/${release_name}" "${current_link}"
mv -Tf "${current_link}" "${deploy_root}/current"
systemctl restart "${service_name}"
