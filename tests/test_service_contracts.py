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
def _menu_functions_source(project_root) -> str:
    """menu.ps1's function definitions, without its interactive main loop
    (an infinite Read-Host while-loop that would hang any automated run)."""
    text = (project_root / "scripts" / "menu.ps1").read_text(encoding="utf-8-sig")
    marker = "# ---------- 메인 루프 ----------"
    assert marker in text, "menu.ps1's main-loop marker moved; update this test's extraction point"
    return text.split(marker)[0]


def _run_invoke_scanner_scenario(project_root, tmp_path, scanner_body: str, pre_existing_result: str | None):
    """Lays out a scenarioRoot/scripts/{menu functions, scanner.ps1} tree
    mirroring the real scripts/ layout (Invoke-Scanner's $root is
    Split-Path -Parent $PSScriptRoot, exactly like the real menu.ps1 --
    a flat layout silently points $root at the wrong directory)."""
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("requires powershell.exe or pwsh")

    scripts_dir = tmp_path / "scripts"
    scripts_dir.mkdir(parents=True)
    if pre_existing_result is not None:
        (tmp_path / "scan_result.json").write_text(pre_existing_result, encoding="utf-8")
    # utf-8-sig, not utf-8: Windows PowerShell 5.1 reads a BOM-less .ps1 in
    # the system code page, so the Korean text extracted from menu.ps1 turns
    # to mojibake mid-string-literal and the whole harness fails to PARSE on
    # the real windows-latest runner while passing locally on pwsh 7 (which
    # defaults to UTF-8 either way). Exactly the 1a lesson, reproduced in
    # this test's own generated fixtures -- the repo-wide BOM guard only
    # covers scripts/*.ps1, not files a test writes at runtime.
    (scripts_dir / "scanner.ps1").write_text(scanner_body, encoding="utf-8-sig")
    harness = (
        'function chcp { param([Parameter(ValueFromRemainingArguments=$true)]$rest) }  # non-Windows test stub\n'
        + _menu_functions_source(project_root)
        # Invoke-Scanner's own $() capture would otherwise interleave the
        # fake scanner's Write-Output noise into the same line as the
        # boolean result; capture it as a real variable instead.
        + '\n$outputPath = Join-Path $root "scan_result.json"\n'
        '$scannerResult = Invoke-Scanner\n'
        'Write-Output "RESULT=$scannerResult"\n'
        'if (Test-Path $outputPath) { Write-Output "CONTENT=$(Get-Content $outputPath -Raw)" }\n'
    )
    (scripts_dir / "harness.ps1").write_text(harness, encoding="utf-8-sig")

    result = subprocess.run(
        [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
         "-File", str(scripts_dir / "harness.ps1")],
        capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    return result


def test_powershell_menu_scanner_gate_survives_a_stale_exit_code(project_root, tmp_path):
    """$LASTEXITCODE only reflects native executable calls, not a called
    .ps1's own success -- a scanner.ps1 that bails out early right after any
    native call (which sets $LASTEXITCODE=0) leaves that stale 0 in place,
    and the old `if ($LASTEXITCODE -ne 0)` gate read it as success, reopening
    a stale scan_result.json as if it were the result of the run that just
    "succeeded". Proves both the old pattern's bug and the new gate's fix
    against the same fixture, then checks two more shapes directly."""
    stale = '{"stale":"before"}'
    bail_early_after_native_call = (
        'hostname | Out-Null\n'  # a real native executable on macOS/Linux/Windows alike, stands in for a native call inside scanner.ps1
        'return\n'
    )

    old_pattern = _run_invoke_scanner_scenario(project_root, tmp_path / "old", bail_early_after_native_call, stale)
    # Reproduce the exact old (pre-fix) gate inline to prove it's wrong on this fixture,
    # not just assert the new one is right in isolation.
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    old_check = tmp_path / "old_check.ps1"
    old_check.write_text(
        f'& "{tmp_path / "old" / "scripts" / "scanner.ps1"}"\n'
        'Write-Output "OLD_WOULD_PROCEED=$($LASTEXITCODE -eq 0)"\n',
        encoding="utf-8-sig",
    )
    old_result = subprocess.run(
        [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(old_check)],
        capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    assert "OLD_WOULD_PROCEED=True" in old_result.stdout, (
        "sanity check that this fixture reproduces the original bug shape failed: "
        f"{old_result.stdout}\n{old_result.stderr}"
    )

    result = _run_invoke_scanner_scenario(project_root, tmp_path / "new", bail_early_after_native_call, stale)
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    assert "RESULT=False" in result.stdout, f"stale exit code must not read as success:\n{result.stdout}"
    assert f"CONTENT={stale}" in result.stdout, "the stale result must not be silently treated as fresh"

    # Regression check: a scanner that genuinely writes a fresh result still passes.
    fresh_body = (
        '$global:LASTEXITCODE = 0\n'
        '\'{"scannedAt":"fresh"}\' | Out-File -FilePath (Join-Path $PSScriptRoot "..\\scan_result.json") -Encoding utf8 -Force\n'
    )
    fresh_result = _run_invoke_scanner_scenario(project_root, tmp_path / "fresh", fresh_body, stale)
    assert "RESULT=True" in fresh_result.stdout, f"a genuine fresh write must pass:\n{fresh_result.stdout}"

    # No prior result at all, scanner does nothing -- must not fabricate success.
    # Write-Host, not Write-Output: matches the real scanner.ps1/menu.ps1
    # convention (progress text goes to the host, never the output stream)
    # -- Write-Output here would interleave into Invoke-Scanner's own
    # captured return value, same as the real function would face if a
    # future edit got this wrong.
    noop_result = _run_invoke_scanner_scenario(project_root, tmp_path / "noop", 'Write-Host "did nothing"\n', None)
    assert "RESULT=False" in noop_result.stdout, f"no output ever written must fail:\n{noop_result.stdout}"


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


@pytest.mark.skipif(platform.system() != "Darwin", reason="launchctl/kmutil/systemextensionsctl require macOS")
def test_macos_launchd_login_items_and_kexts_reach_the_scan_output(project_root, tmp_path):
    """launchctl.txt/loginitems.txt/kexts.txt/sysexts.txt were collected with
    their own collection-status tracking (record_collection_status already
    marks them "ok") but the collected data itself was discarded before
    classification -- a malicious Login Item or launchd job was invisible
    end to end despite the dashboard implying that vector was covered.
    Fixture content is captured verbatim from this machine's real
    `launchctl list` output (ephemeral per-app XPC noise like
    "application.com.foo.Bar.12345.12346" included deliberately, since
    filtering that out correctly is exactly what this test guards)."""
    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "launchctl.txt").write_text(
        "PID\tStatus\tLabel\n"
        "-\t0\tcom.apple.SafariHistoryServiceAgent\n"
        "-\t0\tus.zoom.updater\n"
        "12345\t0\tapplication.com.caldis.Mos.26820450.26820456\n"
        "-\t0\tcom.heznpc.narcissus-multirun-watchdog\n",
        encoding="utf-8",
    )
    (facts / "loginitems.txt").write_text("SaneSideButtons, Mos\n", encoding="utf-8")
    (facts / "kexts.txt").write_text(
        "    3  226 0                  0          0          com.apple.kpi.bsd (27.0.0) EC2DBF2E-ACDC-31C7-98F7-ECDFC6127685 <>\n"
        "   50    1 0                  0          0          com.example.thirdpartykext (1.0.0) 11111111-2222-3333-4444-555555555555 <>\n",
        encoding="utf-8",
    )
    (facts / "sysexts.txt").write_text("0 extension(s)\n", encoding="utf-8")
    (facts / "plists.txt").write_text("", encoding="utf-8")
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

    by_category = {}
    for row in scan["sections"]["autoruns"]:
        by_category.setdefault(row["category"], []).append(row["entry"])

    launchd = by_category.get("Launchd Job", [])
    assert "us.zoom.updater" in launchd
    assert "com.heznpc.narcissus-multirun-watchdog" in launchd
    assert "com.apple.SafariHistoryServiceAgent" not in launchd, "Apple-prefixed labels are baseline noise, not signal"
    assert not any(l.startswith("application.") for l in launchd), \
        "ephemeral per-app XPC registrations are not persistence and must not read as third-party autorun"

    assert by_category.get("Login Item") == ["SaneSideButtons", "Mos"]
    assert by_category.get("Kernel Extension") == ["com.example.thirdpartykext"], \
        "the apple kpi.bsd kext must be filtered as noise; the third-party one must surface"
    assert "System Extension" not in by_category, "0 extension(s) must not fabricate an entry"

    # None of these are silently pre-judged: they reach real classification
    # (unknown, not whitelisted) rather than a hardcoded/omitted risk field.
    for row in scan["sections"]["autoruns"]:
        if row["category"] in ("Launchd Job", "Login Item", "Kernel Extension"):
            assert row["risk"] == "unknown"
            assert row["note"] == "처음 보는 프로그램 - 확인 필요"


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

    # WINDOWS_FILES is a hand-maintained list, not a glob (unlike the Swift
    # check above) -- a new scripts/*.ps1 file works fine in every local and
    # CI test (which run it straight from the checkout) while being silently
    # absent from what actually ships in the Windows release zip, only
    # failing for a real end user the first time something tries to invoke
    # it. Catch that class of gap here instead.
    ps1_files = {
        path.relative_to(project_root).as_posix()
        for path in (project_root / "scripts").glob("*.ps1")
    } | {
        path.relative_to(project_root).as_posix()
        for path in (project_root / "scripts" / "modules").glob("*.ps1")
    }
    assert ps1_files.issubset(set(module.WINDOWS_FILES)), (
        f"missing from WINDOWS_FILES: {ps1_files - set(module.WINDOWS_FILES)}"
    )

    # Same gap, same fix, macOS side: scripts/modules/macos/*.sh is also a
    # hand-maintained list inside MACOS_BASE_FILES, not a glob. A new module
    # sourced by scanner.sh works in every local/CI run (straight from the
    # checkout) while silently missing from the real release zip -- caught
    # this exact way once already for privacy.sh before this guard existed.
    macos_module_files = {
        path.relative_to(project_root).as_posix()
        for path in (project_root / "scripts" / "modules" / "macos").glob("*.sh")
    }
    assert macos_module_files.issubset(set(module.MACOS_FILES)), (
        f"missing from MACOS_FILES: {macos_module_files - set(module.MACOS_FILES)}"
    )

    # Same gap again, one directory up: top-level scripts/*.sh (cleanup.sh,
    # storage_watch.sh, ...) are each asserted by name above rather than
    # globbed, so a new standalone script (login_items.sh being the first
    # one added after this guard existed) could go missing from MACOS_FILES
    # the same silent way. Glob catches it regardless of whether anyone
    # remembers to add a matching by-name assert.
    macos_top_level_scripts = {
        path.relative_to(project_root).as_posix()
        for path in (project_root / "scripts").glob("*.sh")
    }
    assert macos_top_level_scripts.issubset(set(module.MACOS_FILES)), (
        f"missing from MACOS_FILES: {macos_top_level_scripts - set(module.MACOS_FILES)}"
    )


@pytest.mark.parametrize(
    "script,args",
    [
        ("scripts/cleanup.sh", ["--list"]),
        ("scripts/schedule.sh", ["--status"]),
        ("scripts/login_items.sh", ["--preview", "NotARealLoginItem"]),
    ],
)
def test_pinned_fd_execution_sources_support_dir_module(project_root, tmp_path, script, args):
    """Sealed app runs execute these scripts from /dev/fd/N (LocalProcessRunner's
    pinned-file mechanism), where the sibling-relative source of
    modules/support_dir.sh resolves to the nonexistent /dev/fd/modules/... --
    and bash CONTINUES past a failed source, leaving SUPPORT_DIR_NAME unset
    and killing the script later under set -u. Every dev-mode and CI run
    invokes the scripts by real path, so nothing else can catch this: sealed
    cleanup/schedule/login-items were all silently dead from the day the
    source line landed until this contract existed. The fix (and this test's
    shape) is scanner.sh's existing pattern: the module rides its own pinned
    descriptor, announced via PCH_PINNED_SUPPORT_DIR_MODULE."""
    module_fd = os.open(str(project_root / "scripts" / "modules" / "support_dir.sh"), os.O_RDONLY)
    script_fd = os.open(str(project_root / script), os.O_RDONLY)
    try:
        env = os.environ.copy()
        env["PCH_PINNED_SUPPORT_DIR_MODULE"] = f"/dev/fd/{module_fd}"
        if script.endswith("login_items.sh"):
            stub = tmp_path / "osascript-stub"
            stub.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
            stub.chmod(0o755)
            env["PCH_TEST_MODE"] = "1"
            env["PCH_TEST_OSASCRIPT_BIN"] = str(stub)
            env["HOME"] = str(tmp_path / "home")
        result = subprocess.run(
            ["/bin/bash", f"/dev/fd/{script_fd}", *args],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=env,
            pass_fds=(module_fd, script_fd),
        )
    finally:
        os.close(module_fd)
        os.close(script_fd)

    assert "unbound variable" not in result.stderr, result.stderr
    assert "support_dir.sh: No such file or directory" not in result.stderr, result.stderr
    if script.endswith("cleanup.sh"):
        assert result.returncode == 0, result.stderr
        assert "recipe\t" in result.stdout
    if script.endswith("login_items.sh"):
        assert "status\tnot_found" in result.stdout


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


@pytest.mark.skipif(platform.system() != "Darwin", reason="uses real macOS top/sysctl/bc")
def test_macos_system_load_reports_failure_when_vm_stat_output_is_unparseable(project_root, tmp_path):
    """collect_system_load used to substitute a literal "0" for MEM_PCT when
    vm_stat's output didn't match the expected awk patterns (a future macOS
    vm_stat format change, for instance) -- a fake measurement, since a real
    running system is never actually at 0% memory used. The very next line
    checks -z "$MEM_PCT" to decide whether to report the collector as
    failed, but "0" is never empty, so that check could never catch this
    specific failure mode: it silently reported status=ok with a bogus
    number instead of status=failed. CPU_USED's own check has no such
    fallback and already worked correctly -- this is specifically about the
    MEM_PCT path.

    top/sysctl/bc stay real (unlike cleanup.sh, this file calls its tools by
    bare name rather than an absolute path, so PATH interception is safe
    here); only vm_stat is swapped for a fake that omits the lines the awk
    patterns match on, extracting the real collect_system_load function by
    line range rather than a hand-duplicated copy."""
    source_lines = (project_root / "scripts" / "modules" / "macos" / "cpu.sh").read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(source_lines) if line.startswith("collect_system_load() {"))
    end = next(i for i, line in enumerate(source_lines[start:], start) if line == "}") + 1
    collect_system_load_src = "\n".join(source_lines[start:end])
    assert collect_system_load_src.endswith("}"), "extraction boundary moved; update this test"

    def run_with_fake_vm_stat(vm_stat_output, label):
        scenario_dir = tmp_path / label
        fake_bin = scenario_dir / "bin"
        fake_bin.mkdir(parents=True)
        fake_vm_stat = fake_bin / "vm_stat"
        # A single-quoted heredoc, not printf '%s' with an embedded string --
        # this content needs real newlines (vm_stat's output is line-based
        # and the awk patterns match per line), and a double-quoted argument
        # would need its own newlines escaped as literal "\n" text, which
        # printf's %s never interprets back into an actual line break.
        fake_vm_stat.write_text(
            f"#!/bin/bash\ncat <<'PCH_TEST_VMSTAT_EOF'\n{vm_stat_output}\nPCH_TEST_VMSTAT_EOF\n",
            encoding="utf-8",
        )
        fake_vm_stat.chmod(0o700)
        tmp_dir = scenario_dir / "tmp"
        tmp_dir.mkdir()

        harness = scenario_dir / "harness.sh"
        harness.write_text(
            f"""#!/bin/bash
set -u
TMP_DIR="{tmp_dir}"
record_collection_status() {{
    printf 'status\\t%s\\n' "$3" > "{scenario_dir}/captured-status.txt"
    printf 'detail\\t%s\\n' "$5" >> "{scenario_dir}/captured-status.txt"
}}

{collect_system_load_src}

collect_system_load
""",
            encoding="utf-8",
        )
        harness.chmod(0o700)
        env = dict(os.environ)
        env["PATH"] = f"{fake_bin}:{env['PATH']}"
        result = subprocess.run(["/bin/bash", str(harness)], capture_output=True, text=True, encoding="utf-8", env=env, timeout=15)
        assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        captured = (scenario_dir / "captured-status.txt").read_text(encoding="utf-8")
        load = (tmp_dir / "load.txt").read_text(encoding="utf-8")
        return captured, load

    # Real vm_stat output shape: parsing must succeed and report ok.
    real_shaped = (
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
        "Pages free:                                     5122.\n"
        "Pages active:                                 154318.\n"
        "Pages wired down:                             266462.\n"
    )
    ok_captured, ok_load = run_with_fake_vm_stat(real_shaped, "well-formed")
    assert "status\tok" in ok_captured, ok_captured
    assert "MEM_PCT=" in ok_load and "MEM_PCT=\n" not in ok_load, f"expected a real computed value, got:\n{ok_load}"

    # A vm_stat whose output no longer matches the expected lines at all
    # (simulating a format change) must be reported as a failed collector,
    # not silently as ok with a fake 0%.
    unparseable = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nsomething unexpected\n"
    failed_captured, failed_load = run_with_fake_vm_stat(unparseable, "unparseable")
    assert "status\tfailed" in failed_captured, failed_captured
    assert "MEM_PCT=\n" in failed_load, f"expected MEM_PCT left empty (not a fake 0), got:\n{failed_load}"


