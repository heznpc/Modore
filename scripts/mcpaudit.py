#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mcpaudit, Modore's MCP configuration hygiene check: which registered servers cannot run.

MCP config accumulates the way autorun entries always have. A server is added
for one experiment, its checkout is deleted or renamed months later, and the
entry stays -- pointing at a command that is gone, duplicated under a second
name, or carrying an `env` block nobody remembers the contents of. Nothing
reports this: the client silently fails to start the server, and the operator
learns about it as "the tool just isn't there".

This module reads the config files and says which entries cannot start, on the
same terms as every other Modore verdict: deterministic, metadata-only, and
strictly read-only. Ported from decant's `MCPHygiene.swift` (absorbed 2026-08).

Two deliberate deviations from the original:
- decant anonymised every server to `server#N`. Modore names them. A hygiene
  report the operator cannot act on is not a hygiene report, and a server name
  is configuration metadata of the same kind scree already emits (workspace
  paths, repository names). What stays hidden is what was sensitive in the
  first place: `env` is reported as a key *count*, never as keys or values.
- a verdict that depends on PATH is withheld when PATH is unusable, rather
  than reported as `dead`. This is the same fail-safe rule hfscan applies to
  its search: a check that could not run has not established anything.

Privacy contract (metadata-only output):
- `env` values and key names are never read into the output -- only whether a
  block exists and how many keys it has;
- absolute paths are masked through `scree.mask_text` (home path, and the key
  and token patterns it already covers, in case a config embeds one in an arg);
- writes nothing, starts nothing; all output goes to stdout. This module has no
  code path that disables, edits, or removes a server.

Judgment limits (preview-grade evidence, not a removal authorization):
- `dead` means the command does not resolve on this machine right now -- a
  server behind a version manager, a not-yet-built checkout, or a volume that
  is merely unmounted all look the same from here;
- `duplicate` compares command and args only; two entries that differ solely
  by `env` are genuinely different servers and are reported as duplicates;
- whether a server is actually *used* is not judged. That needs session-log
  cross-referencing, which this module does not do.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Optional

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    # Python isolated mode (-I, which CI and the app's runner both use)
    # intentionally omits the script directory. Import only the sibling
    # helper from this resolved, repository-controlled directory.
    sys.path.insert(0, str(SCRIPT_DIR))

from scree import mask_text  # noqa: E402

CONFIG_CANDIDATES = (
    ".claude.json",
    "Library/Application Support/Claude/claude_desktop_config.json",
    ".config/claude/claude_desktop_config.json",
    ".mcp.json",
)

# Arguments that look like a local file the server needs in order to start.
PATH_LIKE_SUFFIXES = frozenset({".js", ".mjs", ".cjs", ".ts", ".py", ".rb",
                                ".jar", ".sh", ".phar"})

STATUS_ORDER = ("dead", "unknown", "duplicate", "manual-review")

MAX_CONFIG_BYTES = 8 * 1024 * 1024


# ---------------------------------------------------------------------------
# Config discovery and parsing
# ---------------------------------------------------------------------------

def discover_configs(home: Path) -> list[Path]:
    return [home / name for name in CONFIG_CANDIDATES if (home / name).is_file()]


def collect_servers(node: Any, config: Path, out: list[dict]) -> None:
    """Every `mcpServers` block anywhere in the document.

    Claude's `~/.claude.json` nests per-project blocks under a `projects` map,
    so a flat read of the root would miss most of the machine's servers.
    """
    if isinstance(node, dict):
        block = node.get("mcpServers")
        if isinstance(block, dict):
            for name, body in block.items():
                if isinstance(body, dict):
                    out.append(_entry(config, str(name), body))
        for value in node.values():
            collect_servers(value, config, out)
    elif isinstance(node, list):
        for value in node:
            collect_servers(value, config, out)


