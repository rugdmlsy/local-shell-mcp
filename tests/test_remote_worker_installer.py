from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
from types import SimpleNamespace

import pytest

from local_shell_mcp import remote_worker_installer as installer
from local_shell_mcp import remote_worker_state as state


def _bundle() -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        content = b"value = 1\n"
        info = tarfile.TarInfo("local_shell_mcp/example.py")
        info.size = len(content)
        tar.addfile(info, io.BytesIO(content))
    return buffer.getvalue()


def _configure(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKER_STATE_DIR", str(tmp_path / "state"))
    state.write_worker_config(server="https://example.test", name="worker", workdir=str(tmp_path))
    monkeypatch.setattr(installer, "verify_extracted_worker_runtime", lambda runtime: None)


def test_install_update_and_cache_runtime(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    payload = _bundle()
    digest = hashlib.sha256(payload).hexdigest()
    monkeypatch.setattr(
        installer,
        "fetch_manifest",
        lambda server: {
            "schema_version": 1,
            "sha256": digest,
            "bundle_version": "3.0.1",
            "url": "https://example.test/bundle.tgz",
        },
    )
    monkeypatch.setattr(installer, "_fetch_bytes", lambda url, timeout=60: payload)

    result = installer.install_or_update_runtime("https://example.test")
    assert result["updated"] is True
    assert (state.worker_runtime_dir() / "local_shell_mcp" / "example.py").exists()
    assert state.read_worker_config()["runtime_digest"] == digest

    monkeypatch.setattr(installer, "_fetch_bytes", lambda *args, **kwargs: pytest.fail("downloaded"))
    cached = installer.install_or_update_runtime("https://example.test")
    assert cached["updated"] is False


def test_runtime_checksum_and_archive_validation(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    payload = _bundle()
    monkeypatch.setattr(
        installer,
        "fetch_manifest",
        lambda server: {
            "schema_version": 1,
            "sha256": "0" * 64,
            "bundle_version": "3.0.1",
            "url": "https://example.test/bundle.tgz",
        },
    )
    monkeypatch.setattr(installer, "_fetch_bytes", lambda url, timeout=60: payload)
    with pytest.raises(ValueError, match="checksum mismatch"):
        installer.install_or_update_runtime("https://example.test")

    archive = tmp_path / "unsafe.tgz"
    with tarfile.open(archive, mode="w:gz") as tar:
        info = tarfile.TarInfo("../escape")
        info.size = 1
        tar.addfile(info, io.BytesIO(b"x"))
    with pytest.raises(ValueError, match="unsafe worker bundle path"):
        installer._safe_extract(archive, tmp_path / "extract")  # noqa: SLF001

    link_archive = tmp_path / "link.tgz"
    with tarfile.open(link_archive, mode="w:gz") as tar:
        info = tarfile.TarInfo("local_shell_mcp/link")
        info.type = tarfile.SYMTYPE
        info.linkname = "target"
        tar.addfile(info)
    with pytest.raises(ValueError, match="links are not supported"):
        installer._safe_extract(link_archive, tmp_path / "extract-links")  # noqa: SLF001


def test_fetch_manifest_validation(monkeypatch):
    valid = {
        "schema_version": 1,
        "sha256": "a" * 64,
        "bundle_version": "3.0.0",
        "url": "/remote/worker-bundle.tgz",
    }
    requested = []

    def fetch(url):
        requested.append(url)
        return json.dumps(valid).encode()

    monkeypatch.setattr(installer, "_fetch_bytes", fetch)
    result = installer.fetch_manifest("https://example.test/base")
    assert requested == ["https://example.test/base/remote/worker-bundle.tgz?manifest=1"]
    assert result["url"] == "https://example.test/remote/worker-bundle.tgz"

    monkeypatch.setattr(installer, "_fetch_bytes", lambda url: b"{}")
    with pytest.raises(ValueError, match="invalid remote worker manifest"):
        installer.fetch_manifest("https://example.test")

    incomplete = {"schema_version": 1, "sha256": "short", "url": ""}
    monkeypatch.setattr(installer, "_fetch_bytes", lambda url: json.dumps(incomplete).encode())
    with pytest.raises(ValueError, match="manifest is incomplete"):
        installer.fetch_manifest("https://example.test")


def test_fetch_bytes_uses_urlopen(monkeypatch):
    class Response:
        def __enter__(self):
            return self
        def __exit__(self, *args):
            return False
        def read(self):
            return b"payload"
    captured = []
    monkeypatch.setattr(
        installer.urllib.request,
        "urlopen",
        lambda request, timeout=60: captured.append((request, timeout)) or Response(),
    )
    assert installer._fetch_bytes("https://example.test/file", timeout=7) == b"payload"  # noqa: SLF001
    request, timeout = captured[0]
    assert request.full_url == "https://example.test/file"
    assert request.headers["Cache-control"] == "no-cache"
    assert request.headers["Pragma"] == "no-cache"
    assert request.headers["User-agent"] == f"local-shell-mcp-worker/{installer.__version__}"
    assert timeout == 7


def test_install_without_existing_config_rejects_incomplete_bundle(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("LOCAL_SHELL_MCP_WORKER_STATE_DIR", str(tmp_path / "state"))
    payload_buffer = io.BytesIO()
    with tarfile.open(fileobj=payload_buffer, mode="w:gz") as tar:
        content = b"not a package"
        info = tarfile.TarInfo("other.txt")
        info.size = len(content)
        tar.addfile(info, io.BytesIO(content))
    payload = payload_buffer.getvalue()
    digest = hashlib.sha256(payload).hexdigest()
    monkeypatch.setattr(
        installer,
        "fetch_manifest",
        lambda server: {"sha256": digest, "bundle_version": "v", "url": "https://s/b.tgz"},
    )
    monkeypatch.setattr(installer, "_fetch_bytes", lambda *args, **kwargs: payload)
    with pytest.raises(ValueError, match="does not contain local_shell_mcp"):
        installer.install_or_update_runtime("https://s")


def test_failed_candidate_self_test_leaves_runtime_and_metadata_untouched(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    runtime = state.worker_runtime_dir()
    (runtime / "local_shell_mcp").mkdir(parents=True)
    (runtime / "local_shell_mcp" / "current.py").write_text("old = True\n", encoding="utf-8")
    state.update_runtime_metadata("old-digest", "old-version")
    payload = _bundle()
    digest = hashlib.sha256(payload).hexdigest()
    monkeypatch.setattr(
        installer,
        "fetch_manifest",
        lambda server: {
            "schema_version": 2,
            "sha256": digest,
            "bundle_version": "new-version",
            "url": "https://example.test/bundle.tgz",
        },
    )
    monkeypatch.setattr(installer, "_fetch_bytes", lambda *args, **kwargs: payload)

    def reject(runtime):
        raise RuntimeError("isolated candidate failed")

    monkeypatch.setattr(installer, "verify_extracted_worker_runtime", reject)
    with pytest.raises(RuntimeError, match="isolated candidate failed"):
        installer.install_or_update_runtime("https://example.test")

    assert (runtime / "local_shell_mcp" / "current.py").exists()
    assert state.read_worker_config()["runtime_digest"] == "old-digest"
    assert not state.worker_previous_runtime_dir().exists()
    assert not state.worker_pending_upgrade_path().exists()


def test_runtime_activation_keeps_previous_and_pending_marker(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    runtime = state.worker_runtime_dir()
    (runtime / "local_shell_mcp").mkdir(parents=True)
    (runtime / "local_shell_mcp" / "current.py").write_text("old = True\n", encoding="utf-8")
    state.update_runtime_metadata("old-digest", "old-version")
    payload = _bundle()
    digest = hashlib.sha256(payload).hexdigest()
    monkeypatch.setattr(
        installer,
        "fetch_manifest",
        lambda server: {
            "schema_version": 2,
            "sha256": digest,
            "bundle_version": "new-version",
            "url": "https://example.test/bundle.tgz",
        },
    )
    monkeypatch.setattr(installer, "_fetch_bytes", lambda *args, **kwargs: payload)

    installer.install_or_update_runtime("https://example.test")

    assert (runtime / "local_shell_mcp" / "example.py").exists()
    assert (state.worker_previous_runtime_dir() / "local_shell_mcp" / "current.py").exists()
    marker = json.loads(state.worker_pending_upgrade_path().read_text(encoding="utf-8"))
    assert marker["old_digest"] == "old-digest"
    assert marker["new_digest"] == digest
    assert marker["old_version"] == "old-version"
    assert marker["new_version"] == "new-version"
    assert marker["launch_attempted_at"] is None
    assert state.read_worker_config()["runtime_digest"] == digest


def test_service_restart_rolls_back_pending_candidate_before_import(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    runtime = state.worker_runtime_dir()
    package = runtime / "local_shell_mcp"
    package.mkdir(parents=True)
    (package / "__init__.py").write_text("", encoding="utf-8")
    (package / "main.py").write_text(
        "def main(argv):\n    print('old-runtime-started')\n",
        encoding="utf-8",
    )
    state.update_runtime_metadata("old-digest", "old-version")

    payload_buffer = io.BytesIO()
    with tarfile.open(fileobj=payload_buffer, mode="w:gz") as archive:
        for name, content in {
            "local_shell_mcp/__init__.py": b"",
            "local_shell_mcp/main.py": b"raise RuntimeError('candidate imported')\n",
        }.items():
            info = tarfile.TarInfo(name)
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
    payload = payload_buffer.getvalue()
    digest = hashlib.sha256(payload).hexdigest()
    monkeypatch.setattr(
        installer,
        "fetch_manifest",
        lambda server: {
            "schema_version": 2,
            "sha256": digest,
            "bundle_version": "new-version",
            "url": "https://example.test/bundle.tgz",
        },
    )
    monkeypatch.setattr(installer, "_fetch_bytes", lambda *args, **kwargs: payload)
    installer.install_or_update_runtime("https://example.test")
    marker_path = state.worker_pending_upgrade_path()
    marker = json.loads(marker_path.read_text(encoding="utf-8"))
    marker["launch_attempted_at"] = 1.0
    marker_path.write_text(json.dumps(marker), encoding="utf-8")
    state.install_launcher()

    completed = subprocess.run(
        [sys.executable, str(state.worker_bootstrap_path()), "worker", "run"],
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "LOCAL_SHELL_MCP_WORKER_STATE_DIR": str(tmp_path / "state")},
    )

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout.strip() == "old-runtime-started"
    assert state.read_worker_config()["runtime_digest"] == "old-digest"
    assert not marker_path.exists()
    assert not state.worker_previous_runtime_dir().exists()



def test_worker_dependency_bootstrap_is_noop_off_windows(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    monkeypatch.setattr(installer.sys, "platform", "linux")
    monkeypatch.setattr(installer.sys, "path", list(installer.sys.path))
    monkeypatch.setenv("PYTHONPATH", "")

    result = installer.ensure_platform_dependencies()

    assert result["available"] is True
    assert result["installed"] is False


def test_windows_worker_reuses_existing_pywinpty(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    monkeypatch.setattr(installer.sys, "platform", "win32")
    monkeypatch.setattr(installer.sys, "path", list(installer.sys.path))
    monkeypatch.setenv("PYTHONPATH", "")
    monkeypatch.setattr(
        installer.importlib,
        "import_module",
        lambda name: SimpleNamespace(PtyProcess=object()),
    )
    monkeypatch.setattr(
        installer.subprocess,
        "run",
        lambda *args, **kwargs: pytest.fail("pip should not run when pywinpty is available"),
    )

    result = installer.ensure_platform_dependencies()

    assert result["available"] is True
    assert result["installed"] is False


def test_windows_worker_reports_failed_import_after_successful_pip(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    monkeypatch.setattr(installer.sys, "platform", "win32")
    monkeypatch.setattr(installer.sys, "path", list(installer.sys.path))
    monkeypatch.setenv("PYTHONPATH", "")
    def missing(name):
        raise ImportError(name)

    monkeypatch.setattr(installer.importlib, "import_module", missing)
    monkeypatch.setattr(installer.importlib, "invalidate_caches", lambda: None)
    monkeypatch.setattr(
        installer.subprocess,
        "run",
        lambda argv, **kwargs: subprocess.CompletedProcess(
            argv, 0, stdout="installed but unavailable", stderr=""
        ),
    )

    result = installer.ensure_platform_dependencies()

    assert result["available"] is False
    assert result["installed"] is False
    assert result["error"] == "installed but unavailable"

def test_windows_worker_installs_pywinpty_into_state_dir(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    monkeypatch.setattr(installer.sys, "platform", "win32")
    monkeypatch.setattr(installer.sys, "path", list(installer.sys.path))
    monkeypatch.setenv("PYTHONPATH", "")
    imports = []

    def import_module(name):
        imports.append(name)
        if len(imports) == 1:
            raise ImportError(name)
        return SimpleNamespace(PtyProcess=object())

    captured = {}

    def run(argv, **kwargs):
        captured["argv"] = argv
        captured["kwargs"] = kwargs
        return subprocess.CompletedProcess(argv, 0, stdout="installed", stderr="")

    monkeypatch.setattr(installer.importlib, "import_module", import_module)
    monkeypatch.setattr(installer.importlib, "invalidate_caches", lambda: None)
    monkeypatch.setattr(installer.subprocess, "run", run)

    result = installer.ensure_platform_dependencies()

    target = installer.worker_dependency_dir()
    assert result["available"] is True
    assert result["installed"] is True
    assert captured["argv"][-1] == "pywinpty>=2.0.13"
    assert captured["argv"][captured["argv"].index("--target") + 1] == str(target)
    assert str(target.resolve()) in installer.sys.path
    assert captured["kwargs"]["timeout"] == 60


def test_windows_worker_falls_back_when_pywinpty_install_fails(tmp_path, monkeypatch):
    _configure(tmp_path, monkeypatch)
    monkeypatch.setattr(installer.sys, "platform", "win32")
    monkeypatch.setattr(installer.sys, "path", list(installer.sys.path))
    monkeypatch.setenv("PYTHONPATH", "")

    def missing(name):
        raise ImportError(name)

    def timeout(*args, **kwargs):
        raise subprocess.TimeoutExpired(args[0], 60)

    monkeypatch.setattr(installer.importlib, "import_module", missing)
    monkeypatch.setattr(installer.subprocess, "run", timeout)

    result = installer.ensure_platform_dependencies()

    assert result["available"] is False
    assert result["installed"] is False
    assert "timed out" in result["error"]
