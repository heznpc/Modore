#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build and validate release zip artifacts for PC Health Check.

This script is intentionally dependency-free. It creates OS-specific zip files
from an allowlist so local scan artifacts, caches, and user config byproducts
cannot accidentally ship in a release.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import zipfile
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path
from typing import BinaryIO, Iterator, NamedTuple

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    # Python isolated mode intentionally omits the script directory. Import only
    # the sibling auditor from this resolved, repository-controlled directory.
    sys.path.insert(0, str(SCRIPT_DIR))

from artifact_audit import audit_zip, inspect_bytes


PROJECT_ROOT = SCRIPT_DIR.parent
VERSION = "0.3.0"
DIST_DIR = Path(os.environ.get("PCH_DISTRIBUTION_DIR", PROJECT_ROOT / "dist")).expanduser()


def trusted_git_executable() -> Path | None:
    """Return Git only from a fixed operating-system installation path."""
    candidates = (
        (
            Path("C:/Program Files/Git/cmd/git.exe"),
            Path("C:/Program Files/Git/bin/git.exe"),
            Path("C:/Program Files (x86)/Git/cmd/git.exe"),
        )
        if os.name == "nt"
        else (Path("/usr/bin/git"),)
    )
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    return None


GIT_EXECUTABLE = trusted_git_executable()
RELEASE_SIGNER_PRINCIPAL = "heznpc"


class ReleaseSigner(NamedTuple):
    principal: str
    fingerprint: str
    public_key: str


class FileSeal(NamedTuple):
    device: int
    inode: int
    size: int
    sha256: str


class FileEntryIdentity(NamedTuple):
    device: int
    inode: int
    file_type: int


EXPECTED_SIGNED_TAG: ContextVar[str | None] = ContextVar(
    "expected_signed_tag", default=None
)


def git_environment() -> dict[str, str]:
    """Build a minimal environment that cannot inherit user Git configuration."""
    if os.name == "nt":
        system_path = (
            r"C:\Windows\System32;C:\Windows;"
            r"C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0"
        )
    else:
        system_path = "/usr/bin:/bin:/usr/sbin:/sbin"
    return {
        "PATH": system_path,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "LC_ALL": "C",
    }


def run_git(
    *arguments: str,
    text: bool = False,
    check: bool = False,
) -> subprocess.CompletedProcess:
    """Run the trusted Git binary with fixed config and no ambient environment."""
    if GIT_EXECUTABLE is None:
        raise FileNotFoundError("trusted Git executable is unavailable")
    options: dict = {
        "capture_output": True,
        "check": check,
        "env": git_environment(),
    }
    if text:
        options.update({"text": True, "encoding": "utf-8"})
    return subprocess.run(
        [
            str(GIT_EXECUTABLE),
            "--no-replace-objects",
            "-c",
            "core.fsmonitor=false",
            "-C",
            str(PROJECT_ROOT),
            *arguments,
        ],
        **options,
    )


def python_is_isolated() -> bool:
    return bool(sys.flags.isolated)


def release_signer_environment_is_complete() -> bool:
    return bool(os.environ.get("PCH_RELEASE_SIGNER_PUBLIC_KEY")) and bool(
        os.environ.get("PCH_RELEASE_SIGNER_SHA256")
    )


