#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MCP 표면 계약 테스트: 읽기 전용 경계, 얇은 층 보장, JSON-RPC 프로토콜."""
import io
import json
import os
import time as _time
from pathlib import Path

import pytest

import mcp_server


def _call(tool: str, arguments: dict) -> dict:
    return mcp_server.handle_request("tools/call", {"name": tool, "arguments": arguments})


def _payload(result: dict) -> dict:
    assert not result.get("isError"), result["content"][0]["text"]
    return result["structuredContent"]


# ---------------------------------------------------------------------------
# 읽기 전용 경계 — 이 표면의 존재 이유
# ---------------------------------------------------------------------------

def test_only_the_read_only_judgment_tools_are_exposed():
    assert sorted(mcp_server.HANDLERS) == ["agent_file_access", "agent_session_list",
                                           "agent_session_search", "agent_state_report",
                                           "mcp_hygiene", "model_residue_report",
                                           "operator_friction_report", "system_scan_summary",
                                           "uninstall_residue_report"]


def test_every_tool_is_annotated_read_only_and_non_destructive():
    for tool in mcp_server.TOOL_DESCRIPTORS:
        annotations = tool["annotations"]
        assert annotations["readOnlyHint"] is True, tool["name"]
        assert annotations["destructiveHint"] is False, tool["name"]
        assert annotations["openWorldHint"] is False, tool["name"]


def test_the_module_has_exactly_one_way_to_start_a_process():
    """The approval-token contract is that a human approves cleanup on screen.

    An agent-reachable execution path would end that guarantee, so the server
    keeps a single, auditable process-spawning call site -- pinned against the
    module source rather than against a naming convention.
    """
    source = Path(mcp_server.__file__).read_text(encoding="utf-8")
    assert source.count("subprocess.run") == 1
    for forbidden in ("os.system", "Popen", "subprocess.call", "subprocess.check",
                      "shell=True", "os.exec", "os.spawn", "runpy"):
        assert forbidden not in source, f"MCP surface must not use {forbidden}"


def test_no_tool_can_run_anything_but_the_judgment_scripts(monkeypatch, tmp_path):
    """Exercised, not inspected: every tool is called and the real spawn point is
    recorded. cleanup.sh, scanner.sh, and scree's content-reading `preserve`
    subcommand must never appear in an argument vector."""
    spawned = []

    class _Proc:
        returncode = 0
        stdout = "{}"
        stderr = ""

    def fake_run(argv, **kwargs):
        spawned.append(argv)
        return _Proc()

    monkeypatch.setattr(mcp_server.subprocess, "run", fake_run)
    monkeypatch.setenv("PCH_SCAN", str(tmp_path / "absent.json"))
    monkeypatch.setattr(mcp_server, "PROJECT_ROOT", tmp_path)
    monkeypatch.setattr(Path, "home", staticmethod(lambda: tmp_path))
    for name in mcp_server.HANDLERS:
        _call(name, {})

    assert spawned, "expected the judgment scripts to be invoked"
    for argv in spawned:
        script = Path(argv[3]).name
        assert script in ("scree.py", "friction.py", "moraine.py", "hfscan.py",
                          "mcpaudit.py", "fileaccess.py"), argv
        joined = " ".join(argv)
        for forbidden in ("cleanup", "scanner", "storage_watch", "schedule",
                          "preserve", "--raw"):
            assert forbidden not in joined, argv


def test_the_read_only_contract_is_enforced_where_tools_are_registered():
    """Ported from AirMCP's iOS server, which fails a tool closed at
    registration rather than hiding it from tools/list. Absence-by-intention is
    not a boundary; this is."""
    assert mcp_server.REJECTED_TOOLS == []
    assert {t["name"] for t in mcp_server.REGISTERED_TOOLS} == mcp_server.EXPOSED_TOOL_NAMES

    forgot_annotation = {"name": "agent_state_report",
                         "annotations": {"destructiveHint": False}}
    assert not mcp_server.contract_allows(forgot_annotation)

    destructive = {"name": "agent_state_report",
                   "annotations": {"readOnlyHint": True, "destructiveHint": True}}
    assert not mcp_server.contract_allows(destructive)

    not_on_the_allowlist = {"name": "run_cleanup",
                            "annotations": {"readOnlyHint": True, "destructiveHint": False}}
    assert not mcp_server.contract_allows(not_on_the_allowlist)


def test_a_tool_rejected_by_the_contract_is_unreachable_not_merely_unlisted(monkeypatch):
    smuggled = {"name": "run_cleanup", "title": "x", "description": "x",
                "inputSchema": {"type": "object"},
                "annotations": {"readOnlyHint": False, "destructiveHint": True},
                "handler": lambda args: {"ran": True}}
    monkeypatch.setattr(mcp_server, "TOOLS", mcp_server.TOOLS + [smuggled])
    registered = [t for t in mcp_server.TOOLS if mcp_server.contract_allows(t)]
    assert "run_cleanup" not in {t["name"] for t in registered}
    # And the live registry, built through the same gate, never learned it.
    response = mcp_server.dispatch({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                    "params": {"name": "run_cleanup", "arguments": {}}})
    assert response["error"]["code"] == mcp_server.METHOD_NOT_FOUND


