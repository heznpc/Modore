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
import hashlib
import json
import os
import re
import select
import sys
import time
from pathlib import Path, PurePath
from typing import Iterator, Optional

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    # Python isolated mode (-I, which CI and the app's runner both use)
    # intentionally omits the script directory. Import only the sibling
    # collectors from this resolved, repository-controlled directory.
    sys.path.insert(0, str(SCRIPT_DIR))

from scree import (  # noqa: E402
    _open_regular_nofollow,
    _prepare_isolated_reader,
    _stat_signature,
    _terminate_worktree_worker,
    collect_claude,
    collect_codex,
    mask_text,
)

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
MAX_BYTES_PER_SESSION = 32 * 1024 * 1024
MAX_LINE_BYTES = 1024 * 1024
MAX_ROWS_PER_SESSION = 10_000
MAX_TOTAL_ROWS = 50_000
SESSION_SCAN_BUDGET_SECONDS = 2.0
INDEX_SCAN_BUDGET_SECONDS = 30.0
DISCOVERY_MAX_OUTPUT_BYTES = 8 * 1024 * 1024
CONTENT_SCAN_MAX_OUTPUT_BYTES = 8 * 1024 * 1024
ISOLATED_SCAN_MAX_ROWS = 1000
MAX_PATH_BYTES = 4096
MAX_TIMESTAMP_BYTES = 256
MAX_RETAINED_BYTES = 4 * 1024 * 1024
MAX_JSON_OUTPUT_BYTES = 8 * 1024 * 1024
MAX_RESULT_LIMIT = 500
PATCH_INPUT_MAX_BYTES = 1024 * 1024
PATCH_PATH_CAP = 256


def _utf8_size(value: str) -> Optional[int]:
    try:
        return len(value.encode("utf-8"))
    except UnicodeEncodeError:
        return None


def _path_within_limit(value: str) -> bool:
    size = _utf8_size(value)
    return size is not None and size <= MAX_PATH_BYTES


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


def _paths_in_command_bounded(
        command: str, cap: int = COMMAND_PATH_CAP,
        ) -> tuple[list[str], int]:
    """Return a bounded unique prefix and an observed omission lower bound."""
    found: list[str] = []
    omitted = 0
    for match in _COMMAND_PATH_RE.finditer(command):
        candidate = match.group(1)
        if not candidate or "//" in candidate:
            continue
        cleaned = _TRAILING_PUNCT_RE.sub("", candidate)
        if not cleaned or cleaned in found:
            continue
        if len(found) < cap:
            found.append(cleaned)
        else:
            omitted += 1
    return (found, omitted)


def paths_in_command(command: str, cap: int = COMMAND_PATH_CAP) -> list[str]:
    """Compatibility projection for callers that only need retained paths."""
    return _paths_in_command_bounded(command, cap)[0]


# ---------------------------------------------------------------------------
# Per-transcript extraction
# ---------------------------------------------------------------------------

def _claude_entries(
        line: dict, line_key: str = "direct",
        ) -> Iterator[tuple[str, str, str, str]]:
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
    for index, block in enumerate(content):
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        name = block.get("name")
        payload = block.get("input")
        if not isinstance(name, str) or not isinstance(payload, dict):
            continue
        block_id = block.get("id")
        # Never retain or re-serialize the potentially MiB-sized input merely
        # to dedupe an id-less block. The caller supplies a bounded digest plus
        # line ordinal from the already-read bytes.
        key = block_id if isinstance(block_id, str) and block_id else (
            f"anon:{line_key}:{index}:{name[:64]}")
        target = next((payload[field] for field in (
            "file_path", "notebook_path", "path")
            if isinstance(payload.get(field), str) and payload[field]), None)
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


def _claude_entry_shape_status(line: dict) -> str:
    """Reject malformed inputs for tool kinds this index claims to decode."""
    message = line.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return "ok"
    truncated = False
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        name = block.get("name")
        if not isinstance(name, str):
            return "parse"
        if name in READ_TOOLS or name in WRITE_TOOLS or name == "Bash":
            payload = block.get("input")
            if not isinstance(payload, dict):
                return "parse"
            if name == "Bash":
                command = payload.get("command")
                if not isinstance(command, str):
                    return "parse"
                if _paths_in_command_bounded(command)[1]:
                    truncated = True
                continue
            path_fields = (
                "file_path", "notebook_path", "path")
            present = [field for field in path_fields if field in payload]
            required_field = (
                "notebook_path" if name in {"NotebookRead", "NotebookEdit"}
                else "file_path" if name not in {"Glob", "Grep"}
                else None)
            if (required_field is not None and required_field not in payload
                    or any(not isinstance(payload[field], str)
                           for field in present)):
                return "parse"
    return "truncated" if truncated else "ok"


