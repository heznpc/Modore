#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fileaccess 계약 테스트.

canary의 `get_file_access`를 옮기면서 지켜야 할 두 가지를 고정한다:
명령문 본문은 절대 나가지 않는다는 것(원본은 200자 발췌를 붙였다), 그리고
같은 파일이 표기 차이로 여러 행이 되지 않는다는 것(역색인의 존재 이유).
"""
import json
import os
import signal
import subprocess
import sys
import time
import tracemalloc
from pathlib import Path

import pytest

import fileaccess
import scree


def _claude_session(home: Path, session_id: str, workspace: str, lines: list[dict]) -> Path:
    project = home / ".claude" / "projects" / workspace.replace("/", "-")
    project.mkdir(parents=True, exist_ok=True)
    path = project / f"{session_id}.jsonl"
    path.write_text("\n".join(json.dumps(line) for line in lines), encoding="utf-8")
    return path


def _codex_session(home: Path, session_id: str, workspace: str,
                   lines: list[dict]) -> Path:
    root = home / ".codex" / "sessions" / "2026" / "08" / "01"
    root.mkdir(parents=True, exist_ok=True)
    path = root / f"{session_id}.jsonl"
    records = [{
        "type": "session_meta",
        "payload": {"id": session_id, "cwd": workspace, "git": {}},
    }, *lines]
    path.write_text("\n".join(json.dumps(line) for line in records),
                    encoding="utf-8")
    return path


def _tool_use(tool: str, payload: dict, *, block_id: str, ts: str = "2026-08-01T00:00:00Z",
              message_id: str = "msg1") -> dict:
    return {
        "timestamp": ts,
        "cwd": "/tmp/ws",
        "message": {"id": message_id, "role": "assistant",
                    "content": [{"type": "tool_use", "id": block_id,
                                 "name": tool, "input": payload}]},
    }


# ---------------------------------------------------------------------------
# 규칙 표면 분류 (canary types.ts에서 그대로 옮김)
# ---------------------------------------------------------------------------

def test_rule_basenames_and_directory_markers_are_flagged():
    for path in ("/a/CLAUDE.md", "/a/AGENTS.md", "/a/settings.json",
                 "/a/config.toml", "/home/x/.claude/anything",
                 "/home/x/.codex/sessions/s.jsonl",
                 "/repo/.github/instructions/x.md"):
        assert fileaccess.is_rule_surface(path), path


def test_ordinary_source_files_are_not_flagged():
    for path in ("/a/main.py", "/a/README.md", "/a/claude.md.bak"):
        assert not fileaccess.is_rule_surface(path), path


# ---------------------------------------------------------------------------
# 명령문에서 경로 추출
# ---------------------------------------------------------------------------

def test_urls_are_not_mistaken_for_paths():
    assert fileaccess.paths_in_command("curl https://example.com/a/b") == []


def test_trailing_punctuation_is_trimmed_and_results_are_capped():
    assert fileaccess.paths_in_command("cat /etc/hosts, /tmp/a.txt.") == [
        "/etc/hosts", "/tmp/a.txt"]
    many = " ".join(f"/tmp/f{i}" for i in range(20))
    assert len(fileaccess.paths_in_command(many)) == fileaccess.COMMAND_PATH_CAP


@pytest.mark.parametrize("provider", ["Claude", "Codex"])
def test_command_path_cap_marks_transcript_coverage_incomplete(
        tmp_path, provider):
    command = "cat " + " ".join(f"/tmp/f{number}" for number in range(10))
    if provider == "Claude":
        source = _claude_session(tmp_path, "capped", "/tmp/ws", [
            _tool_use("Bash", {"command": command}, block_id="cap")])
    else:
        source = _codex_session(tmp_path, "capped", "/tmp/ws", [{
            "type": "response_item",
            "payload": {
                "type": "function_call", "name": "exec_command",
                "arguments": json.dumps({"cmd": command}),
            },
        }])

    rows, _, status, _ = fileaccess._scan_transcript_bounded(
        source, provider)

    assert len(rows) == fileaccess.COMMAND_PATH_CAP
    assert status == "truncated"
    index = fileaccess.build_index(tmp_path)
    assert index["content_scan"]["complete"] is False
    assert index["content_scan"]["truncated_sessions"] == 1


@pytest.mark.parametrize("tool,payload", [
    ("Read", {"file_path": {"forged": "/tmp/not-a-read"}}),
    ("Bash", {"command": {"forged": "/tmp/not-a-command"}}),
])
def test_claude_known_nested_field_type_errors_are_parse_failures(
        tmp_path, tool, payload):
    source = _claude_session(tmp_path, "malformed", "/tmp/ws", [
        _tool_use(tool, payload, block_id="bad")])

    rows, _, status, _ = fileaccess._scan_transcript_bounded(
        source, "Claude")

    assert rows == []
    assert status == "parse"


@pytest.mark.parametrize("arguments", [
    {"cmd": {"forged": "/tmp/not-a-command"}},
    {"command": ["cat", {"forged": "/tmp/not-an-argument"}]},
    {"cmd": "cat /tmp/real", "workdir": {"forged": "/tmp/not-workdir"}},
])
def test_codex_known_nested_field_type_errors_do_not_index_repr_paths(
        arguments):
    entries, status = fileaccess._codex_entries_bounded({
        "payload": {
            "type": "function_call", "name": "exec_command",
            "arguments": json.dumps(arguments),
        }
    }, "/repo")

    assert entries == []
    assert status == "parse"


def test_codex_apply_patch_indexes_update_add_delete_and_move_without_content():
    patch = """*** Begin Patch
