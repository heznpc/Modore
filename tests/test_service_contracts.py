"""Service-loop contracts that unit tests alone used to miss."""

import importlib
import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


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
            "-I",
            "-B",
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
    swift_root = project_root / "macos" / "PCHealthCheckMac"
    swift_files = {
        path.relative_to(project_root).as_posix()
        for path in swift_root.rglob("*.swift")
        if ".build" not in path.parts
    }
    assert swift_files.issubset(set(module.MACOS_FILES))


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
    assert "project-root marker" in source


def test_macos_scan_completion_does_not_open_browser_automatically(project_root):
    source = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/ScanModel.swift"
    ).read_text(encoding="utf-8")
    finish_run = source.split("func finishRun", 1)[1].split(
        "private func refreshExistingResults", 1
    )[0]

    assert "showNormalReport()" not in finish_run


def test_macos_high_frequency_log_state_is_isolated(project_root):
    source = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/ScanModel.swift"
    ).read_text(encoding="utf-8")
    watch_service = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/StorageWatchService.swift"
    ).read_text(encoding="utf-8")
    overview = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/StorageOverviewView.swift"
    ).read_text(encoding="utf-8")

    assert "@Published var logText" not in source
    assert "let logStore = ScanLogStore()" in source
    assert "@Published private(set) var content = ScanContent.empty" in source
    assert "LocalProcessRunner.capture" in watch_service
    assert "struct StorageOverviewPage: View" not in overview


def test_macos_ui_reserves_chromatic_status_colors_for_critical_states(project_root):
    source_root = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac"
    )
    sources = "\n".join(
        path.read_text(encoding="utf-8") for path in source_root.rglob("*.swift")
    )

    assert ".orange" not in sources
    assert ".yellow" not in sources
    assert "systemOrange" not in sources
    assert "systemYellow" not in sources


def test_macos_scanner_pins_the_exact_config_snapshot_used_for_network_consent(
    project_root,
):
    pipeline = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/ScanPipeline.swift"
    ).read_text(encoding="utf-8")
    runner = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/LocalProcessRunner.swift"
    ).read_text(encoding="utf-8")
    scanner = (project_root / "scripts/scanner.sh").read_text(encoding="utf-8")

    assert '["configuration": configurationData]' in pipeline
    assert 'scannerEnvironment["PCH_PINNED_CONFIG"]' in pipeline
    assert 'virusTotalIsExplicitlyEnabled(in: configurationData)' in pipeline
    assert '"PCH_PINNED_CONFIG"' in runner
    assert "CONFIG_PATH=/dev/fd/9" in scanner
    assert '9< "$PINNED_CONFIG_SOURCE"' in scanner
    assert 'umask 077; report_source="$1"' in pipeline
    assert 'umask 077; exec /usr/bin/osascript' in pipeline


def test_macos_collection_failures_cannot_be_reported_as_safe(project_root):
    scanner = (project_root / "scripts/scanner.sh").read_text(encoding="utf-8")
    network = (
        project_root / "scripts/modules/macos/network.sh"
    ).read_text(encoding="utf-8")
    helper = (project_root / "scripts/scanner_helper.jxa.js").read_text(encoding="utf-8")

    for status in (
        "permission_denied",
        "unavailable",
        "timed_out",
        "failed",
    ):
        assert status in scanner
        assert status in helper
    assert "record_collection_status" in scanner
    assert '"network_connections"' in network
    assert '"listening_ports"' in network
    assert 'collectionComplete ? "safe" : "incomplete"' in helper
    assert "필수 검사 일부를 완료하지 못해 안전 여부를 판단할 수 없습니다." in helper


def test_macos_default_scan_never_prompts_for_sfltool_admin_access(project_root):
    autoruns = (
        project_root / "scripts/modules/macos/autoruns.sh"
    ).read_text(encoding="utf-8")

    assert '${PCH_ENABLE_SFLTOOL:-0}' in autoruns
    assert '== "1" && -x /usr/bin/sfltool' in autoruns
    assert "관리자 인증 창을 피하기 위해 기본 검사에서 생략했습니다." in autoruns


def test_macos_browser_automation_evidence_is_structured_without_raw_commands(
    project_root,
):
    storage = (
        project_root / "scripts/modules/macos/storage.sh"
    ).read_text(encoding="utf-8")
    helper = (project_root / "scripts/scanner_helper.jxa.js").read_text(encoding="utf-8")

    for field in ("parentPid", "elapsed", "channel", "state", "profile", "controller"):
        assert field in helper
    assert 'verdict = orphanedRoots.length ? "orphaned"' in helper
    assert 'systemRoots.length ? "conflict_possible"' in helper
    assert "parent_command" in storage
    assert "storage_runtime.tsv" in storage


