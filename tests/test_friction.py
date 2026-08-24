#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""friction 계약 테스트: 분류 체계 이식 충실도, 4개 스토어 파서, 내용 노출 경계."""
import json
import subprocess
import sys
import time
from pathlib import Path

import pytest

import friction


def _jsonl(*objs) -> str:
    return "\n".join(json.dumps(obj, ensure_ascii=False) for obj in objs) + "\n"


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _turns(*texts):
    return [(None, text) for text in texts]


def _ref(source="claude", path="/tmp/s.jsonl", workspace=None):
    return {"source": source, "path": path, "workspace": workspace, "last_active": 0.0}


def _findings(*texts, home=Path("/nonexistent-home"), raw=True):
    findings, turns = friction.extract_friction(_turns(*texts), _ref(), home=home,
                                                raw_quotes=raw)
    return findings, turns


# ---------------------------------------------------------------------------
# 분류 체계 (canary lib/sessions/friction.ts 이식)
# ---------------------------------------------------------------------------

def test_taxonomy_is_the_nine_ported_categories():
    assert friction.FRICTION_CATEGORIES == (
        "wrong-action", "no-research-assertion", "stalling-approval",
        "rule-contamination", "over-orchestration-token", "stale-repetition",
        "verbosity", "tone-attitude", "other-ai-friction")


@pytest.mark.parametrize("text,severity", [
    ("이거 시발 왜 이래", 3),
    ("아오 답이 없다", 3),
    ("아니 왜 또 그러냐", 2),
    ("몇 번을 말해야 하나", 2),
    ("아니 그거 말고", 1),
    ("ㄴㄴ 다시", 1),
    ("좋아요 계속 진행해주세요", None),
])
def test_severity_ladder_matches_the_ported_markers(text, severity):
    assert friction.severity_of(text) == severity


def test_correction_marker_only_fires_at_the_turn_opening():
    # CORRECTION_RE is anchored in the original; a mid-sentence "아니" is not
    # pushback ("그건 아니라고 생각해요" is ordinary prose).
    assert friction.severity_of("그건 아니야 라고 봅니다") is None
    assert friction.severity_of("   아니야 그거") == 1


@pytest.mark.parametrize("text,category", [
    ("아니 검색을 해보고 말해", "no-research-assertion"),
    ("아니 왜 자꾸 물어보지 말고 진행하라니까", "stalling-approval"),
    ("아니 CLAUDE.md 오염시켰네", "rule-contamination"),
    ("아니 에이전트를 8개나 돌려서 토큰 낭비함?", "over-orchestration-token"),
    ("아니 몇 번을 말해야 아까 말한 걸 기억하냐", "stale-repetition"),
    ("아니 장황하게 쓰지 말고 요점만", "verbosity"),
    ("아니 그 말투 좀 고쳐", "tone-attitude"),
    ("아니 누가 그거 하래?", "wrong-action"),
    ("아니 그거", "other-ai-friction"),
])
def test_categories_map_to_the_ported_surface_forms(text, category):
    assert friction.category_of(text) == category


def test_category_order_is_first_match_wins():
    # "검색을 해" (no-research-assertion) precedes "누가 ... 하래" (wrong-action)
    # in CATEGORY_RULES, so a turn carrying both resolves to the earlier rule.
    both = "누가 그거 하래? 검색을 해보고 말하라고"
    assert friction.category_of(both) == "no-research-assertion"


# ---------------------------------------------------------------------------
# 턴 선별
# ---------------------------------------------------------------------------

def test_noise_rows_are_not_turns_at_all():
    findings, turns = _findings("<task 알림>", "<command-name>/foo</command-name>",
                                "<local-command-stdout>", "[Request interrupted] 시발")
    assert findings == []
    assert turns == 0