def test_the_judgment_scripts_are_the_declared_targets():
    assert mcp_server.SCREE.name == "scree.py"
    assert mcp_server.FRICTION.name == "friction.py"
    assert mcp_server.MORAINE.name == "moraine.py"
    assert mcp_server.HFSCAN.name == "hfscan.py"
    assert mcp_server.MCPAUDIT.name == "mcpaudit.py"
    assert mcp_server.FILEACCESS.name == "fileaccess.py"


def test_scan_summary_states_that_it_cannot_start_a_scan(tmp_path, monkeypatch):
    monkeypatch.setenv("PCH_SCAN", str(tmp_path / "absent.json"))
    monkeypatch.setattr(mcp_server, "PROJECT_ROOT", tmp_path)
    monkeypatch.setattr(Path, "home", staticmethod(lambda: tmp_path))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["available"] is False
    assert "not startable" in payload["reason"]
    assert payload["checked_paths"]


# ---------------------------------------------------------------------------
# scan 결과 발견 — 앱의 canonical 발행 디렉토리와 명시적 freshness
# ---------------------------------------------------------------------------

def _write_scan(path: Path, scanned_at: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"scannedAt": scanned_at, "schemaVersion": 1,
                                "platform": "macos", "summary": "ok",
                                "sections": {}, "findings": []}), encoding="utf-8")


def _local(epoch: float) -> str:
    return _time.strftime("%Y-%m-%d %H:%M:%S", _time.localtime(epoch))


@pytest.fixture
def scan_roots(tmp_path, monkeypatch):
    """Fake both discovery roots and pin the wall clock."""
    monkeypatch.delenv("PCH_SCAN", raising=False)
    project = tmp_path / "project"
    home = tmp_path / "home"
    project.mkdir()
    monkeypatch.setattr(mcp_server, "PROJECT_ROOT", project)
    monkeypatch.setattr(Path, "home", staticmethod(lambda: home))
    now = _time.time()
    monkeypatch.setattr(mcp_server, "_wall_clock", lambda: now)
    results = home / "Library" / "Application Support" / "Modore" / "results"
    return project, results, now


def test_scan_summary_reads_the_apps_canonical_publication_directory(scan_roots):
    """PR #100 moved the app's verified scan into .modore-scan-current; the MCP
    surface must find it there, not report available:false beside a fresh scan."""
    project, results, now = scan_roots
    canonical = results / mcp_server.SCAN_PUBLICATION_DIRNAME / "scan_result.json"
    _write_scan(canonical, _local(now - 120))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["available"] is True
    assert payload["source_path"] == str(canonical)


def test_canonical_wins_within_a_root_regardless_of_file_mtime(scan_roots):
    """A restore, `cp`, or `touch` rewrites mtime without rescanning anything.
    Inside one output root the app reads the canonical directory whenever it
    exists (ScanResultLoader) and never ranks it against the legacy file, so
    neither does this surface."""
    project, results, now = scan_roots
    legacy = results / "scan_result.json"
    canonical = results / mcp_server.SCAN_PUBLICATION_DIRNAME / "scan_result.json"
    _write_scan(canonical, _local(now - 60))
    _write_scan(legacy, _local(now - 8 * 3600))
    os.utime(canonical, (now - 3600, now - 3600))
    os.utime(legacy, (now, now))          # legacy touched most recently...
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["source_path"] == str(canonical)   # ...and still loses.
    # The legacy layout is still read when that root has no canonical dir.
    for stray in canonical.parent.iterdir():
        stray.unlink()
    canonical.parent.rmdir()
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["source_path"] == str(legacy)


def test_between_producer_roots_the_more_recent_scan_wins_not_the_newer_file(scan_roots):
    """Two independent producers, no authority to defer to: compare when each
    was scanned, not when its file last moved."""
    project, results, now = scan_roots
    cli = project / "scan_result.json"
    app = results / mcp_server.SCAN_PUBLICATION_DIRNAME / "scan_result.json"
    _write_scan(app, _local(now - 60))
    _write_scan(cli, _local(now - 8 * 3600))
    os.utime(cli, (now, now))             # copied back after the app scanned
    os.utime(app, (now - 7200, now - 7200))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["source_path"] == str(app)
    # And the app's own result does not win by being the app's: a genuinely
    # newer CLI scan is the newer scan.
    _write_scan(cli, _local(now - 30))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["source_path"] == str(cli)


