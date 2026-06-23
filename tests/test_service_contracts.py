"""Service-loop contracts that unit tests alone used to miss."""

import importlib
import json
import subprocess
import sys
from pathlib import Path


def test_report_rejects_raw_facts_without_summary(project_root, tmp_path):
    raw = {
        "schemaVersion": "1.0",
        "scannedAt": "2026-06-23 00:00:00",
        "computerName": "example",
        "userName": "user",
        "osVersion": "Windows",
        "findings": [],
        "sections": {},
    }
    raw_path = tmp_path / "raw_facts.json"
    raw_path.write_text(json.dumps(raw), encoding="utf-8")

    result = subprocess.run(
        [
            sys.executable,
            str(project_root / "scripts" / "report.py"),
            "--scan",
            str(raw_path),
            "--output",
            str(tmp_path / "report.html"),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    assert result.returncode == 2
    assert "summary" in result.stderr
    assert not (tmp_path / "report.html").exists()


def test_scanner_helper_import_has_no_scan_side_effect(project_root, tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("PCH_OUTPUT", str(tmp_path / "scan_result.json"))
    monkeypatch.setenv("PCH_RAW_PATH", str(tmp_path / "raw_facts.json"))

    module = importlib.import_module("scanner_helper")

    assert hasattr(module, "main")
    assert not (tmp_path / "scan_result.json").exists()
    assert not (tmp_path / "raw_facts.json").exists()


def test_release_smoke_check_only(project_root):
    result = subprocess.run(
        [
            sys.executable,
            str(project_root / "scripts" / "release_smoke.py"),
            "--check-only",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["ok"] is True
    assert payload["windows_entries"] > 0
    assert payload["macos_entries"] > 0


def test_macos_launcher_is_executable(project_root):
    mode = (project_root / "검사하기.command").stat().st_mode
    assert mode & 0o111