def _resolved_tool_path(path: str, cwd: Optional[str]) -> str:
    if (cwd and not path.startswith(("/", "~"))
            and PurePath(path).parts):
        return os.path.join(cwd, path)
    return path


def _apply_patch_entries(
        payload: dict, cwd: Optional[str], line_key: str = "direct",
        ) -> tuple[list[tuple[str, str, str, str]], str]:
    """Decode only bounded apply_patch file headers, never patch content.

    ``Update`` and ``Delete`` necessarily inspect an existing file and then
    mutate it, so both a read and a write are retained. ``Add`` and ``Move to``
    are writes. Any malformed or oversized patch makes coverage incomplete
    rather than silently pretending no file was touched.
    """
    raw = payload.get("input")
    if not isinstance(raw, str):
        return ([], "parse")
    size = _utf8_size(raw)
    if size is None:
        return ([], "parse")
    if size > PATCH_INPUT_MAX_BYTES:
        return ([], "truncated")
    lines = raw.splitlines()
    if (not lines or lines[0] != "*** Begin Patch"
            or lines[-1] != "*** End Patch"):
        return ([], "parse")

    call_id = payload.get("call_id") or payload.get("id")
    key_base = (call_id if isinstance(call_id, str) and call_id
                else f"apply_patch:{line_key}")
    entries: list[tuple[str, str, str, str]] = []
    current_update = False
    header_count = 0
    malformed = False
    prefixes = (
        ("*** Update File: ", "update"),
        ("*** Add File: ", "add"),
        ("*** Delete File: ", "delete"),
        ("*** Move to: ", "move"),
    )
    for line_number, line in enumerate(lines[1:-1], start=1):
        match = next(
            ((prefix, operation) for prefix, operation in prefixes
             if line.startswith(prefix)),
            None,
        )
        if match is None:
            if line.startswith("*** "):
                malformed = True
            continue
        prefix, operation = match
        value = line[len(prefix):]
        if (not value or value != value.strip() or "\x00" in value
                or not _path_within_limit(value)):
            malformed = True
            continue
        if operation == "move" and not current_update:
            malformed = True
            continue
        current_update = operation == "update"
        header_count += 1
        if header_count > PATCH_PATH_CAP:
            return (entries, "truncated")
        resolved = _resolved_tool_path(value, cwd)
        if not _path_within_limit(resolved):
            malformed = True
            continue
        key = f"{key_base}|{line_number}|{operation}|{resolved}"
        if operation in ("update", "delete"):
            entries.append(("read", "apply_patch", resolved, key + "|read"))
        entries.append(("write", "apply_patch", resolved, key + "|write"))
    if header_count == 0:
        malformed = True
    return (entries, "parse" if malformed else "ok")


def _codex_entries_bounded(
        line: dict, cwd: Optional[str] = None, line_key: str = "direct",
        ) -> tuple[list[tuple[str, str, str, str]], str]:
    """(op, tool, path, dedupe_key) for one Codex JSONL line.

    Codex records shell work as function calls whose arguments are usually a
    JSON string. An unparseable argument blob yields nothing rather than a
    guess -- a wrong path in a reverse index sends the operator to the wrong
    file.
    """
    payload = line.get("payload")
    if not isinstance(payload, dict):
        return ([], "ok")
    if (payload.get("type") == "custom_tool_call"
            and payload.get("name") == "apply_patch"):
        return _apply_patch_entries(payload, cwd, line_key)
    name = payload.get("name")
    if not isinstance(name, str):
        return (([], "parse") if payload.get("type") in {
            "function_call", "custom_tool_call"} else ([], "ok"))
    if name not in CODEX_COMMAND_TOOLS:
        return ([], "ok")
    raw = payload.get("arguments")
    args: dict = {}
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
        except ValueError:
            return ([], "parse")
        if isinstance(parsed, dict):
            args = parsed
        else:
            return ([], "parse")
    elif isinstance(raw, dict):
        args = raw
    else:
        return ([], "parse")
    command_key = "cmd" if "cmd" in args else "command"
    if command_key not in args:
        return ([], "parse")
    command_field = args[command_key]
    if isinstance(command_field, str):
        command = command_field
    elif (isinstance(command_field, list)
          and all(isinstance(part, str) for part in command_field)):
        command = " ".join(command_field)
    else:
        # Never stringify dictionaries or mixed arrays: their repr can contain
        # path-looking values that were not command arguments at all.
        return ([], "parse")

    seen, omitted = _paths_in_command_bounded(command)
    workdir = args.get("workdir")
    if "workdir" in args and not isinstance(workdir, str):
        return ([], "parse")
    if isinstance(workdir, str) and workdir and workdir not in seen:
        if len(seen) < COMMAND_PATH_CAP:
            seen.append(workdir)
        else:
            omitted += 1
    call_id = payload.get("call_id") or payload.get("id")
    key_base = (call_id if isinstance(call_id, str) and call_id
                else f"anon:{line_key}")
    entries = [
        ("bash", str(name), _resolved_tool_path(path, cwd),
         f"{key_base}|{path}")
        for path in seen
    ]
    return (entries, "truncated" if omitted else "ok")


