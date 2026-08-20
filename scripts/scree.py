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
contract above). Both act on one session the caller names — never on
anything discovered automatically — and both mask by default:
- `scree.py preserve <source>` writes a masked Markdown export of one
  transcript, the same shape as hydroject's `export`;
- `scree.py title <source>` returns one masked line: the first user
  request that says what the session was about, for display beside a
  deletion decision. It is the smaller exception of the two and the only
  one whose output is retained anywhere, so it is capped to one short
  line and is never an input to a safety judgement.
- `scree.py bind <workspace> --deep` reads transcript bodies to find
  file-access evidence, and emits only whether such evidence exists.
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


def _decode_claude_project_dir(name: str) -> Optional[str]:
    """Best-effort decode of '-Users-ren-my-proj' by existence-guided segmentation."""
    if not name.startswith("-"):
        return None
    parts = name.lstrip("-").split("-")
    current = Path("/")
    index = 0
    while index < len(parts):
        segment = parts[index]
        cursor = index + 1
        while not (current / segment).exists() and cursor < len(parts):
            segment = f"{segment}-{parts[cursor]}"
            cursor += 1
        if not (current / segment).exists():
            return None
        current = current / segment
        index = cursor
    return str(current)


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
    """
    configured_days: dict[str, int] = {}
    if home is not None:
        claude_configured = read_claude_cleanup_period_days(home)
        if claude_configured is not None:
            configured_days["Claude"] = claude_configured
    stores: list[dict] = []
    expiring: list[dict] = []

    def flag_expiring(tool: str, sessions: list[dict], ages: list[float], window: float) -> None:
        for session, age in zip(sessions, ages):
            days_left = round(window - age)
            if days_left <= EXPIRY_SOON_DAYS:
                workspace = session["workspace"]
                expiring.append({
                    "tool": tool,
                    "workspace": workspace,
                    "source": session.get("source"),
                    "days_left": days_left,
                    "size_bytes": session["size_bytes"],
                    "story_alive": bool(workspace) and Path(workspace).exists(),
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
    expiring.sort(key=lambda e: (e["days_left"], -e["size_bytes"]))
    return {"stores": stores, "expiring": expiring}


def build_scree(home: Path) -> dict:
    codex_records, codex_status = collect_codex(home)
    claude_records, claude_status = collect_claude(home)
    fork_records, fork_statuses = collect_vscode_forks(home)
    gemini_records, gemini_status = collect_gemini(home)
    records = codex_records + claude_records + fork_records + gemini_records
    stores = [codex_status, claude_status, gemini_status] + fork_statuses

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
    needle = _canon_workspace(root).casefold()
    overlap = max(0, len(needle) - 1)
    try:
        with source.open("r", encoding="utf-8", errors="replace") as handle:
            read = 0
            carry = ""
            while True:
                chunk = handle.read(1 << 20)
                if not chunk:
                    return (False, True)
                read += len(chunk)
                folded = chunk.casefold()
                if needle in carry + folded:
                    return (True, True)
                carry = folded[-overlap:] if overlap else ""
                if read >= ceiling:
                    return (False, False)
    except OSError:
        return (False, False)


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
    complete = True
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
    return {
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
        #                not "no session touched this repo". The common
        #                case for a repo worked on from `~`.
        #   truncated -- a content scan started and stopped early. It tried
        #                deeply; it did not look completely, and a repo
        #                path can appear on the last line of a session.
        #   complete  -- every byte of every candidate transcript was read.
        #                The only value from which emptiness is a finding.
        "coverage": ("complete" if scanned_fully else "truncated") if deep else "shallow",
        # Why a deep pass came back short of `complete`, so a consumer can
        # say which gap to close rather than only that one exists.
        "coverageDetail": {
            "claude": "complete" if claude_complete else "incomplete",
            "codex": "complete" if codex_complete else "incomplete",
            "gemini": "complete" if gemini_complete else "incomplete",
            "editors": "complete" if forks_complete else "incomplete",
            "unboundStores": unbound,
        },
        "assessed": True,
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
            alive = [e for e in expiring if e["story_alive"]]
            lines.append(f"  expiring soon (within D-{EXPIRY_SOON_DAYS}) {len(expiring)}"
                         f" — alive workspaces {len(alive)} · orphaned {len(expiring) - len(alive)}")
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


def _extract_turn(line: dict) -> Optional[tuple[str, str]]:
    """Best-effort (role, text) from one Claude or Codex JSONL line."""
    message = line.get("message") if isinstance(line.get("message"), dict) else None
    payload = line.get("payload") if isinstance(line.get("payload"), dict) else None
    container = message or payload
    if not isinstance(container, dict):
        return None
    role = container.get("role") or line.get("type")
    content = container.get("content")
    if isinstance(content, str):
        return (str(role or "?"), content)
    if isinstance(content, list):
        # Gemini's items carry `text` with no `type` at all, so an item
        # that is nothing but text counts as text.
        parts = [c.get("text", "") for c in content
                 if isinstance(c, dict)
                 and (c.get("type") in TURN_TEXT_TYPES or ("text" in c and "type" not in c))]
        joined = "\n".join(p for p in parts if p)
        return (str(role or "?"), joined) if joined else None
    # Codex also emits a plain `agent_message` payload whose text is not
    # wrapped in a content list at all.
    if isinstance(container.get("message"), str) and container.get("type") == "agent_message":
        return ("assistant", container["message"])
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


def _turns_from_session(source: Path) -> list[tuple[str, str]]:
    """(role, text) for one session, whatever container the provider uses.

    Shared with `preserve` at the decoder rather than by calling it: the
    export writes an entire transcript to disk as Markdown, and a title
    needs a handful of user turns. Reusing the whole flow to get a title
    would read and render everything to throw nearly all of it away.
    """
    turns: list[tuple[str, str]] = []
    if source.suffix == ".json":
        try:
            payload = json.loads(source.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError):
            return []
        messages = payload.get("messages") if isinstance(payload, dict) else None
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
            turn = _extract_turn({"message": normalised})
            if turn:
                turns.append(turn)
        return turns
    try:
        with source.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if len(line) > MAX_LINE_BYTES:
                    continue
                try:
                    parsed = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(parsed, dict):
                    turn = _extract_turn(parsed)
                    if turn:
                        turns.append(turn)
    except OSError:
        return []
    return turns


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
