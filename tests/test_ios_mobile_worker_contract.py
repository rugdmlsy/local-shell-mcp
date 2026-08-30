from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRANSFER_EXECUTOR = ROOT / "ios" / "LSMMobileWorker" / "Sources" / "MobileTransferExecutor.swift"


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
