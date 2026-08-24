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
Everything above this line in the module never calls any of them.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional
from urllib.parse import unquote, urlparse

# The only keys ever copied out of a session line. Everything else is dropped
# unread so prompts, code, and command content can never reach the output.
CLAUDE_META_KEYS = ("cwd", "gitBranch", "sessionId")
CODEX_META_KEYS = ("id", "cwd")
CLAUDE_SCAN_LINES = 25
MAX_LINE_BYTES = 65536

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
    except (json.JSONDecodeError, UnicodeDecodeError):
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


def _decode_claude_project_dir(name: str) -> Optional[str]:
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
    """
    if not name.startswith("-"):
        return None
    truncated = len(name) >= CLAUDE_BUCKET_CAP
    budget = {"nodes": 4096, "listings": 64}

    def spend(kind: str) -> bool:
        budget[kind] -= 1
        return budget[kind] >= 0

    def enumerate_matches(current: Path, rest: str) -> list[Path]:
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
    if not root.is_dir():
        return records, {"store": "Claude", "status": "missing", "count": 0, "unrecognized": 0}
    unresolved = 0
    sessions = 0
    subtranscripts = 0
    for project_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        fallback = _decode_claude_project_dir(project_dir.name)
        project_workspace = fallback
        for path in sorted(project_dir.glob("*.jsonl")):
            workspace = None
            branch = None
            try:
                with path.open("r", encoding="utf-8", errors="replace") as handle:
                    for _ in range(CLAUDE_SCAN_LINES):
                        line = _read_json_line(handle)
                        if line is None:
                            break
                        if not workspace and isinstance(line.get("cwd"), str):
                            workspace = line["cwd"]
                            branch = line.get("gitBranch") if isinstance(line.get("gitBranch"), str) else None
                            break
            except OSError:
                pass
            if not workspace:
                workspace = fallback
            if not workspace:
                unresolved += 1
            elif not project_workspace:
                project_workspace = workspace
            records.append(_record("Claude", "session", path, workspace, branch=branch))
            sessions += 1
        # Nested files are per-session subagent/workflow transcripts. They are
        # never opened: their bytes and mtimes are attributed via stat() only.
        nested = [p for p in sorted(project_dir.rglob("*.jsonl")) if p.parent != project_dir]
        if nested and project_workspace:
            subtranscripts += len(nested)
            records.append({
                "tool": "Claude",
                "kind": "subtranscripts",
                "workspace": _canon_workspace(project_workspace),
                "repo_url": None,
                "branch": None,
                "size_bytes": sum(p.stat().st_size for p in nested),
                "last_active": max(p.stat().st_mtime for p in nested),
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
            except (OSError, json.JSONDecodeError):
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
    except (OSError, json.JSONDecodeError):
        return [], {"store": "Gemini", "status": "unrecognized", "count": 0, "unrecognized": 1}
    projects = data.get("projects") if isinstance(data.get("projects"), dict) else {}
    records = [_record("Gemini", "project_state", registry, workspace)
               for workspace in sorted(projects)]
    return records, {"store": "Gemini", "status": "ok", "count": len(records), "unrecognized": 0}


WORKTREE_SCAN_SKIP = {"node_modules", ".git", ".build", "build", "dist", "Pods",
                      "DerivedData", "__pycache__", ".venv", "venv", "target"}


def _git(args: list[str], cwd: Path) -> Optional[str]:
    try:
        proc = subprocess.run(["git", *args], cwd=cwd, capture_output=True,
                              text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    return proc.stdout if proc.returncode == 0 else None


def _find_worktree_containers(root: Path, max_depth: int = 5) -> list[Path]:
    found: list[Path] = []
    stack: list[tuple[Path, int]] = [(root, 0)]
    while stack:
        current, depth = stack.pop()
        candidate = current / ".claude" / "worktrees"
        if candidate.is_dir():
            found.append(candidate)
        if depth >= max_depth:
            continue
        try:
            children = list(current.iterdir())
        except OSError:
            continue
        for child in children:
            if (child.is_dir() and not child.is_symlink()
                    and not child.name.startswith(".")
                    and child.name not in WORKTREE_SCAN_SKIP):
                stack.append((child, depth + 1))
    return found


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


def collect_worktrees(home: Path) -> dict:
    """Anchor judgment for agent-created git worktrees, via read-only git queries.

    A worktree is unique work ("protected") while it is dirty or carries commits
    unreachable from every remote; only a clean, fully pushed worktree is judged
    "rebuildable". Registration in the parent repo and registry entries whose
    directory disappeared are reported as anchor breaks.
    """
    containers: list[Path] = []
    for root in (home / "IdeaProjects", home / "Documents"):
        if root.is_dir():
            containers.extend(_find_worktree_containers(root))
    items: list[dict] = []
    registered_missing: list[dict] = []
    for container in sorted(set(containers)):
        repo = container.parent.parent
        # The primary checkout itself can be stranded on a non-default branch by
        # an agent session that never opened a PR — the same unique-work risk as
        # a worktree, but invisible to worktree listing. Judge it with the same
        # protected/rebuildable rules and mark it stray_checkout.
        repo_branch_raw = _git(["symbolic-ref", "--short", "HEAD"], repo)
        repo_branch = repo_branch_raw.strip() if repo_branch_raw else None
        if repo_branch and repo_branch not in ("main", "master"):
            status = _git(["status", "--porcelain"], repo)
            unpushed_raw = _git(["rev-list", "--count", "HEAD", "--not", "--remotes"], repo)
            commit_raw = _git(["log", "-1", "--format=%ct"], repo)
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
        listed: set[str] = set()
        porcelain = _git(["worktree", "list", "--porcelain"], repo)
        for line in (porcelain or "").splitlines():
            if line.startswith("worktree "):
                listed.add(str(Path(line.split(" ", 1)[1]).resolve()))
        container_prefix = str(container.resolve()) + "/"
        for path in sorted(listed):
            if path.startswith(container_prefix) and not Path(path).exists():
                registered_missing.append({"repo": str(repo), "path": path})
        for worktree in sorted(p for p in container.iterdir() if p.is_dir()):
            status = _git(["status", "--porcelain"], worktree)
            unpushed_raw = _git(["rev-list", "--count", "HEAD", "--not", "--remotes"],
                                worktree)
            branch_raw = _git(["rev-parse", "--abbrev-ref", "HEAD"], worktree)
            commit_raw = _git(["log", "-1", "--format=%ct"], worktree)
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
                "registered": str(worktree.resolve()) in listed,
                "dirty": dirty,
                "unpushed_commits": unpushed,
                "last_commit": last_commit,
                "verdict": verdict,
                "evidence": "preview",
            }
            if verdict == "rebuildable":
                item["requires_revalidation"] = True
            items.append(item)
    items.sort(key=lambda w: (w["verdict"], w["last_commit"] or "", w["path"]))
    return {"items": items, "registered_missing": registered_missing}


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
    fork_records, fork_statuses = collect_vscode_forks(home)
    gemini_records, gemini_status = collect_gemini(home)
    return (
        codex_records + claude_records + fork_records + gemini_records,
        [codex_status, claude_status, gemini_status] + fork_statuses,
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
        except (OSError, json.JSONDecodeError):
            payload = {}
        for path in (payload.get("projects") or {}):
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
            except (OSError, json.JSONDecodeError):
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
    shared, _ = collect_all(home)
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
        sessions.append({
            "tool": item["tool"],
            "source": item["source"],
            "workspace": workspace,
            # Stated, not implied by an empty string: a session whose
            # workspace is gone and one that never recorded a workspace
            # are different things to a person deciding what to keep.
            "workspaceExists": bool(workspace) and Path(workspace).exists(),
            # Editors keep per-workspace state, not a transcript; saying
            # "대화" for both overstates what a `workspace.json` is.
            "kind": item["kind"],
            "sizeBytes": item["size_bytes"],
            "lastActive": time.strftime(
                "%Y-%m-%d %H:%M", time.localtime(item["last_active"])),
            "lastActiveEpoch": item["last_active"],
        })
    sessions.sort(key=lambda s: (-s["lastActiveEpoch"], s["source"]))
    # `total` is the count before the cap, so a caller can say what it is
    # not showing rather than presenting a truncated list as the whole.
    return {
        "total": len(sessions),
        "sessions": sessions[:limit] if limit > 0 else sessions,
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
        "worktrees": collect_worktrees(home),
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
    if "working-directory" in evidence:
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
    return path == root or path.startswith(root + "/")


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
            except (OSError, json.JSONDecodeError):
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
        except (OSError, json.JSONDecodeError):
            # Without the registry only the workspace itself can be
            # hashed, so its subdirectories and worktrees go unchecked.
            complete = False
            projects = {}
        for path in (projects.get("projects") or {}):
            if isinstance(path, str) and _under(_canon_workspace(path), workspace):
                remember(_canon_workspace(path))

    out: list[dict] = []
    for path in chats:
        try:
            payload = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError):
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
BINDABLE_STORES = {"Claude", "Codex", "Gemini"} | set(VSCODE_PROVIDER_IDS)
KNOWN_STORE_ROOTS = {
    "Claude": (".claude/projects",),
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
    for store, roots in KNOWN_STORE_ROOTS.items():
        if store in BINDABLE_STORES:
            continue
        if any((home / root).is_dir() for root in roots):
            present.append(store)
    support = home / "Library" / "Application Support"
    for label, folder in VSCODE_FORKS:
        if label in BINDABLE_STORES:
            continue
        if (support / folder).is_dir():
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
        per_workspace[workspace] = claude + codex + gemini + forks

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
    scanned_fully = (claude_complete and codex_complete and gemini_complete
                     and forks_complete and not unbound_stores)
    fingerprint = store_fingerprint(home)
    results = {}
    for workspace in workspaces:
        bindings = sorted(per_workspace[workspace],
                          key=lambda b: (b["provider"], b["sessionId"]))
        results[workspace] = _binding_result(
            workspace, repo_urls[workspace], deep, bindings, fingerprint,
            claude_complete, codex_complete, gemini_complete, forks_complete,
            unbound_stores, scanned_fully,
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


def _file_access_session_id(provider: str, path: Path) -> str:
    """The id each store's own binder would have used.

    Falling back to the filename would give the same session two
    different identities depending on which evidence found it, and the
    manifest would then record a session the provider cannot be asked
    about.
    """
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
    except (OSError, json.JSONDecodeError):
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


def store_fingerprint(home: Path) -> dict:
    """Digest over every candidate file in every bindable store.

    An assessment is a statement about a moment. Sealing hundreds of
    megabytes takes long enough for an agent to finish a turn and write a
    new session, and nothing about "these are the bound conversations"
    stays true across that. A timestamp would not catch it either -- the
    question is not "is the newest file newer" but "is this the same set
    of candidates I judged", which a rewritten or removed file changes
    just as much as an added one.

    Metadata only: paths, sizes, mtimes. Nothing here opens a file.
    """
    hasher = hashlib.sha256()
    count = 0
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
            stat = path.stat()
        except OSError:
            # A file that vanished between listing and stat is itself a
            # change, and folding its path in keeps that visible.
            hasher.update(f"{path}\0missing\n".encode("utf-8"))
            count += 1
            continue
        hasher.update(f"{path}\0{stat.st_size}\0{stat.st_mtime_ns}\n".encode("utf-8"))
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
    codex_bindings, codex_complete = bind_codex(home, workspace, repo_url, deep=deep)
    gemini_bindings, gemini_complete = bind_gemini(home, workspace, deep=deep)
    fork_bindings, forks_complete = bind_vscode_forks(home, workspace)
    bindings = claude_bindings + codex_bindings + gemini_bindings + fork_bindings
    unbound = unbound_stores_present(home)
    # Completeness is a property of the whole machine, not of the store
    # that happened to be scanned last. One unreadable rollout, one
    # unrecognised header, or one store with no binder is enough to make
    # "this workspace has no conversations" an assertion nobody checked.
    scanned_fully = (claude_complete and codex_complete and gemini_complete
                     and forks_complete and not unbound)
    bindings.sort(key=lambda b: (b["provider"], b["sessionId"]))
    return _binding_result(
        workspace, repo_url, deep, bindings, store_fingerprint(home),
        claude_complete, codex_complete, gemini_complete, forks_complete,
        unbound, scanned_fully,
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
                    claude_complete, codex_complete, gemini_complete,
                    forks_complete, unbound, scanned_fully) -> dict:
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
                for p in ("claude", "codex", "gemini", *sorted(VSCODE_PROVIDER_IDS.values()))
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
                     f" · unregistered {sum(1 for i in items if not i['registered'])}"
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
    at = _event_string(line, "timestamp", "createdAt", "created_at") \
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


def _read_session_turns(source: Path) -> tuple[list[VisibleTurn], str]:
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
    if not source.exists():
        return ([], "missing")
    turns: list[VisibleTurn] = []
    if source.suffix == ".json":
        try:
            payload = json.loads(source.read_text(encoding="utf-8-sig"))
        except OSError:
            return ([], "unreadable")
        except json.JSONDecodeError:
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

    decoded_any = False
    try:
        with source.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if len(line) > MAX_LINE_BYTES:
                    continue
                try:
                    parsed = json.loads(line)
                except json.JSONDecodeError:
                    continue
                decoded_any = True
                if isinstance(parsed, dict):
                    turn = _extract_turn(parsed)
                    if turn:
                        turns.append(turn)
    except OSError:
        return ([], "unreadable")
    # A JSONL file none of whose lines parsed is not an empty
    # conversation; it is a file this build cannot read.
    if not decoded_any and source.stat().st_size > 0:
        return ([], "unrecognized")
    return (turns, "ok")


def visible_turns(source: Path) -> tuple[list[VisibleTurn], str]:
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
    turns, status = _read_session_turns(source)
    if status != "ok":
        return ([], status)
    deduped: list[VisibleTurn] = []
    for turn in turns:
        if (deduped and deduped[-1].role == turn.role
                and deduped[-1].text == turn.text):
            # Codex emits the same reply in two adjacent record shapes.
            # Keep the richer provenance if only one spelling has it.
            previous = deduped[-1]
            deduped[-1] = VisibleTurn(
                previous.role,
                previous.text,
                previous.at or turn.at,
                previous.event_id or turn.event_id,
            )
            continue
        deduped.append(turn)
    return ([turn for turn in deduped
             if turn.role.lower() not in ("developer", "system")], "ok")


def _turns_from_session(source: Path) -> list[VisibleTurn]:
    """Turns only, for callers that already treat absence as absence.

    `title` is one: a session it cannot read gets a date-shaped fallback,
    which is honest on its own terms. `inspect` needs the status and uses
    `_read_session_turns` directly.
    """
    return visible_turns(source)[0]


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
    turns = _turns_from_session(source)
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
    if "/.claude/" in text or text.startswith(str(home / ".claude")):
        return "claude"
    if "/.codex/" in text:
        return "codex"
    if "/.gemini/" in text:
        return "gemini"
    if "workspaceStorage" in text:
        return "editor"
    return "unknown"


def _session_workspace(provider: str, source: Path) -> Optional[str]:
    """The workspace the session itself recorded, when the store keeps one."""
    try:
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
    turns, status = visible_turns(source)

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
            provider if provider in ("claude", "codex", "gemini") else "claude", source),
        "workspace": _session_workspace(provider, source),
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
    if not source.is_file():
        raise FileNotFoundError(f"no such session file: {source}")
    if source.stat().st_size > MAX_PRESERVE_BYTES:
        raise ValueError(f"refusing to export {source}: exceeds {MAX_PRESERVE_BYTES} bytes "
                         "(single-session exports are meant to be reviewed, not bulk-dumped)")
    lines = ["# Preserved session export", "",
             f"Source: `{source if raw else str(source).replace(str(home), '~')}`",
             f"Masking: {'DISABLED (--raw)' if raw else 'default-on (email/JWT/API-key/private-key/home-path)'}",
             ""]
    turns = 0
    for raw_line in source.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw_line.strip():
            continue
        try:
            parsed = json.loads(raw_line)
        except json.JSONDecodeError:
            continue
        if not isinstance(parsed, dict):
            continue
        turn = _extract_turn(parsed)
        if turn is None:
            continue
        role, text = turn
        if not raw:
            text = mask_text(text, home)
        lines.append(f"## {role}")
        lines.append("")
        lines.append(text)
        lines.append("")
        turns += 1
    if turns == 0:
        lines.append("_(no recognizable turns — file kept in its original session-store format)_")
    return "\n".join(lines)


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

    sessions = build_sessions(home, limit=0)["sessions"]
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
        found, ok = _search_one_session(source, needle, raw=raw)
        scanned += 1
        if not ok:
            unreadable += 1
            continue
        for hit in found:
            matches.append({**hit, "tool": session["tool"],
                            "source": session["source"],
                            "workspace": session["workspace"],
                            "lastActive": session["lastActive"]})

    swept = truncated_reason is None and scanned == len(sessions)
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


def _file_might_contain(source: Path,
                        probes: tuple[tuple[str, ...], ...]) -> tuple[bool, bool]:
    """`(worth_parsing, readable)` from a raw byte scan of the file.

    The cheap half of the search: a necessary condition, checked without
    decoding anything. Stops as soon as every word has been seen, so a
    file that matches early costs almost nothing.
    """
    if not probes:
        return (False, True)
    outstanding = set(range(len(probes)))
    try:
        with source.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                folded = line.casefold()
                for position in tuple(outstanding):
                    if any(probe in folded for probe in probes[position]):
                        outstanding.discard(position)
                if not outstanding:
                    return (True, True)
    except OSError:
        return (False, False)
    return (False, True)


def _search_one_session(source: Path, needle: str, *,
                        raw: bool) -> tuple[list[dict], bool]:
    """Matching turns in one transcript, and whether it could be read.

    Reads through `visible_turns`, so a hit is something a person could
    have seen in the viewer: Codex's doubled replies are collapsed and
    the harness's own instructions are not searchable content.
    """
    home = Path.home()
    probes = _search_probes(needle)
    worth_parsing, readable = _file_might_contain(source, probes)
    if not readable:
        return ([], False)
    if not worth_parsing:
        return ([], True)

    turns, status = visible_turns(source)
    if status != "ok":
        return ([], False)

    hits: list[dict] = []
    for position, turn in enumerate(turns):
        # Confirm against the normalised turn, not the raw bytes: the
        # query had its whitespace collapsed and the transcript did not.
        if needle not in " ".join(turn.text.split()).casefold():
            continue
        hits.append(_search_hit(position, turn, needle, raw=raw, home=home))
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
            f"{turn.role.casefold()}\0{flat}".encode("utf-8")
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
            except json.JSONDecodeError:
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
            "_identity": hashlib.sha256(flat.encode("utf-8")).hexdigest(),
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
        except json.JSONDecodeError:
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
                      raw: bool) -> tuple[list[dict], list[dict], bool]:
    """`(mentions, invocations, readable)` for one session, in one read.

    One pass, not two. Invocation results can be on later lines, so the
    scan cannot stop at the call record -- but re-reading the
    file afterwards to find the mentions doubled the wall clock on this
    machine's corpus. The word test and invocation correlation share
    the single walk, and the decode into turns happens only if the walk
    saw every word.
    """
    home = Path.home()
    probes = _search_probes(needle)
    if not probes:
        return ([], [], True)
    outstanding = set(range(len(probes)))
    invocations: list[dict] = []
    outcomes: dict[str, str] = {}
    try:
        with source.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                folded = line.casefold()
                if outstanding:
                    for position in tuple(outstanding):
                        if any(probe in folded for probe in probes[position]):
                            outstanding.discard(position)
                if not any(marker in folded for marker in PROVIDER_TOOL_MARKERS):
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict):
                    continue
                for call_id, status in _provider_outcomes(record):
                    outcomes[call_id] = status
                if (len(invocations) < SEARCH_MATCHES_PER_SESSION
                        and all(any(probe in folded for probe in group)
                                for group in probes)):
                    invocations.extend(_provider_invocations(
                        record, needle, raw=raw, home=home))
    except OSError:
        return ([], [], False)

    for invocation in invocations:
        call_id = invocation.get("callId", "")
        invocation["status"] = (
            outcomes.get(call_id)
            or invocation.get("status")
            or ("requested" if call_id else "unknown")
        )

    if outstanding:
        return ([], [], True)

    turns, status = visible_turns(source)
    if status != "ok":
        return ([], invocations, False)
    mentions: list[dict] = []
    for position, turn in enumerate(turns):
        if needle not in " ".join(turn.text.split()).casefold():
            continue
        mentions.append(_search_hit(
            position, turn, needle, raw=raw, home=home, include_identity=True
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
    sessions = build_sessions(home, limit=0)["sessions"] if needle else []
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
            Path(session["source"]), needle, raw=raw)
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

    swept = truncated_reason is None and scanned == len(sessions)
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

    if args.command == "preserve":
        try:
            text = render_preserve(args.source, args.home, raw=args.raw)
        except (FileNotFoundError, ValueError) as exc:
            print(f"preserve: {exc}", file=sys.stderr)
            return 1
        if args.out:
            try:
                args.out.parent.mkdir(parents=True, exist_ok=True)
                args.out.write_text(text, encoding="utf-8")
            except OSError as exc:
                print(f"preserve: {exc}", file=sys.stderr)
                return 1
            print(f"wrote {args.out}")
        else:
            print(text)
        return 0

    if args.command == "bind-all":
        # stdin rather than argv: a screen can carry fifty candidates and
        # their absolute paths, which is past what a command line should
        # be asked to hold.
        try:
            raw = (args.targets.read_text(encoding="utf-8")
                   if args.targets else sys.stdin.read())
            targets = json.loads(raw)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"bind-all: {exc}", file=sys.stderr)
            return 1
        if not isinstance(targets, list):
            print("bind-all: expected a JSON array of {workspace, repoUrl}", file=sys.stderr)
            return 1
        payload = json.dumps(
            build_bindings_many(args.home, targets, deep=args.deep),
            ensure_ascii=False, indent=2)
        if args.out:
            try:
                args.out.parent.mkdir(parents=True, exist_ok=True)
                args.out.write_text(payload, encoding="utf-8")
            except OSError as exc:
                print(f"bind-all: {exc}", file=sys.stderr)
                return 1
            print(f"wrote {args.out}")
        else:
            print(payload)
        return 0

    if args.command == "inspect":
        try:
            payload = build_inspect(args.source, args.home, raw=args.raw,
                                    turn_limit=args.turns)
        except OSError as exc:
            print(f"inspect: {exc}", file=sys.stderr)
            return 1
        print(json.dumps(payload, ensure_ascii=False, indent=2))
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
            print(json.dumps(
                build_evidence(query, args.home, raw=args.raw, limit=args.limit,
                               budget_seconds=args.budget_seconds),
                ensure_ascii=False, indent=2))
            return 0
        # Straight to stdout. A result is a few hundred short snippets,
        # nowhere near the size that made `bind-all` write a file, and a
        # command whose contract is that it keeps nothing should not
        # leave the answer on disk to be tidied up afterwards -- a
        # `defer` does not run when the app is force quit.
        print(json.dumps(
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
        except (OSError, json.JSONDecodeError) as exc:
            print(f"titles: {exc}", file=sys.stderr)
            return 1
        if not isinstance(sources, list):
            print("titles: expected a JSON array of session paths", file=sys.stderr)
            return 1
        print(json.dumps(build_titles_many(sources, args.home, raw=args.raw),
                         ensure_ascii=False, indent=2))
        return 0

    if args.command == "sessions":
        payload = json.dumps(build_sessions(args.home, limit=args.limit),
                             ensure_ascii=False, indent=2)
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
            print(payload)
        return 0

    if args.command == "fingerprint":
        print(json.dumps(store_fingerprint(args.home), ensure_ascii=False, indent=2))
        return 0

    if args.command == "title":
        try:
            payload = build_title(args.source, args.home, raw=args.raw,
                                  fallback_label=args.label)
        except OSError as exc:
            print(f"title: {exc}", file=sys.stderr)
            return 1
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    if args.command == "bind":
        # Always JSON: the only consumer is a program deciding whether a
        # workspace may be retired, and that decision must not be parsed
        # out of a human-readable table.
        print(json.dumps(
            build_bindings(args.home, str(args.workspace),
                           repo_url=args.repo_url, deep=args.deep),
            ensure_ascii=False, indent=2))
        return 0

    scree = build_scree(args.home)
    if args.json:
        print(json.dumps(scree, ensure_ascii=False, indent=2))
    else:
        print(render_report(scree, args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
