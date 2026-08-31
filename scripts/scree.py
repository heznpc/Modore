#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Scree, Modore's session-and-residue audit module: judge what AI agents leave behind.

Like the rock debris that piles up at the foot of a slope, local agent session
stores, worktrees, and state directories accumulate under every run. Scree
maps and judges that debris field deterministically.

Answers, deterministically and without any LLM: which tools (Claude Code, Codex,
Gemini CLI, VS Code forks) worked in the same workspace or repository, when, and
how much of each store belongs to workspaces that no longer exist.

Privacy contract (metadata-only output):
- parses at most the leading JSONL lines of each session file in memory;
  message/content fields inside those lines are decoded but discarded — only
  the whitelisted metadata keys below are ever retained or emitted;
- nested subagent transcripts are never opened at all (stat() only);
- writes nothing; all output goes to stdout.

Judgment limits (preview-grade evidence, not deletion authorization):
- an "orphan" workspace may in fact have been moved, renamed, or unmounted;
- "rebuildable" trusts local remote-tracking refs, which can lag the live
  remote; any destructive consumer must revalidate before acting.

Content-reading commands (the deliberate exceptions to the no-content
contract above). Every one of them runs only when a person asks — never
on the app's own initiative, never during a scan — and every one masks by
default:
- `scree.py preserve <source>` writes a masked Markdown export of one
  transcript, the same shape as hydroject's `export`;
- `scree.py title <source>` returns one masked line: the first user
  request that says what the session was about, for display beside a
  deletion decision. It is the smallest content read and the only
  one whose output is retained anywhere, so it is capped to one short
  line and is never an input to a safety judgement.
- `scree.py titles` returns the same one masked line for many named
  sessions in one pass, because a screen showing thirty rows should not
  pay thirty process spawns for their labels. A batch of explicit
  targets is still not a bulk read of the disk: nothing is discovered
  here, and the caller names every source.
- `scree.py search <query>` looks for a phrase across every session and
  returns masked snippets with the coverage the answer rests on. The one
  exception that is not scoped to named sessions -- it cannot be, since
  finding which session matters is the question -- so it is scoped by the
  query instead: it runs only on an explicit search, retains nothing, and
  no verdict reads it.
- `scree.py evidence <query>` answers "how was this handled before" from
  four separate sources -- what was said, provider tool invocations and
  their correlated outcomes, Modore cleanup receipts, and free-space
  observations. They are returned in four lists and never summed: a
  mention is not an invocation, a requested call is not a completed one,
  and no arrow is drawn between a cleanup receipt and later free space.
- `scree.py bind <workspace> --deep` reads transcript bodies to find
  file-access evidence, and emits only whether such evidence exists.
- `scree.py inspect <source>` returns one session's conversation for
  display -- masked, per-turn capped, recent-window only. The viewer the
  display commands imply: judgment stays metadata-only, but the owner can
  always look at what the machine already holds. Never an input to any
  verdict.
Raw backup commands are a separate, explicit exception: `backup` copies one
named Claude Code/Codex transcript or one Claude Desktop conversation unit and
its owned sidecars byte-for-byte only with --include-sensitive. `backup-verify` hashes an explicitly named
archive; `backup-restore` writes it to a NEW directory, never over live state.
These commands do not mask or encrypt the archive, contact a model, delete a
source, or grant permission to reclaim anything. No audit invokes them.
Everything above this line in the module never calls any of them.
"""
from __future__ import annotations

import argparse
import contextlib
import errno
import hashlib
import io
import json
import math
import os
import re
import select
import shutil
import signal
import stat
import subprocess
import sys
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Optional
from urllib.parse import unquote, urlparse

# ``json.JSONDecodeError`` is only one ValueError shape from json.loads.
# Python's integer conversion guard and deeply nested provider data raise
# ValueError/RecursionError instead; every local-data parser must treat those
# as damaged input rather than aborting an entire inspect/search/backup run.
JSON_PARSE_ERRORS = (ValueError, UnicodeDecodeError, RecursionError)
JSON_FILE_ERRORS = (OSError, ValueError, UnicodeDecodeError, RecursionError)


def _is_utf8_text(value: str) -> bool:
    """Whether provider text is a Unicode scalar sequence usable on the wire."""
    try:
        value.encode("utf-8")
        return True
    except UnicodeEncodeError:
        return False

# The only keys ever copied out of a session line. Everything else is dropped
# unread so prompts, code, and command content can never reach the output.
CLAUDE_META_KEYS = ("cwd", "gitBranch", "sessionId")
CODEX_META_KEYS = ("id", "cwd")
CLAUDE_SCAN_LINES = 25
MAX_LINE_BYTES = 65536

# Claude Desktop's Code surface is a separate store from Claude Code.  One
# conversation is a metadata JSON beside a same-named directory; the hundreds
# of JSONL files below that directory are its transcript, audit trail, queues,
# and subagents, not hundreds of conversations.  Keep the path spelling in one
# place so listing, inspection, search, and original backup cannot drift.
CLAUDE_DESKTOP_LOCAL_SESSIONS = (
    "Library", "Application Support", "Claude", "local-agent-mode-sessions",
)
CLAUDE_DESKTOP_PROVIDER = "claude-desktop"
CLAUDE_DESKTOP_TOOL = "Claude Desktop"
CLAUDE_DESKTOP_METADATA_MAX_BYTES = 4 * 1024 * 1024
CLAUDE_DESKTOP_METADATA_TOTAL_BYTES = 64 * 1024 * 1024
CLAUDE_DESKTOP_METADATA_MAX_FILES = 4096
CLAUDE_DESKTOP_SELECTED_FOLDERS_MAX = 64
CLAUDE_DESKTOP_LOCATION_MAX_CHARS = 4096
CLAUDE_DESKTOP_ID_MAX_CHARS = 256
CLAUDE_DESKTOP_TITLE_MAX_CHARS = 4096
# Desktop stores Unix epoch milliseconds. Values outside this deliberately
# generous range are damaged metadata, not dates: Python can serialize an
# arbitrary-size integer that Foundation's JSON parser cannot represent.
CLAUDE_DESKTOP_TIMESTAMP_MAX_MS = 4_102_444_800_000  # 2100-01-01 UTC
CLAUDE_DESKTOP_NAMESPACE_MAX_ENTRIES = 50000
CLAUDE_DESKTOP_PRIMARY_SCAN_MAX_ENTRIES = 50000
CLAUDE_DESKTOP_BIND_MAX_FILES = 50000
CLAUDE_DESKTOP_WORKSPACE_PROBE_SECONDS = 0.50
CLAUDE_DESKTOP_WORKSPACE_PROBE_MAX_BYTES = 4 * 1024 * 1024

# Retention judgment thresholds (observation-based estimates, never vendor claims).
RETENTION_MIN_SESSIONS = 5      # below this a window cannot be inferred honestly
ROLLING_WINDOW_DAYS = (20, 45)  # oldest-session age in this band suggests auto-cleanup
EXPIRY_SOON_DAYS = 7            # sessions this close to the inferred window are flagged
STALLED_STORE_DAYS = 21         # no new session for this long → store no longer written

# Stable provider ids for the fork labels, so a display name change in
# `VSCODE_FORKS` cannot silently invalidate manifests already on disk.
VSCODE_PROVIDER_IDS = {
    "VS Code": "vscode",
    "Kiro": "kiro",
    "Cursor": "cursor",
    "Windsurf": "windsurf",
    "Antigravity": "antigravity",
}

VSCODE_FORKS = (
    ("VS Code", "Code"),
    ("Kiro", "Kiro"),
    ("Cursor", "Cursor"),
    ("Windsurf", "Windsurf"),
    ("Antigravity", "Antigravity"),
)


def _read_json_line(handle) -> Optional[dict]:
    line = handle.readline(MAX_LINE_BYTES)
    if not line:
        return None
    try:
        parsed = json.loads(line)
    # Python's JSON integer conversion can raise ValueError for an attacker-
    # sized numeric literal. Deeply nested input can similarly raise
    # RecursionError. A damaged record must never abort the whole local index.
    except JSON_PARSE_ERRORS:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def normalize_repo_url(url: str) -> str:
    """Reduce https/ssh remote forms to a stable host/owner/name key."""
    cleaned = url.strip()
    cleaned = re.sub(r"\.git/?$", "", cleaned)
    scheme = re.match(r"^[a-z+]+://(?:[^/@]*@)?(?P<host>[^/:]+)(?::\d+)?/(?P<path>.+)$", cleaned)
    if scheme:
        return f"{scheme.group('host')}/{scheme.group('path')}"
    ssh = re.match(r"^(?:[^@]+@)?(?P<host>[^:/]+):(?P<path>.+)$", cleaned)
    if ssh:
        return f"{ssh.group('host')}/{ssh.group('path')}"
    return cleaned


def _canon_workspace(path: str) -> str:
    return path.rstrip("/") or "/"


def _uri_to_path(uri: str) -> Optional[str]:
    parsed = urlparse(uri)
    if parsed.scheme != "file":
        return None
    return _canon_workspace(unquote(parsed.path))


def _record(tool: str, kind: str, source: Path, workspace: Optional[str], *,
            repo_url: Optional[str] = None, branch: Optional[str] = None,
            weight: int = 1) -> dict:
    stat = source.stat()
    return {
        "tool": tool,
        "kind": kind,
        "source": str(source),
        "workspace": _canon_workspace(workspace) if workspace else None,
        "repo_url": normalize_repo_url(repo_url) if repo_url else None,
        "branch": branch,
        "size_bytes": stat.st_size,
        "last_active": stat.st_mtime,
        "weight": weight,
    }


def _claude_desktop_root(home: Path) -> Path:
    return home.joinpath(*CLAUDE_DESKTOP_LOCAL_SESSIONS)


@dataclass(frozen=True)
class _ClaudeDesktopMetadataSnapshot:
    path: Path
    raw: bytes
    metadata_info: os.stat_result
    unit_info: os.stat_result


def _claude_desktop_metadata_scan(
        home: Path) -> tuple[list[_ClaudeDesktopMetadataSnapshot], dict]:
    """Read bounded Desktop metadata through one no-follow descriptor walk."""
    original_home = home.expanduser().absolute()
    store = {
        "store": CLAUDE_DESKTOP_TOOL,
        "status": "ok",
        "count": 0,
        "unrecognized": 0,
    }
    directory_flags = (
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)

    descriptor = -1
    try:
        # Resolve only the caller-supplied home spelling. macOS commonly
        # presents the same home through aliases such as /var -> /private/var;
        # every store component below the canonical home remains no-follow.
        canonical_home = original_home.resolve(strict=True)
        descriptor = _open_directory_nofollow(canonical_home)
        home_device = os.fstat(descriptor).st_dev
    except FileNotFoundError:
        if descriptor >= 0:
            os.close(descriptor)
        store["status"] = "missing"
        return ([], store)
    except OSError:
        if descriptor >= 0:
            os.close(descriptor)
        store["status"] = "unreadable"
        return ([], store)

    root = _claude_desktop_root(canonical_home)
    # Open the fixed store root one component at a time. No later operation
    # reopens any namespace path, so swapping a parent for a symlink cannot
    # redirect discovery or metadata reads.
    try:
        for component in CLAUDE_DESKTOP_LOCAL_SESSIONS:
            child = -1
            try:
                child = os.open(
                    component, directory_flags, dir_fd=descriptor)
                child_info = os.fstat(child)
                named_child = os.stat(
                    component, dir_fd=descriptor,
                    follow_symlinks=False)
                if (not stat.S_ISDIR(child_info.st_mode)
                        or child_info.st_dev != home_device
                        or _stat_identity(child_info)
                        != _stat_identity(named_child)):
                    os.close(child)
                    store["status"] = "unrecognized"
                    store["unrecognized"] = 1
                    os.close(descriptor)
                    return ([], store)
            except FileNotFoundError:
                if child >= 0:
                    os.close(child)
                store["status"] = "missing"
                os.close(descriptor)
                return ([], store)
            except OSError:
                if child >= 0:
                    os.close(child)
                try:
                    named = os.stat(
                        component, dir_fd=descriptor,
                        follow_symlinks=False)
                except OSError:
                    store["status"] = "unreadable"
                else:
                    store["status"] = (
                        "unrecognized"
                        if stat.S_ISLNK(named.st_mode)
                        else "unreadable"
                    )
                    if store["status"] == "unrecognized":
                        store["unrecognized"] = 1
                os.close(descriptor)
                return ([], store)
            os.close(descriptor)
            descriptor = child
    except BaseException:
        os.close(descriptor)
        raise

    snapshots: list[_ClaudeDesktopMetadataSnapshot] = []
    unreadable = False
    truncated = False
    unrecognized = int(store["unrecognized"])
    attempted_bytes = 0
    candidates_seen = 0
    entries_seen = 0
    budget_exhausted = False
    metadata_unit_paths: set[tuple[str, ...]] = set()
    conversation_unit_paths: set[tuple[str, ...]] = set()
    directory_signatures: dict[tuple[str, ...], tuple[int, int, int, int, int, int, int]] = {
        (): _stat_signature(os.fstat(descriptor)),
    }

    def read_candidate(
            parent_descriptor: int, relative_parts: tuple[str, ...],
            name: str, remaining_bytes: int
            ) -> tuple[Optional[_ClaudeDesktopMetadataSnapshot], str, int]:
        path = root.joinpath(*relative_parts, name)
        try:
            file_descriptor = os.open(
                name,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                dir_fd=parent_descriptor,
            )
        except FileNotFoundError:
            return (None, "unrecognized", 0)
        except OSError:
            try:
                named = os.stat(
                    name, dir_fd=parent_descriptor,
                    follow_symlinks=False)
            except OSError:
                return (None, "unreadable", 0)
            return (None, "unrecognized"
                    if stat.S_ISLNK(named.st_mode) else "unreadable", 0)
        try:
            before = os.fstat(file_descriptor)
            if (not stat.S_ISREG(before.st_mode)
                    or before.st_dev != home_device
                    or before.st_nlink != 1
                    or before.st_size > CLAUDE_DESKTOP_METADATA_MAX_BYTES):
                return (None, "unrecognized", 0)
            if before.st_size > remaining_bytes:
                return (None, "truncated", 0)
            with os.fdopen(os.dup(file_descriptor), "rb") as handle:
                raw = handle.read(CLAUDE_DESKTOP_METADATA_MAX_BYTES + 1)
            after = os.fstat(file_descriptor)
            try:
                named = os.stat(
                    name, dir_fd=parent_descriptor,
                    follow_symlinks=False)
            except OSError:
                return (None, "unrecognized", len(raw))
            if (len(raw) > CLAUDE_DESKTOP_METADATA_MAX_BYTES
                    or _stat_signature(before) != _stat_signature(after)
                    or _stat_signature(after) != _stat_signature(named)):
                return (None, "unrecognized", len(raw))
        finally:
            os.close(file_descriptor)

        unit_name = Path(name).stem
        try:
            unit_descriptor = os.open(
                unit_name, directory_flags, dir_fd=parent_descriptor)
        except FileNotFoundError:
            return (None, "unrecognized", len(raw))
        except OSError:
            try:
                named_unit = os.stat(
                    unit_name, dir_fd=parent_descriptor,
                    follow_symlinks=False)
            except OSError:
                return (None, "unreadable", len(raw))
            return (None, "unrecognized"
                    if stat.S_ISLNK(named_unit.st_mode) else "unreadable",
                    len(raw))
        try:
            unit_info = os.fstat(unit_descriptor)
            named_unit = os.stat(
                unit_name, dir_fd=parent_descriptor,
                follow_symlinks=False)
            if (not stat.S_ISDIR(unit_info.st_mode)
                    or unit_info.st_dev != home_device
                    or _stat_identity(unit_info) != _stat_identity(named_unit)):
                return (None, "unrecognized", len(raw))
        except OSError:
            return (None, "unreadable", len(raw))
        finally:
            os.close(unit_descriptor)
        return (
            _ClaudeDesktopMetadataSnapshot(
                path, raw, after, unit_info),
            "ok",
            len(raw),
        )

    def scan_directory(
            current_descriptor: int, relative_parts: tuple[str, ...],
            depth: int) -> None:
        nonlocal attempted_bytes, budget_exhausted, candidates_seen
        nonlocal entries_seen, truncated, unreadable, unrecognized
        try:
            entries_context = os.scandir(current_descriptor)
        except OSError:
            unreadable = True
            return
        with entries_context as entries:
            # Output is sorted after the walk. Streaming here keeps a corrupt
            # namespace from materialising all entries, and immediate recursion
            # holds only one descriptor per depth rather than per sibling.
            for entry in entries:
                entries_seen += 1
                if entries_seen > CLAUDE_DESKTOP_NAMESPACE_MAX_ENTRIES:
                    truncated = True
                    budget_exhausted = True
                    return
                if budget_exhausted:
                    return
                name = entry.name
                path_parts = (*relative_parts, name)
                try:
                    if name.startswith("local_"):
                        if name.endswith(".json"):
                            metadata_unit_paths.add(
                                (*relative_parts, Path(name).stem))
                            candidates_seen += 1
                            if (candidates_seen
                                    > CLAUDE_DESKTOP_METADATA_MAX_FILES):
                                truncated = True
                                budget_exhausted = True
                                return
                            snapshot, status, bytes_read = read_candidate(
                                current_descriptor, relative_parts, name,
                                CLAUDE_DESKTOP_METADATA_TOTAL_BYTES
                                - attempted_bytes)
                            attempted_bytes += bytes_read
                            if status == "truncated":
                                truncated = True
                                budget_exhausted = True
                                return
                            if status == "ok" and snapshot is not None:
                                snapshots.append(snapshot)
                            elif status == "unreadable":
                                unreadable = True
                            else:
                                unrecognized += 1
                        elif entry.is_dir(follow_symlinks=False):
                            # Same-named local_* directories are conversation
                            # bodies, never metadata namespaces. Record them so
                            # an orphaned body cannot disappear as a complete
                            # zero-session scan after its metadata is deleted.
                            conversation_unit_paths.add(path_parts)
                        else:
                            unrecognized += 1
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        if depth >= 3:
                            truncated = True
                            continue
                        child_descriptor = -1
                        try:
                            child_descriptor = os.open(
                                name, directory_flags,
                                dir_fd=current_descriptor)
                            child_info = os.fstat(child_descriptor)
                            named_child = os.stat(
                                name, dir_fd=current_descriptor,
                                follow_symlinks=False)
                            if (_stat_identity(child_info)
                                    != _stat_identity(named_child)
                                    or child_info.st_dev != home_device):
                                unreadable = True
                                continue
                            directory_signatures[path_parts] = _stat_signature(
                                child_info)
                            scan_directory(
                                child_descriptor, path_parts, depth + 1)
                        except OSError:
                            unreadable = True
                        finally:
                            if child_descriptor >= 0:
                                os.close(child_descriptor)
                    elif entry.is_symlink():
                        unrecognized += 1
                except OSError:
                    unreadable = True

    def namespace_is_stable() -> bool:
        """Revalidate every scanned namespace, unit, file, and visible root."""
        for relative_parts, expected in directory_signatures.items():
            current = os.dup(descriptor)
            try:
                for component in relative_parts:
                    child = -1
                    try:
                        child = os.open(
                            component, directory_flags, dir_fd=current)
                        opened = os.fstat(child)
                        named = os.stat(
                            component, dir_fd=current,
                            follow_symlinks=False)
                    except BaseException:
                        if child >= 0:
                            os.close(child)
                        raise
                    os.close(current)
                    current = child
                    if (not stat.S_ISDIR(opened.st_mode)
                            or opened.st_dev != home_device
                            or _stat_identity(opened)
                            != _stat_identity(named)):
                        return False
                if _stat_signature(os.fstat(current)) != expected:
                    return False
            finally:
                os.close(current)

        # A metadata file can be rewritten in place without changing its
        # parent directory's mtime.  Directory-only revalidation would then
        # publish a stale workspace while claiming complete coverage.  Reopen
        # every metadata/unit pair below the pinned store fd and require the
        # same identities and full signatures that produced the snapshot.
        for snapshot in snapshots:
            try:
                relative = snapshot.path.relative_to(root)
            except ValueError:
                return False
            current = os.dup(descriptor)
            metadata_descriptor = -1
            unit_descriptor = -1
            try:
                for component in relative.parts[:-1]:
                    child = -1
                    try:
                        child = os.open(
                            component, directory_flags, dir_fd=current)
                        opened = os.fstat(child)
                        named = os.stat(
                            component, dir_fd=current,
                            follow_symlinks=False)
                    except BaseException:
                        if child >= 0:
                            os.close(child)
                        raise
                    os.close(current)
                    current = child
                    if (not stat.S_ISDIR(opened.st_mode)
                            or opened.st_dev != home_device
                            or _stat_identity(opened)
                            != _stat_identity(named)):
                        return False
                metadata_descriptor = os.open(
                    relative.name,
                    os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                    | os.O_CLOEXEC,
                    dir_fd=current,
                )
                metadata_opened = os.fstat(metadata_descriptor)
                metadata_named = os.stat(
                    relative.name, dir_fd=current,
                    follow_symlinks=False)
                if (not stat.S_ISREG(metadata_opened.st_mode)
                        or metadata_opened.st_dev != home_device
                        or metadata_opened.st_nlink != 1
                        or _stat_signature(metadata_opened)
                        != _stat_signature(snapshot.metadata_info)
                        or _stat_signature(metadata_named)
                        != _stat_signature(snapshot.metadata_info)):
                    return False
                unit_descriptor = os.open(
                    relative.stem, directory_flags, dir_fd=current)
                unit_opened = os.fstat(unit_descriptor)
                unit_named = os.stat(
                    relative.stem, dir_fd=current,
                    follow_symlinks=False)
                if (not stat.S_ISDIR(unit_opened.st_mode)
                        or unit_opened.st_dev != home_device
                        or _stat_signature(unit_opened)
                        != _stat_signature(snapshot.unit_info)
                        or _stat_identity(unit_named)
                        != _stat_identity(snapshot.unit_info)):
                    return False
            finally:
                for opened_descriptor in (
                        unit_descriptor, metadata_descriptor, current):
                    if opened_descriptor >= 0:
                        os.close(opened_descriptor)

        visible = _open_directory_nofollow(canonical_home)
        try:
            for component in CLAUDE_DESKTOP_LOCAL_SESSIONS:
                child = -1
                try:
                    child = os.open(
                        component, directory_flags, dir_fd=visible)
                    opened = os.fstat(child)
                    named = os.stat(
                        component, dir_fd=visible,
                        follow_symlinks=False)
                except BaseException:
                    if child >= 0:
                        os.close(child)
                    raise
                os.close(visible)
                visible = child
                if (not stat.S_ISDIR(opened.st_mode)
                        or opened.st_dev != home_device
                        or _stat_identity(opened) != _stat_identity(named)):
                    return False
            return (_stat_signature(os.fstat(visible))
                    == directory_signatures[()])
        finally:
            os.close(visible)

    try:
        scan_directory(descriptor, (), 0)
        try:
            stable = namespace_is_stable()
        except OSError:
            stable = False
            unreadable = True
        if not stable:
            truncated = True
            snapshots.clear()
    finally:
        os.close(descriptor)

    unrecognized += len(conversation_unit_paths - metadata_unit_paths)
    store["unrecognized"] = unrecognized
    store["status"] = (
        "unreadable" if unreadable else
        "truncated" if truncated else
        "unrecognized" if unrecognized else
        "ok"
    )
    return (sorted(snapshots, key=lambda item: str(item.path)), store)


def _claude_desktop_metadata_files(home: Path) -> list[Path]:
    """Compatibility view for callers that need candidates but no coverage."""
    return [snapshot.path
            for snapshot in _claude_desktop_metadata_scan(home)[0]]


def _claude_desktop_metadata_for_path(path: Path) -> Optional[Path]:
    """The conversation metadata owning ``path``, without opening anything.

    A UI normally passes the top-level ``local_<id>.json``.  Accepting a path
    inside the matching directory as well keeps identity stable for callers
    that already hold the primary transcript: its id is still ``local_<id>``,
    never the especially collision-prone ``audit`` filename.
    """
    candidates = []
    if path.name.startswith("local_") and path.suffix == ".json":
        candidates.append(path)
    for parent in path.parents:
        if parent.name.startswith("local_"):
            candidates.append(parent.with_suffix(".json"))
    for metadata in candidates:
        if not any(parent.name == "local-agent-mode-sessions"
                   for parent in metadata.parents):
            continue
        if metadata.name.startswith("local_"):
            return metadata
    return None


def _claude_desktop_layout(
        path: Path, home: Optional[Path] = None
        ) -> tuple[Optional[Path], Optional[str], Optional[Path], str]:
    """Canonical home, store-relative metadata name, and canonical path."""
    metadata = _claude_desktop_metadata_for_path(path.expanduser().absolute())
    if metadata is None:
        return (None, None, None, "not-desktop")
    fixed = CLAUDE_DESKTOP_LOCAL_SESSIONS
    absolute = metadata.expanduser().absolute()
    relative: Optional[Path] = None
    canonical_home: Optional[Path] = None
    if home is not None:
        original_home = home.expanduser().absolute()
        try:
            canonical_home = original_home.resolve(strict=True)
        except OSError:
            return (None, None, None, "unreadable")
        for base in (original_home, canonical_home):
            try:
                candidate = absolute.relative_to(base)
            except ValueError:
                continue
            if candidate.parts[:len(fixed)] == fixed:
                relative = candidate
                break
    else:
        parts = absolute.parts
        for position in range(0, len(parts) - len(fixed) + 1):
            if tuple(parts[position:position + len(fixed)]) != fixed:
                continue
            home_parts = parts[:position]
            if not home_parts:
                continue
            try:
                canonical_home = Path(*home_parts).resolve(strict=True)
            except OSError:
                return (None, None, None, "unreadable")
            relative = Path(*parts[position:])
            break
    if canonical_home is None or relative is None:
        return (None, None, None, "unrecognized")
    if (relative.parts[:len(fixed)] != fixed
            or len(relative.parts) <= len(fixed)
            or relative.name != metadata.name):
        return (None, None, None, "unrecognized")
    relative_text = relative.as_posix()
    return (
        canonical_home,
        relative_text,
        canonical_home / relative,
        "ok",
    )


def _read_claude_desktop_metadata(
        path: Path, home: Optional[Path] = None) -> tuple[Optional[dict], str]:
    """Read the dedicated metadata object, returning no unfiltered fields.

    Callers copy only the explicit whitelist below.  The source object also
    contains account email, prompts, and remote MCP configuration; returning a
    status separately prevents a malformed object from being mistaken for an
    empty conversation.
    """
    canonical_home, relative, metadata, layout_status = (
        _claude_desktop_layout(path, home))
    if layout_status != "ok" or canonical_home is None or relative is None \
            or metadata is None:
        return (None, layout_status)
    home_descriptor = -1
    parent_descriptor = -1
    descriptor = -1
    try:
        home_descriptor = _open_directory_nofollow(canonical_home)
        home_info = os.fstat(home_descriptor)
        parent_descriptor = os.dup(home_descriptor)
        for component in Path(relative).parts[:-1]:
            child = -1
            try:
                child = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=parent_descriptor,
                )
                opened = os.fstat(child)
                named = os.stat(
                    component, dir_fd=parent_descriptor,
                    follow_symlinks=False)
                if (not stat.S_ISDIR(opened.st_mode)
                        or opened.st_dev != home_info.st_dev
                        or _stat_identity(opened) != _stat_identity(named)):
                    os.close(child)
                    child = -1
                    return (None, "unrecognized")
            except BaseException:
                if child >= 0:
                    os.close(child)
                raise
            os.close(parent_descriptor)
            parent_descriptor = child
            child = -1
        descriptor = os.open(
            Path(relative).name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=parent_descriptor,
        )
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode)
                or before.st_dev != home_info.st_dev
                or before.st_nlink != 1
                or before.st_size > CLAUDE_DESKTOP_METADATA_MAX_BYTES):
            return (None, "unrecognized")
        with os.fdopen(os.dup(descriptor), "rb") as handle:
            if (not stat.S_ISREG(before.st_mode)
                    or before.st_size > CLAUDE_DESKTOP_METADATA_MAX_BYTES):
                return (None, "unrecognized")
            raw = handle.read(CLAUDE_DESKTOP_METADATA_MAX_BYTES + 1)
        after = os.fstat(descriptor)
        current = os.stat(
            Path(relative).name, dir_fd=parent_descriptor,
            follow_symlinks=False)
    except FileNotFoundError:
        return (None, "missing")
    except OSError:
        return (None, "unreadable")
    finally:
        for opened_descriptor in (descriptor, parent_descriptor, home_descriptor):
            if opened_descriptor >= 0:
                try:
                    os.close(opened_descriptor)
                except OSError:
                    pass
    if (len(raw) > CLAUDE_DESKTOP_METADATA_MAX_BYTES
            or _stat_signature(before) != _stat_signature(after)
            or _stat_signature(after) != _stat_signature(current)):
        return (None, "unrecognized")
    payload = _parse_claude_desktop_metadata(raw, metadata.stem)
    return ((payload, "ok") if payload is not None
            else (None, "unrecognized"))


def _open_claude_desktop_primary(
        path: Path, home: Optional[Path] = None
        ) -> tuple[Optional[int], Optional[Path], str]:
    """Open the primary transcript through the pinned home directory."""
    canonical_home, relative, metadata, status = _claude_desktop_layout(
        path, home)
    if status != "ok" or canonical_home is None or relative is None \
            or metadata is None:
        return (None, None, status)
    home_descriptor = -1
    parent_descriptor = -1
    metadata_descriptor = -1
    unit_descriptor = -1
    primary_descriptor = -1
    try:
        home_descriptor = _open_directory_nofollow(canonical_home)
        home_info = os.fstat(home_descriptor)
        parent_descriptor = os.dup(home_descriptor)
        relative_path = Path(relative)
        for component in relative_path.parts[:-1]:
            child = -1
            try:
                child = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=parent_descriptor,
                )
                opened = os.fstat(child)
                named = os.stat(
                    component, dir_fd=parent_descriptor,
                    follow_symlinks=False)
                if (not stat.S_ISDIR(opened.st_mode)
                        or opened.st_dev != home_info.st_dev
                        or _stat_identity(opened) != _stat_identity(named)):
                    os.close(child)
                    child = -1
                    return (None, None, "unrecognized")
            except BaseException:
                if child >= 0:
                    os.close(child)
                raise
            os.close(parent_descriptor)
            parent_descriptor = child
            child = -1

        metadata_descriptor = os.open(
            relative_path.name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=parent_descriptor,
        )
        metadata_before = os.fstat(metadata_descriptor)
        if (not stat.S_ISREG(metadata_before.st_mode)
                or metadata_before.st_dev != home_info.st_dev
                or metadata_before.st_nlink != 1
                or metadata_before.st_size
                > CLAUDE_DESKTOP_METADATA_MAX_BYTES):
            return (None, None, "unrecognized")
        with os.fdopen(os.dup(metadata_descriptor), "rb") as handle:
            raw = handle.read(CLAUDE_DESKTOP_METADATA_MAX_BYTES + 1)
        metadata_after = os.fstat(metadata_descriptor)
        metadata_named = os.stat(
            relative_path.name, dir_fd=parent_descriptor,
            follow_symlinks=False)
        if (len(raw) > CLAUDE_DESKTOP_METADATA_MAX_BYTES
                or _stat_signature(metadata_before)
                != _stat_signature(metadata_after)
                or _stat_signature(metadata_after)
                != _stat_signature(metadata_named)):
            return (None, None, "unrecognized")
        payload = _parse_claude_desktop_metadata(raw, metadata.stem)
        if payload is None:
            return (None, None, "unrecognized")
        cli_session_id = payload["cliSessionId"]
        if re.fullmatch(r"[A-Za-z0-9_-]+", cli_session_id) is None:
            return (None, None, "unrecognized")
        unit_name = relative_path.stem
        unit_descriptor = os.open(
            unit_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_descriptor,
        )
        unit_info = os.fstat(unit_descriptor)
        named_unit = os.stat(
            unit_name, dir_fd=parent_descriptor,
            follow_symlinks=False)
        if (not stat.S_ISDIR(unit_info.st_mode)
                or unit_info.st_dev != home_info.st_dev
                or _stat_identity(unit_info) != _stat_identity(named_unit)):
            return (None, None, "unrecognized")

        entries_seen = 0
        primary_relative: Optional[Path] = None
        wanted_name = f"{cli_session_id}.jsonl"

        def scan_unit(current_descriptor: int, unit_parts: tuple[str, ...],
                      depth: int) -> bool:
            """Locate the unique primary with at most one fd per depth."""
            nonlocal entries_seen, primary_descriptor, primary_relative
            with os.scandir(current_descriptor) as entries:
                for entry in entries:
                    entries_seen += 1
                    if entries_seen > CLAUDE_DESKTOP_PRIMARY_SCAN_MAX_ENTRIES:
                        return False
                    name = entry.name
                    if entry.is_dir(follow_symlinks=False):
                        if depth >= BACKUP_MAX_DEPTH:
                            return False
                        child = -1
                        try:
                            child = os.open(
                                name,
                                os.O_RDONLY | os.O_DIRECTORY
                                | os.O_NOFOLLOW | os.O_CLOEXEC,
                                dir_fd=current_descriptor,
                            )
                            child_info = os.fstat(child)
                            named_child = os.stat(
                                name, dir_fd=current_descriptor,
                                follow_symlinks=False)
                            if (not stat.S_ISDIR(child_info.st_mode)
                                    or child_info.st_dev != home_info.st_dev
                                    or _stat_identity(child_info)
                                    != _stat_identity(named_child)):
                                return False
                            if not scan_unit(
                                    child, (*unit_parts, name), depth + 1):
                                return False
                        finally:
                            if child >= 0:
                                os.close(child)
                        continue
                    if name != wanted_name:
                        continue
                    candidate = -1
                    try:
                        candidate = os.open(
                            name,
                            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                            | os.O_CLOEXEC,
                            dir_fd=current_descriptor,
                        )
                        opened = os.fstat(candidate)
                        named = os.stat(
                            name, dir_fd=current_descriptor,
                            follow_symlinks=False)
                        if (not stat.S_ISREG(opened.st_mode)
                                or opened.st_dev != home_info.st_dev
                                or opened.st_nlink != 1
                                or _stat_signature(opened)
                                != _stat_signature(named)):
                            return False
                        if primary_descriptor >= 0:
                            return False
                        primary_descriptor = candidate
                        candidate = -1
                        primary_relative = Path(*unit_parts, name)
                    finally:
                        if candidate >= 0:
                            os.close(candidate)
            return True

        if not scan_unit(unit_descriptor, (), 0):
            return (None, None, "unrecognized")
        if primary_descriptor < 0 or primary_relative is None:
            return (None, None, "missing")
        metadata_final = os.fstat(metadata_descriptor)
        metadata_named_final = os.stat(
            relative_path.name, dir_fd=parent_descriptor,
            follow_symlinks=False)
        unit_named_final = os.stat(
            unit_name, dir_fd=parent_descriptor,
            follow_symlinks=False)
        if (_stat_signature(metadata_final)
                != _stat_signature(metadata_after)
                or _stat_signature(metadata_named_final)
                != _stat_signature(metadata_after)
                or not stat.S_ISDIR(unit_named_final.st_mode)
                or _stat_identity(unit_named_final)
                != _stat_identity(unit_info)):
            return (None, None, "unrecognized")
        result_descriptor = primary_descriptor
        primary_descriptor = -1
        return (
            result_descriptor,
            canonical_home / relative_path.with_suffix("") / primary_relative,
            "ok",
        )
    except FileNotFoundError:
        return (None, None, "missing")
    except (OSError, ValueError):
        return (None, None, "unreadable")
    finally:
        for opened_descriptor in (
                primary_descriptor, unit_descriptor, metadata_descriptor,
                parent_descriptor, home_descriptor):
            if opened_descriptor >= 0:
                try:
                    os.close(opened_descriptor)
                except OSError:
                    pass


def _parse_claude_desktop_metadata(raw: bytes, session_id: str) -> Optional[dict]:
    """Validate the stable Desktop conversation-unit identity shape.

    This pure parser is shared by the live store reader and ZIP verification.
    A backup is not complete merely because it contains a file named
    ``local_*.json``; the metadata must identify the unit and the one primary
    transcript that a person can actually resume.
    """
    if len(raw) > CLAUDE_DESKTOP_METADATA_MAX_BYTES:
        return None
    try:
        payload = json.loads(raw.decode("utf-8-sig"))
    # json.loads raises ValueError (including JSONDecodeError) when a numeric
    # literal exceeds Python's conversion guard, before the schema check below.
    except JSON_PARSE_ERRORS:
        return None
    if not isinstance(payload, dict):
        return None
    # A dedicated schema check is what keeps an arbitrary local_*.json plus a
    # directory from becoming an indexed conversation.  Extra fields are
    # expected and ignored; these identity/time/location fields are the stable
    # shape observed across every current unit.
    cli_session_id = payload.get("cliSessionId")
    cwd = payload.get("cwd")
    selected = payload.get("userSelectedFolders")
    title = payload.get("title")
    if (payload.get("sessionId") != session_id
            or len(session_id) > CLAUDE_DESKTOP_ID_MAX_CHARS
            or not _is_utf8_text(session_id)
            or re.fullmatch(r"local_[A-Za-z0-9_-]+", session_id) is None
            or not isinstance(cli_session_id, str)
            or not cli_session_id
            or len(cli_session_id) > CLAUDE_DESKTOP_ID_MAX_CHARS
            or not _is_utf8_text(cli_session_id)
            or re.fullmatch(r"[A-Za-z0-9_-]+", cli_session_id) is None
            or not isinstance(cwd, str)
            or not cwd
            or len(cwd) > CLAUDE_DESKTOP_LOCATION_MAX_CHARS
            or not _is_utf8_text(cwd)
            or type(payload.get("createdAt")) is not int
            or type(payload.get("lastActivityAt")) is not int
            or not 0 <= payload["createdAt"] <= CLAUDE_DESKTOP_TIMESTAMP_MAX_MS
            or not 0 <= payload["lastActivityAt"] <= CLAUDE_DESKTOP_TIMESTAMP_MAX_MS
            or not isinstance(selected, list)
            or len(selected) > CLAUDE_DESKTOP_SELECTED_FOLDERS_MAX
            or not all(isinstance(value, str)
                       and 0 < len(value) <= CLAUDE_DESKTOP_LOCATION_MAX_CHARS
                       and _is_utf8_text(value)
                       for value in selected)
            or (title is not None
                and (not isinstance(title, str)
                     or len(title) > CLAUDE_DESKTOP_TITLE_MAX_CHARS
                     or not _is_utf8_text(title)))):
        return None
    return payload


def _claude_desktop_primary_transcript(
        path: Path, home: Optional[Path] = None) -> tuple[Optional[Path], str]:
    """Resolve one Desktop conversation to its one person-visible JSONL.

    ``audit.jsonl``, subagent transcripts, queues, and every output remain
    sidecars.  The metadata's ``cliSessionId`` names the primary transcript;
    matching by that identity is what turns 423 JSONL files into the 94 actual
    conversations observed on this machine.
    """
    descriptor, primary, status = _open_claude_desktop_primary(path, home)
    if descriptor is not None:
        os.close(descriptor)
    return (primary, status)


def _safe_location(value: Any) -> Optional[dict]:
    """A path-shaped metadata value reduced to a bounded basename.

    The descriptor itself never stats an arbitrary provider path: a selected
    folder can be a sleeping network mount or a TCC-protected path. Existence
    remains unknown here; the one Work representative is checked separately in
    a timeout-isolated child process.
    """
    if (not isinstance(value, str) or not value or "\x00" in value
            or len(value) > CLAUDE_DESKTOP_LOCATION_MAX_CHARS):
        return None
    path = Path(value)
    return {"basename": path.name or path.anchor or "/", "exists": None}


def _desktop_epoch(value: Any, fallback: float) -> float:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        # Claude Desktop records milliseconds since epoch.
        try:
            result = float(value) / 1000.0
            if not math.isfinite(result):
                return fallback
            # build_sessions formats this value with localtime. Validate here
            # so one corrupted metadata integer cannot abort the whole index.
            time.localtime(result)
            return result
        except (OverflowError, OSError, ValueError):
            return fallback
    return fallback


def _collect_claude_desktop_sessions_with_coverage(
        home: Path) -> tuple[list[dict], dict]:
    """Return Desktop conversations plus explicit discovery completeness."""
    records: list[dict] = []
    metadata_snapshots, store = _claude_desktop_metadata_scan(home)
    unreadable = store["status"] == "unreadable"
    truncated = store["status"] == "truncated"
    unrecognized = int(store["unrecognized"])
    parsed_snapshots: list[tuple[_ClaudeDesktopMetadataSnapshot, dict]] = []
    workspace_locations: list[str] = []
    for snapshot in metadata_snapshots:
        payload = _parse_claude_desktop_metadata(
            snapshot.raw, snapshot.path.stem)
        if payload is None:
            unrecognized += 1
            continue
        parsed_snapshots.append((snapshot, payload))
        cwd, selected_folders, _ = _desktop_binding_locations(payload)
        workspace_locations.extend(selected_folders or (() if cwd is None else (cwd,)))

    location_status, probe_complete = _desktop_location_statuses_isolated(
        workspace_locations)
    if not probe_complete:
        truncated = True

    for snapshot, payload in parsed_snapshots:
        metadata = snapshot.path
        metadata_info = snapshot.metadata_info
        unit_info = snapshot.unit_info
        fallback = max(metadata_info.st_mtime, unit_info.st_mtime)
        cwd = _safe_location(payload.get("cwd"))
        selected = [location for value in payload.get("userSelectedFolders", [])
                    for location in [_safe_location(value)] if location]
        workspace, workspace_exists = _desktop_index_workspace(
            payload, location_status)
        last_activity = _desktop_epoch(payload.get("lastActivityAt"), fallback)
        session_id = payload.get("sessionId")
        if not isinstance(session_id, str) or not session_id:
            session_id = metadata.stem
        title = payload.get("title") if isinstance(payload.get("title"), str) else None
        records.append({
            "kind": "session",
            "tool": CLAUDE_DESKTOP_TOOL,
            "provider": CLAUDE_DESKTOP_PROVIDER,
            "session_id": session_id,
            # The metadata JSON is the stable conversation-unit handle.  The
            # primary JSONL is an implementation detail resolved only by an
            # explicit content read.
            "source": str(metadata),
            # One representative provider-selected folder lets Work group the
            # conversation with its project. Other selected folders remain
            # binder-only so one conversation is never duplicated across Work
            # projects. The display descriptors below remain basename-only.
            "workspace": workspace,
            "workspace_exists": workspace_exists,
            # Listing must never recurse through a 2 GB sandbox. The exact
            # owned-unit byte count is produced by the explicit backup receipt;
            # this metadata byte count is intentionally marked incomplete.
            "size_bytes": metadata_info.st_size,
            "size_complete": False,
            "last_active": last_activity,
            "repo_url": None,
            "branch": None,
            "weight": 1,
            "desktop_metadata": {
                "title": mask_text(title, home) if title is not None else None,
                "createdAt": payload.get("createdAt")
                             if type(payload.get("createdAt")) is int else None,
                "lastActivityAt": payload.get("lastActivityAt")
                                  if type(payload.get("lastActivityAt")) is int else None,
                "cwd": cwd,
                "userSelectedFolders": selected,
            },
        })
    store.update({
        "status": (
            "unreadable" if unreadable else
            "truncated" if truncated else
            "unrecognized" if unrecognized else
            store["status"]
        ),
        "count": len(records),
        "unrecognized": unrecognized,
    })
    return (records, store)


def collect_claude_desktop_sessions(home: Path) -> list[dict]:
    """One whitelisted metadata record per Claude Desktop Code conversation."""
    return _collect_claude_desktop_sessions_with_coverage(home)[0]


def collect_codex(home: Path) -> tuple[list[dict], dict]:
    records: list[dict] = []
    unrecognized = 0
    roots = [home / ".codex" / "sessions", home / ".codex" / "archived_sessions"]
    seen_root = False
    for root in roots:
        if not root.is_dir():
            continue
        seen_root = True
        for path in sorted(root.rglob("*.jsonl")):
            try:
                with path.open("r", encoding="utf-8", errors="replace") as handle:
                    first = _read_json_line(handle)
            except OSError:
                unrecognized += 1
                continue
            payload = (first or {}).get("payload")
            if (first or {}).get("type") != "session_meta" or not isinstance(payload, dict):
                unrecognized += 1
                continue
            git = payload.get("git") if isinstance(payload.get("git"), dict) else {}
            records.append(_record(
                "Codex", "session", path, payload.get("cwd"),
                repo_url=git.get("repository_url"), branch=git.get("branch")))
    status = {"store": "Codex", "status": "ok" if seen_root else "missing",
              "count": len(records), "unrecognized": unrecognized}
    return records, status


# Claude derives a project directory name from the session's cwd by replacing
# every non-alphanumeric character -- not only the separators -- with a hyphen,
# then capping the result. '.', '_', spaces and every non-ASCII character all
# collapse to the same '-', so the encoding is lossy and cannot be inverted by
# string surgery.
CLAUDE_BUCKET_CAP = 200
_CLAUDE_BUCKET_UNSAFE = re.compile(r"[^a-zA-Z0-9]")
# Directories examined while resolving one bucket name. A bucket that needs
# more than this is left unresolved rather than resolved slowly.
_CLAUDE_BUCKET_BUDGET = 4096


def _encode_claude_project_dir(path: str) -> str:
    """The name Claude would file a session at this cwd under."""
    return _CLAUDE_BUCKET_UNSAFE.sub("-", path)[:CLAUDE_BUCKET_CAP]


def _decode_claude_project_dir(
        name: str, *, allow_directory_listing: bool = True) -> Optional[str]:
    """Resolve '-Users-ren-my-proj' back to the directory it was encoded from.

    Segmenting the name on hyphens and testing each candidate for existence is
    not enough, because a path component made only of non-alphanumeric
    characters encodes to hyphens and nothing else: a home directory and a
    two-character subdirectory of it differ by three hyphens and nothing more.
    And `Path(x) / ""` is `x`, so an
    empty segment tested as a directory reports that it exists and the walk
    stops early -- returning an *ancestor* of the real path, confidently and
    silently, exactly where the name is hardest to read. The ancestor is
    usually another live workspace, so every session and nested transcript
    filed under the bucket is misattributed to it.

    A component that encodes to itself -- every plain ASCII one -- is still
    tried by name, which costs one stat() and covers the ordinary case. Only
    when no name at a level matches is that one directory enumerated and its
    children matched on their encoded form, the way the app resolves it. A
    bucket that resolves to more than one directory is ambiguous by
    construction and is left unresolved: scree reports an unresolved workspace
    as unresolved, and that is the honest answer here.

    Automatic app indexing passes ``allow_directory_listing=False``. That
    preserves exact ASCII path resolution without opening arbitrary folders
    below ``/`` in the GUI's TCC context. The full ambiguity resolver remains
    available to explicit callers and its isolated contract tests.
    """
    if not name.startswith("-"):
        return None
    truncated = len(name) >= CLAUDE_BUCKET_CAP
    budget = {"nodes": 4096, "listings": 64}

    def spend(kind: str) -> bool:
        budget[kind] -= 1
        return budget[kind] >= 0

    def enumerate_matches(current: Path, rest: str) -> list[Path]:
        if not allow_directory_listing:
            return []
        if not spend("listings"):
            return []
        try:
            children = sorted(c for c in current.iterdir() if c.is_dir())
        except OSError:
            return []
        found: list[Path] = []
        for child in children:
            if not spend("nodes"):
                return found[:2]
            token = _encode_claude_project_dir(child.name)
            if rest == token or (truncated and token.startswith(rest)):
                found.append(child)
            elif rest.startswith(f"{token}-"):
                found.extend(resolve(child, rest[len(token) + 1:]))
            if len(found) > 1:
                return found[:2]
        return found

    def resolve(current: Path, rest: str) -> list[Path]:
        if not rest:
            return [current]
        found: list[Path] = []
        for cut in [i for i, ch in enumerate(rest) if ch == "-"] + [len(rest)]:
            head = rest[:cut]
            if not head or not spend("nodes"):
                continue
            child = current / head
            if not child.is_dir():
                continue
            found.extend(resolve(child, rest[cut + 1:]))
            if len(found) > 1:
                return found[:2]
        # Every name at this level failed, so the component here encodes to
        # something other than itself. Widen to this directory only.
        return found or enumerate_matches(current, rest)

    matches = resolve(Path("/"), name[1:])
    if len(matches) != 1:
        return None
    resolved = str(matches[0])
    # The walk may take a symlinked route ('/var' -> '/private/var'); only a
    # path that re-encodes to this bucket can be the one it names.
    return resolved if _encode_claude_project_dir(resolved) == name else None


def collect_claude(home: Path) -> tuple[list[dict], dict]:
    records: list[dict] = []
    root = home / ".claude" / "projects"
    # Do not let a relocated Claude root or one linked bucket turn a local
    # metadata scan into an arbitrary protected/network directory walk.
    claude_root = home / ".claude"
    try:
        claude_info = claude_root.lstat()
        root_info = root.lstat()
    except FileNotFoundError:
        return records, {
            "store": "Claude", "status": "missing",
            "count": 0, "unrecognized": 0,
        }
    except OSError:
        return records, {
            "store": "Claude", "status": "unreadable",
            "count": 0, "unrecognized": 0,
        }
    if (not stat.S_ISDIR(claude_info.st_mode)
            or not stat.S_ISDIR(root_info.st_mode)):
        return records, {
            "store": "Claude", "status": "unrecognized",
            "count": 0, "unrecognized": 1,
        }
    try:
        with os.scandir(root) as entries:
            project_dirs = sorted(
                Path(entry.path) for entry in entries
                if entry.is_dir(follow_symlinks=False)
            )
    except OSError:
        return records, {
            "store": "Claude", "status": "unreadable",
            "count": 0, "unrecognized": 0,
        }
    unresolved = 0
    sessions = 0
    subtranscripts = 0
    for project_dir in project_dirs:
        # The transcript's own cwd is stronger evidence than Claude's lossy
        # bucket name and avoids filesystem-wide reverse lookup. Read every
        # top-level session first, then use a no-directory-listing fallback
        # only when the bucket contains no explicit cwd at all.
        pending_sessions: list[
            tuple[Path, Optional[str], Optional[str], set[str]]
        ] = []
        for path in sorted(
                candidate for candidate in project_dir.glob("*.jsonl")
                if not candidate.is_symlink() and candidate.is_file()):
            workspace = None
            branch = None
            identifiers = {path.stem}
            try:
                with path.open("r", encoding="utf-8", errors="replace") as handle:
                    for _ in range(CLAUDE_SCAN_LINES):
                        line = _read_json_line(handle)
                        if line is None:
                            break
                        if isinstance(line.get("sessionId"), str) and line["sessionId"]:
                            identifiers.add(line["sessionId"])
                        if not workspace and isinstance(line.get("cwd"), str):
                            workspace = line["cwd"]
                            branch = line.get("gitBranch") if isinstance(line.get("gitBranch"), str) else None
                            break
            except OSError:
                pass
            pending_sessions.append((path, workspace, branch, identifiers))

        # Never borrow one session's cwd for a different session that did not
        # record one. Distinct non-ASCII paths can share the same lossy bucket;
        # an explicit cwd proves only that session's location. A bucket-derived
        # fallback is admissible only when the bucket has no explicit cwd and
        # the restricted decoder independently identifies one exact path.
        fallback = None
        if pending_sessions and not any(workspace for _, workspace, _, _ in pending_sessions):
            fallback = _decode_claude_project_dir(
                project_dir.name, allow_directory_listing=False)

        owner_workspaces: dict[str, set[str]] = {}
        for path, workspace, branch, identifiers in pending_sessions:
            workspace = workspace or fallback
            if not workspace:
                unresolved += 1
            else:
                for identifier in identifiers:
                    owner_workspaces.setdefault(identifier, set()).add(workspace)
            records.append(_record("Claude", "session", path, workspace, branch=branch))
            sessions += 1

        # Nested files are per-session subagent/workflow transcripts. Walk
        # without following links and attribute each subtree by its owning
        # session id. One lossy bucket may legitimately contain sessions from
        # different cwd values, so a bucket-wide first-cwd aggregate is unsafe.
        nested_by_workspace: dict[str, list[os.stat_result]] = {}
        observed_nested = 0
        for current, dirs, files in os.walk(project_dir, followlinks=False):
            current_path = Path(current)
            dirs[:] = sorted(
                name for name in dirs
                if not (current_path / name).is_symlink()
            )
            if current_path == project_dir:
                continue
            try:
                owner = current_path.relative_to(project_dir).parts[0]
            except (ValueError, IndexError):
                continue
            candidates = owner_workspaces.get(owner, set())
            owner_workspace = fallback or (
                next(iter(candidates)) if len(candidates) == 1 else None
            )
            for name in sorted(files):
                nested = current_path / name
                if not name.endswith(".jsonl") or nested.is_symlink():
                    continue
                try:
                    nested_info = nested.lstat()
                    if not stat.S_ISREG(nested_info.st_mode):
                        continue
                except OSError:
                    continue
                observed_nested += 1
                if owner_workspace:
                    nested_by_workspace.setdefault(owner_workspace, []).append(nested_info)

        subtranscripts += observed_nested
        for workspace, nested_info in sorted(nested_by_workspace.items()):
            records.append({
                "tool": "Claude",
                "kind": "subtranscripts",
                "workspace": _canon_workspace(workspace),
                "repo_url": None,
                "branch": None,
                "size_bytes": sum(info.st_size for info in nested_info),
                "last_active": max(info.st_mtime for info in nested_info),
                "weight": 0,
            })
    return records, {"store": "Claude", "status": "ok", "count": sessions,
                     "unrecognized": unresolved, "subtranscripts": subtranscripts}


def collect_vscode_forks(home: Path) -> tuple[list[dict], list[dict]]:
    records: list[dict] = []
    statuses: list[dict] = []
    for tool, dir_name in VSCODE_FORKS:
        root = home / "Library" / "Application Support" / dir_name / "User" / "workspaceStorage"
        if not root.is_dir():
            statuses.append({"store": tool, "status": "missing", "count": 0, "unrecognized": 0})
            continue
        count = 0
        unrecognized = 0
        for meta_path in sorted(root.glob("*/workspace.json")):
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8-sig"))
            except JSON_FILE_ERRORS:
                unrecognized += 1
                continue
            if not isinstance(meta, dict):
                unrecognized += 1
                continue
            target = meta.get("folder") or meta.get("workspace")
            workspace = _uri_to_path(target) if isinstance(target, str) else None
            if not workspace:
                unrecognized += 1
                continue
            records.append(_record(tool, "workspace_state", meta_path.parent, workspace))
            count += 1
        statuses.append({"store": tool, "status": "ok", "count": count,
                         "unrecognized": unrecognized})
    return records, statuses


def collect_gemini(home: Path) -> tuple[list[dict], dict]:
    registry = home / ".gemini" / "projects.json"
    if not registry.is_file():
        return [], {"store": "Gemini", "status": "missing", "count": 0, "unrecognized": 0}
    try:
        data = json.loads(registry.read_text(encoding="utf-8-sig"))
    except JSON_FILE_ERRORS:
        return [], {"store": "Gemini", "status": "unrecognized", "count": 0, "unrecognized": 1}
    if not isinstance(data, dict):
        return [], {"store": "Gemini", "status": "unrecognized", "count": 0, "unrecognized": 1}
    if not isinstance(data.get("projects"), dict):
        return [], {"store": "Gemini", "status": "unrecognized", "count": 0, "unrecognized": 1}
    projects = data["projects"]
    records = [_record("Gemini", "project_state", registry, workspace)
               for workspace in sorted(projects)]
    return records, {"store": "Gemini", "status": "ok", "count": len(records), "unrecognized": 0}


WORKTREE_ANCESTOR_PROBE_LIMIT = 16
WORKTREE_GIT_BUDGET_SECONDS = 8.0
WORKTREE_GIT_COMMAND_TIMEOUT_SECONDS = 0.75
WORKTREE_DISCOVERY_ISOLATION_SECONDS = 10.0
WORKTREE_DISCOVERY_MAX_OUTPUT_BYTES = 8 * 1024 * 1024


def _git(args: list[str], cwd: Path, *,
         timeout: float = WORKTREE_GIT_COMMAND_TIMEOUT_SECONDS) -> Optional[str]:
    try:
        cwd_fd = _open_directory_nofollow(cwd)
    except (OSError, ValueError):
        return None
    try:
        before = os.fstat(cwd_fd)
        before_identity = (before.st_dev, before.st_ino)
        # subprocess does not accept a directory fd as cwd on macOS, and
        # /dev/fd/N cannot be chdir'd there. This CLI is single-threaded, so its
        # child can safely fchdir to the inherited, no-follow-opened descriptor
        # immediately before exec. The git process never traverses cwd's path.
        def chdir_to_verified_directory() -> None:
            os.fchdir(cwd_fd)

        proc = subprocess.run(
            ["git", *args], pass_fds=(cwd_fd,),
            preexec_fn=chdir_to_verified_directory,
            capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        os.close(cwd_fd)
    try:
        current_fd = _open_directory_nofollow(cwd)
        try:
            current = os.fstat(current_fd)
        finally:
            os.close(current_fd)
    except (OSError, ValueError):
        return None
    if (current.st_dev, current.st_ino) != before_identity:
        return None
    return proc.stdout if proc.returncode == 0 else None


def _lexical_abspath(value: str) -> Path:
    """Normalize spelling only; never resolve symlinks or touch the disk."""
    return Path(os.path.abspath(os.path.normpath(value)))


def _worktree_containers_from_records(
        records: list[dict]) -> tuple[list[Path], int, bool, dict[Path, set[Path]]]:
    """Build exact container probes from recorded workspaces only.

    The old implementation walked every directory below ``~/IdeaProjects``
    and ``~/Documents`` to depth five. Besides being outside the metadata
    scope claimed by the report, one slow or TCC-blocked directory could keep
    the GUI spinner alive for minutes. A session already records its cwd, so
    probe that path and at most 15 of its ancestors for the exact
    ``.claude/worktrees`` suffix. A cwd already inside
    ``<repo>/.claude/worktrees/<name>`` names its container lexically and needs
    no ancestor search.
    """
    workspaces: dict[str, Path] = {}
    for record in records:
        raw = record.get("workspace")
        if not isinstance(raw, str) or not raw.strip():
            continue
        workspace = _lexical_abspath(raw)
        workspaces.setdefault(str(workspace), workspace)

    candidates: dict[str, Path] = {}
    metadata_children: dict[Path, set[Path]] = {}
    probe_truncated = False
    for workspace in sorted(workspaces.values(), key=str):
        parts = workspace.parts
        lexical_containers: list[Path] = []
        for index in range(len(parts) - 2):
            if (parts[index] == ".claude" and parts[index + 1] == "worktrees"
                    and index + 2 < len(parts)):
                lexical_containers.append(Path(*parts[:index + 2]))
                container = Path(*parts[:index + 2])
                child = Path(*parts[:index + 3])
                metadata_children.setdefault(container, set()).add(child)
        if lexical_containers:
            for container in lexical_containers:
                candidates.setdefault(str(container), container)
            continue

        current = workspace
        reached_root = False
        for _ in range(WORKTREE_ANCESTOR_PROBE_LIMIT):
            candidate = current / ".claude" / "worktrees"
            candidates.setdefault(str(candidate), candidate)
            parent = current.parent
            if parent == current:
                reached_root = True
                break
            current = parent
        if not reached_root:
            probe_truncated = True
    return (sorted(candidates.values(), key=str), len(workspaces), probe_truncated,
            metadata_children)


def _open_directory_nofollow(path: Path) -> int:
    """Open every lexical path component without crossing a symlink."""
    normalized = _lexical_abspath(str(path))
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fd = os.open(os.sep, flags)
    try:
        for component in normalized.parts[1:]:
            next_fd = os.open(component, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
    except BaseException:
        os.close(fd)
        raise
    return fd


def _open_or_create_owned_output_parent(path: Path) -> tuple[int, Path]:
    """Open/create an export parent without following any path component."""
    normalized = _lexical_abspath(str(path))
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open(os.sep, flags)
    try:
        for component in normalized.parts[1:]:
            child = -1
            try:
                try:
                    child = os.open(component, flags, dir_fd=descriptor)
                except FileNotFoundError:
                    try:
                        os.mkdir(component, 0o700, dir_fd=descriptor)
                    except FileExistsError:
                        pass
                    child = os.open(component, flags, dir_fd=descriptor)
                opened = os.fstat(child)
                named = os.stat(
                    component, dir_fd=descriptor,
                    follow_symlinks=False)
                if (not stat.S_ISDIR(opened.st_mode)
                        or _stat_identity(opened) != _stat_identity(named)):
                    raise ValueError("export directory changed while opening")
            except BaseException:
                if child >= 0:
                    os.close(child)
                raise
            os.close(descriptor)
            descriptor = child
        parent_info = os.fstat(descriptor)
        if parent_info.st_uid != os.geteuid():
            raise PermissionError("export directory is not owned by the current user")
        return (descriptor, normalized)
    except BaseException:
        os.close(descriptor)
        raise


def _wire_text(value: str) -> str:
    """Replace non-scalar surrogate code points at the output boundary.

    JSON permits lone surrogate escapes, but the resulting Python string cannot
    be encoded as UTF-8. One damaged provider record must not turn an entire
    JSON API (or a Markdown export) into an empty response. Preserve every
    valid character and make only those invalid scalar values explicit.
    """
    try:
        value.encode("utf-8")
        return value
    except UnicodeEncodeError:
        return "".join(
            "\N{REPLACEMENT CHARACTER}" if 0xD800 <= ord(character) <= 0xDFFF
            else character
            for character in value
        )


def _print_wire(value: str) -> None:
    print(_wire_text(value))


def _filesystem_name_units(value: str) -> int:
    """Return APFS/HFS+'s UTF-16 code-unit count for one filename."""
    return len(value.encode("utf-16-le")) // 2


