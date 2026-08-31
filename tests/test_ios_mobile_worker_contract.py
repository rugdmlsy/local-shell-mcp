from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS_ROOT = ROOT / "ios" / "LSMMobileWorker"
TRANSFER_EXECUTOR = IOS_ROOT / "Sources" / "MobileTransferExecutor.swift"
ACTION_EXECUTOR = IOS_ROOT / "Sources" / "MobileActionExecutor.swift"
CONTENT_VIEW = IOS_ROOT / "Sources" / "ContentView.swift"
PROJECT_SPEC = IOS_ROOT / "project.yml"


def test_ios_worker_dispatches_controller_transfer_wire_tools() -> None:
    source = TRANSFER_EXECUTOR.read_text(encoding="utf-8")
    required = {
        "transfer_stat",
        "transfer_read_chunk",
        "transfer_begin_write",
        "transfer_write_chunk",
        "transfer_finish_write",
        "transfer_abort_write",
        "transfer_upload_url",
        "transfer_download_url",
    }
    missing = sorted(tool for tool in required if f'case "{tool}":' not in source)
    assert not missing, f"iOS worker is missing controller transfer wire tools: {missing}"


def test_ios_worker_dispatches_phase3_mobile_actions() -> None:
    source = ACTION_EXECUTOR.read_text(encoding="utf-8")
    required = {
        "network_history",
        "dns_probe",
        "tcp_probe",
        "tls_probe",
        "bookmarks_list",
        "bookmark_import",
        "bookmark_export",
        "clipboard_status",
        "clipboard_write",
        "clipboard_read",
        "approval_prompt",
    }
    missing = sorted(action for action in required if f'case "{action}":' not in source)
    assert not missing, f"iOS worker is missing Phase 3 mobile actions: {missing}"


def test_ios_privacy_sensitive_phase3_controls_are_local_opt_in() -> None:
    content = CONTENT_VIEW.read_text(encoding="utf-8")
    executor = ACTION_EXECUTOR.read_text(encoding="utf-8")

    assert "Grant Access to File" in content
    assert "Grant Access to Folder" in content
    assert "Allow Remote Clipboard Read" in content
    assert "requestCameraPermission" not in executor.split("func execute", 1)[1]
    assert "requestPhotoPermission" not in executor.split("func execute", 1)[1]
    assert "requestLocationPermission" not in executor.split("func execute", 1)[1]


def test_share_extension_is_optional_and_does_not_change_default_entitlements() -> None:
    spec = PROJECT_SPEC.read_text(encoding="utf-8")
    assert "LSMMobileWorkerWithShare:" in spec
    assert "LSMShareExtension:" in spec
    assert "LSMMobileWorkerShare.entitlements" in spec
    default_target = spec.split("  LSMMobileWorker:\n", 1)[1].split("  LSMMobileWorkerWithShare:\n", 1)[0]
    assert "application-groups" not in default_target
    assert "LSMMobileWorkerShare.entitlements" not in default_target