def test_an_existing_canonical_directory_suppresses_legacy_even_with_no_scan_file(scan_roots):
    """ScanResultLoader resolves the canonical directory first and, when it is
    there, reads only the file beneath it -- returning an empty result when
    that file is missing rather than falling back to the root-level one. A
    canonical directory whose scan is gone means a publication went wrong; the
    honest answer is that there is no current scan, not the stale file the
    publication scheme exists to retire."""
    project, results, now = scan_roots
    legacy = results / "scan_result.json"
    _write_scan(legacy, _local(now - 8 * 3600))
    (results / mcp_server.SCAN_PUBLICATION_DIRNAME).mkdir(parents=True)
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["available"] is False
    assert str(legacy) not in payload["checked_paths"]


def test_a_symlinked_canonical_path_is_not_a_canonical_publication(scan_roots):
    """FilesystemIdentity.directory(at:) uses lstat and S_IFDIR, so the app
    does not accept a symlink as the canonical directory even when it resolves
    to one. Neither does this surface: a redirection the publication scheme
    never created must not suppress the layout it would otherwise read."""
    project, results, now = scan_roots
    legacy = results / "scan_result.json"
    _write_scan(legacy, _local(now - 300))
    elsewhere = results / "some-other-dir"
    elsewhere.mkdir(parents=True)
    (results / mcp_server.SCAN_PUBLICATION_DIRNAME).symlink_to(elsewhere)
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["source_path"] == str(legacy)


def test_a_future_timestamp_does_not_outrank_a_trustworthy_scan(scan_roots):
    """The same timestamp cannot be untrustworthy for freshness and
    authoritative for selection. `_scan_freshness` refuses to read a
    meaningfully future scannedAt as "just scanned"; selection must not then
    pick that candidate over a scan it does trust -- and answer `stale` while a
    fresh result sat unread in the other root."""
    project, results, now = scan_roots
    cli = project / "scan_result.json"
    app = results / mcp_server.SCAN_PUBLICATION_DIRNAME / "scan_result.json"
    _write_scan(app, _local(now - 60))
    _write_scan(cli, _local(now + 3600))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["source_path"] == str(app)
    assert payload["stale"] is False
    # Not merely an mtime accident: even with the freshest mtime on the
    # machine, an untrustworthy timestamp still loses to a trustworthy one.
    os.utime(cli, (now + 7200, now + 7200))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["source_path"] == str(app)


def test_mtime_orders_only_candidates_that_are_equally_untrustworthy(scan_roots):
    """mtime is the fallback, not a competitor: it breaks the tie between two
    results whose own timestamps cannot be trusted, and never lifts one of them
    over a result whose timestamp can be.

    This is this surface's own arbitration rule, not the app's semantics: the
    app falls back to file date freely because it only ever dates one file it
    has already chosen. Choosing between producers is the stronger claim, and a
    malformed result does not win it by having been touched most recently."""
    project, results, now = scan_roots
    cli = project / "scan_result.json"
    app = results / mcp_server.SCAN_PUBLICATION_DIRNAME / "scan_result.json"
    _write_scan(app, "not a timestamp")
    _write_scan(cli, "also not a timestamp")
    os.utime(app, (now, now))
    os.utime(cli, (now - 8 * 3600, now - 8 * 3600))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["source_path"] == str(app)
    assert payload["age_basis"] == "file_mtime"
    # But a readable timestamp outranks both, even an older one: what is known
    # beats what is guessed from when a file last moved.
    _write_scan(cli, _local(now - 8 * 3600))
    os.utime(cli, (now - 8 * 3600, now - 8 * 3600))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["source_path"] == str(cli)
    assert payload["age_basis"] == "scanned_at"


def test_pch_scan_override_is_exclusive_and_never_falls_back(scan_roots, monkeypatch):
    project, results, now = scan_roots
    canonical = results / mcp_server.SCAN_PUBLICATION_DIRNAME / "scan_result.json"
    _write_scan(canonical, _local(now - 60))
    absent = project / "absent.json"
    monkeypatch.setenv("PCH_SCAN", str(absent))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["available"] is False
    assert payload["checked_paths"] == [str(absent)]


def test_scan_summary_reports_explicit_freshness(scan_roots):
    project, results, now = scan_roots
    canonical = results / mcp_server.SCAN_PUBLICATION_DIRNAME / "scan_result.json"
    _write_scan(canonical, _local(now - 300))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["age_basis"] == "scanned_at"
    assert abs(payload["age_seconds"] - 300) <= 1
    assert payload["stale"] is False
    assert payload["freshness_threshold_seconds"] == 6 * 60 * 60


def test_scan_summary_marks_old_and_future_results_stale(scan_roots):
    project, results, now = scan_roots
    canonical = results / mcp_server.SCAN_PUBLICATION_DIRNAME / "scan_result.json"
    _write_scan(canonical, _local(now - 7 * 3600))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["stale"] is True and "threshold" in payload["stale_reason"]
    # The app's own guard: a timestamp meaningfully in the future is stale,
    # not "scanned just now" (a timezone change can shift zone-less times).
    _write_scan(canonical, _local(now + 3600))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["stale"] is True and "future" in payload["stale_reason"]