@contextmanager
def trusted_release_signer() -> Iterator[ReleaseSigner | None]:
    public_key = os.environ.get("PCH_RELEASE_SIGNER_PUBLIC_KEY", "").strip()
    expected_fingerprint = os.environ.get("PCH_RELEASE_SIGNER_SHA256", "").strip()
    if not public_key and not expected_fingerprint:
        yield None
        return
    if not public_key or not expected_fingerprint:
        raise RuntimeError(
            "PCH_RELEASE_SIGNER_PUBLIC_KEY and PCH_RELEASE_SIGNER_SHA256 must be set together"
        )
    if "\n" in public_key or "\r" in public_key or len(public_key.split()) != 2:
        raise RuntimeError("release signer public key must contain only key type and key data")
    if not re.fullmatch(r"SHA256:[A-Za-z0-9+/]{43}", expected_fingerprint):
        raise RuntimeError("PCH_RELEASE_SIGNER_SHA256 is not an OpenSSH SHA-256 fingerprint")
    ssh_keygen = Path("/usr/bin/ssh-keygen")
    if not ssh_keygen.is_file() or not os.access(ssh_keygen, os.X_OK):
        raise RuntimeError("trusted /usr/bin/ssh-keygen is unavailable")

    fingerprint_result = subprocess.run(
        [str(ssh_keygen), "-E", "sha256", "-lf", "-"],
        input=public_key + "\n",
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
        timeout=10,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
    )
    fingerprint_fields = fingerprint_result.stdout.split()
    actual_fingerprint = fingerprint_fields[1] if len(fingerprint_fields) >= 2 else ""
    if fingerprint_result.returncode != 0 or actual_fingerprint != expected_fingerprint:
        raise RuntimeError("release signer public key does not match expected SHA-256 fingerprint")
    yield ReleaseSigner(
        principal=RELEASE_SIGNER_PRINCIPAL,
        fingerprint=expected_fingerprint,
        public_key=public_key,
    )


def signed_tag_payload_has_expected_name(payload: bytes, expected_tag: str) -> bool:
    try:
        expected_tag_bytes = expected_tag.encode("ascii")
    except UnicodeEncodeError:
        return False
    if not re.fullmatch(rb"v[0-9]+\.[0-9]+\.[0-9]+", expected_tag_bytes):
        return False

    header_end = payload.find(b"\n\n")
    if header_end <= 0:
        return False
    headers: list[tuple[bytes, bytes]] = []
    for line in payload[:header_end].split(b"\n"):
        key, separator, value = line.partition(b" ")
        if (
            separator != b" "
            or not value
            or b"\x00" in value
            or b"\r" in value
            or re.fullmatch(rb"[a-z][a-z0-9-]*", key) is None
        ):
            return False
        headers.append((key, value))

    tag_headers = [value for key, value in headers if key == b"tag"]
    return len(tag_headers) == 1 and tag_headers[0] == expected_tag_bytes


def verify_tag_with_signer(
    tag_object_id: str,
    signer: ReleaseSigner,
    *,
    expected_tag: str | None = None,
) -> bool:
    expected_tag = expected_tag if expected_tag is not None else EXPECTED_SIGNED_TAG.get()
    if expected_tag is None:
        return False
    tag = run_git("cat-file", "tag", tag_object_id)
    marker = b"-----BEGIN SSH SIGNATURE-----"
    marker_with_boundary = b"\n" + marker
    marker_boundary_offset = tag.stdout.rfind(marker_with_boundary)
    if tag.returncode != 0 or marker_boundary_offset <= 0:
        return False
    marker_offset = marker_boundary_offset + 1
    payload = tag.stdout[:marker_offset]
    signature = tag.stdout[marker_offset:]
    signature_end = b"-----END SSH SIGNATURE-----"
    normalized_signature = signature[:-1] if signature.endswith(b"\n") else signature
    if (
        not signed_tag_payload_has_expected_name(payload, expected_tag)
        or not normalized_signature.startswith(marker + b"\n")
        or not normalized_signature.endswith(signature_end)
        or normalized_signature.count(marker) != 1
        or normalized_signature.count(signature_end) != 1
    ):
        return False
    with tempfile.TemporaryFile(mode="w+b") as allowed_signers, tempfile.TemporaryFile(
        mode="w+b"
    ) as signature_file:
        os.fchmod(allowed_signers.fileno(), 0o400)
        allowed_signers.write(
            f"{signer.principal} {signer.public_key}\n".encode("utf-8")
        )
        allowed_signers.flush()
        os.fsync(allowed_signers.fileno())
        allowed_signers.seek(0)
        signature_file.write(signature)
        signature_file.flush()
        os.fsync(signature_file.fileno())
        signature_file.seek(0)
        result = subprocess.run(
            [
                "/usr/bin/ssh-keygen",
                "-Y",
                "verify",
                "-f",
                f"/dev/fd/{allowed_signers.fileno()}",
                "-I",
                signer.principal,
                "-n",
                "git",
                "-s",
                f"/dev/fd/{signature_file.fileno()}",
            ],
            input=payload,
            capture_output=True,
            check=False,
            timeout=10,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
            pass_fds=(allowed_signers.fileno(), signature_file.fileno()),
        )
        return result.returncode == 0


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


