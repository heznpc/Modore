#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fileaccess, Modore's path-to-session reverse index: which sessions touched this file.

scree answers "what did the agents leave behind" per store and per workspace.
This module inverts the same evidence to the question an operator actually asks
when something changed and nobody remembers doing it: *which sessions touched
this path, how often, and when last?* Rule surfaces -- CLAUDE.md, AGENTS.md,
settings.json, anything under ~/.claude or ~/.codex -- sort first, because a
silently edited rule file is the case this view exists for.

Ported from canary's `get_file_access` / `getFileAccessAggregates`
(`lib/sessions/scan.ts`), which is being retired into a frozen paper archive.
The taxonomy of what counts as a rule surface is carried over verbatim.

Content contract (stricter than the original, and not an exception to scree's):
- transcripts are streamed and tool-use blocks are decoded, but only the tool
  NAME and the PATHS it names are retained. Assistant text, tool results, and
  tool inputs other than paths are discarded in the same pass that reads them,
  exactly as scree already decodes and discards message content;
- canary attached a 200-character excerpt of the shell command to every row.
  That excerpt is command *content*, and it is dropped here. A path extracted
  from a command is metadata about which file was touched; the command that
  touched it is not;
- nested subagent transcripts are never opened, matching scree's collector;
- writes nothing; all output goes to stdout.

Judgment limits (preview-grade evidence):
- paths inside shell commands are recovered by a heuristic regex, so a `bash`
  count both over- and under-catches: a path mentioned but not touched counts,
  and a path built from a variable does not;
- a file can have been changed by something no session records -- an editor,
  another machine, a script run outside an agent. Absence from this index is
  not evidence that no agent touched it, only that no *indexed* session did;
- tool names are recorded as the transcript spells them, so a renamed tool in a
  future client version simply stops matching the read/write sets rather than
  being reclassified.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Iterator, Optional

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    # Python isolated mode (-I, which CI and the app's runner both use)
    # intentionally omits the script directory. Import only the sibling
    # collectors from this resolved, repository-controlled directory.
    sys.path.insert(0, str(SCRIPT_DIR))

from scree import collect_claude, collect_codex, mask_text  # noqa: E402

# Ported verbatim from canary's lib/sessions/types.ts.
RULE_BASENAMES = frozenset({
    "CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", "AGENTS.override.md",
    "GEMINI.md", "copilot-instructions.md", "settings.json",
    "settings.local.json", "managed-settings.json", "config.toml",
})
RULE_DIR_MARKERS = ("/.claude/", "/.codex/", "/.cursor/", "/.github/instructions/")

READ_TOOLS = frozenset({"Read", "Glob", "Grep", "NotebookRead"})
WRITE_TOOLS = frozenset({"Write", "Edit", "MultiEdit", "NotebookEdit"})
CODEX_COMMAND_TOOLS = frozenset({"exec_command", "shell"})

# Absolute or home-relative paths inside a shell command. URLs (which contain
# "//") are excluded; the cap keeps one pathological command from dominating.
_COMMAND_PATH_RE = re.compile(r"""(?:^|[\s"'=(:])((?:~|/)[A-Za-z0-9_.@\-/]{2,})""")
_TRAILING_PUNCT_RE = re.compile(r"""[).,;:'"]+$""")
COMMAND_PATH_CAP = 8

DEFAULT_MAX_SESSIONS = 400
MAX_LINES_PER_SESSION = 40_000


def canonical_path(path: str, home: Path) -> str:
    """One row per file, whatever spelling the transcript used.

    The same file reaches this index as `/Users/x/.claude/settings.json` from a
    tool input and as `~/.claude/settings.json` from a shell command, and with
    or without a trailing slash. Aggregating on the raw string splits one file
    into several rows, which defeats the point of an inverted index -- so the
    spelling is normalised here, before counting, and masked only on the way
    out.
    """
    text = path.strip()
    if not text:
        return text
    if text == "~":
        text = str(home)
    elif text.startswith("~/"):
        text = str(home) + text[1:]
    text = os.path.normpath(text)
    return text


def is_rule_surface(path: str) -> bool:
    """A path whose silent modification is worth investigating."""
    if os.path.basename(path) in RULE_BASENAMES:
        return True
    return any(marker in path for marker in RULE_DIR_MARKERS)


def paths_in_command(command: str, cap: int = COMMAND_PATH_CAP) -> list[str]:
    found: list[str] = []
    for match in _COMMAND_PATH_RE.finditer(command):
        candidate = match.group(1)
        if not candidate or "//" in candidate:
            continue
        cleaned = _TRAILING_PUNCT_RE.sub("", candidate)
        if cleaned and cleaned not in found:
            found.append(cleaned)
        if len(found) >= cap:
            break
    return found


# ---------------------------------------------------------------------------
# Per-transcript extraction
# ---------------------------------------------------------------------------

def _claude_entries(line: dict) -> Iterator[tuple[str, str, str, str]]:
    """(op, tool, path, dedupe_key) for one Claude JSONL line.

    Claude streams one assistant message as MULTIPLE lines sharing a message
    id, each carrying a different content block, so the same tool_use can be
    read more than once in a single pass. Dedupe therefore belongs at the block
    level, keyed on the block id -- deduping on the path instead would collapse
    a genuine second read of the same file, which is exactly the repetition
    this index exists to count.
    """
    message = line.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return
    message_id = message.get("id") if isinstance(message.get("id"), str) else ""
    for index, block in enumerate(content):
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        name = block.get("name")
        payload = block.get("input")
        if not isinstance(name, str) or not isinstance(payload, dict):
            continue
        block_id = block.get("id")
        # An id-less block still needs a stable key, and the input is what makes
        # one call different from the next.
        key = block_id if isinstance(block_id, str) and block_id else (
            f"{message_id}|{index}|{name}|{json.dumps(payload, sort_keys=True, default=str)}")
        target = (payload.get("file_path") or payload.get("notebook_path")
                  or payload.get("path"))
        if name in READ_TOOLS:
            if isinstance(target, str) and target:
                yield ("read", name, target, key)
        elif name in WRITE_TOOLS:
            if isinstance(target, str) and target:
                yield ("write", name, target, key)
        elif name == "Bash":
            command = payload.get("command")
            if isinstance(command, str):
                for path in paths_in_command(command):
                    yield ("bash", name, path, f"{key}|{path}")


def _codex_entries(line: dict) -> Iterator[tuple[str, str, str, str]]:
    """(op, tool, path, dedupe_key) for one Codex JSONL line.

    Codex records shell work as function calls whose arguments are usually a
    JSON string. An unparseable argument blob yields nothing rather than a
    guess -- a wrong path in a reverse index sends the operator to the wrong
    file.
    """
    payload = line.get("payload")
    if not isinstance(payload, dict):
        return
    name = payload.get("name")
    if name not in CODEX_COMMAND_TOOLS:
        return
    raw = payload.get("arguments")
    args: dict = {}
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
        except ValueError:
            return
        if isinstance(parsed, dict):
            args = parsed
    elif isinstance(raw, dict):
        args = raw
    command_field = args.get("cmd", args.get("command"))
    if isinstance(command_field, list):
        command = " ".join(str(part) for part in command_field)
    elif command_field is None:
        command = ""
    else:
        command = str(command_field)

    seen: list[str] = paths_in_command(command) if command else []
    workdir = args.get("workdir")
    if isinstance(workdir, str) and workdir and workdir not in seen:
        seen.append(workdir)
    call_id = payload.get("call_id") or payload.get("id")
    key_base = call_id if isinstance(call_id, str) and call_id else command
    for path in seen:
        yield ("bash", str(name), path, f"{key_base}|{path}")


def scan_transcript(source: Path, tool: str) -> tuple[list[tuple[str, str, str, Optional[str]]], int]:
    """(op, tool, path, timestamp) rows for one transcript, plus a line count."""
    rows: list[tuple[str, str, str, Optional[str]]] = []
    seen_blocks: set = set()
    lines_read = 0
    extract = _claude_entries if tool == "Claude" else _codex_entries
    try:
        with source.open("r", encoding="utf-8", errors="replace") as handle:
            for raw in handle:
                if lines_read >= MAX_LINES_PER_SESSION:
                    break
                raw = raw.strip()
                if not raw:
                    continue
                lines_read += 1
                try:
                    line = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(line, dict):
                    continue
                ts = line.get("timestamp")
                if not isinstance(ts, str):
                    ts = None
                for op, tool_name, path, key in extract(line):
                    if key in seen_blocks:
                        continue
                    seen_blocks.add(key)
                    rows.append((op, tool_name, path, ts))
    except OSError:
        return rows, lines_read
    return rows, lines_read


# ---------------------------------------------------------------------------
# Inverted index
# ---------------------------------------------------------------------------

def build_index(home: Path, *, max_sessions: int = DEFAULT_MAX_SESSIONS) -> dict:
    claude_records, claude_status = collect_claude(home)
    codex_records, codex_status = collect_codex(home)

    sessions = [r for r in claude_records + codex_records if r.get("kind") == "session"]
    sessions.sort(key=lambda r: r.get("last_active") or 0, reverse=True)
    skipped = max(0, len(sessions) - max_sessions)
    sessions = sessions[:max_sessions]

    by_path: dict[str, dict] = {}
    scanned = 0
    for record in sessions:
        source = Path(record["source"])
        rows, _ = scan_transcript(source, record["tool"])
        if not rows:
            scanned += 1
            continue
        session_id = source.stem
        for op, tool_name, raw_path, ts in rows:
            path = canonical_path(raw_path, home)
            if not path:
                continue
            entry = by_path.get(path)
            if entry is None:
                entry = {
                    "path": path,
                    "rule_surface": is_rule_surface(path),
                    "reads": 0, "writes": 0, "shell": 0,
                    "tools": set(), "sessions": set(),
                    "last_ts": None,
                }
                by_path[path] = entry
            entry["reads" if op == "read" else "writes" if op == "write" else "shell"] += 1
            entry["tools"].add(tool_name)
            entry["sessions"].add(session_id)
            if ts and (entry["last_ts"] is None or ts > entry["last_ts"]):
                entry["last_ts"] = ts
        scanned += 1

    paths = []
    for entry in by_path.values():
        paths.append({
            "path": mask_text(entry["path"], home),
            "rule_surface": entry["rule_surface"],
            "reads": entry["reads"],
            "writes": entry["writes"],
            "shell": entry["shell"],
            "tools": sorted(entry["tools"]),
            "session_count": len(entry["sessions"]),
            "session_ids": sorted(entry["sessions"])[:20],
            "last_ts": entry["last_ts"],
        })
    # Rule surfaces first, then breadth of exposure, then total touches: the
    # order the contamination question is actually asked in.
    paths.sort(key=lambda p: (not p["rule_surface"], -p["session_count"],
                              -(p["reads"] + p["writes"] + p["shell"]), p["path"]))

    return {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime()),
        "stores": [claude_status, codex_status],
        "sessions_scanned": scanned,
        "sessions_skipped_by_cap": skipped,
        "path_count": len(paths),
        "rule_surface_count": sum(1 for p in paths if p["rule_surface"]),
        "paths": paths,
        "evidence": "preview",
        "requires_revalidation": True,
    }


