#!/usr/bin/env bash
set -euo pipefail

readonly deploy_root="${1:-/home/morrow/lsm-controller}"
readonly service_name="${2:-local-shell-mcp.service}"

test -L "${deploy_root}/previous" || {
  echo "previous release link is missing" >&2
  exit 1
}
readonly previous_target="$(readlink "${deploy_root}/previous")"
readonly previous_dir="${deploy_root}/${previous_target}"
test -f "${previous_dir}/READY"
readonly previous_release="$(basename "$(readlink -f "${deploy_root}/previous")")"
readonly previous_sha="$(cat "${previous_dir}/READY")"

current_link="${deploy_root}/.current.${$}"
ln -s "${previous_target}" "${current_link}"
mv -Tf "${current_link}" "${deploy_root}/current"

umask 022
guard_tmp="$(mktemp "${deploy_root}/.AUTHORIZED_RELEASE.XXXXXX")"
printf '%s\t%s\n' "${previous_release}" "${previous_sha}" > "${guard_tmp}"
chmod 0444 "${guard_tmp}"
mv -f "${guard_tmp}" "${deploy_root}/AUTHORIZED_RELEASE"

sudo -n systemctl --no-block restart "${service_name}"
