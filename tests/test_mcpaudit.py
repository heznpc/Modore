#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mcpaudit 계약 테스트: 읽기 전용, env 무접촉, 그리고 확인 못 한 것은 단정하지 않기."""
import json
import os
import stat
from pathlib import Path

import mcpaudit


def _write_config(home: Path, servers: dict, *, name: str = ".claude.json",
                  wrapper: str = "root") -> Path:
    path = home / name
    path.parent.mkdir(parents=True, exist_ok=True)
    block = {"mcpServers": servers}
    document = block if wrapper == "root" else {"projects": {"/some/proj": block}}
    path.write_text(json.dumps(document), encoding="utf-8")
    return path


def _executable(home: Path, name: str) -> Path:
    bindir = home / "bin"
    bindir.mkdir(parents=True, exist_ok=True)
    target = bindir / name
    target.write_text("#!/bin/sh\n", encoding="utf-8")
    target.chmod(target.stat().st_mode | stat.S_IXUSR)
    return target


def _report(home: Path, path_dirs=()) -> dict:
    env = {"PATH": os.pathsep.join(str(p) for p in path_dirs)} if path_dirs else {"PATH": ""}
    return mcpaudit.build_report(home, env=env)


# ---------------------------------------------------------------------------
# 발견
# ---------------------------------------------------------------------------

def test_servers_nested_under_projects_are_found(tmp_path):
    """~/.claude.json은 프로젝트별 블록 아래 서버를 중첩한다. 루트만 읽으면
    이 머신 서버 대부분을 놓친다."""
    _write_config(tmp_path, {"nested": {"command": "node"}}, wrapper="projects")
    report = _report(tmp_path, [_executable(tmp_path, "node").parent])
    assert report["server_count"] == 1


def test_an_absent_config_set_is_not_an_error(tmp_path):
    report = _report(tmp_path)
    assert report["configs"] == []
    assert report["findings"] == []


def test_an_unparseable_config_is_reported_not_swallowed(tmp_path):
    (tmp_path / ".claude.json").write_text("{not json", encoding="utf-8")
    report = _report(tmp_path)
    assert report["config_errors"]
    assert "unreadable" in report["config_errors"][0]["error"]


# ---------------------------------------------------------------------------
# 판정
# ---------------------------------------------------------------------------

def test_a_command_that_does_not_resolve_is_dead(tmp_path):
    _write_config(tmp_path, {"gone": {"command": "definitely-not-installed"}})
    report = _report(tmp_path, [_executable(tmp_path, "node").parent])
    assert [(f["server"], f["status"]) for f in report["findings"]] == [("gone", "dead")]
    assert "command-not-found" in report["findings"][0]["reasons"]


def test_a_missing_script_argument_is_dead(tmp_path):
    bindir = _executable(tmp_path, "node").parent
    _write_config(tmp_path, {"stale": {"command": "node",
                                       "args": [str(tmp_path / "deleted" / "server.mjs")]}})
    report = _report(tmp_path, [bindir])
    assert report["findings"][0]["status"] == "dead"
    assert "local-path-missing" in report["findings"][0]["reasons"]


def test_two_entries_with_the_same_command_and_args_are_duplicates(tmp_path):
    bindir = _executable(tmp_path, "node").parent
    script = tmp_path / "s.mjs"
    script.write_text("", encoding="utf-8")
    _write_config(tmp_path, {"a": {"command": "node", "args": [str(script)]},
                             "b": {"command": "node", "args": [str(script)]}})
    report = _report(tmp_path, [bindir])
    assert {f["status"] for f in report["findings"]} == {"duplicate"}
    assert {f["server"] for f in report["findings"]} == {"a", "b"}


def test_a_healthy_server_produces_no_finding(tmp_path):
    bindir = _executable(tmp_path, "node").parent
    script = tmp_path / "s.mjs"
    script.write_text("", encoding="utf-8")
    _write_config(tmp_path, {"fine": {"command": "node", "args": [str(script)]}})
    report = _report(tmp_path, [bindir])
    assert report["findings"] == []
    assert report["summary"]["healthy"] == 1


