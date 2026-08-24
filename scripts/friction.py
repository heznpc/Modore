#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Friction, Modore's operator-pushback scanner: where the human hit the brakes.

scree maps the debris agent sessions leave on disk. friction reads the same
session stores for the opposite question: inside those transcripts, which turns
are the operator telling the agent it got the behaviour wrong?

Deterministic port of canary's `lib/sessions/friction.ts` (archived 2026-08).
Keyword and tone matching only — no model anywhere in the judgment path, the
same contract every other Modore verdict is held to. The 9-category taxonomy
and its severity ladder come from a 2026-07 human audit of 2,630 genuine user
turns yielding 515 findings; that figure is cited from canary's own record and
is not re-derived here.

Review aid, not ground truth: keyword/tone matching both under- and
over-catches relative to the human audit that produced the taxonomy. Every
verdict carries `evidence: preview`.

Content contract (the deliberate exception, stated plainly):
- scree never retains message content. friction must — a friction finding IS a
  user turn — so this is the second explicit exception in the module, after
  `scree.py preserve`. It is bounded the same way:
  - only turns authored by the *user* are examined; assistant text, tool calls,
    tool results, and nested subagent transcripts are never emitted;
  - each emitted quote is capped at QUOTE_CAP characters;
  - quotes are masked through `scree.mask_text` by default (email, JWT,
    API keys, PEM private keys, home path); `--raw-quotes` opts out explicitly,
    mirroring `scree.py preserve --raw`;
  - nothing is ever written; all output goes to stdout.

Quotes are operator-authored free text. Any consumer that puts them in front of
a model must fence them as untrusted data — `scripts/mcp_server.py` does.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Iterable, Iterator, Optional

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    # Python isolated mode (-I, which CI and the app's runner both use)
    # intentionally omits the script directory. Import only the sibling
    # collector from this resolved, repository-controlled directory.
    sys.path.insert(0, str(SCRIPT_DIR))

from scree import collect_claude, collect_codex, mask_text  # noqa: E402

# ---------------------------------------------------------------------------
# Taxonomy (ported verbatim from canary/lib/sessions/friction.ts)
# ---------------------------------------------------------------------------

FRICTION_CATEGORIES = (
    "wrong-action",
    "no-research-assertion",
    "stalling-approval",
    "rule-contamination",
    "over-orchestration-token",
    "stale-repetition",
    "verbosity",
    "tone-attitude",
    "other-ai-friction",
)

TAXONOMY_BASIS = ("9-category taxonomy and severity ladder derived from a 2026-07 human audit "
                  "of 2,630 user turns / 515 findings (canary); cited, not re-derived here")

QUOTE_CAP = 200

# Injected/non-typed user rows: task notifications, slash-command echoes,
# request markers. Matched against the turn's leading characters.
NOISE_PREFIXES = ("<task", "<command", "<local", "[Request")

# Rage markers -> severity 3.
ANGER_RE = re.compile(r"시발|씨발|ㅅㅂ|병신|좆|개소리|아오 |빡치|열받")

# Clear-irritation markers -> severity 2.
IRRITATION_RE = re.compile(
    r"아니 왜|왜 자꾸|왜 계속|왜 또|;;|하;|답답|짜증|몇\s?번을|라니까|했잖아|말했잖|처하고|처해서|어이가")

# Mild-correction openers -> severity 1.
CORRECTION_RE = re.compile(r"^(아니\s|아니야|아니지|ㄴㄴ|그게 아니|그거 말고|아뇨)")