@pytest.mark.skipif(platform.system() != "Darwin", reason="drives real macOS security tooling")
def test_macos_security_baseline_does_not_mistake_stderr_for_a_real_status(project_root, tmp_path):
    """gatekeeper/sip used to be captured with `2>&1`, merging spctl/csrutil's
    stderr into the same variable as their real stdout status. An error
    message is still non-empty text, so it would slip past the `-z` check
    that's supposed to catch a failed read -- reporting baseline_status=ok
    with the error text standing in for the real Gatekeeper/SIP state,
    instead of correctly failing the collector. Unlike vm_stat's "0" fallback
    (a wrong number), this is a wrong *security verdict source*: exactly the
    kind of thing this whole reliability pass exists to catch.

    spctl/csrutil are called by hardcoded absolute path (/usr/sbin/spctl,
    /usr/bin/csrutil) in the real script -- unlike a bare command name, that
    can't be shadowed via $PATH. The real function source is extracted
    verbatim and only those two absolute paths are substituted for
    test-controlled fake executables; every other line (the actual thing
    under test: whether stderr leaks into the data variable, whether -z
    correctly fires) runs unmodified."""
    real_spctl = "/usr/sbin/spctl"
    real_csrutil = "/usr/bin/csrutil"
    source_lines = (project_root / "scripts" / "modules" / "macos" / "security.sh").read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(source_lines) if line.startswith("collect_security() {"))
    end = next(i for i, line in enumerate(source_lines[start:], start) if line == "}") + 1
    collect_security_src = "\n".join(source_lines[start:end])
    assert collect_security_src.endswith("}"), "extraction boundary moved; update this test"
    assert real_spctl in collect_security_src and real_csrutil in collect_security_src, (
        "extraction no longer references the expected absolute paths; update this test"
    )

    def run_scenario(spctl_body, csrutil_body, label):
        scenario_dir = tmp_path / label
        fake_bin = scenario_dir / "bin"
        fake_bin.mkdir(parents=True)
        fake_spctl = fake_bin / "spctl"
        fake_spctl.write_text(f"#!/bin/bash\n{spctl_body}\n", encoding="utf-8")
        fake_spctl.chmod(0o700)
        fake_csrutil = fake_bin / "csrutil"
        fake_csrutil.write_text(f"#!/bin/bash\n{csrutil_body}\n", encoding="utf-8")
        fake_csrutil.chmod(0o700)
        tmp_dir = scenario_dir / "tmp"
        tmp_dir.mkdir()

        scenario_src = collect_security_src.replace(real_spctl, str(fake_spctl)).replace(real_csrutil, str(fake_csrutil))
        harness = scenario_dir / "harness.sh"
        harness.write_text(
            f"""#!/bin/bash
set -u
TMP_DIR="{tmp_dir}"
record_collection_status() {{
    printf '%s\\t%s\\t%s\\n' "$1" "$3" "$5" >> "{scenario_dir}/captured-status.txt"
}}

{scenario_src}

collect_security
""",
            encoding="utf-8",
        )
        harness.chmod(0o700)
        result = subprocess.run(["/bin/bash", str(harness)], capture_output=True, text=True, encoding="utf-8", timeout=15)
        assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        captured = (scenario_dir / "captured-status.txt").read_text(encoding="utf-8")
        security_txt = (tmp_dir / "security.txt").read_text(encoding="utf-8")
        return captured, security_txt

    # Happy path: both tools succeed cleanly on stdout, nothing on stderr.
    ok_captured, ok_security = run_scenario(
        "echo 'assessments enabled'",
        "echo 'System Integrity Protection status: enabled.'",
        "healthy",
    )
    assert "security_baseline\tok" in ok_captured, ok_captured
    assert "GATEKEEPER=assessments enabled" in ok_security

    # spctl fails and writes only to stderr, stdout is empty -- must be
    # reported as a failed collector, not "ok" with the stderr text baked
    # into GATEKEEPER as if it were the real assessment state.
    failed_captured, failed_security = run_scenario(
        "printf 'spctl: unexpected internal error\\n' >&2; exit 1",
        "echo 'System Integrity Protection status: enabled.'",
        "spctl-stderr-only",
    )
    assert "security_baseline\tfailed" in failed_captured, failed_captured
    assert "GATEKEEPER=\n" in failed_security, f"stderr text must not appear in GATEKEEPER, got:\n{failed_security}"
    assert "unexpected internal error" not in failed_security