FileSource = Path | BinaryIO


def rewind_file_source(source: FileSource) -> None:
    if not isinstance(source, (str, os.PathLike)):
        source.seek(0)


def sha256_file(source: FileSource) -> str:
    h = hashlib.sha256()
    if isinstance(source, (str, os.PathLike)):
        stream = Path(source).open("rb")
        close_stream = True
    else:
        source.seek(0)
        stream = source
        close_stream = False
    try:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    finally:
        if close_stream:
            stream.close()
        else:
            source.seek(0)
    return h.hexdigest()


def source_state(version: str) -> dict:
    unavailable = {
        "repository": False,
        "commit": None,
        "tag": None,
        "tagObjectID": None,
        "tagSignatureVerified": False,
        "tagSignerPrincipal": None,
        "tagSignerFingerprint": None,
        "clean": False,
    }
    if GIT_EXECUTABLE is None:
        return unavailable

    def git(*arguments: str) -> subprocess.CompletedProcess[str]:
        return run_git(*arguments, text=True)

    probe = git("rev-parse", "--is-inside-work-tree")
    if probe.returncode != 0 or probe.stdout.strip() != "true":
        return unavailable
    replace_refs = git("replace", "-l")
    if replace_refs.returncode != 0:
        raise RuntimeError("cannot verify that Git replace refs are absent")
    if replace_refs.stdout.strip():
        raise RuntimeError("release tooling refuses repositories with Git replace refs")

    commit = git("rev-parse", "HEAD").stdout.strip()
    status = git("status", "--porcelain", "--untracked-files=all")
    clean = status.returncode == 0 and not status.stdout.strip()
    expected_tag = f"v{version}"
    expected_tag_ref = f"refs/tags/{expected_tag}"
    tag_object = git("rev-parse", "--verify", expected_tag_ref)
    candidate_tag_object_id = tag_object.stdout.strip().lower()
    tag_object_id = (
        candidate_tag_object_id
        if tag_object.returncode == 0
        and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", candidate_tag_object_id)
        else None
    )
    tagged_commit = (
        git("rev-parse", "--verify", f"{tag_object_id}^{{commit}}")
        if tag_object_id
        else None
    )
    tag_points_to_head = (
        tagged_commit is not None
        and tagged_commit.returncode == 0
        and tagged_commit.stdout.strip() == commit
    )
    tag = expected_tag if tag_points_to_head else None
    tag_object_type = git("cat-file", "-t", tag_object_id) if tag_object_id else None
    tag_signature_verified = False
    tag_signer_principal = None
    tag_signer_fingerprint = None
    with trusted_release_signer() as signer:
        signature_matches_expected_tag = False
        if (
            signer
            and tag_points_to_head
            and tag_object_type
            and tag_object_type.returncode == 0
            and tag_object_type.stdout.strip() == "tag"
        ):
            token = EXPECTED_SIGNED_TAG.set(expected_tag)
            try:
                signature_matches_expected_tag = verify_tag_with_signer(
                    tag_object_id, signer
                )
            finally:
                EXPECTED_SIGNED_TAG.reset(token)
        if signer and signature_matches_expected_tag:
            tag_signature_verified = True
            tag_signer_principal = signer.principal
            tag_signer_fingerprint = signer.fingerprint
    return {
        "repository": True,
        "commit": commit or None,
        "tag": tag,
        "tagObjectID": tag_object_id,
        "tagSignatureVerified": tag_signature_verified,
        "tagSignerPrincipal": tag_signer_principal,
        "tagSignerFingerprint": tag_signer_fingerprint,
        "clean": clean,
    }


def git_bytes(commit: str, rel: str) -> bytes:
    result = run_git("show", f"{commit}:{rel}")
    if result.returncode != 0:
        raise FileNotFoundError(f"release entry missing from {commit[:12]}: {rel}")
    return result.stdout