# First match wins; ordered by how specific the surface form is.
CATEGORY_RULES: tuple[tuple[str, "re.Pattern[str]"], ...] = (
    ("no-research-assertion", re.compile(
        r"리서치를 해|검색을 해|검색해봐|찾아보고|확인을 (하|처)|확인은 하고|소스 검색|검증(도|은)? 안|넘겨짚|단정하")),
    ("stalling-approval", re.compile(
        r"왜 보류|왜 (자꾸 )?(멈|끊)|물어보지 말|물어만 보|진행하라|하라고 했|안 하고 물|제안만|말만 (하|몇)"
        r"|push를 안|푸시를 안|커밋.*안 (하|했)|하다 말(았|고|다)|끝까지 한다(며|더니)")),
    ("rule-contamination", re.compile(
        r"오염|CLAUDE\.md|claude\.md|AGENTS\.md|헌법|규칙 (때문|이) |메모리.*저장|니?\s?맘대로 저장|조항")),
    ("over-orchestration-token", re.compile(
        r"토큰\s?(낭비|이 너무|을 태|써)|에이전트를?\s?\d+개|에이전트.*씩 돌|워크플로|팬아웃|과하게|재검증만|또 검증")),
    ("stale-repetition", re.compile(
        r"몇\s?번을 말|또 (그|이|물어)|반복하지|아까 말|이미 말했|기억을 못|누락시키|같은 (말|얘기)")),
    ("verbosity", re.compile(r"쓸데없|장황|말이 많|요점만|짧게 (해|말)|서론|빙빙")),
    ("tone-attitude", re.compile(r"말투|태도|자랑스럽게|당당하게|훈계|사과(만|하지)")),
    ("wrong-action", re.compile(
        r"누가.*(하래|시켰|만들래)|시키지 않|시킨 적|맘대로|내가 말한 건|의도(가|를) (아니|잘못|모르)"
        r"|엉뚱한|그걸 왜|이걸 왜|왜 (그렇게|이렇게) (하|만들|했)|다르잖|뭘 한거|뭘 만든")),
)

# The operator quotes assistant text and appends a retort after a bare `<`
# ("...했습니다.< 이딴 소리 왜하는거임"). When that shape is present, the retort
# segment -- the operator's own words -- is the quote that matters.
_RETORT_RE = re.compile(r"[^<\s]<\s?(?!/)([^<]{4,})\Z")

# Pasted assistant/report payloads. Operators paste assistant text (reviews,
# cross-session reports) into the prompt; friction markers inside that payload
# are not the operator's own pushback. Heuristic: long text that opens in formal
# register (합니다체) -- assistant voice -- while this scan targets the
# operator's own words. The quote-`<`-retort shape is handled before this check,
# so a retort appended to a paste still counts.
_PASTED_REPORT_RE = re.compile(r"(습니다|합니다)[.…)\"']?\s")

_WHITESPACE_RE = re.compile(r"\s+")


def is_noise(text: str) -> bool:
    return text.startswith(NOISE_PREFIXES)


def looks_pasted_report(text: str) -> bool:
    return len(text) > 400 and bool(_PASTED_REPORT_RE.search(text[:120]))


def retort_segment(text: str) -> str:
    match = _RETORT_RE.search(text)
    return match.group(1) if match else text


def severity_of(text: str) -> Optional[int]:
    if ANGER_RE.search(text):
        return 3
    if IRRITATION_RE.search(text):
        return 2
    if CORRECTION_RE.match(text.lstrip()):
        return 1
    return None


def category_of(text: str) -> str:
    for category, pattern in CATEGORY_RULES:
        if pattern.search(text):
            return category
    return "other-ai-friction"


# ---------------------------------------------------------------------------
# Session discovery
#
# claude/codex reuse scree's own collectors verbatim -- same traversal, same
# whitelisted metadata, no second implementation. gemini and claude-desktop are
# collected here because scree does NOT traverse their transcripts: its
# `collect_gemini` reads only the `~/.gemini/projects.json` registry (one record
# per project, no session file), and it has no Claude Desktop collector at all.
# Both gaps are deliberate on scree's side -- neither store contributes a
# workspace join scree does not already have -- so they are added here rather
# than by widening scree's shipped, UI-consumed report.
# ---------------------------------------------------------------------------

SOURCES = ("claude", "codex", "gemini", "claude-desktop")

# scree labels stores by display name; canary's taxonomy keys them lowercase.
_SCREE_TOOL_TO_SOURCE = {"Claude": "claude", "Codex": "codex"}

CLAUDE_DESKTOP_RELATIVE = ("Library", "Application Support", "Claude",
                           "local-agent-mode-sessions")

# One transcript line larger than this is a pasted blob (base64 image, tool
# result dump), never typed operator prose. Skipped and counted, never silently.
MAX_LINE_BYTES = 1 << 20
# A whole transcript larger than this is skipped and counted the same way.
MAX_FILE_BYTES = 64 << 20


def _session_ref(source: str, path: Path, workspace: Optional[str],
                 last_active: float) -> dict:
    return {"source": source, "path": str(path), "workspace": workspace,
            "last_active": last_active}


