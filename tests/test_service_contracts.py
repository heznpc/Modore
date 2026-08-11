"""Service-loop contracts that unit tests alone used to miss."""

import importlib
import importlib.util
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


def test_every_ps1_script_carries_a_utf8_bom(project_root):
    """Windows PowerShell 5.1 (the runtime this ships to end users, not pwsh
    7+) reads a BOM-less .ps1 file using the system code page, not UTF-8 --
    every Korean string literal comes out as mojibake and the parser fails
    outright. Every existing scripts/*.ps1 file already carries a BOM; a new
    file created without one parses fine locally on pwsh 7 (which defaults to
    UTF-8 either way) and fails only on the real windows-latest CI runner,
    which is exactly what happened here. This is the guard that would have
    caught it before a push instead of after."""
    ps1_files = sorted(project_root.glob("scripts/*.ps1")) + sorted(project_root.glob("scripts/modules/*.ps1"))
    assert len(ps1_files) > 5, "sanity check: the glob found suspiciously few .ps1 files"
    missing_bom = [
        str(p.relative_to(project_root)) for p in ps1_files
        if p.read_bytes()[:3] != b"\xef\xbb\xbf"
    ]
    assert not missing_bom, f"missing UTF-8 BOM (breaks Windows PowerShell 5.1 parsing of non-ASCII literals): {missing_bom}"


def _jxa_regrade(project_root, raw_path, out_path, rules_dir, whitelist_path):
    result = subprocess.run(
        ["/usr/bin/osascript", "-l", "JavaScript", str(project_root / "scripts" / "scanner_helper.jxa.js")],
        capture_output=True, text=True, encoding="utf-8", cwd=str(project_root),
        env={
            "PATH": "/usr/bin:/bin",
            "PCH_RULE_ENGINE_ONLY": "1",
            "PCH_RAW_PATH": str(raw_path),
            "PCH_OUTPUT": str(out_path),
            "PCH_RULES_DIR": str(rules_dir),
            "PCH_WHITELIST_PATH": str(whitelist_path),
        },
    )
    assert result.returncode == 0, f"JXA engine-only failed: {result.stderr or result.stdout}"
    return json.loads(out_path.read_text(encoding="utf-8"))


_MACOS_RAW_FIXTURE = {
    "schemaVersion": "1.0", "scannedAt": "2026-08-11 12:00:00", "computerName": "TEST",
    "userName": "tester", "osVersion": "macOS Test", "platform": "macos", "scannerVersion": "0.3",
    "findings": [],
    "sections": {
        "cpu": [], "network": [], "autoruns": [], "recentInstalls": [],
        "defender": {"gatekeeper": "assessments enabled", "sip": "enabled"},
    },
}