@pytest.mark.parametrize("flag", ["isCompactSummary", "isVisibleInTranscriptOnly"])
def test_rows_the_operator_never_typed_are_not_turns(tmp_path, flag):
    """`/compact` 요약은 type:user 로 저장되지만 본문은 어시스턴트가 쓴 요약이다."""
    home = tmp_path / "home"
    _write(home / ".claude" / "projects" / "-p" / "s.jsonl", _jsonl(
        {"type": "user", "cwd": "/w", "timestamp": "2026-08-01T00:00:00Z", flag: True,
         "message": {"role": "user", "content":
                     "This session is being continued from a previous conversation. "
                     "사용자가 '아니 왜 자꾸 물어만 보냐' 라고 지적했습니다."}},
        {"type": "user", "cwd": "/w", "timestamp": "2026-08-01T00:00:01Z",
         "message": {"role": "user", "content": "아니 누가 그거 하래?"}},
    ))
    report = friction.build_friction(home, raw_quotes=True)
    assert report["user_turns_scanned"] == 1
    assert [f["quote"] for f in report["findings"]] == ["아니 누가 그거 하래?"]


def test_pasted_assistant_report_is_not_operator_pushback():
    pasted = "검토를 완료했습니다. " + "세부 내용은 다음과 같습니다. " * 40 + " 시발"
    assert len(pasted) > 400
    findings, turns = _findings(pasted)
    assert turns == 1
    assert findings == []


def test_retort_appended_after_a_bare_angle_bracket_still_counts():
    pasted = "검토를 완료했습니다. " + "세부 내용은 다음과 같습니다." * 40
    findings, _ = _findings(pasted + "< 이딴 소리 왜 하는 거임 시발")
    assert len(findings) == 1
    # Only the retort segment is quoted, never the pasted assistant payload.
    assert findings[0]["quote"] == "이딴 소리 왜 하는 거임 시발"
    assert "검토를 완료했습니다" not in findings[0]["quote"]


def test_quote_is_whitespace_collapsed_and_capped():
    long_turn = "시발 " + "가" * 400
    findings, _ = _findings(long_turn)
    quote = findings[0]["quote"]
    assert len(quote) == friction.QUOTE_CAP
    assert "\n" not in quote

    findings, _ = _findings("시발\n\n  줄바꿈\t섞임")
    assert findings[0]["quote"] == "시발 줄바꿈 섞임"


# ---------------------------------------------------------------------------
# 내용 노출 경계 (scree의 무내용 계약에 대한 두 번째 명시적 예외)
# ---------------------------------------------------------------------------

def test_quotes_are_masked_by_default_and_raw_only_on_opt_out(tmp_path):
    turn = f"시발 {tmp_path} 에서 me@example.com 로 sk-{'a' * 20} 보냈다"
    masked, _ = friction.extract_friction(_turns(turn), _ref(), home=tmp_path,
                                          raw_quotes=False)
    assert "<email-redacted>" in masked[0]["quote"]
    assert "<api-key-redacted>" in masked[0]["quote"]
    assert str(tmp_path) not in masked[0]["quote"]

    raw, _ = friction.extract_friction(_turns(turn), _ref(), home=tmp_path,
                                       raw_quotes=True)
    assert "me@example.com" in raw[0]["quote"]


def test_masking_never_changes_the_verdict_only_the_quote(tmp_path):
    # Classification runs on the original text; masking is applied at emit time,
    # so a redacted token can never move a finding into another category.
    turn = "아니 me@example.com 로 검색을 해보라니까"  # 라니까 -> severity 2
    masked, _ = friction.extract_friction(_turns(turn), _ref(), home=tmp_path,
                                          raw_quotes=False)
    raw, _ = friction.extract_friction(_turns(turn), _ref(), home=tmp_path,
                                       raw_quotes=True)
    assert masked[0]["category"] == raw[0]["category"] == "no-research-assertion"
    assert masked[0]["severity"] == raw[0]["severity"] == 2


# ---------------------------------------------------------------------------
# 스토어별 파서
# ---------------------------------------------------------------------------

