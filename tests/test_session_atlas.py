#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""session_atlas 계약 테스트: 교차 도구 조인, 고아 판정, 보존 판정, 메타데이터 전용 보장."""
import json
import os
import time

import pytest

import session_atlas


def _jsonl(*objs) -> str:
    return "\n".join(json.dumps(obj) for obj in objs) + "\n"


def _write(path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


@pytest.fixture
def atlas_home(tmp_path):
    """가짜 홈: 5개 도구가 같은 워크스페이스를 만졌고, Claude 세션 하나는 고아."""
    home = tmp_path / "home"
    ws1 = tmp_path / "work" / "proj-a"
    ws1.mkdir(parents=True)
    ws2 = tmp_path / "gone" / "proj-b"  # 일부러 만들지 않음 → 고아

    _write(home / ".codex" / "sessions" / "2026" / "08" / "rollout-1.jsonl", _jsonl(
        {"timestamp": "2026-08-01T10:00:00Z", "type": "session_meta", "payload": {
            "id": "s1", "cwd": str(ws1),
            "git": {"branch": "main", "commit_hash": "abc",
                    "repository_url": "git@github.com:heznpc/proj-a.git"}}},
        {"type": "response_item", "payload": {"content": "SECRET_CODEX_CONTENT"}},
    ))
    _write(home / ".claude" / "projects" / str(ws1).replace("/", "-") / "a.jsonl", _jsonl(
        {"type": "summary", "customTitle": "t", "sessionId": "c1"},
        {"type": "user", "cwd": str(ws1), "gitBranch": "main",
         "message": {"content": "SECRET_CLAUDE_CONTENT"}},
    ))
    _write(home / ".claude" / "projects" / str(ws1).replace("/", "-")
           / "c1" / "subagents" / "agent-x.jsonl", _jsonl(
        {"type": "assistant", "message": {"content": "SECRET_SUBAGENT_CONTENT"}},
    ))
    _write(home / ".claude" / "projects" / str(ws2).replace("/", "-") / "b.jsonl", _jsonl(
        {"type": "user", "cwd": str(ws2)},
    ))
    for fork_dir in ("Code", "Kiro"):
        _write(home / "Library" / "Application Support" / fork_dir / "User"
               / "workspaceStorage" / "h1" / "workspace.json",
               json.dumps({"folder": ws1.as_uri()}))
    _write(home / ".gemini" / "projects.json",
           json.dumps({"projects": {str(ws1): {}}}))
    return home, ws1, ws2


def test_cross_tool_group_joins_by_repo(atlas_home):
    home, ws1, _ = atlas_home
    atlas = session_atlas.build_atlas(home)
    group = next(g for g in atlas["groups"] if g["key"] == "github.com/heznpc/proj-a")
    assert group["grouped_by"] == "repo"
    assert set(group["tools"]) == {"Codex", "Claude", "VS Code", "Kiro", "Gemini"}
    assert group["tools"]["Claude"] == 1  # weight-0 subtranscript aggregate must not inflate
    assert group["cross_tool"] is True
    assert group["orphan"] is False
    assert group["workspaces"] == [str(ws1)]


def test_subtranscripts_counted_by_size_without_opening(atlas_home):
    home, _, _ = atlas_home
    atlas = session_atlas.build_atlas(home)
    claude_store = next(s for s in atlas["stores"] if s["store"] == "Claude")
    assert claude_store["count"] == 2
    assert claude_store["subtranscripts"] == 1
    group = next(g for g in atlas["groups"] if g["key"] == "github.com/heznpc/proj-a")
    assert group["size_bytes"] > 0


def test_orphan_workspace_is_flagged(atlas_home):
    home, _, ws2 = atlas_home
    atlas = session_atlas.build_atlas(home)
    group = next(g for g in atlas["groups"] if g["key"] == f"ws:{ws2}")
    assert group["orphan"] is True
    assert group["cross_tool"] is False


def test_atlas_never_carries_session_content(atlas_home):
    home, _, _ = atlas_home
    dumped = json.dumps(session_atlas.build_atlas(home), ensure_ascii=False)
    assert "SECRET_CODEX_CONTENT" not in dumped
    assert "SECRET_CLAUDE_CONTENT" not in dumped
    assert "SECRET_SUBAGENT_CONTENT" not in dumped
    assert "customTitle" not in dumped


def test_store_statuses_report_missing_tools(atlas_home):
    home, _, _ = atlas_home
    atlas = session_atlas.build_atlas(home)
    by_name = {s["store"]: s for s in atlas["stores"]}
    assert by_name["Cursor"]["status"] == "missing"
    assert by_name["Codex"]["count"] == 1
    assert by_name["Claude"]["count"] == 2


@pytest.fixture
def retention_home(tmp_path):
    """보존 판정용: 나이가 통제된 Claude 세션 5개와 살아있는/사라진 워크스페이스."""
    home = tmp_path / "home"
    ws_live = tmp_path / "alive" / "proj"
    ws_live.mkdir(parents=True)
    ws_gone = tmp_path / "gone" / "proj"  # 일부러 만들지 않음
    now = time.time()

    def session(name, workspace, age_days):
        path = (home / ".claude" / "projects"
                / str(workspace).replace("/", "-") / f"{name}.jsonl")
        _write(path, _jsonl({"type": "user", "cwd": str(workspace)}))
        stamp = now - age_days * 86400
        os.utime(path, (stamp, stamp))

    session("s30", ws_live, 30)   # 관측 최고령 → 윈도우 앵커, D-0
    session("s24", ws_live, 24)   # D-6: 살아있는 이야기의 만료 임박
    session("s25", ws_gone, 25)   # D-5: 고아의 만료 임박
    session("s02a", ws_live, 2)   # 안전
    session("s02b", ws_live, 2)
    return home, ws_live, ws_gone


def test_retention_infers_rolling_window(retention_home):
    home, _, _ = retention_home
    retention = session_atlas.build_atlas(home)["retention"]
    claude = next(s for s in retention["stores"] if s["store"] == "Claude")
    assert claude["mode"] == "rolling"
    assert claude["window_days"] == 30
    assert claude["stalled"] is False


def test_retention_flags_precarious_boundary(retention_home):
    home, ws_live, ws_gone = retention_home
    expiring = session_atlas.build_atlas(home)["retention"]["expiring"]
    assert len(expiring) == 3  # D-0, D-6(살아있음), D-5(고아) — 신선한 세션은 제외
    assert expiring[0]["days_left"] == 0  # 임박순 정렬
    alive = [e for e in expiring if e["story_alive"]]
    assert {e["workspace"] for e in alive} == {str(ws_live)}
    gone = next(e for e in expiring if not e["story_alive"])
    assert gone["workspace"] == str(ws_gone)
    assert gone["days_left"] == 5


def test_retention_insufficient_on_small_stores(atlas_home):
    home, _, _ = atlas_home
    retention = session_atlas.build_atlas(home)["retention"]
    claude = next(s for s in retention["stores"] if s["store"] == "Claude")
    assert claude["mode"] == "insufficient"
    assert retention["expiring"] == []


@pytest.mark.parametrize("raw,expected", [
    ("git@github.com:heznpc/proj-a.git", "github.com/heznpc/proj-a"),
    ("https://github.com/heznpc/proj-a.git", "github.com/heznpc/proj-a"),
    ("ssh://git@github.com:22/heznpc/proj-a", "github.com/heznpc/proj-a"),
])
def test_repo_url_normalization(raw, expected):
    assert session_atlas.normalize_repo_url(raw) == expected