def test_scan_summary_falls_back_to_file_mtime_when_scanned_at_is_unreadable(scan_roots):
    project, results, now = scan_roots
    canonical = results / mcp_server.SCAN_PUBLICATION_DIRNAME / "scan_result.json"
    _write_scan(canonical, "yesterday, roughly")
    os.utime(canonical, (now - 500, now - 500))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["age_basis"] == "file_mtime"
    assert abs(payload["age_seconds"] - 500) <= 1


# ---------------------------------------------------------------------------
# 얇은 층 — 판정을 재구현하지 않는다
# ---------------------------------------------------------------------------

_SCREE_FIXTURE = {
    "contract": "metadata-only output",
    "stores": [{"store": "Claude", "status": "ok", "count": 2, "unrecognized": 0}],
    "groups": [{"key": "g1", "cross_tool": True, "orphan": False},
               {"key": "g2", "cross_tool": False, "orphan": True}],
    "unresolved_sessions": 0,
    "lineage": {"summary": {"total": 2, "vanished": 1},
                "paths": [{"path": "/a", "exists": True}, {"path": "/b", "exists": False}]},
    "retention": {"stores": [{"store": "Claude", "mode": "rolling"}],
                  "expiring": [{"tool": "Claude", "days_left": 2, "size_bytes": 1}]},
    "worktrees": {"items": [
        {"path": "/w/rebuildable", "verdict": "rebuildable"},
        {"path": "/w/protected", "verdict": "protected"},
        {"path": "/w/stray", "verdict": "protected", "stray_checkout": True}],
        "registered_missing": []},
}

_SESSIONS_FIXTURE = {
    "total": 3,
    "sessions": [
        {"tool": "Codex", "source": "/sessions/new.jsonl", "workspace": "/repo",
         "workspaceExists": True, "kind": "session", "sizeBytes": 100,
         "lastActive": "2026-08-30 12:00", "lastActiveEpoch": 1_800_000_000},
        {"tool": "Claude", "source": "/sessions/old.jsonl", "workspace": "",
         "workspaceExists": False, "kind": "session", "sizeBytes": 50,
         "lastActive": "2026-08-29 12:00", "lastActiveEpoch": 1_799_000_000},
    ],
}

_SESSION_SEARCH_FIXTURE = {
    "query": "storage pressure",
    "matches": [
        {"position": 1, "role": "user", "snippet": "masked storage pressure text",
         "tool": "Codex", "source": "/sessions/new.jsonl", "workspace": "/repo",
         "lastActive": "2026-08-30 12:00"},
    ],
    "scannedSessions": 3,
    "totalSessions": 3,
    "unreadableSessions": 0,
    "coverage": "complete",
    "truncatedReason": None,
    "definitive": True,
    "evidenceKind": "conversation_mention",
    "masked": True,
}

_FRICTION_FIXTURE = {
    "contract": "user-authored turns only",
    "taxonomy_basis": "cited",
    "evidence": "preview",
    "quotes": "masked",
    "window_days": 30,
    "stores": [{"store": "claude", "status": "ok"}],
    "sessions_scanned": 2, "sessions_in_window": 2, "sessions_skipped_by_cap": 0,
    "user_turns_scanned": 9,
    "by_category": {"wrong-action": 1, "verbosity": 1},
    "by_severity": {"1": 1, "2": 0, "3": 1},
    "findings": [
        {"ts": "2026-08-01T00:00:00Z", "severity": 3, "category": "wrong-action",
         "quote": "old rage"},
        {"ts": "2026-08-09T00:00:00Z", "severity": 1, "category": "verbosity",
         "quote": "new nudge"},
    ],
}


_MORAINE_FIXTURE = {
    "contract": "read-only",
    "evidence": "preview",
    "prior_art": "AppCleaner covers the file-sweep half",
    "sources": [{"source": "receipts", "status": "ok", "count": 2}],
    "receipts": {"total": 2, "non_apple": 1, "vanished": 1, "sampled": 0,
                 "vendors": [{"vendor": "com.innorix", "apple": False, "fully_removed": True},
                             {"vendor": "com.apple", "apple": True, "fully_removed": False}]},
    "trust_roots": {"total": 2, "orphaned": 1, "unattributed": 1, "unconditional": 1,
                    "items": [{"name": "INNORIX.CA", "verdict": "orphaned"},
                              {"name": "AirFRONT", "verdict": "unattributed"}]},
    "removed_vendors": ["com.innorix"],
}


@pytest.fixture
def stub_scripts(monkeypatch):
    calls = []

    def fake(script, arguments, timeout, *, stdin_text=None):
        calls.append((script.name, arguments))
        if script.name == "scree.py":
            if arguments and arguments[0] == "sessions":
                return _SESSIONS_FIXTURE
            if arguments and arguments[0] == "search":
                return _SESSION_SEARCH_FIXTURE
            return _SCREE_FIXTURE
        return {"friction.py": _FRICTION_FIXTURE,
                "moraine.py": _MORAINE_FIXTURE}[script.name]

    monkeypatch.setattr(mcp_server, "_run_json", fake)
    return calls


