"""Search must make bounded progress without treating a partial scan as absence."""
import json
import subprocess
import sys
from pathlib import Path

import pytest

import mcp_server
import scree


def hit(number, text="needle"):
    return {"eventId": f"event-{number}", "snippet": text, "role": "user", "at": None}


def index(monkeypatch, count=3):
    sessions = [{"tool": "Codex", "kind": "session", "sessionId": f"id-{n}",
                 "source": f"/fixture/{n}.jsonl", "workspace": "/work/target",
                 "lastActive": count-n, "sizeBytes": 10} for n in range(count)]
    value = {"sessions": sessions, "coverage": {"stores": []}}
    monkeypatch.setattr(scree, "_build_sessions_isolated", lambda *_: value)
    return sessions


def page(home, cursor="start", **options):
    return scree.build_search("needle", home, cursor=cursor, **options)


def test_limit_cursor_does_not_reread_finished_sessions(monkeypatch, tmp_path):
    index(monkeypatch)
    calls = []
    def read(source, *a, **kw):
        calls.append(source.name)
        return [hit(source.stem)], "ok", 0
    monkeypatch.setattr(scree, "_search_one_session_isolated", read)
    results, cursor = [], "start"
    while cursor:
        result = page(tmp_path, cursor, limit=1)
        results.extend(result["matches"])
        cursor = result["nextCursor"]
    assert calls == ["0.jsonl", "1.jsonl", "2.jsonl"]
    assert len(results) == 3
    assert result["coverage"] == "complete"
    assert result["progress"]["scannedArtifacts"] == 3


def test_time_cursor_continues_at_unfinished_file(monkeypatch, tmp_path):
    index(monkeypatch)
    now, calls = [0.0], []
    monkeypatch.setattr(scree.time, "monotonic", lambda: now[0])
    def read(source, *a, deadline, **kw):
        calls.append(source.name)
        if now[0] + .6 > deadline:
            now[0] = deadline
            return [], "time", 0
        now[0] += .6
        return [hit(source.stem)], "ok", 0
    monkeypatch.setattr(scree, "_search_one_session_isolated", read)
    first = page(tmp_path, budget_seconds=1)
    assert first["truncatedReason"] == "time"
    assert first["scannedSessions"] == 1
    second = page(tmp_path, first["nextCursor"], budget_seconds=10)
    assert calls == ["0.jsonl", "1.jsonl", "1.jsonl", "2.jsonl"]
    assert len(first["matches"] + second["matches"]) == 3
    assert second["coverage"] == "complete"


def test_mid_file_limit_and_time_resume_without_losing_tail(monkeypatch, tmp_path):
    index(monkeypatch, 1)
    reads = [([hit(1)], "time", 0), ([hit(1), hit(2), hit(3)], "ok", 0)]
    monkeypatch.setattr(scree, "_search_one_session_isolated", lambda *a, **kw: reads[0])
    first = page(tmp_path, limit=1)
    reads.pop(0)
    second = page(tmp_path, first["nextCursor"], limit=1)
    third = page(tmp_path, second["nextCursor"], limit=1)
    assert [r["matches"][0]["eventId"] for r in (first, second, third)] == ["event-1", "event-2", "event-3"]
    assert third["coverage"] == "complete"


def test_unreadable_early_page_cannot_become_definitive_later(monkeypatch, tmp_path):
    index(monkeypatch)
    def read(source, *a, **kw):
        return ([hit(1)], "ok", 0) if source.stem == "1" else ([], "unreadable", 0)
    monkeypatch.setattr(scree, "_search_one_session_isolated", read)
    first = page(tmp_path, limit=1)
    final = page(tmp_path, first["nextCursor"], limit=1)
    assert final["matches"] == []
    assert final["scanFinished"] is True
    assert final["coverage"] == "truncated"
    assert final["definitive"] is False
    assert final["progress"]["unreadableArtifacts"] == 2


@pytest.mark.parametrize("status", ["missing", "unsafe", "new-unknown-status"])
def test_unknown_reader_status_never_claims_complete(monkeypatch, tmp_path, status):
    index(monkeypatch, 1)
    monkeypatch.setattr(scree, "_search_one_session_isolated", lambda *a, **kw: ([], status, 0))
    result = page(tmp_path)
    assert result["coverage"] == "truncated"
    assert result["definitive"] is False
    assert result["unreadableSessions"] == 1


def test_scope_filter_is_applied_before_content_reads(monkeypatch, tmp_path):
    sessions = index(monkeypatch)
    sessions[0]["tool"] = "Claude"
    sessions[1]["workspace"] = "/elsewhere"
    calls = []
    def read(source, *a, **kw):
        calls.append(source.name)
        return [], "ok", 0
    monkeypatch.setattr(scree, "_search_one_session_isolated", read)
    result = page(tmp_path, provider="codex", workspace=["/work/target"], workspace_exact=True)
    assert calls == ["2.jsonl"]
    assert result["totalSessions"] == 1


