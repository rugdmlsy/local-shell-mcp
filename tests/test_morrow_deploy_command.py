from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

REPOSITORY = Path(__file__).parents[1]
DEPLOY_COMMAND = REPOSITORY / "deploy/morrow/deploy-vps.sh"
MCP_PROBE = REPOSITORY / "scripts/probe-mcp.py"


def test_deploy_command_is_executable_and_parses() -> None:
    assert os.access(DEPLOY_COMMAND, os.X_OK)
    subprocess.run(["bash", "-n", str(DEPLOY_COMMAND)], check=True)
    help_result = subprocess.run(
        [str(DEPLOY_COMMAND), "--help"],
        check=True,
        capture_output=True,
        text=True,
    )
    assert "--dry-run" in help_result.stdout


def test_deploy_command_keeps_release_and_rollback_guards() -> None:
    script = DEPLOY_COMMAND.read_text(encoding="utf-8")

    for required in (
        "git status --porcelain",
        "git tag -a",
        "build-release.sh",
        "switch-release.sh",
        "rollback-release.sh",
        "probe-mcp.py",
        "--pin-env LOCAL_SHELL_MCP_OAUTH_ADMIN_PIN",
        "local-shell-mcp-cloudflared.service",
        "LSM_DEPLOY_UV_BIN",
        "sudo -n systemctl --no-block restart",
        "wait_for_release_process",
        "/proc/${pid}/cmdline",
        "ControlMaster=auto",
        "cleanup_ssh",
        "LSM_DEPLOY_SERVICE_ENV",
        "post-switch verification failed; rolling back",
    ):
        assert required in script

    assert 'local release_name="$1"' not in script


def test_probe_accepts_pin_from_environment_without_a_command_line_secret() -> None:
    help_result = subprocess.run(
        [sys.executable, str(MCP_PROBE), "--help"],
        check=True,
        capture_output=True,
        text=True,
    )

    assert "--pin-env NAME" in help_result.stdout
