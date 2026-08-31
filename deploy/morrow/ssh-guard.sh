#!/usr/bin/env bash
# Shared post-switch SSH transport policy. The caller must define
# remote_guarded() and remote_fresh_guarded().

is_transport_failure() {
  test "$1" -eq 124 || test "$1" -eq 255
}

post_switch_run_script() {
  local script_path="$1"
  shift
  local status

  if remote_guarded bash -s -- "$@" < "${script_path}"; then
    return 0
  else
    status=$?
  fi
  if ! is_transport_failure "${status}"; then
    return "${status}"
  fi

  echo "multiplexed SSH transport failed (${status}); trying one independent connection" >&2
  sleep 2
  if remote_fresh_guarded bash -s -- "$@" < "${script_path}"; then
    return 0
  else
    status=$?
  fi
  if is_transport_failure "${status}"; then
    return 75
  fi
  return "${status}"
}
