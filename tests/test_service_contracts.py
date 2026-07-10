"""Service-loop contracts that unit tests alone used to miss."""

import importlib
import importlib.util
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


def test_release_artifacts_exclude_runtime_python(project_root):
    spec = importlib.util.spec_from_file_location(
        "release_smoke",
        project_root / "scripts" / "release_smoke.py",
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    runtime_files = set(module.WINDOWS_FILES + module.MACOS_FILES)
    forbidden = {
        "scripts/_jsonutil.py",
        "scripts/report.py",
        "scripts/rule_engine.py",
        "scripts/scanner_helper.py",
    }

    assert runtime_files.isdisjoint(forbidden)
    assert "scripts/report.ps1" in module.WINDOWS_FILES
    assert "scripts/rule_engine.ps1" in module.WINDOWS_FILES
    assert "scripts/report.jxa.js" in module.MACOS_FILES
    assert "scripts/scanner_helper.jxa.js" in module.MACOS_FILES
    assert "scripts/modules/macos/storage.sh" in module.MACOS_FILES
    assert "scripts/cleanup.sh" in module.MACOS_FILES
    assert "scripts/storage_watch.sh" in module.MACOS_FILES
    assert "scripts/schedule.sh" in module.MACOS_FILES
    assert "scripts/build_macos_swift_app.sh" in module.MACOS_FILES
    assert "scripts/package_macos_release.sh" in module.MACOS_FILES
    assert "Mac앱실행.command" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Package.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/PCHealthCheckMacApp.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Models/ScanModels.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Models/StorageHistory.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Models/WorkspaceSelection.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/RuntimeWorkspace.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/ScanModel.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Support/CleanupPresentation.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Support/ProcessRunState.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Support/ViewStyles.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/AppShell.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/CleanupView.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/DevelopmentView.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/InventoryView.swift" in module.MACOS_FILES
    assert "macos/PCHealthCheckMac/Tests/PCHealthCheckMacTests/PCHealthCheckMacTests.swift" in module.MACOS_FILES


def test_macos_launcher_is_executable(project_root):
    mode = (project_root / "검사하기.command").stat().st_mode
    assert mode & 0o111


def test_macos_swift_launcher_is_executable(project_root):
    for rel in (
        "Mac앱실행.command",
        "scripts/build_macos_swift_app.sh",
        "scripts/package_macos_release.sh",
    ):
        mode = (project_root / rel).stat().st_mode
        assert mode & 0o111, f"{rel} must be executable"


def test_macos_distribution_script_requires_explicit_credentials(project_root):
    source = (project_root / "scripts/package_macos_release.sh").read_text(encoding="utf-8")

    assert "PCH_CODESIGN_IDENTITY" in source
    assert "PCH_NOTARY_PROFILE" in source
    assert "--keychain-profile" in source
    assert "PCH_STANDALONE_BUNDLE=1" in source
    assert "project-root marker" in source


def test_macos_scan_completion_does_not_open_browser_automatically(project_root):
    source = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/ScanModel.swift"
    ).read_text(encoding="utf-8")
    finish_run = source.split("private func finishRun", 1)[1].split(
        "private func refreshExistingResults", 1
    )[0]

    assert "showNormalReport()" not in finish_run


def test_macos_timed_out_cleanup_measurements_remain_visible(project_root):
    helper = (project_root / "scripts/scanner_helper.jxa.js").read_text(encoding="utf-8")
    history = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Models/StorageHistory.swift"
    ).read_text(encoding="utf-8")

    assert 'item.measureStatus === "timed_out"' in helper
    assert "intersection(after.keys)" in history


def test_vt_env_key_contract_is_runtime_backed(project_root, tmp_path, monkeypatch):
    monkeypatch.setenv("VT_API_KEY", "dummy-key")
    module = importlib.import_module("scanner_helper")

    vt = module.VtLookup({"virustotal": {"enabled": False, "apiKey": ""}}, tmp_path)

    assert vt.enabled is True
    assert vt.cfg["apiKey"] == "dummy-key"


def test_macos_jxa_vt_does_not_write_api_key_header_file(project_root):
    helper = (project_root / "scripts" / "scanner_helper.jxa.js").read_text(encoding="utf-8")

    assert "vt_headers" not in helper
    assert "-H @" not in helper
    assert "cfg.enabled = true" in helper


def test_powershell_vt_env_key_auto_enables(project_root):
    helper = (project_root / "scripts" / "vt-lookup.ps1").read_text(encoding="utf-8-sig")

    assert "NotePropertyName enabled -NotePropertyValue $true" in helper
    assert "hasExplicitEnabled" not in helper


def test_release_report_generators_have_investigation_links(project_root):
    jxa = (project_root / "scripts" / "report.jxa.js").read_text(encoding="utf-8")
    ps1 = (project_root / "scripts" / "report.ps1").read_text(encoding="utf-8-sig")

    for source in (jxa, ps1):
        assert "https://www.google.com/search" in source
        assert "https://www.virustotal.com/gui/ip-address" in source
        assert "https://www.virustotal.com/gui/file" in source