def filter_paths(index: dict, *, query: Optional[str], rule_only: bool) -> list[dict]:
    paths = index["paths"]
    if rule_only:
        paths = [p for p in paths if p["rule_surface"]]
    if query:
        needle = query.lower()
        paths = [p for p in paths if needle in p["path"].lower()]
    return paths


def render_report(index: dict, paths: list[dict], limit: int) -> str:
    lines = ["파일 접근 역색인 (읽기 전용)", ""]
    lines.append(f"세션 {index['sessions_scanned']}개 · 경로 {index['path_count']}개 "
                 f"· 규칙 표면 {index['rule_surface_count']}개")
    if index["sessions_skipped_by_cap"]:
        lines.append(f"상한으로 건너뛴 세션 {index['sessions_skipped_by_cap']}개 "
                     "(--max-sessions 로 조정)")
    lines.append("")

    if not paths:
        lines.append("조건에 맞는 경로가 없습니다.")
        return "\n".join(lines)

    for entry in paths[:limit]:
        mark = "규칙" if entry["rule_surface"] else "  "
        lines.append(f"[{mark}] {entry['path']}")
        lines.append(f"      읽기 {entry['reads']} · 쓰기 {entry['writes']} "
                     f"· 셸 {entry['shell']} · 세션 {entry['session_count']}개"
                     + (f" · 최근 {entry['last_ts']}" if entry["last_ts"] else ""))
    if len(paths) > limit:
        lines.append(f"... 그 외 {len(paths) - limit}개 생략")

    lines.append("")
    lines.append("셸 경로는 명령문에서 추출한 추정치라 과잉·누락이 모두 발생합니다. "
                 "이 색인에 없다는 것은 어떤 에이전트도 건드리지 않았다는 뜻이 아니라, "
                 "색인된 세션 중에는 없다는 뜻입니다.")
    return "\n".join(lines)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Reverse index: which local agent sessions touched which paths.")
    parser.add_argument("-q", "--query", default=None,
                        help="substring filter over paths")
    parser.add_argument("--all", action="store_true",
                        help="include paths that are not agent rule surfaces")
    parser.add_argument("--max-sessions", type=int, default=DEFAULT_MAX_SESSIONS,
                        help="newest-first cap on sessions parsed in one run")
    parser.add_argument("--json", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--limit", type=int, default=30, help=argparse.SUPPRESS)
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    index = build_index(args.home, max_sessions=args.max_sessions)
    paths = filter_paths(index, query=args.query, rule_only=not args.all)

    if args.json:
        print(json.dumps({**index, "paths": paths,
                          "filters": {"query": args.query, "rule_only": not args.all}},
                         ensure_ascii=False, indent=2))
    else:
        print(render_report(index, paths, args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