def _truncate_name_to_units(value: str, maximum: int) -> str:
    """Take a Unicode-scalar prefix within a macOS filename budget."""
    if maximum <= 0:
        return ""
    result: list[str] = []
    used = 0
    for character in value:
        units = _filesystem_name_units(character)
        if used + units > maximum:
            break
        result.append(character)
        used += units
    return "".join(result)


def _write_preserve_output(destination: Path, text: str) -> Path:
    """Create one private export without replacing any existing name."""
    requested = _lexical_abspath(str(destination))
    requested_name = _validated_leaf_name(requested.name)
    parent_descriptor, parent = _open_or_create_owned_output_parent(
        requested.parent)
    parent_identity = _stat_identity(os.fstat(parent_descriptor))
    descriptor = -1
    created_name: Optional[str] = None
    created_identity: Optional[tuple[int, int]] = None
    try:
        suffix = "".join(Path(requested_name).suffixes)
        stem = (requested_name[:-len(suffix)] if suffix
                else requested_name)
        try:
            name_max = int(os.fpathconf(parent_descriptor, "PC_NAME_MAX"))
        except (OSError, ValueError):
            name_max = 255
        for attempt in range(65):
            if attempt == 0:
                candidate = requested_name
            else:
                random_tail = "-" + os.urandom(16).hex()
                suffix_units = _filesystem_name_units(suffix)
                tail_units = _filesystem_name_units(random_tail)
                # Keep the requested extension when it fits, and shorten only
                # the stem by filesystem bytes. A valid NAME_MAX-sized first
                # choice must still have a valid create-only collision sibling.
                collision_suffix = (
                    suffix if suffix_units + tail_units <= name_max else "")
                budget = (name_max - tail_units
                          - _filesystem_name_units(collision_suffix))
                collision_stem = _truncate_name_to_units(stem, budget)
                candidate = collision_stem + random_tail + collision_suffix
            _validated_leaf_name(candidate)
            try:
                descriptor = os.open(
                    candidate,
                    os.O_RDWR | os.O_CREAT | os.O_EXCL
                    | os.O_NOFOLLOW | os.O_CLOEXEC,
                    0o600,
                    dir_fd=parent_descriptor,
                )
            except FileExistsError:
                continue
            created_name = candidate
            break
        if descriptor < 0 or created_name is None:
            raise ValueError("could not allocate a private export filename")
        created = os.fstat(descriptor)
        created_identity = _stat_identity(created)
        if (not stat.S_ISREG(created.st_mode)
                or created.st_nlink != 1
                or created.st_uid != os.geteuid()):
            raise ValueError("export output is not a private regular file")
        os.fchmod(descriptor, 0o600)
        encoded = _wire_text(text).encode("utf-8")
        expected_digest = hashlib.sha256(encoded).hexdigest()
        with os.fdopen(os.dup(descriptor), "wb") as handle:
            handle.write(encoded)
            handle.flush()
        os.fsync(descriptor)
        # Resolve the name before reading the held inode back. A same-user
        # process can open our 0600 file, and previously a mutation triggered
        # at this namespace check still received a success receipt.
        named_after = os.stat(
            created_name, dir_fd=parent_descriptor,
            follow_symlinks=False)
        before_read = os.fstat(descriptor)
        os.lseek(descriptor, 0, os.SEEK_SET)
        digest = hashlib.sha256()
        actual_size = 0
        with os.fdopen(os.dup(descriptor), "rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                actual_size += len(chunk)
                digest.update(chunk)
        after_read = os.fstat(descriptor)
        named_final = os.stat(
            created_name, dir_fd=parent_descriptor,
            follow_symlinks=False)
        opened_final = os.fstat(descriptor)
        if (not stat.S_ISREG(named_after.st_mode)
                or not stat.S_ISREG(named_final.st_mode)
                or named_final.st_nlink != 1
                or named_final.st_uid != os.geteuid()
                or stat.S_IMODE(named_final.st_mode) != 0o600
                or stat.S_IMODE(opened_final.st_mode) != 0o600
                or actual_size != len(encoded)
                or digest.hexdigest() != expected_digest
                or _content_signature(before_read)
                != _content_signature(after_read)
                or _stat_signature(after_read) != _stat_signature(opened_final)
                or _stat_signature(named_final) != _stat_signature(opened_final)
                or _stat_identity(opened_final) != created_identity
                or _stat_identity(named_after) != created_identity):
            raise ValueError("export output changed during creation")
        visible_parent = _open_directory_nofollow(parent)
        try:
            if _stat_identity(os.fstat(visible_parent)) != parent_identity:
                raise ValueError("export directory changed during creation")
        finally:
            os.close(visible_parent)
        named_return = os.stat(
            created_name, dir_fd=parent_descriptor,
            follow_symlinks=False)
        opened_return = os.fstat(descriptor)
        if (_stat_signature(named_return) != _stat_signature(opened_return)
                or _stat_signature(opened_return)
                != _stat_signature(opened_final)):
            raise ValueError("export output changed during creation")
        return parent / created_name
    except BaseException:
        if created_name is not None and created_identity is not None:
            try:
                named = os.stat(
                    created_name, dir_fd=parent_descriptor,
                    follow_symlinks=False)
                if (_stat_identity(named) == created_identity
                        and stat.S_ISREG(named.st_mode)):
                    os.unlink(created_name, dir_fd=parent_descriptor)
            except OSError:
                pass
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_descriptor)