def _codex_entries(
        line: dict, cwd: Optional[str] = None,
        ) -> Iterator[tuple[str, str, str, str]]:
    """Compatibility iterator for callers that do not need coverage status."""
    entries, _ = _codex_entries_bounded(line, cwd)
    yield from entries


def _scan_transcript_bounded(
        source: Path, tool: str, *, deadline: Optional[float] = None,
        maximum_bytes: Optional[int] = None,
        maximum_line_bytes: Optional[int] = None,
        maximum_lines: Optional[int] = None,
        maximum_rows: Optional[int] = None,
        ) -> tuple[
            list[tuple[str, str, str, Optional[str]]], int, str, dict]:
    """Extract one transcript through a pinned regular-file descriptor.

    ``status`` is ``ok``, ``truncated``, ``time``, or the no-follow opener's
    missing/unreadable/unrecognized classification. A caller may retain rows
    decoded before a declared bound, but it must not present absence as a
    complete result when the status is not ``ok``.
    """
    rows: list[tuple[str, str, str, Optional[str]]] = []
    seen_blocks: set = set()
    lines_read = 0
    counters = {
        "rows_omitted_by_limit_at_least": 0,
        "paths_omitted_by_size": 0,
        "timestamps_omitted_by_size": 0,
    }
    byte_limit = (
        MAX_BYTES_PER_SESSION if maximum_bytes is None else maximum_bytes)
    line_byte_limit = (
        MAX_LINE_BYTES if maximum_line_bytes is None else maximum_line_bytes)
    line_limit = MAX_LINES_PER_SESSION if maximum_lines is None else maximum_lines
    row_limit = MAX_ROWS_PER_SESSION if maximum_rows is None else maximum_rows
    descriptor, before, open_status = _open_regular_nofollow(source)
    if descriptor is None or before is None:
        return (rows, lines_read, open_status, counters)
    status = "truncated" if before.st_size > byte_limit else "ok"
    consumed = 0
    parse_failed = False
    row_limit_reached = False
    codex_cwd: Optional[str] = None
    try:
        with os.fdopen(os.dup(descriptor), "rb") as handle:
            while consumed < byte_limit:
                if deadline is not None and time.monotonic() >= deadline:
                    status = "time"
                    break
                if lines_read >= line_limit:
                    if consumed < before.st_size:
                        status = "truncated"
                    break
                remaining = byte_limit - consumed
                raw_bytes = handle.readline(min(line_byte_limit + 1, remaining + 1))
                if not raw_bytes:
                    break
                consumed += len(raw_bytes)
                if deadline is not None and time.monotonic() >= deadline:
                    status = "time"
                    break
                if len(raw_bytes) > remaining:
                    status = "truncated"
                    break
                if len(raw_bytes) > line_byte_limit:
                    # Stop rather than allocating/discarding an attacker-sized
                    # logical line in repeated chunks. Later evidence is not
                    # claimed absent; the session is explicitly truncated.
                    status = "truncated"
                    break
                raw = raw_bytes.strip()
                if not raw:
                    continue
                lines_read += 1
                line_key = (
                    f"{lines_read}:"
                    f"{hashlib.sha256(raw_bytes).hexdigest()[:16]}")
                try:
                    line = json.loads(raw.decode("utf-8"))
                except (ValueError, UnicodeError, RecursionError):
                    parse_failed = True
                    continue
                if not isinstance(line, dict):
                    parse_failed = True
                    continue
                if tool == "Codex":
                    payload = line.get("payload")
                    if (isinstance(payload, dict)
                            and payload.get("type") == "session_meta"
                            and isinstance(payload.get("cwd"), str)
                            and _path_within_limit(payload["cwd"])):
                        codex_cwd = payload["cwd"]
                ts = line.get("timestamp")
                if not isinstance(ts, str):
                    ts = None
                elif (_utf8_size(ts) is None
                      or _utf8_size(ts) > MAX_TIMESTAMP_BYTES):
                    counters["timestamps_omitted_by_size"] += 1
                    if status == "ok":
                        status = "truncated"
                    ts = None
                if tool == "Claude":
                    entries = list(_claude_entries(line, line_key))
                    extract_status = _claude_entry_shape_status(line)
                else:
                    entries, extract_status = _codex_entries_bounded(
                        line, codex_cwd, line_key)
                if extract_status == "parse":
                    parse_failed = True
                elif extract_status == "truncated" and status == "ok":
                    status = "truncated"
                for op, tool_name, path, key in entries:
                    if deadline is not None and time.monotonic() >= deadline:
                        status = "time"
                        row_limit_reached = True
                        break
                    if not _path_within_limit(path):
                        counters["paths_omitted_by_size"] += 1
                        if status == "ok":
                            status = "truncated"
                        continue
                    if len(rows) >= row_limit:
                        status = "truncated"
                        row_limit_reached = True
                        counters["rows_omitted_by_limit_at_least"] += 1
                        break
                    if key in seen_blocks:
                        continue
                    seen_blocks.add(key)
                    rows.append((op, tool_name, path, ts))
                if row_limit_reached:
                    break
            if consumed >= byte_limit and before.st_size > consumed:
                status = "truncated"
        after = os.fstat(descriptor)
        if _stat_signature(before) != _stat_signature(after):
            return ([], 0, "unreadable", counters)
        current_descriptor, current, current_status = (
            _open_regular_nofollow(source))
        if current_descriptor is None or current is None:
            return ([], 0, current_status, counters)
        try:
            if _stat_signature(after) != _stat_signature(current):
                return ([], 0, "unreadable", counters)
        finally:
            os.close(current_descriptor)
    except OSError:
        return ([], 0, "unreadable", counters)
    finally:
        os.close(descriptor)
    if status == "ok" and parse_failed:
        status = "parse"
    return (rows, lines_read, status, counters)