def test_scree_report_forwards_the_scripts_own_verdicts(stub_scripts):
    payload = _payload(_call("agent_state_report", {"section": "all", "limit": 10}))
    assert payload["summary"]["contract"] == _SCREE_FIXTURE["contract"]
    assert payload["summary"]["groups_orphan"] == 1
    assert payload["summary"]["worktrees_protected"] == 2
    assert payload["summary"]["stray_checkouts"] == 1
    assert stub_scripts == [("scree.py", ["report", "--json"])]


def test_scree_report_orders_sole_copy_worktrees_first(stub_scripts):
    payload = _payload(_call("agent_state_report", {"section": "worktrees", "limit": 1}))
    assert payload["worktrees"]["items"][0]["verdict"] == "protected"
    assert payload["worktrees"]["truncated"] is True
    assert payload["worktrees"]["omitted"] == 2


def test_scree_summary_section_is_counts_only(stub_scripts):
    payload = _payload(_call("agent_state_report", {"section": "summary"}))
    assert "groups" not in payload and "worktrees" not in payload
    assert payload["groups_total"] == 2


def test_agent_session_list_delegates_to_metadata_only_scree_sessions(stub_scripts):
    payload = _payload(_call("agent_session_list", {"limit": 2}))

    assert stub_scripts == [("scree.py", ["sessions", "--limit", "2"])]
    assert payload["contract"] == "metadata-only; session bodies were not read"
    assert payload["delegated_to"] == "scree sessions"
    assert [item["tool"] for item in payload["sessions"]] == ["Codex", "Claude"]
    assert payload["returned"] == 2
    assert payload["total"] == 3
    assert payload["truncated"] is True and payload["omitted"] == 1


def test_agent_session_search_requires_explicit_user_intent_before_reading_bodies(
    monkeypatch
):
    calls = []
    monkeypatch.setattr(mcp_server, "_run_json", lambda *a, **kw: calls.append((a, kw)))

    for arguments in ({}, {"query": "storage"},
                      {"query": "storage", "user_initiated": False},
                      {"query": "   ", "user_initiated": True}):
        result = _call("agent_session_search", arguments)
        assert result.get("isError"), arguments
    assert calls == [], "no transcript subprocess may start without explicit user intent and query"


def test_agent_session_search_delegates_query_over_stdin_and_forces_masking(monkeypatch):
    captured = {}

    class _Proc:
        returncode = 0
        stdout = json.dumps(_SESSION_SEARCH_FIXTURE)
        stderr = ""

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        captured["kwargs"] = kwargs
        return _Proc()

    monkeypatch.setattr(mcp_server.subprocess, "run", fake_run)
    payload = _payload(_call("agent_session_search", {
        "query": "storage pressure", "user_initiated": True,
        "limit": 7, "budget_seconds": 12,
    }))

    argv = captured["argv"]
    assert argv[4:] == ["search", "--query-file", "/dev/fd/0", "--limit", "7",
                        "--budget-seconds", "12"]
    assert "storage pressure" not in argv
    assert "--raw" not in argv
    assert captured["kwargs"]["input"] == "storage pressure"
    assert "stdin" not in captured["kwargs"]
    assert captured["kwargs"]["timeout"] == 12 + mcp_server.SCREE_SEARCH_PROCESS_GRACE_SECONDS
    assert payload["masked"] is True
    assert payload["delegatedTo"] == "scree search"
    assert payload["evidenceKind"] == "conversation_mention"


def test_agent_session_search_rejects_unmasked_or_malformed_scree_output(monkeypatch):
    for report in (
        {**_SESSION_SEARCH_FIXTURE, "masked": False},
        {"masked": True, "matches": "not-a-list"},
    ):
        monkeypatch.setattr(mcp_server, "_run_json", lambda *a, report=report, **kw: report)
        result = _call("agent_session_search", {
            "query": "storage", "user_initiated": True,
        })
        assert result.get("isError"), report


def test_agent_session_search_applies_a_second_output_limit(monkeypatch):
    report = {**_SESSION_SEARCH_FIXTURE,
              "matches": [{"snippet": f"masked-{index}"} for index in range(10)]}
    monkeypatch.setattr(mcp_server, "_run_json", lambda *a, **kw: report)

    payload = _payload(_call("agent_session_search", {
        "query": "storage", "user_initiated": True, "limit": 2,
    }))

    assert len(payload["matches"]) == 2
    assert payload["returnWindow"] == {
        "returned": 2, "total": 10, "truncated": True, "omitted": 8,
    }