@pytest.fixture
def friction_home(tmp_path):
    """4개 스토어를 모두 가진 가짜 홈. 각 스토어에 friction 턴이 하나씩 있다."""
    home = tmp_path / "home"
    workspace = tmp_path / "work" / "proj"
    workspace.mkdir(parents=True)

    project_dir = home / ".claude" / "projects" / "-proj"
    _write(project_dir / "sess-a.jsonl", _jsonl(
        {"type": "user", "cwd": str(workspace), "gitBranch": "main",
         "timestamp": "2026-08-01T00:00:00Z",
         "message": {"role": "user", "content": "아니 누가 그거 하래?"}},
        {"type": "assistant", "timestamp": "2026-08-01T00:00:01Z",
         "message": {"role": "assistant",
                     "content": [{"type": "text", "text": "죄송합니다 시발 정말"}]}},
        {"type": "user", "timestamp": "2026-08-01T00:00:02Z",
         "message": {"role": "user", "content": [
             {"type": "image", "source": {"data": "AAAA"}},
             {"type": "text", "text": "아니 왜 자꾸 물어만 보냐"}]}},
    ))
    # 중첩 서브에이전트 트랜스크립트: scree가 열지 않는 것과 같이 여기서도 안 연다.
    _write(project_dir / "sub" / "nested.jsonl", _jsonl(
        {"type": "user", "timestamp": "2026-08-01T00:00:03Z",
         "message": {"role": "user", "content": "시발 중첩 턴"}}))

    codex_dir = home / ".codex" / "sessions" / "2026" / "08" / "01"
    _write(codex_dir / "rollout-a.jsonl", _jsonl(
        {"type": "session_meta", "timestamp": "2026-08-01T00:00:00Z",
         "payload": {"id": "cx-1", "cwd": str(workspace),
                     "git": {"repository_url": "git@github.com:o/r.git", "branch": "main"}}},
        {"type": "event_msg", "timestamp": "2026-08-01T00:00:01Z",
         "payload": {"type": "user_message", "message": "아니 장황하게 쓰지 말고 요점만"}},
        {"type": "response_item", "timestamp": "2026-08-01T00:00:01Z",
         "payload": {"type": "message", "role": "user",
                     "content": [{"type": "input_text",
                                  "text": "아니 장황하게 쓰지 말고 요점만"}]}},
    ))

    gemini_chats = home / ".gemini" / "tmp" / "proj-alias" / "chats"
    _write(gemini_chats / "session-a.jsonl", _jsonl(
        {"sessionId": "g-1", "startTime": "2026-08-01T00:00:00Z", "kind": "main"},
        {"$set": {"messages": [
            {"id": "m1", "timestamp": "2026-08-01T00:00:01Z", "type": "user",
             "content": [{"text": "아니 몇 번을 말해야 아까 말한 걸 기억하냐"}]}]}},
        {"id": "m1", "timestamp": "2026-08-01T00:00:01Z", "type": "user",
         "content": [{"text": "아니 몇 번을 말해야 아까 말한 걸 기억하냐"}]},
        {"id": "m2", "timestamp": "2026-08-01T00:00:02Z", "type": "gemini",
         "content": "시발 죄송합니다"},
    ))
    _write(home / ".gemini" / "projects.json",
           json.dumps({"projects": {str(workspace): "proj-alias"}}, ensure_ascii=False))

    desktop = home.joinpath(*friction.CLAUDE_DESKTOP_RELATIVE) / "a" / "b" / "local_c"
    _write(desktop / "audit.jsonl", _jsonl(
        {"type": "system", "subtype": "init", "cwd": "/sessions/x",
         "_audit_timestamp": "2026-08-01T00:00:00Z"},
        {"type": "user", "_audit_timestamp": "2026-08-01T00:00:01Z",
         "message": {"role": "user", "content": "아니 CLAUDE.md 오염시켰네"}},
    ))

    now = time.time()
    for path in home.rglob("*.jsonl"):
        import os
        os.utime(path, (now, now))
    return home