def _entry(config: Path, name: str, body: dict) -> dict:
    command = body.get("command")
    args = body.get("args")
    env = body.get("env")
    return {
        "config": config,
        "name": name,
        "command": command if isinstance(command, str) else None,
        "args": [a for a in args if isinstance(a, str)] if isinstance(args, list) else [],
        "env_key_count": len(env) if isinstance(env, dict) else 0,
        "transport": "http" if isinstance(body.get("url"), str) else "stdio",
        "url_only": isinstance(body.get("url"), str) and not isinstance(command, str),
    }


def parse_config(path: Path) -> tuple[list[dict], Optional[str]]:
    try:
        if path.stat().st_size > MAX_CONFIG_BYTES:
            return [], "config-too-large"
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        return [], f"unreadable: {type(exc).__name__}"
    entries: list[dict] = []
    collect_servers(document, path, entries)
    return entries, None


# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

def path_entries(env: Optional[dict] = None) -> list[str]:
    env = os.environ if env is None else env
    raw = env.get("PATH") or ""
    return [p for p in raw.split(os.pathsep) if p]


def command_resolves(command: str, search_path: list[str]) -> Optional[bool]:
    """True / False / None, where None means 'could not check'.

    None is the fail-safe answer: a bare command name cannot be judged missing
    when there is no PATH to look in, and reporting it as dead would send the
    operator to delete a working server.
    """
    if "/" in command:
        expanded = os.path.expanduser(command)
        return os.path.isfile(expanded) and os.access(expanded, os.X_OK)
    if not search_path:
        return None
    for directory in search_path:
        candidate = os.path.join(directory, command)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return True
    return False


def missing_local_paths(args: list[str], config_dir: Path) -> list[str]:
    missing: list[str] = []
    for arg in args:
        if arg.startswith("-"):
            continue
        expanded = os.path.expanduser(arg)
        suffix = os.path.splitext(expanded)[1].lower()
        looks_local = expanded.startswith(("/", "./", "../", "~")) or suffix in PATH_LIKE_SUFFIXES
        if not looks_local:
            continue
        resolved = expanded if os.path.isabs(expanded) else str(config_dir / expanded)
        if not os.path.exists(resolved):
            missing.append(resolved)
    return missing


def signature(entry: dict) -> str:
    return "\x1f".join([entry["command"] or ""] + entry["args"])


def classify(entry: dict, duplicates: set, search_path: list[str]) -> Optional[dict]:
    """One finding, or None when the entry looks healthy.

    Order matters: an entry that cannot start at all is reported as such, and
    the softer observations (duplicate, env present) only apply to entries that
    otherwise resolve.
    """
    reasons: list[str] = []

    if entry["url_only"]:
        # A remote server has no local command to resolve. Reachability is a
        # network question, and Modore does not make network calls.
        return None

    command = (entry["command"] or "").strip()
    if not command:
        return _finding(entry, "unknown", ["missing-command"])

    resolved = command_resolves(command, search_path)
    if resolved is None:
        return _finding(entry, "unknown", ["path-unavailable-cannot-check-command"])
    if resolved is False:
        reasons.append("command-not-found")

    if missing_local_paths(entry["args"], entry["config"].parent):
        reasons.append("local-path-missing")

    if reasons:
        return _finding(entry, "dead", reasons)
    if signature(entry) in duplicates:
        return _finding(entry, "duplicate", ["same-command-and-args-as-another-server"])
    if entry["env_key_count"]:
        return _finding(entry, "manual-review", ["env-present-not-read"])
    return None