def scan_transcript(
        source: Path, tool: str,
        ) -> tuple[list[tuple[str, str, str, Optional[str]]], int]:
    """Compatibility result for direct callers; bounded internally."""
    rows, lines_read, _, _ = _scan_transcript_bounded(source, tool)
    return (rows, lines_read)


def _scan_transcript_isolated(
        source: Path, tool: str, deadline: float,
        ) -> tuple[list[tuple[str, str, str, Optional[str]]], int, str, dict]:
    """Put transcript open/read/stat behind a killable process boundary."""
    empty = {"rows_omitted_by_limit_at_least": 0,
             "paths_omitted_by_size": 0,
             "timestamps_omitted_by_size": 0}
    if time.monotonic() >= deadline:
        return ([], 0, "time", empty)
    try:
        read_descriptor, write_descriptor = os.pipe()
        pid = os.fork()
    except OSError:
        for descriptor in (locals().get("read_descriptor", -1),
                           locals().get("write_descriptor", -1)):
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
        return ([], 0, "unreadable", empty)
    if pid == 0:
        try:
            os.close(read_descriptor)
            rows, lines, status, counters = _scan_transcript_bounded(
                source, tool, deadline=deadline,
                maximum_rows=min(MAX_ROWS_PER_SESSION, ISOLATED_SCAN_MAX_ROWS))
            payload = json.dumps(
                {"rows": rows, "lines": lines, "status": status,
                 "counters": counters}, ensure_ascii=False,
                separators=(",", ":")).encode("utf-8")
            if len(payload) > CONTENT_SCAN_MAX_OUTPUT_BYTES:
                counters["rows_omitted_by_limit_at_least"] = max(
                    1, int(counters["rows_omitted_by_limit_at_least"])
                    + len(rows))
                payload = json.dumps(
                    {"rows": [], "lines": lines, "status": "truncated",
                     "counters": counters},
                    separators=(",", ":")).encode("utf-8")
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

    if not _prepare_isolated_reader(read_descriptor, write_descriptor, pid):
        return ([], 0, "unreadable", empty)
    chunks: list[bytes] = []
    total = 0
    eof = reaped = success = oversized = False
    try:
        while time.monotonic() < deadline and not (eof and reaped):
            remaining = deadline - time.monotonic()
            ready = select.select(
                [read_descriptor] if not eof else [], [], [],
                min(0.05, max(0.0, remaining)))[0]
            if ready:
                try:
                    chunk = os.read(read_descriptor, 65536)
                except BlockingIOError:
                    chunk = None
                if chunk == b"":
                    eof = True
                elif chunk:
                    total += len(chunk)
                    if total > CONTENT_SCAN_MAX_OUTPUT_BYTES:
                        oversized = True
                    elif not oversized:
                        chunks.append(chunk)
            if not reaped:
                try:
                    waited, wait_status = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    waited, wait_status = pid, None
                if waited == pid:
                    reaped = True
                    success = (wait_status is not None
                               and os.WIFEXITED(wait_status)
                               and os.WEXITSTATUS(wait_status) == 0)
        if not reaped:
            if not _terminate_worktree_worker(pid):
                return ([], 0, "worker-leaked", empty)
            reaped = True
        if not (eof and success) or oversized:
            return ([], 0, "time" if time.monotonic() >= deadline
                    else "unreadable", empty)
        try:
            payload = json.loads(b"".join(chunks).decode("utf-8"))
        except (ValueError, UnicodeError, RecursionError):
            return ([], 0, "unreadable", empty)
        if (not isinstance(payload, dict)
                or not isinstance(payload.get("rows"), list)
                or type(payload.get("lines")) is not int
                or not isinstance(payload.get("status"), str)
                or not isinstance(payload.get("counters"), dict)):
            return ([], 0, "unreadable", empty)
        rows = []
        for row in payload["rows"]:
            if (not isinstance(row, list) or len(row) != 4
                    or not all(isinstance(value, str) for value in row[:3])
                    or (row[3] is not None and not isinstance(row[3], str))):
                return ([], 0, "unreadable", empty)
            rows.append((row[0], row[1], row[2], row[3]))
        counters = {
            "rows_omitted_by_limit_at_least": int(payload["counters"].get(
                "rows_omitted_by_limit_at_least", 0)),
            "paths_omitted_by_size": int(payload["counters"].get(
                "paths_omitted_by_size", 0)),
            "timestamps_omitted_by_size": int(payload["counters"].get(
                "timestamps_omitted_by_size", 0)),
        }
        return (rows, payload["lines"], payload["status"], counters)
    finally:
        try:
            os.close(read_descriptor)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Inverted index