def test_agent_session_tools_delegate_end_to_end_without_unmasking(tmp_path, monkeypatch):
    workspace = tmp_path / "repo"
    workspace.mkdir()
    session = tmp_path / ".claude" / "projects" / "-fixture" / "session.jsonl"
    session.parent.mkdir(parents=True)
    session.write_text("\n".join([
        json.dumps({"cwd": str(workspace)}),
        json.dumps({
            "timestamp": "2026-08-30T12:00:00Z",
            "message": {"role": "user", "content": [
                {"type": "text", "text": "needle contact someone@example.com"},
            ]},
        }),
    ]) + "\n", encoding="utf-8")
    monkeypatch.setenv("HOME", str(tmp_path))

    listed = _payload(_call("agent_session_list", {"limit": 10}))
    assert listed["sessions"][0]["source"] == str(session)
    assert "needle" not in json.dumps(listed, ensure_ascii=False)

    searched_result = _call("agent_session_search", {
        "query": "needle", "user_initiated": True, "limit": 10,
        "budget_seconds": 10,
    })
    searched = _payload(searched_result)
    assert searched["matches"]
    rendered = json.dumps(searched, ensure_ascii=False)
    assert "someone@example.com" not in rendered
    assert "<email-redacted>" in rendered
    assert searched_result["content"][0]["text"].startswith(mcp_server.UNTRUSTED_OPEN)
    assert searched_result["content"][0]["text"].rstrip().endswith(mcp_server.UNTRUSTED_CLOSE)


@pytest.mark.parametrize("arguments", [
    {"query": "x", "user_initiated": True, "limit": 0},
    {"query": "x", "user_initiated": True, "limit": 201},
    {"query": "x", "user_initiated": True, "budget_seconds": 0},
    {"query": "x", "user_initiated": True, "budget_seconds": 61},
    {"query": "\x00", "user_initiated": True},
    {"query": "가" * 1366, "user_initiated": True},
])
def test_agent_session_search_bounds_query_limit_and_timeout(arguments, monkeypatch):
    calls = []
    monkeypatch.setattr(mcp_server, "_run_json", lambda *a, **kw: calls.append((a, kw)))

    result = _call("agent_session_search", arguments)

    assert result.get("isError")
    assert calls == []


def test_friction_scan_passes_filters_through_and_applies_the_rest_locally(stub_scripts):
    payload = _payload(_call("operator_friction_report", {
        "since_days": 14, "source": "codex", "max_sessions": 50,
        "min_severity": 3, "limit": 10}))
    assert stub_scripts == [("friction.py", [
        "scan", "--json", "--since-days", "14", "--max-sessions", "50",
        "--source", "codex"])]
    assert payload["matched_findings"] == 1
    assert payload["findings"][0]["quote"] == "old rage"
    assert payload["taxonomy_basis"] == "cited"


def test_friction_findings_come_back_newest_first(stub_scripts):
    payload = _payload(_call("operator_friction_report", {"min_severity": 1}))
    assert [f["quote"] for f in payload["findings"]] == ["new nudge", "old rage"]


def test_category_filter_is_applied(stub_scripts):
    payload = _payload(_call("operator_friction_report", {"category": "verbosity"}))
    assert payload["matched_findings"] == 1
    assert payload["findings"][0]["category"] == "verbosity"


def test_truncation_is_always_accounted_for(stub_scripts):
    payload = _payload(_call("operator_friction_report", {"limit": 1, "min_severity": 1}))
    assert payload["returned"] == 1
    assert payload["total"] == 2
    assert payload["truncated"] is True
    assert payload["omitted"] == 1


def test_moraine_report_forwards_the_correlated_verdict(stub_scripts):
    payload = _payload(_call("uninstall_residue_report", {"section": "all", "limit": 10}))
    assert payload["summary"]["trust_roots_orphaned"] == 1
    assert payload["summary"]["removed_vendors"] == ["com.innorix"]
    assert payload["trust_roots"]["items"][0]["name"] == "INNORIX.CA"
    # Apple 패키지는 벤더 롤업에서 빠진다 — 사람이 읽을 대상이 아니다.
    assert [v["vendor"] for v in payload["receipts"]["non_apple_vendors"]] == ["com.innorix"]
    assert stub_scripts == [("moraine.py", ["--json"])]


def test_moraine_summary_section_is_counts_only(stub_scripts):
    payload = _payload(_call("uninstall_residue_report", {"section": "summary"}))
    assert "trust_roots" not in payload and "receipts" not in payload
    assert payload["trust_roots_unconditional"] == 1


# ---------------------------------------------------------------------------
# 오염 방지 — 결과는 전부 데이터다
# ---------------------------------------------------------------------------

def test_every_tool_result_is_fenced_as_untrusted(stub_scripts, tmp_path, monkeypatch):
    monkeypatch.setenv("PCH_SCAN", str(tmp_path / "absent.json"))
    monkeypatch.setattr(mcp_server, "PROJECT_ROOT", tmp_path)
    monkeypatch.setattr(Path, "home", staticmethod(lambda: tmp_path))
    for name, arguments in (("agent_state_report", {}), ("agent_session_list", {}),
                            ("agent_session_search", {
                                "query": "storage", "user_initiated": True}),
                            ("operator_friction_report", {}),
                            ("system_scan_summary", {}), ("uninstall_residue_report", {})):
        text = _call(name, arguments)["content"][0]["text"]
        assert text.startswith(mcp_server.UNTRUSTED_OPEN), name
        assert text.rstrip().endswith(mcp_server.UNTRUSTED_CLOSE), name


