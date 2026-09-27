#!/usr/bin/env python3
"""Explicit, local recovery bundles for supported AI record stores.

This command never deletes source data, reads credentials, follows source links,
contacts a service, or resumes an AI session. A bundle contains records, not a
Git repository backup. Plan outputs metadata only; backup requires explicit raw
content consent. SQLite files are online, read-only-source snapshots, not a copy
of a possibly inconsistent database/WAL pair.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import signal
import sqlite3
import stat
import sys
import time
from typing import Any
import unicodedata
from urllib.parse import quote

SCHEMA = 1
FORMAT = "modore-session-recovery"
RESTORED_MANIFEST = ".modore-recovery-manifest.json"
CHUNK = 1024 * 1024
MAX_FILES = 500_000
MAX_MANIFEST = 128 * 1024 * 1024
MAX_METADATA = 1024 * 1024
SQLITE_TIMEOUT = 30.0
O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
EXCLUDED_NAMES = {
    ".git", "node_modules", ".build", "__pycache__", "runtime", "runtimes",
    "cache", "caches", "vm", "vms", "auth.json", "credentials.json",
    "credentials", ".credentials.json", "config.toml", ".env", ".npmrc",
    "settings.json", "settings.local.json", "session-env",
}
EXCLUDED_SUFFIXES = (".qcow2", ".vmdk", ".vhd", ".vhdx", ".sparseimage",
                     ".sparsebundle", ".p8", ".p12", ".pfx")
DATABASE_NAME = re.compile(
    r"^(?:state|thread_history|queue|memories|goals|logs)_[0-9]+\.sqlite$")
PROVIDERS = ("Codex", "Claude Code", "Claude Desktop")
ROOTS = (
    ("codex.sessions", "Codex", "Current session records", ".codex/sessions"),
    ("codex.archived", "Codex", "Archived session records", ".codex/archived_sessions"),
    ("codex.index", "Codex", "Session index", ".codex/session_index.jsonl"),
    ("codex.history", "Codex", "Prompt history", ".codex/history.jsonl"),
    ("codex.attachments", "Codex", "Owned attachments", ".codex/attachments"),
    ("codex.uploads", "Codex", "Owned uploads", ".codex/uploads"),
    ("codex.images", "Codex", "Owned images", ".codex/images"),
    ("claude.projects", "Claude Code", "Session records and owned sidecars", ".claude/projects"),
    ("claude.history", "Claude Code", "Prompt history", ".claude/history.jsonl"),
    ("claude.file-history", "Claude Code", "File snapshots", ".claude/file-history"),
    ("claude.image-cache", "Claude Code", "Session image attachments", ".claude/image-cache"),
    ("claude.uploads", "Claude Code", "Owned uploads", ".claude/uploads"),
    ("claude.todos", "Claude Code", "Session todo records", ".claude/todos"),
    ("claude.tasks", "Claude Code", "Session task records", ".claude/tasks"),
    ("claude.plans", "Claude Code", "Session plans", ".claude/plans"),
    ("desktop.local-agent", "Claude Desktop", "Local Code conversation units",
     "Library/Application Support/Claude/local-agent-mode-sessions"),
    ("desktop.code", "Claude Desktop", "Local Claude Code sessions",
     "Library/Application Support/Claude/claude-code-sessions"),
)
EXCLUSIONS = [
    "Git working directories and repository history outside these record stores",
    "Authentication files, credentials, configuration, settings and environment files",
    "node_modules, build/runtime caches, virtual-machine images and embedded .git directories",
    "SQLite WAL/SHM files as raw files (their committed data are captured by SQLite backup)",
    "External symlink targets and externally referenced or temporary attachments",
    "Claude Desktop shared Electron login/browser stores and cloud-only conversations",
    "Gemini and IDE session stores: unsupported in this recovery version",
]
WARNINGS = [
    "Git linkage describes a workspace relationship, not remote preservation of a session.",
    "This is an explicit local backup, not an automatic or encrypted backup.",
    "External/temporary attachments and linked files are not followed; their contents may be absent.",
    "All files present in the selected supported stores are considered; omitted or unavailable items are not backed up.",
    "Provider stores and separate SQLite databases are captured sequentially, not in one cross-store transaction.",
    "Verified bytes do not prove that a provider application can resume a session. Install/login and session import or resume preparation may still be required.",
    "Claude Desktop support covers local Code records, not cloud-only chats or a complete application profile.",
    "Project code, Git history (.git), uncommitted work and ignored project files are not included; back up project folders separately.",
    "Only the standard stores under the selected home are supported; custom CODEX_HOME/CLAUDE_CONFIG_DIR stores are not discovered.",
    "Coverage counts only recognizable session metadata and is not a guarantee that every provider record can be resumed.",
    "Planned sizes are estimates; SQLite snapshots can include additional committed WAL data.",
    "File bytes, links, permission bits and file timestamps are preserved; ownership, ACLs and extended attributes are not restored.",
]


class RecoveryError(ValueError):
    pass


class RecoveryCancelled(KeyboardInterrupt):
    """Bypasses per-record error recovery while preserving cleanup finally blocks."""


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _relative(value: str) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "\0" in value:
        raise RecoveryError("invalid relative path")
    parts = value.split("/")
    if value.startswith("/") or any(p in ("", ".", "..") for p in parts):
        raise RecoveryError("unsafe relative path")
    if len(parts) > 128 or any(len(p.encode("utf-8")) > 255 for p in parts):
        raise RecoveryError("path exceeds supported limits")
    return str(PurePosixPath(value))


def _absolute(value: Path) -> Path:
    # Do not silently normalize a user-supplied traversal spelling.
    if ".." in Path(os.path.expanduser(str(value))).parts:
        raise RecoveryError("path traversal is not supported")
    return Path(os.path.abspath(os.path.expanduser(str(value))))


def _signature(info: os.stat_result) -> tuple:
    return (info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode), info.st_size,
            info.st_mtime_ns, info.st_ctime_ns, info.st_nlink)


def _identity(info: os.stat_result) -> tuple:
    return (info.st_dev, info.st_ino)


def _open_dir(path: Path, *, create: bool = False) -> int:
    """Open every component without following links, returning an owned fd."""
    path = _absolute(path)
    fd = os.open("/", os.O_RDONLY | O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            if component in (".", ".."):
                raise RecoveryError("unsafe directory component")
            if create:
                try:
                    os.mkdir(component, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(component, os.O_RDONLY | O_DIRECTORY | NOFOLLOW,
                            dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


@contextlib.contextmanager
def _parent_fd(root_fd: int, relative: str, *, create: bool = False):
    parts = _relative(relative).split("/")
    fd = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            nxt = os.open(part, os.O_RDONLY | O_DIRECTORY | NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        yield fd, parts[-1]
    finally:
        os.close(fd)


def _excluded(relative: str) -> bool:
    for component in PurePosixPath(relative).parts:
        low = component.casefold()
        if (low in EXCLUDED_NAMES or low.startswith(".env.")
                or low.endswith(EXCLUDED_SUFFIXES)):
            return True
    return False


def _is_database(relative: str) -> bool:
    name = PurePosixPath(relative).name.lower()
    return name.endswith((".sqlite", ".sqlite3", ".db"))


def _allowed(relative: str) -> bool:
    relative = _relative(relative)
    if _excluded(relative):
        return False
    if any(relative == r or relative.startswith(r + "/") for _, _, _, r in ROOTS):
        return True
    path = PurePosixPath(relative)
    if path.parent == PurePosixPath(".codex") and DATABASE_NAME.fullmatch(path.name):
        return True
    return (len(path.parts) == 3 and path.parts[:2] == (".codex", "sqlite")
            and _is_database(relative))


def _provider(relative: str) -> str:
    if relative.startswith(".codex/"):
        return "Codex"
    if relative.startswith(".claude/"):
        return "Claude Code"
    return "Claude Desktop"


def _home(home: Path) -> Path:
    original = Path(os.path.expanduser(str(home)))
    if ".." in original.parts or original.is_symlink():
        raise RecoveryError("home must be a real directory without traversal")
    home = _absolute(original)
    fd = _open_dir(home)
    os.close(fd)
    return home


def _db_roots(home: Path) -> list[str]:
    roots = []
    for relative in (".codex", ".codex/sqlite"):
        path = home / relative
        if not path.exists():
            continue
        fd = _open_dir(path)
        try:
            for name in sorted(os.listdir(fd)):
                value = relative + "/" + name
                if ((relative == ".codex" and DATABASE_NAME.fullmatch(name))
                        or (relative == ".codex/sqlite" and _is_database(value))):
                    roots.append(value)
        finally:
            os.close(fd)
    return roots


def _catalog(home: Path) -> list[dict]:
    items = [{"id": i, "provider": p, "label": label, "relativeRoots": [r],
              "source": str(home / r), "kind": "record-store"}
             for i, p, label, r in ROOTS]
    items.append({"id": "codex.databases", "provider": "Codex",
                  "label": "Session and application SQLite snapshots",
                  "relativeRoots": _db_roots(home), "source": str(home / ".codex"),
                  "kind": "sqlite-snapshots"})
    return items


def _inventory(home: Path, roots: list[str]) -> tuple[list[dict], list[dict], list[str]]:
    files: dict[str, dict] = {}
    directories: dict[str, dict] = {}
    skipped = []
    fd = _open_dir(home)
    try:
        def walk(relative: str, *, root: bool = False):
            if _excluded(relative):
                skipped.append(relative)
                return
            with _parent_fd(fd, relative) as (parent, name):
                info = os.stat(name, dir_fd=parent, follow_symlinks=False)
                mode = stat.S_IMODE(info.st_mode)
                if stat.S_ISLNK(info.st_mode):
                    if root:
                        raise RecoveryError("record-store roots cannot be symlinks")
                    link = os.readlink(name, dir_fd=parent)
                    files[relative] = {"path": relative, "kind": "symlink",
                                       "signature": _signature(info), "mode": mode,
                                       "mtimeNs": info.st_mtime_ns, "linkTarget": link,
                                       "size": len(os.fsencode(link))}
                elif stat.S_ISDIR(info.st_mode):
                    opened = os.open(name, os.O_RDONLY | O_DIRECTORY | NOFOLLOW,
                                     dir_fd=parent)
                    try:
                        if _identity(os.fstat(opened)) != _identity(info):
                            raise RecoveryError("source directory changed")
                        names = sorted(os.listdir(opened))
                    finally:
                        os.close(opened)
                    directories[relative] = {"path": relative, "mode": mode,
                                             "identity": _identity(info)}
                    for child in names:
                        child_rel = _relative(relative + "/" + child)
                        # Database backup captures committed WAL content. Do not
                        # copy transient companions as an inconsistent second source.
                        if child.endswith(("-wal", "-shm", "-journal")):
                            base = child.rsplit("-", 1)[0]
                            if _is_database(base):
                                skipped.append(child_rel)
                                continue
                        walk(child_rel)
                elif stat.S_ISREG(info.st_mode):
                    if not _allowed(relative):
                        raise RecoveryError("source entry is outside the allowlist")
                    if relative in files:
                        raise RecoveryError("overlapping selected sources")
                    files[relative] = {
                        "path": relative, "kind": "sqlite" if _is_database(relative) else "file",
                        "signature": _signature(info), "mode": mode,
                        "mtimeNs": info.st_mtime_ns, "size": info.st_size,
                    }
                else:
                    raise RecoveryError("record store contains a non-regular special file")
            if len(files) > MAX_FILES:
                raise RecoveryError("record store exceeds the file-count limit")
        for relative in roots:
            walk(_relative(relative), root=True)
    finally:
        os.close(fd)
    # Provider-owned hardlinks are ordinary records. Copy each distinct path
    # independently; do not recreate hardlink relationships in the bundle.
    return (sorted(files.values(), key=lambda e: e["path"]),
            sorted(directories.values(), key=lambda e: e["path"]), skipped)


def _identity_tuple(signature: tuple) -> tuple:
    return tuple(signature[:2])


def _metadata(home: Path, entry: dict) -> dict:
    """Return only association metadata, never a title, prompt, or tool body."""
    path = entry["path"]
    if entry["kind"] != "file" or not path.endswith((".jsonl", ".json")):
        return {}
    if not (path.startswith((".codex/sessions/", ".codex/archived_sessions/",
                             ".claude/projects/"))
            or "/local-agent-mode-sessions/" in path
            or "/claude-code-sessions/" in path):
        return {}
    # Sidecar tool results and subagents can have arbitrary `id` fields; they
    # belong in the raw backup but must not inflate main-session coverage.
    is_codex = path.startswith(".codex/")
    is_claude = path.startswith(".claude/")
    if is_codex and not path.endswith(".jsonl"):
        return {}
    if is_claude and (len(PurePosixPath(path).parts) != 4 or not path.endswith(".jsonl")):
        return {}
    if not is_codex and not is_claude:
        if not (PurePosixPath(path).name.startswith("local_") and path.endswith(".json")):
            return {}
    root_fd = _open_dir(home)
    try:
        with _parent_fd(root_fd, path) as (parent, name):
            f = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=parent)
            try:
                if _signature(os.fstat(f)) != entry["signature"]:
                    raise RecoveryError("source changed during metadata planning")
                with os.fdopen(os.dup(f), "rb") as handle:
                    lines = ([handle.read(MAX_METADATA)] if path.endswith(".json")
                             else [handle.readline(65536) for _ in range(25)])
                meta: dict[str, Any] = {}
                for line in lines:
                    try:
                        value = json.loads(line)
                    except (ValueError, UnicodeError, RecursionError):
                        continue
                    if not isinstance(value, dict):
                        continue
                    if is_codex and value.get("type") != "session_meta":
                        continue
                    value = value.get("payload", {}) if value.get("type") == "session_meta" else value
                    if not isinstance(value, dict):
                        continue
                    for key in ("id", "sessionId", "cliSessionId", "cwd", "gitBranch"):
                        if isinstance(value.get(key), str):
                            meta.setdefault(key, value[key][:4096])
                    git = value.get("git")
                    if isinstance(git, dict):
                        meta["gitLinked"] = bool(git.get("repository_url") or git.get("commit_hash")
                                                 or git.get("branch"))
                    folders = value.get("userSelectedFolders")
                    if isinstance(folders, list) and folders:
                        meta["folderLinked"] = True
                if _signature(os.fstat(f)) != entry["signature"]:
                    raise RecoveryError("source changed during metadata planning")
                return meta
            finally:
                os.close(f)
    finally:
        os.close(root_fd)


def _note_record(home: Path, provider: str, file: dict, records: dict) -> None:
    meta = _metadata(home, file)
    if not meta:
        return
    identity = (meta.get("cliSessionId") or meta.get("sessionId")
                or meta.get("id") or file["path"])
    git_link = bool(meta.get("gitLinked") or meta.get("gitBranch"))
    folder_link = bool(meta.get("cwd") or meta.get("folderLinked"))
    previous = records[provider].get(identity, (False, False))
    records[provider][identity] = (previous[0] or git_link, previous[1] or folder_link)


def _coverage(records: dict) -> list[dict]:
    coverage = []
    for provider in PROVIDERS:
        values = list(records[provider].values())
        coverage.append({
            "provider": provider, "recordCount": len(values),
            "gitLinkedCount": sum(g for g, _ in values),
            "folderLinkedCount": sum(not g and f for g, f in values),
            "unassignedCount": sum(not g and not f for g, f in values),
            "resumeSupport": ("Local Code records can be restored; Desktop import/resume is unverified."
                              if provider == "Claude Desktop" else
                              "Original records can be restored to a new home; CLI resume requires separate preparation and validation."),
        })
    coverage += [{"provider": p, "recordCount": 0, "gitLinkedCount": 0,
                  "folderLinkedCount": 0, "unassignedCount": 0,
                  "resumeSupport": "Unsupported: not inventoried or backed up."}
                 for p in ("Gemini", "IDE")]
    return coverage


def plan(home: Path) -> dict:
    home = _home(home)
    warnings = list(WARNINGS)
    items = []
    records: dict[str, dict[str, tuple[bool, bool]]] = {p: {} for p in PROVIDERS}
    for spec in _catalog(home):
        entry = {k: spec[k] for k in ("id", "provider", "label", "source", "kind")}
        entry.update(bytes=0, fileCount=0, available=False, reason="")
        roots = [r for r in spec["relativeRoots"] if os.path.lexists(home / r)]
        if not roots:
            entry["reason"] = "Not present"
        else:
            try:
                files, _, skipped = _inventory(home, roots)
                entry.update(bytes=sum(e["size"] for e in files), fileCount=len(files),
                             available=bool(files), reason="Available" if files else "No included files")
                if skipped:
                    entry["reason"] += f"; {len(skipped)} excluded entries"
                incomplete_metadata = 0
                for file in files:
                    try:
                        _note_record(home, spec["provider"], file, records)
                    except (OSError, RecoveryError):
                        incomplete_metadata += 1
                if incomplete_metadata:
                    entry["reason"] += f"; association counts incomplete for {incomplete_metadata} changing or unreadable records"
                    warnings.append(f"{spec['label']}: association counts are incomplete; {incomplete_metadata} metadata records changed or could not be read.")
            except (OSError, RecoveryError) as exc:
                entry["available"] = False
                entry["reason"] = f"Unavailable: {type(exc).__name__}: {exc}"
                warnings.append(f"{spec['label']} could not be completely inventoried.")
        items.append(entry)
    return {"schemaVersion": SCHEMA, "status": "planned", "items": items,
            "warnings": warnings, "excluded": list(EXCLUSIONS), "coverage": _coverage(records)}


def _hash_fd(fd: int, target_fd: int | None = None) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    while True:
        block = os.read(fd, CHUNK)
        if not block:
            break
        digest.update(block)
        size += len(block)
        if target_fd is not None:
            view = memoryview(block)
            while view:
                written = os.write(target_fd, view)
                view = view[written:]
    return size, digest.hexdigest()


def _copy_regular(root_fd: int, relative: str, target_fd: int, expected: tuple) -> tuple:
    with _parent_fd(root_fd, relative) as (parent, name):
        fd = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=parent)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or _signature(before) != tuple(expected):
                raise RecoveryError("source file changed before copy")
            result = _hash_fd(fd, target_fd)
            if (_signature(os.fstat(fd)) != tuple(expected)
                    or _signature(os.stat(name, dir_fd=parent, follow_symlinks=False)) != tuple(expected)):
                raise RecoveryError("source file changed during copy")
            return result
        finally:
            os.close(fd)


def _sqlite_integrity(path: Path) -> None:
    uri = "file:" + quote(str(path), safe="/") + "?mode=ro&immutable=1"
    with contextlib.closing(sqlite3.connect(uri, uri=True)) as db:
        result = db.execute("PRAGMA integrity_check").fetchall()
        if result != [("ok",)]:
            raise RecoveryError("SQLite integrity_check failed")


def _snapshot_sqlite(home: Path, entry: dict, destination: Path) -> tuple[int, str]:
    """An online backup includes committed WAL state without modifying the source."""
    source = home / entry["path"]
    source_parent = _open_dir(source.parent)
    guard = -1
    try:
        before = os.stat(source.name, dir_fd=source_parent, follow_symlinks=False)
        guard = os.open(source.name, os.O_RDONLY | NOFOLLOW, dir_fd=source_parent)
        if (not stat.S_ISREG(before.st_mode)
                or _identity(before) != _identity_tuple(entry["signature"])
                or _identity(os.fstat(guard)) != _identity(before)):
            raise RecoveryError("SQLite source changed before opening")
        parent_identity = _identity(os.fstat(source_parent))
        companion_identities = {}

        def validate_namespace():
            # SQLite opens its companions internally, so validate every one
            # before connecting and throughout the snapshot. The directory
            # descriptor remains pinned until the connection has closed.
            current_parent = _open_dir(source.parent)
            try:
                if _identity(os.fstat(current_parent)) != parent_identity:
                    raise RecoveryError("SQLite parent directory was replaced")
            finally:
                os.close(current_parent)
            current = os.stat(source.name, dir_fd=source_parent, follow_symlinks=False)
            if not stat.S_ISREG(current.st_mode) or _identity(current) != _identity(before):
                raise RecoveryError("SQLite source was replaced during snapshot")
            for suffix in ("-wal", "-shm", "-journal"):
                name = source.name + suffix
                try:
                    companion = os.stat(name, dir_fd=source_parent, follow_symlinks=False)
                except FileNotFoundError:
                    if name in companion_identities:
                        raise RecoveryError("SQLite companion disappeared during snapshot")
                    continue
                if not stat.S_ISREG(companion.st_mode):
                    raise RecoveryError("SQLite companion must be a regular non-symlink file")
                check_fd = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=source_parent)
                try:
                    if _identity(os.fstat(check_fd)) != _identity(companion):
                        raise RecoveryError("SQLite companion changed while opening")
                finally:
                    os.close(check_fd)
                identity = _identity(companion)
                if name in companion_identities and companion_identities[name] != identity:
                    raise RecoveryError("SQLite companion was replaced during snapshot")
                companion_identities[name] = identity

        started = time.monotonic()

        def progress(status, remaining, total):
            if time.monotonic() - started > SQLITE_TIMEOUT:
                raise RecoveryError("SQLite snapshot timed out")
            validate_namespace()

        uri = "file:" + quote(str(source), safe="/") + "?mode=ro"
        validate_namespace()
        with contextlib.closing(sqlite3.connect(uri, uri=True, timeout=2)) as src:
            validate_namespace()
            src.execute("PRAGMA query_only=ON")
            with contextlib.closing(sqlite3.connect(str(destination))) as dst:
                src.backup(dst, pages=256, progress=progress, sleep=0.01)
                # Consolidate only our copy so it has no live WAL dependency.
                dst.execute("PRAGMA journal_mode=DELETE").fetchone()
            validate_namespace()
        validate_namespace()
        _sqlite_integrity(destination)
        fd = os.open(destination, os.O_RDONLY | NOFOLLOW)
        try:
            os.fsync(fd)
            return _hash_fd(fd)
        finally:
            os.close(fd)
    finally:
        if guard >= 0:
            os.close(guard)
        os.close(source_parent)


def _destination(destination: Path, forbidden: list[Path]) -> tuple[Path, int, int]:
    if ".." in Path(str(destination)).parts:
        raise RecoveryError("destination traversal is not supported")
    destination = _absolute(destination)
    def conservative_parts(path: Path) -> tuple[str, ...]:
        # APFS/HFS+ usually ignore case and Unicode normalization. Be
        # conservative even on a case-sensitive destination volume.
        return tuple(unicodedata.normalize("NFD", p).casefold() for p in path.parts)
    destination_parts = conservative_parts(destination)
    for source in forbidden:
        source = _absolute(source)
        source_parts = conservative_parts(source)
        shared = min(len(source_parts), len(destination_parts))
        if destination_parts[:shared] == source_parts[:shared]:
            raise RecoveryError("destination overlaps source data")
    if os.path.lexists(destination):
        raise RecoveryError("destination already exists; choose a new directory")
    parent = _open_dir(destination.parent, create=True)
    try:
        os.mkdir(destination.name, 0o700, dir_fd=parent)
        fd = os.open(destination.name, os.O_RDONLY | O_DIRECTORY | NOFOLLOW, dir_fd=parent)
        return destination, parent, fd
    except BaseException:
        os.close(parent)
        raise


def _cleanup_created(parent: int, name: str, identity: tuple) -> None:
    """Remove only our unpublished directory, with descriptor-relative nofollow traversal."""
    try:
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISDIR(info.st_mode) or _identity(info) != identity:
            return
        fd = os.open(name, os.O_RDONLY | O_DIRECTORY | NOFOLLOW, dir_fd=parent)
        try:
            for entry in os.listdir(fd):
                child = os.stat(entry, dir_fd=fd, follow_symlinks=False)
                if stat.S_ISDIR(child.st_mode):
                    _cleanup_created(fd, entry, _identity(child))
                else:
                    os.unlink(entry, dir_fd=fd)
        finally:
            os.close(fd)
        os.rmdir(name, dir_fd=parent)
    except OSError:
        pass


def _write_json(fd: int, name: str, value: dict) -> None:
    out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=fd)
    try:
        payload = (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()
        view = memoryview(payload)
        while view:
            view = view[os.write(out, view):]
        os.fsync(out)
    finally:
        os.close(out)


def _receipt(bundle: Path, manifest: dict, restored: Path | None = None) -> dict:
    result = {"schemaVersion": SCHEMA, "status": "restored" if restored else "verified",
              "bundle": str(bundle), "fileCount": len(manifest["files"]),
              "totalBytes": sum(e["size"] for e in manifest["files"]),
              "providers": manifest["providers"], "warnings": manifest["warnings"]}
    if restored is not None:
        result["restoredRoot"] = str(restored)
    return result


def backup(destination: Path, item_ids: list[str], home: Path, *,
           include_sensitive: bool = False) -> dict:
    if not include_sensitive:
        raise RecoveryError("--include-sensitive is required for an unencrypted original backup")
    if (not isinstance(item_ids, list) or not item_ids
            or any(not isinstance(x, str) for x in item_ids)
            or len(set(item_ids)) != len(item_ids)):
        raise RecoveryError("items-json must be a nonempty array of unique item IDs")
    home = _home(home)
    catalog = {e["id"]: e for e in _catalog(home)}
    if any(i not in catalog for i in item_ids):
        raise RecoveryError("unknown recovery item ID")
    selected = [catalog[i] for i in item_ids]
    roots = [r for spec in selected for r in spec["relativeRoots"]]
    if not roots or any(not os.path.lexists(home / r) for r in roots):
        raise RecoveryError("a selected item is missing; plan again")
    files, dirs, skipped = _inventory(home, roots)
    if not files:
        raise RecoveryError("selected items contain no supported files")
    records = {p: {} for p in PROVIDERS}
    for file in files:
        _note_record(home, _provider(file["path"]), file, records)
    # Reject destinations anywhere within a live provider store, even an
    # unselected sibling, and paths resolving back through any source link.
    forbidden = [home / ".codex", home / ".claude",
                 home / "Library/Application Support/Claude"]
    home_fd = _open_dir(home)
    try:
        destination, parent, dest_fd = _destination(destination, forbidden)
    except BaseException:
        os.close(home_fd)
        raise
    identity = _identity(os.fstat(dest_fd))
    payload_fd = -1
    completed = False
    manifest = {"schemaVersion": SCHEMA, "format": FORMAT, "createdAt": _now(),
                "sourceHome": str(home), "providers": sorted({s["provider"] for s in selected}),
                "selectedItemIds": item_ids, "files": [], "directories": [],
                "warnings": list(WARNINGS), "excluded": list(EXCLUSIONS),
                "skippedEntries": skipped, "coverage": _coverage(records)}
    try:
        os.mkdir("payload", 0o700, dir_fd=dest_fd)
        payload_fd = os.open("payload", os.O_RDONLY | O_DIRECTORY | NOFOLLOW, dir_fd=dest_fd)
        # Creating parents on demand preserves empty allowed record-store dirs too.
        for directory in dirs:
            with _parent_fd(payload_fd, directory["path"], create=True) as (p, n):
                try:
                    os.mkdir(n, 0o700, dir_fd=p)
                except FileExistsError:
                    pass
            manifest["directories"].append({"path": directory["path"], "mode": directory["mode"]})
        for entry in files:
            record = {k: entry[k] for k in ("path", "kind", "mode", "mtimeNs")}
            with _parent_fd(payload_fd, entry["path"], create=True) as (p, n):
                if entry["kind"] == "symlink":
                    with _parent_fd(home_fd, entry["path"]) as (sp, sn):
                        target = os.readlink(sn, dir_fd=sp)
                        if (target != entry["linkTarget"] or
                                _signature(os.stat(sn, dir_fd=sp, follow_symlinks=False)) != entry["signature"]):
                            raise RecoveryError("source symlink changed")
                    os.symlink(target, n, dir_fd=p)
                    raw = os.fsencode(target)
                    record.update(size=len(raw), sha256=hashlib.sha256(raw).hexdigest(),
                                  linkTarget=target)
                else:
                    out = os.open(n, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o600, dir_fd=p)
                    try:
                        if entry["kind"] == "sqlite":
                            os.close(out)
                            out = -1
                            size, digest = _snapshot_sqlite(home, entry, destination / "payload" / entry["path"])
                        else:
                            size, digest = _copy_regular(home_fd, entry["path"], out, entry["signature"])
                            os.fsync(out)
                    finally:
                        if out >= 0:
                            os.close(out)
                    record.update(size=size, sha256=digest)
            manifest["files"].append(record)
        current, current_dirs, _ = _inventory(home, roots)
        if [e["path"] for e in current] != [e["path"] for e in files]:
            raise RecoveryError("source file inventory changed during backup")
        for before, after in zip(files, current):
            expected = (_identity_tuple(before["signature"]) if before["kind"] == "sqlite"
                        else before["signature"])
            actual = (_identity_tuple(after["signature"]) if after["kind"] == "sqlite"
                      else after["signature"])
            if expected != actual:
                raise RecoveryError("source file changed during backup")
        if dirs != current_dirs:
            raise RecoveryError("source directories changed during backup")
        # Verify copied bytes before publishing the manifest that marks completion.
        _verify_payload(payload_fd, destination / "payload", manifest)
        _write_json(dest_fd, "manifest.json", manifest)
        os.fsync(dest_fd)
        if _identity(os.lstat(destination)) != identity:
            raise RecoveryError("destination changed during backup")
        completed = True
        return _receipt(destination, manifest)
    finally:
        if payload_fd >= 0:
            os.close(payload_fd)
        os.close(home_fd)
        os.close(dest_fd)
        if not completed:
            _cleanup_created(parent, destination.name, identity)
        os.close(parent)


def _validate_manifest(manifest: dict) -> None:
    if (not isinstance(manifest, dict) or manifest.get("schemaVersion") != SCHEMA
            or manifest.get("format") != FORMAT):
        raise RecoveryError("unsupported recovery manifest")
    source_home = manifest.get("sourceHome")
    if (not isinstance(source_home, str) or not source_home.startswith("/")
            or source_home == "/" or "\\" in source_home or "\0" in source_home
            or any(p in ("", ".", "..") for p in source_home.split("/")[1:])):
        raise RecoveryError("invalid absolute sourceHome in manifest")
    files = manifest.get("files")
    if not isinstance(files, list) or not files or len(files) > MAX_FILES:
        raise RecoveryError("invalid manifest file list")
    if (not isinstance(manifest.get("providers"), list)
            or any(p not in PROVIDERS for p in manifest["providers"])
            or not isinstance(manifest.get("warnings"), list)
            or any(not isinstance(w, str) for w in manifest["warnings"])):
        raise RecoveryError("invalid manifest metadata")
    paths = set()
    links = set()
    for entry in files:
        if not isinstance(entry, dict):
            raise RecoveryError("invalid manifest entry")
        relative = _relative(entry.get("path"))
        if relative in paths or not _allowed(relative):
            raise RecoveryError("duplicate or unapproved payload path")
        paths.add(relative)
        if entry.get("kind") not in ("file", "sqlite", "symlink"):
            raise RecoveryError("invalid payload kind")
        if type(entry.get("size")) is not int or entry["size"] < 0:
            raise RecoveryError("invalid payload size")
        if (type(entry.get("mode")) is not int or not 0 <= entry["mode"] <= 0o7777
                or type(entry.get("mtimeNs")) is not int
                or not -(2**63) < entry["mtimeNs"] < 2**63):
            raise RecoveryError("invalid payload attributes")
        if not isinstance(entry.get("sha256"), str) or not re.fullmatch("[0-9a-f]{64}", entry["sha256"]):
            raise RecoveryError("invalid payload hash")
        if entry["kind"] == "sqlite" and not _is_database(relative):
            raise RecoveryError("SQLite entry has an invalid path")
        if entry["kind"] == "symlink":
            target = entry.get("linkTarget")
            if not isinstance(target, str) or not target or "\0" in target:
                raise RecoveryError("invalid symlink target")
            links.add(relative)
    for path in paths:
        for parent in PurePosixPath(path).parents:
            if str(parent) in paths:
                raise RecoveryError("file or symlink used as a payload directory")
    directory_paths = set()
    if not isinstance(manifest.get("directories", []), list):
        raise RecoveryError("invalid directory list")
    for entry in manifest.get("directories", []):
        if (not isinstance(entry, dict) or type(entry.get("mode")) is not int
                or not 0 <= entry["mode"] <= 0o7777):
            raise RecoveryError("invalid directory attributes")
        relative = _relative(entry.get("path"))
        if relative in paths or relative in directory_paths or not _allowed(relative):
            raise RecoveryError("invalid payload directory")
        if any(str(p) in paths for p in PurePosixPath(relative).parents):
            raise RecoveryError("file used as a parent directory")
        directory_paths.add(relative)


def _read_manifest(root_fd: int) -> dict:
    f = os.open("manifest.json", os.O_RDONLY | NOFOLLOW, dir_fd=root_fd)
    try:
        info = os.fstat(f)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_MANIFEST:
            raise RecoveryError("invalid manifest file")
        with os.fdopen(os.dup(f), "rb") as handle:
            manifest = json.load(handle)
        if _signature(info) != _signature(os.fstat(f)):
            raise RecoveryError("manifest changed during verification")
    finally:
        os.close(f)
    _validate_manifest(manifest)
    return manifest


def _payload_files(fd: int, prefix: str = "") -> set[str]:
    result = set()
    for name in os.listdir(fd):
        relative = name if not prefix else prefix + "/" + name
        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            child = os.open(name, os.O_RDONLY | O_DIRECTORY | NOFOLLOW, dir_fd=fd)
            try:
                result |= _payload_files(child, relative)
            finally:
                os.close(child)
        elif stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
            result.add(relative)
        else:
            raise RecoveryError("unexpected special file in bundle")
    return result


def _verify_payload(fd: int, path: Path, manifest: dict) -> None:
    _validate_manifest(manifest)
    expected = {e["path"] for e in manifest["files"]}
    if _payload_files(fd) != expected:
        raise RecoveryError("payload inventory does not match the manifest")
    for entry in manifest["files"]:
        with _parent_fd(fd, entry["path"]) as (parent, name):
            info = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if entry["kind"] == "symlink":
                if not stat.S_ISLNK(info.st_mode):
                    raise RecoveryError("payload kind changed")
                target = os.readlink(name, dir_fd=parent)
                raw = os.fsencode(target)
                size, digest = len(raw), hashlib.sha256(raw).hexdigest()
                if target != entry["linkTarget"]:
                    raise RecoveryError("symlink target mismatch")
            else:
                f = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=parent)
                try:
                    if not stat.S_ISREG(os.fstat(f).st_mode):
                        raise RecoveryError("payload is not a regular file")
                    size, digest = _hash_fd(f)
                    if _signature(os.fstat(f)) != _signature(info):
                        raise RecoveryError("payload changed during verification")
                finally:
                    os.close(f)
            if size != entry["size"] or digest != entry["sha256"]:
                raise RecoveryError("payload SHA-256 or size mismatch")
            if entry["kind"] == "sqlite":
                _sqlite_integrity(path / entry["path"])


def verify(bundle: Path) -> dict:
    bundle = _absolute(bundle)
    fd = _open_dir(bundle)
    try:
        manifest = _read_manifest(fd)
        payload = os.open("payload", os.O_RDONLY | O_DIRECTORY | NOFOLLOW, dir_fd=fd)
        try:
            _verify_payload(payload, bundle / "payload", manifest)
        finally:
            os.close(payload)
        return _receipt(bundle, manifest)
    finally:
        os.close(fd)


def restore(bundle: Path, destination: Path) -> dict:
    bundle = _absolute(bundle)
    bundle_fd = _open_dir(bundle)
    payload = -1
    parent = dest_fd = -1
    completed = False
    try:
        manifest = _read_manifest(bundle_fd)
        payload = os.open("payload", os.O_RDONLY | O_DIRECTORY | NOFOLLOW, dir_fd=bundle_fd)
        _verify_payload(payload, bundle / "payload", manifest)
        source_home = manifest.get("sourceHome")
        forbidden = [bundle]
        for home in (Path.home(), Path(source_home) if isinstance(source_home, str) else Path.home()):
            forbidden += [home / ".codex", home / ".claude",
                          home / "Library/Application Support/Claude"]
        destination, parent, dest_fd = _destination(destination, forbidden)
        identity = _identity(os.fstat(dest_fd))
        for directory in manifest.get("directories", []):
            with _parent_fd(dest_fd, directory["path"], create=True) as (p, n):
                try:
                    os.mkdir(n, 0o700, dir_fd=p)
                except FileExistsError:
                    pass
        for entry in manifest["files"]:
            with _parent_fd(dest_fd, entry["path"], create=True) as (p, n):
                if entry["kind"] == "symlink":
                    with _parent_fd(payload, entry["path"]) as (sp, sn):
                        if os.readlink(sn, dir_fd=sp) != entry["linkTarget"]:
                            raise RecoveryError("bundle symlink changed during restore")
                    os.symlink(entry["linkTarget"], n, dir_fd=p)
                else:
                    with _parent_fd(payload, entry["path"]) as (sp, sn):
                        expected = _signature(os.stat(sn, dir_fd=sp, follow_symlinks=False))
                    out = os.open(n, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW,
                                  0o600, dir_fd=p)
                    try:
                        size, digest = _copy_regular(payload, entry["path"], out, expected)
                        os.fchmod(out, entry["mode"] & 0o777)
                        os.fsync(out)
                    finally:
                        os.close(out)
                    if (size, digest) != (entry["size"], entry["sha256"]):
                        raise RecoveryError("bundle changed during restore")
                os.utime(n, ns=(entry["mtimeNs"], entry["mtimeNs"]),
                         dir_fd=p, follow_symlinks=False)
        _verify_payload(dest_fd, destination, manifest)
        _write_json(dest_fd, RESTORED_MANIFEST, manifest)
        # Apply directory permissions only after populating and verifying them.
        for directory in sorted(manifest.get("directories", []),
                                key=lambda d: len(d["path"]), reverse=True):
            with _parent_fd(dest_fd, directory["path"]) as (p, n):
                child = os.open(n, os.O_RDONLY | O_DIRECTORY | NOFOLLOW, dir_fd=p)
                try:
                    os.fchmod(child, directory["mode"] & 0o777)
                finally:
                    os.close(child)
        os.fsync(dest_fd)
        completed = True
        return _receipt(bundle, manifest, destination)
    finally:
        if dest_fd >= 0:
            os.close(dest_fd)
            if not completed:
                _cleanup_created(parent, destination.name, identity)
        if parent >= 0:
            os.close(parent)
        if payload >= 0:
            os.close(payload)
        os.close(bundle_fd)


def main(argv: list[str] | None = None) -> int:
    class JSONParser(argparse.ArgumentParser):
        def error(self, message):
            raise RecoveryError(message)
    parser = JSONParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("plan")
    p.add_argument("--home", type=Path, default=Path.home())
    p = commands.add_parser("backup")
    p.add_argument("--home", type=Path, default=Path.home())
    p.add_argument("--destination", type=Path, required=True)
    p.add_argument("--items-json", required=True, help="JSON array of plan item IDs")
    p.add_argument("--include-sensitive", action="store_true")
    p = commands.add_parser("verify")
    p.add_argument("bundle", type=Path)
    p = commands.add_parser("restore")
    p.add_argument("bundle", type=Path)
    p.add_argument("--destination", type=Path, required=True)
    previous_handlers = {}

    def cancel(signum, frame):
        # A second termination request must not interrupt removal of our own
        # unpublished directory. SIGKILL/power failure may still leave a
        # partial bundle, which never verifies without a complete manifest.
        for number in (signal.SIGTERM, signal.SIGINT):
            signal.signal(number, signal.SIG_IGN)
        raise RecoveryCancelled(f"Operation cancelled by signal {signum}")

    try:
        for number in (signal.SIGTERM, signal.SIGINT):
            previous_handlers[number] = signal.signal(number, cancel)
        args = parser.parse_args(argv)
        if args.command == "plan":
            result = plan(args.home)
        elif args.command == "backup":
            result = backup(args.destination, json.loads(args.items_json), args.home,
                            include_sensitive=args.include_sensitive)
        elif args.command == "verify":
            result = verify(args.bundle)
        else:
            result = restore(args.bundle, args.destination)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ValueError, sqlite3.Error, RecursionError, RecoveryCancelled) as exc:
        error = {"schemaVersion": SCHEMA, "status": "error",
                 "error": f"{type(exc).__name__}: {exc}"}
        if isinstance(exc, RecoveryCancelled):
            error["cancelled"] = True
        print(json.dumps(error, ensure_ascii=False))
        return 1
    finally:
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(main())