def git_entry_mode(commit: str, rel: str) -> str:
    result = run_git("ls-tree", "-z", commit, "--", rel)
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


def file_entry_identity(path: Path) -> FileEntryIdentity:
    metadata = path.lstat()
    return FileEntryIdentity(
        device=metadata.st_dev,
        inode=metadata.st_ino,
        file_type=stat.S_IFMT(metadata.st_mode),
    )


def seal_open_regular_file(descriptor: int) -> FileSeal:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode):
        raise ValueError("release artifact descriptor must be a regular file")
    digest = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    for chunk in iter(lambda: os.read(descriptor, 1024 * 1024), b""):
        digest.update(chunk)
    after = os.fstat(descriptor)
    os.lseek(descriptor, 0, os.SEEK_SET)
    identity_before = (before.st_dev, before.st_ino, before.st_size)
    identity_after = (after.st_dev, after.st_ino, after.st_size)
    if identity_before != identity_after:
        raise RuntimeError("release artifact changed while its descriptor was sealed")
    return FileSeal(*identity_after, digest.hexdigest())


def seal_regular_file(path: Path) -> FileSeal:
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        sealed = seal_open_regular_file(descriptor)
        entry = path.lstat()
        identity_at_path = (entry.st_dev, entry.st_ino, entry.st_size)
        if (
            (sealed.device, sealed.inode, sealed.size) != identity_at_path
            or not stat.S_ISREG(entry.st_mode)
        ):
            raise RuntimeError(f"release artifact changed while it was sealed: {path}")
        return sealed
    finally:
        os.close(descriptor)