# ---------------------------------------------------------------------------

def _store_failure(store: str) -> dict:
    return {
        "records": [],
        "status": {
            "store": store,
            "status": "truncated",
            "count": 0,
            "unrecognized": 1,
        },
        "eligible_count": 0,
    }


def _collector_payload(
        home: Path, collector, store: str, max_sessions: int) -> bytes:
    records, status = collector(home)
    eligible = [
        record for record in records
        if isinstance(record, dict) and record.get("kind") == "session"
    ]
    eligible.sort(key=lambda record: record.get("last_active") or 0,
                  reverse=True)
    safe: list[dict] = []
    omitted = 0
    for record in eligible[:max_sessions]:
        source = record.get("source")
        tool = record.get("tool")
        active = record.get("last_active")
        if (not isinstance(source, str) or not _path_within_limit(source)
                or not isinstance(tool, str) or _utf8_size(tool) is None
                or _utf8_size(tool) > 128
                or not isinstance(active, (int, float))):
            omitted += 1
            continue
        safe.append({
            "kind": "session",
            "source": source,
            "tool": tool,
            "last_active": active,
            # Collectors do not expose a uniform provider session id.  The
            # source leaf is useful to humans, while the full source identity
            # is retained below only as a bounded digest for collision safety.
            "session_id": source.rsplit("/", 1)[-1].rsplit(".", 1)[0],
        })
    safe_status = status if isinstance(status, dict) else {}
    safe_status = {
        "store": store,
        "status": safe_status.get("status", "unrecognized"),
        "count": int(safe_status.get("count", len(records))),
        "unrecognized": int(safe_status.get("unrecognized", 0)) + omitted,
    }
    if omitted and safe_status["status"] in ("ok", "missing"):
        safe_status["status"] = "truncated"
    payload = {
        "records": safe,
        "status": safe_status,
        "eligible_count": len(eligible),
    }
    encoded = json.dumps(
        payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    # A high caller cap can still exceed the transport budget. Retain the
    # newest prefix and make the loss explicit rather than blocking on a full
    # pipe or letting one provider dominate memory.
    while len(encoded) > DISCOVERY_MAX_OUTPUT_BYTES and safe:
        removed = max(1, len(safe) // 4)
        del safe[-removed:]
        safe_status["status"] = "truncated"
        safe_status["unrecognized"] += removed
        encoded = json.dumps(
            payload, ensure_ascii=False,
            separators=(",", ":")).encode("utf-8")
    if len(encoded) > DISCOVERY_MAX_OUTPUT_BYTES:
        return json.dumps(
            _store_failure(store), separators=(",", ":")).encode("utf-8")
    return encoded


def _collect_stores_isolated(
        home: Path, max_sessions: int, deadline: float,
        ) -> tuple[dict, dict]:
    """Collect both providers in sibling workers under one wall-clock bound."""
    specifications = (
        ("Claude", collect_claude),
        ("Codex", collect_codex),
    )
    workers: dict[int, dict] = {}
    results = {store: _store_failure(store) for store, _ in specifications}
    if time.monotonic() >= deadline:
        return (results["Claude"], results["Codex"])

    for store, collector in specifications:
        read_descriptor = -1
        write_descriptor = -1
        try:
            read_descriptor, write_descriptor = os.pipe()
            pid = os.fork()
        except OSError:
            for descriptor in (read_descriptor, write_descriptor):
                if descriptor >= 0:
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass
            continue
        if pid == 0:
            try:
                os.close(read_descriptor)
                payload = _collector_payload(
                    home, collector, store, max_sessions)
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
        if not _prepare_isolated_reader(
                read_descriptor, write_descriptor, pid):
            continue
        workers[pid] = {
            "store": store,
            "descriptor": read_descriptor,
            "chunks": [],
            "bytes": 0,
            "eof": False,
            "reaped": False,
            "success": False,
            "oversized": False,
        }

    try:
        while workers:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            descriptors = [worker["descriptor"] for worker in workers.values()
                           if not worker["eof"]]
            ready = select.select(
                descriptors, [], [], min(0.05, remaining))[0] if descriptors else []
            for descriptor in ready:
                worker = next(item for item in workers.values()
                              if item["descriptor"] == descriptor)
                try:
                    chunk = os.read(descriptor, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    worker["eof"] = True
                    continue
                worker["bytes"] += len(chunk)
                if worker["bytes"] > DISCOVERY_MAX_OUTPUT_BYTES:
                    worker["oversized"] = True
                else:
                    worker["chunks"].append(chunk)
            finished: list[int] = []
            for pid, worker in workers.items():
                if not worker["reaped"]:
                    try:
                        waited, status = os.waitpid(pid, os.WNOHANG)
                    except ChildProcessError:
                        waited, status = pid, None
                    if waited == pid:
                        worker["reaped"] = True
                        worker["success"] = (
                            status is not None
                            and os.WIFEXITED(status)
                            and os.WEXITSTATUS(status) == 0)
                if worker["reaped"] and worker["eof"]:
                    finished.append(pid)
            for pid in finished:
                worker = workers.pop(pid)
                os.close(worker["descriptor"])
                if worker["oversized"] or not worker["success"]:
                    continue
                try:
                    payload = json.loads(
                        b"".join(worker["chunks"]).decode("utf-8"))
                except (ValueError, UnicodeError, RecursionError):
                    continue
                if (not isinstance(payload, dict)
                        or not isinstance(payload.get("records"), list)
                        or not isinstance(payload.get("status"), dict)
                        or type(payload.get("eligible_count")) is not int):
                    continue
                results[worker["store"]] = payload
    finally:
        for pid, worker in list(workers.items()):
            if not worker["reaped"]:
                _terminate_worktree_worker(pid)
            try:
                os.close(worker["descriptor"])
            except OSError:
                pass
    return (results["Claude"], results["Codex"])


def build_index(home: Path, *, max_sessions: int = DEFAULT_MAX_SESSIONS) -> dict:
    index_deadline = time.monotonic() + max(0.0, INDEX_SCAN_BUDGET_SECONDS)
    claude_result, codex_result = _collect_stores_isolated(
        home, max_sessions, index_deadline)
    claude_records = claude_result["records"]
    claude_status = claude_result["status"]
    codex_records = codex_result["records"]
    codex_status = codex_result["status"]

    sessions = [r for r in claude_records + codex_records if r.get("kind") == "session"]
    sessions.sort(key=lambda r: r.get("last_active") or 0, reverse=True)
    eligible_count = (
        claude_result["eligible_count"] + codex_result["eligible_count"])
    skipped = max(0, eligible_count - max_sessions)
    sessions = sessions[:max_sessions]

    by_path: dict[str, dict] = {}
    scanned = 0
    unreadable = truncated = timed_out = parse_errors = leaked_workers = 0
    skipped_by_budget = skipped_by_row_limit = 0
    rows_indexed = rows_omitted_at_least = 0
    paths_omitted_by_size = timestamps_omitted_by_size = retained_bytes = 0
    row_limit_reached = retained_byte_limit_reached = False
    aggregation_timed_out = False
    for position, record in enumerate(sessions):
        now = time.monotonic()
        if now >= index_deadline:
            skipped_by_budget = len(sessions) - position
            break
        source = Path(record["source"])
        rows, _, scan_status, scan_counters = _scan_transcript_isolated(
            source, record["tool"],
            min(
                index_deadline,
                now + max(0.0, SESSION_SCAN_BUDGET_SECONDS),
            ),
        )
        if scan_status == "time":
            timed_out += 1
        elif scan_status == "truncated":
            truncated += 1
        elif scan_status == "parse":
            parse_errors += 1
        elif scan_status == "worker-leaked":
            # A worker stuck in an uninterruptible kernel wait cannot be
            # synchronously reaped.  Surface that separately; folding it into
            # a generic read failure would hide a process-lifecycle problem.
            unreadable += 1
            leaked_workers += 1
        elif scan_status != "ok":
            unreadable += 1
        rows_omitted_at_least += int(
            scan_counters["rows_omitted_by_limit_at_least"])
        paths_omitted_by_size += int(
            scan_counters["paths_omitted_by_size"])
        timestamps_omitted_by_size += int(
            scan_counters["timestamps_omitted_by_size"])
        supplied_session_id = record.get("session_id")
        if not isinstance(supplied_session_id, str) or not supplied_session_id:
            supplied_session_id = source.stem
        # A stem alone aliases Claude and Codex sessions named ``shared`` and
        # aliases live/archived Codex sources.  Include provider plus a bounded
        # digest of the stable source identity; never retain another copy of a
        # potentially long path in every aggregate row.
        source_identity = hashlib.sha256(
            os.fsencode(os.path.normpath(str(source)))).hexdigest()[:12]
        session_id = (
            f"{record['tool']}:{supplied_session_id}#{source_identity}")
        for row_position, (op, tool_name, raw_path, ts) in enumerate(rows):
            if time.monotonic() >= index_deadline:
                aggregation_timed_out = True
                timed_out += scan_status != "time"
                rows_omitted_at_least += len(rows) - row_position
                break
            if rows_indexed >= MAX_TOTAL_ROWS:
                row_limit_reached = True
                rows_omitted_at_least += len(rows) - row_position
                break
            path = canonical_path(raw_path, home)
            if not path:
                continue
            path_bytes = _utf8_size(path)
            if path_bytes is None or path_bytes > MAX_PATH_BYTES:
                paths_omitted_by_size += 1
                continue
            entry = by_path.get(path)
            additional_bytes = 0
            if entry is None:
                additional_bytes += path_bytes + 512
                entry = {
                    "path": path,
                    "rule_surface": is_rule_surface(path),
                    "reads": 0, "writes": 0, "shell": 0,
                    "tools": set(), "sessions": set(),
                    "last_ts": None,
                }
            if tool_name not in entry["tools"]:
                additional_bytes += (_utf8_size(tool_name) or 128) + 16
            if session_id not in entry["sessions"]:
                additional_bytes += (_utf8_size(session_id) or 256) + 16
            timestamp_delta = 0
            if ts and (entry["last_ts"] is None or ts > entry["last_ts"]):
                timestamp_delta = ((_utf8_size(ts) or MAX_TIMESTAMP_BYTES) + 16
                                   - ((_utf8_size(entry["last_ts"]) or 0) + 16
                                      if entry["last_ts"] is not None else 0))
            if (retained_bytes + additional_bytes
                    + max(0, timestamp_delta) > MAX_RETAINED_BYTES):
                retained_byte_limit_reached = True
                rows_omitted_at_least += len(rows) - row_position
                break
            if path not in by_path:
                by_path[path] = entry
            retained_bytes += additional_bytes + timestamp_delta
            rows_indexed += 1
            entry["reads" if op == "read" else "writes" if op == "write" else "shell"] += 1
            entry["tools"].add(tool_name)
            entry["sessions"].add(session_id)
            if ts and (entry["last_ts"] is None or ts > entry["last_ts"]):
                entry["last_ts"] = ts
        scanned += 1
        if aggregation_timed_out:
            skipped_by_budget = len(sessions) - position - 1
            break
        if row_limit_reached or retained_byte_limit_reached:
            skipped_by_row_limit = len(sessions) - position - 1
            break

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
            "session_ids_omitted": max(0, len(entry["sessions"]) - 20),
            "last_ts": entry["last_ts"],
        })
    # Rule surfaces first, then breadth of exposure, then total touches: the
    # order the contamination question is actually asked in.
    paths.sort(key=lambda p: (not p["rule_surface"], -p["session_count"],
                              -(p["reads"] + p["writes"] + p["shell"]), p["path"]))

    stores = [claude_status, codex_status]
    incomplete_stores = sorted(
        store["store"] for store in stores
        if (store.get("status") not in ("ok", "missing")
            or int(store.get("unrecognized", 0)) > 0)
    )
    content_complete = (
        not incomplete_stores
        and skipped == 0
        and unreadable == 0
        and parse_errors == 0
        and truncated == 0
        and timed_out == 0
        and leaked_workers == 0
        and skipped_by_budget == 0
        and skipped_by_row_limit == 0
        and not row_limit_reached
        and not retained_byte_limit_reached
        and not aggregation_timed_out
        and paths_omitted_by_size == 0
        and timestamps_omitted_by_size == 0
    )

    return {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime()),
        "stores": stores,
        "sessions_scanned": scanned,
        "sessions_skipped_by_cap": skipped,
        "content_scan": {
            "complete": content_complete,
            "incomplete_stores": incomplete_stores,
            "unreadable_sessions": unreadable,
            "parse_error_sessions": parse_errors,
            "truncated_sessions": truncated,
            "timed_out_sessions": timed_out,
            "leaked_worker_sessions": leaked_workers,
            "sessions_skipped_by_budget": skipped_by_budget,
            "sessions_skipped_by_row_limit": skipped_by_row_limit,
            "rows_indexed": rows_indexed,
            # Exact omission counts require continuing to decode data after a
            # safety bound fires. This is the number directly observed, so its
            # lower-bound semantics remain honest under per-session truncation.
            "rows_omitted_by_limit_at_least": rows_omitted_at_least,
            "paths_omitted_by_size": paths_omitted_by_size,
            "timestamps_omitted_by_size": timestamps_omitted_by_size,
            "retained_bytes": retained_bytes,
            "row_limit_reached": row_limit_reached,
            "retained_byte_limit_reached": retained_byte_limit_reached,
        },
        "path_count": len(paths),
        "rule_surface_count": sum(1 for p in paths if p["rule_surface"]),
        "paths": paths,
        "evidence": "preview",
        "requires_revalidation": True,
    }


