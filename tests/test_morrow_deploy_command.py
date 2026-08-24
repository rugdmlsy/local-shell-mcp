from __future__ import annotations

import os
import subprocess
from pathlib import Path

REPOSITORY = Path(__file__).parents[1]
DEPLOY_COMMAND = REPOSITORY / "deploy/morrow/deploy-vps.sh"


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
        "--call-environment",
        "local-shell-mcp-cloudflared.service",
        "LSM_DEPLOY_UV_BIN",
        "sudo -n systemctl --no-block restart",
        "wait_for_release_process",
        "/proc/${pid}/cmdline",
        "ControlMaster=auto",
        "cleanup_ssh",
        "post-switch verification failed; rolling back",
    ):
        assert required in script