@pytest.mark.skipif(platform.system() != "Darwin", reason="JXA runtime requires macOS osascript")
def test_jxa_corrupted_rule_file_reports_incomplete_not_safe(project_root, tmp_path):
    """readJson's silent []/{} fallback used to make a corrupted rules/*.json
    or whitelist.json classify as if that category had simply found nothing
    -- indistinguishable from a genuinely clean scan. A required source
    failing to load must gate overall the same way a failed bash collector
    already does, and a real finding elsewhere must still outrank it."""
    raw_path = tmp_path / "raw.json"
    raw_path.write_text(json.dumps(_MACOS_RAW_FIXTURE), encoding="utf-8")

    # Corrupted defender.json specifically -> incomplete, not vacuously safe.
    broken_rules = tmp_path / "rules_broken"
    broken_rules.mkdir()
    for f in (project_root / "rules").glob("*.json"):
        shutil.copy(f, broken_rules / f.name)
    (broken_rules / "defender.json").write_text("{ not valid json", encoding="utf-8")
    out_path = tmp_path / "out_broken.json"
    scan = _jxa_regrade(project_root, raw_path, out_path, broken_rules, project_root / "data" / "whitelist.json")
    assert scan["summary"]["overall"] == "incomplete"
    assert scan["summary"]["collectionComplete"] is False
    issues = scan["collection"]["issues"]
    assert any(i["id"] == "rule_defender" and i["status"] == "failed" for i in issues)

    # Corrupted whitelist.json -> same gating, different source id.
    broken_whitelist = tmp_path / "whitelist_broken.json"
    broken_whitelist.write_text("not json", encoding="utf-8")
    out_wl_path = tmp_path / "out_wl_broken.json"
    wl_scan = _jxa_regrade(project_root, raw_path, out_wl_path, project_root / "rules", broken_whitelist)
    assert wl_scan["summary"]["overall"] == "incomplete"
    assert any(i["id"] == "whitelist" and i["status"] == "failed" for i in wl_scan["collection"]["issues"])

    # A genuine danger elsewhere must still fire and outrank incomplete --
    # this layer must never mask a real finding behind a load failure.
    danger_raw = dict(_MACOS_RAW_FIXTURE)
    danger_raw["sections"] = dict(_MACOS_RAW_FIXTURE["sections"])
    danger_raw["sections"]["defender"] = {"gatekeeper": "assessments disabled", "sip": "enabled"}
    danger_raw_path = tmp_path / "raw_danger.json"
    danger_raw_path.write_text(json.dumps(danger_raw), encoding="utf-8")
    broken_rules_2 = tmp_path / "rules_broken_2"
    broken_rules_2.mkdir()
    for f in (project_root / "rules").glob("*.json"):
        shutil.copy(f, broken_rules_2 / f.name)
    (broken_rules_2 / "installs.json").write_text("not json at all", encoding="utf-8")
    out_danger_path = tmp_path / "out_danger.json"
    danger_scan = _jxa_regrade(project_root, danger_raw_path, out_danger_path, broken_rules_2, project_root / "data" / "whitelist.json")
    assert danger_scan["summary"]["overall"] == "danger"
    assert danger_scan["summary"]["dangerCount"] > 0
    assert any(i["id"] == "rule_installs" for i in danger_scan["collection"]["issues"])

    # Regression check: an all-clean run is unaffected.
    good_out_path = tmp_path / "out_good.json"
    good_scan = _jxa_regrade(project_root, raw_path, good_out_path, project_root / "rules", project_root / "data" / "whitelist.json")
    assert good_scan["summary"]["overall"] == "safe"
    assert good_scan["summary"]["collectionComplete"] is True


@pytest.mark.skipif(platform.system() != "Darwin", reason="codesign requires macOS")
def test_macos_autorun_signature_verification_actually_runs(project_root, tmp_path):
    """scanner_helper.jxa.js hardcoded verified:false/signer:"" for every
    autorun entry -- a Python->JXA port regression, not a disclosed
    limitation -- since real codesign verification was never re-implemented.
    Exercises the actual, full (non-regrade) collection path against a real
    system LaunchDaemon plist and a genuinely unsigned test binary."""
    daemon_plist = Path("/System/Library/LaunchDaemons/com.apple.ContainerMigrationService.plist")
    if not daemon_plist.exists():
        pytest.skip("expected system LaunchDaemon plist not present on this machine")

    unsigned_bin = tmp_path / "unsigned_test_bin"
    shutil.copy("/bin/echo", unsigned_bin)
    subprocess.run(["/usr/bin/codesign", "--remove-signature", str(unsigned_bin)], check=True, capture_output=True)
    unsigned_plist = tmp_path / "com.pch.test.unsigned.plist"
    unsigned_plist.write_text(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\"><dict><key>Label</key><string>com.pch.test.unsigned</string>"
        f"<key>Program</key><string>{unsigned_bin}</string></dict></plist>\n",
        encoding="utf-8",
    )

    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "plists.txt").write_text(f"{daemon_plist}\n{unsigned_plist}\n", encoding="utf-8")
    for name in ("ps.txt", "net.txt", "listen.txt", "security.txt", "load.txt",
                 "storage_simulators.tsv", "collection_status.tsv"):
        (facts / name).write_text("", encoding="utf-8")

    output = tmp_path / "scan.json"
    raw = tmp_path / "raw.json"
    env = os.environ.copy()
    env.update({
        "TMP_DIR": str(facts),
        "PCH_OUTPUT": str(output),
        "PCH_RAW_PATH": str(raw),
        "PCH_RULES_DIR": str(project_root / "rules"),
        "PCH_CONFIG_PATH": str(tmp_path / "config.json"),
        "PCH_WHITELIST_PATH": str(project_root / "data" / "whitelist.json"),
        "PCH_SIMULATOR_KEEP_PATH": str(tmp_path / "simulator-keep.txt"),
        "PCH_NO_VT": "true",
    })
    result = subprocess.run(
        ["/usr/bin/osascript", "-l", "JavaScript", str(project_root / "scripts" / "scanner_helper.jxa.js")],
        capture_output=True, text=True, encoding="utf-8", env=env, timeout=30,
    )
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    scan = json.loads(output.read_text(encoding="utf-8"))

    by_entry = {row["entry"]: row for row in scan["sections"]["autoruns"]}
    signed = by_entry["com.apple.ContainerMigrationService"]
    assert signed["verified"] is True
    assert "Apple" in signed["signer"] or "Software Signing" in signed["signer"]
    unsigned = by_entry["com.pch.test.unsigned"]
    assert unsigned["verified"] is False
    assert unsigned["signer"] == ""


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
    assert "run-mac-app.command" in module.MACOS_FILES
    assert "macos/Modore/Package.swift" in module.MACOS_FILES
    swift_root = project_root / "macos" / "Modore"
    swift_files = {
        path.relative_to(project_root).as_posix()
        for path in swift_root.rglob("*.swift")
        if ".build" not in path.parts
    }
    assert swift_files.issubset(set(module.MACOS_FILES))