def _existing_worktree_containers(
        candidates: list[Path]) -> tuple[list[Path], int, dict[Path, Path]]:
    """Accept real directories and collapse lexical aliases by opened inode."""
    containers: list[Path] = []
    unreadable = 0
    aliases: dict[Path, Path] = {}
    by_identity: dict[tuple[int, int], Path] = {}
    for candidate in candidates:
        try:
            fd = _open_directory_nofollow(candidate)
        except FileNotFoundError:
            continue
        except (OSError, ValueError):
            unreadable += 1
            continue
        try:
            info = os.fstat(fd)
        finally:
            os.close(fd)
        identity = (info.st_dev, info.st_ino)
        representative = by_identity.get(identity)
        if representative is None:
            representative = candidate
            by_identity[identity] = representative
            containers.append(representative)
        aliases[candidate] = representative
    return containers, unreadable, aliases


def _remap_metadata_children(
        children: dict[Path, set[Path]], aliases: dict[Path, Path]
        ) -> dict[Path, set[Path]]:
    remapped: dict[Path, set[Path]] = {}
    for container, paths in children.items():
        representative = aliases.get(container, container)
        for child in paths:
            remapped.setdefault(representative, set()).add(representative / child.name)
    return remapped


def _container_aliases_by_representative(
        aliases: dict[Path, Path]) -> dict[Path, set[Path]]:
    result: dict[Path, set[Path]] = {}
    for alias, representative in aliases.items():
        result.setdefault(representative, set()).add(alias)
    return result


def _relative_below_aliases(path: str, parents: set[Path]) -> Optional[str]:
    for parent in sorted(parents, key=str):
        if _path_is_below(path, parent):
            return os.path.relpath(path, str(parent))
    return None


def _has_worktree_registry_nofollow(repo: Path) -> bool:
    """Whether an exact candidate repo has a local linked-worktree registry."""
    try:
        repo_fd = _open_directory_nofollow(repo)
    except (OSError, ValueError):
        return False
    try:
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        git_fd = os.open(".git", flags, dir_fd=repo_fd)
    except (OSError, ValueError):
        return False
    finally:
        os.close(repo_fd)
    try:
        registry_fd = os.open("worktrees", flags, dir_fd=git_fd)
    except (OSError, ValueError):
        return False
    finally:
        os.close(git_fd)
    os.close(registry_fd)
    return True


@dataclass
class _WorktreeGitBudget:
    """One monotonic ceiling shared by every git query in a report."""

    deadline: float
    exhausted: bool = False

    @classmethod
    def start(cls) -> "_WorktreeGitBudget":
        return cls(time.monotonic() + max(0.0, WORKTREE_GIT_BUDGET_SECONDS))

    def run(self, args: list[str], cwd: Path) -> Optional[str]:
        remaining = self.deadline - time.monotonic()
        if self.exhausted or remaining <= 0.001:
            self.exhausted = True
            return None
        output = _git(
            args, cwd,
            timeout=min(WORKTREE_GIT_COMMAND_TIMEOUT_SECONDS, remaining),
        )
        if time.monotonic() >= self.deadline:
            # The completed command's output is still valid, but no later
            # command may extend the report beyond the shared budget.
            self.exhausted = True
        return output


def _normalized_git_path(value: str) -> str:
    """Git porcelain paths are compared lexically; never call resolve()."""
    return str(_lexical_abspath(value))


def _path_is_below(path: str, parent: Path) -> bool:
    parent_text = str(parent)
    try:
        return os.path.commonpath((path, parent_text)) == parent_text and path != parent_text
    except ValueError:
        return False


def _direct_worktree_children(container: Path) -> tuple[list[Path], bool]:
    """List one descriptor-bound directory level and reject symlink children."""
    try:
        fd = _open_directory_nofollow(container)
    except (OSError, ValueError):
        return [], False
    try:
        with os.scandir(fd) as entries:
            children = []
            for entry in entries:
                try:
                    if entry.is_dir(follow_symlinks=False):
                        children.append(container / entry.name)
                except OSError:
                    continue
    except (OSError, ValueError):
        return [], False
    finally:
        os.close(fd)
    return sorted(children, key=str), True


def _worktree_verdict(dirty: Optional[bool], unpushed: Optional[int]) -> str:
    """protected fires on any positive evidence even with one signal unknown
    (a confirmed risk doesn't need the other check to also succeed).
    rebuildable requires BOTH confirmed clean/pushed -- not protected is not
    the same as confirmed safe. Previously "not protected" fell straight
    through to rebuildable, so a git command failing partway through (e.g.
    status succeeds, rev-list against remotes fails) produced rebuildable
    instead of unreadable."""
    if dirty or (unpushed or 0) > 0:
        return "protected"
    if dirty is None or unpushed is None:
        return "unreadable"
    return "rebuildable"


def _worktree_item_identity(item: dict) -> tuple:
    path = Path(item["path"])
    try:
        fd = _open_directory_nofollow(path)
        try:
            info = os.fstat(fd)
        finally:
            os.close(fd)
    except (OSError, ValueError):
        # Missing/unreadable paths have no proof of identity. Preserve exact
        # spellings: a case-sensitive APFS/external volume may hold both.
        return ("path", str(path), bool(item.get("stray_checkout")))
    return ("inode", info.st_dev, info.st_ino, bool(item.get("stray_checkout")))


def _dedupe_worktree_items(items: list[dict]) -> list[dict]:
    """One row per opened directory, even when metadata casing differs."""
    by_identity: dict[tuple, dict] = {}
    verdict_rank = {"rebuildable": 0, "unreadable": 1, "protected": 2}
    for item in items:
        key = _worktree_item_identity(item)
        existing = by_identity.get(key)
        if existing is None:
            by_identity[key] = item
            continue
        if verdict_rank.get(item["verdict"], 1) > verdict_rank.get(existing["verdict"], 1):
            representative, other = item, existing
        else:
            representative, other = existing, item
        merged = dict(representative)
        registrations = (representative.get("registered"), other.get("registered"))
        merged["registered"] = (True if True in registrations
                                else None if None in registrations else False)
        if merged["verdict"] != "rebuildable":
            merged.pop("requires_revalidation", None)
        by_identity[key] = merged
    return list(by_identity.values())


def _dedupe_registered_missing(entries: list[dict]) -> list[dict]:
    seen: set[tuple[str, str]] = set()
    result: list[dict] = []
    for entry in entries:
        key = (entry["repo"], entry["path"])
        if key not in seen:
            seen.add(key)
            result.append(entry)
    return result


def collect_worktrees(home: Path, records: Optional[list[dict]] = None) -> dict:
    """Anchor judgment for agent-created git worktrees, via read-only git queries.

    A worktree is unique work ("protected") while it is dirty or carries commits
    unreachable from every remote; only a clean, fully pushed worktree is judged
    "rebuildable". Registration in the parent repo and registry entries whose
    directory disappeared are reported as anchor breaks. Discovery is deliberately
    partial: only workspaces recorded by a local agent store are observed. ``home``
    is retained for API compatibility and to make that scope explicit; it is never
    recursively enumerated.
    """
    del home
    records = records or []
    candidates, observed_workspaces, probe_truncated, metadata_children = (
        _worktree_containers_from_records(records)
    )
    containers, discovery_unreadable, container_aliases = (
        _existing_worktree_containers(candidates)
    )
    metadata_children = _remap_metadata_children(metadata_children, container_aliases)
    aliases_by_container = _container_aliases_by_representative(container_aliases)
    # A repo-root session can outlive its entire `.claude/worktrees` directory.
    # Its exact `.git` anchor still lets `git worktree list` recover registered
    # children, so do not require the container itself to remain readable.
    registry_candidates = {
        container_aliases.get(candidate, candidate)
        for candidate in candidates
        if _has_worktree_registry_nofollow(candidate.parent.parent)
    }
    container_paths = sorted(
        set(containers) | set(metadata_children) | registry_candidates, key=str,
    )
    readable_containers = set(containers)
    budget = _WorktreeGitBudget.start()
    registry_unreadable = 0
    items: list[dict] = []
    registered_missing: list[dict] = []
    for container in container_paths:
        container_spellings = aliases_by_container.get(container, {container})
        repo = container.parent.parent
        # The primary checkout itself can be stranded on a non-default branch by
        # an agent session that never opened a PR — the same unique-work risk as
        # a worktree, but invisible to worktree listing. Judge it with the same
        # protected/rebuildable rules and mark it stray_checkout.
        repo_branch_raw = budget.run(["symbolic-ref", "--short", "HEAD"], repo)
        repo_branch = repo_branch_raw.strip() if repo_branch_raw else None
        if repo_branch and repo_branch not in ("main", "master"):
            status = budget.run(["status", "--porcelain"], repo)
            unpushed_raw = budget.run(
                ["rev-list", "--count", "HEAD", "--not", "--remotes"], repo)
            commit_raw = budget.run(["log", "-1", "--format=%ct"], repo)
            dirty = bool(status.strip()) if status is not None else None
            unpushed = None
            if unpushed_raw and unpushed_raw.strip().isdigit():
                unpushed = int(unpushed_raw.strip())
            verdict = _worktree_verdict(dirty, unpushed)
            last_commit = None
            if commit_raw and commit_raw.strip().isdigit():
                last_commit = time.strftime("%Y-%m-%d",
                                            time.localtime(int(commit_raw.strip())))
            stray = {
                "path": str(repo),
                "repo": str(repo),
                "branch": repo_branch,
                "registered": True,
                "dirty": dirty,
                "unpushed_commits": unpushed,
                "last_commit": last_commit,
                "verdict": verdict,
                "evidence": "preview",
                "stray_checkout": True,
            }
            if verdict == "rebuildable":
                stray["requires_revalidation"] = True
            items.append(stray)
        porcelain = budget.run(["worktree", "list", "--porcelain"], repo)
        listed: Optional[set[str]] = None
        registered_children: set[Path] = set()
        unreadable_registered_children: set[Path] = set()
        if porcelain is not None:
            listed = set()
            for line in porcelain.splitlines():
                if line.startswith("worktree "):
                    listed.add(_normalized_git_path(line.split(" ", 1)[1]))
            for path in sorted(listed):
                relative = _relative_below_aliases(path, container_spellings)
                if relative is None:
                    continue
                is_direct_child = os.sep not in relative and relative not in (".", "..")
                canonical_child = container / relative
                if is_direct_child:
                    # The registry itself establishes this worktree even when
                    # its directory later vanished or became unreadable.
                    registered_children.add(canonical_child)
                try:
                    registered_fd = _open_directory_nofollow(Path(path))
                except FileNotFoundError:
                    registered_missing.append(
                        {"repo": str(repo), "path": str(canonical_child)})
                    if is_direct_child:
                        unreadable_registered_children.add(canonical_child)
                except (OSError, ValueError):
                    discovery_unreadable += 1
                    if is_direct_child:
                        unreadable_registered_children.add(canonical_child)
                else:
                    os.close(registered_fd)
        else:
            registry_unreadable += 1

        if container in readable_containers:
            children, readable = _direct_worktree_children(container)
            if not readable:
                discovery_unreadable += 1
        else:
            children, readable = [], False
        # A registry entry is already a known worktree. If directory enumeration
        # races or is unreadable, retain that known item instead of silently
        # dropping it; the git signals below will make it unreadable as needed.
        observed_children = set(children) | registered_children
        metadata_only_children = metadata_children.get(container, set()) - observed_children
        unreadable_children = metadata_only_children | unreadable_registered_children
        children = sorted(
            observed_children | metadata_children.get(container, set()), key=str,
        )
        for worktree in children:
            status = budget.run(["status", "--porcelain"], worktree)
            unpushed_raw = budget.run(
                ["rev-list", "--count", "HEAD", "--not", "--remotes"], worktree)
            branch_raw = budget.run(["rev-parse", "--abbrev-ref", "HEAD"], worktree)
            commit_raw = budget.run(["log", "-1", "--format=%ct"], worktree)
            dirty = bool(status.strip()) if status is not None else None
            unpushed = None
            if unpushed_raw and unpushed_raw.strip().isdigit():
                unpushed = int(unpushed_raw.strip())
            verdict = _worktree_verdict(dirty, unpushed)
            last_commit = None
            if commit_raw and commit_raw.strip().isdigit():
                last_commit = time.strftime("%Y-%m-%d",
                                            time.localtime(int(commit_raw.strip())))
            item = {
                "path": str(worktree),
                "repo": str(repo),
                "branch": branch_raw.strip() if branch_raw else None,
                # A failed/budgeted registry query establishes neither true nor
                # false. ``null`` keeps that uncertainty intact for consumers.
                "registered": (
                    True if worktree in unreadable_registered_children
                    else None if worktree in metadata_only_children or listed is None
                    else worktree in registered_children
                ),
                "dirty": dirty,
                "unpushed_commits": unpushed,
                "last_commit": last_commit,
                "verdict": verdict,
                "evidence": "preview",
            }
            if worktree in unreadable_children:
                # Never allow stale git output from a raced path to upgrade a
                # metadata/registry-known but unreadable item.
                item.update({
                    "branch": None,
                    "dirty": None,
                    "unpushed_commits": None,
                    "last_commit": None,
                    "verdict": "unreadable",
                })
            if item["verdict"] == "rebuildable":
                item["requires_revalidation"] = True
            items.append(item)
    items = _dedupe_worktree_items(items)
    registered_missing = _dedupe_registered_missing(registered_missing)
    items.sort(key=lambda w: (w["verdict"], w["last_commit"] or "", w["path"]))
    item_unreadable = sum(
        1 for item in items
        if item["verdict"] == "unreadable" or item.get("registered") is None
    )
    return {
        "items": items,
        "registered_missing": registered_missing,
        "scope": "session-metadata",
        "global_complete": False,
        "observed_workspaces": observed_workspaces,
        "unreadable": item_unreadable + discovery_unreadable + registry_unreadable,
        "truncated": probe_truncated or budget.exhausted,
    }


def _metadata_worktree_fallback(records: list[dict]) -> dict:
    """No-I/O answer used when the isolated discovery cannot finish."""
    _, observed_workspaces, _, metadata_children = _worktree_containers_from_records(records)
    known: dict[str, tuple[Path, Path]] = {}
    for container, children in metadata_children.items():
        for child in children:
            known.setdefault(str(child), (container, child))
    items = [{
        "path": str(child),
        "repo": str(container.parent.parent),
        "branch": None,
        "registered": None,
        "dirty": None,
        "unpushed_commits": None,
        "last_commit": None,
        "verdict": "unreadable",
        "evidence": "preview",
    } for container, child in sorted(known.values(), key=lambda pair: str(pair[1]))]
    return {
        "items": items,
        "registered_missing": [],
        "scope": "session-metadata",
        "global_complete": False,
        "observed_workspaces": observed_workspaces,
        # One discovery failure plus every metadata-known row whose state could
        # not be read. No filesystem call is made while constructing this.
        "unreadable": len(items) + 1,
        "truncated": True,
    }


def _signal_worktree_worker(
        pid: int, signal_number: int, *, process_group: bool = False) -> None:
    try:
        if process_group:
            os.killpg(pid, signal_number)
        else:
            os.kill(pid, signal_number)
    except OSError:
        pass


def _waitpid_until(pid: int, deadline: float) -> tuple[bool, Optional[int]]:
    while True:
        try:
            waited, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return True, None
        if waited == pid:
            return True, status
        if time.monotonic() >= deadline:
            return False, None
        time.sleep(0.01)


def _worktree_group_exists(pid: int) -> bool:
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _terminate_worktree_worker(pid: int, *, process_group: bool = False) -> None:
    """Terminate the isolated worker and every git process it started."""
    _signal_worktree_worker(
        pid, signal.SIGTERM, process_group=process_group)
    deadline = time.monotonic() + 0.20
    stopped = False
    while time.monotonic() < deadline:
        if not stopped:
            stopped, _ = _waitpid_until(pid, time.monotonic())
        group_gone = not process_group or not _worktree_group_exists(pid)
        if stopped and group_gone:
            return
        time.sleep(0.01)
    _signal_worktree_worker(
        pid, signal.SIGKILL, process_group=process_group)
    _waitpid_until(pid, time.monotonic() + 0.20)
    if process_group:
        deadline = time.monotonic() + 0.20
        while _worktree_group_exists(pid) and time.monotonic() < deadline:
            time.sleep(0.01)