def collect_gemini_chats(home: Path) -> tuple[list[dict], dict]:
    """`~/.gemini/tmp/<alias>/chats/*.jsonl`, joined to a real workspace path.

    Gemini CLI records no `cwd` in the transcript; it names the scratch
    directory after the project alias it stores in `~/.gemini/projects.json`
    (`{workspace_path: alias}`). Inverting that map is the only deterministic
    join available, so an alias with no registry entry stays workspace-null
    rather than being guessed at.
    """
    root = home / ".gemini" / "tmp"
    if not root.is_dir():
        return [], {"store": "gemini", "status": "missing", "found": 0, "unreadable": 0}
    alias_to_workspace: dict[str, str] = {}
    registry = home / ".gemini" / "projects.json"
    try:
        data = json.loads(registry.read_text(encoding="utf-8-sig"))
        projects = data.get("projects") if isinstance(data, dict) else None
        if isinstance(projects, dict):
            for workspace in sorted(projects):
                alias = projects[workspace]
                if isinstance(alias, str):
                    alias_to_workspace.setdefault(alias, workspace)
    except (OSError, ValueError):
        pass
    refs: list[dict] = []
    unreadable = 0
    for chats in sorted(root.glob("*/chats")):
        workspace = alias_to_workspace.get(chats.parent.name)
        for path in sorted(chats.glob("*.jsonl")):
            try:
                stat = path.stat()
            except OSError:
                unreadable += 1
                continue
            refs.append(_session_ref("gemini", path, workspace, stat.st_mtime))
    return refs, {"store": "gemini", "status": "ok", "found": len(refs),
                  "unreadable": unreadable}


def collect_claude_desktop(home: Path) -> tuple[list[dict], dict]:
    """`~/Library/Application Support/Claude/local-agent-mode-sessions/**/*.jsonl`.

    Claude Desktop's local agent mode writes the same stream shape as Claude
    Code (`type: "user"`, `message.content`), only with `_audit_timestamp` in
    place of `timestamp` and a sandbox `cwd`; the Claude parser handles both.
    """
    root = home.joinpath(*CLAUDE_DESKTOP_RELATIVE)
    if not root.is_dir():
        return [], {"store": "claude-desktop", "status": "missing", "found": 0,
                    "unreadable": 0}
    refs: list[dict] = []
    unreadable = 0
    for path in sorted(root.rglob("*.jsonl")):
        try:
            stat = path.stat()
        except OSError:
            unreadable += 1
            continue
        refs.append(_session_ref("claude-desktop", path, None, stat.st_mtime))
    return refs, {"store": "claude-desktop", "status": "ok", "found": len(refs),
                  "unreadable": unreadable}


def collect_sessions(home: Path) -> tuple[list[dict], list[dict]]:
    """Every candidate transcript across the four stores, newest first."""
    refs: list[dict] = []
    stores: list[dict] = []
    for collector in (collect_claude, collect_codex):
        records, status = collector(home)
        source = _SCREE_TOOL_TO_SOURCE[status["store"]]
        found = 0
        for record in records:
            if record.get("kind") != "session" or not record.get("source"):
                continue
            refs.append(_session_ref(source, Path(record["source"]),
                                     record.get("workspace"), record["last_active"]))
            found += 1
        stores.append({"store": source, "status": status["status"], "found": found,
                       "unreadable": status.get("unrecognized", 0)})
    for collector in (collect_gemini_chats, collect_claude_desktop):
        found_refs, status = collector(home)
        refs.extend(found_refs)
        stores.append(status)
    refs.sort(key=lambda ref: ref["last_active"], reverse=True)
    return refs, stores


# ---------------------------------------------------------------------------
# Per-store user-turn extraction
# ---------------------------------------------------------------------------

def _iter_json_lines(path: Path, budget: dict) -> Iterator[dict]:
    try:
        if path.stat().st_size > MAX_FILE_BYTES:
            budget["oversized_files"] += 1
            return
    except OSError:
        budget["unreadable_files"] += 1
        return
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if len(line) > MAX_LINE_BYTES:
                    budget["oversized_lines"] += 1
                    continue
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    parsed = json.loads(stripped)
                except ValueError:
                    budget["unparsed_lines"] += 1
                    continue
                if isinstance(parsed, dict):
                    yield parsed
    except OSError:
        budget["unreadable_files"] += 1


