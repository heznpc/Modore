#!/usr/bin/env python3
"""Fail closed when a release payload contains local data or unsafe entries."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
import zipfile
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath
from typing import BinaryIO


MAX_FILE_BYTES = 256 * 1024 * 1024
MAX_ZIP_BYTES = 1024 * 1024 * 1024
PLACEHOLDER_USERS = {
    "<redacted>",
    "example",
    "runner",
    "sample",
    "shared",
    "test",
    "user",
    "username",
    "x",
    "your-name",
}
PLACEHOLDER_SECRETS = {
    "changeme",
    "example",
    "placeholder",
    "redacted",
    "your_api_key",
    "your_api_key_here",
    "your_key",
    "your_key_here",
    "your_token",
}
ALLOWED_EXTENDED_ATTRIBUTES = {"com.apple.provenance"}


@dataclass(frozen=True)
class Finding:
    entry: str
    rule: str
    detail: str


PRIVATE_KEY_MARKERS = (
    b"-----BEGIN " + b"PRIVATE KEY-----",
    b"-----BEGIN " + b"RSA PRIVATE KEY-----",
    b"-----BEGIN " + b"EC PRIVATE KEY-----",
    b"-----BEGIN " + b"DSA PRIVATE KEY-----",
    b"-----BEGIN " + b"OPENSSH PRIVATE KEY-----",
    b"-----BEGIN PGP " + b"PRIVATE KEY BLOCK-----",
)
SECRET_PATTERNS = (
    ("github-token", re.compile(rb"gh" rb"[pousr]_[A-Za-z0-9]{24,}")),
    ("openai-token", re.compile(rb"sk-" rb"[A-Za-z0-9_-]{24,}")),
    ("slack-token", re.compile(rb"xox" rb"[baprs]-[A-Za-z0-9-]{10,}")),
    ("google-api-key", re.compile(rb"AI" rb"za[A-Za-z0-9_-]{30,}")),
    ("gitlab-token", re.compile(rb"gl" rb"pat-[A-Za-z0-9_-]{20,}")),
    ("npm-token", re.compile(rb"npm" rb"_[A-Za-z0-9]{24,}")),
    ("aws-access-key", re.compile(rb"AKIA[A-Z0-9]{16}")),
    ("credential-url", re.compile(rb"https?://[^/\s:@]{1,80}:[^/\s@]{4,80}@")),
)
SECRET_ASSIGNMENT = re.compile(
    rb"(?i)(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)"
    rb"[\"'\s]*[:=]\s*([\"'])([^\"'\s]{8,})\1"
)
UNQUOTED_SECRET_ASSIGNMENT = re.compile(
    rb"(?im)^[ \t]*(?:export[ \t]+)?\$?"
    rb"(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)"
    rb"[ \t]*[:=][ \t]*([^\s#;]{8,})[ \t]*$"
)
EMAIL = re.compile(rb"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,24}\b")
MAC_USER_PATH = re.compile(
    (rb"/" + rb"Users/" + rb"([A-Z0-9][A-Z0-9._-]{0,79})"),
    re.IGNORECASE,
)
HOME_USER_PATH = re.compile(
    (rb"/" + rb"home/" + rb"([A-Z0-9][A-Z0-9._-]{0,79})"),
    re.IGNORECASE,
)
WINDOWS_USER_PATH = re.compile(
    (rb"[A-Z]:\\" + rb"Users\\" + rb"([A-Z0-9][A-Z0-9._-]{0,79})"),
    re.IGNORECASE,
)


def _clean_value(value: bytes) -> str:
    return value.decode("utf-8", errors="ignore").strip().strip("<>[]{}()'\"").lower()


def _is_placeholder_secret(value: bytes) -> bool:
    cleaned = _clean_value(value)
    return (
        not cleaned
        or cleaned in PLACEHOLDER_SECRETS
        or cleaned.startswith(("your_", "example_", "test_", "${", "$env:"))
        or "<" in value.decode("utf-8", errors="ignore")
    )


def inspect_bytes(entry: str, data: bytes) -> list[Finding]:
    findings: list[Finding] = []
    lowered = data.lower()
    if any(marker.lower() in lowered for marker in PRIVATE_KEY_MARKERS):
        findings.append(Finding(entry, "private-key", "private key material"))
    for rule, pattern in SECRET_PATTERNS:
        if pattern.search(data):
            findings.append(Finding(entry, rule, "credential-shaped data"))

    for match in SECRET_ASSIGNMENT.finditer(data):
        if not _is_placeholder_secret(match.group(2)):
            findings.append(Finding(entry, "assigned-secret", "non-placeholder credential value"))
            break

    for match in UNQUOTED_SECRET_ASSIGNMENT.finditer(data):
        if not _is_placeholder_secret(match.group(1)):
            findings.append(Finding(entry, "assigned-secret", "non-placeholder credential value"))
            break

    for pattern, platform in (
        (MAC_USER_PATH, "macOS"),
        (HOME_USER_PATH, "Unix"),
        (WINDOWS_USER_PATH, "Windows"),
    ):
        for match in pattern.finditer(data):
            user = _clean_value(match.group(1))
            if user not in PLACEHOLDER_USERS:
                findings.append(Finding(entry, "local-user-path", f"{platform} home path embedded"))
                break

    for match in EMAIL.finditer(data):
        address = _clean_value(match.group(0))
        if address.endswith(("@2x.png", "@example.com", "@example.invalid", "@users.noreply.github.com")):
            continue
        findings.append(Finding(entry, "email-address", "email-shaped personal data"))
        break

    return findings


def extended_attributes(path: Path) -> tuple[list[str], dict[str, bytes]]:
    if hasattr(os, "listxattr") and hasattr(os, "getxattr"):
        names = os.listxattr(path, follow_symlinks=False)
        return names, {
            name: os.getxattr(path, name, follow_symlinks=False)
            for name in names
        }
    if sys.platform != "darwin":
        return [], {}

    link_option = ["-s"] if path.is_symlink() else []
    listing = subprocess.run(
        ["/usr/bin/xattr", *link_option, str(path)],
        capture_output=True,
        check=False,
    )
    if listing.returncode != 0:
        raise OSError("xattr listing failed")
    names = listing.stdout.decode("utf-8", errors="strict").splitlines()
    values: dict[str, bytes] = {}
    for name in names:
        value = subprocess.run(
            ["/usr/bin/xattr", "-p", name, *link_option, str(path)],
            capture_output=True,
            check=False,
        )
        if value.returncode != 0:
            raise OSError(f"xattr read failed: {name}")
        values[name] = value.stdout
    return names, values


def inspect_metadata(entry: str, path: Path) -> list[Finding]:
    findings: list[Finding] = []
    try:
        attributes, values = extended_attributes(path)
    except (UnicodeError, OSError) as error:
        findings.append(Finding(entry, "metadata-unreadable", type(error).__name__))
        attributes, values = [], {}

    for attribute in attributes:
        if attribute not in ALLOWED_EXTENDED_ATTRIBUTES:
            findings.append(Finding(entry, "extended-attribute", attribute))
        try:
            findings.extend(inspect_bytes(f"{entry}:xattr:{attribute}", values[attribute]))
        except KeyError:
            findings.append(Finding(entry, "metadata-unreadable", "missing xattr value"))

    if sys.platform == "darwin":
        result = subprocess.run(
            ["/bin/ls", "-lde", str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
        first_field = result.stdout.split(maxsplit=1)[0] if result.stdout else ""
        if result.returncode != 0:
            findings.append(Finding(entry, "metadata-unreadable", "ACL inspection failed"))
        elif first_field.endswith("+"):
            findings.append(Finding(entry, "acl", "unexpected access control list"))
    return findings


def _safe_archive_name(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and ".." not in path.parts and "\\" not in name


def audit_zip(
    source: Path | BinaryIO,
    *,
    artifact_name: str | None = None,
) -> list[Finding]:
    findings: list[Finding] = []
    total_size = 0
    seen: set[str] = set()
    if isinstance(source, (str, os.PathLike)):
        display_name = artifact_name or Path(source).name
    else:
        display_name = artifact_name or "release.zip"
        source.seek(0)
    with zipfile.ZipFile(source) as archive:
        if archive.comment:
            findings.append(Finding(display_name, "zip-comment", "unexpected archive comment"))
            findings.extend(inspect_bytes(f"{display_name}:comment", archive.comment))
        for info in archive.infolist():
            name = info.filename
            if name in seen:
                findings.append(Finding(name, "duplicate-entry", "duplicate ZIP member"))
            seen.add(name)
            if not _safe_archive_name(name):
                findings.append(Finding(name, "unsafe-path", "absolute, traversal, or backslash ZIP path"))
            if info.comment:
                findings.append(Finding(name, "zip-comment", "unexpected member comment"))
                findings.extend(inspect_bytes(f"{display_name}:{name}:comment", info.comment))
            if info.extra:
                findings.append(Finding(name, "zip-extra", "unexpected member metadata"))
                findings.extend(inspect_bytes(f"{display_name}:{name}:extra", info.extra))

            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                findings.append(Finding(name, "symlink", "release ZIP entries must be regular files"))
                continue
            if info.is_dir():
                continue
            if mode and not stat.S_ISREG(mode):
                findings.append(Finding(name, "special-file", "release ZIP entry is not a regular file"))
                continue

            total_size += info.file_size
            if info.file_size > MAX_FILE_BYTES or total_size > MAX_ZIP_BYTES:
                findings.append(Finding(name, "size-limit", "release ZIP exceeds audit size limit"))
                continue
            inspect_name = f"{display_name}:{name}"
            findings.extend(inspect_bytes(inspect_name, archive.read(info)))
    if not isinstance(source, (str, os.PathLike)):
        source.seek(0)
    return findings


def audit_tree(root: Path, allowed_symlinks: set[str]) -> list[Finding]:
    findings: list[Finding] = []
    if root.is_symlink():
        return [Finding(str(root), "symlink-root", "audit root must not be a symlink")]
    if not root.is_dir():
        return [Finding(str(root), "not-directory", "expected an artifact directory")]

    findings.extend(inspect_metadata(".", root))
    root_mode = root.lstat().st_mode
    if root_mode & (stat.S_IWGRP | stat.S_IWOTH):
        findings.append(Finding(".", "unsafe-mode", "group/world-writable artifact root"))

    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        for name in list(directories) + files:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            try:
                mode = path.lstat().st_mode
            except OSError as error:
                findings.append(Finding(relative, "unreadable", type(error).__name__))
                continue

            findings.extend(inspect_metadata(relative, path))

            if stat.S_ISLNK(mode):
                if relative not in allowed_symlinks:
                    findings.append(Finding(relative, "symlink", "unexpected symbolic link"))
                elif os.readlink(path) != "/Applications":
                    findings.append(Finding(relative, "symlink-target", "allowed link has an unexpected target"))
                if name in directories:
                    directories.remove(name)
                continue
            if mode & (stat.S_IWGRP | stat.S_IWOTH):
                findings.append(Finding(relative, "unsafe-mode", "group/world-writable artifact entry"))
            if mode & (stat.S_ISUID | stat.S_ISGID):
                findings.append(Finding(relative, "privileged-mode", "setuid/setgid artifact entry"))
            if stat.S_ISDIR(mode):
                continue
            if not stat.S_ISREG(mode):
                findings.append(Finding(relative, "special-file", "artifact entry is not a regular file"))
                continue
            if path.stat().st_size > MAX_FILE_BYTES:
                findings.append(Finding(relative, "size-limit", "artifact file exceeds audit size limit"))
                continue
            try:
                findings.extend(inspect_bytes(relative, path.read_bytes()))
            except OSError as error:
                findings.append(Finding(relative, "unreadable", type(error).__name__))
    return findings


def audit_path(path: Path, allowed_symlinks: set[str]) -> list[Finding]:
    if path.is_symlink():
        return [Finding(str(path), "symlink-root", "artifact path must not be a symlink")]
    if path.suffix.lower() == ".zip":
        return inspect_metadata(path.name, path) + audit_zip(path)
    if path.suffix.lower() == ".dmg":
        # Compressed disk-image bytes are not text and can randomly resemble
        # email/token patterns. A DMG must instead be verified, mounted
        # read-only, and passed back through audit_tree by the packager.
        return inspect_metadata(path.name, path) + [
            Finding(path.name, "unexpanded-disk-image", "mount and audit the DMG payload")
        ]
    if path.is_dir():
        return audit_tree(path, allowed_symlinks)
    if path.is_file():
        findings = inspect_metadata(path.name, path)
        if path.stat().st_size > MAX_FILE_BYTES:
            findings.append(Finding(path.name, "size-limit", "artifact file exceeds audit size limit"))
            return findings
        findings.extend(inspect_bytes(path.name, path.read_bytes()))
        return findings
    return [Finding(str(path), "missing", "artifact does not exist")]


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit release payloads for secrets, PII, and unsafe entries")
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument(
        "--allow-symlink",
        action="append",
        default=[],
        help="Allow an exact relative /Applications link (DMG staging only)",
    )
    parser.add_argument(
        "--metadata-only",
        action="store_true",
        help="Audit filesystem metadata without interpreting the file payload",
    )
    args = parser.parse_args()

    allowed_symlinks = set(args.allow_symlink)
    findings = [
        finding
        for path in args.paths
        for finding in (
            inspect_metadata(path.name, path)
            if args.metadata_only
            else audit_path(path, allowed_symlinks)
        )
    ]
    payload = {
        "ok": not findings,
        "paths": [str(path) for path in args.paths],
        "findings": [asdict(finding) for finding in findings],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if not findings else 2


if __name__ == "__main__":
    sys.exit(main())
