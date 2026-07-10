#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build and validate release zip artifacts for PC Health Check.

This script is intentionally dependency-free. It creates OS-specific zip files
from an allowlist so local scan artifacts, caches, and user config byproducts
cannot accidentally ship in a release.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import stat
import sys
import zipfile
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.3.0"
DIST_DIR = PROJECT_ROOT / "dist"

COMMON_FILES = [
    "README.md",
    "LICENSE",
    "SECURITY.md",
    "CONTRIBUTING.md",
    "CHANGELOG.md",
    "사용법.txt",
    "data/config.json",
    "data/explain.json",
    "data/whitelist.json",
    "data/report_i18n/ko.json",
    "data/report_i18n/en.json",
    "data/report_i18n/ja.json",
    "rules/README.md",
    "rules/autoruns.json",
    "rules/defender.json",
    "rules/installs.json",
    "rules/network.json",
    "rules/process.json",
]

WINDOWS_FILES = COMMON_FILES + [
    "검사하기.bat",
    "scripts/menu.ps1",
    "scripts/scanner.ps1",
    "scripts/report.ps1",
    "scripts/rule_engine.ps1",
    "scripts/monitor.ps1",
    "scripts/vt-lookup.ps1",
    "scripts/_sysinternals-verify.ps1",
    "scripts/sigcheck-helper.ps1",
    "scripts/autorunsc-helper.ps1",
    "scripts/modules/cpu.ps1",
    "scripts/modules/network.ps1",
    "scripts/modules/autoruns.ps1",
    "scripts/modules/defender.ps1",
    "scripts/modules/installs.ps1",
]

MACOS_FILES = COMMON_FILES + [
    "검사하기.command",
    "Mac앱실행.command",
    "scripts/scanner.sh",
    "scripts/cleanup.sh",
    "scripts/storage_watch.sh",
    "scripts/schedule.sh",
    "scripts/report.jxa.js",
    "scripts/scanner_helper.jxa.js",
    "scripts/build_macos_swift_app.sh",
    "scripts/package_macos_release.sh",
    "scripts/modules/macos/cpu.sh",
    "scripts/modules/macos/network.sh",
    "scripts/modules/macos/autoruns.sh",
    "scripts/modules/macos/security.sh",
    "scripts/modules/macos/storage.sh",
    "macos/PCHealthCheckMac/Package.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/PCHealthCheckMacApp.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Models/CleanupModels.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Models/ScanContent.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Models/ScanModels.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Models/StorageHistory.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Models/StorageModels.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Models/WorkspaceSelection.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/LocalProcessRunner.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/RuntimeWorkspace.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/ScanModel.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/ScanModelActions.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Services/ScanPipeline.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Support/CleanupPresentation.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Support/ProcessRunState.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Support/ScanLogStore.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Support/ViewStyles.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/ActivityView.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/AppShell.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/CleanupInspectorView.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/CleanupView.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/DevelopmentInspectorView.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/DevelopmentView.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/InventoryInspectorView.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/InventoryView.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/NativeSettingsComponents.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/NativeSourceIcons.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/SecurityView.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/SharedComponents.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/StorageOverviewView.swift",
    "macos/PCHealthCheckMac/Sources/PCHealthCheckMac/Views/StorageVolumeCard.swift",
    "macos/PCHealthCheckMac/Tests/PCHealthCheckMacTests/PCHealthCheckMacTests.swift",
]

FORBIDDEN_NAMES = {
    "scan_result.json",
    "raw_facts.json",
    "monitor_result.json",
    "검사결과.html",
    "검사결과_공유용.html",
    "vt-cache.json",
}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def assert_clean_file_list(files: list[str]) -> None:
    seen = set()
    for rel in files:
        if rel in seen:
            raise ValueError(f"duplicate release entry: {rel}")
        seen.add(rel)
        path = PROJECT_ROOT / rel
        if not path.is_file():
            raise FileNotFoundError(f"release entry missing: {rel}")
        if Path(rel).name in FORBIDDEN_NAMES:
            raise ValueError(f"forbidden release entry: {rel}")


def add_file(zf: zipfile.ZipFile, rel: str, root_name: str, executable: bool = False) -> None:
    path = PROJECT_ROOT / rel
    info = zipfile.ZipInfo(str(Path(root_name) / rel))
    info.date_time = (2026, 1, 1, 0, 0, 0)
    mode = 0o755 if executable else 0o644
    info.external_attr = (stat.S_IFREG | mode) << 16
    zf.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED)


def build_zip(name: str, files: list[str], executable_entries: set[str]) -> Path:
    assert_clean_file_list(files)
    DIST_DIR.mkdir(exist_ok=True)
    zip_path = DIST_DIR / f"{name}.zip"
    root_name = name
    with zipfile.ZipFile(zip_path, "w") as zf:
        for rel in files:
            add_file(zf, rel, root_name, executable=rel in executable_entries)
    return zip_path


def validate_zip(path: Path) -> dict:
    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
        forbidden = [n for n in names if Path(n).name in FORBIDDEN_NAMES or "__pycache__" in n]
        if forbidden:
            raise ValueError(f"{path.name} contains forbidden entries: {forbidden}")
        command_entries = [i for i in zf.infolist() if i.filename.endswith(".command")]
        for info in command_entries:
            mode = (info.external_attr >> 16) & 0o777
            if mode & 0o111 == 0:
                raise ValueError(f"{info.filename} is not executable in {path.name}")
        return {"file": str(path), "entries": len(names), "sha256": sha256_file(path)}


def main() -> int:
    parser = argparse.ArgumentParser(description="Build and validate release zips")
    parser.add_argument("--check-only", action="store_true", help="validate source allowlists without writing zips")
    args = parser.parse_args()

    assert_clean_file_list(WINDOWS_FILES)
    assert_clean_file_list(MACOS_FILES)
    if args.check_only:
        print(json.dumps({"ok": True, "windows_entries": len(WINDOWS_FILES), "macos_entries": len(MACOS_FILES)}, ensure_ascii=False))
        return 0

    win = build_zip(f"pch-v{VERSION}-win", WINDOWS_FILES, executable_entries=set())
    mac = build_zip(
        f"pch-v{VERSION}-mac",
        MACOS_FILES,
        executable_entries={
            "검사하기.command",
            "Mac앱실행.command",
            "scripts/scanner.sh",
            "scripts/cleanup.sh",
            "scripts/storage_watch.sh",
            "scripts/schedule.sh",
            "scripts/build_macos_swift_app.sh",
            "scripts/package_macos_release.sh",
        },
    )
    manifest = {"version": VERSION, "artifacts": [validate_zip(win), validate_zip(mac)]}
    manifest_path = DIST_DIR / "release-manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