def _text_of_content(content: object) -> str:
    """Concatenated `text` blocks. Non-text blocks (image, tool_use,
    tool_result) are dropped: they are not the operator's typed words."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = [block.get("text", "") for block in content
             if isinstance(block, dict) and block.get("type") in (None, "text")
             and isinstance(block.get("text"), str)]
    return "\n".join(part for part in parts if part)


def _timestamp_of(line: dict) -> Optional[str]:
    for key in ("timestamp", "_audit_timestamp", "lastUpdated", "startTime"):
        value = line.get(key)
        if isinstance(value, str) and value:
            return value
    return None


# Rows Claude writes into the user channel that the operator never typed.
# A `/compact` continuation carries isCompactSummary; a row the app renders but
# was never sent as a prompt carries isVisibleInTranscriptOnly.
CLAUDE_UNTYPED_ROW_FLAGS = ("isCompactSummary", "isVisibleInTranscriptOnly")


def claude_user_turns(path: Path, budget: dict) -> Iterator[tuple[Optional[str], str]]:
    """Claude Code and Claude Desktop streams alike.

    A `/compact` continuation is stored as `type: "user"`, but its body is the
    assistant's summary of the conversation so far. Reading it as operator text
    breaks the content contract twice over: it invents pushback the operator
    never expressed, and it emits assistant prose inside a quote attributed to
    them. Both kinds of row are skipped by their flag rather than by matching
    the summary's opening sentence, which is English and would miss any
    localised build.
    """
    for line in _iter_json_lines(path, budget):
        if line.get("type") != "user":
            continue
        if any(line.get(flag) for flag in CLAUDE_UNTYPED_ROW_FLAGS):
            continue
        message = line.get("message")
        if not isinstance(message, dict):
            continue
        text = _text_of_content(message.get("content"))
        if text:
            yield _timestamp_of(line), text


def codex_user_turns(path: Path, budget: dict) -> Iterator[tuple[Optional[str], str]]:
    """Codex rollouts carry the same turn on two channels.

    `event_msg`/`user_message` is the human-visible channel and is preferred.
    `response_item` messages with role=user duplicate it in current rollouts, so
    they are used only for files where the event channel produced nothing --
    the same precedence canary's parser applies.
    """
    event_turns: list[tuple[Optional[str], str]] = []
    item_turns: list[tuple[Optional[str], str]] = []
    for line in _iter_json_lines(path, budget):
        payload = line.get("payload")
        if not isinstance(payload, dict):
            continue
        ts = _timestamp_of(line)
        kind = line.get("type")
        if kind == "event_msg" and payload.get("type") == "user_message":
            message = payload.get("message")
            if isinstance(message, str) and message:
                event_turns.append((ts, message))
        elif (kind == "response_item" and payload.get("type") == "message"
              and payload.get("role") == "user"):
            content = payload.get("content")
            parts = [block.get("text", "") for block in content
                     if isinstance(content, list) and isinstance(block, dict)
                     and block.get("type") in ("input_text", "text")
                     and isinstance(block.get("text"), str)] if isinstance(content, list) else []
            text = "\n".join(part for part in parts if part)
            if text:
                item_turns.append((ts, text))
    yield from (event_turns or item_turns)


def gemini_user_turns(path: Path, budget: dict) -> Iterator[tuple[Optional[str], str]]:
    """Gemini CLI chat files interleave two views of the same conversation:
    standalone message rows and `$set` rows that rewrite the whole `messages`
    array. Both are read and deduplicated by message id, so a turn rewritten on
    every `$set` is counted once."""
    seen: set[str] = set()
    turns: list[tuple[Optional[str], str]] = []

    def take(entry: object) -> None:
        if not isinstance(entry, dict) or entry.get("type") != "user":
            return
        text = _text_of_content(entry.get("content"))
        if not text:
            return
        key = entry.get("id") if isinstance(entry.get("id"), str) else f"#{len(turns)}"
        if key in seen:
            return
        seen.add(key)
        turns.append((_timestamp_of(entry), text))

    for line in _iter_json_lines(path, budget):
        setter = line.get("$set")
        if isinstance(setter, dict):
            messages = setter.get("messages")
            if isinstance(messages, list):
                for entry in messages:
                    take(entry)
            continue
        take(line)
    yield from turns


_PARSERS = {
    "claude": claude_user_turns,
    "claude-desktop": claude_user_turns,
    "codex": codex_user_turns,
    "gemini": gemini_user_turns,
}


# ---------------------------------------------------------------------------
# Judgment
# ---------------------------------------------------------------------------

def extract_friction(turns: Iterable[tuple[Optional[str], str]], ref: dict,
                     *, home: Path, raw_quotes: bool) -> tuple[list[dict], int]:
    """Pure core: friction findings from one session's user turns."""
    findings: list[dict] = []
    user_turns = 0
    for ts, text in turns:
        raw = text.strip().strip("﻿").strip()
        if not raw or is_noise(raw):
            continue
        user_turns += 1
        focus = retort_segment(raw)
        if focus == raw and looks_pasted_report(raw):
            continue
        severity = severity_of(focus)
        if severity is None:
            continue
        quote = _WHITESPACE_RE.sub(" ", focus).strip()[:QUOTE_CAP]
        findings.append({
            "ts": ts,
            "source": ref["source"],
            "session": str(Path(ref["path"]).name),
            "path": ref["path"],
            "workspace": ref["workspace"],
            "category": category_of(focus),
            "severity": severity,
            "quote": quote if raw_quotes else mask_text(quote, home),
        })
    return findings, user_turns


