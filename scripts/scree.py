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
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
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
            if dirty is None and unpushed is None:
                verdict = "unreadable"
            elif dirty or (unpushed or 0) > 0:
                verdict = "protected"
            else:
                verdict = "rebuildable"
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


def build_retention(records: list[dict], now_ts: float) -> dict:
    """Per-store retention judgment from session-file age distribution alone.

    A store whose oldest surviving session sits in the rolling band is judged
    "rolling" and its observed oldest age becomes the estimated window; sessions
    within EXPIRY_SOON_DAYS of that window are flagged, split by whether their
    workspace still exists (a living story about to lose its transcript versus
    an orphan whose loss likely goes unnoticed).
    """
    stores: list[dict] = []
    expiring: list[dict] = []
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
        if len(sessions) < RETENTION_MIN_SESSIONS:
            entry["mode"] = "insufficient"
        elif ROLLING_WINDOW_DAYS[0] <= oldest <= ROLLING_WINDOW_DAYS[1]:
            entry["mode"] = "rolling"
            entry["window_days"] = round(oldest)
            for session, age in zip(sessions, ages):
                days_left = round(oldest - age)
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
        "retention": build_retention(records, time.time()),
        "worktrees": collect_worktrees(home),
    }


def _format_size(size_bytes: int) -> str:
    if size_bytes >= 1 << 30:
        return f"{size_bytes / (1 << 30):.1f}GB"
    if size_bytes >= 1 << 20:
        return f"{size_bytes / (1 << 20):.0f}MB"
    return f"{size_bytes / 1024:.0f}KB"


def render_report(scree: dict, limit: int) -> str:
    lines = ["Modore scree — 에이전트가 남긴 것들의 지도 (메타데이터 전용 · 결정적 조인)"]
    store_bits = []
    for store in scree["stores"]:
        if store["status"] == "missing":
            store_bits.append(f"{store['store']} 없음")
        else:
            note = f"+미해석 {store['unrecognized']}" if store["unrecognized"] else ""
            if store.get("subtranscripts"):
                note += f"+부속 {store['subtranscripts']}"
            store_bits.append(f"{store['store']} {store['count']}건{note}")
    lines.append("저장소: " + " · ".join(store_bits))
    groups = scree["groups"]
    cross = sum(1 for g in groups if g["cross_tool"])
    orphan = sum(1 for g in groups if g["orphan"])
    lines.append(f"그룹 {len(groups)}개 — 교차 도구 {cross} · 고아 {orphan}"
                 f" · 미해석 세션 {scree['unresolved_sessions']}")
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
    retention = scree.get("retention", {})
    if retention.get("stores"):
        lines.append("")
        lines.append("보존 판정 (파일 나이 관측 기반 추정)")
        mode_label = {"rolling": "롤링", "long": "장기 보존", "insufficient": "관측 부족"}
        for store in retention["stores"]:
            bits = [mode_label.get(store["mode"], store["mode"])]
            if store["mode"] == "rolling":
                bits[0] = f"롤링 약 {store['window_days']}일"
            bits.append(f"최고 {store['oldest_days']}일")
            if store["stalled"]:
                bits.append("기록 중단 의심")
            lines.append(f"  {store['store']}: " + " · ".join(bits))
        expiring = retention.get("expiring", [])
        if expiring:
            alive = [e for e in expiring if e["story_alive"]]
            lines.append(f"  만료 임박(D-{EXPIRY_SOON_DAYS} 이내) {len(expiring)}건"
                         f" — 살아있는 워크스페이스 {len(alive)} · 고아 {len(expiring) - len(alive)}")
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
        lines.append("워크트리 앵커 판정 (git 등록부·푸시 상태, 읽기 전용)")
        lines.append(f"  총 {len(items)}개 — 보호(유일본) {counts.get('protected', 0)}"
                     f" · 재생성 가능 {counts.get('rebuildable', 0)}"
                     f" · 판독 불가 {counts.get('unreadable', 0)}"
                     f" · 미등록 {sum(1 for i in items if not i['registered'])}")
        if worktrees["registered_missing"]:
            lines.append(f"  등록부 고아(등록됐지만 디스크 소멸) {len(worktrees['registered_missing'])}건")
        for item in [i for i in items if i["verdict"] == "rebuildable"][:6]:
            lines.append(f"    재생성 가능: {item['path']} (마지막 커밋 {item['last_commit'] or '?'})")
    return "\n".join(lines)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Join local agent session stores by workspace/repo.")
    parser.add_argument("--json", action="store_true", help="print the full scree as JSON")
    parser.add_argument("--limit", type=int, default=12, help="groups to show in the text report")
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    scree = build_scree(args.home)
    if args.json:
        print(json.dumps(scree, ensure_ascii=False, indent=2))
    else:
        print(render_report(scree, args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