def test_macos_launcher_is_executable(project_root):
    mode = (project_root / "scan.command").stat().st_mode
    assert mode & 0o111


def test_macos_swift_launcher_is_executable(project_root):
    for rel in (
        "run-mac-app.command",
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
        / "macos/Modore/Sources/Modore/Services/ScanModel.swift"
    ).read_text(encoding="utf-8")
    finish_run = source.split("func finishRun", 1)[1].split(
        "private func refreshExistingResults", 1
    )[0]

    assert "showNormalReport()" not in finish_run


def test_macos_high_frequency_log_state_is_isolated(project_root):
    source = (
        project_root
        / "macos/Modore/Sources/Modore/Services/ScanModel.swift"
    ).read_text(encoding="utf-8")
    watch_service = (
        project_root
        / "macos/Modore/Sources/Modore/Services/StorageWatchService.swift"
    ).read_text(encoding="utf-8")
    overview = (
        project_root
        / "macos/Modore/Sources/Modore/Views/StorageOverviewView.swift"
    ).read_text(encoding="utf-8")

    assert "@Published var logText" not in source
    assert "let logStore = ScanLogStore()" in source
    assert "@Published private(set) var content = ScanContent.empty" in source
    assert "LocalProcessRunner.capture" in watch_service
    assert "struct StorageOverviewPage: View" not in overview