def _dedupe_replayed_turns(findings: list[dict]) -> tuple[list[dict], int]:
    """One operator turn is one finding, however many transcripts replay it.

    Resuming or forking a Claude session writes a fresh `.jsonl` that replays
    the whole prior conversation: each message keeps its `uuid` and
    `timestamp` and only the `sessionId` changes. A turn typed once is
    therefore on disk once per resume -- eleven copies for one conversation on
    the development machine -- and counting every copy inflates the finding
    list and both summary tables with turns that were never repeated. This is
    the rule the Gemini parser already applies to `$set` rewrites, widened
    from within one file to across the store.

    Keyed on (source, timestamp, quote). A turn with no timestamp cannot be
    identified across files, so it is kept rather than guessed at. Sessions
    arrive newest-first, so the copy that survives is the one in the most
    recently active session -- the transcript the operator would resume.
    """
    seen: set[tuple[str, str, str]] = set()
    kept: list[dict] = []
    collapsed = 0
    for finding in findings:
        timestamp = finding["ts"]
        if not timestamp:
            kept.append(finding)
            continue
        key = (finding["source"], timestamp, finding["quote"])
        if key in seen:
            collapsed += 1
            continue
        seen.add(key)
        kept.append(finding)
    return kept, collapsed


DEFAULT_SINCE_DAYS = 30
DEFAULT_MAX_SESSIONS = 200


def build_friction(home: Path, *, since_days: int = DEFAULT_SINCE_DAYS,
                   source: Optional[str] = None,
                   max_sessions: int = DEFAULT_MAX_SESSIONS,
                   raw_quotes: bool = False, now_ts: Optional[float] = None) -> dict:
    now = time.time() if now_ts is None else now_ts
    cutoff = now - since_days * 86400
    refs, stores = collect_sessions(home)
    candidates = [ref for ref in refs if ref["last_active"] >= cutoff]
    if source:
        candidates = [ref for ref in candidates if ref["source"] == source]
    selected = candidates[:max_sessions]
    budget = {"oversized_files": 0, "oversized_lines": 0, "unparsed_lines": 0,
              "unreadable_files": 0}

    findings: list[dict] = []
    user_turns = 0
    scanned_by_source: dict[str, int] = {}
    for ref in selected:
        parser = _PARSERS[ref["source"]]
        session_findings, turns = extract_friction(
            parser(Path(ref["path"]), budget), ref, home=home, raw_quotes=raw_quotes)
        findings.extend(session_findings)
        user_turns += turns
        scanned_by_source[ref["source"]] = scanned_by_source.get(ref["source"], 0) + 1
    findings, replayed_copies = _dedupe_replayed_turns(findings)
    findings.sort(key=lambda f: (f["ts"] or "", f["path"]))

    by_category = {name: 0 for name in FRICTION_CATEGORIES}
    by_severity = {"1": 0, "2": 0, "3": 0}
    for finding in findings:
        by_category[finding["category"]] += 1
        by_severity[str(finding["severity"])] += 1

    for store in stores:
        store["in_window"] = sum(1 for ref in candidates if ref["source"] == store["store"])
        store["scanned"] = scanned_by_source.get(store["store"], 0)

    return {
        "contract": ("user-authored turns only; quotes capped and masked by default; "
                     "deterministic keyword/tone matching; no model in the judgment path; "
                     "writes nothing"),
        "taxonomy_basis": TAXONOMY_BASIS,
        "evidence": "preview",
        "quotes": "raw" if raw_quotes else "masked",
        "window_days": since_days,
        "source_filter": source,
        "stores": stores,
        "sessions_in_window": len(candidates),
        "sessions_scanned": len(selected),
        "sessions_skipped_by_cap": max(0, len(candidates) - len(selected)),
        "replayed_copies_collapsed": replayed_copies,
        "max_sessions": max_sessions,
        "user_turns_scanned": user_turns,
        "skipped": budget,
        "findings": findings,
        "by_category": by_category,
        "by_severity": by_severity,
    }


