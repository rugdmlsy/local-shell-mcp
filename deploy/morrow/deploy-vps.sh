#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: deploy/morrow/deploy-vps.sh [--dry-run]

Build and atomically deploy the current pushed Morrow release to the production VPS.
The release tag is derived from the 4.2.0+morrow.N version in pyproject.toml.
EOF
}

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repository_root="$(cd "${script_dir}/../.." && pwd)"
readonly ssh_host="${LSM_DEPLOY_SSH_HOST:-ovh-vps}"
readonly deploy_root="${LSM_DEPLOY_ROOT:-/home/morrow/lsm-controller}"
readonly service_name="${LSM_DEPLOY_SERVICE:-local-shell-mcp.service}"
readonly public_base_url="${LSM_DEPLOY_PUBLIC_BASE_URL:-https://mcp.xycdev.com}"
readonly expected_hostname="${LSM_DEPLOY_EXPECTED_HOSTNAME:-vps-96468177}"
readonly repository_url="${LSM_DEPLOY_REPOSITORY_URL:-https://github.com/rugdmlsy/local-shell-mcp.git}"
readonly uv_bin="${LSM_DEPLOY_UV_BIN:-${deploy_root}/tools/uv-0.11.25/bin/uv}"
readonly service_env="${LSM_DEPLOY_SERVICE_ENV:-/home/morrow/.config/local-shell-mcp/service.env}"

dry_run=false
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
test "$#" -le 1 || {
  usage >&2
  exit 64
}

