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
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from artifact_audit import audit_zip, inspect_bytes, inspect_metadata


PROJECT_ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.3.0"
DIST_DIR = Path(os.environ.get("PCH_DISTRIBUTION_DIR", PROJECT_ROOT / "dist")).expanduser()

COMMON_FILES = [
    "README.md",
    "LICENSE",
    "SECURITY.md",
    "CONTRIBUTING.md",
    "CHANGELOG.md",
    "사용법.txt",
    "docs/ARCHITECTURE.md",
    "data/config.example.json",
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

SWIFT_FILES = sorted(
    path.relative_to(PROJECT_ROOT).as_posix()
    for base in (
        PROJECT_ROOT / "macos/PCHealthCheckMac/Sources",
        PROJECT_ROOT / "macos/PCHealthCheckMac/Tests",
    )
    for path in base.rglob("*.swift")
    if ".build" not in path.parts
)

MACOS_BASE_FILES = COMMON_FILES + [
    "검사하기.command",
    "Mac앱실행.command",
    "scripts/scanner.sh",
    "scripts/cleanup.sh",
    "scripts/storage_watch.sh",
    "scripts/schedule.sh",
    "scripts/report.jxa.js",
    "scripts/scanner_helper.jxa.js",
    "scripts/build_macos_swift_app.sh",
    "scripts/build_macos_icon.sh",
    "scripts/package_macos_release.sh",
    "scripts/artifact_audit.py",
    "scripts/modules/macos/cpu.sh",
    "scripts/modules/macos/network.sh",
    "scripts/modules/macos/autoruns.sh",
    "scripts/modules/macos/security.sh",
    "scripts/modules/macos/storage.sh",
    "macos/PCHealthCheckMac/Package.swift",
    "assets/macos/AppIcon.svg",
]
MACOS_FILES = MACOS_BASE_FILES + SWIFT_FILES

FORBIDDEN_NAMES = {
    "scan_result.json",
    "raw_facts.json",
    "monitor_result.json",
    "검사결과.html",
    "검사결과_공유용.html",
    "vt-cache.json",
    "config.json",
}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def source_state(version: str) -> dict:
    if shutil.which("git") is None:
        return {"repository": False, "commit": None, "tag": None, "clean": False}

    def git(*arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(PROJECT_ROOT), *arguments],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        )

    probe = git("rev-parse", "--is-inside-work-tree")
    if probe.returncode != 0 or probe.stdout.strip() != "true":
        return {"repository": False, "commit": None, "tag": None, "clean": False}

    commit = git("rev-parse", "HEAD").stdout.strip()
    status = git("status", "--porcelain", "--untracked-files=all")
    clean = status.returncode == 0 and not status.stdout.strip()
    expected_tag = f"v{version}"
    tagged_commit = git("rev-parse", f"{expected_tag}^{{commit}}")
    tag = expected_tag if tagged_commit.returncode == 0 and tagged_commit.stdout.strip() == commit else None
    return {"repository": True, "commit": commit or None, "tag": tag, "clean": clean}


def git_bytes(commit: str, rel: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(PROJECT_ROOT), "show", f"{commit}:{rel}"],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise FileNotFoundError(f"release entry missing from {commit[:12]}: {rel}")
    return result.stdout


def git_entry_mode(commit: str, rel: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(PROJECT_ROOT), "ls-tree", "-z", commit, "--", rel],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0 or not result.stdout:
        raise FileNotFoundError(f"release entry missing from {commit[:12]}: {rel}")
    records = [record for record in result.stdout.split(b"\0") if record]
    if len(records) != 1:
        raise ValueError(f"release entry is ambiguous: {rel}")
    header, path = records[0].split(b"\t", 1)
    mode, object_type, _object_id = header.decode("ascii").split()
    if path.decode("utf-8", errors="strict") != rel or object_type != "blob":
        raise ValueError(f"release entry is not a regular Git blob: {rel}")
    return mode


def source_bytes(rel: str, source_commit: str | None) -> bytes:
    if source_commit:
        return git_bytes(source_commit, rel)
    return (PROJECT_ROOT / rel).read_bytes()


