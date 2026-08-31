#!/usr/bin/env bash
set -euo pipefail

test "$#" -eq 1 || exit 64
deploy_root="$1"
basename "$(readlink -f "${deploy_root}/current")"