def rename_entry_noreplace(
    source_directory: int,
    source_name: str,
    recovery_directory: int,
    recovery_name: str,
) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        rename_function = libc.renameatx_np
        rename_flags = 0x00000004  # RENAME_EXCL
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        rename_function = libc.renameat2
        rename_flags = 0x00000001  # RENAME_NOREPLACE
    else:
        raise OSError(errno.ENOTSUP, "atomic no-replace rename is unavailable")
    rename_function.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    rename_function.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = rename_function(
        source_directory,
        os.fsencode(source_name),
        recovery_directory,
        os.fsencode(recovery_name),
        rename_flags,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def preserve_entry_for_review(
    path: Path,
    expected: FileEntryIdentity,
) -> tuple[bool, Path | None]:
    """Move an entry out of its public name without deleting any pathname."""
    try:
        path.lstat()
    except FileNotFoundError:
        return True, None

    recovery_directory = Path(
        tempfile.mkdtemp(prefix=".pch-release-recovery.", dir=path.parent)
    )
    recovery_path: Path | None = None
    try:
        if os.name == "nt":
            for _ in range(32):
                recovery_path = recovery_directory / (
                    f"{path.name}.{secrets.token_hex(12)}.preserved"
                )
                try:
                    path.rename(recovery_path)
                    break
                except FileExistsError:
                    continue
            else:
                return False, recovery_path
        else:
            directory_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
            directory_flags |= getattr(os, "O_DIRECTORY", 0)
            directory_flags |= getattr(os, "O_NOFOLLOW", 0)
            source_directory = os.open(path.parent, directory_flags)
            recovery_descriptor = os.open(recovery_directory, directory_flags)
            try:
                for _ in range(32):
                    recovery_name = (
                        f"{path.name}.{secrets.token_hex(12)}.preserved"
                    )
                    try:
                        rename_entry_noreplace(
                            source_directory,
                            path.name,
                            recovery_descriptor,
                            recovery_name,
                        )
                        recovery_path = recovery_directory / recovery_name
                        break
                    except FileExistsError:
                        continue
                else:
                    return False, recovery_path
            finally:
                os.close(recovery_descriptor)
                os.close(source_directory)
    except FileNotFoundError:
        return True, recovery_path
    except OSError:
        return False, recovery_path
    if recovery_path is None:
        return False, None
    try:
        return file_entry_identity(recovery_path) == expected, recovery_path
    except (FileNotFoundError, OSError):
        return False, recovery_path


def discard_preserved_entry(
    recovery_path: Path | None,
    expected: FileEntryIdentity,
) -> None:
    """Remove only the exact private recovery entry created by this run."""
    if recovery_path is None:
        return
    try:
        current = file_entry_identity(recovery_path)
    except (FileNotFoundError, OSError) as error:
        raise RuntimeError(
            f"preserved release entry disappeared before cleanup: {recovery_path}"
        ) from error
    if current != expected:
        raise RuntimeError(
            f"preserved release entry changed before cleanup: {recovery_path}"
        )
    recovery_directory = recovery_path.parent
    try:
        recovery_path.unlink()
        recovery_directory.rmdir()
    except OSError as error:
        raise RuntimeError(
            f"could not remove verified release recovery entry: {recovery_path}"
        ) from error


def materialize_snapshot(
    destination: Path,
    snapshot: BinaryIO,
    *,
    expected_sha256: str,
) -> tuple[Path, int, FileSeal]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_path = tempfile.mkstemp(
        prefix=f".{destination.name}.",
        suffix=".partial",
        dir=destination.parent,
    )
    temporary = Path(raw_path)
    initial = os.fstat(descriptor)
    initial_entry = FileEntryIdentity(initial.st_dev, initial.st_ino, stat.S_IFREG)
    try:
        snapshot.seek(0)
        while True:
            chunk = snapshot.read(1024 * 1024)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise OSError("short write while materializing release artifact")
                view = view[written:]
        snapshot.seek(0)
        os.fsync(descriptor)
        if sys.platform == "darwin":
            descriptor_path = f"/dev/fd/{descriptor}"
            environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"}
            for command in (
                ["/usr/bin/xattr", "-c", descriptor_path],
                ["/bin/chmod", "-N", descriptor_path],
            ):
                subprocess.run(
                    command,
                    check=True,
                    capture_output=True,
                    env=environment,
                    pass_fds=(descriptor,),
                )
            attributes = subprocess.run(
                ["/usr/bin/xattr", descriptor_path],
                check=True,
                capture_output=True,
                env=environment,
                pass_fds=(descriptor,),
            )
            os.fchmod(descriptor, 0o644)
            access = subprocess.run(
                ["/bin/ls", "-Llde", descriptor_path],
                check=True,
                capture_output=True,
                text=True,
                encoding="utf-8",
                env=environment,
                pass_fds=(descriptor,),
            )
            first_field = access.stdout.split(maxsplit=1)[0] if access.stdout else ""
            attribute_names = set(attributes.stdout.decode("utf-8").splitlines())
            if attribute_names - {"com.apple.provenance"} or first_field.endswith("+"):
                raise RuntimeError("staged release artifact has unexpected metadata")
        else:
            os.fchmod(descriptor, 0o644)
        sealed = seal_open_regular_file(descriptor)
        entry = temporary.lstat()
        if (
            (entry.st_dev, entry.st_ino, entry.st_size)
            != (sealed.device, sealed.inode, sealed.size)
            or not stat.S_ISREG(entry.st_mode)
            or sealed.sha256 != expected_sha256
        ):
            raise RuntimeError("staged release artifact is not the audited snapshot")
        return temporary, descriptor, sealed
    except Exception:
        os.close(descriptor)
        preserve_entry_for_review(temporary, initial_entry)
        raise


def publish_new_file(
    temporary: Path,
    descriptor: int,
    destination: Path,
    *,
    audited_seal: FileSeal,
) -> None:
    published_entry: FileEntryIdentity | None = None
    if seal_open_regular_file(descriptor) != audited_seal:
        raise RuntimeError("release artifact changed after content audit")
    if seal_regular_file(temporary) != audited_seal:
        raise RuntimeError("staged pathname no longer names the audited descriptor")
    try:
        link_options = (
            {"follow_symlinks": False}
            if os.link in os.supports_follow_symlinks
            else {}
        )
        os.link(temporary, destination, **link_options)
        published_entry = file_entry_identity(destination)
        if (
            seal_open_regular_file(descriptor) != audited_seal
            or seal_regular_file(temporary) != audited_seal
            or seal_regular_file(destination) != audited_seal
        ):
            raise RuntimeError("published release artifact is not the audited file")
        temporary_entry = FileEntryIdentity(
            audited_seal.device, audited_seal.inode, stat.S_IFREG
        )
        staged_matches, staged_recovery = preserve_entry_for_review(
            temporary, temporary_entry
        )
        if not staged_matches:
            raise RuntimeError(
                "staged release artifact changed before preservation: "
                f"{staged_recovery or temporary}"
            )
        if seal_regular_file(destination) != audited_seal:
            raise RuntimeError("published release artifact changed after preservation")
        discard_preserved_entry(staged_recovery, temporary_entry)
    except FileExistsError as error:
        raise FileExistsError(f"refusing to overwrite release artifact: {destination}") from error
    except Exception:
        if published_entry is not None:
            published_matches, published_recovery = preserve_entry_for_review(
                destination, published_entry
            )
            if not published_matches:
                raise RuntimeError(
                    "published artifact changed and was retained for recovery: "
                    f"{published_recovery or destination}"
                )
        raise
    finally:
        temporary_entry = FileEntryIdentity(
            audited_seal.device, audited_seal.inode, stat.S_IFREG
        )
        preserve_entry_for_review(temporary, temporary_entry)


def build_zip(
    name: str,
    files: list[str],
    executable_entries: set[str],
    *,
    output_dir: Path | None = None,
    source_commit: str | None = None,
    publication_seals: dict[Path, FileSeal] | None = None,
) -> Path:
    assert_clean_file_list(files, source_commit=source_commit)
    output_dir = output_dir or DIST_DIR
    zip_path = output_dir / f"{name}.zip"
    if zip_path.exists() or zip_path.is_symlink():
        raise FileExistsError(f"refusing to overwrite release artifact: {zip_path}")
    root_name = name
    with tempfile.TemporaryFile(mode="w+b") as snapshot:
        with zipfile.ZipFile(snapshot, "w") as zf:
            for rel in files:
                add_file(
                    zf,
                    rel,
                    root_name,
                    executable=rel in executable_entries,
                    source_commit=source_commit,
                )
        snapshot.flush()
        os.fsync(snapshot.fileno())
        validation = validate_zip(snapshot, artifact_name=zip_path.name)
        temporary, descriptor, audited_seal = materialize_snapshot(
            zip_path,
            snapshot,
            expected_sha256=validation["sha256"],
        )
        try:
            publish_new_file(
                temporary,
                descriptor,
                zip_path,
                audited_seal=audited_seal,
            )
            if publication_seals is not None:
                publication_seals[zip_path] = audited_seal
        finally:
            os.close(descriptor)
    return zip_path


def validate_zip(source: FileSource, artifact_name: str | None = None) -> dict:
    display_name = artifact_name or (
        Path(source).name if isinstance(source, (str, os.PathLike)) else "release.zip"
    )
    rewind_file_source(source)
    with zipfile.ZipFile(source) as zf:
        names = zf.namelist()
        forbidden = [n for n in names if Path(n).name in FORBIDDEN_NAMES or "__pycache__" in n]
        if forbidden:
            raise ValueError(f"{display_name} contains forbidden entries: {forbidden}")
        command_entries = [i for i in zf.infolist() if i.filename.endswith(".command")]
        for info in command_entries:
            mode = (info.external_attr >> 16) & 0o777
            if mode & 0o111 == 0:
                raise ValueError(f"{info.filename} is not executable in {display_name}")
    rewind_file_source(source)
    findings = audit_zip(source, artifact_name=display_name)
    if findings:
        details = ", ".join(f"{item.rule}:{item.entry}" for item in findings)
        raise ValueError(f"{display_name} failed artifact audit: {details}")
    return {
        "file": display_name,
        "entries": len(names),
        "sha256": sha256_file(source),
        "audit": {"secrets": True, "pii": True, "symlinks": True},
    }


def swift_files_from_commit(commit: str) -> list[str]:
    result = run_git("ls-tree", "-r", "-z", "--name-only", commit, check=True)
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
    payload = text.encode("utf-8")
    findings = inspect_bytes(destination.name, payload)
    if findings:
        details = ", ".join(f"{item.rule}:{item.entry}" for item in findings)
        raise ValueError(f"release manifest failed artifact audit: {details}")
    with tempfile.TemporaryFile(mode="w+b") as snapshot:
        snapshot.write(payload)
        snapshot.flush()
        os.fsync(snapshot.fileno())
        snapshot.seek(0)
        temporary, descriptor, audited_seal = materialize_snapshot(
            destination,
            snapshot,
            expected_sha256=hashlib.sha256(payload).hexdigest(),
        )
        try:
            publish_new_file(
                temporary,
                descriptor,
                destination,
                audited_seal=audited_seal,
            )
        finally:
            os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build and validate release zips")
    parser.add_argument("--check-only", action="store_true", help="validate source allowlists without writing zips")
    parser.add_argument(
        "--release",
        action="store_true",
        help=(
            "require clean HEAD at an exact verified signed annotated v<version> tag "
            "before writing publishable source artifacts"
        ),
    )
    parser.add_argument("--version", default=VERSION, help="artifact version (default: %(default)s)")
    args = parser.parse_args()

    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        parser.error("--version must be a numeric X.Y.Z release version")
    if args.release and args.check_only:
        parser.error("--release cannot be combined with --check-only")
    if args.release and not python_is_isolated():
        parser.error("--release requires Python isolated mode; run with python3 -I -B")
    if args.release and not release_signer_environment_is_complete():
        parser.error(
            "--release requires PCH_RELEASE_SIGNER_PUBLIC_KEY and PCH_RELEASE_SIGNER_SHA256"
        )

    state = source_state(args.version)
    if args.release and not (
        state["repository"]
        and state["clean"]
        and state["tag"]
        and state["tagObjectID"]
        and state["tagSignatureVerified"]
        and state["tagSignerPrincipal"] == RELEASE_SIGNER_PRINCIPAL
        and state["tagSignerFingerprint"]
        == os.environ["PCH_RELEASE_SIGNER_SHA256"].strip()
    ):
        raise RuntimeError(
            "release requires clean HEAD at an exact verified signed annotated "
            f"tag v{args.version}"
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

    publication_seals: dict[Path, FileSeal] = {}
    created: list[tuple[Path, FileSeal]] = []
    try:
        win = build_zip(
            win_name,
            WINDOWS_FILES,
            executable_entries=set(),
            output_dir=output_dir,
            source_commit=source_commit,
            publication_seals=publication_seals,
        )
        win_seal = publication_seals.get(win)
        if win_seal is None:
            win_seal = seal_regular_file(win)
        created.append((win, win_seal))
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
            publication_seals=publication_seals,
        )
        mac_seal = publication_seals.get(mac)
        if mac_seal is None:
            mac_seal = seal_regular_file(mac)
        created.append((mac, mac_seal))
        if args.release and source_state(version) != state:
            raise RuntimeError("source checkout changed while release ZIPs were being built")
        win_validation = validate_zip(win)
        mac_validation = validate_zip(mac)
        if (
            seal_regular_file(win) != win_seal
            or win_validation["sha256"] != win_seal.sha256
            or seal_regular_file(mac) != mac_seal
            or mac_validation["sha256"] != mac_seal.sha256
        ):
            raise RuntimeError("published release ZIP changed before manifest creation")
        manifest = {
            "version": version,
            "publishable": args.release,
            "source": state,
            "artifacts": [win_validation, mac_validation],
        }
        write_new_text(
            manifest_path,
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        )
    except Exception as error:
        unsafe_cleanup = []
        for path, seal in created:
            identity = FileEntryIdentity(seal.device, seal.inode, stat.S_IFREG)
            matches, recovery = preserve_entry_for_review(path, identity)
            if not matches:
                unsafe_cleanup.append(str(recovery or path))
        if unsafe_cleanup:
            raise RuntimeError(
                "changed release artifacts were retained after failure: "
                + ", ".join(unsafe_cleanup)
            ) from error
        raise
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