def test_provider_coverage_ignores_other_stores_but_not_failed_global_discovery(monkeypatch, tmp_path):
    sessions = index(monkeypatch, 1)
    stores = [{"store": "Codex", "status": "ok"}, {"store": "Claude", "status": "unreadable"}]
    monkeypatch.setattr(scree, "_build_sessions_isolated", lambda *_: {
        "sessions": sessions, "coverage": {"stores": stores}})
    monkeypatch.setattr(scree, "_search_one_session_isolated", lambda *a, **kw: ([], "ok", 0))
    assert page(tmp_path, provider="codex")["coverage"] == "complete"
    assert page(tmp_path)["coverage"] == "truncated"
    stores.append({"store": "Session discovery", "status": "unreadable"})
    assert page(tmp_path, provider="codex")["coverage"] == "truncated"


def test_discovery_gaps_carry_over_across_pages(monkeypatch, tmp_path):
    sessions = index(monkeypatch, 2)
    stores = [{"store": "Codex", "status": "unrecognized", "unrecognized": 1}]
    monkeypatch.setattr(scree, "_build_sessions_isolated", lambda *_: {
        "sessions": sessions, "coverage": {"stores": stores}})
    monkeypatch.setattr(scree, "_search_one_session_isolated", lambda *a, **kw: ([hit(1)], "ok", 0))
    first = page(tmp_path, limit=1)
    stores[0].update(status="ok", unrecognized=0)
    final = page(tmp_path, first["nextCursor"], limit=1)
    assert final["scanFinished"] is True
    assert final["coverage"] == "truncated" and final["definitive"] is False
    assert final["truncatedReason"] == "discovery"


def test_identical_messages_without_event_ids_are_distinct(monkeypatch, tmp_path):
    index(monkeypatch, 1)
    monkeypatch.setattr(scree, "_search_one_session_isolated", lambda *a, **kw: (
        [{**hit(1), "eventId": None, "index": 0}, {**hit(1), "eventId": None, "index": 1}], "ok", 0))
    assert len(page(tmp_path)["matches"]) == 2


def test_cursor_rejects_changed_query_and_store(monkeypatch, tmp_path):
    sessions = index(monkeypatch)
    monkeypatch.setattr(scree, "_search_one_session_isolated", lambda *a, **kw: ([hit(1)], "ok", 0))
    cursor = page(tmp_path, limit=1)["nextCursor"]
    with pytest.raises(ValueError, match="another query"):
        scree.build_search("other", tmp_path, cursor=cursor)
    sessions.append({**sessions[0], "sessionId": "added", "source": "/fixture/new.jsonl"})
    with pytest.raises(ValueError, match="store changed"):
        page(tmp_path, cursor)


def test_completed_sessions_can_keep_growing_without_resetting_progress(monkeypatch, tmp_path):
    sessions = index(monkeypatch)
    monkeypatch.setattr(scree, "_search_one_session_isolated", lambda *a, **kw: ([hit(1)], "ok", 0))
    cursor = page(tmp_path, limit=1)["nextCursor"]
    sessions[0].update(sizeBytes=200, lastActive=100)
    result = page(tmp_path, cursor, limit=1)
    assert result["scannedSessions"] == 2


def test_changed_unfinished_session_requires_restart(monkeypatch, tmp_path):
    sessions = index(monkeypatch, 1)
    monkeypatch.setattr(scree, "_search_one_session_isolated", lambda *a, **kw: ([hit(1), hit(2)], "ok", 0))
    cursor = page(tmp_path, limit=1)["nextCursor"]
    sessions[0]["sizeBytes"] = 200
    with pytest.raises(ValueError, match="unfinished session changed"):
        page(tmp_path, cursor)


def test_stalled_reader_is_reported_without_skipping(monkeypatch, tmp_path):
    index(monkeypatch, 1)
    monkeypatch.setattr(scree, "_search_one_session_isolated", lambda *a, **kw: ([], "time", 0))
    result = page(tmp_path)
    assert result["progressMade"] is False
    assert result["hasMore"] is True
    assert result["scannedArtifacts"] == 0
    assert page(tmp_path, result["nextCursor"])["nextCursor"] == result["nextCursor"]