def test_macos_ui_reserves_chromatic_status_colors_for_critical_states(project_root):
    source_root = (
        project_root
        / "macos/Modore/Sources/Modore"
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
        / "macos/Modore/Sources/Modore/Services/ScanPipeline.swift"
    ).read_text(encoding="utf-8")
    runner = (
        project_root
        / "macos/Modore/Sources/Modore/Services/LocalProcessRunner.swift"
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
        / "macos/Modore/Sources/Modore/Models/StorageChangeSummary.swift"
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


def _write_raw_facts(path, collection, defender_facts=None, cpu_facts=None):
    raw = {
        "schemaVersion": "1.0",
        "scannedAt": "2026-08-11 12:00:00",
        "computerName": "TEST-PC",
        "userName": "tester",
        "osVersion": "Windows Test",
        "platform": "windows",
        "scannerVersion": "0.3",
        "findings": [],
        "sections": {
            "cpu": cpu_facts if cpu_facts is not None else [],
            "network": [],
            "listeningPorts": [],
            "autoruns": [],
            "scheduledTasks": [],
            "recentInstalls": [],
            "defender": defender_facts if defender_facts is not None else {},
        },
        "collection": collection,
    }
    path.write_text(json.dumps(raw), encoding="utf-8")


def _run_rule_engine(powershell, project_root, raw_path, out_path, debug=False):
    env = dict(os.environ)
    if debug:
        env["PCH_RULE_ENGINE_DEBUG"] = "1"
    result = subprocess.run(
        [
            powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(project_root / "scripts" / "rule_engine.ps1"),
            "-Raw", str(raw_path),
            "-Rules", str(project_root / "rules"),
            "-Whitelist", str(project_root / "data" / "whitelist.json"),
            "-Output", str(out_path),
        ],
        capture_output=True,
        timeout=30,
        env=env,
    )
    stdout = result.stdout.decode("utf-8", errors="replace")
    stderr = result.stderr.decode("utf-8", errors="replace")
    if debug:
        print("RULE_ENGINE_DEBUG stdout:\n" + stdout)
    assert result.returncode == 0, f"stdout:\n{stdout}\nstderr:\n{stderr}"
    return json.loads(out_path.read_text(encoding="utf-8-sig"))


_OK_COLLECTION = [
    {"id": "defender", "label": "Windows Defender 상태", "status": "ok", "required": True, "detail": ""},
    {"id": "network_established", "label": "외부 네트워크 연결", "status": "ok", "required": True, "detail": ""},
    {"id": "network_listening", "label": "열린 포트", "status": "ok", "required": True, "detail": ""},
    {"id": "startup_registry", "label": "자동 실행 레지스트리", "status": "ok", "required": True, "detail": ""},
    {"id": "scheduled_tasks", "label": "예약 작업", "status": "ok", "required": True, "detail": ""},
]


def test_powershell_collection_status_gates_overall_on_required_failures(project_root, tmp_path):
    """A required collector failing (e.g. Get-MpComputerStatus erroring) must
    never be indistinguishable from 'nothing to report' -- overall must drop
    to 'incomplete', not 'safe', even with zero findings."""
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("requires powershell.exe or pwsh")

    failed_collection = [dict(item) for item in _OK_COLLECTION]
    failed_collection[0] = {
        "id": "defender", "label": "Windows Defender 상태",
        "status": "unavailable", "required": True, "detail": "Get-MpComputerStatus 실패",
    }
    raw_path = tmp_path / "raw_incomplete.json"
    out_path = tmp_path / "scan_incomplete.json"
    _write_raw_facts(raw_path, failed_collection)
    scan = _run_rule_engine(powershell, project_root, raw_path, out_path)

    assert scan["summary"]["overall"] == "incomplete"
    assert scan["summary"]["collectionComplete"] is False
    assert scan["summary"]["dangerCount"] == 0
    assert scan["collection"]["complete"] is False
    assert "Windows Defender" in scan["summary"]["message"]

    # All-ok regression check: unrelated to the failure path, must stay 'safe'.
    ok_raw_path = tmp_path / "raw_ok.json"
    ok_out_path = tmp_path / "scan_ok.json"
    _write_raw_facts(
        ok_raw_path, _OK_COLLECTION,
        defender_facts={"realtimeEnabled": True, "antivirusEnabled": True, "signatureDaysOld": 1},
    )
    ok_scan = _run_rule_engine(powershell, project_root, ok_raw_path, ok_out_path)
    assert ok_scan["summary"]["overall"] == "safe"
    assert ok_scan["summary"]["collectionComplete"] is True

    # A real danger (collection succeeded, Defender genuinely reports off)
    # must still fire -- this layer must never mask an actual finding.
    danger_raw_path = tmp_path / "raw_danger.json"
    danger_out_path = tmp_path / "scan_danger.json"
    _write_raw_facts(
        danger_raw_path, _OK_COLLECTION,
        defender_facts={"realtimeEnabled": False, "antivirusEnabled": False, "signatureDaysOld": 40},
        # A single-condition, unambiguous process rule (rules/process.json's
        # miner_xmrig, "name.iregex": "^xmrig.*$") as a cross-check: this
        # facts array goes through the *array* iteration branch in
        # rule_engine.ps1, structurally different from defender's single-
        # object branch. If this ALSO fails to match on PS5.1, the bug is in
        # rule loading/matching generally, not something specific to how the
        # defender section is handled.
        cpu_facts=[{"name": "xmrig", "pid_": 1234, "cpu": 10, "memoryMB": 100, "path": "C:\\x\\xmrig.exe"}],
    )
    danger_scan = _run_rule_engine(powershell, project_root, danger_raw_path, danger_out_path, debug=True)
    if danger_scan["summary"]["overall"] != "danger":
        # Diagnostic for a platform-specific mismatch (this exact branch is
        # what surfaced the failure on real Windows PowerShell 5.1 CI while
        # passing locally on pwsh 7) -- dump the state pytest's default
        # assertion introspection wouldn't show, so the *next* CI log (if
        # this still fails) carries enough to root-cause it without another
        # blind round trip.
        print("DIAG summary:", json.dumps(danger_scan["summary"], ensure_ascii=False))
        print("DIAG defender section:", json.dumps(danger_scan["sections"].get("defender"), ensure_ascii=False))
        print("DIAG cpu section:", json.dumps(danger_scan["sections"].get("cpu"), ensure_ascii=False))
        print("DIAG findings:", json.dumps(danger_scan["findings"], ensure_ascii=False))
        print("DIAG collection:", json.dumps(danger_scan["collection"], ensure_ascii=False))
    assert danger_scan["summary"]["overall"] == "danger"
    assert danger_scan["summary"]["dangerCount"] > 0

    # Missing collection field entirely (older raw_facts, or a regression that
    # stops writing it) must fail closed, not vacuously report complete.
    no_collection_raw = tmp_path / "raw_no_collection.json"
    no_collection_out = tmp_path / "scan_no_collection.json"
    raw = json.loads(raw_path.read_text(encoding="utf-8"))
    del raw["collection"]
    no_collection_raw.write_text(json.dumps(raw), encoding="utf-8")
    no_collection_scan = _run_rule_engine(powershell, project_root, no_collection_raw, no_collection_out)
    assert no_collection_scan["summary"]["overall"] == "incomplete"
    assert no_collection_scan["collection"]["sources"][0]["id"] == "collector_protocol"


def test_powershell_report_html_generation_actually_runs(project_root, tmp_path):
    """report.ps1's HtmlEncode/UrlEncode helpers must not collide with a
    built-in PowerShell alias (h -> Get-History ships by default) -- a
    same-named function silently loses to the alias at every bare call site,
    so report generation crashed on line 1 of real usage while a bare
    syntax-only check (what CI ran) stayed green forever."""
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("requires powershell.exe or pwsh")

    raw_path = tmp_path / "raw.json"
    scan_path = tmp_path / "scan.json"
    report_path = tmp_path / "report.html"
    _write_raw_facts(raw_path, _OK_COLLECTION)
    _run_rule_engine(powershell, project_root, raw_path, scan_path)

    result = subprocess.run(
        [
            powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(project_root / "scripts" / "report.ps1"),
            "-Scan", str(scan_path),
            "-Output", str(report_path),
        ],
        capture_output=True,
        timeout=30,
    )
    stdout = result.stdout.decode("utf-8", errors="replace")
    stderr = result.stderr.decode("utf-8", errors="replace")
    assert result.returncode == 0, f"stdout:\n{stdout}\nstderr:\n{stderr}"

    html = report_path.read_text(encoding="utf-8")
    assert len(html) > 500, "report.ps1 produced suspiciously little output"
    assert "<html" in html and "</html>" in html
    assert "TEST-PC" in html  # HtmlEncode actually ran, not a silent no-op


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
        / "macos/Modore/Sources/Modore/Support/CleanupPresentation.swift"
    ).read_text(encoding="utf-8")
    sheet = (
        project_root
        / "macos/Modore/Sources/Modore/Views/CleanupApprovalSheet.swift"
    ).read_text(encoding="utf-8")

    assert "display_process_names" in shell
    assert "display_process_evidence" in shell
    assert "/bin/ps -axo pid=,command=" in shell
    assert "rawCommand" not in presentation
    assert "rawCommand" not in sheet


def test_release_report_generators_have_investigation_links(project_root):
    jxa = (project_root / "scripts" / "report.jxa.js").read_text(encoding="utf-8")
    ps1 = (project_root / "scripts" / "report.ps1").read_text(encoding="utf-8-sig")

    for source in (jxa, ps1):
        assert "https://www.google.com/search" in source
        assert "https://www.virustotal.com/gui/ip-address" in source
        assert "https://www.virustotal.com/gui/file" in source
        assert "noopener noreferrer" in source
        assert "aria-label" in source