def test_macos_timed_out_cleanup_measurements_remain_visible(project_root):
    helper = (project_root / "scripts/scanner_helper.jxa.js").read_text(encoding="utf-8")
    history = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Models/StorageChangeSummary.swift"
    ).read_text(encoding="utf-8")

    assert 'item.measureStatus === "timed_out"' in helper
    assert "union(after.keys)" in history
    assert 'old?.measureStatus == "timed_out"' in history
    assert 'row?.measureStatus == "timed_out"' in history


def test_vt_env_key_requires_explicit_local_enable(project_root, tmp_path, monkeypatch):
    monkeypatch.setenv("VT_API_KEY", "dummy-key")
    module = importlib.import_module("scanner_helper")

    vt = module.VtLookup({"virustotal": {"enabled": False, "apiKey": ""}}, tmp_path)

    assert vt.enabled is False
    assert vt.cfg["apiKey"] == "dummy-key"

    enabled = module.VtLookup({"virustotal": {"enabled": True, "apiKey": ""}}, tmp_path)
    assert enabled.enabled is True


def test_macos_jxa_vt_does_not_write_api_key_header_file(project_root):
    helper = (project_root / "scripts" / "scanner_helper.jxa.js").read_text(encoding="utf-8")

    assert "vt_headers" not in helper
    assert "-H @" not in helper
    assert "cfg.enabled = true" not in helper


def test_powershell_vt_env_key_does_not_auto_enable(project_root):
    helper = (project_root / "scripts" / "vt-lookup.ps1").read_text(encoding="utf-8-sig")

    assert "NotePropertyName enabled -NotePropertyValue $true" not in helper
    assert "virustotal.enabled=true" in helper
    assert "ConvertFrom-Json -AsHashtable" not in helper
    assert "function ConvertTo-VtHashtable" in helper