def assert_clean_file_list(files: list[str], source_commit: str | None = None) -> None:
    seen = set()
    for rel in files:
        if rel in seen:
            raise ValueError(f"duplicate release entry: {rel}")
        seen.add(rel)
        if source_commit:
            if git_entry_mode(source_commit, rel) not in {"100644", "100755"}:
                raise ValueError(f"release entry must be a regular file: {rel}")
        else:
            path = PROJECT_ROOT / rel
            if not path.is_file():
                raise FileNotFoundError(f"release entry missing: {rel}")
            if path.is_symlink():
                raise ValueError(f"release entry must not be a symlink: {rel}")
        if Path(rel).name in FORBIDDEN_NAMES:
            raise ValueError(f"forbidden release entry: {rel}")
        findings = inspect_bytes(rel, source_bytes(rel, source_commit))
        if findings:
            details = ", ".join(f"{item.rule}:{item.entry}" for item in findings)
            raise ValueError(f"release source audit failed: {details}")


def add_file(
    zf: zipfile.ZipFile,
    rel: str,
    root_name: str,
    executable: bool = False,
    source_commit: str | None = None,
) -> None:
    info = zipfile.ZipInfo(str(Path(root_name) / rel))
    info.date_time = (2026, 1, 1, 0, 0, 0)
    mode = 0o755 if executable else 0o644
    info.external_attr = (stat.S_IFREG | mode) << 16
    zf.writestr(info, source_bytes(rel, source_commit), compress_type=zipfile.ZIP_DEFLATED)


def publish_new_file(temporary: Path, destination: Path) -> None:
    if sys.platform == "darwin":
        subprocess.run(["/usr/bin/xattr", "-c", str(temporary)], check=True)
        subprocess.run(["/bin/chmod", "-N", str(temporary)], check=True)
    metadata_findings = inspect_metadata(destination.name, temporary)
    if metadata_findings:
        details = ", ".join(f"{item.rule}:{item.entry}" for item in metadata_findings)
        raise ValueError(f"release artifact metadata audit failed: {details}")
    os.chmod(temporary, 0o644)
    try:
        os.link(temporary, destination)
    except FileExistsError as error:
        raise FileExistsError(f"refusing to overwrite release artifact: {destination}") from error
    finally:
        temporary.unlink(missing_ok=True)


def temporary_path_for(destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_path = tempfile.mkstemp(
        prefix=f".{destination.name}.",
        suffix=".partial",
        dir=destination.parent,
    )
    os.close(descriptor)
    return Path(raw_path)


def build_zip(
    name: str,
    files: list[str],
    executable_entries: set[str],
    *,
    output_dir: Path | None = None,
    source_commit: str | None = None,
) -> Path:
    assert_clean_file_list(files, source_commit=source_commit)
    output_dir = output_dir or DIST_DIR
    zip_path = output_dir / f"{name}.zip"
    if zip_path.exists() or zip_path.is_symlink():
        raise FileExistsError(f"refusing to overwrite release artifact: {zip_path}")
    temporary = temporary_path_for(zip_path)
    root_name = name
    try:
        with zipfile.ZipFile(temporary, "w") as zf:
            for rel in files:
                add_file(
                    zf,
                    rel,
                    root_name,
                    executable=rel in executable_entries,
                    source_commit=source_commit,
                )
        validate_zip(temporary, artifact_name=zip_path.name)
        publish_new_file(temporary, zip_path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return zip_path


def validate_zip(path: Path, artifact_name: str | None = None) -> dict:
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
        findings = audit_zip(path)
        if findings:
            details = ", ".join(f"{item.rule}:{item.entry}" for item in findings)
            raise ValueError(f"{path.name} failed artifact audit: {details}")
        return {
            "file": artifact_name or path.name,
            "entries": len(names),
            "sha256": sha256_file(path),
            "audit": {"secrets": True, "pii": True, "symlinks": True},
        }


def swift_files_from_commit(commit: str) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(PROJECT_ROOT), "ls-tree", "-r", "-z", "--name-only", commit],
        capture_output=True,
        check=True,
    )
    prefixes = (
        "macos/PCHealthCheckMac/Sources/",
        "macos/PCHealthCheckMac/Tests/",
    )
    return sorted(
        raw.decode("utf-8", errors="strict")
        for raw in result.stdout.split(b"\0")
        if raw
        and raw.endswith(b".swift")
        and raw.decode("utf-8", errors="strict").startswith(prefixes)
    )


