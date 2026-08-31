#!/usr/bin/env python3
"""Run one command with a hard wall-clock timeout.

Exit 124 is reserved for a local deadline expiry, matching the conventional
`timeout(1)` status. Child stdout/stderr/stdin stay attached to the caller so
this helper is safe around SSH scripts and probes.
"""

from __future__ import annotations

import subprocess
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[1] == "--help":
        print(f"usage: {argv[0]} <timeout-seconds> <command> [args...]", file=sys.stderr)
        return 64
    try:
        timeout_s = float(argv[1])
    except ValueError:
        print("timeout must be numeric", file=sys.stderr)
        return 64
    if timeout_s <= 0:
        print("timeout must be positive", file=sys.stderr)
        return 64
    try:
        completed = subprocess.run(argv[2:], check=False, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        print(f"command exceeded {timeout_s:g}s deadline", file=sys.stderr)
        return 124
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