def test_a_remote_server_is_not_judged_dead_for_having_no_command(tmp_path):
    """URL 서버의 도달성은 네트워크 질문이고, Modore는 네트워크를 만지지 않는다."""
    _write_config(tmp_path, {"remote": {"url": "https://example.invalid/mcp"}})
    assert _report(tmp_path, [tmp_path])["findings"] == []


# ---------------------------------------------------------------------------
# fail-safe — 확인하지 못한 것은 단정하지 않는다
# ---------------------------------------------------------------------------

def test_without_a_usable_path_a_bare_command_is_withheld_not_called_dead(tmp_path):
    _write_config(tmp_path, {"maybe": {"command": "node"}})
    report = mcpaudit.build_report(tmp_path, env={"PATH": ""})
    finding = report["findings"][0]
    assert finding["status"] == "unknown"
    assert finding["reasons"] == ["path-unavailable-cannot-check-command"]
    assert report["path_available"] is False


def test_an_absolute_command_is_still_checkable_without_path(tmp_path):
    target = _executable(tmp_path, "srv")
    _write_config(tmp_path, {"abs": {"command": str(target)}})
    assert mcpaudit.build_report(tmp_path, env={"PATH": ""})["findings"] == []


def test_a_missing_command_key_is_unknown_not_dead(tmp_path):
    _write_config(tmp_path, {"empty": {"args": ["x"]}})
    report = _report(tmp_path, [tmp_path])
    assert report["findings"][0]["status"] == "unknown"
    assert report["findings"][0]["reasons"] == ["missing-command"]


# ---------------------------------------------------------------------------
# 프라이버시 계약
# ---------------------------------------------------------------------------

def test_env_values_and_key_names_are_never_emitted(tmp_path):
    bindir = _executable(tmp_path, "node").parent
    _write_config(tmp_path, {"secretive": {
        "command": "node",
        "env": {"ANTHROPIC_API_KEY": "sk-ant-do-not-leak", "DB_URL": "postgres://u:p@h/db"},
    }})
    report = _report(tmp_path, [bindir])
    blob = json.dumps(report, ensure_ascii=False)

    assert "sk-ant-do-not-leak" not in blob
    assert "postgres://u:p@h/db" not in blob
    assert "ANTHROPIC_API_KEY" not in blob
    assert "DB_URL" not in blob

    finding = report["findings"][0]
    assert finding["status"] == "manual-review"
    assert finding["env_key_count"] == 2


def test_home_paths_are_masked(tmp_path):
    _write_config(tmp_path, {"gone": {"command": "definitely-not-installed"}})
    report = _report(tmp_path, [tmp_path])
    assert report["configs"] == ["~/.claude.json"]
    assert str(tmp_path) not in json.dumps(report, ensure_ascii=False)


def test_the_module_cannot_modify_disable_or_start_anything():
    source = Path(mcpaudit.__file__).read_text(encoding="utf-8")
    for forbidden in ("subprocess", "os.system", "os.remove", "os.unlink",
                      "shutil", "write_text", "write_bytes", "shell=True",
                      "urllib", "socket.", "urlopen", "http.client", "requests."):
        assert forbidden not in source, f"mcpaudit must not use {forbidden}"


def test_every_report_is_labelled_preview_evidence(tmp_path):
    _write_config(tmp_path, {"gone": {"command": "definitely-not-installed"}})
    report = _report(tmp_path, [tmp_path])
    assert report["evidence"] == "preview"
    assert report["requires_revalidation"] is True


def test_the_renderer_states_that_nothing_was_changed(tmp_path):
    _write_config(tmp_path, {"gone": {"command": "definitely-not-installed"}})
    text = mcpaudit.render_report(_report(tmp_path, [tmp_path]), 20)
    assert "설정을 바꾸지 않았고" in text
    assert "불필요하다는 판정이 아닙니다" in text
