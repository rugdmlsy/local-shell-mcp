#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <tag> <expected-full-sha> [repository-url] [deploy-root] [uv-bin]" >&2
  exit 64
}

test "$#" -ge 2 && test "$#" -le 5 || usage

readonly tag="$1"
readonly expected_sha="$2"
readonly repository_url="${3:-https://github.com/rugdmlsy/local-shell-mcp.git}"
readonly deploy_root="${4:-/home/morrow/lsm-controller}"
uv_bin="${5:-}"
if test -z "${uv_bin}"; then
  uv_bin="$(command -v uv 2>/dev/null || true)"
fi
if test -z "${uv_bin}" && test -x "${deploy_root}/tools/uv-0.11.25/bin/uv"; then
  uv_bin="${deploy_root}/tools/uv-0.11.25/bin/uv"
fi
readonly uv_bin
test -x "${uv_bin}" || {
  echo "uv executable is missing; pass its absolute path as the fifth argument" >&2
  exit 1
}

[[ "${tag}" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || {
  echo "invalid tag: ${tag}" >&2
  exit 64
}
[[ "${expected_sha}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "expected SHA must be 40 lowercase hexadecimal characters" >&2
  exit 64
}

readonly short_sha="${expected_sha:0:12}"
readonly releases_dir="${deploy_root}/releases"
readonly release_name="${tag}-${short_sha}"
readonly release_dir="${releases_dir}/${release_name}"
mkdir -p "${releases_dir}"

if test -e "${release_dir}"; then
  test -f "${release_dir}/READY" || {
    echo "incomplete release already exists: ${release_dir}" >&2
    exit 1
  }
  grep -Fxq "${expected_sha}" "${release_dir}/READY" || {
    echo "existing release SHA does not match" >&2
    exit 1
  }
  echo "${release_dir}"
  exit 0
fi

stage_dir="$(mktemp -d "${releases_dir}/.${release_name}.source.XXXXXX")"
cleanup() {
  if test -n "${stage_dir:-}" && test -d "${stage_dir}"; then
    rm -rf -- "${stage_dir}"
  fi
}
trap cleanup EXIT

git -C "${stage_dir}" init -q
git -C "${stage_dir}" remote add origin "${repository_url}"
git -C "${stage_dir}" fetch -q --depth 1 origin "refs/tags/${tag}"
git -C "${stage_dir}" checkout -q --detach FETCH_HEAD

readonly actual_sha="$(git -C "${stage_dir}" rev-parse HEAD)"
test "${actual_sha}" = "${expected_sha}" || {
  echo "tag resolved to ${actual_sha}, expected ${expected_sha}" >&2
  exit 1
}
test -f "${stage_dir}/uv.lock"

mv "${stage_dir}" "${release_dir}"
stage_dir=""

(
  cd "${release_dir}"
  "${uv_bin}" lock --check
  "${uv_bin}" sync --frozen
  .venv/bin/local-shell-mcp --version
  .venv/bin/python - "${tag}" "${expected_sha}" > release-manifest.json <<'PY'
import hashlib
import json
import platform
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

tag, commit = sys.argv[1:]
lock_path = Path("uv.lock")
manifest = {
    "schema": 1,
    "tag": tag,
    "fork_commit": commit,
    "upstream_tag": "v4.2.0",
    "upstream_commit": "1bfdf52d9566ee945b32ceb15aa3cde3ea6175dc",
    "lock_sha256": hashlib.sha256(lock_path.read_bytes()).hexdigest(),
    "tree": subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], text=True).strip(),
    "python": platform.python_version(),
    "built_at": datetime.now(UTC).isoformat(),
}
print(json.dumps(manifest, indent=2, sort_keys=True))
PY
  chmod 0444 release-manifest.json
  printf '%s\n' "${expected_sha}" > READY
  chmod 0444 READY
)

candidate_link="${deploy_root}/.candidate.${$}"
ln -s "releases/${release_name}" "${candidate_link}"
mv -Tf "${candidate_link}" "${deploy_root}/candidate"
echo "${release_dir}"
