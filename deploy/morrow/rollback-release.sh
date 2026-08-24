#!/usr/bin/env bash
set -euo pipefail

readonly deploy_root="${1:-/home/morrow/lsm-controller}"
readonly service_name="${2:-local-shell-mcp.service}"

test -L "${deploy_root}/previous" || {
  echo "previous release link is missing" >&2
  exit 1
}
readonly previous_target="$(readlink "${deploy_root}/previous")"
test -f "${deploy_root}/${previous_target}/READY"

current_link="${deploy_root}/.current.${$}"
ln -s "${previous_target}" "${current_link}"
mv -Tf "${current_link}" "${deploy_root}/current"
sudo -n systemctl --no-block restart "${service_name}"
