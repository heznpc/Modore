#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fileaccess 계약 테스트.

canary의 `get_file_access`를 옮기면서 지켜야 할 두 가지를 고정한다:
명령문 본문은 절대 나가지 않는다는 것(원본은 200자 발췌를 붙였다), 그리고
같은 파일이 표기 차이로 여러 행이 되지 않는다는 것(역색인의 존재 이유).
"""
import json
from pathlib import Path

import fileaccess


def _claude_session(home: Path, session_id: str, workspace: str, lines: list[dict]) -> Path:
    project = home / ".claude" / "projects" / workspace.replace("/", "-")
    project.mkdir(parents=True, exist_ok=True)
    path = project / f"{session_id}.jsonl"
    path.write_text("\n".join(json.dumps(line) for line in lines), encoding="utf-8")
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
    assert sorted(row["session_ids"]) == ["s1", "s2"]


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


def test_the_module_never_writes_and_never_deletes():
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
