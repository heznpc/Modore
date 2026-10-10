#!/usr/bin/env python3
"""Bounded, local evidence extraction for explicitly selected JSONL files.

Unlike the session-search reader, evaluation needs physical line references,
tool/result pairs and provenance for injected context. This adapter never
searches stores, executes transcript text, or exports hidden reasoning.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat

from scree import mask_text

MAX_BYTES = 64 * 1024 * 1024
MAX_LINE = 1024 * 1024
CONTEXT_PREFIXES = (
    "# AGENTS.md", "<environment_context>", "<external_", "<task-notification",
    "<system-reminder>", "<command-", "<local-command", "[Request interrupted",
    "This session is being continued from a previous conversation",
)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def text_content(value: object) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(b["text"] for b in value if isinstance(b, dict)
                         and b.get("type") in ("text", "input_text", "output_text")
                         and isinstance(b.get("text"), str))
    return ""


def serialized(value: object) -> str:
    return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)


def decode(row: dict, metadata: dict, counts: dict) -> list[dict]:
    """Normalize visible events; metadata/context are never user instructions."""
    kind = row.get("type")
    payload = row.get("payload")
    if not isinstance(payload, dict):
        payload = {}
    if kind == "session_meta":
        metadata["providers"].add("codex")
        metadata["session_ids"].add(str(payload.get("id") or "unknown"))
        metadata["subagent"] |= isinstance(payload.get("source"), dict)
        return []
    if kind == "turn_context":
        if isinstance(payload.get("model"), str):
            metadata["models"].add(payload["model"])
        return []
    if kind in ("compacted", "compact_boundary") or row.get("isCompactSummary"):
        counts["compactions"] += 1
        return [{"role": "context", "text": "[Compaction; earlier context may be missing]"}]
    if row.get("isVisibleInTranscriptOnly"):
        counts["injected_rows"] += 1
        return []
    if kind == "event_msg":
        event = payload.get("type")
        if event in ("user_message", "agent_message"):
            return [{"role": "user" if event == "user_message" else "assistant",
                     "text": payload.get("message", ""), "stream": "event_msg",
                     "channel": payload.get("phase")}]
        if event in ("agent_reasoning", "reasoning"):
            counts["hidden_reasoning_rows"] += 1
        return []
    if kind == "response_item":
        metadata["providers"].add("codex")
        item = payload.get("type")
        if item == "message":
            role = payload.get("role")
            if role not in ("user", "assistant") or payload.get("channel") in ("analysis", "summary"):
                counts["excluded_context_rows"] += 1
                return []
            return [{"role": role, "text": text_content(payload.get("content")),
                     "stream": "response_item", "channel": payload.get("channel") or payload.get("phase")}]
        if item == "agent_message":
            return [{"role": "agent_report", "text": text_content(payload.get("content")),
                     "name": payload.get("author")}]
        if item in ("function_call", "custom_tool_call", "function_call_output", "custom_tool_call_output"):
            call = not item.endswith("output")
            output = payload.get("output", "")
            if (not call and payload.get("name") == "create_thread" and isinstance(output, str)
                    and output.lstrip().startswith("<codex_delegation>")):
                match = re.search(r"<input>([\s\S]*?)</input>", output)
                if match:
                    metadata["delegated_input"] = True
                    return [{"role": "delegated_prompt", "text": match.group(1),
                             "name": "create_thread", "authorship": "delegated; not a direct human prompt"}]
            return [{"role": "tool_call" if call else "tool_result",
                     "text": serialized(payload.get("arguments", payload.get("input", ""))
                                        if call else payload.get("output", "")),
                     "name": payload.get("name"), "call_id": payload.get("call_id")}]
        if item == "reasoning":
            counts["hidden_reasoning_rows"] += 1
        else:
            counts["unsupported_response_items"] += 1
        return []
    message = row.get("message")
    if kind in ("user", "assistant") and isinstance(message, dict):
        metadata["providers"].add("claude")
        if row.get("sessionId"):
            metadata["session_ids"].add(str(row["sessionId"]))
        if isinstance(message.get("model"), str):
            metadata["models"].add(message["model"])
        metadata["subagent"] |= bool(row.get("isSidechain"))
        result = []
        content = message.get("content")
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        if not isinstance(content, list):
            counts["unsupported_message_content"] += 1
            return []
        for block in content:
            if not isinstance(block, dict):
                counts["unsupported_message_content"] += 1
                continue
            block_type = block.get("type")
            if block_type == "text":
                result.append({"role": kind, "text": block.get("text", "")})
            elif block_type == "tool_use":
                result.append({"role": "tool_call", "text": serialized(block.get("input", {})),
                               "name": block.get("name"), "call_id": block.get("id")})
            elif block_type == "tool_result":
                result.append({"role": "tool_result", "text": text_content(block.get("content")),
                               "call_id": block.get("tool_use_id"), "is_error": block.get("is_error")})
            elif block_type in ("thinking", "redacted_thinking"):
                counts["hidden_reasoning_rows"] += 1
            else:
                counts["unsupported_message_content"] += 1
        return result
    counts["other_metadata_rows"] += 1
    return []


def read_evidence(source: Path, *, home: Path, excerpt_chars: int = 4000,
                  max_events: int = 10000, max_bytes: int = MAX_BYTES) -> dict:
    counts = dict.fromkeys(("malformed_lines", "oversized_lines", "duplicates",
                            "compactions", "injected_rows", "excluded_context_rows",
                            "hidden_reasoning_rows", "unsupported_response_items",
                            "unsupported_message_content", "other_metadata_rows",
                            "clipped_events", "omitted_events"), 0)
    metadata = {"providers": set(), "models": set(), "session_ids": set(),
                "subagent": False, "delegated_input": False}
    events: list[dict] = []
    fingerprint = hashlib.sha256()
    seen_uuids: set[str] = set()
    previous_message = None
    bytes_read = 0
    line_number = 0
    byte_limit = False
    changed = False
    fd = os.open(source, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as handle:
        before = os.fstat(handle.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("source must be a regular JSONL file")
        while True:
            raw = handle.readline(min(MAX_LINE + 1, max_bytes - bytes_read + 1))
            if not raw:
                break
            line_number += 1
            bytes_read += len(raw)
            fingerprint.update(raw)
            if bytes_read > max_bytes:
                byte_limit = True
                break
            if len(raw) > MAX_LINE:
                counts["oversized_lines"] += 1
                while raw and not raw.endswith(b"\n"):
                    raw = handle.readline(min(MAX_LINE + 1, max_bytes - bytes_read + 1))
                    bytes_read += len(raw)
                    fingerprint.update(raw)
                    if bytes_read > max_bytes:
                        byte_limit = True
                        break
                if byte_limit:
                    break
                continue
            if not raw.strip():
                continue
            try:
                row = json.loads(raw)
                if not isinstance(row, dict):
                    raise ValueError("not an object")
            except (ValueError, UnicodeError, RecursionError):
                counts["malformed_lines"] += 1
                continue
            uuid = row.get("uuid")
            if isinstance(uuid, str):
                if uuid in seen_uuids:
                    counts["duplicates"] += 1
                    continue
                seen_uuids.add(uuid)
            decoded = decode(row, metadata, counts)
            for slot, event in enumerate(decoded):
                text = event.get("text")
                if not isinstance(text, str) or not text.strip():
                    continue
                role = event["role"]
                text_hash = digest(text)
                # Collapse only matching alternate Codex representations. A
                # repeated message on the same channel is a real event.
                if role in ("user", "assistant"):
                    key = (role, text_hash, event.get("stream"), False)
                    if (previous_message and previous_message[:2] == key[:2]
                            and previous_message[2] != key[2]
                            and previous_message[2] and key[2] and not previous_message[3]):
                        counts["duplicates"] += 1
                        previous_message = (*key[:3], True)
                        continue
                    previous_message = key
                if role == "user" and text.lstrip().startswith(CONTEXT_PREFIXES):
                    role = "context"
                    counts["injected_rows"] += 1
                    text = "[Injected instructions, environment, or continuation; excluded from prompt scoring]"
                masked = mask_text(text, home)
                clipped = len(masked) > excerpt_chars
                if len(events) >= max_events:
                    counts["omitted_events"] += 1
                    continue
                counts["clipped_events"] += int(clipped)
                event.update(id=f"L{line_number}:{slot}", line=line_number, role=role,
                             text=masked[:excerpt_chars], clipped=clipped,
                             timestamp=row.get("timestamp"),
                             replay_key=digest(str(row.get("timestamp")) + text_hash)
                             if row.get("timestamp") else None)
                for key in ("name", "call_id", "channel", "stream"):
                    if event.get(key) is not None:
                        event[key] = mask_text(str(event[key]), home)[:200]
                events.append(event)
        after = os.fstat(handle.fileno())
        changed = (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_size, after.st_mtime_ns, after.st_ctime_ns)
    gaps = [name for name in ("malformed_lines", "oversized_lines", "unsupported_response_items",
                              "unsupported_message_content", "clipped_events", "omitted_events")
            if counts[name]]
    if byte_limit:
        gaps.append("byte_limit")
    if changed:
        gaps.append("source_changed_during_read")
    if not metadata["providers"]:
        gaps.append("unrecognized_provider")
    call_ids = {e.get("call_id") for e in events if e["role"] == "tool_call" and e.get("call_id")}
    result_ids = {e.get("call_id") for e in events if e["role"] == "tool_result" and e.get("call_id")}
    return {
        "source": mask_text(str(source.absolute()), home),
        "source_sha256": fingerprint.hexdigest() if not (byte_limit or changed) else None,
        "observed_bytes_sha256": fingerprint.hexdigest(), "source_bytes": before.st_size,
        "metadata": {k: sorted(v) if isinstance(v, set) else v for k, v in metadata.items()},
        "coverage": {"status": "partial" if gaps else "complete_for_supported_events",
                     "gaps": gaps, "counts": counts, "physical_lines_read": line_number,
                     "unmatched_tool_calls": len(call_ids - result_ids),
                     "unmatched_tool_results": len(result_ids - call_ids),
                     "scope": "one physical file; other fragments and subagents are not followed"},
        "events": events,
    }