@pytest.mark.skipif(platform.system() != "Darwin", reason="uses real macOS sqlite3")
def test_macos_privacy_permissions_reports_only_allowed_camera_and_microphone_grants(project_root, tmp_path):
    """collect_privacy_permissions reads TCC.db's real access table -- this
    builds a genuine SQLite fixture with that exact schema (not a hand-typed
    TSV stand-in) and runs the real extracted function against it via the
    real sqlite3 binary. Must include only auth_value=2 (allowed) rows for
    camera/microphone specifically: a denied camera grant, an allowed grant
    for an unrelated service (Contacts), and a denied microphone grant must
    all be excluded -- proving the SQL filter, not just the shell plumbing
    around it, is exercised for real."""
    import sqlite3

    source_lines = (project_root / "scripts" / "modules" / "macos" / "privacy.sh").read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(source_lines) if line.startswith("collect_privacy_permissions() {"))
    end = next(i for i, line in enumerate(source_lines[start:], start) if line == "}") + 1
    collect_privacy_permissions_src = "\n".join(source_lines[start:end])
    assert collect_privacy_permissions_src.endswith("}"), "extraction boundary moved; update this test"

    def build_tcc_fixture(path, rows):
        connection = sqlite3.connect(str(path))
        connection.execute(
            "CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, "
            "auth_value INTEGER, auth_reason INTEGER, auth_version INTEGER)"
        )
        connection.executemany(
            "INSERT INTO access VALUES (?, ?, 0, ?, 0, 1)", rows
        )
        connection.commit()
        connection.close()

    def run_scenario(tcc_db_path, label):
        scenario_dir = tmp_path / label
        tmp_dir = scenario_dir / "tmp"
        tmp_dir.mkdir(parents=True)
        harness = scenario_dir / "harness.sh"
        harness.write_text(
            f"""#!/bin/bash
set -u
TMP_DIR="{tmp_dir}"
PCH_TCC_DB_PATH="{tcc_db_path}"
record_collection_status() {{
    printf 'status\\t%s\\n' "$3" > "{scenario_dir}/captured-status.txt"
    printf 'detail\\t%s\\n' "$5" >> "{scenario_dir}/captured-status.txt"
}}

{collect_privacy_permissions_src}

collect_privacy_permissions
""",
            encoding="utf-8",
        )
        harness.chmod(0o700)
        result = subprocess.run(
            ["/bin/bash", str(harness)], capture_output=True, text=True, encoding="utf-8", timeout=15
        )
        assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        captured = (scenario_dir / "captured-status.txt").read_text(encoding="utf-8")
        privacy_tsv = (tmp_dir / "privacy.tsv").read_text(encoding="utf-8")
        return captured, privacy_tsv

    tcc_db = tmp_path / "TCC.db"
    build_tcc_fixture(tcc_db, [
        ("kTCCServiceCamera", "com.apple.FaceTime", 2),
        ("kTCCServiceMicrophone", "com.apple.FaceTime", 2),
        ("kTCCServiceCamera", "com.example.denied-camera", 0),
        ("kTCCServiceMicrophone", "com.example.denied-mic", 0),
        ("kTCCServiceContacts", "com.example.unrelated-service", 2),
    ])
    ok_captured, ok_privacy = run_scenario(tcc_db, "allowed-and-denied-mixed")
    assert "status\tok" in ok_captured, ok_captured
    assert "kTCCServiceCamera\tcom.apple.FaceTime" in ok_privacy
    assert "kTCCServiceMicrophone\tcom.apple.FaceTime" in ok_privacy
    assert "denied-camera" not in ok_privacy
    assert "denied-mic" not in ok_privacy
    assert "unrelated-service" not in ok_privacy

    # No TCC.db at the pinned path (the real no-Full-Disk-Access shape,
    # where macOS makes the file appear not to exist at all) must degrade
    # cleanly to unavailable, not fail the whole collector.
    missing_captured, missing_privacy = run_scenario(tmp_path / "does-not-exist" / "TCC.db", "no-full-disk-access")
    assert "status\tunavailable" in missing_captured, missing_captured
    assert missing_privacy == ""


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


