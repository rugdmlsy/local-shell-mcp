from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

REPOSITORY = Path(__file__).parents[1]
DEPLOY_COMMAND = REPOSITORY / "deploy/morrow/deploy-vps.sh"
MCP_PROBE = REPOSITORY / "scripts/probe-mcp.py"
HOST_CONFIG = REPOSITORY / "deploy/morrow/host.yaml.example"
HOST_LAUNCHER = REPOSITORY / "deploy/morrow/run-host-vps.sh"
VERIFY_RELEASE = REPOSITORY / "deploy/morrow/verify-release.sh"
CHECK_RELEASE_PROCESS = REPOSITORY / "deploy/morrow/check-release-process.sh"
CURRENT_RELEASE = REPOSITORY / "deploy/morrow/current-release.sh"
SSH_GUARD = REPOSITORY / "deploy/morrow/ssh-guard.sh"
TIMEOUT_HELPER = REPOSITORY / "deploy/morrow/run-command-with-timeout.py"


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
        "local-shell-mcp-cloudflared.service",
        "LSM_DEPLOY_UV_BIN",
        "sudo -n systemctl --no-block restart",
        "wait_for_release_process",
        "ControlMaster=auto",
        "ControlMaster=no",
        "ServerAliveInterval=5",
        "ServerAliveCountMax=2",
        "remote_fresh_guarded",
        "run-command-with-timeout.py",
        "verify-release.sh",
        "post_switch_transport_uncertain",
        "ssh-guard.sh",
        "post_switch_run_script",
        "preserving the current release; refusing automatic rollback",
        "cleanup_ssh",
        "LSM_DEPLOY_SERVICE_ENV",
        "post-switch verification failed; rolling back",
    ):
        assert required in script

    assert 'local release_name="$1"' not in script
    assert "remote_guarded()" in script
    assert "remote_fresh_guarded()" in script
    assert script.index("if ${post_switch_transport_uncertain}; then") < script.index(
        'echo "post-switch verification failed; rolling back"'
    )


def test_post_switch_verifier_and_timeout_helper_are_deterministic() -> None:
    verifier = VERIFY_RELEASE.read_text(encoding="utf-8")
    process_check = CHECK_RELEASE_PROCESS.read_text(encoding="utf-8")
    guard = SSH_GUARD.read_text(encoding="utf-8")
    assert "probe-mcp.py" in verifier
    assert "--pin-env LOCAL_SHELL_MCP_OAUTH_ADMIN_PIN" in verifier
    assert "/proc/${pid}/cmdline" in process_check
    assert 'test "$1" -eq 124 || test "$1" -eq 255' in guard
    for script in (VERIFY_RELEASE, CHECK_RELEASE_PROCESS, CURRENT_RELEASE, SSH_GUARD):
        subprocess.run(["bash", "-n", str(script)], check=True)

    success = subprocess.run(
        [sys.executable, str(TIMEOUT_HELPER), "2", sys.executable, "-c", "print('ok')"],
        check=False,
        capture_output=True,
        text=True,
    )
    assert success.returncode == 0
    assert success.stdout.strip() == "ok"

    child_failure = subprocess.run(
        [sys.executable, str(TIMEOUT_HELPER), "2", sys.executable, "-c", "raise SystemExit(7)"],
        check=False,
    )
    assert child_failure.returncode == 7

    expired = subprocess.run(
        [
            sys.executable,
            str(TIMEOUT_HELPER),
            "0.05",
            sys.executable,
            "-c",
            "import time; time.sleep(1)",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert expired.returncode == 124
    assert "exceeded 0.05s deadline" in expired.stderr


def test_post_switch_ssh_policy_fault_injection(tmp_path: Path) -> None:
    payload = tmp_path / "payload.sh"
    payload.write_text("exit 0\n", encoding="utf-8")
    marker = tmp_path / "fresh-called"
    harness = r'''
sleep() { :; }
remote_guarded() { cat >/dev/null; return "${PRIMARY_STATUS}"; }
remote_fresh_guarded() {
  cat >/dev/null
  printf 'called\n' >> "${MARKER}"
  return "${FRESH_STATUS}"
}
. "${SSH_GUARD_PATH}"
if post_switch_run_script "${PAYLOAD}" demo; then
  status=0
else
  status=$?
fi
printf 'status=%s\n' "${status}"
'''

    def run(primary: int, fresh: int) -> subprocess.CompletedProcess[str]:
        marker.unlink(missing_ok=True)
        env = {
            **os.environ,
            "PRIMARY_STATUS": str(primary),
            "FRESH_STATUS": str(fresh),
            "MARKER": str(marker),
            "SSH_GUARD_PATH": str(SSH_GUARD),
            "PAYLOAD": str(payload),
        }
        return subprocess.run(
            ["bash", "-c", harness],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    recovered = run(124, 0)
    assert recovered.returncode == 0
    assert "status=0" in recovered.stdout
    assert marker.exists()

    explicit_remote_failure = run(7, 0)
    assert explicit_remote_failure.returncode == 0
    assert "status=7" in explicit_remote_failure.stdout
    assert not marker.exists(), "explicit remote failures must not try an alternate transport"

    indeterminate = run(255, 255)
    assert indeterminate.returncode == 0
    assert "status=75" in indeterminate.stdout
    assert marker.exists()


def test_production_owns_official_live_workspace_and_goal_continuation() -> None:
    config = HOST_CONFIG.read_text(encoding="utf-8")
    launcher = HOST_LAUNCHER.read_text(encoding="utf-8")

    assert "disable_local: false" in config
    assert "logical_sessions_enabled: true" in config
    assert "live_workspace_enabled: true" in config
    assert "LOCAL_SHELL_MCP_DISABLE_LOCAL=false" in launcher
    assert "LOCAL_SHELL_MCP_LOGICAL_SESSIONS_ENABLED=true" in launcher
    assert "LOCAL_SHELL_MCP_LIVE_WORKSPACE_ENABLED=true" in launcher
    assert "do not delegate continuation to Morrow Chat" in (
        REPOSITORY / "deploy/morrow/README.md"
    ).read_text(encoding="utf-8")


def test_probe_accepts_pin_from_environment_without_a_command_line_secret() -> None:
    help_result = subprocess.run(
        [sys.executable, str(MCP_PROBE), "--help"],
        check=True,
        capture_output=True,
        text=True,
    )

    assert "--pin-env NAME" in help_result.stdout