[[ "${ssh_host}" =~ ^[0-9A-Za-z._@-]+$ ]] || {
  echo "invalid SSH host: ${ssh_host}" >&2
  exit 64
}
[[ "${deploy_root}" =~ ^/[0-9A-Za-z._/-]+$ ]] || {
  echo "invalid deploy root: ${deploy_root}" >&2
  exit 64
}
[[ "${service_name}" =~ ^[0-9A-Za-z_.@-]+$ ]] || {
  echo "invalid service name: ${service_name}" >&2
  exit 64
}
[[ "${expected_hostname}" =~ ^[0-9A-Za-z._-]+$ ]] || {
  echo "invalid expected hostname: ${expected_hostname}" >&2
  exit 64
}
[[ "${public_base_url}" =~ ^https://[0-9A-Za-z._:/-]+$ ]] || {
  echo "invalid public base URL: ${public_base_url}" >&2
  exit 64
}
[[ "${repository_url}" =~ ^https://[0-9A-Za-z._/-]+$ ]] || {
  echo "invalid repository URL: ${repository_url}" >&2
  exit 64
}
[[ "${uv_bin}" =~ ^/[0-9A-Za-z._/-]+$ ]] || {
  echo "invalid uv path: ${uv_bin}" >&2
  exit 64
}
[[ "${service_env}" =~ ^/[0-9A-Za-z._/-]+$ ]] || {
  echo "invalid service environment path: ${service_env}" >&2
  exit 64
}

readonly ssh_control_dir="$(mktemp -d "${TMPDIR:-/tmp}/lsm-deploy.XXXXXX")"
readonly ssh_control_path="${ssh_control_dir}/control"
readonly -a ssh_options=(
  -o ControlMaster=auto
  -o ControlPersist=180
  -o ControlPath="${ssh_control_path}"
  -o ConnectTimeout=10
  -o ConnectionAttempts=3
)

remote() {
  ssh "${ssh_options[@]}" "${ssh_host}" "$@"
}

cleanup_ssh() {
  ssh "${ssh_options[@]}" -O exit "${ssh_host}" >/dev/null 2>&1 || true
  rmdir "${ssh_control_dir}" 2>/dev/null || true
}
trap cleanup_ssh EXIT

cd "${repository_root}"
test -z "$(git status --porcelain)" || {
  echo "working tree must be clean before deployment" >&2
  exit 1
}

readonly branch_name="$(git branch --show-current)"
test -n "${branch_name}" || {
  echo "deployment requires a branch checkout" >&2
  exit 1
}
[[ "${branch_name}" =~ ^[0-9A-Za-z._/-]+$ ]] || {
  echo "invalid branch name: ${branch_name}" >&2
  exit 1
}

git fetch --quiet origin "refs/heads/${branch_name}:refs/remotes/origin/${branch_name}"
readonly commit_sha="$(git rev-parse HEAD)"
readonly remote_branch_sha="$(git rev-parse "refs/remotes/origin/${branch_name}")"
test "${commit_sha}" = "${remote_branch_sha}" || {
  echo "HEAD must exactly match origin/${branch_name} before deployment" >&2
  exit 1
}

readonly version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' pyproject.toml | head -n 1)"
if [[ "${version}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+morrow\.([0-9]+)$ ]]; then
  readonly release_tag="morrow-v${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
else
  echo "unsupported Morrow version: ${version}" >&2
  exit 1
fi
readonly release_name="${release_tag}-${commit_sha:0:12}"
readonly local_icon="docs/assets/logo.png"
readonly icon_bytes="$(wc -c < "${local_icon}" | tr -d ' ')"
readonly icon_sha256="$(shasum -a 256 "${local_icon}" | awk '{print $1}')"
test "${icon_bytes}" -lt 10240 || {
  echo "official icon must remain below 10 KiB" >&2
  exit 1
}

if git rev-parse --verify --quiet "refs/tags/${release_tag}" >/dev/null; then
  readonly local_tag_sha="$(git rev-list -n 1 "${release_tag}")"
  test "${local_tag_sha}" = "${commit_sha}" || {
    echo "tag ${release_tag} already points to ${local_tag_sha}; increment the Morrow version" >&2
    exit 1
  }
else
  if ${dry_run}; then
    echo "DRY RUN: would create annotated tag ${release_tag} at ${commit_sha}"
  else
    git tag -a "${release_tag}" -m "Deploy ${version}" "${commit_sha}"
  fi
fi

remote_tag_lines="$(git ls-remote origin "refs/tags/${release_tag}" "refs/tags/${release_tag}^{}")"
remote_tag_sha="$(printf '%s\n' "${remote_tag_lines}" | awk '$2 ~ /\^\{\}$/ {print $1; exit}')"
if test -z "${remote_tag_sha}"; then
  remote_tag_sha="$(printf '%s\n' "${remote_tag_lines}" | awk 'NF == 2 {print $1; exit}')"
fi
if test -n "${remote_tag_sha}"; then
  test "${remote_tag_sha}" = "${commit_sha}" || {
    echo "remote tag ${release_tag} points to ${remote_tag_sha}, not ${commit_sha}" >&2
    exit 1
  }
elif ${dry_run}; then
  echo "DRY RUN: would push tag ${release_tag}"
else
  git push origin "refs/tags/${release_tag}"
fi

remote bash -s -- \
  "${expected_hostname}" "${deploy_root}" "${service_name}" "${uv_bin}" \
  "${service_env}" <<'REMOTE'
set -euo pipefail
expected_hostname="$1"
deploy_root="$2"
service_name="$3"
uv_bin="$4"
service_env="$5"
test "$(hostname)" = "${expected_hostname}"
test "$(id -un)" = morrow
command -v git >/dev/null || { echo "git is missing on the VPS" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is missing on the VPS" >&2; exit 1; }
test -x "${uv_bin}" || { echo "uv is missing at ${uv_bin}" >&2; exit 1; }
test -r "${service_env}" || { echo "service environment is unreadable" >&2; exit 1; }
grep -q '^LOCAL_SHELL_MCP_OAUTH_ADMIN_PIN=' "${service_env}" || {
  echo "OAuth admin PIN is missing from the service environment" >&2
  exit 1
}
sudo -n true
systemctl is-active --quiet "${service_name}"
systemctl is-active --quiet local-shell-mcp-cloudflared.service
test -d "${deploy_root}/releases"
test "$(df -Pk "${deploy_root}" | awk 'NR == 2 {print $4}')" -gt 1048576
echo "remote host: $(hostname)"
echo "uv: $("${uv_bin}" --version)"
echo "current release: $(readlink -f "${deploy_root}/current" 2>/dev/null || echo legacy)"
REMOTE

echo "release: ${release_name}"
echo "version: ${version}"
echo "commit: ${commit_sha}"
echo "icon: ${icon_bytes} bytes ${icon_sha256}"
if ${dry_run}; then
  echo "DRY RUN: preflight passed; no tag, release, symlink, or service was changed"
  exit 0
fi

remote bash -s -- \
  "${release_tag}" "${commit_sha}" "${repository_url}" "${deploy_root}" "${uv_bin}" \
  < "${script_dir}/build-release.sh"

remote bash -s -- \
  "${deploy_root}" "${release_name}" "${commit_sha}" "${version}" \
  "${icon_bytes}" "${icon_sha256}" <<'REMOTE'
set -euo pipefail
deploy_root="$1"
release_name="$2"
commit_sha="$3"
version="$4"
icon_bytes="$5"
icon_sha256="$6"
release_dir="${deploy_root}/releases/${release_name}"
test -f "${release_dir}/READY"
grep -Fxq "${commit_sha}" "${release_dir}/READY"
test "$("${release_dir}/.venv/bin/local-shell-mcp" --version)" = "${version}"
test "$(wc -c < "${release_dir}/docs/assets/logo.png" | tr -d ' ')" = "${icon_bytes}"
test "$(sha256sum "${release_dir}/docs/assets/logo.png" | awk '{print $1}')" = "${icon_sha256}"
"${release_dir}/.venv/bin/python" - "${release_dir}/release-manifest.json" "${commit_sha}" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if manifest.get("fork_commit") != sys.argv[2]:
    raise SystemExit("release manifest commit mismatch")
PY
echo "candidate verified: ${release_dir}"
REMOTE

current_release="$(remote bash -s -- "${deploy_root}" <<'REMOTE'
set -euo pipefail
deploy_root="$1"
if test -L "${deploy_root}/current"; then
  basename "$(readlink -f "${deploy_root}/current")"
fi
REMOTE
)"

service_pid() {
  remote systemctl show "${service_name}" -p MainPID --value
}

wait_for_release_process() {
  local target_release_name="$1"
  local old_pid="$2"
  local process_state

  # A systemd restart can spend roughly TimeoutStopSec draining active MCP
  # sessions. Poll fresh SSH channels until both the PID changes and the
  # interpreter path proves that systemd launched the requested release.
  for attempt in $(seq 1 40); do
    if process_state="$(remote bash -s -- \
      "${deploy_root}" "${target_release_name}" "${service_name}" "${old_pid}" <<'REMOTE'
set -u
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
REMOTE
    )"; then
      echo "service process: ${process_state} (${target_release_name})"
      return 0
    fi
    test "${attempt}" -lt 40 || break
    sleep 2
  done

  echo "service did not start from ${target_release_name}" >&2
  return 1
}

switched=false
rollback_on_failure() {
  status="$?"
  trap - EXIT
  if test "${status}" -ne 0 && ${switched}; then
    echo "post-switch verification failed; rolling back" >&2
    rollback_pid="$(service_pid 2>/dev/null || true)"
    if remote bash -s -- "${deploy_root}" "${service_name}" \
      < "${script_dir}/rollback-release.sh"; then
      rollback_release="$(remote bash -s -- "${deploy_root}" <<'REMOTE'
basename "$(readlink -f "$1/current")"
REMOTE
)"
      wait_for_release_process "${rollback_release}" "${rollback_pid}" || true
    fi
  fi
  cleanup_ssh
  exit "${status}"
}
trap rollback_on_failure EXIT

old_pid="$(service_pid)"
if test "${current_release}" = "${release_name}"; then
  echo "release is already current; restarting ${service_name} without changing previous"
  remote sudo -n systemctl --no-block restart "${service_name}"
else
  remote bash -s -- "${release_name}" "${deploy_root}" "${service_name}" \
    < "${script_dir}/switch-release.sh"
  switched=true
fi
wait_for_release_process "${release_name}" "${old_pid}"

remote bash -s -- \
  "${deploy_root}" "${release_name}" "${service_name}" "${version}" \
  "${service_env}" <<'REMOTE'
set -euo pipefail
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
REMOTE

# A passing loopback MCP call proves the new controller is healthy. Do not turn
# a later Cloudflare or client-network failure into an automatic code rollback.
switched=false
trap - EXIT
cleanup_ssh

curl -fsS --retry 5 --retry-delay 1 --max-time 10 "${public_base_url}/healthz"
echo
curl -fsS --retry 3 --max-time 10 \
  "${public_base_url}/.well-known/oauth-protected-resource" >/dev/null

echo "deployed ${release_name} to ${expected_hostname}"
echo "rollback: ssh ${ssh_host} 'bash ${deploy_root}/current/deploy/morrow/rollback-release.sh'"