def test_macos_jxa_vt_budget_exhaustion_is_counted_and_cache_saves_incrementally(project_root, tmp_path):
    """Mirrors test_powershell_vt_budget_exhaustion_is_counted_and_cache_saves_incrementally
    for the macOS/JXA implementation of the same fix. save() used to run
    exactly once, at the very end of the whole scan, and nothing counted or
    surfaced how many eligible files got skipped once maxCallsPerScan was
    hit -- the same gap fixed on the Windows side, present here too since
    both platforms shared the identical once-at-the-end save() structure.

    vtLookup's own body makes no direct JXA/$.NS* calls -- every OS
    interaction goes through named helper functions (env, homeDir, ensureDir,
    readJson, writeText, run, runCurlWithSecretHeader, sha256, shouldSkipVt),
    so it is plain, JXA-independent JavaScript that runs unmodified under
    Node once those are stubbed. Extracted directly from the shipped file by
    line range (not a hand-duplicated copy that could silently drift from
    it), the same discipline as this file's PowerShell dot-sourcing tests
    and the cleanup.sh condition-extraction test."""
    node = shutil.which("node")
    if node is None:
        pytest.skip("requires node for a syntax-level harness around real JXA-independent logic")

    source_lines = (project_root / "scripts" / "scanner_helper.jxa.js").read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(source_lines) if line.startswith("function vtLookup(config, disabled) {"))
    end = next(i for i, line in enumerate(source_lines) if line.startswith("function get(obj, path) {"))
    vt_lookup_source = "\n".join(source_lines[start:end]).strip()
    assert vt_lookup_source.startswith("function vtLookup"), "extraction boundary moved; update this test"
    assert vt_lookup_source.endswith("}"), "extraction boundary moved; update this test"

    harness_path = tmp_path / "vt-budget-harness.js"
    harness_path.write_text(
        r"""
'use strict';
let files = {};
function env(name, fallback) { return fallback; }
function homeDir() { return '/fake-home'; }
function ensureDir(path) {}
function readJson(path, fallback, maximumBytes) {
  return Object.prototype.hasOwnProperty.call(files, path) ? JSON.parse(files[path]) : fallback;
}
function writeText(path, text) { files[path] = text; return true; }
function run(cmd) { return ''; }
function shouldSkipVt(path) { return false; }
function sha256(path) { return 'fakehash-' + path; }
let curlCalls = 0;
function runCurlWithSecretHeader(url, apiKey) {
  curlCalls += 1;
  const body = JSON.stringify({ attributes: { last_analysis_stats: { malicious: 0, suspicious: 0, harmless: 70, undetected: 3 } } });
  return JSON.stringify({ data: JSON.parse(body) }) + '\n200';
}

##VT_LOOKUP_SOURCE##

const config = { virustotal: { apiKey: 'a'.repeat(64), enabled: true, cacheHours: 48, maxCallsPerScan: 2 } };
const vt = vtLookup(config, false);
const cachePath = homeDir() + '/Library/Caches/PC건강검진/vt-cache.json';

const resultA = vt.file('/fake/a.bin');
if (resultA.status !== 'ok') throw new Error('expected sample A to succeed, got ' + resultA.status);
if (curlCalls !== 1) throw new Error('expected exactly 1 real call after sample A, got ' + curlCalls);

// Prove the save happened incrementally: the fake filesystem must already
// reflect this entry before the second call, since vt.save() is never
// called explicitly anywhere in this harness.
if (!files[cachePath]) throw new Error('cache file does not exist after the first real lookup');
const afterFirst = JSON.parse(files[cachePath]);
if (!afterFirst['file:fakehash-/fake/a.bin']) throw new Error('first lookup was not persisted incrementally');

const resultB = vt.file('/fake/b.bin');
if (resultB.status !== 'ok') throw new Error('expected sample B to succeed, got ' + resultB.status);
const afterSecond = JSON.parse(files[cachePath]);
if (!afterSecond['file:fakehash-/fake/a.bin'] || !afterSecond['file:fakehash-/fake/b.bin']) {
  throw new Error('second lookup did not persist incrementally alongside the first');
}

// Third distinct file, budget already spent (maxCallsPerScan=2) -- must be
// refused without spending a third real curl call, and must not carry a
// malicious verdict field that could be misread as a clean result.
const resultC = vt.file('/fake/c.bin');
if (resultC.status !== 'quota') throw new Error('expected sample C to be budget-refused, got ' + resultC.status);
if (Object.prototype.hasOwnProperty.call(resultC, 'malicious')) throw new Error('a budget-refused result must not carry a malicious verdict field');
if (curlCalls !== 2) throw new Error('expected exactly 2 real curl calls spent, got ' + curlCalls);
if (vt.calls !== 2) throw new Error('expected vt.calls === 2, got ' + vt.calls);
if (vt.skippedForBudget !== 1) throw new Error('expected vt.skippedForBudget === 1, got ' + vt.skippedForBudget);

console.log('VT_BUDGET_OK');
""".lstrip().replace("##VT_LOOKUP_SOURCE##", vt_lookup_source),
        encoding="utf-8",
    )

    result = subprocess.run([node, str(harness_path)], capture_output=True, text=True, encoding="utf-8", timeout=30)
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    assert "VT_BUDGET_OK" in result.stdout


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