def test_every_store_is_scanned_and_classified(friction_home):
    report = friction.build_friction(friction_home, raw_quotes=True)
    by_source = {}
    for finding in report["findings"]:
        by_source.setdefault(finding["source"], []).append(finding)
    assert set(by_source) == {"claude", "codex", "gemini", "claude-desktop"}
    assert {f["category"] for f in by_source["claude"]} == {"wrong-action",
                                                            "stalling-approval"}
    assert by_source["codex"][0]["category"] == "verbosity"
    assert by_source["gemini"][0]["category"] == "stale-repetition"
    assert by_source["claude-desktop"][0]["category"] == "rule-contamination"
    assert all(store["status"] == "ok" for store in report["stores"])


def test_only_user_turns_are_read_never_assistant_or_nested(friction_home):
    report = friction.build_friction(friction_home, raw_quotes=True)
    quotes = " ".join(f["quote"] for f in report["findings"])
    # Assistant apologies and nested subagent transcripts both carry rage
    # markers in the fixture; neither may ever reach the output.
    assert "죄송합니다" not in quotes
    assert "중첩 턴" not in quotes


def test_codex_prefers_the_event_channel_over_the_duplicate_response_item(friction_home):
    report = friction.build_friction(friction_home, raw_quotes=True)
    codex = [f for f in report["findings"] if f["source"] == "codex"]
    assert len(codex) == 1


def test_codex_falls_back_to_response_items_when_the_event_channel_is_empty(tmp_path):
    path = tmp_path / "rollout.jsonl"
    _write(path, _jsonl(
        {"type": "session_meta", "payload": {"id": "x", "cwd": "/tmp"}},
        {"type": "response_item", "timestamp": "2026-08-01T00:00:00Z",
         "payload": {"type": "message", "role": "user",
                     "content": [{"type": "input_text", "text": "아니 그거 말고"}]}},
    ))
    budget = {"oversized_files": 0, "oversized_lines": 0, "unparsed_lines": 0,
              "unreadable_files": 0}
    assert [text for _, text in friction.codex_user_turns(path, budget)] == ["아니 그거 말고"]


def test_gemini_set_rewrites_are_deduplicated_by_message_id(friction_home):
    report = friction.build_friction(friction_home, raw_quotes=True)
    gemini = [f for f in report["findings"] if f["source"] == "gemini"]
    assert len(gemini) == 1


def test_gemini_workspace_is_joined_through_the_project_registry(friction_home):
    report = friction.build_friction(friction_home, raw_quotes=True)
    gemini = [f for f in report["findings"] if f["source"] == "gemini"][0]
    assert gemini["workspace"] is not None
    assert gemini["workspace"].endswith("/work/proj")


def test_gemini_alias_without_a_registry_entry_stays_unjoined(tmp_path):
    home = tmp_path / "home"
    _write(home / ".gemini" / "tmp" / "unknown" / "chats" / "s.jsonl",
           _jsonl({"id": "m", "type": "user", "content": [{"text": "아니 그거"}]}))
    refs, status = friction.collect_gemini_chats(home)
    assert status["found"] == 1
    assert refs[0]["workspace"] is None


# ---------------------------------------------------------------------------
# 상한과 창(window) — 조용한 절단 금지
# ---------------------------------------------------------------------------

def test_sessions_outside_the_window_are_excluded(friction_home):
    future = time.time() + 86400 * 400
    report = friction.build_friction(friction_home, since_days=30, now_ts=future)
    assert report["sessions_in_window"] == 0
    assert report["findings"] == []


def test_the_session_cap_is_reported_rather_than_applied_silently(friction_home):
    report = friction.build_friction(friction_home, max_sessions=1)
    assert report["sessions_scanned"] == 1
    assert report["sessions_skipped_by_cap"] == report["sessions_in_window"] - 1
    assert report["sessions_skipped_by_cap"] > 0
    assert f"{report['sessions_skipped_by_cap']} in-window sessions were not scanned" \
        in friction.render_report(report, 5)