def filter_paths(
        index: dict, *, query: Optional[str], rule_only: bool,
        home: Optional[Path] = None,
        ) -> list[dict]:
    paths = index["paths"]
    if rule_only:
        paths = [p for p in paths if p["rule_surface"]]
    if query:
        canonical_query = canonical_path(query, home) if home is not None else query
        masked_query = (mask_text(canonical_query, home)
                        if home is not None else canonical_query)
        needle = masked_query.lower()
        paths = [p for p in paths if needle in p["path"].lower()]
    return paths


def render_report(index: dict, paths: list[dict], limit: int) -> str:
    lines = ["파일 접근 역색인 (읽기 전용)", ""]
    lines.append(f"세션 {index['sessions_scanned']}개 · 경로 {index['path_count']}개 "
                 f"· 규칙 표면 {index['rule_surface_count']}개")
    if index["sessions_skipped_by_cap"]:
        lines.append(f"상한으로 건너뛴 세션 {index['sessions_skipped_by_cap']}개 "
                     "(--max-sessions 로 조정)")
    content_scan = index.get("content_scan", {})
    if not content_scan.get("complete", True):
        lines.append(
            "콘텐츠 범위 불완전 · 저장소 "
            f"{len(content_scan.get('incomplete_stores', []))} · 읽기 실패 "
            f"{content_scan.get('unreadable_sessions', 0)} · 잘림 "
            f"{content_scan.get('truncated_sessions', 0)} · JSON 실패 "
            f"{content_scan.get('parse_error_sessions', 0)} · 시간 초과 "
            f"{content_scan.get('timed_out_sessions', 0)} · 미시도 "
            f"{content_scan.get('leaked_worker_sessions', 0)} · 작업자 미회수 "
            f"{content_scan.get('sessions_skipped_by_budget', 0)} · 행 상한 "
            f"{content_scan.get('row_limit_reached', False)} · 경로 크기 생략 "
            f"{content_scan.get('paths_omitted_by_size', 0)} · 시각 크기 생략 "
            f"{content_scan.get('timestamps_omitted_by_size', 0)} · 보존 바이트 상한 "
            f"{content_scan.get('retained_byte_limit_reached', False)}"
        )
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