def test_powershell_vt_budget_exhaustion_is_counted_and_cache_saves_incrementally(project_root, tmp_path):
    """Save-VtCache used to run exactly once, at the very end of a whole scan
    -- a scan interrupted (closed window, sleep, crash) after real, quota-
    consuming lookups lost every one of them, forcing a full re-pay on the
    next run. And nothing counted or surfaced how many eligible files got
    skipped once maxCallsPerScan was hit, so a budget-exhausted scan looked
    identical to one that checked everything.

    Drives the real Invoke-VtRequest (so its actual budget-check/counter
    logic runs), stubbing only Invoke-RestMethod -- the one cmdlet inside it
    that would otherwise hit the real network -- the same shadowing
    technique test_powershell_vt_cache_round_trip already established."""
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("requires powershell.exe or pwsh")

    config_path = tmp_path / "config.json"
    config_path.write_text(
        json.dumps({"virustotal": {"apiKey": "test-only-key", "enabled": True, "cacheHours": 48, "maxCallsPerScan": 2}}),
        encoding="utf-8",
    )
    cache_dir = tmp_path / "cache"
    sample_a = tmp_path / "a.bin"
    sample_a.write_bytes(b"sample a\n")
    sample_b = tmp_path / "b.bin"
    sample_b.write_bytes(b"sample b\n")
    sample_c = tmp_path / "c.bin"
    sample_c.write_bytes(b"sample c\n")

    harness_path = tmp_path / "vt-budget.ps1"
    harness_path.write_text(
        r"""
param(
    [Parameter(Mandatory = $true)][string]$VtScript,
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$CacheDir,
    [Parameter(Mandatory = $true)][string]$SampleA,
    [Parameter(Mandatory = $true)][string]$SampleB,
    [Parameter(Mandatory = $true)][string]$SampleC
)

$ErrorActionPreference = 'Stop'
. $VtScript

function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $ErrorAction)
    return [PSCustomObject]@{
        data = [PSCustomObject]@{
            attributes = [PSCustomObject]@{
                last_analysis_stats = [PSCustomObject]@{ malicious = 0; suspicious = 0; harmless = 70; undetected = 3 }
                reputation = 0
                last_analysis_date = $null
                signature_info = [PSCustomObject]@{ verified = $null }
                names = @()
            }
        }
    }
}

Initialize-VtLookup -ConfigPath $ConfigPath -CacheDir $CacheDir
$cachePath = Join-Path $CacheDir 'vt-cache.json'

# Two calls under budget (maxCallsPerScan=2), one over -- reset VtLastCall
# before each so the real 16s rate-limit sleep doesn't slow this test; that
# timing behavior isn't what's under test here.
$script:VtLastCall = [DateTime]::MinValue
$resultA = Get-VtFileReputation -FilePath $SampleA
if ($resultA.status -ne 'ok') { throw "expected sample A to succeed, got $($resultA.status)" }

# Prove the save happened incrementally: the file must already reflect this
# entry before the second call, since Save-VtCache is never called explicitly
# anywhere in this harness.
if (-not (Test-Path $cachePath)) { throw 'cache file does not exist after the first real lookup' }
$afterFirst = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
$hashA = (Get-FileHash -Path $SampleA -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not $afterFirst.PSObject.Properties["file:$hashA"]) { throw 'first lookup was not persisted incrementally' }

$script:VtLastCall = [DateTime]::MinValue
$resultB = Get-VtFileReputation -FilePath $SampleB
if ($resultB.status -ne 'ok') { throw "expected sample B to succeed, got $($resultB.status)" }

$afterSecond = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
$hashB = (Get-FileHash -Path $SampleB -Algorithm SHA256).Hash.ToLowerInvariant()
if (-not $afterSecond.PSObject.Properties["file:$hashA"] -or -not $afterSecond.PSObject.Properties["file:$hashB"]) {
    throw 'second lookup did not persist incrementally alongside the first'
}

# Third distinct file, budget already spent -- must be refused, not billed
# as a third real call, and must not be misreadable as a clean verdict.
$script:VtLastCall = [DateTime]::MinValue
$resultC = Get-VtFileReputation -FilePath $SampleC
if ($resultC.status -ne 'quota') { throw "expected sample C to be budget-refused, got $($resultC.status)" }
if ($resultC.ContainsKey('malicious')) { throw 'a budget-refused result must not carry a malicious verdict field' }
if ($script:VtCallsThisScan -ne 2) { throw "expected exactly 2 real calls spent, got $($script:VtCallsThisScan)" }
if ($script:VtSkippedForBudget -ne 1) { throw "expected exactly 1 call counted as budget-skipped, got $($script:VtSkippedForBudget)" }

Write-Output 'VT_BUDGET_OK'
""".lstrip(),
        encoding="utf-8-sig",
    )

    result = subprocess.run(
        [
            powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(harness_path),
            "-VtScript", str(project_root / "scripts" / "vt-lookup.ps1"),
            "-ConfigPath", str(config_path),
            "-CacheDir", str(cache_dir),
            "-SampleA", str(sample_a), "-SampleB", str(sample_b), "-SampleC", str(sample_c),
        ],
        capture_output=True,
        timeout=30,
    )
    stdout = result.stdout.decode("utf-8", errors="replace")
    stderr = result.stderr.decode("utf-8", errors="replace")
    assert result.returncode == 0, f"stdout:\n{stdout}\nstderr:\n{stderr}"
    assert "VT_BUDGET_OK" in stdout


