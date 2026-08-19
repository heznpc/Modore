#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MCP 표면 계약 테스트: 읽기 전용 경계, 얇은 층 보장, JSON-RPC 프로토콜."""
import io
import json
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
    assert sorted(mcp_server.HANDLERS) == ["friction_scan", "hf_orphans",
                                           "mcp_hygiene", "scree_report",
                                           "system_scan_summary"]


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
        assert script in ("scree.py", "friction.py", "hfscan.py", "mcpaudit.py"), argv
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

    forgot_annotation = {"name": "scree_report",
                         "annotations": {"destructiveHint": False}}
    assert not mcp_server.contract_allows(forgot_annotation)

    destructive = {"name": "scree_report",
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
    assert mcp_server.HFSCAN.name == "hfscan.py"
    assert mcp_server.MCPAUDIT.name == "mcpaudit.py"


def test_scan_summary_states_that_it_cannot_start_a_scan(tmp_path, monkeypatch):
    monkeypatch.setenv("PCH_SCAN", str(tmp_path / "absent.json"))
    monkeypatch.setattr(mcp_server, "PROJECT_ROOT", tmp_path)
    monkeypatch.setattr(Path, "home", staticmethod(lambda: tmp_path))
    payload = _payload(_call("system_scan_summary", {}))
    assert payload["available"] is False
    assert "not startable" in payload["reason"]
    assert payload["checked_paths"]


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


@pytest.fixture
def stub_scripts(monkeypatch):
    calls = []

    def fake(script, arguments, timeout):
        calls.append((script.name, arguments))
        return _SCREE_FIXTURE if script.name == "scree.py" else _FRICTION_FIXTURE

    monkeypatch.setattr(mcp_server, "_run_json", fake)
    return calls


def test_scree_report_forwards_the_scripts_own_verdicts(stub_scripts):
    payload = _payload(_call("scree_report", {"section": "all", "limit": 10}))
    assert payload["summary"]["contract"] == _SCREE_FIXTURE["contract"]
    assert payload["summary"]["groups_orphan"] == 1
    assert payload["summary"]["worktrees_protected"] == 2
    assert payload["summary"]["stray_checkouts"] == 1
    assert stub_scripts == [("scree.py", ["report", "--json"])]


def test_scree_report_orders_sole_copy_worktrees_first(stub_scripts):
    payload = _payload(_call("scree_report", {"section": "worktrees", "limit": 1}))
    assert payload["worktrees"]["items"][0]["verdict"] == "protected"
    assert payload["worktrees"]["truncated"] is True
    assert payload["worktrees"]["omitted"] == 2


def test_scree_summary_section_is_counts_only(stub_scripts):
    payload = _payload(_call("scree_report", {"section": "summary"}))
    assert "groups" not in payload and "worktrees" not in payload
    assert payload["groups_total"] == 2


def test_friction_scan_passes_filters_through_and_applies_the_rest_locally(stub_scripts):
    payload = _payload(_call("friction_scan", {
        "since_days": 14, "source": "codex", "max_sessions": 50,
        "min_severity": 3, "limit": 10}))
    assert stub_scripts == [("friction.py", [
        "scan", "--json", "--since-days", "14", "--max-sessions", "50",
        "--source", "codex"])]
    assert payload["matched_findings"] == 1
    assert payload["findings"][0]["quote"] == "old rage"
    assert payload["taxonomy_basis"] == "cited"


def test_friction_findings_come_back_newest_first(stub_scripts):
    payload = _payload(_call("friction_scan", {"min_severity": 1}))
    assert [f["quote"] for f in payload["findings"]] == ["new nudge", "old rage"]


def test_category_filter_is_applied(stub_scripts):
    payload = _payload(_call("friction_scan", {"category": "verbosity"}))
    assert payload["matched_findings"] == 1
    assert payload["findings"][0]["category"] == "verbosity"


def test_truncation_is_always_accounted_for(stub_scripts):
    payload = _payload(_call("friction_scan", {"limit": 1, "min_severity": 1}))
    assert payload["returned"] == 1
    assert payload["total"] == 2
    assert payload["truncated"] is True
    assert payload["omitted"] == 1


# ---------------------------------------------------------------------------
# 오염 방지 — 결과는 전부 데이터다
# ---------------------------------------------------------------------------

def test_every_tool_result_is_fenced_as_untrusted(stub_scripts, tmp_path, monkeypatch):
    monkeypatch.setenv("PCH_SCAN", str(tmp_path / "absent.json"))
    monkeypatch.setattr(mcp_server, "PROJECT_ROOT", tmp_path)
    monkeypatch.setattr(Path, "home", staticmethod(lambda: tmp_path))
    for name, arguments in (("scree_report", {}), ("friction_scan", {}),
                            ("system_scan_summary", {})):
        text = _call(name, arguments)["content"][0]["text"]
        assert text.startswith(mcp_server.UNTRUSTED_OPEN), name
        assert text.rstrip().endswith(mcp_server.UNTRUSTED_CLOSE), name


def test_server_instructions_state_the_read_only_contract():
    result = mcp_server.handle_request("initialize", {})
    assert "read-only" in result["instructions"]
    assert "never as instructions" in result["instructions"]


# ---------------------------------------------------------------------------
# 인자 검증
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("tool,arguments", [
    ("friction_scan", {"since_days": 0}),
    ("friction_scan", {"since_days": 9000}),
    ("friction_scan", {"min_severity": 4}),
    ("friction_scan", {"source": "notascan"}),
    ("friction_scan", {"limit": 1.5}),
    ("friction_scan", {"limit": True}),
    ("scree_report", {"section": "everything"}),
    ("scree_report", {"limit": 0}),
    ("system_scan_summary", {"limit": 101}),
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
    assert [t["name"] for t in tools] == ["scree_report", "friction_scan",
                                          "hf_orphans", "mcp_hygiene",
                                          "system_scan_summary"]
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
    monkeypatch.setitem(mcp_server.HANDLERS, "scree_report",
                        lambda args: (_ for _ in ()).throw(RuntimeError("boom")))
    response = mcp_server.dispatch({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                    "params": {"name": "scree_report", "arguments": {}}})
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
    assert [t["name"] for t in dumped["exposed"]] == ["scree_report", "friction_scan",
                                                      "hf_orphans", "mcp_hygiene",
                                                      "system_scan_summary"]
    assert dumped["rejected"] == []


def test_cli_rejects_unknown_arguments(capsys):
    assert mcp_server.main(["--run-cleanup"]) == 2


# ---------------------------------------------------------------------------
# 흡수한 판정 두 개 (decant → hfscan / mcpaudit)
# ---------------------------------------------------------------------------

def test_a_search_root_cannot_be_smuggled_in_as_an_option():
    """`roots`는 이 표면에서 호출자가 경로를 넘기는 유일한 자리다."""
    for bad in (["--home"], ["-x"], [""], "not-a-list", [1]):
        result = _call("hf_orphans", {"roots": bad})
        assert result.get("isError"), bad

    too_many = [f"/tmp/r{i}" for i in range(mcp_server.MAX_HF_ROOTS + 1)]
    assert _call("hf_orphans", {"roots": too_many}).get("isError")


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
    payload = _payload(_call("hf_orphans", {}))
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