def test_fragments_repeat_stable_ids_for_cross_page_merge(monkeypatch, tmp_path):
    sessions = index(monkeypatch, 1)
    sessions[0]["artifactSources"] = ["/fixture/one", "/fixture/two"]
    monkeypatch.setattr(scree, "_search_one_session_isolated", lambda *a, **kw: ([hit(1), hit(2)], "ok", 0))
    results, cursor = [], "start"
    for _ in range(5):
        result = page(tmp_path, cursor, limit=1)
        results.extend(result["matches"])
        cursor = result["nextCursor"]
        if cursor is None: break
    assert cursor is None
    assert len({h["matchId"] for h in results}) == 2
    assert len(results) == 4


@pytest.mark.parametrize("cursor", ["garbage", "a"*4097, "e30", "W10"])
def test_invalid_cursor_is_a_bounded_error(tmp_path, cursor):
    with pytest.raises(ValueError, match="invalid search cursor"):
        page(tmp_path, cursor)


def test_mcp_caps_request_and_forwards_filters_and_cursor_on_stdin(monkeypatch):
    captured = {}
    def run(script, arguments, timeout, *, stdin_text):
        captured.update(arguments=arguments, timeout=timeout, request=json.loads(stdin_text))
        return {"matches": [], "masked": True, "nextCursor": "next"}
    monkeypatch.setattr(mcp_server, "_run_json", run)
    result = mcp_server.tool_agent_session_search({"query": "private phrase", "user_initiated": True,
        "limit": 1000, "budget_seconds": 300, "provider": "codex", "workspace": ["/work/target"],
        "workspace_exact": True, "exclude_workspace": ["archive"], "cursor": "opaque-cursor"})
    assert captured["request"] == {"query": "private phrase", "cursor": "opaque-cursor"}
    assert "private phrase" not in captured["arguments"] and "opaque-cursor" not in captured["arguments"]
    assert captured["timeout"] == 70
    assert "--provider" in captured["arguments"] and "--workspace-exact" in captured["arguments"]
    assert result["requestBounds"]["effectiveLimit"] == 200
    assert result["requestBounds"]["effectiveBudgetSeconds"] == 60


@pytest.mark.parametrize("options", [{"workspace": "bad"}, {"workspace": [""]},
    {"exclude_workspace": ["x"] * 33}, {"workspace_exact": 1}, {"provider": "unknown"}, {"cursor": ""}])
def test_mcp_rejects_bad_scope_before_reading(monkeypatch, options):
    monkeypatch.setattr(mcp_server, "_run_json", lambda *a, **kw: pytest.fail("must not read"))
    with pytest.raises(mcp_server.ToolFailure):
        mcp_server.tool_agent_session_search({"query": "needle", "user_initiated": True, **options})


def test_real_mcp_pages_read_all_hits_and_keep_private_input_off_argv(monkeypatch, tmp_path):
    source = tmp_path / ".codex/sessions/2026/10/21/example.jsonl"
    source.parent.mkdir(parents=True)
    source.write_text("\n".join(json.dumps(row) for row in [
        {"type": "session_meta", "payload": {"id": "cursor-fixture", "cwd": "/fixture/work"}},
        *[{"type": "response_item", "timestamp": f"2026-10-21T10:00:0{n}Z", "payload": {
            "type": "message", "id": f"message-{n}", "role": "user", "content": [
                {"type": "input_text", "text": f"needle {n} someone@example.com"}]}} for n in range(3)],
    ]) + "\n")
    monkeypatch.setenv("HOME", str(tmp_path))
    arguments = {"query": "needle", "user_initiated": True, "provider": "codex",
                 "workspace": ["/fixture/work"], "workspace_exact": True, "limit": 1}
    results, tokens = [], []
    for _ in range(4):
        report = mcp_server.tool_agent_session_search(arguments)
        results.extend(report["matches"])
        if not report["nextCursor"]: break
        tokens.append(report["nextCursor"])
        arguments["cursor"] = report["nextCursor"]
    assert report["coverage"] == "complete"
    assert report["scanFinished"] is True
    assert len({item["matchId"] for item in results}) == 3
    assert "someone@example.com" not in json.dumps(results)
    assert "<email-redacted>" in json.dumps(results)
    for token in tokens:
        state = scree._search_cursor_decode(token)
        assert "needle" not in json.dumps(state)
        assert str(tmp_path) not in json.dumps(state)
        assert "someone@example.com" not in json.dumps(state)


def test_cli_invalid_cursor_is_an_actionable_error_not_traceback(tmp_path):
    result = subprocess.run([sys.executable, "-I", "-B", str(Path(scree.__file__)),
        "search", "--query-file", "/dev/fd/0", "--request-json", "--home", str(tmp_path)],
        input=json.dumps({"query": "private phrase", "cursor": "malformed"}),
        capture_output=True, text=True, timeout=10)
    assert result.returncode == 2
    assert "invalid search cursor" in result.stderr
    assert "Traceback" not in result.stderr and "private phrase" not in result.stderr