def _write_raw_facts(path, collection, defender_facts=None, cpu_facts=None, run_id=None, background_cpu_facts=None, virustotal=None):
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
            "backgroundCpu": background_cpu_facts if background_cpu_facts is not None else [],
            "network": [],
            "listeningPorts": [],
            "autoruns": [],
            "scheduledTasks": [],
            "recentInstalls": [],
            "defender": defender_facts if defender_facts is not None else {},
        },
        "collection": collection,
    }
    if run_id is not None:
        raw["runId"] = run_id
    if virustotal is not None:
        raw["sections"]["virustotal"] = virustotal
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


def test_powershell_scanner_generates_a_run_id(project_root):
    """runId is what lets monitor_merge.ps1 verify, 5 minutes later, that it's
    augmenting the exact scan that's still on disk rather than a stale or
    unrelated one. scanner.ps1 must mint a fresh one on every run. Running
    the real scanner.ps1 end-to-end (real Get-Process/Defender/network calls)
    isn't practical in CI -- this is the same weight of check as the other
    source-presence assertions in this file for pieces too expensive to run."""
    source = (project_root / "scripts" / "scanner.ps1").read_text(encoding="utf-8-sig")
    assert "runId = [guid]::NewGuid().ToString()" in source


def test_powershell_rule_engine_dedupes_the_same_executable_across_cpu_and_background_cpu(project_root, tmp_path):
    """A process can legitimately appear in both cpu (point-in-time snapshot)
    and backgroundCpu (the precision scan's 5-minute observation, aggregated
    by name and so structurally without a pid_). A name-pattern rule (miner
    detection) fires independently in each section and would double-count
    the same real process as two danger findings without dedup. The
    discriminator has to be path, not pid_: backgroundCpu facts never carry
    one, so a pid_-keyed dedup (the literal JXA/macOS approach) silently
    fails to collapse them here -- this is what proves it actually collapses."""
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("requires powershell.exe or pwsh")

    raw_path = tmp_path / "raw.json"
    out_path = tmp_path / "scan.json"
    _write_raw_facts(
        raw_path, _OK_COLLECTION, run_id="run-abc",
        cpu_facts=[{"name": "xmrig", "pid_": 1234, "cpu": 10, "memoryMB": 100, "path": "C:\\x\\xmrig.exe"}],
        background_cpu_facts=[
            {"name": "xmrig", "path": "C:\\x\\xmrig.exe", "cpuPercent": 95, "maxPercent": 99, "totalCpuSec": 280},
            {"name": "chrome", "path": "C:\\Program Files\\Chrome\\chrome.exe", "cpuPercent": 35, "maxPercent": 40, "totalCpuSec": 90},
        ],
    )
    scan = _run_rule_engine(powershell, project_root, raw_path, out_path)

    assert scan["runId"] == "run-abc"
    miner_findings = [f for f in scan["findings"] if f["category"] == "check_cpu" and "xmrig" in f["title"]]
    assert len(miner_findings) == 1, f"expected one deduped miner finding, got {miner_findings}"
    background_findings = [f for f in scan["findings"] if f["category"] == "check_background_cpu"]
    assert any("chrome" in f["title"] for f in background_findings)

    by_name = {f["name"]: f for f in scan["sections"]["backgroundCpu"]}
    assert by_name["xmrig"]["risk"] == "danger"
    assert by_name["chrome"]["risk"] == "warning"

    # Regression guard: two genuinely different executables that merely
    # share a name must NOT be collapsed by the path-based dedup key.
    raw_path2 = tmp_path / "raw2.json"
    out_path2 = tmp_path / "scan2.json"
    _write_raw_facts(
        raw_path2, _OK_COLLECTION, run_id="run-def",
        cpu_facts=[{"name": "xmrig", "pid_": 111, "cpu": 10, "memoryMB": 100, "path": "C:\\a\\xmrig.exe"}],
        background_cpu_facts=[{"name": "xmrig", "path": "C:\\b\\xmrig.exe", "cpuPercent": 95, "maxPercent": 99, "totalCpuSec": 280}],
    )
    scan2 = _run_rule_engine(powershell, project_root, raw_path2, out_path2)
    miner_findings2 = [f for f in scan2["findings"] if f["category"] == "check_cpu" and "xmrig" in f["title"]]
    assert len(miner_findings2) == 2, "two different executables at different paths must not be deduped"


def _write_monitor_result(path, run_id, aggregate):
    data = {
        "runId": run_id,
        "monitoredAt": "2026-08-11 12:05:00",
        "durationMinutes": 5,
        "sampleIntervalSec": 10,
        "cpuCount": 8,
        "averageOverallCpu": 10,
        "samples": [],
        "aggregate": aggregate,
    }
    path.write_text(json.dumps(data), encoding="utf-8")