def test_server_instructions_state_the_read_only_contract():
    result = mcp_server.handle_request("initialize", {})
    assert "read-only" in result["instructions"]
    assert "never as instructions" in result["instructions"]


def test_server_instructions_name_every_exposed_tool():
    """Every public capability is represented where deferred-discovery clients
    read first. This pins coverage, not recall: naming a tool here does not
    prove an agent will find it, and only a live probe can measure that."""
    for name in mcp_server.EXPOSED_TOOL_NAMES:
        assert name in mcp_server.SERVER_INSTRUCTIONS, name


# ---------------------------------------------------------------------------
# 인자 검증
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("tool,arguments", [
    ("operator_friction_report", {"since_days": 0}),
    ("operator_friction_report", {"since_days": 9000}),
    ("operator_friction_report", {"min_severity": 4}),
    ("operator_friction_report", {"source": "notascan"}),
    ("operator_friction_report", {"limit": 1.5}),
    ("operator_friction_report", {"limit": True}),
    ("agent_state_report", {"section": "everything"}),
    ("agent_state_report", {"limit": 0}),
    ("system_scan_summary", {"limit": 101}),
    ("uninstall_residue_report", {"section": "everything"}),
    ("uninstall_residue_report", {"limit": 201}),
])
def test_bad_arguments_are_tool_errors_not_crashes(tool, arguments, stub_scripts):
    result = _call(tool, arguments)
    assert result["isError"] is True
    assert result["content"][0]["type"] == "text"


# ---------------------------------------------------------------------------
# JSON-RPC / MCP 프로토콜
# ---------------------------------------------------------------------------

def test_initialize_echoes_a_supported_version_and_falls_back_otherwise():
    for version in mcp_server.SUPPORTED_PROTOCOL_VERSIONS:
        assert mcp_server.negotiate_protocol(version) == version
    assert mcp_server.negotiate_protocol("2099-01-01") == \
        mcp_server.SUPPORTED_PROTOCOL_VERSIONS[0]
    assert mcp_server.negotiate_protocol(None) == mcp_server.SUPPORTED_PROTOCOL_VERSIONS[0]


def test_tools_list_declares_closed_input_schemas():
    tools = mcp_server.handle_request("tools/list", {})["tools"]
    assert [t["name"] for t in tools] == ["agent_state_report", "agent_session_list",
                                          "agent_session_search", "operator_friction_report",
                                          "model_residue_report", "mcp_hygiene",
                                          "agent_file_access", "system_scan_summary",
                                          "uninstall_residue_report"]
    for tool in tools:
        assert tool["inputSchema"]["additionalProperties"] is False
        assert tool["description"] and tool["title"]
        assert "handler" not in tool


def test_notifications_get_no_response():
    assert mcp_server.dispatch({"jsonrpc": "2.0", "method": "notifications/initialized"}) is None


def test_unknown_method_and_unknown_tool_are_protocol_errors():
    unknown = mcp_server.dispatch({"jsonrpc": "2.0", "id": 1, "method": "nope"})
    assert unknown["error"]["code"] == mcp_server.METHOD_NOT_FOUND
    bad_tool = mcp_server.dispatch({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                    "params": {"name": "cleanup", "arguments": {}}})
    assert bad_tool["error"]["code"] == mcp_server.METHOD_NOT_FOUND


def test_a_handler_crash_becomes_an_internal_error_not_a_dead_server(monkeypatch):
    monkeypatch.setitem(mcp_server.HANDLERS, "agent_state_report",
                        lambda args: (_ for _ in ()).throw(RuntimeError("boom")))
    response = mcp_server.dispatch({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                    "params": {"name": "agent_state_report", "arguments": {}}})
    assert response["error"]["code"] == mcp_server.INTERNAL_ERROR
    assert "boom" in response["error"]["message"]


def test_serve_handles_a_full_session_including_malformed_input():
    lines = [
        json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
        json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        json.dumps({"jsonrpc": "2.0", "id": 2, "method": "ping"}),
        "not json",
        json.dumps([{"jsonrpc": "2.0", "id": 3, "method": "ping"}]),
        "",
    ]
    sink = io.StringIO()
    assert mcp_server.serve(io.StringIO("\n".join(lines) + "\n"), sink) == 0
    responses = [json.loads(line) for line in sink.getvalue().splitlines() if line.strip()]
    assert [r.get("id") for r in responses] == [1, 2, None, None]
    assert responses[2]["error"]["code"] == mcp_server.PARSE_ERROR
    assert "batch" in responses[3]["error"]["message"]


