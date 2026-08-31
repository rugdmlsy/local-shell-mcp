from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IOS_ROOT = ROOT / "ios" / "LSMMobileWorker"
TRANSFER_EXECUTOR = IOS_ROOT / "Sources" / "MobileTransferExecutor.swift"
ACTION_EXECUTOR = IOS_ROOT / "Sources" / "MobileActionExecutor.swift"
CONTENT_VIEW = IOS_ROOT / "Sources" / "ContentView.swift"
PROJECT_SPEC = IOS_ROOT / "project.yml"
WORKER_CLIENT = IOS_ROOT / "Sources" / "WorkerClient.swift"
WORKER_RUNTIME = IOS_ROOT / "Sources" / "WorkerRuntime.swift"
SCANNER = IOS_ROOT / "Sources" / "CodeScanner.swift"
APP_INTENTS = IOS_ROOT / "Sources" / "LSMAppIntents.swift"


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


def test_ios_worker_dispatches_phase4_mobile_actions() -> None:
    source = ACTION_EXECUTOR.read_text(encoding="utf-8")
    assert '"mobile.controller_events"' in source
    required = {
        "device_status",
        "sensor_snapshot",
        "last_scanned_code",
        "send_to_mobile",
        "inbox_list",
    }
    missing = sorted(action for action in required if f'case "{action}":' not in source)
    assert not missing, f"iOS worker is missing Phase 4 mobile actions: {missing}"


def test_phase4_controller_events_use_authenticated_poll_ack_and_dashboard_routes() -> None:
    client = WORKER_CLIENT.read_text(encoding="utf-8")
    runtime = WORKER_RUNTIME.read_text(encoding="utf-8")
    assert 'path: "/remote/events-ack"' in client
    assert 'path: "/remote/mobile-dashboard"' in client
    assert 'payload["events"]' in client
    assert 'payload["events"]' in runtime


def test_qr_scanner_remains_local_user_initiated() -> None:
    content = CONTENT_VIEW.read_text(encoding="utf-8")
    executor = ACTION_EXECUTOR.read_text(encoding="utf-8")
    scanner = SCANNER.read_text(encoding="utf-8")
    intents = APP_INTENTS.read_text(encoding="utf-8")
    assert 'Button("Scan QR / Barcode")' in content
    assert "startLocalScan()" in content
    assert "startLocalScan()" not in executor
    assert "AVCaptureMetadataOutput" in scanner
    assert "openAppWhenRun: Bool = true" in intents


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