def _run_monitor_merge(powershell, project_root, monitor_result_path, raw_facts_path, scan_result_path, run_id=""):
    args = [
        powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", str(project_root / "scripts" / "monitor_merge.ps1"),
        "-MonitorResultPath", str(monitor_result_path),
        "-RawFactsPath", str(raw_facts_path),
        "-ScanResultPath", str(scan_result_path),
        "-RulesDir", str(project_root / "rules"),
        "-WhitelistPath", str(project_root / "data" / "whitelist.json"),
    ]
    if run_id:
        args += ["-RunId", run_id]
    return subprocess.run(args, capture_output=True, text=True, encoding="utf-8", timeout=30)


def test_powershell_monitor_merge_integrates_scan_result_when_run_id_matches(project_root, tmp_path):
    """This is what makes the 5-minute observation actually reach
    scan_result.json -- before this, monitor.ps1's findings never left its
    own standalone monitor_result.json, so the precision scan's distinguishing
    feature (catching a sustained miner) was invisible in the report the user
    actually keeps."""
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("requires powershell.exe or pwsh")

    raw_path = tmp_path / "raw_facts.json"
    scan_path = tmp_path / "scan_result.json"
    monitor_path = tmp_path / "monitor_result.json"
    _write_raw_facts(raw_path, _OK_COLLECTION, run_id="run-abc")
    _write_monitor_result(monitor_path, "run-abc", [
        {"name": "xmrig", "path": "C:\\x\\xmrig.exe", "averagePercent": 95, "maxPercent": 99, "totalCpuSec": 280},
    ])

    result = _run_monitor_merge(powershell, project_root, monitor_path, raw_path, scan_path, run_id="run-abc")
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    assert scan_path.is_file()
    scan = json.loads(scan_path.read_text(encoding="utf-8-sig"))
    assert scan["runId"] == "run-abc"
    assert scan["summary"]["overall"] == "danger"
    assert any("xmrig" in f["title"] for f in scan["findings"])
    assert "기본 검사 결과에 반영됨" in result.stdout


def test_powershell_monitor_merge_skips_integration_on_run_id_mismatch(project_root, tmp_path):
    """A mismatched runId means raw_facts.json belongs to a different run
    (e.g. the user re-ran a quick scan while the 5-minute observation was
    still going) -- merging into it would silently attach the observation to
    the wrong scan's report. Must skip, not guess, and must not touch the
    existing raw_facts.json."""
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("requires powershell.exe or pwsh")

    raw_path = tmp_path / "raw_facts.json"
    scan_path = tmp_path / "scan_result.json"
    monitor_path = tmp_path / "monitor_result.json"
    _write_raw_facts(raw_path, _OK_COLLECTION, run_id="run-original")
    _write_monitor_result(monitor_path, "run-observed", [])

    result = _run_monitor_merge(powershell, project_root, monitor_path, raw_path, scan_path, run_id="run-observed")
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    assert not scan_path.exists()
    assert "일치하지" in result.stdout
    assert json.loads(raw_path.read_text(encoding="utf-8"))["runId"] == "run-original"


def test_powershell_monitor_merge_standalone_run_is_silent_and_skips_integration(project_root, tmp_path):
    """monitor.ps1 (and by extension monitor_merge.ps1) must stay usable as a
    standalone diagnostic tool run directly outside menu.ps1's flow -- no
    RunId at all is the normal case for that, not an error worth a warning."""
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("requires powershell.exe or pwsh")

    raw_path = tmp_path / "raw_facts.json"  # deliberately never created
    scan_path = tmp_path / "scan_result.json"
    monitor_path = tmp_path / "monitor_result.json"
    _write_monitor_result(monitor_path, "", [])

    result = _run_monitor_merge(powershell, project_root, monitor_path, raw_path, scan_path, run_id="")
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    assert not scan_path.exists()
    assert "⚠️" not in result.stdout


