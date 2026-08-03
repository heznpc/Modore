#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cross-tool session atlas: join local AI-agent session stores by workspace/repo.

Answers, deterministically and without any LLM: which tools (Claude Code, Codex,
Gemini CLI, VS Code forks) worked in the same workspace or repository, when, and
how much of each store belongs to workspaces that no longer exist.

Privacy contract (metadata-only):
- reads at most the first few JSONL lines per session file;
- extracts only the whitelisted metadata keys below — never message/content fields;
- writes nothing; all output goes to stdout.
"""
from __future__ import annotations

import argparse
import json
import re
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


def build_atlas(home: Path) -> dict:
    codex_records, codex_status = collect_codex(home)
    claude_records, claude_status = collect_claude(home)
    fork_records, fork_statuses = collect_vscode_forks(home)
    gemini_records, gemini_status = collect_gemini(home)
    records = codex_records + claude_records + fork_records + gemini_records
    stores = [codex_status, claude_status, gemini_status] + fork_statuses

    workspace_to_repo: dict[str, str] = {}
    for item in records:
        if item["workspace"] and item["repo_url"]:
            workspace_to_repo.setdefault(item["workspace"], item["repo_url"])

    groups: dict[str, dict] = {}
    unresolved_count = 0
    for item in records:
        workspace = item["workspace"]
        if not workspace:
            unresolved_count += 1
            continue
        repo = workspace_to_repo.get(workspace)
        key = repo if repo else f"ws:{workspace}"
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
        finished.append({
            **group,
            "workspaces": workspaces,
            "worktrees": [w for w in workspaces if "/worktrees/" in w],
            "orphan": not existing,
            "cross_tool": len(group["tools"]) > 1,
            "last_active": time.strftime("%Y-%m-%d %H:%M", time.localtime(group["last_active"])),
        })
    finished.sort(key=lambda g: (g["last_active"], g["key"]), reverse=True)
    return {
        "contract": "metadata-only; whitelisted keys; deterministic join; no content read",
        "stores": stores,
        "groups": finished,
        "unresolved_sessions": unresolved_count,
    }


def _format_size(size_bytes: int) -> str:
    if size_bytes >= 1 << 30:
        return f"{size_bytes / (1 << 30):.1f}GB"
    if size_bytes >= 1 << 20:
        return f"{size_bytes / (1 << 20):.0f}MB"
    return f"{size_bytes / 1024:.0f}KB"


def render_report(atlas: dict, limit: int) -> str:
    lines = ["크로스 도구 세션 지도 (메타데이터 전용 · 결정적 조인)"]
    store_bits = []
    for store in atlas["stores"]:
        if store["status"] == "missing":
            store_bits.append(f"{store['store']} 없음")
        else:
            note = f"+미해석 {store['unrecognized']}" if store["unrecognized"] else ""
            if store.get("subtranscripts"):
                note += f"+부속 {store['subtranscripts']}"
            store_bits.append(f"{store['store']} {store['count']}건{note}")
    lines.append("저장소: " + " · ".join(store_bits))
    groups = atlas["groups"]
    cross = sum(1 for g in groups if g["cross_tool"])
    orphan = sum(1 for g in groups if g["orphan"])
    lines.append(f"그룹 {len(groups)}개 — 교차 도구 {cross} · 고아 {orphan}"
                 f" · 미해석 세션 {atlas['unresolved_sessions']}")
    lines.append("")
    for rank, group in enumerate(groups[:limit], start=1):
        marks = []
        if group["cross_tool"]:
            marks.append("교차")
        if group["orphan"]:
            marks.append("고아")
        if group["worktrees"]:
            marks.append(f"워크트리 {len(group['worktrees'])}")
        tools = " · ".join(f"{name} {count}" for name, count in sorted(group["tools"].items()))
        label = group["key"] if group["grouped_by"] == "repo" else group["key"][3:]
        lines.append(f"{rank:2d}. [{'|'.join(marks) or '단일'}] {label}")
        lines.append(f"     {tools} | 워크스페이스 {len(group['workspaces'])}"
                     f" | {_format_size(group['size_bytes'])} | 최근 {group['last_active']}")
    return "\n".join(lines)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Join local agent session stores by workspace/repo.")
    parser.add_argument("--json", action="store_true", help="print the full atlas as JSON")
    parser.add_argument("--limit", type=int, default=12, help="groups to show in the text report")
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    atlas = build_atlas(args.home)
    if args.json:
        print(json.dumps(atlas, ensure_ascii=False, indent=2))
    else:
        print(render_report(atlas, args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