def test_a_turn_replayed_by_resume_is_counted_once(tmp_path):
    """리줌하면 전체 트랜스크립트가 새 파일로 복제된다 — 턴은 하나다."""
    home = tmp_path / "home"
    turn = {"type": "user", "cwd": "/w", "timestamp": "2026-08-01T00:00:00Z",
            "message": {"role": "user", "content": "아니 누가 그거 하래?"}}
    for name in ("sess-a.jsonl", "sess-b.jsonl", "sess-c.jsonl"):
        _write(home / ".claude" / "projects" / "-p" / name, _jsonl(turn))
    report = friction.build_friction(home, raw_quotes=True)
    assert report["sessions_scanned"] == 3
    assert len(report["findings"]) == 1
    assert report["replayed_copies_collapsed"] == 2
    assert sum(report["by_severity"].values()) == 1
    assert "2 replayed copies" in friction.render_report(report, 5)


def test_distinct_turns_are_not_collapsed_by_a_shared_timestamp(tmp_path):
    home = tmp_path / "home"
    _write(home / ".claude" / "projects" / "-p" / "s.jsonl", _jsonl(
        {"type": "user", "cwd": "/w", "timestamp": "2026-08-01T00:00:00Z",
         "message": {"role": "user", "content": "아니 누가 그거 하래?"}},
        {"type": "user", "cwd": "/w", "timestamp": "2026-08-01T00:00:00Z",
         "message": {"role": "user", "content": "ㄴㄴ 그거 말고 다른거"}},
    ))
    report = friction.build_friction(home, raw_quotes=True)
    assert len(report["findings"]) == 2
    assert report["replayed_copies_collapsed"] == 0


def test_a_turn_without_a_timestamp_is_kept_rather_than_guessed_at():
    """타임스탬프가 없으면 파일 사이에서 같은 턴인지 판정할 수 없다 — 남긴다."""
    findings = [{"ts": None, "source": "gemini", "quote": "아니 그거 말고", "path": "a"},
                {"ts": None, "source": "gemini", "quote": "아니 그거 말고", "path": "b"}]
    kept, collapsed = friction._dedupe_replayed_turns(findings)
    assert len(kept) == 2
    assert collapsed == 0


def test_oversized_lines_are_counted_not_silently_dropped(tmp_path):
    home = tmp_path / "home"
    huge = "x" * (friction.MAX_LINE_BYTES + 10)
    _write(home / ".claude" / "projects" / "-p" / "s.jsonl",
           _jsonl({"type": "user", "cwd": "/tmp",
                   "message": {"role": "user", "content": huge}},
                  {"type": "user", "message": {"role": "user", "content": "아니 그거 말고"}}))
    report = friction.build_friction(home)
    assert report["skipped"]["oversized_lines"] == 1
    assert len(report["findings"]) == 1


def test_source_filter_restricts_the_scan(friction_home):
    report = friction.build_friction(friction_home, source="codex")
    assert {f["source"] for f in report["findings"]} == {"codex"}
    assert report["source_filter"] == "codex"


def test_report_counts_agree_with_the_finding_list(friction_home):
    report = friction.build_friction(friction_home)
    assert sum(report["by_category"].values()) == len(report["findings"])
    assert sum(report["by_severity"].values()) == len(report["findings"])
    assert set(report["by_category"]) == set(friction.FRICTION_CATEGORIES)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def test_cli_json_is_machine_readable(friction_home, tmp_path):
    script = Path(friction.__file__)
    proc = subprocess.run(
        [sys.executable, "-I", "-B", str(script), "scan", "--json",
         "--home", str(friction_home)],
        capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, proc.stderr
    payload = json.loads(proc.stdout)
    assert payload["evidence"] == "preview"
    assert payload["quotes"] == "masked"
    assert payload["by_category"]["wrong-action"] >= 1


def test_cli_rejects_nonpositive_windows(friction_home):
    assert friction.main(["scan", "--since-days", "0", "--home", str(friction_home)]) == 2