def _finding(entry: dict, status: str, reasons: list[str]) -> dict:
    return {
        "config": entry["config"],
        "server": entry["name"],
        "command_kind": os.path.basename(entry["command"] or "") or "missing-command",
        "transport": entry["transport"],
        "env_key_count": entry["env_key_count"],
        "status": status,
        "reasons": sorted(set(reasons)),
    }


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def build_report(home: Path, *, env: Optional[dict] = None) -> dict:
    configs = discover_configs(home)
    search_path = path_entries(env)

    entries: list[dict] = []
    config_notes: list[dict] = []
    for config in configs:
        parsed, error = parse_config(config)
        if error:
            config_notes.append({"path": mask_text(str(config), home), "error": error})
        entries.extend(parsed)

    counts: dict[str, int] = {}
    for entry in entries:
        sig = signature(entry)
        if sig.strip("\x1f"):
            counts[sig] = counts.get(sig, 0) + 1
    duplicates = {sig for sig, n in counts.items() if n > 1}

    findings = []
    for entry in entries:
        finding = classify(entry, duplicates, search_path)
        if finding:
            findings.append({
                **finding,
                "config": mask_text(str(finding["config"]), home),
                "server": mask_text(finding["server"], home),
            })
    findings.sort(key=lambda f: (STATUS_ORDER.index(f["status"]), f["server"]))

    summary = {status: sum(1 for f in findings if f["status"] == status)
               for status in STATUS_ORDER}
    return {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime()),
        "configs": [mask_text(str(c), home) for c in configs],
        "config_errors": config_notes,
        "server_count": len(entries),
        "path_available": bool(search_path),
        "findings": findings,
        "summary": {**summary, "healthy": len(entries) - len(findings)},
        "evidence": "preview",
        "requires_revalidation": True,
    }


STATUS_LABEL = {
    "dead": "실행 불가",
    "unknown": "판정보류",
    "duplicate": "중복",
    "manual-review": "직접 확인",
}


def render_report(report: dict, limit: int) -> str:
    lines = ["MCP 설정 위생 점검 (읽기 전용)", ""]

    if not report["configs"]:
        lines.append("MCP 설정 파일을 찾지 못했습니다.")
        return "\n".join(lines)

    lines.append(f"설정 {len(report['configs'])}개 · 서버 {report['server_count']}개")
    for config in report["configs"]:
        lines.append(f"  {config}")
    for note in report["config_errors"]:
        lines.append(f"  ⚠ {note['path']}: {note['error']}")
    lines.append("")

    if not report["path_available"]:
        lines.append("⚠ PATH를 읽을 수 없어 명령 존재 여부를 확인하지 않았습니다. "
                     "이름만 적힌 명령은 '판정보류'로 남습니다.")
        lines.append("")

    if not report["findings"]:
        lines.append("위생 소견 없음. 그래도 서버를 지우기 전에는 직접 확인하십시오.")
        return "\n".join(lines)

    summary = report["summary"]
    lines.append(" · ".join(f"{STATUS_LABEL[s]} {summary[s]}" for s in STATUS_ORDER
                            if summary.get(s)))
    lines.append(f"정상 {summary['healthy']}")
    lines.append("")

    for finding in report["findings"][:limit]:
        lines.append(f"[{STATUS_LABEL[finding['status']]}] {finding['server']} "
                     f"· {finding['command_kind']}")
        lines.append(f"    설정: {finding['config']}")
        lines.append(f"    근거: {', '.join(finding['reasons'])}")
        if finding["env_key_count"]:
            lines.append(f"    env 키 {finding['env_key_count']}개 (값·키 이름은 읽지 않음)")
    if len(report["findings"]) > limit:
        lines.append(f"... 그 외 {len(report['findings']) - limit}건 생략")

    lines.append("")
    lines.append("이 점검은 설정을 바꾸지 않았고 서버를 끄거나 지우지 않았습니다. "
                 "'실행 불가'는 지금 이 머신에서 명령이 풀리지 않는다는 뜻이지, "
                 "그 서버가 불필요하다는 판정이 아닙니다.")
    return "\n".join(lines)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check registered MCP servers for entries that cannot start.")
    parser.add_argument("--json", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--limit", type=int, default=20, help=argparse.SUPPRESS)
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    report = build_report(args.home)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(render_report(report, args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