def write_new_text(destination: Path, text: str) -> None:
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f"refusing to overwrite release artifact: {destination}")
    temporary = temporary_path_for(destination)
    try:
        with temporary.open("w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        findings = inspect_bytes(destination.name, temporary.read_bytes())
        if findings:
            details = ", ".join(f"{item.rule}:{item.entry}" for item in findings)
            raise ValueError(f"release manifest failed artifact audit: {details}")
        publish_new_file(temporary, destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description="Build and validate release zips")
    parser.add_argument("--check-only", action="store_true", help="validate source allowlists without writing zips")
    parser.add_argument(
        "--release",
        action="store_true",
        help="require a clean exact v<version> tag before writing publishable source artifacts",
    )
    parser.add_argument("--version", default=VERSION, help="artifact version (default: %(default)s)")
    args = parser.parse_args()

    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        parser.error("--version must be a numeric X.Y.Z release version")
    if args.release and args.check_only:
        parser.error("--release cannot be combined with --check-only")

    state = source_state(args.version)
    if args.release and not (state["repository"] and state["clean"] and state["tag"]):
        raise RuntimeError(
            f"release requires clean HEAD at exact tag v{args.version}"
        )

    source_commit = state["commit"] if args.release else None
    macos_files = MACOS_BASE_FILES + (
        swift_files_from_commit(source_commit) if source_commit else SWIFT_FILES
    )
    assert_clean_file_list(WINDOWS_FILES, source_commit=source_commit)
    assert_clean_file_list(macos_files, source_commit=source_commit)
    if args.check_only:
        print(json.dumps({"ok": True, "windows_entries": len(WINDOWS_FILES), "macos_entries": len(macos_files)}, ensure_ascii=False))
        return 0

    version = args.version
    if args.release:
        output_dir = DIST_DIR
        build_suffix = ""
        manifest_name = "release-manifest.json"
    else:
        output_dir = DIST_DIR / "local"
        commit_label = (state["commit"] or "source")[:12]
        dirty_label = "-dirty" if not state["clean"] else ""
        build_suffix = f"-source-smoke-{commit_label}{dirty_label}"
        manifest_name = f"release-manifest{build_suffix}.json"

    win_name = f"pch-v{version}-win{build_suffix}"
    mac_name = f"pch-v{version}-mac{build_suffix}"
    manifest_path = output_dir / manifest_name
    destinations = [
        output_dir / f"{win_name}.zip",
        output_dir / f"{mac_name}.zip",
        manifest_path,
    ]
    if any(path.exists() or path.is_symlink() for path in destinations):
        raise FileExistsError("refusing to overwrite an existing release artifact")

    created: list[Path] = []
    try:
        win = build_zip(
            win_name,
            WINDOWS_FILES,
            executable_entries=set(),
            output_dir=output_dir,
            source_commit=source_commit,
        )
        created.append(win)
        mac = build_zip(
            mac_name,
            macos_files,
            executable_entries={
                "검사하기.command",
                "Mac앱실행.command",
                "scripts/scanner.sh",
                "scripts/cleanup.sh",
                "scripts/storage_watch.sh",
                "scripts/schedule.sh",
                "scripts/build_macos_swift_app.sh",
                "scripts/build_macos_icon.sh",
                "scripts/package_macos_release.sh",
                "scripts/artifact_audit.py",
            },
            output_dir=output_dir,
            source_commit=source_commit,
        )
        created.append(mac)
        if args.release and source_state(version) != state:
            raise RuntimeError("source checkout changed while release ZIPs were being built")
        manifest = {
            "version": version,
            "publishable": args.release,
            "source": state,
            "artifacts": [validate_zip(win), validate_zip(mac)],
        }
        write_new_text(
            manifest_path,
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        )
    except Exception:
        for path in created:
            path.unlink(missing_ok=True)
        raise
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