*** Update File: src/old.py
@@
-PRIVATE_OLD
+PRIVATE_NEW
*** Move to: src/moved.py
*** Add File: src/new.py
+SECRET_ADD
*** Delete File: src/gone.py
*** End Patch"""
    line = {
        "payload": {
            "type": "custom_tool_call",
            "name": "apply_patch",
            "call_id": "call-1",
            "input": patch,
        }
    }

    entries, status = fileaccess._codex_entries_bounded(line, "/repo")

    assert status == "ok"
    assert {(op, path) for op, _, path, _ in entries} == {
        ("read", "/repo/src/old.py"),
        ("write", "/repo/src/old.py"),
        ("write", "/repo/src/moved.py"),
        ("write", "/repo/src/new.py"),
        ("read", "/repo/src/gone.py"),
        ("write", "/repo/src/gone.py"),
    }
    assert "PRIVATE" not in json.dumps(entries)
    assert "SECRET" not in json.dumps(entries)


@pytest.mark.parametrize("patch", [
    "*** Begin Patch\n*** Move to: orphan.py\n*** End Patch",
    "*** Begin Patch\n*** Rename File: old.py\n*** End Patch",
    "*** Update File: missing-begin.py\n*** End Patch",
])
def test_codex_apply_patch_malformed_headers_make_coverage_incomplete(patch):
    entries, status = fileaccess._codex_entries_bounded({
        "payload": {
            "type": "custom_tool_call", "name": "apply_patch",
            "call_id": "bad", "input": patch,
        }
    }, "/repo")

    assert status == "parse"
    assert entries == []


# ---------------------------------------------------------------------------
# 경로 정규화 — 역색인이 한 파일을 한 줄로 보여주기 위한 조건
# ---------------------------------------------------------------------------

def test_one_file_is_one_row_whatever_the_transcript_spelled(tmp_path):
    """도구 입력은 절대경로로, 셸 명령은 틸데로 같은 파일을 가리킨다."""
    settings = tmp_path / ".claude" / "settings.json"
    _claude_session(tmp_path, "s1", "/tmp/ws", [
        _tool_use("Read", {"file_path": str(settings)}, block_id="b1"),
        _tool_use("Bash", {"command": "cat ~/.claude/settings.json"}, block_id="b2"),
        _tool_use("Bash", {"command": "ls ~/.claude/"}, block_id="b3"),
        _tool_use("Bash", {"command": "ls ~/.claude"}, block_id="b4"),
    ])
    index = fileaccess.build_index(tmp_path)
    rows = {p["path"]: p for p in index["paths"]}

    assert rows["~/.claude/settings.json"]["reads"] == 1
    assert rows["~/.claude/settings.json"]["shell"] == 1
    assert rows["~/.claude"]["shell"] == 2  # 후행 슬래시 유무가 갈라지지 않는다


# ---------------------------------------------------------------------------
# 집계
# ---------------------------------------------------------------------------

def test_reads_writes_and_shell_are_counted_separately(tmp_path):
    _claude_session(tmp_path, "s1", "/tmp/ws", [
        _tool_use("Read", {"file_path": "/tmp/ws/a.py"}, block_id="b1"),
        _tool_use("Edit", {"file_path": "/tmp/ws/a.py"}, block_id="b2"),
        _tool_use("Bash", {"command": "wc -l /tmp/ws/a.py"}, block_id="b3"),
    ])
    row = fileaccess.build_index(tmp_path)["paths"][0]
    assert (row["reads"], row["writes"], row["shell"]) == (1, 1, 1)
    assert row["session_count"] == 1
    assert sorted(row["tools"]) == ["Bash", "Edit", "Read"]


def test_a_streamed_duplicate_block_is_counted_once_but_a_real_repeat_is_not(tmp_path):
    """Claude는 한 메시지를 여러 줄로 흘려 쓰므로 같은 블록이 두 번 읽힌다.
    블록 id로 잡아야지, 경로로 잡으면 진짜 두 번째 읽기까지 사라진다."""
    duplicated = _tool_use("Read", {"file_path": "/tmp/ws/a.py"}, block_id="same")
    genuine_repeat = _tool_use("Read", {"file_path": "/tmp/ws/a.py"}, block_id="other")
    _claude_session(tmp_path, "s1", "/tmp/ws", [duplicated, duplicated, genuine_repeat])

    assert fileaccess.build_index(tmp_path)["paths"][0]["reads"] == 2


def test_sessions_touching_the_same_path_are_joined(tmp_path):
    for session in ("s1", "s2"):
        _claude_session(tmp_path, session, "/tmp/ws", [
            _tool_use("Read", {"file_path": "/tmp/ws/CLAUDE.md"}, block_id=f"{session}-b")])
    row = fileaccess.build_index(tmp_path)["paths"][0]
    assert row["session_count"] == 2
    assert {value.split("#", 1)[0] for value in row["session_ids"]} == {
        "Claude:s1", "Claude:s2"}


def test_same_stem_from_different_providers_remains_two_sessions(tmp_path):
    target = "/tmp/ws/shared.py"
    _claude_session(tmp_path, "shared", "/tmp/ws", [
        _tool_use("Read", {"file_path": target}, block_id="claude")])
    _codex_session(tmp_path, "shared", "/tmp/ws", [{
        "timestamp": "2026-08-01T00:00:00Z",
        "payload": {
            "type": "function_call", "name": "exec_command",
            "call_id": "codex", "arguments": json.dumps({
                "cmd": f"cat {target}", "workdir": "/tmp/ws"}),
        },
    }])

    row = next(item for item in fileaccess.build_index(tmp_path)["paths"]
               if item["path"] == target)

    assert row["session_count"] == 2
    assert {value.split(":", 1)[0] for value in row["session_ids"]} == {
        "Claude", "Codex"}


def test_session_id_projection_reports_omitted_ids(tmp_path):
    for number in range(25):
        session = f"s{number:02d}"
        _claude_session(tmp_path, session, "/tmp/ws", [
            _tool_use("Read", {"file_path": "/tmp/ws/shared.py"},
                      block_id=session)])

    row = fileaccess.build_index(tmp_path)["paths"][0]

    assert row["session_count"] == 25
    assert len(row["session_ids"]) == 20
    assert row["session_ids_omitted"] == 5


def test_rule_surfaces_sort_ahead_of_busier_ordinary_files(tmp_path):
    lines = [_tool_use("Read", {"file_path": "/tmp/ws/main.py"}, block_id=f"b{i}")
             for i in range(10)]
    lines.append(_tool_use("Read", {"file_path": "/tmp/ws/CLAUDE.md"}, block_id="rule"))
    _claude_session(tmp_path, "s1", "/tmp/ws", lines)

    assert fileaccess.build_index(tmp_path)["paths"][0]["path"].endswith("CLAUDE.md")


def test_the_newest_timestamp_wins(tmp_path):
    _claude_session(tmp_path, "s1", "/tmp/ws", [
        _tool_use("Read", {"file_path": "/tmp/ws/a.py"}, block_id="b1",
                  ts="2026-01-01T00:00:00Z"),
        _tool_use("Read", {"file_path": "/tmp/ws/a.py"}, block_id="b2",
                  ts="2026-06-01T00:00:00Z"),
    ])
    assert fileaccess.build_index(tmp_path)["paths"][0]["last_ts"] == "2026-06-01T00:00:00Z"


# ---------------------------------------------------------------------------
# 콘텐츠 계약 — 원본과 갈라지는 지점
# ---------------------------------------------------------------------------

def test_the_shell_command_itself_is_never_emitted(tmp_path):
    """canary는 명령문 200자 발췌를 행마다 붙였다. 여기서는 경로만 남는다."""
    _claude_session(tmp_path, "s1", "/tmp/ws", [
        _tool_use("Bash", {"command": "grep -r 'hunter2' /tmp/ws/secrets.txt"},
                  block_id="b1")])
    blob = json.dumps(fileaccess.build_index(tmp_path), ensure_ascii=False)

    assert "/tmp/ws/secrets.txt" in blob
    assert "hunter2" not in blob
    assert "grep" not in blob


def test_assistant_text_and_tool_results_are_never_emitted(tmp_path):
    _claude_session(tmp_path, "s1", "/tmp/ws", [
        {"timestamp": "2026-08-01T00:00:00Z", "cwd": "/tmp/ws",
         "message": {"role": "assistant",
                     "content": [{"type": "text", "text": "SENSITIVE-PROSE"}]}},
        {"timestamp": "2026-08-01T00:00:01Z", "cwd": "/tmp/ws",
         "message": {"role": "user",
                     "content": [{"type": "tool_result", "content": "TOOL-OUTPUT"}]}},
        _tool_use("Read", {"file_path": "/tmp/ws/a.py"}, block_id="b1"),
    ])
    blob = json.dumps(fileaccess.build_index(tmp_path), ensure_ascii=False)
    assert "SENSITIVE-PROSE" not in blob
    assert "TOOL-OUTPUT" not in blob


def test_non_path_tool_inputs_are_not_retained(tmp_path):
    _claude_session(tmp_path, "s1", "/tmp/ws", [
        _tool_use("Grep", {"path": "/tmp/ws", "pattern": "MY-SECRET-REGEX"},
                  block_id="b1")])
    assert "MY-SECRET-REGEX" not in json.dumps(fileaccess.build_index(tmp_path))


def test_home_paths_are_masked(tmp_path):
    _claude_session(tmp_path, "s1", "/tmp/ws", [
        _tool_use("Read", {"file_path": str(tmp_path / "notes.md")}, block_id="b1")])
    index = fileaccess.build_index(tmp_path)
    assert index["paths"][0]["path"] == "~/notes.md"
    assert str(tmp_path) not in json.dumps(index)


def test_absolute_and_tilde_queries_find_the_same_masked_home_path(tmp_path):
    target = tmp_path / ".claude" / "settings.json"
    _claude_session(tmp_path, "s1", "/tmp/ws", [
        _tool_use("Read", {"file_path": str(target)}, block_id="b1")])
    index = fileaccess.build_index(tmp_path)

    absolute = fileaccess.filter_paths(
        index, query=str(target), rule_only=False, home=tmp_path)
    tilde = fileaccess.filter_paths(
        index, query="~/.claude/settings.json", rule_only=False,
        home=tmp_path)

    assert absolute == tilde
    assert len(absolute) == 1


def test_nested_subagent_transcripts_are_never_opened(tmp_path):
    """scree의 수집기 규약과 동일하다."""
    project = tmp_path / ".claude" / "projects" / "-tmp-ws"
    nested = project / "parent-session" / "tool-results"
    nested.mkdir(parents=True)
    (nested / "sub.jsonl").write_text(json.dumps(
        _tool_use("Read", {"file_path": "/tmp/ws/NESTED-ONLY.py"}, block_id="n1")),
        encoding="utf-8")
    _claude_session(tmp_path, "s1", "/tmp/ws", [
        _tool_use("Read", {"file_path": "/tmp/ws/a.py"}, block_id="b1")])

    assert "NESTED-ONLY" not in json.dumps(fileaccess.build_index(tmp_path))


@pytest.mark.parametrize("kind", ["symlink", "hardlink", "fifo"])
def test_transcript_scan_rejects_links_and_special_files_without_blocking(
        tmp_path, kind):
    source = tmp_path / "session.jsonl"
    if kind in ("symlink", "hardlink"):
        outside = tmp_path / "outside.jsonl"
        outside.write_text(json.dumps(
            _tool_use("Read", {"file_path": "/tmp/SECRET"}, block_id="x")),
            encoding="utf-8",
        )
        if kind == "symlink":
            source.symlink_to(outside)
        else:
            os.link(outside, source)
    else:
        os.mkfifo(source)

    started = time.monotonic()
    rows, lines, status, _ = fileaccess._scan_transcript_bounded(
        source, "Claude")

    assert time.monotonic() - started < 1.0
    assert rows == [] and lines == 0
    assert status == "unrecognized"


def test_transcript_scan_rejects_a_leaf_replaced_during_read(
        tmp_path, monkeypatch):
    source = tmp_path / "session.jsonl"
    source.write_text(json.dumps(
        _tool_use("Read", {"file_path": "/tmp/original"}, block_id="x")),
        encoding="utf-8",
    )
    held = tmp_path / "held.jsonl"
    original_extract = fileaccess._claude_entries
    replaced = False

    def replace_before_yield(line, line_key="direct"):
        nonlocal replaced
        if not replaced:
            source.rename(held)
            source.write_text(json.dumps(
                _tool_use("Read", {"file_path": "/tmp/replacement"},
                          block_id="y")), encoding="utf-8")
            replaced = True
        yield from original_extract(line, line_key)

    monkeypatch.setattr(fileaccess, "_claude_entries", replace_before_yield)

    rows, lines, status, _ = fileaccess._scan_transcript_bounded(
        source, "Claude")

    assert replaced is True
    assert rows == [] and lines == 0
    assert status == "unreadable"


def test_oversized_transcript_and_line_are_reported_incomplete(
        tmp_path, monkeypatch):
    monkeypatch.setattr(fileaccess, "MAX_BYTES_PER_SESSION", 512)
    monkeypatch.setattr(fileaccess, "MAX_LINE_BYTES", 128)
    source = _claude_session(tmp_path, "large", "/tmp/ws", [])
    source.write_bytes(
        json.dumps(_tool_use(
            "Read", {"file_path": "/tmp/SHOULD-NOT-APPEAR"},
            block_id="x")).encode()
        + (b"x" * 1024)
    )

    index = fileaccess.build_index(tmp_path)

    assert index["paths"] == []
    assert index["content_scan"]["complete"] is False
    assert index["content_scan"]["truncated_sessions"] == 1


def test_expired_content_budget_is_reported_instead_of_claiming_coverage(
        tmp_path, monkeypatch):
    _claude_session(tmp_path, "slow", "/tmp/ws", [
        _tool_use("Read", {"file_path": "/tmp/a"}, block_id="x")])
    monkeypatch.setattr(fileaccess, "SESSION_SCAN_BUDGET_SECONDS", 0.0)

    index = fileaccess.build_index(tmp_path)

    assert index["paths"] == []
    assert index["content_scan"]["complete"] is False
    assert index["content_scan"]["timed_out_sessions"] == 1
    assert index["content_scan"]["sessions_skipped_by_budget"] == 0


def test_store_special_file_makes_content_coverage_incomplete(tmp_path):
    fifo = tmp_path / ".claude" / "projects" / "-tmp-ws" / "blocked.jsonl"
    fifo.parent.mkdir(parents=True)
    os.mkfifo(fifo)

    index = fileaccess.build_index(tmp_path)

    assert index["sessions_scanned"] == 0
    assert index["content_scan"]["complete"] is False
    assert index["content_scan"]["incomplete_stores"] == ["Claude"]


def test_json_parse_failure_is_not_reported_as_complete_absence(tmp_path):
    source = _claude_session(tmp_path, "damaged", "/tmp/ws", [
        _tool_use("Read", {"file_path": "/tmp/visible"}, block_id="x")])
    with source.open("a", encoding="utf-8") as handle:
        handle.write("\n{damaged-json\n")

    index = fileaccess.build_index(tmp_path)

    assert index["path_count"] == 1
    assert index["content_scan"]["parse_error_sessions"] == 1
    assert index["content_scan"]["complete"] is False


@pytest.mark.parametrize("payload", ["[]", "null", '"text"'])
def test_valid_json_non_object_is_a_parse_failure(tmp_path, payload):
    source = _claude_session(tmp_path, "wrong-shape", "/tmp/ws", [])
    source.write_text(payload + "\n", encoding="utf-8")

    index = fileaccess.build_index(tmp_path)

    assert index["content_scan"]["parse_error_sessions"] == 1
    assert index["content_scan"]["complete"] is False


def test_apply_patch_parse_failure_is_not_reported_as_complete_absence(tmp_path):
    source = tmp_path / "codex.jsonl"
    source.write_text(json.dumps({
        "timestamp": "2026-08-01T00:00:00Z",
        "payload": {
            "type": "custom_tool_call", "name": "apply_patch",
            "input": "*** Begin Patch\n*** Rename File: bad.py\n*** End Patch",
        },
    }), encoding="utf-8")

    rows, _, status, _ = fileaccess._scan_transcript_bounded(
        source, "Codex")

    assert rows == []
    assert status == "parse"


@pytest.mark.parametrize("arguments", ["[]", "null", '"text"', ["x"]])
def test_codex_known_command_with_non_object_arguments_is_parse_failure(
        tmp_path, arguments):
    source = tmp_path / "codex-malformed.jsonl"
    source.write_text(json.dumps({
        "payload": {"type": "function_call", "name": "exec_command",
                    "arguments": arguments},
    }), encoding="utf-8")

    rows, _, status, _ = fileaccess._scan_transcript_bounded(source, "Codex")

    assert rows == []
    assert status == "parse"


@pytest.mark.parametrize("payload", ["text", ["not", "an", "object"], None])
def test_claude_known_tool_with_non_object_input_is_parse_failure(
        tmp_path, payload):
    source = tmp_path / "claude-malformed.jsonl"
    source.write_text(json.dumps({
        "message": {"content": [{"type": "tool_use", "name": "Read",
                                  "input": payload}]},
    }), encoding="utf-8")

    rows, _, status, _ = fileaccess._scan_transcript_bounded(source, "Claude")

    assert rows == []
    assert status == "parse"


def test_provider_discovery_itself_is_hard_deadline_isolated(
        tmp_path, monkeypatch):
    def blocked(_home):
        time.sleep(5)
        raise AssertionError("discovery worker should have been terminated")

    monkeypatch.setattr(fileaccess, "collect_claude", blocked)
    monkeypatch.setattr(fileaccess, "INDEX_SCAN_BUDGET_SECONDS", 0.05)
    started = time.monotonic()

    index = fileaccess.build_index(tmp_path)

    assert time.monotonic() - started < 1.0
    claude = next(store for store in index["stores"]
                  if store["store"] == "Claude")
    assert claude["status"] == "truncated"
    assert index["content_scan"]["complete"] is False


def test_second_provider_pipe_failure_does_not_close_first_worker_fd(
        tmp_path, monkeypatch):
    _claude_session(tmp_path, "alive", "/tmp/ws", [
        _tool_use("Read", {"file_path": "/tmp/alive.py"}, block_id="x")])
    original_pipe = fileaccess.os.pipe
    calls = 0

    def fail_second_pipe():
        nonlocal calls
        calls += 1
        if calls == 2:
            raise OSError(24, "too many open files")
        return original_pipe()

    monkeypatch.setattr(fileaccess.os, "pipe", fail_second_pipe)

    index = fileaccess.build_index(tmp_path)

    assert any(row["path"] == "/tmp/alive.py" for row in index["paths"])
    codex = next(store for store in index["stores"]
                 if store["store"] == "Codex")
    assert codex["status"] == "truncated"


@pytest.mark.parametrize("helper", ["content", "discovery"])
def test_post_fork_reader_setup_failure_closes_fds_and_reaps_workers(
        tmp_path, monkeypatch, helper):
    real_pipe = os.pipe
    real_fork = os.fork
    pipes: list[tuple[int, int]] = []
    child_pids: list[int] = []

    def tracked_pipe():
        pair = real_pipe()
        pipes.append(pair)
        return pair

    def tracked_fork():
        pid = real_fork()
        if pid > 0:
            child_pids.append(pid)
        return pid

    def fail_nonblocking(_descriptor, _blocking):
        raise OSError("injected nonblocking setup failure")

    monkeypatch.setattr(fileaccess.os, "pipe", tracked_pipe)
    monkeypatch.setattr(fileaccess.os, "fork", tracked_fork)
    monkeypatch.setattr(fileaccess.os, "set_blocking", fail_nonblocking)

    if helper == "content":
        rows, _, status, _ = fileaccess._scan_transcript_isolated(
            tmp_path / "unused.jsonl", "Claude", time.monotonic() + 2)
        assert rows == []
        assert status == "unreadable"
    else:
        claude, codex = fileaccess._collect_stores_isolated(
            tmp_path, 1, time.monotonic() + 2)
        assert claude["status"]["status"] == "truncated"
        assert codex["status"]["status"] == "truncated"

    assert child_pids
    for pid in child_pids:
        with pytest.raises(ChildProcessError):
            os.waitpid(pid, os.WNOHANG)
    for pair in pipes:
        for descriptor in pair:
            with pytest.raises(OSError):
                os.fstat(descriptor)


def test_setup_failure_reaps_descendant_forked_after_first_tree_snapshot(
        tmp_path, monkeypatch):
    go = tmp_path / "fork-now"
    forker_pid_file = tmp_path / "forker.pid"
    late_pid_file = tmp_path / "late.pid"
    real_snapshot = scree._process_descendants
    snapshot_calls = 0

    forker_code = r'''
import pathlib
import subprocess
import sys
import time
go = pathlib.Path(sys.argv[1])
late = pathlib.Path(sys.argv[2])
while not go.exists():
    time.sleep(0.001)
child = subprocess.Popen(["/bin/sleep", "30"])
late_staging = late.with_name(late.name + ".tmp")
late_staging.write_text(str(child.pid), encoding="utf-8")
late_staging.replace(late)
time.sleep(30)
'''

    def worker_that_forks(*_args, **_kwargs):
        forker = subprocess.Popen([
            sys.executable, "-I", "-B", "-c", forker_code,
            str(go), str(late_pid_file),
        ])
        forker_staging = forker_pid_file.with_name(forker_pid_file.name + ".tmp")
        forker_staging.write_text(str(forker.pid), encoding="utf-8")
        forker_staging.replace(forker_pid_file)
        time.sleep(30)
        raise AssertionError("setup cleanup must kill the worker")

    def wait_then_fail_nonblocking(_descriptor, _blocking):
        deadline = time.monotonic() + 2
        while not forker_pid_file.exists() and time.monotonic() < deadline:
            time.sleep(0.001)
        raise OSError("injected nonblocking setup failure")

    def snapshot_then_allow_late_fork(pid):
        nonlocal snapshot_calls
        snapshot = real_snapshot(pid)
        snapshot_calls += 1
        if snapshot_calls == 1:
            # The returned snapshot is intentionally stale: the already-seen
            # child forks one more generation immediately after it was taken.
            go.write_text("go", encoding="utf-8")
            deadline = time.monotonic() + 2
            while not late_pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.001)
        return snapshot

    monkeypatch.setattr(
        fileaccess, "_scan_transcript_bounded", worker_that_forks)
    monkeypatch.setattr(scree, "_process_descendants", snapshot_then_allow_late_fork)
    monkeypatch.setattr(fileaccess.os, "set_blocking", wait_then_fail_nonblocking)

    rows, lines, status, _ = fileaccess._scan_transcript_isolated(
        tmp_path / "unused.jsonl", "Claude", time.monotonic() + 5)

    assert rows == [] and lines == 0 and status == "unreadable"
    assert snapshot_calls >= 2
    assert forker_pid_file.exists() and late_pid_file.exists()
    descendants = [
        int(forker_pid_file.read_text(encoding="utf-8")),
        int(late_pid_file.read_text(encoding="utf-8")),
    ]
    try:
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            if all(not scree._pid_exists(pid) for pid in descendants):
                break
            time.sleep(0.01)
        assert all(not scree._pid_exists(pid) for pid in descendants)
    finally:
        for pid in descendants:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def test_content_open_is_behind_the_hard_deadline_process_boundary(
        tmp_path, monkeypatch):
    source = _claude_session(tmp_path, "slow", "/tmp/ws", [
        _tool_use("Read", {"file_path": "/tmp/a"}, block_id="x")])
    record = {"kind": "session", "source": str(source), "tool": "Claude",
              "last_active": source.stat().st_mtime, "session_id": "slow"}
    ok = {"records": [record],
          "status": {"store": "Claude", "status": "ok", "count": 1,
                     "unrecognized": 0}, "eligible_count": 1}
    missing = {"records": [],
               "status": {"store": "Codex", "status": "missing", "count": 0,
                          "unrecognized": 0}, "eligible_count": 0}
    monkeypatch.setattr(fileaccess, "_collect_stores_isolated",
                        lambda *_args: (ok, missing))

    def blocked_open(_path):
        time.sleep(5)
        raise AssertionError("content worker should have been terminated")

    monkeypatch.setattr(fileaccess, "_open_regular_nofollow", blocked_open)
    monkeypatch.setattr(fileaccess, "INDEX_SCAN_BUDGET_SECONDS", 0.08)
    monkeypatch.setattr(fileaccess, "SESSION_SCAN_BUDGET_SECONDS", 0.05)
    started = time.monotonic()

    index = fileaccess.build_index(tmp_path)

    assert time.monotonic() - started < 1.0
    assert index["content_scan"]["timed_out_sessions"] == 1
    assert index["content_scan"]["complete"] is False


def test_content_timeout_reaps_a_killable_descendant(
        tmp_path, monkeypatch):
    descendant_file = tmp_path / "descendant.pid"

    def spawn_then_block(*_args, **_kwargs):
        child = subprocess.Popen(["/bin/sleep", "30"])
        descendant_file.write_text(str(child.pid), encoding="utf-8")
        time.sleep(30)
        return ([], 0, "ok", {})

    monkeypatch.setattr(fileaccess, "_scan_transcript_bounded",
                        spawn_then_block)
    _, _, status, _ = fileaccess._scan_transcript_isolated(
        tmp_path / "ignored.jsonl", "Claude", time.monotonic() + 0.10)

    assert status == "time"
    descendant = int(descendant_file.read_text(encoding="utf-8"))
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        try:
            os.kill(descendant, 0)
        except ProcessLookupError:
            break
        time.sleep(0.01)
    else:
        os.kill(descendant, signal.SIGKILL)
        pytest.fail("content timeout left a killable descendant")


def test_root_group_sigkill_reaches_fileaccess_content_descendant(tmp_path):
    marker = tmp_path / "descendant.pid"
    program = r'''
import os
import pathlib
import subprocess
import sys
import time
sys.path.insert(0, sys.argv[1])
import fileaccess

marker = pathlib.Path(sys.argv[2])
def blocked(*_args, **_kwargs):
    child = subprocess.Popen(["/bin/sleep", "30"])
    marker.write_text(str(child.pid), encoding="utf-8")
    time.sleep(30)
    return ([], 0, "ok", {})
fileaccess._scan_transcript_bounded = blocked
fileaccess._scan_transcript_isolated(
    pathlib.Path("/tmp/ignored.jsonl"), "Claude", time.monotonic() + 30)
'''
    process = subprocess.Popen(
        [sys.executable, "-c", program,
         str(Path(fileaccess.__file__).parent), str(marker)],
        start_new_session=True,
    )
    descendant = None
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if marker.exists():
                descendant = int(marker.read_text(encoding="utf-8"))
                break
            if process.poll() is not None:
                pytest.fail(f"fileaccess reproducer exited: {process.returncode}")
            time.sleep(0.01)
        assert descendant is not None
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            try:
                os.kill(descendant, 0)
            except ProcessLookupError:
                break
            time.sleep(0.01)
        else:
            pytest.fail("root-group SIGKILL left fileaccess descendant")
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=1)
        if descendant is not None:
            try:
                os.kill(descendant, signal.SIGKILL)
            except ProcessLookupError:
                pass


def test_reaped_signal_exited_collector_is_not_terminated_again(
        tmp_path, monkeypatch):
    original = fileaccess._collector_payload
    terminated: list[int] = []

    def exits_by_signal(home, collector, store, max_sessions):
        if store == "Claude":
            os.kill(os.getpid(), signal.SIGTERM)
        return original(home, collector, store, max_sessions)

    monkeypatch.setattr(fileaccess, "_collector_payload", exits_by_signal)
    monkeypatch.setattr(
        fileaccess, "_terminate_worktree_worker",
        lambda pid, **_kwargs: terminated.append(pid) or True)

    index = fileaccess.build_index(tmp_path)

    assert terminated == []
    assert index["content_scan"]["incomplete_stores"] == ["Claude"]


def test_idless_megabyte_tool_payload_does_not_become_a_dedupe_key(
        tmp_path, monkeypatch):
    monkeypatch.setattr(fileaccess, "MAX_LINE_BYTES", 2 * 1024 * 1024)
    source = tmp_path / "idless.jsonl"
    secret = "S" * (1024 * 1024)
    records = [
        _tool_use("Bash", {"command": f"cat /tmp/a {secret}"},
                  block_id="placeholder")
        for _ in range(4)
    ]
    for record in records:
        del record["message"]["content"][0]["id"]
    source.write_text("\n".join(json.dumps(item) for item in records),
                      encoding="utf-8")

    tracemalloc.start()
    rows, _, status, _ = fileaccess._scan_transcript_bounded(
        source, "Claude")
    _, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()

    assert status == "ok"
    assert len(rows) == 4
    assert peak < 20 * 1024 * 1024


def test_many_megabyte_paths_are_dropped_before_retention_and_stdout(
        tmp_path, monkeypatch):
    monkeypatch.setattr(fileaccess, "MAX_LINE_BYTES", 2 * 1024 * 1024)
    monkeypatch.setattr(fileaccess, "MAX_BYTES_PER_SESSION", 2 * 1024 * 1024)
    huge = "/" + ("x" * (1024 * 1024))
    for number in range(4):
        _claude_session(tmp_path, f"huge-{number}", "/tmp/ws", [
            _tool_use("Read", {"file_path": huge}, block_id=f"h-{number}")])

    index = fileaccess.build_index(tmp_path)
    encoded = fileaccess._bounded_json_result(
        index, index["paths"], query=None, rule_only=False, limit=30)

    assert index["paths"] == []
    assert index["content_scan"]["paths_omitted_by_size"] == 4
    assert index["content_scan"]["complete"] is False
    assert len(encoded) < 10_000


def test_megabyte_timestamps_are_dropped_and_never_escape_retention_accounting(
        tmp_path, monkeypatch):
    monkeypatch.setattr(fileaccess, "MAX_LINE_BYTES", 512 * 1024)
    monkeypatch.setattr(fileaccess, "MAX_BYTES_PER_SESSION", 512 * 1024)
    huge_timestamp = "2" * (256 * 1024)
    for number in range(20):
        _claude_session(tmp_path, f"time-{number}", "/tmp/ws", [{
            **_tool_use(
                "Read", {"file_path": f"/tmp/{number}.py"},
                block_id=f"b-{number}"),
            "timestamp": huge_timestamp,
        }])

    index = fileaccess.build_index(tmp_path)
    encoded = fileaccess._bounded_json_result(
        index, index["paths"], query=None, rule_only=False, limit=100)

    assert index["content_scan"]["timestamps_omitted_by_size"] == 20
    assert index["content_scan"]["complete"] is False
    assert index["content_scan"]["retained_bytes"] < 50_000
    assert len(encoded) < 50_000
    assert huge_timestamp[:1000] not in encoded.decode("utf-8")


def test_aggregate_retention_and_json_projection_have_independent_caps(
        tmp_path, monkeypatch):
    monkeypatch.setattr(fileaccess, "MAX_RETAINED_BYTES", 10_000)
    _claude_session(tmp_path, "many", "/tmp/ws", [
        _tool_use("Read", {"file_path": f"/tmp/{number:03d}.py"},
                  block_id=f"b-{number}")
        for number in range(100)
    ])

    index = fileaccess.build_index(tmp_path)

    assert index["content_scan"]["retained_byte_limit_reached"] is True
    assert index["content_scan"]["complete"] is False
    assert index["path_count"] < 100
    monkeypatch.setattr(fileaccess, "MAX_JSON_OUTPUT_BYTES", 1600)
    encoded = fileaccess._bounded_json_result(
        index, index["paths"], query=None, rule_only=False, limit=500)
    payload = json.loads(encoded)
    assert len(encoded) <= 1600
    assert payload["results_omitted_by_output_limit"] > 0


def test_adversarial_unique_rows_are_bounded_per_session_and_in_total(
        tmp_path, monkeypatch):
    monkeypatch.setattr(fileaccess, "MAX_ROWS_PER_SESSION", 25)
    monkeypatch.setattr(fileaccess, "MAX_TOTAL_ROWS", 30)
    for session in ("one", "two"):
        _claude_session(tmp_path, session, "/tmp/ws", [
            _tool_use(
                "Read", {"file_path": f"/tmp/{session}-{number:03d}"},
                block_id=f"{session}-{number:03d}")
            for number in range(100)
        ])

    index = fileaccess.build_index(tmp_path)

    assert index["path_count"] == 30
    assert index["content_scan"]["rows_indexed"] == 30
    assert index["content_scan"]["row_limit_reached"] is True
    assert index["content_scan"]["rows_omitted_by_limit_at_least"] == 22
    assert index["content_scan"]["truncated_sessions"] == 2
    assert index["content_scan"]["complete"] is False


def test_source_omits_known_filesystem_mutation_primitives():
    source = Path(fileaccess.__file__).read_text(encoding="utf-8")
    for forbidden in ("shutil", "os.remove", "os.unlink", "os.rmdir",
                      "write_text", "write_bytes", "subprocess", "os.system",
                      "shell=True"):
        assert forbidden not in source, f"fileaccess must not use {forbidden}"


# ---------------------------------------------------------------------------
# 상한 · 필터 · 증거 등급
# ---------------------------------------------------------------------------

def test_the_session_cap_is_reported_not_silent(tmp_path):
    for i in range(5):
        _claude_session(tmp_path, f"s{i}", "/tmp/ws", [
            _tool_use("Read", {"file_path": f"/tmp/ws/f{i}.py"}, block_id=f"b{i}")])
    index = fileaccess.build_index(tmp_path, max_sessions=2)
    assert index["sessions_scanned"] == 2
    assert index["sessions_skipped_by_cap"] == 3
    assert index["content_scan"]["complete"] is False


def test_rule_only_is_the_default_view(tmp_path):
    _claude_session(tmp_path, "s1", "/tmp/ws", [
        _tool_use("Read", {"file_path": "/tmp/ws/CLAUDE.md"}, block_id="b1"),
        _tool_use("Read", {"file_path": "/tmp/ws/main.py"}, block_id="b2"),
    ])
    index = fileaccess.build_index(tmp_path)
    assert len(fileaccess.filter_paths(index, query=None, rule_only=True)) == 1
    assert len(fileaccess.filter_paths(index, query=None, rule_only=False)) == 2
    assert len(fileaccess.filter_paths(index, query="main", rule_only=False)) == 1


def test_every_index_is_labelled_preview_evidence(tmp_path):
    index = fileaccess.build_index(tmp_path)
    assert index["evidence"] == "preview"
    assert index["requires_revalidation"] is True


def test_the_renderer_states_that_absence_is_not_proof(tmp_path):
    _claude_session(tmp_path, "s1", "/tmp/ws", [
        _tool_use("Read", {"file_path": "/tmp/ws/CLAUDE.md"}, block_id="b1")])
    index = fileaccess.build_index(tmp_path)
    text = fileaccess.render_report(index, index["paths"], 20)
    assert "건드리지 않았다는 뜻이 아니라" in text