def _run_invoke_monitor_scenario(project_root, tmp_path, monitor_body: str, pre_existing_result: str | None):
    """Mirrors _run_invoke_scanner_scenario (1e) but drives Invoke-Monitor:
    lays out scenarioRoot/scripts/{menu functions, monitor.ps1}."""
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("requires powershell.exe or pwsh")

    scripts_dir = tmp_path / "scripts"
    scripts_dir.mkdir(parents=True)
    if pre_existing_result is not None:
        (tmp_path / "scan_result.json").write_text(pre_existing_result, encoding="utf-8")
    (scripts_dir / "monitor.ps1").write_text(monitor_body, encoding="utf-8-sig")
    harness = (
        'function chcp { param([Parameter(ValueFromRemainingArguments=$true)]$rest) }  # non-Windows test stub\n'
        + _menu_functions_source(project_root)
        + '\n$outputPath = Join-Path $root "scan_result.json"\n'
        '$monitorResult = Invoke-Monitor -RunId "test-run"\n'
        'Write-Output "RESULT=$monitorResult"\n'
        'if (Test-Path $outputPath) { Write-Output "CONTENT=$(Get-Content $outputPath -Raw)" }\n'
    )
    (scripts_dir / "harness.ps1").write_text(harness, encoding="utf-8-sig")

    result = subprocess.run(
        [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
         "-File", str(scripts_dir / "harness.ps1")],
        capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    return result


def test_powershell_menu_monitor_gate_treats_a_cancelled_observation_as_non_fatal(project_root, tmp_path):
    """Ctrl+C during the 5-minute wait is an explicitly supported cancellation
    path (menu.ps1's own prompt says so) -- monitor.ps1 aborts before it ever
    reaches its save step (monitor_merge.ps1), so scan_result.json is simply
    never rewritten. Invoke-Monitor must read that as "did not complete" via
    freshness (matching Invoke-Scanner's 1e-established pattern), not crash,
    and the caller must treat it as a soft warning, not a hard stop -- the
    valid quick-scan result from step 1 must survive untouched."""
    stale = '{"stale":"before"}'
    aborts_before_saving = 'hostname | Out-Null\nreturn\n'

    result = _run_invoke_monitor_scenario(project_root, tmp_path, aborts_before_saving, stale)
    assert result.returncode == 0, result.stderr
    assert "RESULT=False" in result.stdout
    assert '"stale":"before"' in result.stdout


def test_powershell_menu_monitor_gate_recognizes_a_completed_observation(project_root, tmp_path):
    """The positive case: monitor.ps1 (via monitor_merge.ps1) actually
    rewrites scan_result.json with fresh content -- Invoke-Monitor must
    recognize that as success."""
    stale = '{"stale":"before"}'
    rewrites_scan_result = '''Start-Sleep -Milliseconds 20
$outputPath = Join-Path $root "scan_result.json"
Set-Content -Path $outputPath -Value '{"fresh":"after"}' -Encoding UTF8
'''

    result = _run_invoke_monitor_scenario(project_root, tmp_path, rewrites_scan_result, stale)
    assert result.returncode == 0, result.stderr
    assert "RESULT=True" in result.stdout
    assert '"fresh":"after"' in result.stdout


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


def test_powershell_report_renders_background_cpu_observation_results(project_root, tmp_path):
    """The precision scan's whole distinguishing value is the 5-minute
    observation -- if backgroundCpu facts reach scan_result.json but
    report.ps1 never renders them, the user's saved/shared report still
    doesn't show what the deep scan actually found. Prove the full chain:
    raw facts with a backgroundCpu section -> rule_engine.ps1 classifies it
    -> report.ps1 puts a real row (not just an empty-state placeholder) in
    the HTML."""
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("requires powershell.exe or pwsh")

    raw_path = tmp_path / "raw.json"
    scan_path = tmp_path / "scan.json"
    report_path = tmp_path / "report.html"
    _write_raw_facts(
        raw_path, _OK_COLLECTION, run_id="run-report",
        background_cpu_facts=[
            {"name": "xmrig", "path": "C:\\x\\xmrig.exe", "cpuPercent": 95, "maxPercent": 99, "totalCpuSec": 280},
        ],
    )
    _run_rule_engine(powershell, project_root, raw_path, scan_path)

    result = subprocess.run(
        [
            powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(project_root / "scripts" / "report.ps1"),
            "-Scan", str(scan_path),
            "-Output", str(report_path),
        ],
        capture_output=True, timeout=30,
    )
    stdout = result.stdout.decode("utf-8", errors="replace")
    stderr = result.stderr.decode("utf-8", errors="replace")
    assert result.returncode == 0, f"stdout:\n{stdout}\nstderr:\n{stderr}"

    html = report_path.read_text(encoding="utf-8")
    assert "5분 유휴 관측 결과" in html
    assert "xmrig" in html
    assert "risk-danger" in html
    # And the no-observation-ran case must degrade to the existing empty
    # state, not an error -- most scans (quick scan) never populate this.
    scan_no_observation = tmp_path / "scan_no_obs.json"
    report_no_observation = tmp_path / "report_no_obs.html"
    raw_no_observation = tmp_path / "raw_no_obs.json"
    _write_raw_facts(raw_no_observation, _OK_COLLECTION)
    _run_rule_engine(powershell, project_root, raw_no_observation, scan_no_observation)
    result2 = subprocess.run(
        [
            powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(project_root / "scripts" / "report.ps1"),
            "-Scan", str(scan_no_observation),
            "-Output", str(report_no_observation),
        ],
        capture_output=True, timeout=30,
    )
    assert result2.returncode == 0, result2.stderr.decode("utf-8", errors="replace")
    html_no_observation = report_no_observation.read_text(encoding="utf-8")
    assert "5분 유휴 관측 결과" in html_no_observation
    assert "표시할 항목이 없습니다" in html_no_observation


def test_powershell_report_renders_vt_budget_caveat_when_calls_were_skipped(project_root, tmp_path):
    """A file VT couldn't check because the quota ran out isn't judged unsafe
    -- it's just unverified this run. Before this, nothing in the report
    said so: a budget-exhausted scan looked identical to one that verified
    every eligible file, and report.ps1 didn't even render a VT section at
    all. Prove both the caveat appears when calls were skipped, and that a
    disabled/fully-completed VT run doesn't show a false caveat."""
    powershell = shutil.which("powershell.exe") or shutil.which("pwsh")
    if powershell is None:
        pytest.skip("requires powershell.exe or pwsh")

    def render(virustotal):
        raw_path = tmp_path / f"raw-{virustotal.get('callsThisScan', 'x')}-{virustotal.get('skippedForBudget', 'x')}.json"
        scan_path = raw_path.with_suffix(".scan.json")
        report_path = raw_path.with_suffix(".html")
        _write_raw_facts(raw_path, _OK_COLLECTION, virustotal=virustotal)
        _run_rule_engine(powershell, project_root, raw_path, scan_path)
        result = subprocess.run(
            [
                powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-File", str(project_root / "scripts" / "report.ps1"),
                "-Scan", str(scan_path), "-Output", str(report_path),
            ],
            capture_output=True, timeout=30,
        )
        assert result.returncode == 0, result.stderr.decode("utf-8", errors="replace")
        return report_path.read_text(encoding="utf-8")

    skipped_html = render({"enabled": True, "callsThisScan": 3, "cacheHours": 48, "skippedForBudget": 7})
    assert "VirusTotal 조회" in skipped_html
    assert "쿼터 소진" in skipped_html
    assert "7" in skipped_html

    complete_html = render({"enabled": True, "callsThisScan": 10, "cacheHours": 48, "skippedForBudget": 0})
    assert "VirusTotal 조회" in complete_html
    assert "쿼터 소진" not in complete_html

    disabled_html = render({"enabled": False, "callsThisScan": 0, "cacheHours": 0, "skippedForBudget": 0})
    assert "VirusTotal 조회" not in disabled_html


@pytest.mark.skipif(platform.system() != "Darwin", reason="JXA runtime requires macOS osascript")
def test_macos_jxa_report_renders_vt_budget_caveat_when_calls_were_skipped(project_root, tmp_path):
    """macOS equivalent of test_powershell_report_renders_vt_budget_caveat_when_calls_were_skipped
    -- report.jxa.js had no VT section at all before this, on either
    platform."""

    def render(virustotal):
        scan_path = tmp_path / f"scan-{virustotal.get('skippedForBudget', 'x')}.json"
        report_path = tmp_path / f"report-{virustotal.get('skippedForBudget', 'x')}.html"
        scan = {
            "computerName": "TEST-MAC", "userName": "tester", "osVersion": "macOS Test",
            "scannedAt": "2026-08-11 12:00:00",
            "summary": {"overall": "safe", "message": "특별한 이상 없음", "dangerCount": 0, "warningCount": 0},
            "findings": [],
            "collection": {"completedRequiredCount": 0, "requiredCount": 0, "completedCount": 0, "sourceCount": 0, "sources": []},
            "sections": {
                "cpu": [], "network": [], "listeningPorts": [], "autoruns": [], "recentInstalls": [],
                "virustotal": virustotal,
            },
        }
        scan_path.write_text(json.dumps(scan), encoding="utf-8")
        env = dict(os.environ)
        env["PCH_SCAN"] = str(scan_path)
        env["PCH_REPORT_OUTPUT"] = str(report_path)
        result = subprocess.run(
            ["/usr/bin/osascript", "-l", "JavaScript", str(project_root / "scripts" / "report.jxa.js")],
            capture_output=True, text=True, encoding="utf-8", env=env, timeout=30,
        )
        assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        return report_path.read_text(encoding="utf-8")

    skipped_html = render({"enabled": True, "callsThisScan": 3, "cacheHours": 48, "skippedForBudget": 7})
    assert "VirusTotal 조회" in skipped_html
    assert "쿼터 소진" in skipped_html
    assert "7" in skipped_html

    complete_html = render({"enabled": True, "callsThisScan": 10, "cacheHours": 48, "skippedForBudget": 0})
    assert "VirusTotal 조회" in complete_html
    assert "쿼터 소진" not in complete_html

    disabled_html = render({"enabled": False, "callsThisScan": 0, "cacheHours": 0, "skippedForBudget": 0})
    assert "VirusTotal 조회" not in disabled_html


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