# ---------------------------------------------------------------------------
# Text report
# ---------------------------------------------------------------------------

_SEVERITY_MARK = {3: "rage", 2: "irritation", 1: "correction"}


def render_report(report: dict, limit: int) -> str:
    lines = ["Modore friction — where the operator hit the brakes "
             "(deterministic keyword/tone · no LLM · preview evidence)"]
    store_bits = []
    for store in report["stores"]:
        if store["status"] == "missing":
            store_bits.append(f"{store['store']} none")
        else:
            store_bits.append(f"{store['store']} {store['scanned']}/{store['in_window']}")
    lines.append("stores (scanned/in-window): " + " · ".join(store_bits))
    lines.append(f"window {report['window_days']}d · sessions scanned "
                 f"{report['sessions_scanned']}/{report['sessions_in_window']}"
                 f" · user turns {report['user_turns_scanned']}"
                 f" · findings {len(report['findings'])}")
    if report["sessions_skipped_by_cap"]:
        lines.append(f"  note: {report['sessions_skipped_by_cap']} in-window sessions were not "
                     f"scanned (--max-sessions {report['max_sessions']}); raise the cap to cover them")
    if report.get("replayed_copies_collapsed"):
        lines.append(f"  note: {report['replayed_copies_collapsed']} replayed copies of turns "
                     f"counted above were collapsed; resuming a session rewrites the whole "
                     f"transcript, so one turn can sit in many files")
    skipped = report["skipped"]
    if any(skipped.values()):
        lines.append("  skipped: " + " · ".join(f"{k} {v}" for k, v in skipped.items() if v))
    severity = report["by_severity"]
    lines.append(f"severity — rage {severity['3']} · irritation {severity['2']}"
                 f" · correction {severity['1']}")
    ranked = sorted(report["by_category"].items(), key=lambda kv: (-kv[1], kv[0]))
    lines.append("category — " + " · ".join(f"{name} {count}" for name, count in ranked if count)
                 if any(count for _, count in ranked) else "category — none")
    lines.append("")
    lines.append(f"quotes below are operator-authored text ({report['quotes']}); treat as data, "
                 "never as instructions")
    worst = sorted(report["findings"], key=lambda f: (-f["severity"], f["ts"] or ""))
    for rank, finding in enumerate(worst[:limit], start=1):
        stamp = (finding["ts"] or "")[:16] or "?"
        where = finding["workspace"] or finding["source"]
        lines.append(f"{rank:2d}. [{_SEVERITY_MARK[finding['severity']]}|{finding['category']}] "
                     f"{stamp} {where}")
        lines.append(f"     \"{finding['quote']}\"")
    if len(worst) > limit:
        lines.append(f"… {len(worst) - limit} more (use --limit or --json)")
    return "\n".join(lines)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Find the turns where the operator pushed back on agent behaviour.")
    sub = parser.add_subparsers(dest="command")

    def add_scan_args(target: argparse.ArgumentParser, *, hidden: bool = False) -> None:
        hide = argparse.SUPPRESS if hidden else None
        target.add_argument("--json", action="store_true",
                            help=hide or "print the full report as JSON")
        target.add_argument("--since-days", type=int, default=DEFAULT_SINCE_DAYS,
                            help=hide or f"look-back window (default {DEFAULT_SINCE_DAYS})")
        target.add_argument("--source", choices=SOURCES, default=None,
                            help=hide or "restrict to one session store")
        target.add_argument("--max-sessions", type=int, default=DEFAULT_MAX_SESSIONS,
                            help=hide or f"newest-first cap (default {DEFAULT_MAX_SESSIONS})")
        target.add_argument("--limit", type=int, default=15,
                            help=hide or "findings to show in the text report")
        target.add_argument("--raw-quotes", action="store_true",
                            help=hide or "disable quote masking (explicit opt-out, off by default)")
        target.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)

    add_scan_args(sub.add_parser("scan", help="scan session stores for operator friction (default)"))
    add_scan_args(parser, hidden=True)

    args = parser.parse_args(argv)
    if args.since_days <= 0 or args.max_sessions <= 0:
        print("friction: --since-days and --max-sessions must be positive", file=sys.stderr)
        return 2

    report = build_friction(args.home, since_days=args.since_days, source=args.source,
                            max_sessions=args.max_sessions, raw_quotes=args.raw_quotes)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(render_report(report, args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
