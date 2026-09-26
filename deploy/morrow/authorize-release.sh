#!/usr/bin/env bash
set -euo pipefail

test "$#" -eq 3 || {
  echo "usage: $0 <release-name> <expected-sha> <deploy-root>" >&2
  exit 64
}

readonly release_name="$1"
readonly expected_sha="$2"
readonly deploy_root="$3"
readonly release_dir="${deploy_root}/releases/${release_name}"
readonly guard_file="${deploy_root}/AUTHORIZED_RELEASE"

[[ "${release_name}" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || {
  echo "invalid release name" >&2
  exit 64
}
[[ "${expected_sha}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "expected SHA must be 40 lowercase hexadecimal characters" >&2
  exit 64
}
test -f "${release_dir}/READY"
grep -Fxq "${expected_sha}" "${release_dir}/READY"

umask 022
tmp="$(mktemp "${deploy_root}/.AUTHORIZED_RELEASE.XXXXXX")"
printf '%s\t%s\n' "${release_name}" "${expected_sha}" > "${tmp}"
chmod 0444 "${tmp}"
mv -f "${tmp}" "${guard_file}"
echo "authorized production release: ${release_name}"