def collect_worktrees_isolated(
        home: Path, records: list[dict], *,
        timeout_seconds: float = WORKTREE_DISCOVERY_ISOLATION_SECONDS) -> dict:
    """Run every potentially blocking worktree filesystem read in a child.

    macOS GUI/TCC context can leave even one exact ``openat`` blocked despite
    the same path returning instantly in a shell. A process boundary is the
    only hard timeout around such a syscall. The child deliberately remains in
    the report's existing process group: Modore's root group cancellation and
    force-kill therefore always reaches the parent. The worker is its own
    process group so this function's timeout can terminate every live git
    descendant; while it is supervised, SIGTERM to the parent is forwarded to
    that group before the parent exits.
    """
    fallback = _metadata_worktree_fallback(records)
    setup_signal_mask = None
    setup_sigterm_blocked = False
    read_fd = -1
    write_fd = -1
    try:
        read_fd, write_fd = os.pipe()
        # Close the only cancellation gap before creating the worker.  A
        # SIGTERM delivered after fork but before ``forward_sigterm`` was
        # installed used to kill only this parent, leaving the worker and its
        # git descendant behind.  The child inherits the blocked mask, enters
        # its private process group, then restores the caller's mask before it
        # performs any discovery.  The parent restores its mask only after the
        # forwarding handler is live, so a pending termination is delivered
        # through that handler.
        if hasattr(signal, "pthread_sigmask"):
            try:
                setup_signal_mask = signal.pthread_sigmask(
                    signal.SIG_BLOCK, {signal.SIGTERM})
                setup_sigterm_blocked = True
            except (OSError, ValueError):
                # The normal app CLI supports pthread masks. A constrained
                # embedding still gets the pre-existing timeout cleanup and
                # must not leak the pipe merely because masking is unavailable.
                setup_signal_mask = None
        try:
            pid = os.fork()
        except OSError:
            os.close(read_fd)
            os.close(write_fd)
            if setup_sigterm_blocked:
                signal.pthread_sigmask(
                    signal.SIG_SETMASK, setup_signal_mask)
            raise
    except OSError:
        return fallback

    if pid == 0:
        try:
            os.setpgid(0, 0)
            if setup_sigterm_blocked:
                signal.pthread_sigmask(
                    signal.SIG_SETMASK, setup_signal_mask)
                setup_sigterm_blocked = False
            os.close(read_fd)
            result = collect_worktrees(home, records)
            payload = json.dumps(result, ensure_ascii=False).encode("utf-8")
            offset = 0
            while offset < len(payload):
                offset += os.write(write_fd, payload[offset:])
        except BaseException:
            pass
        finally:
            try:
                os.close(write_fd)
            except OSError:
                pass
        os._exit(0)

    process_group = False
    previous_sigterm = None
    sigterm_installed = False

    def forward_sigterm(signal_number, frame):
        _signal_worktree_worker(
            pid, signal_number, process_group=process_group)
        if callable(previous_sigterm):
            previous_sigterm(signal_number, frame)
        elif previous_sigterm == signal.SIG_IGN:
            return
        else:
            raise SystemExit(128 + signal_number)

    try:
        try:
            # Doing this in both processes closes the fork race: whichever
            # runs first establishes the private group before
            # collect_worktrees can spawn git.
            os.setpgid(pid, pid)
            process_group = True
        except OSError:
            try:
                process_group = os.getpgid(pid) == pid
            except OSError:
                process_group = False

        os.close(write_fd)
        write_fd = -1
        os.set_blocking(read_fd, False)
        chunks: list[bytes] = []
        total_bytes = 0
        eof = False
        child_status: Optional[int] = None
        deadline = time.monotonic() + max(0.01, timeout_seconds)
        try:
            previous_sigterm = signal.getsignal(signal.SIGTERM)
            signal.signal(signal.SIGTERM, forward_sigterm)
            sigterm_installed = True
        except (OSError, ValueError):
            # signal handlers are main-thread only. The normal CLI path is the
            # main thread; a library caller still gets internal group cleanup.
            pass
    except BaseException:
        _terminate_worktree_worker(pid, process_group=process_group)
        if read_fd >= 0:
            os.close(read_fd)
            read_fd = -1
        if write_fd >= 0:
            os.close(write_fd)
            write_fd = -1
        raise
    finally:
        if setup_sigterm_blocked:
            signal.pthread_sigmask(signal.SIG_SETMASK, setup_signal_mask)
            setup_sigterm_blocked = False
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _terminate_worktree_worker(pid, process_group=process_group)
                return fallback
            ready, _, _ = select.select([read_fd], [], [], min(0.05, remaining))
            if ready:
                try:
                    chunk = os.read(read_fd, 65536)
                except BlockingIOError:
                    chunk = None
                if chunk is None:
                    pass
                elif chunk:
                    total_bytes += len(chunk)
                    if total_bytes > WORKTREE_DISCOVERY_MAX_OUTPUT_BYTES:
                        _terminate_worktree_worker(pid, process_group=process_group)
                        return fallback
                    chunks.append(chunk)
                else:
                    eof = True
            if child_status is None:
                try:
                    waited, status = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    waited, status = pid, 0
                if waited == pid:
                    child_status = status
            if eof and child_status is not None:
                break
    except BaseException:
        _terminate_worktree_worker(pid, process_group=process_group)
        raise
    finally:
        if sigterm_installed:
            signal.signal(signal.SIGTERM, previous_sigterm)
        if read_fd >= 0:
            os.close(read_fd)

    if child_status is None or not os.WIFEXITED(child_status):
        return fallback
    try:
        result = json.loads(b"".join(chunks).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return fallback
    required = {
        "items": list,
        "registered_missing": list,
        "scope": str,
        "global_complete": bool,
        "observed_workspaces": int,
        "unreadable": int,
        "truncated": bool,
    }
    if (not isinstance(result, dict)
            or any(not isinstance(result.get(key), expected)
                   for key, expected in required.items())):
        return fallback
    return result


def build_lineage(records: list[dict]) -> dict:
    """Universal facts about every work path seen in session records: does it
    still exist, and is it a git repo. Session records are often the only
    surviving trace of vanished work, so this is the map of what the sessions
    remember versus what the disk still holds.

    Case-insensitive filesystems (macOS default) let the same path be recorded
    under several casings; variants are grouped by casefold, reported once with
    their spellings, and never double-counted. Metadata only: path strings,
    existence, and a `.git` presence check — no session content involved.
    """
    by_key: dict[str, set[str]] = {}
    for item in records:
        workspace = item.get("workspace")
        if workspace:
            by_key.setdefault(workspace.casefold(), set()).add(workspace)
    paths: list[dict] = []
    alive_git = alive_plain = vanished = ghosts = 0
    for key in sorted(by_key):
        variants = sorted(by_key[key])
        exists = any(Path(v).exists() for v in variants)
        has_git = exists and any((Path(v) / ".git").exists() for v in variants)
        entry: dict = {"path": variants[0], "exists": exists, "has_git": has_git}
        if len(variants) > 1:
            entry["case_variants"] = variants
            ghosts += 1
        paths.append(entry)
        if not exists:
            vanished += 1
        elif has_git:
            alive_git += 1
        else:
            alive_plain += 1
    return {"paths": paths,
            "summary": {"total": len(paths), "alive_git": alive_git,
                        "alive_plain": alive_plain, "vanished": vanished,
                        "case_ghosts": ghosts}}


# Enterprise MDM policy path (macOS). Modore's own collectors are already
# macOS-only (see collect_vscode_forks's ~/Library/Application Support use),
# so this is the one real path scree needs -- Linux/Windows equivalents exist
# for Claude Code itself but never apply to a scree invocation.
MANAGED_SETTINGS_PATH = Path("/Library/Application Support/ClaudeCode/managed-settings.json")


def _cleanup_period_days_from(path: Path) -> Optional[int]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    value = data.get("cleanupPeriodDays")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value <= 0:
        return None
    return int(value)


def read_claude_cleanup_period_days(home: Path) -> Optional[int]:
    """The one authoritative retention signal scree ever reads: Claude Code's
    own `cleanupPeriodDays` setting. Read-only, config-only — never message
    content, so this stays inside the metadata-only contract.

    A guess from file ages cannot tell "old sessions are about to be deleted"
    apart from "old sessions exist and nothing deletes them" — both look
    identical on disk. A user who deliberately set retention days ago and then
    sees scree call live sessions "D-day" has caught scree contradicting a
    fact it could have just read.

    Checked in Claude Code's own precedence order: an enterprise-managed
    policy overrides every other scope and can't be overridden by the user,
    so it is checked first and short-circuits the rest; `settings.local.json`
    then overrides `settings.json`, both under the user's home. (Project-level
    `.claude/settings.json` sits between those two in Claude Code's real
    precedence, but scree audits every workspace under `home` in one pass —
    there is no single "current project" to read a project-level file from,
    so that tier is intentionally not read here.) Any failure (missing file,
    bad JSON, missing/non-numeric key) falls through to the next tier, and
    ultimately to the observed-age heuristic, silently — this is a
    preference, not a requirement.
    """
    managed = _cleanup_period_days_from(MANAGED_SETTINGS_PATH)
    if managed is not None:
        return managed
    claude_dir = home / ".claude"
    for name in ("settings.local.json", "settings.json"):
        value = _cleanup_period_days_from(claude_dir / name)
        if value is not None:
            return value
    return None


# A configured window this long is retention in practice, not a number to
# compare session ages against — flagging "expires in 36,466 days" would be a
# technically-true but useless and alarming thing to print.
EFFECTIVELY_INDEFINITE_DAYS = 3650


# The Claude desktop app keeps the list of conversations it shows beside the
# transcripts rather than inside them: one `local_<id>.json` per listed
# conversation, and a `deleted_<id>` tombstone per conversation the owner
# removed. Deleting in the app rewrites only that index -- the transcript is
# never touched -- so a tombstone is the one record on disk of the owner
# having decided a conversation was finished with.
CLAUDE_DESKTOP_INDEX = ("Library", "Application Support", "Claude", "claude-code-sessions")
_TOMBSTONE_PREFIX = "deleted_"


def collect_claude_desktop_deletions(home: Path) -> set[str]:
    """Ids the desktop app was told to delete, from tombstone filenames alone.

    The tombstone body is a delete timestamp and is never opened, so this stays
    inside the metadata-only contract -- it reads a directory listing, nothing
    more. One delete writes two or three tombstones (the app's own session id,
    the transcript id, sometimes a third), but an id naming no transcript
    simply never matches one, so no pairing rule is needed here.
    """
    root = home.joinpath(*CLAUDE_DESKTOP_INDEX)
    if not root.is_dir():
        return set()
    deleted: set[str] = set()
    try:
        for path in root.rglob(f"{_TOMBSTONE_PREFIX}*"):
            deleted.add(path.name[len(_TOMBSTONE_PREFIX):])
    except OSError:
        pass
    return deleted


def build_retention(records: list[dict], now_ts: float, home: Optional[Path] = None) -> dict:
    """Per-store retention judgment.

    Prefers a real, read configuration value over a guess wherever scree knows
    where to look (today: Claude Code's own `cleanupPeriodDays`). Every other
    store is still judged from session-file age distribution alone: a store
    whose oldest surviving session sits in the rolling band is judged
    "rolling" and its observed oldest age becomes the estimated window; sessions
    within EXPIRY_SOON_DAYS of that window are flagged, split by whether their
    workspace still exists (a living story about to lose its transcript versus
    an orphan whose loss likely goes unnoticed).

    A third state sits underneath both: a conversation the owner already
    deleted in the desktop app. Deleting there removes the app's index entry
    and leaves the transcript untouched, so the session reads here as any other
    live one and the forecast urges rescuing something its owner threw away.
    Tombstoned sessions are marked `owner_deleted` and sorted below the rest,
    so the urgency at the top of the list is only ever about work still wanted.
    """
    configured_days: dict[str, int] = {}
    if home is not None:
        claude_configured = read_claude_cleanup_period_days(home)
        if claude_configured is not None:
            configured_days["Claude"] = claude_configured
    owner_deleted = collect_claude_desktop_deletions(home) if home is not None else set()
    stores: list[dict] = []
    expiring: list[dict] = []

    def flag_expiring(tool: str, sessions: list[dict], ages: list[float], window: float) -> None:
        for session, age in zip(sessions, ages):
            days_left = round(window - age)
            if days_left <= EXPIRY_SOON_DAYS:
                workspace = session["workspace"]
                source = session.get("source")
                expiring.append({
                    "tool": tool,
                    "workspace": workspace,
                    "source": source,
                    "days_left": days_left,
                    "size_bytes": session["size_bytes"],
                    "story_alive": bool(workspace) and Path(workspace).exists(),
                    "owner_deleted": bool(source) and Path(source).stem in owner_deleted,
                })

    by_tool: dict[str, list[dict]] = {}
    for item in records:
        if item["kind"] == "session":
            by_tool.setdefault(item["tool"], []).append(item)
    for tool in sorted(by_tool):
        sessions = by_tool[tool]
        ages = [(now_ts - s["last_active"]) / 86400 for s in sessions]
        oldest = max(ages)
        newest = min(ages)
        entry = {"store": tool, "sessions": len(sessions),
                 "oldest_days": round(oldest), "stalled": newest > STALLED_STORE_DAYS}
        configured = configured_days.get(tool)
        if configured is not None:
            # A real setting always outranks a guess, even a low-confidence one.
            entry["mode"] = "configured"
            entry["configured_days"] = configured
            if configured < EFFECTIVELY_INDEFINITE_DAYS:
                flag_expiring(tool, sessions, ages, configured)
        elif len(sessions) < RETENTION_MIN_SESSIONS:
            entry["mode"] = "insufficient"
        elif ROLLING_WINDOW_DAYS[0] <= oldest <= ROLLING_WINDOW_DAYS[1]:
            entry["mode"] = "rolling"
            entry["window_days"] = round(oldest)
            flag_expiring(tool, sessions, ages, oldest)
        else:
            entry["mode"] = "long"
        stores.append(entry)
    expiring.sort(key=lambda e: (e["owner_deleted"], e["days_left"], -e["size_bytes"]))
    return {"stores": stores, "expiring": expiring}


def collect_all(home: Path) -> tuple[list[dict], list[dict]]:
    """Every store, walked once: `(records, statuses)`.

    One definition of "all the stores", so a provider added here reaches
    the judgment and the browser together. They previously each listed
    the collectors themselves, which is how Gemini ended up visible to
    one and invisible to the other.

    Note what this does *not* do: `report` and `sessions` are still
    separate commands and so still separate processes. Measured on this
    machine that costs about 0.4s of a 5.6s report -- the report's time
    is git and worktree inspection, not this traversal -- so collapsing
    them into one invocation would buy little and couple two answers
    that are wanted at different moments.
    """
    codex_records, codex_status = collect_codex(home)
    claude_records, claude_status = collect_claude(home)
    desktop_records, desktop_status = (
        _collect_claude_desktop_sessions_with_coverage(home))
    fork_records, fork_statuses = collect_vscode_forks(home)
    gemini_records, gemini_status = collect_gemini(home)
    return (
        codex_records + claude_records + desktop_records
        + fork_records + gemini_records,
        [codex_status, claude_status, desktop_status, gemini_status]
        + fork_statuses,
    )


def collect_gemini_chats(home: Path) -> list[dict]:
    """Gemini's actual conversations, for the session browser.

    `collect_gemini` deliberately reports the registry -- one
    `project_state` record per registered project, which is what the
    retention and lineage judgment wants. The conversations themselves
    live in `~/.gemini/tmp/*/chats/*.json` and were invisible to every
    listing, so a screen that named Gemini in its subtitle offered no way
    to reach a single Gemini chat.

    Workspace identity is `sha256(absolute path)`, recorded per chat as
    `projectHash`; `projects.json` supplies the paths to hash back. Every
    chat in one directory shares a workspace, so one file per directory
    is read to resolve it rather than all of them -- 75 reads instead of
    4,005 on this machine. A directory whose hash is not in the registry
    keeps an empty workspace rather than a guessed one: the directory
    name resembles the workspace's last component, but resembling is not
    knowing, and this list is read by someone deciding what to delete.
    """
    chat_root = home / ".gemini" / "tmp"
    if not chat_root.is_dir():
        return []

    known: dict[str, str] = {}
    registry = home / ".gemini" / "projects.json"
    if registry.is_file():
        try:
            payload = json.loads(registry.read_text(encoding="utf-8-sig"))
        except JSON_FILE_ERRORS:
            payload = {}
        if not isinstance(payload, dict):
            payload = {}
        project_map = payload.get("projects")
        if not isinstance(project_map, dict):
            project_map = {}
        for path in project_map:
            if isinstance(path, str):
                known[hashlib.sha256(path.encode("utf-8")).hexdigest()] = path

    records: list[dict] = []
    for chats_dir in sorted(chat_root.glob("*/chats")):
        chats = sorted(chats_dir.glob("*.json"))
        if not chats:
            continue
        workspace = ""
        for probe in chats:
            try:
                head = json.loads(probe.read_text(encoding="utf-8-sig"))
            except JSON_FILE_ERRORS:
                continue
            if isinstance(head, dict):
                workspace = known.get(str(head.get("projectHash")), "")
                break
        for chat in chats:
            try:
                size = chat.stat().st_size
                mtime = chat.stat().st_mtime
            except OSError:
                continue
            records.append({
                "kind": "session",
                "tool": "Gemini",
                "source": str(chat),
                "workspace": workspace,
                "size_bytes": size,
                "last_active": mtime,
            })
    return records


SESSIONS_DEFAULT_LIMIT = 0


def build_sessions(home: Path, *, limit: int = SESSIONS_DEFAULT_LIMIT) -> dict:
    """Every session this build can see, as metadata, most recent first.

    The index a browser needs, and nothing more. `report` groups sessions
    by workspace to answer "what is piling up"; a person looking for one
    conversation they had last Tuesday is asking a different question,
    and answering it by scrolling a grouped summary is why that screen
    had no way to find anything.

    Metadata only, deliberately: this is a listing, so it runs over every
    store on the machine, and a listing that opened thousands of
    transcripts to describe them would be a content read of the whole
    disk on every refresh. Bodies are read one at a time, by name,
    through `inspect` -- when someone asks for that one.
    """
    # `collect_gemini` reports the registry, which is what retention and
    # lineage want; the browser wants the chats, which live elsewhere. So
    # the shared walk supplies everything except Gemini, whose registry
    # records are dropped in favour of the conversations themselves.
    shared, store_coverage = collect_all(home)
    records = [item for item in shared if item["tool"] != "Gemini"]
    records += collect_gemini_chats(home)
    sessions = []
    for item in records:
        # Editor workspace state is listed alongside agent transcripts.
        # Modore's boundary is durable local state that outlived whatever
        # made it, not conversations specifically -- and a browser that
        # hid the VS Code entry would hide something a person retiring a
        # folder is about to lose. Whether an entry has a readable
        # conversation is a separate question, answered by its store.
        if item.get("kind") not in ("session", "workspace_state"):
            continue
        if not item.get("source"):
            continue
        workspace = item.get("workspace") or ""
        workspace_exists = (item["workspace_exists"]
                            if "workspace_exists" in item
                            else bool(workspace) and Path(workspace).exists())
        session = {
            "tool": item["tool"],
            "source": item["source"],
            "workspace": workspace,
            # Stated, not implied by an empty string: a session whose
            # workspace is gone and one that never recorded a workspace
            # are different things to a person deciding what to keep.
            "workspaceExists": workspace_exists,
            # Editors keep per-workspace state, not a transcript; saying
            # "대화" for both overstates what a `workspace.json` is.
            "kind": item["kind"],
            "sizeBytes": item["size_bytes"],
            "lastActive": time.strftime(
                "%Y-%m-%d %H:%M", time.localtime(item["last_active"])),
            "lastActiveEpoch": item["last_active"],
        }
        if item.get("provider") == CLAUDE_DESKTOP_PROVIDER:
            # Dedicated metadata files contain many private fields.  Only this
            # whitelist crosses the index boundary; no catch-all copy or
            # dictionary merge may be introduced here.
            session.update({
                "provider": CLAUDE_DESKTOP_PROVIDER,
                "sessionId": item["session_id"],
                "sizeComplete": item["size_complete"],
                **item["desktop_metadata"],
            })
        sessions.append(session)
    sessions.sort(key=lambda s: (-s["lastActiveEpoch"], s["source"]))
    # `total` is the count before the cap, so a caller can say what it is
    # not showing rather than presenting a truncated list as the whole.
    coverage_stores = [
        {
            "store": entry["store"],
            "status": entry["status"],
            "count": entry["count"],
            "unrecognized": entry.get("unrecognized", 0),
        }
        for entry in store_coverage
    ]
    complete = all(
        entry["status"] in ("ok", "missing")
        and entry["unrecognized"] == 0
        for entry in coverage_stores
    )
    return {
        "total": len(sessions),
        "sessions": sessions[:limit] if limit > 0 else sessions,
        "coverage": {"complete": complete, "stores": coverage_stores},
    }


def build_scree(home: Path) -> dict:
    records, stores = collect_all(home)

    # Keyed by casefold, same as build_lineage: a case-insensitive filesystem
    # (macOS default) lets Codex/Claude/Gemini/VS Code each record the same
    # real directory under a different casing (confirmed on real project
    # data, not hypothetical), so an exact-string key would silently split
    # one workspace into unrelated groups depending on which tool logged it.
    workspace_to_repo: dict[str, str] = {}
    for item in records:
        if item["workspace"] and item["repo_url"]:
            workspace_to_repo.setdefault(item["workspace"].casefold(), item["repo_url"])

    groups: dict[str, dict] = {}
    unresolved_count = 0
    for item in records:
        workspace = item["workspace"]
        if not workspace:
            unresolved_count += 1
            continue
        repo = workspace_to_repo.get(workspace.casefold())
        key = repo if repo else f"ws:{workspace.casefold()}"
        group = groups.setdefault(key, {
            "key": key,
            "grouped_by": "repo" if repo else "workspace",
            "workspaces": set(),
            "tools": {},
            "sessions": 0,
            "size_bytes": 0,
            "last_active": 0.0,
        })
        group["workspaces"].add(workspace)
        weight = item.get("weight", 1)
        if weight:
            group["tools"][item["tool"]] = group["tools"].get(item["tool"], 0) + weight
        group["sessions"] += weight
        group["size_bytes"] += item["size_bytes"]
        group["last_active"] = max(group["last_active"], item["last_active"])

    finished = []
    for group in groups.values():
        workspaces = sorted(group.pop("workspaces"))
        existing = [w for w in workspaces if Path(w).exists()]
        if group["grouped_by"] != "repo":
            # The join key above is casefolded for matching; the key exposed
            # to consumers must stay a real, displayable casing instead of
            # the lowercased join string.
            group["key"] = f"ws:{workspaces[0]}"
        entry = {
            **group,
            "workspaces": workspaces,
            "worktrees": [w for w in workspaces if "/worktrees/" in w],
            "orphan": not existing,
            "cross_tool": len(group["tools"]) > 1,
            "last_active": time.strftime("%Y-%m-%d %H:%M", time.localtime(group["last_active"])),
        }
        if entry["orphan"]:
            # The only fact checked is path absence; a moved/renamed/unmounted
            # workspace looks identical, so consumers get the basis explicitly.
            entry["orphan_basis"] = "path_missing"
        finished.append(entry)
    finished.sort(key=lambda g: (g["last_active"], g["key"]), reverse=True)
    return {
        "contract": ("metadata-only output; whitelisted keys; deterministic join; "
                     "leading lines parsed in memory, content never retained"),
        "stores": stores,
        "groups": finished,
        "unresolved_sessions": unresolved_count,
        "lineage": build_lineage(records),
        "retention": build_retention(records, time.time(), home),
        "worktrees": collect_worktrees_isolated(home, records),
    }


# --- Session binding (the second deliberate exception to the no-content
# contract, alongside `preserve`) -------------------------------------------
#
# `report` answers "how much debris, and whose", and its metadata-only
# contract is what makes it safe to run on a whim. Binding answers a
# different question -- "which conversations would be stranded if this
# workspace were deleted" -- and that answer has to be right, because a
# consumer acts destructively on it. So binding is its own command:
# invoked for one named workspace, never during a report, and emitting
# evidence *types* and session ids rather than anything said in them.

# Safety valve, not a scan depth. A content scan that stops early has not
# established absence, so tripping this is recorded and downgrades the
# run's coverage rather than passing silently as a completed look.
BINDER_SCAN_CEILING_BYTES = 512 * 1024 * 1024


def _binding_confidence(evidence: list[str]) -> str:
    """Confidence follows the strongest evidence present, not a count.

    `remote-url` is the only signal the provider itself recorded about
    repository identity, and the only one that survives the workspace
    being moved or deleted -- so it outranks any amount of weaker
    corroboration. File access alone stays `low` on its own: reading a
    path proves a visit, not ownership.
    """
    if "remote-url" in evidence:
        return "high"
    if "working-directory" in evidence or "selected-folder" in evidence:
        return "medium"
    return "low"


def _under(path: str, root: str) -> bool:
    """True when `path` is `root` or lives inside it.

    Prefix matching rather than equality so a repo's own worktrees --
    `<repo>/.claude/worktrees/*`, each a separate session store slug --
    bind to the repo being retired. Retiring the repo strands those
    conversations exactly as much as it strands the top-level ones.

    Case-folded because macOS filesystems are case-insensitive by default
    and providers record whatever casing the user typed: `build_lineage`
    already found the same workspace written several ways on this machine
    and folds them together. A case-sensitive binder misses exactly those
    recordings, and a miss here reads as "no conversation was held in
    this workspace".
    """
    root = _canon_workspace(root).casefold()
    path = path.casefold()
    if root == "/":
        return path.startswith("/")
    return path == root or path.startswith(root + "/")


@dataclass(frozen=True)
class _ClaudeDesktopBindingCandidate:
    source: Path
    session_id: str
    cwd: Optional[str]
    selected_folders: tuple[str, ...]
    subtranscripts: tuple[Path, ...]
    artifact_root: Path
    size: int


@dataclass(frozen=True)
class _ClaudeDesktopBindingState:
    metadata_snapshots: tuple[_ClaudeDesktopMetadataSnapshot, ...]
    coverage: dict
    artifact_snapshots: tuple[tuple[str, tuple], ...]
    complete: bool


def _desktop_binding_location(value: Any) -> Optional[str]:
    """Validate one provider path lexically, without touching that path."""
    if (not isinstance(value, str) or not value or "\x00" in value
            or len(value) > CLAUDE_DESKTOP_LOCATION_MAX_CHARS):
        return None
    path = PurePosixPath(value)
    if not path.is_absolute():
        return None
    # normpath is lexical.  In particular this never resolves a symlink,
    # probes a sleeping network mount, expands another user's home, or asks
    # TCC for access to the provider-supplied location.
    normalized = os.path.normpath(value)
    if not PurePosixPath(normalized).is_absolute():
        return None
    return _canon_workspace(normalized)


def _desktop_binding_locations(
        payload: dict,
        ) -> tuple[Optional[str], tuple[str, ...], bool]:
    """Classify Desktop workspace fields without opening provider paths."""
    complete = True
    cwd = _desktop_binding_location(payload.get("cwd"))
    if cwd is None:
        complete = False
    selected: list[str] = []
    for value in payload.get("userSelectedFolders", []):
        location = _desktop_binding_location(value)
        if location is None:
            complete = False
            continue
        selected.append(location)
    return (cwd, tuple(dict.fromkeys(selected)), complete)


def _desktop_location_statuses_isolated(
        locations: list[str],
        ) -> tuple[dict[str, Optional[bool]], bool]:
    """Probe provider paths behind one hard process timeout.

    A selected folder can be a dead network mount or TCC-protected location.
    Opening it in the index process would let one provider value hang every
    sessions/search/evidence refresh. The child emits only one integer status
    per lexical location; no path is copied back through the pipe.
    """
    unique = list(dict.fromkeys(locations))
    if not unique:
        return ({}, True)
    try:
        read_descriptor, write_descriptor = os.pipe()
        try:
            pid = os.fork()
        except OSError:
            os.close(read_descriptor)
            os.close(write_descriptor)
            raise
    except OSError:
        return ({location: None for location in unique}, False)

    if pid == 0:
        try:
            os.close(read_descriptor)
            statuses: list[int] = []
            for location in unique:
                try:
                    info = os.stat(location)
                except (FileNotFoundError, NotADirectoryError):
                    statuses.append(0)
                except OSError:
                    statuses.append(-1)
                else:
                    statuses.append(1 if stat.S_ISDIR(info.st_mode) else 0)
            payload = json.dumps(statuses, separators=(",", ":")).encode("ascii")
            offset = 0
            while offset < len(payload):
                offset += os.write(write_descriptor, payload[offset:])
        except BaseException:
            pass
        finally:
            try:
                os.close(write_descriptor)
            except OSError:
                pass
        os._exit(0)

    os.close(write_descriptor)
    os.set_blocking(read_descriptor, False)
    chunks: list[bytes] = []
    total = 0
    eof = False
    child_status: Optional[int] = None
    deadline = time.monotonic() + CLAUDE_DESKTOP_WORKSPACE_PROBE_SECONDS
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _terminate_worktree_worker(pid)
                return ({location: None for location in unique}, False)
            ready, _, _ = select.select(
                [read_descriptor], [], [], min(0.05, remaining))
            if ready:
                try:
                    chunk = os.read(read_descriptor, 65536)
                except BlockingIOError:
                    chunk = None
                if chunk:
                    total += len(chunk)
                    if total > CLAUDE_DESKTOP_WORKSPACE_PROBE_MAX_BYTES:
                        _terminate_worktree_worker(pid)
                        return ({location: None for location in unique}, False)
                    chunks.append(chunk)
                elif chunk == b"":
                    eof = True
            if child_status is None:
                try:
                    waited, wait_status = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    waited, wait_status = pid, 0
                if waited == pid:
                    child_status = wait_status
            if eof and child_status is not None:
                break
    except BaseException:
        _terminate_worktree_worker(pid)
        raise
    finally:
        os.close(read_descriptor)

    try:
        statuses = json.loads(b"".join(chunks))
    except (ValueError, UnicodeDecodeError, RecursionError):
        statuses = None
    if (child_status is None or not os.WIFEXITED(child_status)
            or not isinstance(statuses, list)
            or len(statuses) != len(unique)
            or any(type(value) is not int or value not in (-1, 0, 1)
                   for value in statuses)):
        return ({location: None for location in unique}, False)
    result = {
        location: (None if value == -1 else value == 1)
        for location, value in zip(unique, statuses)
    }
    return (result, all(value is not None for value in result.values()))


def _desktop_index_workspace(
        payload: dict,
        location_status: dict[str, Optional[bool]],
        ) -> tuple[str, bool]:
    """Choose one Work group while keeping every other folder binder-only.

    ``userSelectedFolders`` is ordered by the provider. Prefer its first
    currently existing canonical directory. If every selected folder is now
    missing, retain the first as a useful lost-workspace identity. Only a unit
    with no selected folders falls back to ``cwd``; Desktop's cwd can be its
    own sandbox, so it must not displace an explicit project selection.
    """
    cwd, selected, _ = _desktop_binding_locations(payload)
    if selected:
        for location in selected:
            if location_status.get(location) is True:
                return (location, True)
        if any(location_status.get(location) is None for location in selected):
            return ("", False)
        return (selected[0], False)
    if cwd is not None:
        exists = location_status.get(cwd)
        return ((cwd, exists) if exists is not None else ("", False))
    return ("", False)


def _claude_desktop_binding_scan(
        home: Path,
        ) -> tuple[
            list[_ClaudeDesktopBindingCandidate], bool,
            _ClaudeDesktopBindingState,
        ]:
    """Read Desktop workspace metadata once for single or batch binding.

    Raw ``cwd`` and ``userSelectedFolders`` values stay inside this function.
    The wire result carries only the caller-named workspace, the provider's
    session id, and the evidence type.
    """
    snapshots, store = _claude_desktop_metadata_scan(home)
    complete = (
        store["status"] in ("ok", "missing")
        and int(store.get("unrecognized", 0)) == 0
    )
    candidates: list[_ClaudeDesktopBindingCandidate] = []
    artifact_snapshots: list[tuple[str, tuple]] = []
    enumerated_files = 0
    home_descriptor = -1
    try:
        canonical_home = home.expanduser().absolute().resolve(strict=True)
        home_descriptor = _open_directory_nofollow(canonical_home)
    except FileNotFoundError:
        canonical_home = home.expanduser().absolute()
        if snapshots:
            complete = False
    except OSError:
        canonical_home = home.expanduser().absolute()
        complete = False

    try:
        for snapshot in snapshots:
            payload = _parse_claude_desktop_metadata(
                snapshot.raw, snapshot.path.stem)
            if payload is None or home_descriptor < 0:
                complete = False
                continue
            cwd, selected_folders, locations_complete = (
                _desktop_binding_locations(payload))
            if not locations_complete:
                # A relative or otherwise unclassifiable provider location
                # cannot establish absence for any repo.
                complete = False

            try:
                source_relative = snapshot.path.relative_to(
                    canonical_home).as_posix()
                first = _backup_inventory(
                    home_descriptor, source_relative)
                second = _backup_inventory(
                    home_descriptor, source_relative)
                source_entry = first.entries.get(source_relative)
                unit_relative = PurePosixPath(source_relative).with_suffix("")
                unit_signature = first.directories.get(str(unit_relative))
                if (source_entry is None
                        or source_entry.signature
                        != _stat_signature(snapshot.metadata_info)
                        or unit_signature
                        != _stat_identity(snapshot.unit_info)
                        or first.snapshot() != second.snapshot()):
                    raise ValueError(
                        "Desktop conversation changed during binding")
            except (OSError, ValueError):
                complete = False
                continue

            enumerated_files += len(first.entries)
            if enumerated_files > CLAUDE_DESKTOP_BIND_MAX_FILES:
                complete = False
                break
            artifact_snapshots.append(
                (source_relative, first.snapshot()))
            regular_unit_files = tuple(
                canonical_home / entry.relative
                for entry in first.entries.values()
                if entry.kind == "file"
                and entry.relative != source_relative
                and unit_relative in PurePosixPath(entry.relative).parents
            )
            size = source_entry.size + sum(
                first.entries[path.relative_to(canonical_home).as_posix()].size
                for path in regular_unit_files)
            candidates.append(_ClaudeDesktopBindingCandidate(
                source=snapshot.path,
                session_id=payload["sessionId"],
                cwd=cwd,
                selected_folders=selected_folders,
                subtranscripts=regular_unit_files,
                artifact_root=canonical_home / unit_relative,
                size=size,
            ))
    finally:
        if home_descriptor >= 0:
            os.close(home_descriptor)

    state = _ClaudeDesktopBindingState(
        metadata_snapshots=tuple(snapshots),
        coverage=dict(store),
        artifact_snapshots=tuple(artifact_snapshots),
        complete=complete,
    )
    return (candidates, complete, state)


def _bind_claude_desktop_candidates(
        candidates: list[_ClaudeDesktopBindingCandidate],
        workspace: str) -> list[dict]:
    bindings: list[dict] = []
    for candidate in candidates:
        evidence: list[str] = []
        if candidate.cwd is not None and _under(candidate.cwd, workspace):
            evidence.append("working-directory")
        # A selected folder is an access root, so both relationships matter:
        # selecting `/work` can strand a conversation that accessed
        # `/work/repo`, while selecting `/work/repo/subdir` also belongs to
        # the repo being retired.
        if any(_under(selected, workspace) or _under(workspace, selected)
               for selected in candidate.selected_folders):
            evidence.append("selected-folder")
        if not evidence:
            continue
        bindings.append({
            "provider": CLAUDE_DESKTOP_PROVIDER,
            "sessionId": candidate.session_id,
            "source": str(candidate.source),
            "subtranscripts": [str(path) for path in candidate.subtranscripts],
            "artifactRoot": str(candidate.artifact_root),
            "evidence": evidence,
            "confidence": _binding_confidence(evidence),
            "sizeBytes": candidate.size,
        })
    return bindings


def bind_claude_desktop(
        home: Path, workspace: str) -> tuple[list[dict], bool]:
    candidates, complete, _ = _claude_desktop_binding_scan(home)
    return (_bind_claude_desktop_candidates(candidates, workspace), complete)


def _claude_subtranscripts(project_dir: Path, session_id: str) -> list[Path]:
    """Subagent/workflow transcripts for one session.

    Kept separate from the top-level file because the provider's cleanup
    deletes the parent and leaves these behind: on this machine 181 such
    orphans exist. A bundle that copied only the parent would preserve
    the smaller half of the record.
    """
    nested = project_dir / session_id
    if not nested.is_dir():
        return []
    return sorted(p for p in nested.rglob("*.jsonl") if p.is_file())


def _scans_for_paths(source: Path, root: str,
                     ceiling: Optional[int] = None) -> tuple[bool, bool]:
    """Single-workspace form, kept for callers with one question."""
    matched, complete = _scan_for_any_path(source, [root], ceiling=ceiling)
    return (bool(matched), complete)


def _scan_for_any_path(source: Path, roots: list[str],
                       ceiling: Optional[int] = None) -> tuple[set[str], bool]:
    """Deep scan: does this transcript mention any path inside `root`?

    Returns `(found, complete)`. Reads content and emits neither -- the
    caller learns only that `file-access` evidence exists, which is why
    this returns a boolean rather than the matches.

    `complete` is the half that matters for the gate. A scan that stopped
    before the end has not established absence, and a repo path can appear
    anywhere in a transcript: the tool call that touched it may be the
    last line of a fifty-megabyte session. Reporting a truncated look as a
    finished one is how a workspace with bindings comes back empty.

    Chunks overlap by the needle length so a path split across a chunk
    boundary is still matched -- without that, a scan is silently
    incomplete even when it reads every byte.
    """
    # Read the module constant at call time rather than binding it as a
    # default: a default is captured at definition and cannot be lowered
    # by a test, which would leave the truncation path unexercised.
    ceiling = BINDER_SCAN_CEILING_BYTES if ceiling is None else ceiling
    # Folded for the same reason `_under` is: the transcript records the
    # casing the user typed, which need not match the casing on disk.
    #
    # Every workspace at once. One pass per candidate re-reads the same
    # stores for each repo on the list -- measured here at 14.5s per repo
    # across 53 candidates, thirteen minutes spent re-reading the same six
    # gigabytes.
    needles = {root: _canon_workspace(root).casefold() for root in roots}
    if not needles:
        return (set(), True)
    overlap = max(len(n) for n in needles.values()) - 1
    found: set[str] = set()
    try:
        with source.open("r", encoding="utf-8", errors="replace") as handle:
            read = 0
            carry = ""
            while True:
                chunk = handle.read(1 << 20)
                if not chunk:
                    return (found, True)
                read += len(chunk)
                window = carry + chunk.casefold()
                for root, needle in needles.items():
                    if root not in found and needle in window:
                        found.add(root)
                if len(found) == len(needles):
                    # Nothing left to look for in this file.
                    return (found, True)
                carry = window[-overlap:] if overlap else ""
                if read >= ceiling:
                    return (found, False)
    except OSError:
        return (found, False)


def bind_codex(home: Path, workspace: str, repo_url: Optional[str], *,
               deep: bool = False) -> tuple[list[dict], bool]:
    """Codex bindings start nearly free: the repository URL is already in
    the rollout's own `session_meta` header, which `collect_codex` reads
    and then discards into a group count.

    The header is not the whole story, though, and `complete` means every
    byte of every candidate transcript was read. A rollout that started
    somewhere else and later edited files in this repo names it nowhere
    in its first line -- so under `deep` the ones the header did not
    match get the same content scan Claude's do. Without that, Codex
    could be declared fully read on the strength of one line per file."""
    wanted = normalize_repo_url(repo_url) if repo_url else None
    out: list[dict] = []
    complete = True
    for root in (home / ".codex" / "sessions", home / ".codex" / "archived_sessions"):
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.jsonl")):
            try:
                with path.open("r", encoding="utf-8", errors="replace") as handle:
                    first = _read_json_line(handle)
            except OSError:
                # A rollout that could not be opened was not examined. It
                # may name this workspace; nobody knows. Skipping it and
                # still reporting a completed look is how "no sessions"
                # gets asserted about a store that was never read.
                complete = False
                continue
            payload = (first or {}).get("payload")
            if (first or {}).get("type") != "session_meta" or not isinstance(payload, dict):
                # Same reasoning: a rollout whose header this build cannot
                # recognise is an unexamined candidate, not an absent one.
                complete = False
                continue
            git = payload.get("git") if isinstance(payload.get("git"), dict) else {}
            evidence: list[str] = []
            recorded = git.get("repository_url")
            if wanted and recorded and normalize_repo_url(recorded) == wanted:
                evidence.append("remote-url")
            cwd = payload.get("cwd")
            if isinstance(cwd, str) and _under(_canon_workspace(cwd), workspace):
                evidence.append("working-directory")
            if not evidence and deep:
                # Only the rollouts the header did not match: one that is
                # already bound gains nothing from being read again.
                found, scanned_fully = _scans_for_paths(path, workspace)
                if not scanned_fully:
                    complete = False
                if found:
                    evidence.append("file-access")
            if not evidence:
                continue
            session_id = payload.get("id") or path.stem
            out.append({
                "provider": "codex",
                "sessionId": str(session_id),
                "source": str(path),
                "subtranscripts": [],
                "evidence": evidence,
                "confidence": _binding_confidence(evidence),
                "sizeBytes": path.stat().st_size,
            })
    return (out, complete)


def bind_vscode_forks(home: Path, workspace: str) -> tuple[list[dict], bool]:
    """VS Code and its forks record the folder a window was opened on, as
    a `file://` URI in each workspace-storage entry.

    What they store is editor state -- open tabs, an AI panel's history,
    per-workspace settings -- not a transcript, so a binding here says
    "this tool held state about this workspace", which is still work that
    a delete strands. Being unable to read one of these entries makes the
    scan incomplete for the same reason it does everywhere else: an entry
    that was not examined is not an entry that was absent.
    """
    out: list[dict] = []
    complete = True
    for tool, dir_name in VSCODE_FORKS:
        root = home / "Library" / "Application Support" / dir_name / "User" / "workspaceStorage"
        if not root.is_dir():
            continue
        for meta_path in sorted(root.glob("*/workspace.json")):
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8-sig"))
            except JSON_FILE_ERRORS:
                complete = False
                continue
            if not isinstance(meta, dict):
                complete = False
                continue
            target = meta.get("folder") or meta.get("workspace")
            recorded = _uri_to_path(target) if isinstance(target, str) else None
            if not recorded:
                complete = False
                continue
            if not _under(recorded, workspace):
                continue
            entry = meta_path.parent
            try:
                size = sum(f.stat().st_size for f in entry.rglob("*") if f.is_file())
            except OSError:
                complete = False
                size = 0
            out.append({
                "provider": VSCODE_PROVIDER_IDS[tool],
                "sessionId": entry.name,
                "source": str(meta_path),
                "subtranscripts": sorted(
                    str(f) for f in entry.rglob("*") if f.is_file() and f != meta_path
                ),
                # The entry directory, not `workspace.json` minus its
                # extension. An editor keeps `chat/` and `panels/` beside
                # the manifest, and letting the sealer guess flattens
                # them into digest-prefixed basenames.
                "artifactRoot": str(entry),
                "evidence": ["working-directory"],
                "confidence": "medium",
                "sizeBytes": size,
            })
    return (out, complete)


def bind_gemini(home: Path, workspace: str, *, deep: bool) -> tuple[list[dict], bool]:
    """Gemini records the workspace as `sha256(absolute path)` in every
    session file, which is an exact identity rather than a prefix guess --
    verified against this machine's own store before relying on it.

    The hash is over the path string, so it cannot answer "is this under
    the repo". `projects.json` supplies the registered paths and the ones
    inside the workspace are hashed too, which is what makes a repo's
    subdirectories and worktrees bind to the repo being retired.

    Case folding cannot help here: the hash is of the exact bytes the
    provider recorded. A workspace registered under different casing
    hashes differently and is invisible to this binder, which is why a
    content scan still runs when `deep` is set.
    """
    chats = sorted((home / ".gemini" / "tmp").glob("*/chats/*.json"))
    if not chats:
        return ([], True)

    wanted: dict[str, str] = {}

    def remember(path: str) -> None:
        wanted[hashlib.sha256(path.encode("utf-8")).hexdigest()] = path

    remember(workspace)
    registry = home / ".gemini" / "projects.json"
    # Without the registry the only hash we can compute is the workspace's
    # own, so a session held in a subdirectory or worktree is
    # unmatchable -- its `projectHash` is over a path we cannot enumerate.
    # A content scan does not rescue it either: transcripts routinely name
    # files relatively, so reading every byte and finding nothing proves
    # nothing here. Sessions exist and their workspace identity cannot be
    # reconstructed, which is the definition of an incomplete look.
    complete = not (chats and not registry.is_file())
    if registry.is_file():
        try:
            projects = json.loads(registry.read_text(encoding="utf-8-sig"))
        except JSON_FILE_ERRORS:
            # Without the registry only the workspace itself can be
            # hashed, so its subdirectories and worktrees go unchecked.
            complete = False
            projects = {}
        if not isinstance(projects, dict):
            complete = False
            projects = {}
        project_map = projects.get("projects")
        if not isinstance(project_map, dict):
            complete = False
            project_map = {}
        for path in project_map:
            if isinstance(path, str) and _under(_canon_workspace(path), workspace):
                remember(_canon_workspace(path))

    out: list[dict] = []
    for path in chats:
        try:
            payload = json.loads(path.read_text(encoding="utf-8-sig"))
        except JSON_FILE_ERRORS:
            complete = False
            continue
        if not isinstance(payload, dict):
            complete = False
            continue
        evidence: list[str] = []
        if payload.get("projectHash") in wanted:
            evidence.append("working-directory")
        elif deep:
            found, scanned_fully = _scans_for_paths(path, workspace)
            if not scanned_fully:
                complete = False
            if found:
                evidence.append("file-access")
        if not evidence:
            continue
        session_id = payload.get("sessionId") or path.stem
        out.append({
            "provider": "gemini",
            "sessionId": str(session_id),
            "source": str(path),
            "subtranscripts": [],
            "evidence": evidence,
            "confidence": _binding_confidence(evidence),
            "sizeBytes": path.stat().st_size,
        })
    return (out, complete)


def bind_claude(home: Path, workspace: str, *, deep: bool) -> tuple[list[dict], bool]:
    """Claude records `gitBranch` but never a remote URL, so no Claude
    session can ever reach `high` confidence from provider metadata
    alone. That asymmetry is why binding is per-provider rather than one
    generic scanner: the Codex path reads one line, this one may have to
    read the file."""
    root = home / ".claude" / "projects"
    if not root.is_dir():
        return ([], True)
    out: list[dict] = []
    complete = True
    for project_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        for path in sorted(project_dir.glob("*.jsonl")):
            cwd = None
            try:
                with path.open("r", encoding="utf-8", errors="replace") as handle:
                    for _ in range(CLAUDE_SCAN_LINES):
                        line = _read_json_line(handle)
                        if line is None:
                            break
                        if isinstance(line.get("cwd"), str):
                            cwd = _canon_workspace(line["cwd"])
                            break
            except OSError:
                # The metadata pre-read failed, so this transcript was
                # never examined at all -- weaker than a scan that ran and
                # found nothing.
                complete = False
                continue
            evidence: list[str] = []
            if cwd and _under(cwd, workspace):
                evidence.append("working-directory")
            elif deep:
                # Only when the cheap signal missed. A session already
                # bound by its cwd gains nothing from also having read
                # files there, and scanning it would be pure cost.
                found, scanned_fully = _scans_for_paths(path, workspace)
                if not scanned_fully:
                    complete = False
                if found:
                    evidence.append("file-access")
            if not evidence:
                continue
            session_id = path.stem
            subs = _claude_subtranscripts(project_dir, session_id)
            out.append({
                "provider": "claude",
                "sessionId": session_id,
                "source": str(path),
                "subtranscripts": [str(p) for p in subs],
                "evidence": evidence,
                "confidence": _binding_confidence(evidence),
                "sizeBytes": path.stat().st_size + sum(p.stat().st_size for p in subs),
            })
    return (out, complete)


# Session stores this module knows how to *find* (see the `collect_*`
# functions) paired with whether it can also *bind* them to a workspace.
# A store present on disk with no binder is the loudest kind of
# incompleteness: the scan never looked there at all, so "no sessions"
# would be a claim about two stores made on behalf of five.
BINDABLE_STORES = {
    "Claude", CLAUDE_DESKTOP_TOOL, "Codex", "Gemini",
} | set(VSCODE_PROVIDER_IDS)
KNOWN_STORE_ROOTS = {
    "Claude": (".claude/projects",),
    CLAUDE_DESKTOP_TOOL: ("/".join(CLAUDE_DESKTOP_LOCAL_SESSIONS),),
    "Codex": (".codex/sessions", ".codex/archived_sessions"),
    "Gemini": (".gemini/tmp",),
}


def unbound_stores_present(home: Path) -> list[str]:
    """Stores that exist on this machine but have no binder.

    VS Code forks live under Application Support and are enumerated by
    `collect_vscode_forks`; they are checked through the same table so a
    future binder only has to be added in one place.
    """
    present: list[str] = []

    def may_exist(root: Path) -> bool:
        # Binding coverage is a safety claim.  Never follow a store-root
        # symlink merely to decide whether that claim is complete, and never
        # turn an unreadable or malformed root into "absent".  Any named
        # object (or an access failure while looking for it) means the store
        # still needs a binder before coverage can be complete.
        try:
            root.lstat()
        except FileNotFoundError:
            return False
        except OSError:
            return True
        return True

    for store, roots in KNOWN_STORE_ROOTS.items():
        if store in BINDABLE_STORES:
            continue
        if any(may_exist(home / root) for root in roots):
            present.append(store)
    support = home / "Library" / "Application Support"
    for label, folder in VSCODE_FORKS:
        if label in BINDABLE_STORES:
            continue
        if may_exist(support / folder):
            present.append(label)
    return sorted(set(present))


def build_bindings_many(home: Path, targets: list[dict], *, deep: bool = False) -> dict:
    """`build_bindings` for several workspaces, reading each store once.

    Modore asks about every archive candidate on the screen, and a
    shallow pass never establishes completeness -- so every candidate
    needs a deep look, and doing that one repo at a time re-reads the
    whole session store per repo. Measured on this machine that is 14.5s
    across 53 candidates: thirteen minutes to answer a question the
    stores could have answered in one pass.

    Each `target` is `{"workspace": str, "repoUrl": str | None}`. The
    result maps workspace to the same shape `build_bindings` returns, so
    a caller can move between the two without reshaping anything.
    """
    workspaces = [_canon_workspace(t["workspace"]) for t in targets]
    repo_urls = {_canon_workspace(t["workspace"]): t.get("repoUrl") for t in targets}
    if not workspaces:
        return {"results": {}}

    per_workspace: dict[str, list[dict]] = {w: [] for w in workspaces}
    claude_complete = codex_complete = gemini_complete = forks_complete = True
    desktop_candidates, desktop_complete, desktop_state = (
        _claude_desktop_binding_scan(home))

    for workspace in workspaces:
        # The cheap, per-workspace parts stay per-workspace: they are
        # metadata comparisons, not file reads, and the shared cost is
        # entirely in the content scan below.
        claude, ok = bind_claude(home, workspace, deep=False)
        claude_complete = claude_complete and ok
        codex, ok = bind_codex(home, workspace, repo_urls[workspace], deep=False)
        codex_complete = codex_complete and ok
        gemini, ok = bind_gemini(home, workspace, deep=False)
        gemini_complete = gemini_complete and ok
        forks, ok = bind_vscode_forks(home, workspace)
        forks_complete = forks_complete and ok
        desktop = _bind_claude_desktop_candidates(
            desktop_candidates, workspace)
        per_workspace[workspace] = claude + desktop + codex + gemini + forks

    if deep:
        bound_sources = {w: {b["source"] for b in per_workspace[w]} for w in workspaces}
        for provider, path in _deep_scan_candidates(home):
            # `str`, not `Path`: `bound_sources` holds the same strings the
            # binders emit, and comparing the two types silently never
            # matches -- which rescans every already-bound file and adds a
            # second, differently-identified binding for it.
            source = str(path)
            unbound = [w for w in workspaces if source not in bound_sources[w]]
            if not unbound:
                continue
            matched, scanned_fully = _scan_for_any_path(path, unbound)
            if not scanned_fully:
                if provider == "claude":
                    claude_complete = False
                elif provider == "codex":
                    codex_complete = False
                else:
                    gemini_complete = False
            for workspace in matched:
                per_workspace[workspace].append(
                    _file_access_binding(provider, path)
                )

    unbound_stores = unbound_stores_present(home)
    scanned_fully = (
        claude_complete and desktop_complete and codex_complete
        and gemini_complete and forks_complete and not unbound_stores)
    fingerprint = store_fingerprint(home, desktop_state=desktop_state)
    results = {}
    for workspace in workspaces:
        bindings = sorted(per_workspace[workspace],
                          key=lambda b: (b["provider"], b["sessionId"]))
        results[workspace] = _binding_result(
            workspace, repo_urls[workspace], deep, bindings, fingerprint,
            claude_complete, desktop_complete, codex_complete,
            gemini_complete, forks_complete, unbound_stores, scanned_fully,
        )
    return {"results": results}


def _deep_scan_candidates(home: Path):
    """Every file a content scan would consider, tagged by store."""
    for path in sorted((home / ".claude" / "projects").glob("*/*.jsonl")):
        yield ("claude", path)
    for root in (home / ".codex" / "sessions", home / ".codex" / "archived_sessions"):
        if root.is_dir():
            for path in sorted(root.rglob("*.jsonl")):
                yield ("codex", path)
    for path in sorted((home / ".gemini" / "tmp").glob("*/chats/*.json")):
        yield ("gemini", path)


def _file_access_session_id(
        provider: str, path: Path, home: Optional[Path] = None) -> str:
    """The id each store's own binder would have used.

    Falling back to the filename would give the same session two
    different identities depending on which evidence found it, and the
    manifest would then record a session the provider cannot be asked
    about.
    """
    if provider == CLAUDE_DESKTOP_PROVIDER:
        metadata = _claude_desktop_metadata_for_path(path)
        payload, status = _read_claude_desktop_metadata(
            metadata or path, home)
        if status == "ok" and payload is not None:
            session_id = payload.get("sessionId")
            if isinstance(session_id, str) and session_id:
                return session_id
        # Never let ``audit.jsonl`` collapse every Desktop conversation to
        # the same id even if its metadata was temporarily unreadable.
        if metadata is not None:
            return metadata.stem
    if provider == "claude":
        return path.stem
    try:
        if provider == "gemini":
            payload = json.loads(path.read_text(encoding="utf-8-sig"))
            if isinstance(payload, dict) and payload.get("sessionId"):
                return str(payload["sessionId"])
        else:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                first = _read_json_line(handle)
            payload = (first or {}).get("payload")
            if isinstance(payload, dict) and payload.get("id"):
                return str(payload["id"])
    except JSON_FILE_ERRORS:
        pass
    return path.stem


def _file_access_binding(provider: str, path: Path) -> dict:
    return {
        "provider": provider,
        "sessionId": _file_access_session_id(provider, path),
        "source": str(path),
        "subtranscripts": [],
        "evidence": ["file-access"],
        "confidence": _binding_confidence(["file-access"]),
        "sizeBytes": path.stat().st_size,
    }


def store_fingerprint(
        home: Path, *,
        desktop_state: Optional[_ClaudeDesktopBindingState] = None,
        ) -> dict:
    """Digest over every candidate file in every bindable store.

    An assessment is a statement about a moment. Sealing hundreds of
    megabytes takes long enough for an agent to finish a turn and write a
    new session, and nothing about "these are the bound conversations"
    stays true across that. A timestamp would not catch it either -- the
    question is not "is the newest file newer" but "is this the same set
    of candidates I judged", which a rewritten or removed file changes
    just as much as an added one.

    Transcript content is never retained. Ordinary stores contribute paths,
    sizes, and mtimes; Desktop contributes its already-read metadata snapshot
    plus the no-follow conversation-unit inventory used by its binder.
    """
    hasher = hashlib.sha256()
    count = 0
    # Bind coverage also depends on every known store root. Its absent/present
    # state must participate in the revalidation token or a
    # stale "complete, zero sessions" assessment can survive a newly-created
    # Desktop store. lstat deliberately does not follow a leaf symlink.
    for store, roots in sorted(KNOWN_STORE_ROOTS.items()):
        for relative in sorted(roots):
            root = home / relative
            try:
                info = root.lstat()
            except FileNotFoundError:
                state = "missing"
            except OSError as exc:
                state = f"unreadable:{exc.errno}"
            else:
                state = "\0".join(str(value) for value in _stat_signature(info))
            hasher.update(
                f"store-root\0{store}\0{relative}\0{state}\n".encode("utf-8"))
    if desktop_state is None:
        _, _, desktop_state = _claude_desktop_binding_scan(home)
    desktop_snapshots = desktop_state.metadata_snapshots
    desktop_coverage = desktop_state.coverage
    hasher.update((
        "desktop-coverage\0"
        + json.dumps(desktop_coverage, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8"))
    hasher.update(
        f"desktop-binding-complete\0{int(desktop_state.complete)}\n".encode(
            "utf-8"))
    for snapshot in sorted(desktop_snapshots, key=lambda item: str(item.path)):
        hasher.update((
            f"{snapshot.path}\0"
            + "\0".join(str(value) for value in
                          _stat_signature(snapshot.metadata_info))
            + "\n"
        ).encode("utf-8"))
        count += 1
    for source_relative, artifact_snapshot in desktop_state.artifact_snapshots:
        hasher.update((
            "desktop-unit\0" + source_relative + "\0"
            + json.dumps(
                artifact_snapshot, ensure_ascii=False,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8"))
        # Metadata itself was counted above; the inventory also contains it.
        count += max(0, len(artifact_snapshot[0]) - 1)
    for path in sorted(
        list((home / ".claude" / "projects").glob("*/*.jsonl"))
        + list((home / ".codex" / "sessions").rglob("*.jsonl"))
        + list((home / ".codex" / "archived_sessions").rglob("*.jsonl"))
        + list((home / ".gemini" / "tmp").glob("*/chats/*.json"))
        + [meta for _, folder in VSCODE_FORKS
           for meta in (home / "Library" / "Application Support" / folder
                        / "User" / "workspaceStorage").glob("*/workspace.json")]
    ):
        try:
            info = path.stat()
        except OSError:
            # A file that vanished between listing and stat is itself a
            # change, and folding its path in keeps that visible.
            hasher.update(f"{path}\0missing\n".encode("utf-8"))
            count += 1
            continue
        hasher.update(
            f"{path}\0{info.st_size}\0{info.st_mtime_ns}\n".encode("utf-8"))
        count += 1
    return {"digest": hasher.hexdigest(), "fileCount": count}


def build_bindings(home: Path, workspace: str, *, repo_url: Optional[str] = None,
                   deep: bool = False) -> dict:
    """The whole output of `bind`.

    `assessed` is always true here, and that is the field the consumer
    actually needs: it is what lets "a binder ran and found nothing" be
    told apart from "no binder ran". An empty `bindings` list on its own
    cannot make that distinction, and a consumer that treats the two the
    same will delete a workspace whose conversations nobody checked for.
    """
    workspace = _canon_workspace(workspace)
    claude_bindings, claude_complete = bind_claude(home, workspace, deep=deep)
    desktop_candidates, desktop_complete, desktop_state = (
        _claude_desktop_binding_scan(home))
    desktop_bindings = _bind_claude_desktop_candidates(
        desktop_candidates, workspace)
    codex_bindings, codex_complete = bind_codex(home, workspace, repo_url, deep=deep)
    gemini_bindings, gemini_complete = bind_gemini(home, workspace, deep=deep)
    fork_bindings, forks_complete = bind_vscode_forks(home, workspace)
    bindings = (claude_bindings + desktop_bindings + codex_bindings
                + gemini_bindings + fork_bindings)
    unbound = unbound_stores_present(home)
    # Completeness is a property of the whole machine, not of the store
    # that happened to be scanned last. One unreadable rollout, one
    # unrecognised header, or one store with no binder is enough to make
    # "this workspace has no conversations" an assertion nobody checked.
    scanned_fully = (
        claude_complete and desktop_complete and codex_complete
        and gemini_complete and forks_complete and not unbound)
    bindings.sort(key=lambda b: (b["provider"], b["sessionId"]))
    return _binding_result(
        workspace, repo_url, deep, bindings,
        store_fingerprint(home, desktop_state=desktop_state),
        claude_complete, desktop_complete, codex_complete,
        gemini_complete, forks_complete, unbound, scanned_fully,
    )


# The frozen wire contract for one workspace's snapshot. Version 1.
#
# Everything a consumer outside this repository (Zoint first) may rely
# on. Three semantic limits are part of the contract, not commentary:
#
# 1. `coverage: "complete"` means every candidate binding was
#    conclusively classified -- decided by authoritative metadata or
#    read to EOF and found not to mention the workspace. It does NOT
#    mean the machine was completely observed.
# 2. `storeFingerprint` identifies the session-store state that was
#    observed at snapshot time, for same-or-changed comparison. It is
#    not a provenance proof of anything inside the stores.
# 3. A snapshot is historical evidence, never destructive authorization.
#    Anything acting on it must have Modore revalidate at the moment of
#    action -- the `revalidate` hook on the archive path exists for
#    exactly this.
#
# Additive changes (new optional keys) do not bump the version;
# renaming, removing, or changing the meaning of any key listed here
# does.
SNAPSHOT_SCHEMA = "modore.agent-state-snapshot"
SNAPSHOT_SCHEMA_VERSION = 1


def _binding_result(workspace, repo_url, deep, bindings, fingerprint,
                    claude_complete, desktop_complete, codex_complete,
                    gemini_complete, forks_complete, unbound,
                    scanned_fully) -> dict:
    """One workspace's answer, assembled the same way whichever path
    produced it -- single or batch. Kept in one place so the two cannot
    drift into reporting coverage differently."""
    return {
        "schema": SNAPSHOT_SCHEMA,
        "schemaVersion": SNAPSHOT_SCHEMA_VERSION,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "contract": ("session ids, evidence types, and sizes only; transcript "
                     "content is read for file-access evidence but never retained"),
        "workspace": workspace,
        "repoUrl": normalize_repo_url(repo_url) if repo_url else None,
        "deep": deep,
        # How much of the store was actually examined, which is a
        # different claim from whether the run finished.
        #
        #   shallow   -- matched recorded working directories only, so an
        #                empty result means "no session was *run* here",
        #                not "no session touched this repo".
        #   truncated -- a look that started and could not finish: a
        #                content scan that stopped early, a transcript
        #                that would not open, a store whose identity data
        #                is missing. It tried; it did not conclude.
        #   complete  -- every candidate was conclusively classified.
        #                Either its own metadata was authoritative enough
        #                to decide, or it was read to EOF and found not to
        #                mention the workspace. Not "every byte was read":
        #                a session already bound by its header gains
        #                nothing from being read again, and editor entries
        #                have no transcript body at all.
        "coverage": ("complete" if scanned_fully else "truncated") if deep else "shallow",
        "coverageDetail": {
            "claude": "complete" if claude_complete else "incomplete",
            "claudeDesktop": (
                "complete" if desktop_complete else "incomplete"),
            "codex": "complete" if codex_complete else "incomplete",
            "gemini": "complete" if gemini_complete else "incomplete",
            "editors": "complete" if forks_complete else "incomplete",
            "unboundStores": unbound,
        },
        "assessed": True,
        "storeFingerprint": fingerprint,
        "bindings": bindings,
        "summary": {
            "total": len(bindings),
            "byProvider": {
                p: sum(1 for b in bindings if b["provider"] == p)
                for p in (
                    "claude", CLAUDE_DESKTOP_PROVIDER, "codex", "gemini",
                    *sorted(VSCODE_PROVIDER_IDS.values()),
                )
            },
            "byConfidence": {
                c: sum(1 for b in bindings if b["confidence"] == c)
                for c in ("high", "medium", "low")
            },
            "sizeBytes": sum(b["sizeBytes"] for b in bindings),
        },
    }


def _format_size(size_bytes: int) -> str:
    if size_bytes >= 1 << 30:
        return f"{size_bytes / (1 << 30):.1f}GB"
    if size_bytes >= 1 << 20:
        return f"{size_bytes / (1 << 20):.0f}MB"
    return f"{size_bytes / 1024:.0f}KB"


def render_report(scree: dict, limit: int) -> str:
    lines = ["Modore scree — a map of what agents left behind (metadata-only · deterministic join)"]
    store_bits = []
    for store in scree["stores"]:
        if store["status"] == "missing":
            store_bits.append(f"{store['store']} none")
        else:
            note = f"+unresolved {store['unrecognized']}" if store["unrecognized"] else ""
            if store.get("subtranscripts"):
                note += f"+nested {store['subtranscripts']}"
            store_bits.append(f"{store['store']} {store['count']}{note}")
    lines.append("stores: " + " · ".join(store_bits))
    groups = scree["groups"]
    cross = sum(1 for g in groups if g["cross_tool"])
    orphan = sum(1 for g in groups if g["orphan"])
    lines.append(f"{len(groups)} groups — cross-tool {cross} · orphan {orphan}"
                 f" · unresolved sessions {scree['unresolved_sessions']}")
    lineage_summary = scree.get("lineage", {}).get("summary")
    if lineage_summary:
        lineage_line = (f"work paths {lineage_summary['total']}:"
                        f" alive+git {lineage_summary['alive_git']}"
                        f" · alive+plain {lineage_summary['alive_plain']}"
                        f" · vanished {lineage_summary['vanished']}")
        if lineage_summary.get("case_ghosts"):
            lineage_line += f" · case ghosts {lineage_summary['case_ghosts']}"
        lines.append(lineage_line)
    lines.append("")
    for rank, group in enumerate(groups[:limit], start=1):
        marks = []
        if group["cross_tool"]:
            marks.append("cross-tool")
        if group["orphan"]:
            marks.append("orphan")
        if group["worktrees"]:
            marks.append(f"worktree {len(group['worktrees'])}")
        tools = " · ".join(f"{name} {count}" for name, count in sorted(group["tools"].items()))
        label = group["key"] if group["grouped_by"] == "repo" else group["key"][3:]
        lines.append(f"{rank:2d}. [{'|'.join(marks) or 'single'}] {label}")
        lines.append(f"     {tools} | workspaces {len(group['workspaces'])}"
                     f" | {_format_size(group['size_bytes'])} | last active {group['last_active']}")
    retention = scree.get("retention", {})
    if retention.get("stores"):
        lines.append("")
        lines.append("retention forecast (estimated from observed file ages)")
        mode_label = {"rolling": "rolling", "long": "long retention", "insufficient": "insufficient data",
                      "configured": "configured"}
        for store in retention["stores"]:
            bits = [mode_label.get(store["mode"], store["mode"])]
            if store["mode"] == "rolling":
                bits[0] = f"rolling ~{store['window_days']}d"
            elif store["mode"] == "configured":
                days = store["configured_days"]
                bits[0] = ("configured: kept indefinitely" if days >= EFFECTIVELY_INDEFINITE_DAYS
                            else f"configured ~{days}d")
            bits.append(f"oldest {store['oldest_days']}d")
            if store["stalled"]:
                bits.append("recording may have stalled")
            lines.append(f"  {store['store']}: " + " · ".join(bits))
        expiring = retention.get("expiring", [])
        if expiring:
            wanted = [e for e in expiring if not e.get("owner_deleted")]
            alive = [e for e in wanted if e["story_alive"]]
            counts = [f"alive workspaces {len(alive)}",
                      f"orphaned {len(wanted) - len(alive)}"]
            discarded = len(expiring) - len(wanted)
            if discarded:
                counts.append(f"already deleted in the app {discarded}")
            lines.append(f"  expiring soon (within D-{EXPIRY_SOON_DAYS}) {len(expiring)}"
                         f" — " + " · ".join(counts))
            for entry in alive[:5]:
                lines.append(f"    D-{entry['days_left']} {entry['workspace']}"
                             f" ({entry['tool']}, {_format_size(entry['size_bytes'])})")
    worktrees = scree.get("worktrees", {})
    if worktrees.get("items"):
        items = worktrees["items"]
        counts: dict[str, int] = {}
        for item in items:
            counts[item["verdict"]] = counts.get(item["verdict"], 0) + 1
        lines.append("")
        lines.append("worktree anchor judgment (git registry · push state, read-only)")
        strays = [i for i in items if i.get("stray_checkout")]
        lines.append(f"  total {len(items)} — protected (sole-copy) {counts.get('protected', 0)}"
                     f" · rebuildable {counts.get('rebuildable', 0)}"
                     f" · unreadable {counts.get('unreadable', 0)}"
                     f" · unregistered {sum(1 for i in items if i['registered'] is False)}"
                     f" · registration unknown {sum(1 for i in items if i['registered'] is None)}"
                     f" · stray checkouts {len(strays)}")
        for item in strays:
            lines.append(f"    stray checkout: {item['path']} @ {item['branch']}"
                         f" ({item['verdict']}, unpushed {item['unpushed_commits']})")
        if worktrees["registered_missing"]:
            lines.append(f"  registry orphans (registered but vanished on disk) {len(worktrees['registered_missing'])}")
        for item in [i for i in items if i["verdict"] == "rebuildable"][:6]:
            lines.append(f"    rebuildable: {item['path']} (last commit {item['last_commit'] or '?'})")
    return "\n".join(lines)


MAX_PRESERVE_BYTES = 8 * 1024 * 1024

_EMAIL_RE = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
_JWT_RE = re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")
_PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----")
_API_KEY_RE = re.compile(
    r"\b(?:sk|pk)-[A-Za-z0-9]{16,}\b"
    r"|\bgh[opsu]_[A-Za-z0-9]{16,}\b"
    r"|\bAKIA[0-9A-Z]{16}\b"
    r"|\bASIA[0-9A-Z]{16}\b"
    r"|\bxox[baprs]-[A-Za-z0-9-]{10,}\b"
    r"|\bAIza[A-Za-z0-9_-]{20,}\b"
    r"|\bglpat-[A-Za-z0-9_-]{16,}\b")


def mask_text(text: str, home: Path) -> str:
    """Default-on redaction: email, JWT, PEM private keys, known API-key
    prefixes, and the caller's home path. Order matters — keys before the
    generic home-path swap so a key embedded in a home-relative path still
    gets caught by its own pattern first."""
    text = _PRIVATE_KEY_RE.sub("<private-key-redacted>", text)
    text = _JWT_RE.sub("<jwt-redacted>", text)
    text = _API_KEY_RE.sub("<api-key-redacted>", text)
    text = _EMAIL_RE.sub("<email-redacted>", text)
    home_str = str(home)
    if home_str:
        text = text.replace(home_str, "~")
    return text


# Content-block kinds that carry prose across the stores seen so far.
# Claude writes `text`; Codex splits the same thing by direction into
# `input_text`/`output_text`. Matching only `text` silently produced empty
# exports for every Codex session -- and Codex is the larger store on a
# machine that uses both.
TURN_TEXT_TYPES = ("text", "input_text", "output_text")


@dataclass(frozen=True)
class VisibleTurn:
    """One person-visible turn with its provider event provenance.

    Iteration deliberately yields only ``(role, text)`` so the title,
    inspect, and preserve readers keep consuming the same canonical
    conversation definition. Timestamp and event identity are additive
    provenance for search/evidence; they never change what counts as a
    visible turn.
    """

    role: str
    text: str
    at: Optional[str] = None
    event_id: Optional[str] = None

    def __iter__(self):
        yield self.role
        yield self.text


def _event_string(container: dict, *keys: str) -> Optional[str]:
    for key in keys:
        value = container.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _extract_turn(line: dict) -> Optional[VisibleTurn]:
    """Best-effort visible turn from one Claude, Codex, or Gemini record."""
    message = line.get("message") if isinstance(line.get("message"), dict) else None
    payload = line.get("payload") if isinstance(line.get("payload"), dict) else None
    container = message or payload
    if not isinstance(container, dict):
        return None
    role = container.get("role") or line.get("type")
    at = _event_string(line, "timestamp", "createdAt", "created_at", "_audit_timestamp") \
        or _event_string(container, "timestamp", "createdAt", "created_at")
    event_id = _event_string(line, "uuid", "eventId", "event_id") \
        or _event_string(container, "id", "uuid", "eventId", "event_id")
    content = container.get("content")
    if isinstance(content, str):
        return VisibleTurn(str(role or "?"), content, at, event_id)
    if isinstance(content, list):
        # Gemini's items carry `text` with no `type` at all, so an item
        # that is nothing but text counts as text.
        parts = [c.get("text", "") for c in content
                 if isinstance(c, dict)
                 and (c.get("type") in TURN_TEXT_TYPES or ("text" in c and "type" not in c))]
        joined = "\n".join(p for p in parts if p)
        return VisibleTurn(str(role or "?"), joined, at, event_id) if joined else None
    # Codex also emits a plain `agent_message` payload whose text is not
    # wrapped in a content list at all.
    if isinstance(container.get("message"), str) and container.get("type") == "agent_message":
        return VisibleTurn("assistant", container["message"], at, event_id)
    return None


# --- Session titles (display only, never gate input) -----------------------
#
# Binding evidence is a fact about deletion safety. A title is a fact
# about a person's memory, and the two must not be mixed: a title is
# lossy, guessed, and sometimes wrong, and nothing that decides whether a
# workspace may be deleted is allowed to rest on it.
#
# Extracting one is the first time this module retains any part of a
# conversation, so the terms are narrow: local only, masked by default,
# one line, length-capped, and produced for a session the caller names --
# never swept.

TITLE_MAX_CHARS = 80
# Above this a user turn is pasted context -- a stack trace, a file, a
# transcript -- not a request. Such a turn describes what was handed to
# the agent, not what the person wanted.
TITLE_PASTE_CHARS = 600
# Below this it is an acknowledgement: "네", "ok", "continue".
TITLE_MIN_CHARS = 8
# Turns that are structurally not requests, however long they are.
TITLE_SKIP_PREFIXES = ("/", "<", "#", "```")
# Phrases that resume or acknowledge rather than ask. They are real user
# turns of a reasonable length, so no length or shape rule catches them,
# and as a title they describe the mechanics of the session instead of
# its subject. Matched against the whole first line, folded -- a request
# that merely contains "continue" is still a request.
TITLE_BOILERPLATE = {
    "continue", "continue.", "go on", "go ahead", "proceed", "keep going",
    "continue from where you left off", "continue from where you left off.",
    "resume", "이어서", "계속", "계속해", "계속해줘", "진행", "진행해", "ㄱㄱ",
}


def _read_jsonl_turns(handle) -> tuple[list[VisibleTurn], bool]:
    """Decode visible records from an already-open text stream."""
    turns: list[VisibleTurn] = []
    decoded_any = False
    for line in handle:
        if len(line) > MAX_LINE_BYTES:
            continue
        try:
            parsed = json.loads(line)
        except JSON_PARSE_ERRORS:
            continue
        decoded_any = True
        if isinstance(parsed, dict):
            turn = _extract_turn(parsed)
            if turn:
                turns.append(turn)
    return (turns, decoded_any)


def _read_session_turns(
        source: Path, home: Optional[Path] = None
        ) -> tuple[list[VisibleTurn], str]:
    """`(turns, status)` for one session.

    The status is the half that matters. A transcript that vanished
    between binding and reading is the normal case here -- providers
    sweep their own stores -- and "no conversation" and "the conversation
    can no longer be read" are different facts to put in front of someone
    deciding whether to delete something. Returning `[]` for both is the
    same collapse the coverage work spent its length preventing, and it
    reappeared the moment a new reader was written.

    Status is one of `ok`, `missing`, `unreadable`, `unrecognized`.
    """
    desktop_descriptor, _, desktop_status = _open_claude_desktop_primary(
        source, home)
    if desktop_status != "not-desktop":
        if desktop_status != "ok" or desktop_descriptor is None:
            return ([], desktop_status)
        try:
            before = os.fstat(desktop_descriptor)
            with os.fdopen(os.dup(desktop_descriptor), "r", encoding="utf-8",
                           errors="replace") as handle:
                turns, decoded_any = _read_jsonl_turns(handle)
            after = os.fstat(desktop_descriptor)
        except OSError:
            return ([], "unreadable")
        finally:
            os.close(desktop_descriptor)
        if _stat_signature(before) != _stat_signature(after):
            return ([], "unreadable")
        if not decoded_any and before.st_size > 0:
            return ([], "unrecognized")
        return (turns, "ok")
    if not source.exists():
        return ([], "missing")
    turns: list[VisibleTurn] = []
    if source.suffix == ".json":
        try:
            payload = json.loads(source.read_text(encoding="utf-8-sig"))
        except OSError:
            return ([], "unreadable")
        except JSON_PARSE_ERRORS:
            return ([], "unrecognized")
        if not isinstance(payload, dict):
            return ([], "unrecognized")
        messages = payload.get("messages")
        for message in messages or []:
            if not isinstance(message, dict):
                continue
            # Gemini names the speaker `type`, where the JSONL stores use
            # `role`. Without normalising it every Gemini turn arrives
            # with an unknown speaker and no user request is ever found,
            # so the title silently degrades to the weakest fallback.
            normalised = dict(message)
            if "role" not in normalised and isinstance(normalised.get("type"), str):
                normalised["role"] = normalised["type"]
            turn = _extract_turn({
                "message": normalised,
                "timestamp": message.get("timestamp"),
                "uuid": message.get("uuid"),
            })
            if turn:
                turns.append(turn)
        return (turns, "ok")

    try:
        with source.open("r", encoding="utf-8", errors="replace") as handle:
            turns, decoded_any = _read_jsonl_turns(handle)
    except OSError:
        return ([], "unreadable")
    # A JSONL file none of whose lines parsed is not an empty
    # conversation; it is a file this build cannot read.
    if not decoded_any and source.stat().st_size > 0:
        return ([], "unrecognized")
    return (turns, "ok")


def _canonical_visible_turns(turns: list[VisibleTurn]) -> list[VisibleTurn]:
    """Collapse provider duplicates and remove harness-only roles."""
    deduped: list[VisibleTurn] = []
    for turn in turns:
        if (deduped and deduped[-1].role == turn.role
                and deduped[-1].text == turn.text):
            previous = deduped[-1]
            deduped[-1] = VisibleTurn(
                previous.role,
                previous.text,
                previous.at or turn.at,
                previous.event_id or turn.event_id,
            )
            continue
        deduped.append(turn)
    return [turn for turn in deduped
            if turn.role.lower() not in ("developer", "system")]


def visible_turns(
        source: Path, home: Optional[Path] = None
        ) -> tuple[list[VisibleTurn], str]:
    """`(turns, status)` for one session, as a person would read it.

    The single definition of what counts as the conversation. It lived
    inside `inspect` and nothing else could reach it, so every other
    reader answered a slightly different question about the same file --
    `search` could return the same Codex reply twice or surface harness
    instructions as a hit, and `title` could name a session after
    something the harness said rather than anything a person did.

    Two provider facts, both measured rather than assumed:

    Codex records one reply twice, as `response_item/message` and again
    as `event_msg/agent_message`, so a straight read doubles every agent
    turn -- 16 of 41 turns on a live rollout. Collapsing *consecutive*
    identical turns is provider-agnostic and cannot merge two things a
    person genuinely said twice, because a reply always separates those.

    `developer` and `system` turns are the harness talking to the agent,
    not the conversation. They are the longest thing in a Codex rollout,
    and treating them as content pushes the actual exchange off screen.
    """
    turns, status = _read_session_turns(source, home)
    if status != "ok":
        return ([], status)
    return (_canonical_visible_turns(turns), "ok")


def _turns_from_session(
        source: Path, home: Optional[Path] = None) -> list[VisibleTurn]:
    """Turns only, for callers that already treat absence as absence.

    `title` is one: a session it cannot read gets a date-shaped fallback,
    which is honest on its own terms. `inspect` needs the status and uses
    `_read_session_turns` directly.
    """
    return visible_turns(source, home)[0]


def _is_user_role(role: str) -> bool:
    return role.lower() in {"user", "human", "user_message"}


def _meaningful_request(text: str) -> Optional[str]:
    """The one line of a user turn worth showing, or None.

    Without this the title becomes an attachment notice, a slash command,
    a wrapped system block, or the first line of a pasted file -- all of
    which are the first user turn and none of which is what the person
    was trying to do.
    """
    stripped = text.strip()
    if not stripped or len(stripped) > TITLE_PASTE_CHARS:
        return None
    if stripped.startswith(TITLE_SKIP_PREFIXES):
        return None
    first = next((line.strip() for line in stripped.splitlines() if line.strip()), "")
    if len(first) < TITLE_MIN_CHARS or first.startswith(TITLE_SKIP_PREFIXES):
        return None
    return first


def _clip(text: str) -> str:
    collapsed = " ".join(text.split())
    if len(collapsed) <= TITLE_MAX_CHARS:
        return collapsed
    return collapsed[: TITLE_MAX_CHARS - 1].rstrip() + "\u2026"


def build_title(source: Path, home: Path, *, raw: bool = False,
                fallback_label: Optional[str] = None) -> dict:
    """Title, and where it came from.

    `titleSource` is not decoration. A first-request title and a
    date-shaped fallback look alike in a list and mean very different
    things, and only the caller showing them can decide whether to admit
    the difference.
    """
    desktop_payload, desktop_status = _read_claude_desktop_metadata(
        source, home)
    if desktop_status == "ok" and desktop_payload is not None:
        desktop_title = desktop_payload.get("title")
        if isinstance(desktop_title, str) and desktop_title.strip():
            title = desktop_title if raw else mask_text(desktop_title, home)
            return {"title": _clip(title), "titleSource": "provider-metadata"}

    turns = _turns_from_session(source, home)
    requests = [candidate for role, text in turns if _is_user_role(role)
                for candidate in [_meaningful_request(text)] if candidate]

    def is_boilerplate(candidate: str) -> bool:
        return candidate.strip().casefold().rstrip(".!~ ") in {
            phrase.rstrip(".!~ ") for phrase in TITLE_BOILERPLATE
        }

    title = None
    origin = "date"
    if requests:
        # Prefer the first request that says what the session was about.
        # A resumption marker is the first user turn of every continued
        # session, and taking it verbatim titles them all identically.
        subject = next((r for r in requests if not is_boilerplate(r)), None)
        title, origin = (subject, "first-request") if subject else (requests[0], "resumption")
    elif turns:
        # Nothing recognisable as a request, but the session had content:
        # the last thing said is a better anchor than the file's mtime.
        for role, text in reversed(turns):
            candidate = _meaningful_request(text)
            if candidate:
                title, origin = candidate, "recent-turn"
                break

    if title is None:
        try:
            stamp = time.strftime("%Y-%m-%d", time.localtime(source.stat().st_mtime))
        except OSError:
            stamp = "날짜 미상"
        title = f"{stamp} {fallback_label or '작업'}"

    if not raw:
        title = mask_text(title, home)
    return {"title": _clip(title), "titleSource": origin}


# --- Session inspection (display only, never gate input) --------------------
#
# The fourth deliberate content exception, and the one that makes the
# other three make sense to a person: `bind --deep` proves a session
# touched a workspace, `title` names it, `preserve` exports it -- and
# none of them lets the owner simply *look at* a conversation the
# machine already holds. Modore's judgment stays metadata-only;
# inspection is what the judgment plane is deliberately blind to,
# surfaced on explicit request. Nothing returned here is an input to
# any verdict -- structurally: no judgment path calls it.

INSPECT_TURN_CHARS = 400
INSPECT_DEFAULT_TURNS = 20


def _session_provider(source: Path, home: Path) -> str:
    """Which store a transcript lives in, from its path alone."""
    text = str(source)
    if _claude_desktop_metadata_for_path(source) is not None:
        return CLAUDE_DESKTOP_PROVIDER
    if "/.claude/" in text or text.startswith(str(home / ".claude")):
        return "claude"
    if "/.codex/" in text:
        return "codex"
    if "/.gemini/" in text:
        return "gemini"
    if "workspaceStorage" in text:
        return "editor"
    return "unknown"


def _session_workspace(
        provider: str, source: Path,
        home: Optional[Path] = None) -> Optional[str]:
    """The workspace the session itself recorded, when the store keeps one."""
    try:
        if provider == CLAUDE_DESKTOP_PROVIDER:
            payload, status = _read_claude_desktop_metadata(source, home)
            if status != "ok" or payload is None:
                return None
            for value in payload.get("userSelectedFolders", []):
                location = _safe_location(value)
                if location:
                    return location["basename"]
            location = _safe_location(payload.get("cwd"))
            return location["basename"] if location else None
        if provider == "claude":
            with source.open("r", encoding="utf-8", errors="replace") as handle:
                for _ in range(CLAUDE_SCAN_LINES):
                    line = _read_json_line(handle)
                    if line is None:
                        break
                    if isinstance(line.get("cwd"), str):
                        return _canon_workspace(line["cwd"])
        elif provider == "codex":
            with source.open("r", encoding="utf-8", errors="replace") as handle:
                first = _read_json_line(handle)
            payload = (first or {}).get("payload")
            if isinstance(payload, dict) and isinstance(payload.get("cwd"), str):
                return _canon_workspace(payload["cwd"])
    except OSError:
        return None
    # Gemini records only a path hash; there is no workspace string to read.
    return None


def build_inspect(source: Path, home: Path, *, raw: bool = False,
                  turn_limit: int = INSPECT_DEFAULT_TURNS) -> dict:
    """One session's conversation, prepared for display.

    The rules that make this safe to expose are the point, not the
    plumbing: one caller-named session per invocation, never swept;
    masked by default; every turn capped, because a pasted stack trace is
    context the agent was handed, not something a preview should replay;
    and the recent window plus the opening request, because a person
    recognising a session needs how it started and where it ended, not
    the middle. Subagent transcripts are not opened -- expanding those is
    its own explicit act.
    """
    provider = _session_provider(source, home)
    turns, status = visible_turns(source, home)

    def clip(text: str) -> str:
        cleaned = " ".join(text.split())
        if not raw:
            cleaned = mask_text(cleaned, home)
        if len(cleaned) > INSPECT_TURN_CHARS:
            cleaned = cleaned[: INSPECT_TURN_CHARS - 1].rstrip() + "\u2026"
        return cleaned

    first_user = next((clip(text) for role, text in turns
                       if _is_user_role(role) and text.strip()), None)
    window = turns[-turn_limit:] if turn_limit > 0 else []
    return {
        # `ok` / `missing` / `unreadable` / `unrecognized`. A caller that
        # shows "no conversation" for anything but `ok` is telling
        # someone about to delete this that there was nothing to lose.
        "status": status,
        "provider": provider,
        "sessionId": _file_access_session_id(
            provider if provider in ("claude", "codex", "gemini",
                                     CLAUDE_DESKTOP_PROVIDER) else "claude",
            source, home),
        "workspace": _session_workspace(provider, source, home),
        "messageCount": len(turns),
        "userTurnCount": sum(1 for role, _ in turns if _is_user_role(role)),
        "firstUserTurn": first_user,
        # `index` is the turn's ordinal in the window, because a display
        # needs stable identity and the obvious substitute -- role plus
        # text -- collides on exactly the case the dedupe rule
        # deliberately preserves: the same person saying the same thing
        # twice with a reply in between.
        "turns": [{"index": position, "role": turn.role, "text": clip(turn.text),
                   "at": turn.at, "eventId": turn.event_id}
                  for position, turn in enumerate(window) if turn.text.strip()],
        "omittedTurns": max(0, len(turns) - len(window)),
        "masked": not raw,
    }


def render_preserve(source: Path, home: Path, *, raw: bool) -> str:
    requested_source = source
    desktop_descriptor, desktop_source, desktop_status = (
        _open_claude_desktop_primary(source, home))
    if desktop_status != "not-desktop":
        if (desktop_status != "ok" or desktop_source is None
                or desktop_descriptor is None):
            raise ValueError(f"cannot resolve Desktop conversation: {desktop_status}")
        source = desktop_source
    lines = ["# Preserved session export", "",
             f"Source: `{requested_source if raw else str(requested_source).replace(str(home), '~')}`",
             f"Masking: {'DISABLED (--raw)' if raw else 'default-on (email/JWT/API-key/private-key/home-path)'}",
             ""]
    turns = 0

    def consume(handle) -> None:
        nonlocal turns
        for raw_line in handle:
            if not raw_line.strip():
                continue
            try:
                parsed = json.loads(raw_line)
            except JSON_PARSE_ERRORS:
                continue
            if not isinstance(parsed, dict):
                continue
            turn = _extract_turn(parsed)
            if turn is None:
                continue
            role, text = turn
            if not raw:
                text = mask_text(text, home)
            lines.extend((f"## {role}", "", text, ""))
            turns += 1

    if desktop_descriptor is not None:
        try:
            before = os.fstat(desktop_descriptor)
            if before.st_size > MAX_PRESERVE_BYTES:
                raise ValueError(
                    f"refusing to export {source}: exceeds {MAX_PRESERVE_BYTES} bytes "
                    "(single-session exports are meant to be reviewed, not bulk-dumped)")
            with os.fdopen(os.dup(desktop_descriptor), "r", encoding="utf-8",
                           errors="replace") as handle:
                consume(handle)
            if _stat_signature(before) != _stat_signature(
                    os.fstat(desktop_descriptor)):
                raise ValueError("Desktop conversation changed during export")
        finally:
            os.close(desktop_descriptor)
    else:
        if not source.is_file():
            raise FileNotFoundError(f"no such session file: {source}")
        if source.stat().st_size > MAX_PRESERVE_BYTES:
            raise ValueError(f"refusing to export {source}: exceeds {MAX_PRESERVE_BYTES} bytes "
                             "(single-session exports are meant to be reviewed, not bulk-dumped)")
        with source.open("r", encoding="utf-8", errors="replace") as handle:
            consume(handle)
    if turns == 0:
        lines.append("_(no recognizable turns — file kept in its original session-store format)_")
    return "\n".join(lines)


# Original session backups are deliberately separate from the lossy Markdown
# export. Keep them in this sealed script so the app's pinned invocation does
# not load an unverified helper from a mutable Python search path.
BACKUP_MAX_BYTES = 2 * 1024 * 1024 * 1024
BACKUP_MAX_FILES = 10000
BACKUP_MAX_DEPTH = 128
RESTORE_MAX_DIRECTORIES = 192
BACKUP_MANIFEST_MAX_BYTES = 4 * 1024 * 1024
BACKUP_CHUNK_BYTES = 1024 * 1024
# APFS/HFS+ expose NAME_MAX=255 UTF-16 code units (not UTF-8 bytes). Every
# payload path is restored one component at a time, so reject a forged ZIP
# name the shipped filesystem cannot create before calling it "verified".
RESTORE_NAME_MAX_UNITS = 255
# macOS reports PATH_MAX=1024 and symlink(2) reserves one byte for NUL: a
# 1,024-byte target is already ENAMETOOLONG. Verification must never approve a
# payload restore cannot create on the shipped platform.
BACKUP_SYMLINK_MAX_BYTES = 1023
BACKUP_EXCLUSIONS = [
    "workspace-code", "project-memory", "settings-and-credentials",
    "other-sessions", "external-referenced-files",
]
BACKUP_DESKTOP_EXCLUSIONS = [
    "other-conversation-units", "external-referenced-files",
]


def _backup_relative(value: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise ValueError("invalid archive path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(p in ("", ".", "..") for p in value.split("/")):
        raise ValueError("unsafe archive path")
    if len(path.parts) > BACKUP_MAX_DEPTH:
        raise ValueError("archive path is too deep")
    try:
        if any(_filesystem_name_units(component) > RESTORE_NAME_MAX_UNITS
               for component in path.parts):
            raise ValueError("archive path component is too long")
    except UnicodeEncodeError as exc:
        raise ValueError("archive path is not a filesystem name") from exc
    return path


def _backup_scope(source_relative: str) -> tuple[str, list[PurePosixPath]]:
    source = _backup_relative(source_relative)
    parts = source.parts
    if (len(parts) == 4 and parts[:2] == (".claude", "projects")
            and source.suffix == ".jsonl"):
        session = source.stem
        if not session or session in (".", ".."):
            raise ValueError("invalid session name")
        return "Claude", [
            source.parent / session / "subagents",
            source.parent / session / "tool-results",
            *[PurePosixPath(".claude") / kind / session
              for kind in ("file-history", "image-cache", "uploads")],
        ]
    if (len(parts) >= 3 and parts[0] == ".codex"
            and parts[1] in ("sessions", "archived_sessions")
            and source.suffix == ".jsonl"):
        return "Codex", []
    desktop_prefix = CLAUDE_DESKTOP_LOCAL_SESSIONS
    if (len(parts) >= len(desktop_prefix) + 3
            and parts[:len(desktop_prefix)] == desktop_prefix
            and source.suffix == ".json"
            and re.fullmatch(r"local_[A-Za-z0-9_-]+", source.stem)):
        # The metadata JSON plus its same-named directory is the complete
        # owned unit.  userSelectedFolders may point anywhere on disk, but no
        # path from metadata is ever turned into a backup root.
        return CLAUDE_DESKTOP_TOOL, [source.with_suffix("")]
    raise ValueError(
        "only Claude projects, Claude Desktop conversation units, and Codex session stores are supported")


def _backup_scope_name(source_relative: str) -> str:
    provider, _ = _backup_scope(source_relative)
    if provider == CLAUDE_DESKTOP_TOOL:
        return "claude-desktop-conversation-unit"
    if provider == "Claude":
        return "claude-code-session"
    return "codex-session"


def _stat_identity(value: os.stat_result) -> tuple[int, int]:
    return (value.st_dev, value.st_ino)


def _stat_signature(value: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode), value.st_size,
        value.st_mtime_ns, value.st_ctime_ns, value.st_nlink,
    )


def _content_signature(value: os.stat_result) -> tuple[int, int, int]:
    return (value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def _validated_leaf_name(value: str) -> str:
    if (not isinstance(value, str) or not value or value in (".", "..")
            or "/" in value or "\x00" in value):
        raise ValueError("invalid filesystem name")
    return value


def _relative_components(value: str | PurePosixPath) -> tuple[str, ...]:
    relative = _backup_relative(str(value))
    for component in relative.parts:
        _validated_leaf_name(component)
    return relative.parts


def _open_directory_component(
        parent_descriptor: int, name: str, *,
        expected: Optional[tuple[int, int]] = None
        ) -> tuple[int, tuple[int, int]]:
    """Open one directory component without a pathname check/use gap."""
    _validated_leaf_name(name)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    except OSError as exc:
        try:
            named = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        except OSError:
            named = None
        if exc.errno == errno.ELOOP or (
                named is not None and stat.S_ISLNK(named.st_mode)):
            raise ValueError("symlinks are not supported in session backups") from exc
        raise
    try:
        info = os.fstat(descriptor)
    except BaseException:
        os.close(descriptor)
        raise
    # Directory mtimes/ctimes change when unrelated names are created in the
    # same directory (for example, publishing a backup beside a synthetic
    # HOME in an integration test).  The security boundary is the opened
    # component's inode, device, and no-follow traversal; entry identities are
    # inventoried separately and the entire scoped tree is walked again before
    # publication.
    signature = _stat_identity(info)
    if (not stat.S_ISDIR(info.st_mode)
            or (expected is not None and signature != expected)):
        os.close(descriptor)
        raise ValueError("session path changed during backup")
    return descriptor, signature


@dataclass(frozen=True)
class _BackupEntry:
    relative: str
    kind: str
    signature: tuple[int, int, int, int, int, int, int]

    @property
    def size(self) -> int:
        return self.signature[3]


@dataclass
class _BackupInventory:
    entries: dict[str, _BackupEntry]
    directories: dict[str, tuple[int, int]]
    device: int

    def snapshot(self) -> tuple:
        return (
            tuple(sorted((key, entry.kind, entry.signature)
                         for key, entry in self.entries.items())),
            tuple(sorted(self.directories.items())),
        )


def _backup_open_parent(
        home_descriptor: int, relative: str | PurePosixPath,
        directories: dict[str, tuple[int, int]], *,
        record: bool) -> tuple[int, str]:
    parts = _relative_components(relative)
    descriptor = os.dup(home_descriptor)
    prefix: list[str] = []
    try:
        home_identity = _stat_identity(os.fstat(descriptor))
        if record:
            directories.setdefault("", home_identity)
        elif directories.get("") != home_identity:
            raise ValueError("session home changed during backup")
        for component in parts[:-1]:
            prefix.append(component)
            key = "/".join(prefix)
            expected = None if record else directories.get(key)
            if not record and expected is None:
                raise ValueError("session directory was not inventoried")
            next_descriptor, identity = _open_directory_component(
                descriptor, component, expected=expected)
            os.close(descriptor)
            descriptor = next_descriptor
            if record:
                previous = directories.setdefault(key, identity)
                if previous != identity:
                    raise ValueError("session path changed during inventory")
        return descriptor, parts[-1]
    except BaseException:
        os.close(descriptor)
        raise


def _backup_open_directory(
        home_descriptor: int, relative: PurePosixPath,
        directories: dict[str, tuple[int, int]], *,
        record: bool,
        missing_ok: bool = False) -> Optional[int]:
    parent_descriptor, name = _backup_open_parent(
        home_descriptor, relative, directories, record=record)
    try:
        key = str(relative)
        expected = None if record else directories.get(key)
        if not record and expected is None:
            raise ValueError("session directory was not inventoried")
        try:
            descriptor, identity = _open_directory_component(
                parent_descriptor, name, expected=expected)
        except FileNotFoundError:
            if missing_ok:
                return None
            raise
        if record:
            previous = directories.setdefault(key, identity)
            if previous != identity:
                os.close(descriptor)
                raise ValueError("session path changed during inventory")
        return descriptor
    finally:
        os.close(parent_descriptor)


def _backup_inventory(home_descriptor: int, source_relative: str) -> _BackupInventory:
    """Inventory one session below an already-open canonical home directory.

    Every later read reopens components beneath this descriptor and requires
    the exact directory/file identities recorded here. A parent renamed and
    replaced by a symlink can therefore never redirect the copy outside home.
    """
    provider, roots = _backup_scope(source_relative)
    allow_owned_links = provider == CLAUDE_DESKTOP_TOOL
    entries: dict[str, _BackupEntry] = {}
    directories: dict[str, tuple[int, int]] = {
        "": _stat_identity(os.fstat(home_descriptor)),
    }
    source_device: Optional[int] = None

    def require_device(info: os.stat_result) -> None:
        if source_device is not None and info.st_dev != source_device:
            raise ValueError("session scope crosses a filesystem boundary")

    def add(relative: PurePosixPath, *, allow_link: bool = False) -> None:
        nonlocal source_device
        parent_descriptor, name = _backup_open_parent(
            home_descriptor, relative, directories, record=True)
        try:
            info = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        finally:
            os.close(parent_descriptor)
        kind = "symlink" if stat.S_ISLNK(info.st_mode) else "file"
        if kind == "symlink" and not allow_link:
            raise ValueError("symlinks are not supported in session backups")
        if kind == "file" and not stat.S_ISREG(info.st_mode):
            raise ValueError("session backups require regular files")
        if kind == "file" and info.st_nlink != 1:
            raise ValueError("hard-linked files are not supported in session backups")
        if source_device is None:
            source_device = info.st_dev
            if any(identity[0] != source_device for identity in directories.values()):
                raise ValueError("session scope crosses a filesystem boundary")
        require_device(info)
        key = str(relative)
        entries[key] = _BackupEntry(key, kind, _stat_signature(info))
        if len(entries) > BACKUP_MAX_FILES:
            raise ValueError("session backup has too many files")

    def walk(relative: PurePosixPath) -> None:
        try:
            descriptor = _backup_open_directory(
                home_descriptor, relative, directories, record=True, missing_ok=True)
        except FileNotFoundError:
            return
        if descriptor is None:
            return
        try:
            require_device(os.fstat(descriptor))
            if len(directories) > BACKUP_MAX_FILES:
                raise ValueError("session backup has too many directories")
            try:
                entries_context = os.scandir(descriptor)
            except OSError as exc:
                raise ValueError("session sidecar directory is unreadable") from exc
            with entries_context as directory_entries:
                for directory_entry in directory_entries:
                    name = directory_entry.name
                    _validated_leaf_name(name)
                    child = relative / name
                    try:
                        info = os.stat(
                            name, dir_fd=descriptor,
                            follow_symlinks=False)
                    except FileNotFoundError as exc:
                        raise ValueError(
                            "session files changed during inventory") from exc
                    require_device(info)
                    if stat.S_ISDIR(info.st_mode):
                        child_descriptor, identity = _open_directory_component(
                            descriptor, name, expected=_stat_identity(info))
                        try:
                            key = str(child)
                            previous = directories.setdefault(key, identity)
                            if previous != identity:
                                raise ValueError(
                                    "session path changed during inventory")
                        finally:
                            os.close(child_descriptor)
                        walk(child)
                    elif stat.S_ISLNK(info.st_mode):
                        add(child, allow_link=allow_owned_links)
                    elif stat.S_ISREG(info.st_mode):
                        add(child)
                    else:
                        raise ValueError(
                            "session backups require regular files")
        finally:
            os.close(descriptor)

    add(PurePosixPath(source_relative))
    for relative in roots:
        walk(relative)

    if source_device is None:
        raise ValueError("session source is missing")
    if any(identity[0] != source_device for identity in directories.values()):
        raise ValueError("session scope crosses a filesystem boundary")
    inventory = _BackupInventory(
        dict(sorted(entries.items())), directories, source_device)
    if sum(entry.size for entry in inventory.entries.values()) > BACKUP_MAX_BYTES:
        raise ValueError("session backup exceeds the size limit")
    restore_directories: set[PurePosixPath] = set()
    for name in inventory.entries:
        parent = PurePosixPath(name).parent
        while str(parent) != ".":
            restore_directories.add(parent)
            parent = parent.parent
        if len(restore_directories) > RESTORE_MAX_DIRECTORIES:
            # Restore has a deliberately bounded descriptor/cleanup ledger.
            # Reject before reading payload bytes or allocating a temporary
            # ZIP, rather than doing gigabytes of work for an archive the
            # verifier is guaranteed to reject.
            raise ValueError("backup has too many restore directories")

    if provider == CLAUDE_DESKTOP_TOOL:
        metadata_entry = inventory.entries[source_relative]
        metadata = _backup_read_bytes(
            home_descriptor, inventory, metadata_entry,
            limit=CLAUDE_DESKTOP_METADATA_MAX_BYTES)
        payload = _parse_claude_desktop_metadata(metadata, PurePosixPath(source_relative).stem)
        if payload is None:
            raise ValueError("invalid Claude Desktop conversation metadata")
        cli_session_id = payload["cliSessionId"]
        if re.fullmatch(r"[A-Za-z0-9_-]+", cli_session_id) is None:
            raise ValueError("invalid Claude Desktop primary transcript identity")
        unit = PurePosixPath(source_relative).with_suffix("")
        primary = [
            entry for entry in inventory.entries.values()
            if PurePosixPath(entry.relative).name == f"{cli_session_id}.jsonl"
            and unit in PurePosixPath(entry.relative).parents
            and entry.kind == "file"
        ]
        if len(primary) != 1:
            raise ValueError("Claude Desktop conversation has no unique primary transcript")
    return inventory


def _backup_stream(source, target=None, *, limit: int = BACKUP_MAX_BYTES) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = source.read(BACKUP_CHUNK_BYTES)
        if not chunk:
            break
        size += len(chunk)
        if size > limit:
            raise ValueError("session backup exceeds the size limit")
        digest.update(chunk)
        if target is not None:
            target.write(chunk)
    return size, digest.hexdigest()


def _backup_read_file(
        home_descriptor: int, inventory: _BackupInventory,
        entry: _BackupEntry, target=None, *,
        limit: int = BACKUP_MAX_BYTES) -> tuple[int, str]:
    parent_descriptor, name = _backup_open_parent(
        home_descriptor, entry.relative, inventory.directories, record=False)
    try:
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                dir_fd=parent_descriptor,
            )
        except OSError as exc:
            raise ValueError(
                "session changed during backup; retry after it stops writing") from exc
        try:
            before = os.fstat(descriptor)
            if (not stat.S_ISREG(before.st_mode)
                    or before.st_dev != inventory.device
                    or before.st_nlink != 1
                    or _stat_signature(before) != entry.signature):
                raise ValueError("session changed during backup; retry after it stops writing")
            with os.fdopen(os.dup(descriptor), "rb") as source:
                result = _backup_stream(source, target, limit=limit)
            after = os.fstat(descriptor)
            named = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
            if (_stat_signature(before) != _stat_signature(after)
                    or _stat_signature(after) != _stat_signature(named)):
                raise ValueError("session changed during backup; retry after it stops writing")
            return result
        finally:
            os.close(descriptor)
    finally:
        os.close(parent_descriptor)


def _backup_read_bytes(
        home_descriptor: int, inventory: _BackupInventory,
        entry: _BackupEntry, *, limit: int) -> bytes:
    target = io.BytesIO()
    size, _ = _backup_read_file(
        home_descriptor, inventory, entry, target, limit=limit)
    if size > limit:
        raise ValueError("session backup exceeds the size limit")
    return target.getvalue()


def _backup_read_symlink(
        home_descriptor: int, inventory: _BackupInventory,
        entry: _BackupEntry, target=None) -> tuple[int, str]:
    """Copy a Desktop-owned link as link text, never its referent.

    Desktop sandboxes commonly leave ``.claude/debug/latest`` pointing at a
    now-vanished VM path.  Rejecting it made an otherwise valid conversation
    impossible to preserve; following it could escape the conversation unit.
    The ZIP payload therefore stores only ``readlink(2)`` bytes and restore
    recreates the link after every regular file has been written.
    """
    parent_descriptor, name = _backup_open_parent(
        home_descriptor, entry.relative, inventory.directories, record=False)
    try:
        before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (not stat.S_ISLNK(before.st_mode)
                or _stat_signature(before) != entry.signature):
            raise ValueError("session changed during backup; retry after it stops writing")
        value = os.fsencode(os.readlink(name, dir_fd=parent_descriptor))
        if len(value) > BACKUP_SYMLINK_MAX_BYTES:
            raise ValueError("session backup symlink target is too large")
        after = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        current = os.fsencode(os.readlink(name, dir_fd=parent_descriptor))
        if _stat_signature(before) != _stat_signature(after) or current != value:
            raise ValueError("session changed during backup; retry after it stops writing")
        digest = hashlib.sha256(value).hexdigest()
        if target is not None:
            target.write(value)
        return len(value), digest
    finally:
        os.close(parent_descriptor)


def _backup_manifest(archive: zipfile.ZipFile) -> dict:
    infos = archive.infolist()
    if not infos or len(infos) > BACKUP_MAX_FILES + 1:
        raise ValueError("invalid archive file count")
    names = [info.filename for info in infos]
    if len(names) != len(set(names)) or "manifest.json" not in names:
        raise ValueError("duplicate entries or missing backup manifest")
    for info in infos:
        _backup_relative(info.filename)
        mode = info.external_attr >> 16
        if (info.is_dir() or (stat.S_IFMT(mode) not in (0, stat.S_IFREG))
                or info.flag_bits & 1
                or info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)):
            raise ValueError("unsupported archive entry")
    manifest_info = archive.getinfo("manifest.json")
    if manifest_info.file_size > BACKUP_MANIFEST_MAX_BYTES:
        raise ValueError("backup manifest exceeds the size limit")
    try:
        manifest = json.loads(archive.read(manifest_info))
    except JSON_PARSE_ERRORS as exc:
        raise ValueError("invalid backup manifest") from exc
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1:
        raise ValueError("unsupported backup manifest")
    source = manifest.get("sourceRelative")
    provider, roots = _backup_scope(source)
    if manifest.get("provider") != provider:
        raise ValueError("backup provider does not match its source")
    expected_scope = _backup_scope_name(source)
    if manifest.get("scope", expected_scope) != expected_scope:
        raise ValueError("backup scope does not match its source")
    entries = manifest.get("files")
    if not isinstance(entries, list) or not entries or len(entries) > BACKUP_MAX_FILES:
        raise ValueError("invalid backup manifest files")
    expected = {"manifest.json"}
    entries_by_path = {}
    payload_paths: set[str] = set()
    payload_ancestors: set[str] = set()
    restore_directories: set[PurePosixPath] = set()
    total = 0
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("invalid backup file entry")
        relative = _backup_relative(entry.get("path"))
        if str(relative) != source and not any(root in relative.parents for root in roots):
            raise ValueError("backup entry is outside this session's scope")
        name = "payload/" + str(relative)
        if name in expected:
            raise ValueError("duplicate backup file path")
        relative_text = str(relative)
        parents = {
            str(parent) for parent in relative.parents
            if str(parent) != "."
        }
        # ZIP has no filesystem type constraints between payload entries. A
        # symlink/file can therefore be declared at `a` while another payload
        # lives at `a/b`; verification used to approve that impossible tree
        # and restore then failed after partial work. Every payload entry is a
        # leaf, so neither an earlier nor a later path may be its ancestor.
        if (relative_text in payload_ancestors
                or any(parent in payload_paths for parent in parents)):
            raise ValueError("backup payload paths have an ancestor conflict")
        expected.add(name)
        entries_by_path[relative_text] = entry
        payload_paths.add(relative_text)
        payload_ancestors.update(parents)
        parent = relative.parent
        while str(parent) != ".":
            restore_directories.add(parent)
            parent = parent.parent
        if len(restore_directories) > RESTORE_MAX_DIRECTORIES:
            raise ValueError("backup has too many restore directories")
        size, digest = entry.get("size"), entry.get("sha256")
        kind = entry.get("kind", "file")
        expected_category = _backup_category(
            provider, source, str(relative))
        if (type(size) is not int or size < 0 or not isinstance(digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", digest) is None
                or kind not in ("file", "symlink")
                or entry.get("category") != expected_category
                or (kind == "symlink" and size > BACKUP_SYMLINK_MAX_BYTES)):
            raise ValueError("invalid backup file metadata")
        if kind == "symlink" and not (
                provider == CLAUDE_DESKTOP_TOOL
                and str(relative) != source
                and any(root in relative.parents for root in roots)):
            raise ValueError("backup symlinks are limited to Claude Desktop sidecars")
        total += size
        if total > BACKUP_MAX_BYTES:
            raise ValueError("session backup exceeds the size limit")
        if name not in names or archive.getinfo(name).file_size != size:
            raise ValueError("backup file is missing or has the wrong size")
    if expected != set(names) or "payload/" + source not in expected:
        raise ValueError("backup has unexpected files or no primary transcript")
    if provider == CLAUDE_DESKTOP_TOOL:
        metadata_info = archive.getinfo("payload/" + source)
        metadata_entry = entries_by_path.get(source)
        if (metadata_entry is None or metadata_entry.get("kind", "file") != "file"
                or metadata_info.file_size > CLAUDE_DESKTOP_METADATA_MAX_BYTES):
            raise ValueError("invalid Claude Desktop conversation metadata")
        payload = _parse_claude_desktop_metadata(
            archive.read(metadata_info), PurePosixPath(source).stem)
        if payload is None:
            raise ValueError("invalid Claude Desktop conversation metadata")
        cli_session_id = payload["cliSessionId"]
        if re.fullmatch(r"[A-Za-z0-9_-]+", cli_session_id) is None:
            raise ValueError("invalid Claude Desktop primary transcript identity")
        unit = PurePosixPath(source).with_suffix("")
        primary = [
            path for path, entry in entries_by_path.items()
            if PurePosixPath(path).name == f"{cli_session_id}.jsonl"
            and unit in PurePosixPath(path).parents
            and entry.get("kind", "file") == "file"
        ]
        if len(primary) != 1:
            raise ValueError("Claude Desktop backup has no unique primary transcript")
    return manifest


def _backup_verify_open(archive: zipfile.ZipFile) -> dict:
    manifest = _backup_manifest(archive)
    for entry in manifest["files"]:
        with archive.open("payload/" + entry["path"]) as source:
            if entry.get("kind", "file") == "symlink":
                value = source.read(BACKUP_SYMLINK_MAX_BYTES + 1)
                size = len(value)
                digest = hashlib.sha256(value).hexdigest()
                if not value or b"\x00" in value:
                    raise ValueError("backup symlink target is invalid")
            else:
                size, digest = _backup_stream(source, limit=entry["size"])
        if (size, digest) != (entry["size"], entry["sha256"]):
            raise ValueError("backup checksum mismatch")
    return manifest


def _backup_result(archive: Path, manifest: dict, restored: Path | None = None) -> dict:
    # A Desktop conversation unit is archived recursively without filtering
    # names. It can contain copied code, settings, tokens, or credentials, so
    # claiming those categories were excluded would be a false safety receipt.
    exclusions = (BACKUP_DESKTOP_EXCLUSIONS
                  if manifest["provider"] == CLAUDE_DESKTOP_TOOL
                  else BACKUP_EXCLUSIONS)
    return {
        "schemaVersion": 1, "status": "restored" if restored else "verified",
        "archive": str(archive), "provider": manifest["provider"],
        "scope": manifest.get("scope") or _backup_scope_name(manifest["sourceRelative"]),
        "sourceRelative": manifest["sourceRelative"],
        "fileCount": len(manifest["files"]),
        "totalBytes": sum(e["size"] for e in manifest["files"]),
        "categories": sorted(set(e["category"] for e in manifest["files"]
                                 if isinstance(e.get("category"), str))),
        "excluded": list(exclusions),
        "masked": False, "encrypted": False,
        "restoredRoot": str(restored) if restored else None,
        "restoredSource": str(restored / manifest["sourceRelative"]) if restored else None,
    }


def verify_session_backup(archive: Path) -> dict:
    archive = archive.expanduser().absolute()
    with _open_backup_bundle(archive) as bundle:
        return _backup_result(archive, _backup_verify_open(bundle))


@contextlib.contextmanager
def _open_backup_bundle(archive: Path):
    """Open one selected archive inode without blocking on special files."""
    descriptor = os.open(
        archive,
        os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC,
    )
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise ValueError("backup archive is not a regular file")
        visible_before = os.lstat(archive)
        referent_before = os.stat(archive)
        if _stat_identity(referent_before) != _stat_identity(opened):
            raise ValueError("backup archive path changed before verification")
        before = _content_signature(opened)
        with os.fdopen(os.dup(descriptor), "rb") as handle:
            with zipfile.ZipFile(handle) as bundle:
                yield bundle
        after = os.fstat(descriptor)
        try:
            visible_after = os.lstat(archive)
            referent_after = os.stat(archive)
        except OSError as exc:
            raise ValueError(
                "backup archive path changed during verification") from exc
        if (_content_signature(after) != before
                or _stat_signature(visible_after)
                != _stat_signature(visible_before)
                or _stat_identity(referent_after) != _stat_identity(after)):
            raise ValueError("backup archive changed during verification")
    finally:
        os.close(descriptor)


def _install_sigterm_cleanup(cleanup: Callable[[], None]) -> Any:
    """Run operation-owned cleanup before LocalProcessRunner's hard kill.

    The app terminates a timed-out process group with SIGTERM, then SIGKILL one
    second later. Python's default SIGTERM action skips ``finally`` blocks, so
    a backup could otherwise leave a multi-gigabyte partial ZIP and a restore
    could leave its partial output tree. The handler exits through SystemExit,
    which also lets ordinary context managers finish closing their handles.
    """
    previous = signal.getsignal(signal.SIGTERM)

    def handle(signum, _frame) -> None:
        try:
            cleanup()
        finally:
            raise SystemExit(128 + signum)

    try:
        signal.signal(signal.SIGTERM, handle)
    except ValueError:
        # Signal handlers may only be installed on Python's main thread. The
        # shipped CLI always runs there; keeping library calls functional on a
        # worker thread does not weaken the app-owned execution path.
        return None
    return previous


def _restore_sigterm_handler(previous: Any) -> None:
    if previous is not None:
        signal.signal(signal.SIGTERM, previous)


@contextlib.contextmanager
def _blocked_sigterm():
    """Make one filesystem mutation and its ownership record indivisible."""
    if not hasattr(signal, "pthread_sigmask"):
        yield
        return
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def _directory_path_identity(path: Path, expected: tuple[int, int]) -> bool:
    """Validate a visible directory path without ever following a link."""
    try:
        descriptor = _open_directory_nofollow(path)
    except OSError:
        return False
    try:
        info = os.fstat(descriptor)
        return stat.S_ISDIR(info.st_mode) and _stat_identity(info) == expected
    finally:
        os.close(descriptor)


def _unlink_same_file_at(
        parent_descriptor: int, name: str, identity: tuple[int, int]) -> None:
    """Best-effort cleanup inside an already-open parent directory."""
    try:
        current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if _stat_identity(current) == identity and stat.S_ISREG(current.st_mode):
            os.unlink(name, dir_fd=parent_descriptor)
    except OSError:
        pass


def _rollback_new_entry_at(
        parent_descriptor: int, name: str, identity: tuple[int, int], *,
        directory: bool) -> None:
    """Undo a created name only while it still names the known inode."""
    try:
        current = os.stat(
            name, dir_fd=parent_descriptor, follow_symlinks=False)
        expected_kind = (stat.S_ISDIR(current.st_mode) if directory
                         else not stat.S_ISDIR(current.st_mode))
        if _stat_identity(current) != identity or not expected_kind:
            return
        if directory:
            os.rmdir(name, dir_fd=parent_descriptor)
        else:
            os.unlink(name, dir_fd=parent_descriptor)
    except OSError:
        pass


def _remove_same_file(path: Path, identity: tuple[int, int]) -> None:
    """Compatibility wrapper for descriptor-anchored temporary cleanup."""
    try:
        parent_descriptor = _open_directory_nofollow(path.parent)
    except OSError:
        return
    try:
        _unlink_same_file_at(parent_descriptor, path.name, identity)
    finally:
        os.close(parent_descriptor)


def _backup_verify_descriptor(descriptor: int) -> dict:
    """Verify the exact opened ZIP inode, independent of its visible name."""
    with os.fdopen(os.dup(descriptor), "rb") as handle:
        handle.seek(0)
        with zipfile.ZipFile(handle) as bundle:
            return _backup_verify_open(bundle)


def _backup_category(provider: str, source_relative: str, name: str) -> str:
    path = PurePosixPath(name)
    path_parts = path.parts
    if provider == CLAUDE_DESKTOP_TOOL:
        unit = PurePosixPath(source_relative).with_suffix("")
        inside = PurePosixPath(name).relative_to(unit).parts if name != source_relative else ()
        return (
            "metadata" if name == source_relative else
            "audit" if inside == ("audit.jsonl",) else
            "subagents" if "subagents" in inside else
            "queue" if "sessions" in inside and name.endswith(".jsonl") else
            "transcript" if name.endswith(".jsonl") else
            "uploads" if inside and inside[0] == "uploads" else
            "outputs" if inside and inside[0] == "outputs" else
            "sidecar"
        )
    if name == source_relative:
        return "transcript"
    if provider == "Claude":
        _, roots = _backup_scope(source_relative)
        for category, root in zip(
                ("subagents", "tool-results", "file-history", "image-cache", "uploads"),
                roots):
            if path == root or root in path.parents:
                return category
    return "sidecar"


def build_session_backup(source: Path, home: Path, destination: Path, *,
                         include_sensitive: bool = False) -> dict:
    if not include_sensitive:
        raise ValueError("raw backup includes private content; --include-sensitive is required")
    original_home = home.expanduser().absolute()
    home = original_home.resolve(strict=True)
    source = source.expanduser().absolute()
    # Preserve the store-relative spelling, including any symlink to reject.
    try:
        relative = source.relative_to(home).as_posix()
    except ValueError:
        # macOS callers can name a canonical home through /var rather than
        # /private/var. Resolve only the home prefix, not the session itself.
        relative = source.relative_to(original_home).as_posix()
    provider, _ = _backup_scope(relative)
    parent = destination.expanduser().absolute().parent.resolve(strict=True)
    destination_name = _validated_leaf_name(destination.name)
    destination = parent / destination_name
    if any(root == parent or root in parent.parents for root in
           (home / ".claude", home / ".codex/sessions", home / ".codex/archived_sessions",
            _claude_desktop_root(home))):
        raise ValueError("keep the backup outside the live session store")
    manifest = {
        "schemaVersion": 1,
        "provider": provider,
        "scope": _backup_scope_name(relative),
        "sourceRelative": relative,
        "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "files": [],
    }

    home_descriptor = _open_directory_nofollow(home)
    try:
        parent_descriptor = _open_directory_nofollow(parent)
    except BaseException:
        os.close(home_descriptor)
        raise
    parent_identity = _stat_identity(os.fstat(parent_descriptor))
    try:
        os.stat(
            destination_name, dir_fd=parent_descriptor,
            follow_symlinks=False)
    except FileNotFoundError:
        pass
    except BaseException:
        os.close(parent_descriptor)
        os.close(home_descriptor)
        raise
    else:
        os.close(parent_descriptor)
        os.close(home_descriptor)
        raise ValueError(
            "backup destination already exists; choose a new filename")
    temporary_name = ".modore-backup-" + os.urandom(16).hex()
    temporary_descriptor = -1
    temporary_identity: Optional[tuple[int, int]] = None
    state = {"published": False, "completed": False}

    def cleanup() -> None:
        if temporary_identity is not None:
            _unlink_same_file_at(
                parent_descriptor, temporary_name, temporary_identity)
        if (state["published"] and not state["completed"]
                and temporary_identity is not None):
            _unlink_same_file_at(
                parent_descriptor, destination_name, temporary_identity)

    previous_sigterm = _install_sigterm_cleanup(cleanup)
    try:
        inventory = _backup_inventory(home_descriptor, relative)
        with _blocked_sigterm():
            try:
                temporary_descriptor = os.open(
                    temporary_name,
                    os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                    0o600,
                    dir_fd=parent_descriptor,
                )
            except FileExistsError as exc:
                raise ValueError(
                    "could not allocate a private backup filename") from exc
            try:
                temporary_info = os.fstat(temporary_descriptor)
            except BaseException:
                try:
                    recovered = os.fstat(temporary_descriptor)
                except OSError:
                    recovered = None
                if recovered is not None:
                    _rollback_new_entry_at(
                        parent_descriptor, temporary_name,
                        _stat_identity(recovered), directory=False)
                raise
            if (not stat.S_ISREG(temporary_info.st_mode)
                    or temporary_info.st_nlink != 1):
                raise ValueError("backup temporary file is not private")
            temporary_identity = _stat_identity(temporary_info)
            os.fchmod(temporary_descriptor, 0o600)

        # ZipFile receives a duplicate of the already-open inode. It never
        # resolves the random temporary name.
        with os.fdopen(os.dup(temporary_descriptor), "r+b") as handle:
            handle.seek(0)
            handle.truncate()
            with zipfile.ZipFile(
                    handle, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
                total = 0
                for name, inventory_entry in inventory.entries.items():
                    with bundle.open(
                            "payload/" + name, "w", force_zip64=True) as target:
                        reader = (_backup_read_symlink
                                  if inventory_entry.kind == "symlink"
                                  else _backup_read_file)
                        size, digest = reader(
                            home_descriptor, inventory, inventory_entry, target)
                    total += size
                    if total > BACKUP_MAX_BYTES:
                        raise ValueError("session backup exceeds the size limit")
                    manifest["files"].append({
                        "path": name,
                        "size": size,
                        "sha256": digest,
                        "category": _backup_category(provider, relative, name),
                        "kind": inventory_entry.kind,
                    })

                # Rewalk from the fixed home descriptor, then hash every exact
                # inventoried inode again before making a success claim.
                current = _backup_inventory(home_descriptor, relative)
                if inventory.snapshot() != current.snapshot():
                    raise ValueError(
                        "session files changed during backup; retry when idle")
                for manifest_entry in manifest["files"]:
                    inventory_entry = inventory.entries[manifest_entry["path"]]
                    reader = (_backup_read_symlink
                              if inventory_entry.kind == "symlink"
                              else _backup_read_file)
                    if reader(
                            home_descriptor, inventory, inventory_entry) != (
                                manifest_entry["size"], manifest_entry["sha256"]):
                        raise ValueError(
                            "session changed during backup; retry when idle")
                bundle.writestr(
                    "manifest.json",
                    json.dumps(manifest, ensure_ascii=False, indent=2),
                )
            handle.flush()
        os.fsync(temporary_descriptor)

        named_temp = os.stat(
            temporary_name, dir_fd=parent_descriptor, follow_symlinks=False)
        opened_temp = os.fstat(temporary_descriptor)
        if (_stat_identity(named_temp) != temporary_identity
                or _stat_identity(opened_temp) != temporary_identity
                or not stat.S_ISREG(named_temp.st_mode)
                or named_temp.st_nlink != 1
                or opened_temp.st_nlink != 1):
            raise ValueError("backup temporary file changed during creation")
        before_verify = os.fstat(temporary_descriptor)
        verified_manifest = _backup_verify_descriptor(temporary_descriptor)
        after_verify = os.fstat(temporary_descriptor)
        if _content_signature(before_verify) != _content_signature(after_verify):
            raise ValueError("backup ZIP changed during verification")
        if verified_manifest != manifest:
            raise ValueError("backup manifest changed during verification")
        if not _directory_path_identity(parent, parent_identity):
            raise ValueError(
                "backup destination directory changed during creation")

        # linkat is an atomic no-clobber publish from the exact named inode in
        # the already-open parent. Never reopen the temporary ZIP by pathname.
        with _blocked_sigterm():
            named_temp = os.stat(
                temporary_name, dir_fd=parent_descriptor,
                follow_symlinks=False)
            if (_stat_identity(named_temp) != temporary_identity
                    or named_temp.st_nlink != 1
                    or _stat_identity(os.fstat(
                        temporary_descriptor)) != temporary_identity):
                raise ValueError(
                    "backup temporary file changed before publish")
            try:
                os.link(
                    temporary_name,
                    destination_name,
                    src_dir_fd=parent_descriptor,
                    dst_dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
            except FileExistsError as exc:
                raise ValueError(
                    "backup destination already exists; choose a new filename") from exc
            state["published"] = True
        published = os.stat(
            destination_name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (_stat_identity(published) != temporary_identity
                or not stat.S_ISREG(published.st_mode)
                or published.st_nlink != 2
                or os.fstat(temporary_descriptor).st_nlink != 2):
            raise ValueError("published backup identity mismatch")
        # Linking changes ctime/nlink, so take a fresh stable signature and
        # verify the exact opened inode again after publication. A mutation in
        # the gap after the first verify can never become a success receipt.
        before_published_verify = os.fstat(temporary_descriptor)
        if _backup_verify_descriptor(temporary_descriptor) != manifest:
            raise ValueError("published backup manifest mismatch")
        after_published_verify = os.fstat(temporary_descriptor)
        if (_content_signature(before_published_verify)
                != _content_signature(after_published_verify)):
            raise ValueError("published backup changed during verification")
        named_temp = os.stat(
            temporary_name, dir_fd=parent_descriptor, follow_symlinks=False)
        published = os.stat(
            destination_name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (_stat_identity(named_temp) != temporary_identity
                or _stat_identity(published) != temporary_identity
                or named_temp.st_nlink != 2
                or published.st_nlink != 2):
            raise ValueError("published backup names changed during verification")
        if not _directory_path_identity(parent, parent_identity):
            raise ValueError(
                "backup destination directory changed during publish")
        state["completed"] = True
        return _backup_result(destination, manifest)
    finally:
        with _blocked_sigterm():
            try:
                cleanup()
            finally:
                if temporary_descriptor >= 0:
                    try:
                        os.close(temporary_descriptor)
                    except OSError:
                        pass
                for descriptor in (parent_descriptor, home_descriptor):
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass
                _restore_sigterm_handler(previous_sigterm)

@dataclass(frozen=True)
class _RestoreOwnedEntry:
    parent: str
    name: str
    kind: str
    identity: tuple[int, int]
    size: int
    digest: str
    descriptor: Optional[int]


class _RestoreLedger:
    """Own restore outputs by open descriptors, never by mutable paths."""

    def __init__(self, parent: Path, parent_descriptor: int, root_name: str):
        self.parent = parent
        self.parent_descriptor = os.dup(parent_descriptor)
        try:
            parent_info = os.fstat(self.parent_descriptor)
        except BaseException:
            os.close(self.parent_descriptor)
            raise
        self.parent_identity = _stat_identity(parent_info)
        self.parent_device = parent_info.st_dev
        self.root_name = _validated_leaf_name(root_name)
        self.root_descriptor: Optional[int] = None
        self.root_identity: Optional[tuple[int, int]] = None
        self.device: Optional[int] = None
        # relative -> (held descriptor, identity, parent relative, leaf name)
        self.directories: dict[
            str, tuple[int, tuple[int, int], str, str]
        ] = {}
        self.owned: list[_RestoreOwnedEntry] = []

    def create_root(self) -> None:
        with _blocked_sigterm():
            try:
                os.stat(
                    self.root_name,
                    dir_fd=self.parent_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                pass
            else:
                raise ValueError(
                    "restore requires a NEW directory; existing data is never overwritten")
            try:
                os.mkdir(self.root_name, 0o700, dir_fd=self.parent_descriptor)
            except FileExistsError as exc:
                raise ValueError(
                    "restore requires a NEW directory; existing data is never overwritten") from exc
            descriptor = -1
            try:
                descriptor = os.open(
                    self.root_name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=self.parent_descriptor,
                )
                opened = os.fstat(descriptor)
                identity = _stat_identity(opened)
                # Ledger ownership before the namespace recheck: if that
                # recheck fails, cleanup can remove only this exact inode.
                self.root_identity = identity
                observed = os.stat(
                    self.root_name,
                    dir_fd=self.parent_descriptor,
                    follow_symlinks=False,
                )
            except BaseException:
                if descriptor >= 0:
                    if self.root_identity is None:
                        try:
                            recovered = os.fstat(descriptor)
                        except OSError:
                            recovered = None
                        if (recovered is not None
                                and stat.S_ISDIR(recovered.st_mode)):
                            self.root_identity = _stat_identity(recovered)
                    os.close(descriptor)
                raise
            if (not stat.S_ISDIR(opened.st_mode)
                    or _stat_identity(observed) != self.root_identity
                    or observed.st_dev != self.parent_device
                    or opened.st_dev != self.parent_device):
                os.close(descriptor)
                raise ValueError(
                    "restore destination crossed a filesystem boundary")
            self.root_descriptor = descriptor
            self.device = opened.st_dev
            os.fchmod(descriptor, 0o700)

    def validate_root(self) -> None:
        if self.root_descriptor is None or self.root_identity is None:
            raise ValueError("restore destination was not created")
        if not _directory_path_identity(self.parent, self.parent_identity):
            raise ValueError("restore destination parent changed during restore")
        try:
            named = os.stat(
                self.root_name,
                dir_fd=self.parent_descriptor,
                follow_symlinks=False,
            )
        except OSError as exc:
            raise ValueError("restore destination changed during restore") from exc
        if (not stat.S_ISDIR(named.st_mode)
                or _stat_identity(named) != self.root_identity):
            raise ValueError("restore destination changed during restore")

    def open_directory(self, relative: str, *, create: bool) -> int:
        self.validate_root()
        assert self.root_descriptor is not None
        descriptor = os.dup(self.root_descriptor)
        if not relative:
            return descriptor
        prefix: list[str] = []
        try:
            for component in _relative_components(relative):
                parent_key = "/".join(prefix)
                prefix.append(component)
                key = "/".join(prefix)
                recorded = self.directories.get(key)
                if recorded is None:
                    if not create:
                        raise ValueError(
                            "restore directory changed during restore")
                    with _blocked_sigterm():
                        try:
                            os.mkdir(component, 0o700, dir_fd=descriptor)
                        except FileExistsError as exc:
                            raise ValueError(
                                "restore archive paths conflict with existing data") from exc
                        child = -1
                        try:
                            child = os.open(
                                component,
                                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                dir_fd=descriptor,
                            )
                            opened = os.fstat(child)
                            identity = _stat_identity(opened)
                            # Record the opened inode before the fallible named
                            # recheck, dup, or chmod.
                            self.directories[key] = (
                                -1, identity, parent_key, component)
                            observed = os.stat(
                                component,
                                dir_fd=descriptor,
                                follow_symlinks=False,
                            )
                            if (not stat.S_ISDIR(opened.st_mode)
                                    or _stat_identity(observed) != identity
                                    or opened.st_dev != self.device):
                                raise ValueError(
                                    "restore directory changed during creation")
                            held = os.dup(child)
                            try:
                                self.directories[key] = (
                                    held, identity, parent_key, component)
                            except BaseException:
                                os.close(held)
                                raise
                            os.fchmod(child, 0o700)
                        except BaseException:
                            if child >= 0:
                                if key not in self.directories:
                                    try:
                                        recovered = os.fstat(child)
                                    except OSError:
                                        recovered = None
                                    if (recovered is not None
                                            and stat.S_ISDIR(
                                                recovered.st_mode)):
                                        self.directories[key] = (
                                            -1, _stat_identity(recovered),
                                            parent_key, component)
                                os.close(child)
                            raise
                else:
                    _, identity, recorded_parent, recorded_name = recorded
                    if (recorded_parent != parent_key
                            or recorded_name != component):
                        raise ValueError("restore directory ledger mismatch")
                    try:
                        child = os.open(
                            component,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                            dir_fd=descriptor,
                        )
                    except OSError as exc:
                        raise ValueError(
                            "restore directory changed during restore") from exc
                    try:
                        opened = os.fstat(child)
                    except BaseException:
                        os.close(child)
                        raise
                    if (not stat.S_ISDIR(opened.st_mode)
                            or _stat_identity(opened) != identity
                            or opened.st_dev != self.device):
                        os.close(child)
                        raise ValueError(
                            "restore directory changed during restore")
                os.close(descriptor)
                descriptor = child
            return descriptor
        except BaseException:
            os.close(descriptor)
            raise

    def record_owned(
            self, parent: str, name: str, kind: str,
            identity: tuple[int, int], size: int, digest: str, *,
            descriptor: Optional[int] = None) -> None:
        held = os.dup(descriptor) if descriptor is not None else None
        try:
            self.owned.append(_RestoreOwnedEntry(
                parent, name, kind, identity, size, digest, held))
        except BaseException:
            if held is not None:
                os.close(held)
            raise

    def validate_all(self) -> None:
        self.validate_root()
        for relative in sorted(
                self.directories,
                key=lambda value: (value.count("/"), value)):
            descriptor = self.open_directory(relative, create=False)
            os.close(descriptor)
        for entry in self.owned:
            parent_descriptor = self.open_directory(
                entry.parent, create=False)
            try:
                try:
                    named = os.stat(
                        entry.name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                except OSError as exc:
                    raise ValueError(
                        "restored file changed during restore") from exc
                expected_kind = (
                    stat.S_ISLNK(named.st_mode)
                    if entry.kind == "symlink"
                    else stat.S_ISREG(named.st_mode)
                )
                if (not expected_kind
                        or _stat_identity(named) != entry.identity
                        or named.st_dev != self.device):
                    raise ValueError("restored file changed during restore")
                if entry.kind == "symlink":
                    value = os.fsencode(os.readlink(
                        entry.name, dir_fd=parent_descriptor))
                    named_after = os.stat(
                        entry.name, dir_fd=parent_descriptor,
                        follow_symlinks=False)
                    if (not stat.S_ISLNK(named_after.st_mode)
                            or named_after.st_dev != self.device
                            or _stat_identity(named_after) != entry.identity
                            or _stat_signature(named_after)
                            != _stat_signature(named)):
                        raise ValueError(
                            "restored file changed during restore")
                    final = (len(value), hashlib.sha256(value).hexdigest())
                else:
                    descriptor = os.open(
                        entry.name,
                        os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                        | os.O_CLOEXEC,
                        dir_fd=parent_descriptor,
                    )
                    try:
                        opened = os.fstat(descriptor)
                        if (_stat_identity(opened) != entry.identity
                                or not stat.S_ISREG(opened.st_mode)
                                or opened.st_nlink != 1
                                or opened.st_dev != self.device):
                            raise ValueError(
                                "restored file changed during restore")
                        with os.fdopen(os.dup(descriptor), "rb") as source:
                            final = _backup_stream(source, limit=entry.size)
                        after = os.fstat(descriptor)
                        named_after = os.stat(
                            entry.name, dir_fd=parent_descriptor,
                            follow_symlinks=False)
                        if (_stat_signature(opened)
                                != _stat_signature(after)
                                or _stat_identity(named_after)
                                != entry.identity):
                            raise ValueError(
                                "restored file changed during restore")
                    finally:
                        os.close(descriptor)
            finally:
                os.close(parent_descriptor)
            if final != (entry.size, entry.digest):
                raise ValueError("restored file checksum mismatch")

    def cleanup(self) -> None:
        # Held parent descriptors still name operation-owned files even if an
        # attacker moved a directory out of the visible restore tree.
        for entry in reversed(self.owned):
            if entry.parent:
                recorded = self.directories.get(entry.parent)
                parent_descriptor = (
                    recorded[0] if recorded is not None else None)
            else:
                parent_descriptor = self.root_descriptor
            if parent_descriptor is None:
                continue
            try:
                named = os.stat(
                    entry.name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                # dev+ino is not enough after unlink/recreate: Linux can reuse
                # the just-freed inode immediately.  That made cleanup remove
                # an attacker/user replacement even though the ledger had
                # never created its bytes.  Reconfirm the recorded payload as
                # well as the namespace identity before unlinking.  Symlinks
                # are bounded to 1,023 bytes; regular-file hashing happens only
                # on a failed restore and is capped by the manifest size.
                payload_matches = False
                if (entry.kind == "symlink"
                        and stat.S_ISLNK(named.st_mode)):
                    value = os.fsencode(os.readlink(
                        entry.name, dir_fd=parent_descriptor))
                    after = os.stat(
                        entry.name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                    payload_matches = (
                        _stat_identity(after) == entry.identity
                        and len(value) == entry.size
                        and hashlib.sha256(value).hexdigest() == entry.digest
                    )
                elif (entry.kind == "file"
                      and entry.descriptor is not None
                      and stat.S_ISREG(named.st_mode)):
                    # Keeping the creation descriptor open prevents its inode
                    # from being recycled. A matching namespace identity is
                    # therefore still our file even when a failed write or a
                    # final validation changed its bytes, and should be
                    # removed. A replacement cannot acquire this live inode.
                    held = os.fstat(entry.descriptor)
                    payload_matches = (
                        stat.S_ISREG(held.st_mode)
                        and _stat_identity(held) == entry.identity
                    )
                if (_stat_identity(named) == entry.identity
                        and payload_matches):
                    os.unlink(entry.name, dir_fd=parent_descriptor)
            except (OSError, ValueError):
                pass
        for key in sorted(
                self.directories,
                key=lambda value: (value.count("/"), value),
                reverse=True):
            _, identity, parent_key, name = self.directories[key]
            if parent_key:
                parent_record = self.directories.get(parent_key)
                parent_descriptor = (
                    parent_record[0] if parent_record is not None else None)
            else:
                parent_descriptor = self.root_descriptor
            if parent_descriptor is None:
                continue
            try:
                named = os.stat(
                    name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
                if (stat.S_ISDIR(named.st_mode)
                        and _stat_identity(named) == identity):
                    os.rmdir(name, dir_fd=parent_descriptor)
            except OSError:
                pass
        if self.root_identity is not None:
            try:
                named = os.stat(
                    self.root_name,
                    dir_fd=self.parent_descriptor,
                    follow_symlinks=False,
                )
                if (stat.S_ISDIR(named.st_mode)
                        and _stat_identity(named) == self.root_identity):
                    os.rmdir(
                        self.root_name, dir_fd=self.parent_descriptor)
            except OSError:
                pass

    def close(self) -> None:
        for entry in self.owned:
            if entry.descriptor is not None:
                try:
                    os.close(entry.descriptor)
                except OSError:
                    pass
        self.owned.clear()
        for descriptor, _, _, _ in self.directories.values():
            try:
                os.close(descriptor)
            except OSError:
                pass
        self.directories.clear()
        if self.root_descriptor is not None:
            try:
                os.close(self.root_descriptor)
            except OSError:
                pass
            self.root_descriptor = None
        try:
            os.close(self.parent_descriptor)
        except OSError:
            pass


def _restore_regular(
        bundle: zipfile.ZipFile, entry: dict,
        ledger: _RestoreLedger) -> tuple[int, str]:
    relative = _backup_relative(entry["path"])
    parent = "" if str(relative.parent) == "." else str(relative.parent)
    name = _validated_leaf_name(relative.name)
    parent_descriptor = ledger.open_directory(parent, create=True)
    descriptor = -1
    try:
        with _blocked_sigterm():
            descriptor = os.open(
                name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=parent_descriptor,
            )
            try:
                before = os.fstat(descriptor)
                identity = _stat_identity(before)
                ledger.record_owned(
                    parent, name, "file", identity,
                    entry["size"], entry["sha256"], descriptor=descriptor)
            except BaseException:
                try:
                    recovered = os.fstat(descriptor)
                except OSError:
                    recovered = None
                if recovered is not None:
                    _rollback_new_entry_at(
                        parent_descriptor, name, _stat_identity(recovered),
                        directory=False)
                raise
            if (not stat.S_ISREG(before.st_mode)
                    or before.st_nlink != 1
                    or before.st_dev != ledger.device):
                raise ValueError(
                    "restore output is not a private regular file")
            os.fchmod(descriptor, 0o600)
        with os.fdopen(os.dup(descriptor), "wb") as output, bundle.open(
                "payload/" + entry["path"]) as source:
            result = _backup_stream(
                source, output, limit=entry["size"])
            output.flush()
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        named = os.stat(
            name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (_stat_identity(after) != identity
                or _stat_identity(named) != identity
                or not stat.S_ISREG(named.st_mode)
                or after.st_nlink != 1):
            raise ValueError("restored file changed during restore")
        os.lseek(descriptor, 0, os.SEEK_SET)
        with os.fdopen(os.dup(descriptor), "rb") as restored:
            confirmed = _backup_stream(
                restored, limit=entry["size"])
        if result != confirmed:
            raise ValueError("restored file checksum mismatch")
        return result
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_descriptor)


def _restore_symlink(
        bundle: zipfile.ZipFile, entry: dict,
        ledger: _RestoreLedger) -> tuple[int, str]:
    relative = _backup_relative(entry["path"])
    parent = "" if str(relative.parent) == "." else str(relative.parent)
    name = _validated_leaf_name(relative.name)
    with bundle.open("payload/" + entry["path"]) as source:
        value = source.read(BACKUP_SYMLINK_MAX_BYTES + 1)
    if len(value) > BACKUP_SYMLINK_MAX_BYTES:
        raise ValueError("backup symlink target is too large")
    result = (len(value), hashlib.sha256(value).hexdigest())
    parent_descriptor = ledger.open_directory(parent, create=True)
    try:
        with _blocked_sigterm():
            os.symlink(
                value, os.fsencode(name), dir_fd=parent_descriptor)
            try:
                named = os.stat(
                    name, dir_fd=parent_descriptor, follow_symlinks=False)
            except BaseException:
                # A symlink has no safely openable descriptor. Until the first
                # no-follow stat succeeds, adopting the current name's inode
                # could delete a user replacement installed in the gap.
                raise
            if (not stat.S_ISLNK(named.st_mode)
                    or named.st_dev != ledger.device):
                raise ValueError("restore output is not a symlink")
            identity = _stat_identity(named)
            try:
                ledger.record_owned(
                    parent, name, "symlink", identity,
                    entry["size"], entry["sha256"])
            except BaseException:
                _rollback_new_entry_at(
                    parent_descriptor, name, identity, directory=False)
                raise
        current = os.readlink(
            os.fsencode(name), dir_fd=parent_descriptor)
        named_after = os.stat(
            name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (current != value
                or _stat_identity(named_after) != identity
                or not stat.S_ISLNK(named_after.st_mode)):
            raise ValueError("restored symlink changed during restore")
        return result
    finally:
        os.close(parent_descriptor)


def _restore_live_store_roots() -> tuple[Path, ...]:
    """Provider-owned roots where restored copies must never be written."""
    home = Path.home().expanduser().absolute()
    try:
        home = home.resolve(strict=True)
    except OSError:
        # The lexical roots still catch the ordinary HOME spelling. Any
        # existing symlink spelling is also considered below when possible.
        pass
    return (
        home / ".claude",
        home / ".codex",
        _claude_desktop_root(home),
    )


def _restore_path_key(path: Path) -> str:
    """macOS store spelling key; its default volumes ignore ASCII case."""
    return os.path.normpath(str(path)).casefold()


def _restore_spelling_is_under(path: Path, root: Path) -> bool:
    path_key = _restore_path_key(path)
    root_key = _restore_path_key(root).rstrip("/") or "/"
    return (path_key == root_key
            or (root_key == "/" and path_key.startswith("/"))
            or path_key.startswith(root_key + "/"))


def _restore_directory_identity(path: Path) -> Optional[tuple[int, int]]:
    try:
        descriptor = _open_directory_nofollow(path)
    except OSError:
        return None
    try:
        info = os.fstat(descriptor)
        return _stat_identity(info) if stat.S_ISDIR(info.st_mode) else None
    finally:
        os.close(descriptor)


def _restore_ancestor_identities(path: Path) -> set[tuple[int, int]]:
    identities: set[tuple[int, int]] = set()
    current = path
    while True:
        identity = _restore_directory_identity(current)
        if identity is not None:
            identities.add(identity)
        if current.parent == current:
            break
        current = current.parent
    return identities


def _reject_live_restore_destination(destination: Path) -> None:
    """Keep a verified copy from becoming live provider state by placement."""
    destination_candidates = [destination]
    try:
        os.lstat(destination)
    except FileNotFoundError:
        pass
    except OSError:
        # The restore ledger will reject any existing/unreadable leaf without
        # following it. There is no safely resolved alias to compare here.
        pass
    else:
        try:
            resolved_destination = destination.resolve(strict=True)
        except OSError:
            resolved_destination = None
        if (resolved_destination is not None
                and resolved_destination not in destination_candidates):
            destination_candidates.append(resolved_destination)

    root_candidates: list[Path] = []
    root_identities: set[tuple[int, int]] = set()
    for root in _restore_live_store_roots():
        candidate = root.expanduser().absolute()
        root_candidates.append(candidate)
        try:
            resolved = root.resolve(strict=False)
        except OSError:
            resolved = None
        if resolved is not None and resolved not in root_candidates:
            root_candidates.append(resolved)
        for root_path in (candidate, resolved):
            if root_path is None:
                continue
            identity = _restore_directory_identity(root_path)
            if identity is not None:
                root_identities.add(identity)

    spelling_match = any(
        _restore_spelling_is_under(path, root)
        for path in destination_candidates
        for root in root_candidates
    )
    # Identity catches aliases whose spelling bears no resemblance to the
    # provider root. Case folding catches `.CLAUDE` before a not-yet-existing
    # leaf has an inode, which is required on default case-insensitive APFS.
    identity_match = bool(root_identities.intersection(
        identity
        for path in destination_candidates
        for identity in _restore_ancestor_identities(path)
    ))
    if spelling_match or identity_match:
        raise ValueError(
            "restore destination must be outside live AI session stores")


def restore_session_backup(archive: Path, destination: Path) -> dict:
    archive = archive.expanduser().absolute()
    parent = destination.expanduser().absolute().parent.resolve(strict=True)
    destination_name = _validated_leaf_name(destination.name)
    destination = parent / destination_name
    _reject_live_restore_destination(destination)
    parent_descriptor = _open_directory_nofollow(parent)
    try:
        ledger = _RestoreLedger(
            parent, parent_descriptor, destination_name)
    finally:
        os.close(parent_descriptor)
    # Validate all entries before creating anything. Keep the same ZIP open
    # for verification and extraction; do not reopen a path another process
    # could swap after validation.
    state = {"completed": False}

    def cleanup() -> None:
        if not state["completed"]:
            ledger.cleanup()

    previous_sigterm = _install_sigterm_cleanup(cleanup)
    try:
        with _open_backup_bundle(archive) as bundle:
            manifest = _backup_verify_open(bundle)
            ledger.create_root()
            # A link is never allowed to become a parent of a later output.
            # Extract every regular file first, then create leaf links only.
            ordered = sorted(
                manifest["files"],
                key=lambda entry: entry.get("kind") == "symlink",
            )
            for entry in ordered:
                result = (
                    _restore_symlink(bundle, entry, ledger)
                    if entry.get("kind") == "symlink"
                    else _restore_regular(bundle, entry, ledger)
                )
                if result != (entry["size"], entry["sha256"]):
                    raise ValueError("backup changed during restore")
            ledger.validate_all()
            result = _backup_result(archive, manifest, destination)
        # The archive context validates its held inode on exit. Publish a
        # success state only after that final validation has completed.
        state["completed"] = True
        return result
    finally:
        with _blocked_sigterm():
            try:
                cleanup()
            finally:
                ledger.close()
                _restore_sigterm_handler(previous_sigterm)

SEARCH_DEFAULT_LIMIT = 200
SEARCH_MATCHES_PER_SESSION = 3
SEARCH_SNIPPET_CHARS = 240
SEARCH_DEFAULT_BUDGET_SECONDS = 60.0


def build_search(query: str, home: Path, *, raw: bool = False,
                 limit: int = SEARCH_DEFAULT_LIMIT,
                 budget_seconds: float = SEARCH_DEFAULT_BUDGET_SECONDS) -> dict:
    """Find a phrase across every session on the machine.

    The one thing the owner kept leaving this app to do. Modore could
    already list 7,000 conversations and open any one by name, and had no
    way to answer "which of these was the one where I fixed this before" --
    so the answer came from `rg` in a terminal instead.

    A deliberate content read: the caller names what to look for, nothing
    is discovered on the app's own initiative, snippets are masked by
    default, and nothing here reaches a verdict. `report` stays
    metadata-only; this runs only when a person types a query. Deep bind's
    separate derived-evidence contract is documented at module level.

    Coverage is part of the answer, not a footnote. "No results" and "I
    could not finish looking" are different facts, and a search that
    quietly stops at a time budget while reporting nothing found is the
    same collapse this codebase keeps having to undo.
    """
    needle = " ".join(query.split()).casefold()
    if not needle:
        return {"query": query, "matches": [], "scannedSessions": 0,
                "totalSessions": 0, "unreadableSessions": 0,
                "coverage": "complete", "truncatedReason": None,
                "definitive": False, "evidenceKind": "conversation_mention",
                "masked": not raw}

    session_index = build_sessions(home, limit=0)
    sessions = session_index["sessions"]
    discovery_complete = session_index["coverage"]["complete"] is True
    started = time.monotonic()
    matches: list[dict] = []
    scanned = unreadable = 0
    truncated_reason: Optional[str] = None

    for session in sessions:
        if len(matches) >= limit > 0:
            truncated_reason = "limit"
            break
        if time.monotonic() - started > budget_seconds:
            truncated_reason = "time"
            break
        source = Path(session["source"])
        found, ok = _search_one_session(
            source, needle, raw=raw, home=home)
        scanned += 1
        if not ok:
            unreadable += 1
            continue
        for hit in found:
            matches.append({**hit, "tool": session["tool"],
                            "source": session["source"],
                            "workspace": session["workspace"],
                            "lastActive": session["lastActive"]})

    swept = (truncated_reason is None and scanned == len(sessions)
             and discovery_complete)
    if truncated_reason is None and not discovery_complete:
        truncated_reason = "discovery"
    return {
        "query": query,
        # Newest first: the recent time you solved this is the one worth
        # reading, and the older ones are what "see all" is for.
        "matches": sorted(matches, key=lambda m: m["lastActive"], reverse=True)[:limit or None],
        "scannedSessions": scanned,
        "totalSessions": len(sessions),
        "unreadableSessions": unreadable,
        # Did the sweep reach every session it knew about.
        "coverage": "complete" if swept else "truncated",
        "truncatedReason": truncated_reason,
        # Whether "no match" may be stated as a fact.
        #
        # Decided here rather than by each caller, because this is the
        # exact place `unknown` turns into `none` if anybody gets it
        # wrong: a sweep that visited every session but could not open 59
        # of them is a finished sweep and is not grounds for telling
        # someone the phrase never appears. The two failures are separate
        # -- stopping early, and being unable to read -- and either one
        # is enough to withhold the conclusion.
        "definitive": swept and unreadable == 0,
        # What kind of evidence a hit is. A phrase in a conversation is a
        # mention -- somebody said it. That it was ever run is a
        # different claim needing a different source, and collapsing the
        # two is how "81 occurrences" becomes "ran 81 times".
        "evidenceKind": "conversation_mention",
        "masked": not raw,
    }


def _search_probes(needle: str) -> tuple[tuple[str, ...], ...]:
    """Per-word alternatives a file must contain before it is worth decoding.

    One group per word in the phrase, and every group has to appear
    somewhere in the file. If the phrase is present then each of its
    words is, so requiring all of them cannot lose a match -- and it is
    far more selective than probing on a single word. Probing on the
    longest word alone picked "cache" out of "npm cache clean", which
    occurs in nearly every transcript, so nearly every session got fully
    decoded: 63s against 22s for the same corpus.

    Each group also carries the JSON-escaped spelling. A store written
    with `ensure_ascii` holds Korean as `\uc6a9\ub7c9`, where the literal
    word never appears -- without this the search is silently useless for
    most of what is on this machine.
    """
    groups: list[tuple[str, ...]] = []
    for word in needle.split() or [needle]:
        escaped = json.dumps(word, ensure_ascii=True)[1:-1].casefold()
        groups.append((word, escaped) if escaped != word else (word,))
    return tuple(groups)


def _file_might_contain_handle(
        handle, probes: tuple[tuple[str, ...], ...]) -> bool:
    if not probes:
        return False
    outstanding = set(range(len(probes)))
    for line in handle:
        folded = line.casefold()
        for position in tuple(outstanding):
            if any(probe in folded for probe in probes[position]):
                outstanding.discard(position)
        if not outstanding:
            return True
    return False


def _file_might_contain(source: Path,
                        probes: tuple[tuple[str, ...], ...]) -> tuple[bool, bool]:
    """`(worth_parsing, readable)` from a raw byte scan of the file.

    The cheap half of the search: a necessary condition, checked without
    decoding anything. Stops as soon as every word has been seen, so a
    file that matches early costs almost nothing.
    """
    if not probes:
        return (False, True)
    try:
        with source.open("r", encoding="utf-8", errors="replace") as handle:
            return (_file_might_contain_handle(handle, probes), True)
    except OSError:
        return (False, False)


def _search_one_session(source: Path, needle: str, *,
                        raw: bool, home: Optional[Path] = None
                        ) -> tuple[list[dict], bool]:
    """Matching turns in one transcript, and whether it could be read.

    Reads through `visible_turns`, so a hit is something a person could
    have seen in the viewer: Codex's doubled replies are collapsed and
    the harness's own instructions are not searchable content.
    """
    desktop_descriptor, _, desktop_status = _open_claude_desktop_primary(
        source, home)
    if desktop_status != "not-desktop":
        if desktop_status != "ok" or desktop_descriptor is None:
            return ([], False)
        try:
            before = os.fstat(desktop_descriptor)
            probes = _search_probes(needle)
            with os.fdopen(os.dup(desktop_descriptor), "r", encoding="utf-8",
                           errors="replace") as handle:
                worth_parsing = _file_might_contain_handle(handle, probes)
            if not worth_parsing:
                return ([], _stat_signature(before) == _stat_signature(
                    os.fstat(desktop_descriptor)))
            os.lseek(desktop_descriptor, 0, os.SEEK_SET)
            with os.fdopen(os.dup(desktop_descriptor), "r", encoding="utf-8",
                           errors="replace") as handle:
                turns, decoded_any = _read_jsonl_turns(handle)
            after = os.fstat(desktop_descriptor)
            if (_stat_signature(before) != _stat_signature(after)
                    or (not decoded_any and before.st_size > 0)):
                return ([], False)
            turns = _canonical_visible_turns(turns)
        except OSError:
            return ([], False)
        finally:
            os.close(desktop_descriptor)
    else:
        probes = _search_probes(needle)
        worth_parsing, readable = _file_might_contain(source, probes)
        if not readable:
            return ([], False)
        if not worth_parsing:
            return ([], True)
        turns, status = visible_turns(source, home)
        if status != "ok":
            return ([], False)

    mask_home = home or Path.home()

    hits: list[dict] = []
    for position, turn in enumerate(turns):
        # Confirm against the normalised turn, not the raw bytes: the
        # query had its whitespace collapsed and the transcript did not.
        if needle not in " ".join(turn.text.split()).casefold():
            continue
        hits.append(_search_hit(
            position, turn, needle, raw=raw, home=mask_home))
        if len(hits) >= SEARCH_MATCHES_PER_SESSION:
            break
    return (hits, True)


def _search_hit(position: int, turn: VisibleTurn, needle: str, *,
                raw: bool, home: Path, include_identity: bool = False) -> dict:
    """One match, as a window around the phrase rather than a whole turn.

    A turn can be thousands of characters; what the reader needs is the
    sentence the phrase sits in. Masking is applied after the window is
    cut so the snippet a person sees is the snippet that was masked.
    """
    flat = " ".join(turn.text.split())
    where = flat.casefold().find(needle)
    if where < 0:
        where = 0
    half = max(0, (SEARCH_SNIPPET_CHARS - len(needle)) // 2)
    start = max(0, where - half)
    end = min(len(flat), where + len(needle) + half)
    snippet = flat[start:end]
    if start > 0:
        snippet = "\u2026" + snippet
    if end < len(flat):
        snippet = snippet + "\u2026"
    hit = {
        "index": position,
        "role": turn.role,
        "isUser": _is_user_role(turn.role),
        "snippet": snippet if raw else mask_text(snippet, home),
        "at": turn.at,
        "eventId": turn.event_id,
    }
    if include_identity:
        hit["_identity"] = hashlib.sha256(
            _wire_text(f"{turn.role.casefold()}\0{flat}").encode("utf-8")
        ).hexdigest()
    return hit


# The only record types that can carry a command or its outcome. Checked as
# raw substrings before anything is decoded.
PROVIDER_TOOL_MARKERS = (
    '"tool_use"', '"tool_result"', '"function_call"',
    '"function_call_output"', '"local_shell_call"',
)

# Evidence costs about twice a search, and the reason is structural
# rather than fixable: a search stops reading a file the moment it has
# seen every word, while an execution can be on any line, so a file that
# matches must be read to the end. Measured on this machine's 6.0 GB of
# transcripts: 33s to search, 59s to gather evidence. The budget is set
# above that so the common case reports complete coverage instead of
# truncating just short of the finish.
EVIDENCE_DEFAULT_BUDGET_SECONDS = 180.0

EVIDENCE_KINDS = (
    "conversation_mention",
    "provider_tool_invocation",
    "modore_cleanup_receipt",
    "filesystem_observation",
)


def _provider_invocations(record: dict, needle: str, *, raw: bool,
                          home: Path) -> list[dict]:
    """Shell invocations in one provider record, before outcome correlation."""
    invocations: list[dict] = []
    message = record.get("message")
    if isinstance(message, dict):
        for part in message.get("content") or []:
            if not isinstance(part, dict) or part.get("type") != "tool_use":
                continue
            if str(part.get("name", "")).lower() not in ("bash", "shell"):
                continue
            command = (part.get("input") or {}).get("command")
            if isinstance(command, str):
                invocations.append({
                    "callId": str(part.get("id") or ""),
                    "command": command,
                    "at": str(record.get("timestamp") or ""),
                    "inlineStatus": None,
                })

    payload = record.get("payload") if isinstance(record.get("payload"), dict) else record
    if isinstance(payload, dict) and payload.get("type") in (
        "function_call", "local_shell_call"
    ):
        arguments = payload.get("arguments")
        if isinstance(arguments, str):
            try:
                arguments = json.loads(arguments)
            except JSON_PARSE_ERRORS:
                arguments = None
        if not isinstance(arguments, dict):
            action = payload.get("action")
            arguments = action if isinstance(action, dict) else payload
        if isinstance(arguments, dict):
            command = arguments.get("cmd") or arguments.get("command")
            if isinstance(command, list):
                command = " ".join(str(part) for part in command)
            if isinstance(command, str):
                invocations.append({
                    "callId": str(payload.get("call_id") or payload.get("id") or ""),
                    "command": command,
                    "at": str(record.get("timestamp") or ""),
                    "inlineStatus": payload.get("status"),
                })

    matched: list[dict] = []
    for invocation in invocations:
        flat = " ".join(invocation["command"].split())
        if needle not in flat.casefold():
            continue
        matched.append({
            "kind": "provider_tool_invocation",
            # `rg -e 'npm cache clean'` is a search, not that cleanup
            # command. Text alone cannot distinguish intent, so the
            # reader sees the complete provider call.
            "command": flat if raw else mask_text(flat, home),
            "at": invocation["at"],
            "callId": invocation["callId"],
            "status": _inline_invocation_status(invocation["inlineStatus"]),
            "_identity": hashlib.sha256(
                _wire_text(flat).encode("utf-8")).hexdigest(),
        })
    return matched


_DENIAL_RE = re.compile(
    r"permission|not permitted|denied|rejected|cancelled|canceled|approval",
    re.IGNORECASE,
)
_SHELL_EXIT_RE = re.compile(
    r"(?:Process exited with code|Exit code)\s*:?\s*(-?\d+)", re.IGNORECASE
)


def _inline_invocation_status(value: Any) -> Optional[str]:
    status = str(value or "").casefold()
    if status in ("completed", "complete", "success", "succeeded"):
        return "completed"
    if status in ("failed", "error"):
        return "failed"
    if status in ("denied", "rejected", "cancelled", "canceled"):
        return "denied"
    return None


def _structured_exit_code(value: Any) -> Optional[int]:
    if isinstance(value, bool):
        return None
    if isinstance(value, dict):
        exit_code = value.get("exit_code", value.get("exitCode"))
        if isinstance(exit_code, int) and not isinstance(exit_code, bool):
            return exit_code
        for nested in value.values():
            found = _structured_exit_code(nested)
            if found is not None:
                return found
    elif isinstance(value, list):
        for nested in value:
            found = _structured_exit_code(nested)
            if found is not None:
                return found
    elif isinstance(value, str) and value.lstrip().startswith(("{", "[")):
        try:
            decoded = json.loads(value)
        except JSON_PARSE_ERRORS:
            return None
        return _structured_exit_code(decoded)
    return None


def _provider_outcomes(record: dict) -> list[tuple[str, str]]:
    """Call outcomes carried by one provider record, keyed for correlation."""
    outcomes: list[tuple[str, str]] = []
    message = record.get("message")
    if isinstance(message, dict):
        for part in message.get("content") or []:
            if not isinstance(part, dict) or part.get("type") != "tool_result":
                continue
            call_id = str(part.get("tool_use_id") or "")
            if not call_id:
                continue
            content = part.get("content")
            rendered = content if isinstance(content, str) else json.dumps(
                content, ensure_ascii=False)
            exit_match = _SHELL_EXIT_RE.search(rendered)
            if record.get("toolDenialKind"):
                status = "denied"
            elif exit_match:
                exit_code = int(exit_match.group(1))
                status = ("completed" if exit_code == 0 else
                          "denied" if _DENIAL_RE.search(rendered) else "failed")
            elif part.get("is_error") is True:
                denied = (bool(record.get("toolDenialKind"))
                          or bool(_DENIAL_RE.search(rendered)))
                status = "denied" if denied else "failed"
            else:
                status = "completed"
            outcomes.append((call_id, status))

    payload = record.get("payload") if isinstance(record.get("payload"), dict) else record
    if isinstance(payload, dict) and payload.get("type") == "function_call_output":
        call_id = str(payload.get("call_id") or "")
        if call_id:
            output = payload.get("output")
            rendered = output if isinstance(output, str) else json.dumps(
                output, ensure_ascii=False)
            structured_exit = _structured_exit_code(output)
            exit_match = _SHELL_EXIT_RE.search(rendered)
            exit_code = structured_exit if structured_exit is not None else (
                int(exit_match.group(1)) if exit_match else None
            )
            if exit_code is not None:
                status = ("completed" if exit_code == 0 else
                          "denied" if _DENIAL_RE.search(rendered) else "failed")
            elif _DENIAL_RE.search(rendered):
                status = "denied"
            else:
                status = "unknown"
            outcomes.append((call_id, status))
    return outcomes


def _session_evidence(source: Path, needle: str, *,
                      raw: bool, home: Optional[Path] = None
                      ) -> tuple[list[dict], list[dict], bool]:
    """`(mentions, invocations, readable)` for one session, in one read.

    One pass, not two. Invocation results can be on later lines, so the
    scan cannot stop at the call record -- but re-reading the
    file afterwards to find the mentions doubled the wall clock on this
    machine's corpus. The word test and invocation correlation share
    the single walk, and the decode into turns happens only if the walk
    saw every word.
    """
    desktop_descriptor, _, desktop_status = _open_claude_desktop_primary(
        source, home)
    if desktop_status != "not-desktop":
        if desktop_status != "ok" or desktop_descriptor is None:
            return ([], [], False)
    mask_home = home or Path.home()
    probes = _search_probes(needle)
    if not probes:
        if desktop_descriptor is not None:
            os.close(desktop_descriptor)
        return ([], [], True)
    outstanding = set(range(len(probes)))
    invocations: list[dict] = []
    outcomes: dict[str, str] = {}
    raw_turns: list[VisibleTurn] = []

    def scan(handle) -> None:
        for line in handle:
            folded = line.casefold()
            if outstanding:
                for position in tuple(outstanding):
                    if any(probe in folded for probe in probes[position]):
                        outstanding.discard(position)
            try:
                record = json.loads(line)
            except JSON_PARSE_ERRORS:
                continue
            if not isinstance(record, dict):
                continue
            turn = _extract_turn(record)
            if turn is not None:
                raw_turns.append(turn)
            if not any(marker in folded for marker in PROVIDER_TOOL_MARKERS):
                continue
            for call_id, status in _provider_outcomes(record):
                outcomes[call_id] = status
            if (len(invocations) < SEARCH_MATCHES_PER_SESSION
                    and all(any(probe in folded for probe in group)
                            for group in probes)):
                invocations.extend(_provider_invocations(
                    record, needle, raw=raw, home=mask_home))

    try:
        if desktop_descriptor is not None:
            before = os.fstat(desktop_descriptor)
            with os.fdopen(os.dup(desktop_descriptor), "r", encoding="utf-8",
                           errors="replace") as handle:
                scan(handle)
            if _stat_signature(before) != _stat_signature(
                    os.fstat(desktop_descriptor)):
                return ([], [], False)
        else:
            with source.open("r", encoding="utf-8", errors="replace") as handle:
                scan(handle)
    except OSError:
        return ([], [], False)
    finally:
        if desktop_descriptor is not None:
            os.close(desktop_descriptor)

    for invocation in invocations:
        call_id = invocation.get("callId", "")
        invocation["status"] = (
            outcomes.get(call_id)
            or invocation.get("status")
            or ("requested" if call_id else "unknown")
        )

    if outstanding:
        return ([], [], True)

    turns = _canonical_visible_turns(raw_turns)
    mentions: list[dict] = []
    for position, turn in enumerate(turns):
        if needle not in " ".join(turn.text.split()).casefold():
            continue
        mentions.append(_search_hit(
            position, turn, needle, raw=raw, home=mask_home,
            include_identity=True
        ))
        if len(mentions) >= SEARCH_MATCHES_PER_SESSION:
            break
    return (mentions, invocations, True)


def read_cleanup_receipts(home: Path, *, limit: int = 50) -> list[dict]:
    """Modore action receipts, including blocked and partial outcomes.

    A receipt is stronger provenance than a conversation mention, but it
    is not synonymous with deletion: the cleanup harness also writes a
    receipt when it blocks before moving anything. Status and measured
    deltas therefore travel with the record instead of being promoted to
    an unconditional execution claim.
    """
    directory = (home / "Library" / "Application Support" / "Modore"
                 / "cleanup-receipts")
    if not directory.is_dir():
        return []
    receipts: list[dict] = []
    for path in sorted(directory.glob("*.tsv"), reverse=True)[:limit]:
        fields: dict[str, str] = {}
        try:
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                key, _, value = line.partition("\t")
                if key and key not in fields:
                    fields[key] = value
        except OSError:
            continue
        if not fields.get("timestamp"):
            continue
        receipts.append({
            "kind": "modore_cleanup_receipt",
            "at": fields.get("timestamp", ""),
            "recipeId": fields.get("recipeId", ""),
            "label": fields.get("label", ""),
            "status": fields.get("status", ""),
            "estimatedKB": int(fields["estimatedKB"])
                           if fields.get("estimatedKB", "").isdigit() else None,
            "reclaimedKB": int(fields["reclaimedKB"])
                         if fields.get("reclaimedKB", "").isdigit() else None,
            "physicalDeltaKB": int(fields["physicalDeltaKB"])
                             if fields.get("physicalDeltaKB", "").isdigit() else None,
        })
    return receipts


def read_storage_observations(home: Path, *, limit: int = 60) -> list[dict]:
    """Free space as it was actually measured, over time.

    Never matched against the query, and never joined to anything above.
    A cache deleted at 14:02 and space appearing at 14:03 is a sequence,
    not a proof, and this file is the only honest thing to show for it --
    the numbers, with their times, and no arrow drawn between them.
    """
    samples = (home / "Library" / "Application Support" / "Modore"
               / "storage-samples.tsv")
    if not samples.is_file():
        return []
    out: list[dict] = []
    try:
        lines = samples.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    for line in lines[-limit:]:
        parts = line.split("\t")
        if len(parts) < 4 or not parts[1].isdigit():
            continue
        out.append({
            "kind": "filesystem_observation",
            "at": parts[0],
            "freeKB": int(parts[1]),
            "dropKB": int(parts[2]) if parts[2].isdigit() else 0,
            "status": parts[3],
        })
    return out


def build_evidence(query: str, home: Path, *, raw: bool = False,
                   limit: int = SEARCH_DEFAULT_LIMIT,
                   budget_seconds: float = EVIDENCE_DEFAULT_BUDGET_SECONDS) -> dict:
    """How this machine answered a question like this before.

    Four kinds of evidence, kept in four lists and never summed. Somebody
    saying "npm cache clean" is not the same claim as a provider recording
    a tool request or result. A completed Modore receipt is different from
    a blocked receipt, and neither proves why free space later changed.
    Every one is worth showing at its own strength, so the caller gets
    labelled records rather than a merged count that means nothing.

    Mentions and provider invocations answer the query. Receipts and
    observations are query-independent local context and stay in their
    own lists so a consumer cannot present them as search matches.
    """
    needle = " ".join(query.split()).casefold()
    session_index = build_sessions(home, limit=0)
    sessions = session_index["sessions"] if needle else []
    discovery_complete = session_index["coverage"]["complete"] is True
    started = time.monotonic()
    mentions: list[dict] = []
    invocations: list[dict] = []
    mention_ids: set[tuple] = set()
    invocation_ids: dict[tuple, int] = {}
    scanned = unreadable = 0
    truncated_reason: Optional[str] = None

    for session in sessions:
        if len(mentions) + len(invocations) >= limit > 0:
            truncated_reason = "limit"
            break
        if time.monotonic() - started > budget_seconds:
            truncated_reason = "time"
            break
        found_mentions, found_invocations, ok = _session_evidence(
            Path(session["source"]), needle, raw=raw, home=home)
        scanned += 1
        if not ok:
            unreadable += 1
            continue
        context = {"tool": session["tool"], "source": session["source"],
                   "workspace": session["workspace"],
                   "lastActive": session["lastActive"],
                   # The display string is local time while storage-watch
                   # observations are UTC ISO-8601. Carry the source epoch so
                   # consumers never have to compare those two spellings as
                   # strings or guess which timezone the first one used.
                   "lastActiveEpoch": session["lastActiveEpoch"]}
        for hit in found_mentions:
            identity = (
                "event", session["tool"], hit["eventId"]
            ) if hit.get("eventId") else (
                "fallback", session["tool"], hit.get("at") or "",
                hit["_identity"],
            )
            if identity in mention_ids:
                continue
            mention_ids.add(identity)
            hit = {key: value for key, value in hit.items() if key != "_identity"}
            mentions.append({**hit, "kind": "conversation_mention", **context})
        for hit in found_invocations:
            identity = (
                "call", session["tool"], hit["callId"]
            ) if hit.get("callId") else (
                "fallback", session["tool"], hit.get("at") or "",
                hit["_identity"],
            )
            hit = {key: value for key, value in hit.items() if key != "_identity"}
            candidate = {**hit, **context}
            if identity in invocation_ids:
                existing_index = invocation_ids[identity]
                strength = {"unknown": 0, "requested": 1,
                            "completed": 2, "failed": 2, "denied": 2}
                if strength.get(candidate["status"], 0) > strength.get(
                        invocations[existing_index]["status"], 0):
                    invocations[existing_index] = candidate
                continue
            invocation_ids[identity] = len(invocations)
            invocations.append(candidate)

    swept = (bool(needle) and truncated_reason is None
             and scanned == len(sessions) and discovery_complete)
    if needle and truncated_reason is None and not discovery_complete:
        truncated_reason = "discovery"
    return {
        "query": query,
        "conversationMentions": sorted(
            mentions, key=lambda m: (bool(m.get("at")), m.get("at") or ""), reverse=True),
        "providerToolInvocations": sorted(
            invocations, key=lambda m: (bool(m.get("at")), m.get("at") or ""), reverse=True),
        "modoreCleanupReceipts": read_cleanup_receipts(home),
        "filesystemObservations": read_storage_observations(home),
        "scannedSessions": scanned,
        "totalSessions": len(sessions),
        "unreadableSessions": unreadable,
        "coverage": "complete" if swept else "truncated",
        "truncatedReason": truncated_reason,
        # Whether the absence of matching mentions/invocations may be stated.
        "definitive": swept and unreadable == 0,
        "masked": not raw,
    }


def build_titles_many(sources: list[str], home: Path, *,
                      raw: bool = False) -> dict:
    """Titles for the sessions a screen is about to show, in one pass.

    The per-session command is right for one session and wrong for a
    list: a screen showing thirty rows paid thirty process spawns for
    them, serially, which is why rows sat on "제목을 읽는 중…" long
    enough to look broken.

    Still bounded the same way `title` is -- the caller names every
    source, nothing is discovered here, and each answer is one masked
    line. A batch of explicit targets is not a bulk read of the disk.
    """
    titles = {}
    for source in sources:
        if not isinstance(source, str) or not source:
            continue
        try:
            titles[source] = build_title(Path(source), home, raw=raw)
        except OSError as exc:
            # One unreadable session must not cost the other twenty-nine
            # their titles.
            titles[source] = {"title": None, "titleSource": "error",
                              "error": str(exc)}
    return {"titles": titles}


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Judge what AI agents leave behind.")
    sub = parser.add_subparsers(dest="command")

    report = sub.add_parser("report", help="print the join/retention/worktree judgment (default)")
    report.add_argument("--json", action="store_true", help="print the full scree as JSON")
    report.add_argument("--limit", type=int, default=12, help="groups to show in the text report")
    report.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    preserve = sub.add_parser(
        "preserve", help="export ONE named session file as masked Markdown (single-session, explicit)")
    preserve.add_argument("source", type=Path,
                          help="session file path, e.g. from a report's retention.expiring[].source")
    preserve.add_argument("--out", type=Path, default=None, help="write to this file instead of stdout")
    preserve.add_argument("--raw", action="store_true",
                          help="disable masking (explicit opt-out, off by default)")
    preserve.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    backup = sub.add_parser(
        "backup", help="back up one original Claude/Codex session or Claude Desktop conversation unit")
    backup.add_argument("source", type=Path)
    backup.add_argument("--out", type=Path, required=True, help="new private ZIP outside the session store")
    backup.add_argument("--include-sensitive", action="store_true",
                        help="acknowledge that originals are neither masked nor encrypted")
    backup.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    verify_backup = sub.add_parser("backup-verify", help="verify every file in a session backup")
    verify_backup.add_argument("archive", type=Path)
    restore_backup = sub.add_parser("backup-restore", help="restore and verify into a NEW directory only")
    restore_backup.add_argument("archive", type=Path)
    restore_backup.add_argument("--out", type=Path, required=True)

    bind = sub.add_parser(
        "bind", help="list the AI sessions bound to ONE named workspace (explicit, never automatic)")
    bind.add_argument("workspace", type=Path,
                      help="workspace path to bind against; need not still exist")
    bind.add_argument("--repo-url", default=None,
                      help="remote URL, so Codex sessions can bind by the repository "
                           "identity they recorded rather than by path alone")
    bind.add_argument("--deep", action="store_true",
                      help="also scan transcript bodies for file access under the workspace "
                           "(slower; finds sessions that ran elsewhere but worked here)")
    bind.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    bind_all = sub.add_parser(
        "bind-all",
        help="bind MANY workspaces in one pass; reads a JSON array on stdin")
    bind_all.add_argument("--targets", type=Path, default=None,
                          help="read the JSON array from this file instead of stdin; "
                               "a screen's worth of absolute paths is past what a "
                               "command line should be asked to hold")
    bind_all.add_argument("--out", type=Path, default=None,
                          help="write the result here instead of stdout; the answer "
                               "grows with the machine's session count and is not "
                               "something a pipe should be asked to carry")
    bind_all.add_argument("--deep", action="store_true",
                          help="also scan transcript bodies for file access")
    bind_all.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    inspect = sub.add_parser(
        "inspect", help="one session's conversation for display (masked; never gate input)")
    inspect.add_argument("source", type=Path, help="session file path from a bind result")
    inspect.add_argument("--turns", type=int, default=INSPECT_DEFAULT_TURNS,
                         help="recent turns to include")
    inspect.add_argument("--raw", action="store_true",
                         help="disable masking (explicit opt-out, off by default)")
    inspect.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    sessions = sub.add_parser(
        "sessions", help="metadata index of every visible session, newest first (no bodies read)")
    sessions.add_argument("--limit", type=int, default=SESSIONS_DEFAULT_LIMIT,
                          help="sessions to return; 0 (the default) for all")
    sessions.add_argument("--out", type=Path, default=None,
                          help="write to this file instead of stdout")
    sessions.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    search = sub.add_parser(
        "search", help="find a phrase across all sessions (masked; explicit content read)")
    # The phrase can come from a file instead of the command line. Every
    # argv on the machine is readable by any local process, and a search
    # query is the most personal thing this tool handles -- a command
    # that promises to retain nothing should not broadcast the question.
    search.add_argument("query", nargs="?", default=None, help="phrase to look for")
    search.add_argument("--query-file", type=Path, default=None,
                        help="read the phrase from this file instead of the command line")
    search.add_argument("--limit", type=int, default=SEARCH_DEFAULT_LIMIT,
                        help="maximum matches to return")
    search.add_argument("--budget-seconds", type=float,
                        default=SEARCH_DEFAULT_BUDGET_SECONDS,
                        help="stop after this long and report truncated coverage")
    search.add_argument("--raw", action="store_true",
                        help="disable masking (explicit opt-out, off by default)")
    search.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    evidence = sub.add_parser(
        "evidence",
        help="how this machine handled a question like this before (four kinds, never merged)")
    evidence.add_argument("query", nargs="?", default=None, help="phrase to look for")
    evidence.add_argument("--query-file", type=Path, default=None,
                          help="read the phrase from this file instead of the command line")
    evidence.add_argument("--limit", type=int, default=SEARCH_DEFAULT_LIMIT,
                          help="maximum mentions plus provider invocations to return")
    evidence.add_argument("--budget-seconds", type=float,
                          default=EVIDENCE_DEFAULT_BUDGET_SECONDS,
                          help="stop after this long and report truncated coverage")
    evidence.add_argument("--raw", action="store_true",
                          help="disable masking (explicit opt-out, off by default)")
    evidence.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    titles_many = sub.add_parser(
        "titles", help="titles for MANY named sessions in one pass (display only)")
    titles_many.add_argument("--sources", type=Path, default=None,
                             help="file holding a JSON array of session paths; default stdin")
    titles_many.add_argument("--raw", action="store_true",
                             help="disable masking (explicit opt-out, off by default)")
    titles_many.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    fingerprint = sub.add_parser(
        "fingerprint", help="digest of every bindable session store, to detect drift")
    fingerprint.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    title = sub.add_parser(
        "title", help="one-line title for ONE named session (display only, never gate input)")
    title.add_argument("source", type=Path, help="session file path from a bind result")
    title.add_argument("--label", default=None,
                       help="fallback label when the session has no recognisable request")
    title.add_argument("--raw", action="store_true",
                       help="disable masking (explicit opt-out, off by default)")
    title.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    parser.add_argument("--json", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--limit", type=int, default=12, help=argparse.SUPPRESS)
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    args = parser.parse_args(argv)

    if args.command in ("backup", "backup-verify", "backup-restore"):
        try:
            if args.command == "backup":
                result = build_session_backup(args.source, args.home, args.out,
                                              include_sensitive=args.include_sensitive)
            elif args.command == "backup-verify":
                result = verify_session_backup(args.archive)
            else:
                result = restore_session_backup(args.archive, args.out)
        except (OSError, ValueError, zipfile.BadZipFile, RuntimeError, EOFError) as exc:
            _print_wire(json.dumps({"error": str(exc)}, ensure_ascii=False))
            return 1
        _print_wire(json.dumps(result, ensure_ascii=False, indent=2))
        return 0

    if args.command == "preserve":
        try:
            text = render_preserve(args.source, args.home, raw=args.raw)
        except (FileNotFoundError, ValueError) as exc:
            print(f"preserve: {exc}", file=sys.stderr)
            return 1
        if args.out:
            try:
                output = _write_preserve_output(args.out, text)
            except (OSError, ValueError) as exc:
                print(f"preserve: {exc}", file=sys.stderr)
                return 1
            _print_wire(json.dumps({
                "status": "preserved",
                "output": str(output),
                "masked": not args.raw,
            }, ensure_ascii=False))
        else:
            _print_wire(text)
        return 0

    if args.command == "bind-all":
        # stdin rather than argv: a screen can carry fifty candidates and
        # their absolute paths, which is past what a command line should
        # be asked to hold.
        try:
            raw = (args.targets.read_text(encoding="utf-8")
                   if args.targets else sys.stdin.read())
            targets = json.loads(raw)
        except JSON_FILE_ERRORS as exc:
            print(f"bind-all: {exc}", file=sys.stderr)
            return 1
        if not isinstance(targets, list):
            print("bind-all: expected a JSON array of {workspace, repoUrl}", file=sys.stderr)
            return 1
        payload = _wire_text(json.dumps(
            build_bindings_many(args.home, targets, deep=args.deep),
            ensure_ascii=False, indent=2))
        if args.out:
            try:
                args.out.parent.mkdir(parents=True, exist_ok=True)
                args.out.write_text(payload, encoding="utf-8")
            except OSError as exc:
                print(f"bind-all: {exc}", file=sys.stderr)
                return 1
            print(f"wrote {args.out}")
        else:
            _print_wire(payload)
        return 0

    if args.command == "inspect":
        try:
            payload = build_inspect(args.source, args.home, raw=args.raw,
                                    turn_limit=args.turns)
        except OSError as exc:
            print(f"inspect: {exc}", file=sys.stderr)
            return 1
        _print_wire(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    if args.command in ("search", "evidence"):
        query = args.query
        if args.query_file is not None:
            try:
                query = args.query_file.read_text(encoding="utf-8")
            except OSError as exc:
                print(f"{args.command}: {exc}", file=sys.stderr)
                return 1
        if query is None:
            print(f"{args.command}: a query is required", file=sys.stderr)
            return 2
        if args.command == "evidence":
            _print_wire(json.dumps(
                build_evidence(query, args.home, raw=args.raw, limit=args.limit,
                               budget_seconds=args.budget_seconds),
                ensure_ascii=False, indent=2))
            return 0
        # Straight to stdout. A result is a few hundred short snippets,
        # nowhere near the size that made `bind-all` write a file, and a
        # command whose contract is that it keeps nothing should not
        # leave the answer on disk to be tidied up afterwards -- a
        # `defer` does not run when the app is force quit.
        _print_wire(json.dumps(
            build_search(query, args.home, raw=args.raw, limit=args.limit,
                         budget_seconds=args.budget_seconds),
            ensure_ascii=False, indent=2))
        return 0

    if args.command == "titles":
        # stdin rather than argv, same as `bind-all`: a screen's worth of
        # absolute paths is past what a command line should hold.
        try:
            raw_text = (args.sources.read_text(encoding="utf-8")
                        if args.sources else sys.stdin.read())
            sources = json.loads(raw_text)
        except JSON_FILE_ERRORS as exc:
            print(f"titles: {exc}", file=sys.stderr)
            return 1
        if not isinstance(sources, list):
            print("titles: expected a JSON array of session paths", file=sys.stderr)
            return 1
        _print_wire(json.dumps(build_titles_many(sources, args.home, raw=args.raw),
                               ensure_ascii=False, indent=2))
        return 0

    if args.command == "sessions":
        payload = _wire_text(json.dumps(
            build_sessions(args.home, limit=args.limit),
            ensure_ascii=False, indent=2))
        # The answer goes to a file when asked: a full index is 7,205
        # entries and several megabytes here, past the runner's output
        # ceiling -- and a limit that exists to stop a runaway subprocess
        # is the wrong thing to raise for a result that is legitimately
        # large.
        if args.out:
            try:
                args.out.parent.mkdir(parents=True, exist_ok=True)
                args.out.write_text(payload, encoding="utf-8")
            except OSError as exc:
                print(f"sessions: {exc}", file=sys.stderr)
                return 1
            print(f"wrote {args.out}")
        else:
            _print_wire(payload)
        return 0

    if args.command == "fingerprint":
        _print_wire(json.dumps(
            store_fingerprint(args.home), ensure_ascii=False, indent=2))
        return 0

    if args.command == "title":
        try:
            payload = build_title(args.source, args.home, raw=args.raw,
                                  fallback_label=args.label)
        except OSError as exc:
            print(f"title: {exc}", file=sys.stderr)
            return 1
        _print_wire(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    if args.command == "bind":
        # Always JSON: the only consumer is a program deciding whether a
        # workspace may be retired, and that decision must not be parsed
        # out of a human-readable table.
        _print_wire(json.dumps(
            build_bindings(args.home, str(args.workspace),
                           repo_url=args.repo_url, deep=args.deep),
            ensure_ascii=False, indent=2))
        return 0

    scree = build_scree(args.home)
    if args.json:
        _print_wire(json.dumps(scree, ensure_ascii=False, indent=2))
    else:
        _print_wire(render_report(scree, args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