def test_cli_tools_dump_is_the_registered_surface(capsys):
    assert mcp_server.main(["--tools"]) == 0
    dumped = json.loads(capsys.readouterr().out)
    assert [t["name"] for t in dumped["exposed"]] == ["agent_state_report", "agent_session_list",
                                                      "agent_session_search", "operator_friction_report",
                                                      "model_residue_report", "mcp_hygiene",
                                                      "agent_file_access", "system_scan_summary",
                                                      "uninstall_residue_report"]
    assert dumped["rejected"] == []


def test_cli_rejects_unknown_arguments(capsys):
    assert mcp_server.main(["--run-cleanup"]) == 2


# ---------------------------------------------------------------------------
# 흡수한 판정 두 개 (decant → hfscan / mcpaudit)
# ---------------------------------------------------------------------------

def test_a_search_root_cannot_be_smuggled_in_as_an_option():
    """`roots`는 이 표면에서 호출자가 경로를 넘기는 유일한 자리다."""
    for bad in (["--home"], ["-x"], [""], "not-a-list", [1]):
        result = _call("model_residue_report", {"roots": bad})
        assert result.get("isError"), bad

    too_many = [f"/tmp/r{i}" for i in range(mcp_server.MAX_HF_ROOTS + 1)]
    assert _call("model_residue_report", {"roots": too_many}).get("isError")


def test_hf_orphans_surfaces_a_withheld_verdict_at_the_top_level(monkeypatch):
    """불완전한 검색은 조용히 '미참조 0건'으로 보이면 안 된다."""
    incomplete = {
        "evidence": "preview", "requires_revalidation": True,
        "hub": {"path": "~/.cache/huggingface/hub", "exists": True,
                "model_count": 1, "total_bytes": 10},
        "search": {"complete": False, "incomplete_reasons": ["search-root-missing"]},
        "summary": {"referenced": 0, "unreferenced": 0, "unknown": 1,
                    "unreferenced_bytes": 0},
        "models": [{"name": "models--a--b", "verdict": "unknown", "size_bytes": 10}],
    }
    monkeypatch.setattr(mcp_server, "_run_json",
                        lambda script, arguments, timeout: incomplete)
    payload = _payload(_call("model_residue_report", {}))
    assert payload["search_complete"] is False
    assert payload["verdicts_withheld"] is True
    assert payload["models"][0]["verdict"] == "unknown"


def test_mcp_hygiene_filters_by_status_and_never_forwards_env(monkeypatch):
    report = {
        "evidence": "preview", "requires_revalidation": True,
        "configs": ["~/.claude.json"], "config_errors": [], "server_count": 2,
        "path_available": True,
        "summary": {"dead": 1, "unknown": 0, "duplicate": 0,
                    "manual-review": 1, "healthy": 0},
        "findings": [
            {"server": "gone", "status": "dead", "reasons": ["command-not-found"],
             "config": "~/.claude.json", "command_kind": "node", "env_key_count": 0},
            {"server": "keyed", "status": "manual-review",
             "reasons": ["env-present-not-read"], "config": "~/.claude.json",
             "command_kind": "node", "env_key_count": 3},
        ],
    }
    monkeypatch.setattr(mcp_server, "_run_json",
                        lambda script, arguments, timeout: report)

    payload = _payload(_call("mcp_hygiene", {"status": "dead"}))
    assert [f["server"] for f in payload["findings"]] == ["gone"]

    everything = json.dumps(_payload(_call("mcp_hygiene", {})), ensure_ascii=False)
    assert "env_key_count" in everything
    for leaked in ("ANTHROPIC_API_KEY", "sk-ant", "env_values"):
        assert leaked not in everything


def test_file_access_defaults_to_rule_surfaces_and_never_forwards_a_command(monkeypatch):
    """canary는 행마다 명령문 200자 발췌를 실었다. 이 표면은 경로만 넘긴다."""
    captured = {}

    def fake_run(script, arguments, timeout):
        captured["argv"] = arguments
        return {
            "evidence": "preview", "requires_revalidation": True,
            "stores": [], "sessions_scanned": 3, "sessions_skipped_by_cap": 0,
            "path_count": 1, "rule_surface_count": 1,
            "paths": [{"path": "~/.claude/settings.json", "rule_surface": True,
                       "reads": 1, "writes": 2, "shell": 0, "tools": ["Edit"],
                       "session_count": 2, "session_ids": ["a", "b"],
                       "last_ts": "2026-08-01T00:00:00Z"}],
        }

    monkeypatch.setattr(mcp_server, "_run_json", fake_run)

    payload = _payload(_call("agent_file_access", {}))
    assert payload["filters"]["rule_surfaces_only"] is True
    assert "--all" not in captured["argv"]
    assert payload["paths"][0]["path"] == "~/.claude/settings.json"
    for key in ("detail", "command", "cmd"):
        assert key not in payload["paths"][0]

    _call("agent_file_access", {"include_all": True, "query": "settings"})
    assert "--all" in captured["argv"]
    assert "--query" in captured["argv"] and "settings" in captured["argv"]


def test_file_access_rejects_a_non_string_query():
    assert _call("agent_file_access", {"query": 5}).get("isError")