def _bounded_json_result(
        index: dict, paths: list[dict], *, query: Optional[str],
        rule_only: bool, limit: int,
        ) -> bytes:
    retained = paths[:limit]
    payload = {
        **index,
        "paths": retained,
        "filters": {"query": query, "rule_only": rule_only},
        "result_limit": limit,
        "results_omitted_by_output_limit": len(paths) - len(retained),
    }
    encoded = json.dumps(
        payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    while len(encoded) > MAX_JSON_OUTPUT_BYTES and retained:
        retained.pop()
        payload["results_omitted_by_output_limit"] += 1
        encoded = json.dumps(
            payload, ensure_ascii=False,
            separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_JSON_OUTPUT_BYTES:
        raise ValueError("fileaccess metadata exceeds the JSON output limit")
    return encoded


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
    if args.max_sessions < 1:
        parser.error("--max-sessions must be at least 1")
    if args.limit < 1 or args.limit > MAX_RESULT_LIMIT:
        parser.error(f"--limit must be between 1 and {MAX_RESULT_LIMIT}")

    index = build_index(args.home, max_sessions=args.max_sessions)
    paths = filter_paths(
        index, query=args.query, rule_only=not args.all, home=args.home)

    if args.json:
        encoded = _bounded_json_result(
            index, paths, query=args.query, rule_only=not args.all,
            limit=args.limit)
        sys.stdout.buffer.write(encoded + b"\n")
    else:
        print(render_report(index, paths, args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