def test_powershell_vt_cache_round_trip(project_root, tmp_path):
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("PowerShell cache round-trip requires powershell.exe or pwsh")

    config_path = tmp_path / "config.json"
    config_path.write_text(
        json.dumps(
            {
                "virustotal": {
                    "apiKey": "test-only-key",
                    "enabled": True,
                    "cacheHours": 48,
                    "maxCallsPerScan": 100,
                }
            }
        ),
        encoding="utf-8",
    )
    sample_path = tmp_path / "sample.bin"
    sample_path.write_bytes(b"VirusTotal cache round-trip\n")
    cache_dir = tmp_path / "cache"
    harness_path = tmp_path / "vt-cache-round-trip.ps1"
    harness_path.write_text(
        r"""
param(
    [Parameter(Mandatory = $true)][string]$VtScript,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$CacheDir,
    [Parameter(Mandatory = $true)][string]$SamplePath
)

$ErrorActionPreference = 'Stop'
. $VtScript

$mixedItems = $null, [PSCustomObject]@{ value = 'ok' }
$mixed = ConvertTo-VtHashtable -InputObject @{
    nested = [PSCustomObject]@{ items = $mixedItems }
}
if (-not ($mixed -is [hashtable]) -or
    -not ($mixed['nested'] -is [hashtable]) -or
    -not ($mixed['nested']['items'] -is [System.Array]) -or
    $mixed['nested']['items'].Count -ne 2 -or
    $null -ne $mixed['nested']['items'][0] -or
    -not ($mixed['nested']['items'][1] -is [hashtable])) {
    throw 'Recursive cache conversion did not preserve dictionaries, arrays, and nulls'
}

Initialize-VtLookup -ConfigPath $ConfigPath -CacheDir $CacheDir
$hash = (Get-FileHash -Path $SamplePath -Algorithm SHA256).Hash.ToLowerInvariant()
$cacheKey = "file:$hash"
$expected = @{
    status = 'ok'
    hash = $hash
    metadata = @{
        label = '캐시 호환성'
        tags = @('cached', 'local')
    }
    evidence = @(
        @{ name = 'engine-a'; verdict = 'clean' }
        @{ name = 'engine-b'; verdict = 'suspicious' }
    )
}
Set-CachedVt -Key $cacheKey -Result $expected
Save-VtCache

$cachePath = Join-Path $CacheDir 'vt-cache.json'
$cacheBytes = [System.IO.File]::ReadAllBytes($cachePath)
if ($cacheBytes.Length -lt 3 -or
    $cacheBytes[0] -ne 0xEF -or
    $cacheBytes[1] -ne 0xBB -or
    $cacheBytes[2] -ne 0xBF) {
    throw 'VirusTotal cache is not UTF-8 with BOM'
}

$script:VtCache = $null
Initialize-VtLookup -ConfigPath $ConfigPath -CacheDir $CacheDir
if (-not ($script:VtCache -is [hashtable])) {
    throw 'Loaded cache root is not a hashtable'
}
if (-not $script:VtCache.ContainsKey($cacheKey)) {
    throw 'Saved cache entry was not loaded'
}
$entry = $script:VtCache[$cacheKey]
if (-not ($entry -is [hashtable]) -or -not $entry.ContainsKey('result')) {
    throw 'Loaded cache entry is not hashtable-compatible'
}
if (-not ($entry['result']['metadata'] -is [hashtable])) {
    throw 'Nested result data is not a hashtable'
}

$script:NetworkRequests = 0
function Invoke-VtRequest {
    param([string]$Url)
    $script:NetworkRequests += 1
    throw "Unexpected network request: $Url"
}

$result = Get-VtFileReputation -FilePath $SamplePath
if ($script:NetworkRequests -ne 0) {
    throw 'Cached result triggered a network request'
}
if (-not ($result -is [hashtable]) -or $result['status'] -ne 'ok') {
    throw 'Cached result was not served'
}
if ($result['metadata']['label'] -ne '캐시 호환성' -or
    $result['metadata']['tags'][1] -ne 'local') {
    throw 'UTF-8 nested cache data did not round-trip'
}
$evidence = $result['evidence']
if (-not ($evidence -is [System.Array]) -or $evidence.Count -ne 2) {
    throw 'Nested cache array did not round-trip'
}
if (-not ($evidence[0] -is [hashtable]) -or
    -not $evidence[0].ContainsKey('verdict') -or
    $evidence[0]['verdict'] -ne 'clean') {
    throw 'Nested cache dictionaries are not hashtable-compatible'
}

Write-Output 'VT_CACHE_ROUND_TRIP_OK'
""".lstrip(),
        encoding="utf-8-sig",
    )

    result = subprocess.run(
        [
            powershell,
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(harness_path),
            "-VtScript",
            str(project_root / "scripts" / "vt-lookup.ps1"),
            "-ConfigPath",
            str(config_path),
            "-CacheDir",
            str(cache_dir),
            "-SamplePath",
            str(sample_path),
        ],
        capture_output=True,
        timeout=30,
    )
    stdout = result.stdout.decode("utf-8", errors="replace")
    stderr = result.stderr.decode("utf-8", errors="replace")

    assert result.returncode == 0, f"stdout:\n{stdout}\nstderr:\n{stderr}"
    assert "VT_CACHE_ROUND_TRIP_OK" in stdout


def test_virustotal_automatic_lookups_send_file_hashes_only(project_root):
    sources = [
        project_root / "scripts/scanner_helper.py",
        project_root / "scripts/scanner_helper.jxa.js",
        project_root / "scripts/vt-lookup.ps1",
        project_root / "scripts/modules/network.ps1",
    ]
    combined = "\n".join(path.read_text(encoding="utf-8-sig") for path in sources)

    assert "api/v3/files/" in combined
    assert "ip_addresses/" not in combined
    assert "Get-VtIpReputation" not in combined


def test_cleanup_ui_never_exposes_raw_process_commands(project_root):
    shell = (project_root / "scripts/cleanup.sh").read_text(encoding="utf-8")
    presentation = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Support/CleanupPresentation.swift"
    ).read_text(encoding="utf-8")
    sheet = (
        project_root
        / "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/CleanupApprovalSheet.swift"
    ).read_text(encoding="utf-8")

    assert "display_process_names" in shell
    assert "rawCommand" not in presentation
    assert "rawCommand" not in sheet


def test_release_report_generators_have_investigation_links(project_root):
    jxa = (project_root / "scripts" / "report.jxa.js").read_text(encoding="utf-8")
    ps1 = (project_root / "scripts" / "report.ps1").read_text(encoding="utf-8-sig")

    for source in (jxa, ps1):
        assert "https://www.google.com/search" in source
        assert "https://www.virustotal.com/gui/ip-address" in source
        assert "https://www.virustotal.com/gui/file" in source
