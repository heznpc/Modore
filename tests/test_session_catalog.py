"""Catalog contracts use synthetic stores; no owner transcripts are fixtures."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time

import pytest

import scree
import session_catalog as catalog


SESSION = "00000000-0000-4000-8000-000000000001"


def rollout(root, name, *, session=SESSION, workspace="/synthetic/project", epoch=1700000000):
    path = root / "sessions" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"type": "session_meta", "payload": {
        "id": session, "cwd": workspace, "session_id": "unrelated-parent" if session else None,
        "auth": "SECRET_AUTH", "title": "BODY_DERIVED_TITLE_NOT_ALLOWED"}}) + "\n"
        + json.dumps({"type": "response_item", "payload": {
            "content": "SECRET_BODY", "command": "SECRET_COMMAND"}}) + "\n")
    os.utime(path, (epoch, epoch))
    return path


def forbid_content(monkeypatch):
    def fail(*args, **kwargs):
        raise AssertionError("catalog must not invoke a content reader")
    for name in ("build_title", "build_titles_many", "build_search", "build_inspect",
                 "build_evidence", "_read_session_turns", "visible_turns"):
        monkeypatch.setattr(scree, name, fail)


def test_real_collectors_deduplicate_fragments_without_titles_or_body_output(tmp_path, monkeypatch):
    forbid_content(monkeypatch)
    home = tmp_path / "home"
    first = rollout(home / ".codex", "a.jsonl")
    rollout(home / ".codex", "b.jsonl", epoch=1700001000)
    archive = home / ".codex" / "archived_sessions" / "copy.jsonl"
    archive.parent.mkdir()
    archive.write_bytes(first.read_bytes())
    os.utime(archive, (1700000000, 1700000000))
    result = catalog.build_catalog(home)
    assert result["schemaVersion"] == 1
    assert result["source"] == "modore"
    assert result["generatedAt"].endswith("Z")
    assert result["scan"] == {"complete": True, "truncated": False, "errors": []}
    assert len(result["sessions"]) == 1
    item = result["sessions"][0]
    assert item["providerSessionId"] == SESSION
    assert item["profileKey"] is None
    assert item["lastActivityAt"] == "2023-11-14T22:30:00.000000Z"
    assert set(item) == {"key", "provider", "providerSessionId", "profileKey",
                         "workspacePath", "lastActivityAt", "provenance"}
    assert item["provenance"] == "local-metadata"
    encoded = json.dumps(result)
    for forbidden in ("SECRET_", "BODY_DERIVED", "unrelated-parent", str(first), "running", "completed"):
        assert forbidden not in encoded
    # Another fragment does not change the logical identity.
    rollout(home / ".codex", "c.jsonl", epoch=1700002000)
    assert catalog.build_catalog(home)["sessions"][0]["key"] == item["key"]


def test_profiles_keep_same_ids_separate_and_report_collisions(tmp_path):
    home = tmp_path / "home"
    root_a, root_b = tmp_path / "profile-a", tmp_path / "profile-b"
    rollout(home / ".codex", "default.jsonl")
    rollout(root_a, "a.jsonl")
    rollout(root_b, "b.jsonl")
    result = catalog.build_catalog(home, codex_profiles=[("work", root_a), ("work", root_b)])
    assert len(result["sessions"]) == 3
    assert len({s["key"] for s in result["sessions"]}) == 3
    assert {s["profileKey"] for s in result["sessions"]} == {None, "work"}
    assert result["scan"] == {"complete": False, "truncated": False, "errors": [
        "codex:profile-key-conflict", "codex:session-id-in-multiple-scopes"]}


def test_conflicting_names_for_one_profile_become_unknown(tmp_path):
    home = tmp_path / "home"
    root = home / ".codex"
    rollout(root, "a.jsonl")
    result = catalog.build_catalog(home, codex_profiles=[("a", root), ("b", root)])
    assert len(result["sessions"]) == 1
    assert result["sessions"][0]["profileKey"] is None
    assert result["scan"]["errors"] == ["codex:profile-root-conflict"]


def test_explicit_default_profile_is_not_scanned_twice(tmp_path):
    root = tmp_path / ".codex"
    rollout(root, "a.jsonl")
    result = catalog.build_catalog(tmp_path, codex_profiles=[("local", root), ("local", root)])
    assert len(result["sessions"]) == 1
    assert result["sessions"][0]["profileKey"] == "local"
    assert result["scan"]["complete"]


def test_missing_explicit_profile_is_incomplete(tmp_path):
    result = catalog.build_catalog(tmp_path, codex_profiles=[("missing", tmp_path / "absent")])
    assert not result["scan"]["complete"]
    assert "codex:explicit-profile-missing" in result["scan"]["errors"]


def test_unidentified_sessions_remain_separate(tmp_path):
    for name in ("a.jsonl", "b.jsonl"):
        rollout(tmp_path / ".codex", name, session=None)
    result = catalog.build_catalog(tmp_path)
    assert len(result["sessions"]) == 2
    assert all(s["providerSessionId"] is None for s in result["sessions"])
    assert len({s["key"] for s in result["sessions"]}) == 2


def test_workspace_conflict_does_not_pick_newest_path(tmp_path):
    rollout(tmp_path / ".codex", "a.jsonl", workspace="/synthetic/a")
    rollout(tmp_path / ".codex", "b.jsonl", workspace="/synthetic/b", epoch=1700001000)
    result = catalog.build_catalog(tmp_path)
    assert len(result["sessions"]) == 1
    assert result["sessions"][0]["workspacePath"] is None
    assert result["scan"]["errors"][0].endswith(":workspace-conflict")


def test_desktop_unknown_account_namespaces_are_not_merged(tmp_path):
    records = [{"kind": "session", "tool": "Claude Desktop", "session_id": "local_same",
                "source": str(tmp_path / name / "local_same.json"),
                "last_active": 1700000000, "workspace": "/synthetic/project",
                "desktop_metadata": {"title": "Metadata title", "auth": "SECRET_AUTH"}}
               for name in ("account-a", "account-b")]
    result = catalog._project(records, [], tmp_path, {}, set())
    assert len(result["sessions"]) == 2
    assert all(s["profileKey"] is None and s["title"] == "Metadata title" for s in result["sessions"])
    assert result["scan"]["errors"] == ["claude-desktop:session-id-in-multiple-scopes"]
    assert "SECRET_AUTH" not in json.dumps(result)


def test_claude_filename_identity_and_gemini_unknown_id(tmp_path):
    records = [{"kind": "session", "tool": tool, "source": str(tmp_path / name),
                "last_active": None, "workspace": ""}
               for tool, name in (("Claude", SESSION + ".jsonl"), ("Gemini", "session-short.json"))]
    records.append({"kind": "workspace_state", "tool": "Cursor", "source": "editor-state"})
    result = catalog._project(records, [], tmp_path, {}, set())
    rows = {s["provider"]: s for s in result["sessions"]}
    assert len(rows) == 2
    assert rows["claude"]["providerSessionId"] == SESSION
    assert rows["gemini"]["providerSessionId"] is None
    assert all(s["lastActivityAt"] is None for s in rows.values())
    assert not result["scan"]["complete"]


def test_coverage_and_limit_remain_explicit(tmp_path):
    rollout(tmp_path / ".codex", "a.jsonl")
    rollout(tmp_path / ".codex", "b.jsonl", session="second")
    bad = tmp_path / ".codex" / "sessions" / "broken.jsonl"
    bad.write_text("invalid metadata SECRET_PARSE\n")
    result = catalog.build_catalog(tmp_path, limit=1)
    assert len(result["sessions"]) == 1
    assert not result["scan"]["complete"] and result["scan"]["truncated"]
    assert set(result["scan"]["errors"]) == {
        "catalog:limit", "codex:scan-unrecognized", "codex:unrecognized-metadata"}
    assert "SECRET_PARSE" not in json.dumps(result)


def test_truncated_collectors_and_symlinks_never_claim_complete(tmp_path, monkeypatch):
    rollout(tmp_path / ".codex", "a.jsonl")
    discover = scree._discover_regular_files_nofollow
    def bounded(*args, **kwargs):
        return discover(*args, **{**kwargs, "maximum_entries": 0})
    monkeypatch.setattr(scree, "_discover_regular_files_nofollow", bounded)
    result = catalog.build_catalog(tmp_path)
    assert not result["scan"]["complete"] and result["scan"]["truncated"]
    monkeypatch.undo()
    foreign = tmp_path / "elsewhere"
    rollout(foreign, "secret.jsonl")
    (tmp_path / ".codex" / "sessions" / "linked.jsonl").symlink_to(foreign / "sessions" / "secret.jsonl")
    result = catalog.build_catalog(tmp_path)
    assert not result["scan"]["complete"]
    assert len(result["sessions"]) == 1


def test_worker_timeout_and_error_do_not_leak_exception_text(tmp_path, monkeypatch):
    monkeypatch.setattr(scree, "collect_session_metadata", lambda *_: time.sleep(10))
    start = time.monotonic()
    result = catalog.build_catalog(tmp_path, budget_seconds=0.05)
    assert time.monotonic() - start < 3
    assert result["sessions"] == []
    assert result["scan"] == {"complete": False, "truncated": True,
                               "errors": ["discovery:worker-time"]}
    def fail(*args):
        raise OSError("SECRET_EXCEPTION")
    monkeypatch.setattr(scree, "collect_session_metadata", fail)
    result = catalog.build_catalog(tmp_path)
    assert not result["scan"]["complete"]
    assert "SECRET_EXCEPTION" not in json.dumps(result)


def test_cli_private_create_only_export_and_incomplete_exit(tmp_path):
    home = tmp_path / "home"
    rollout(home / ".codex", "a.jsonl")
    out = tmp_path / "private" / "catalog.json"
    command = [sys.executable, "-I", "-B", str(Path(catalog.__file__)), "--home", str(home), "--out", str(out)]
    first = subprocess.run(command, text=True, capture_output=True)
    assert first.returncode == 0, first.stderr
    assert json.loads(first.stdout)["outputPath"] == str(out)
    assert stat.S_IMODE(out.stat().st_mode) == 0o600
    original = out.read_bytes()
    second = subprocess.run(command, text=True, capture_output=True)
    assert second.returncode == 0
    sibling = Path(json.loads(second.stdout)["outputPath"])
    assert sibling != out and sibling.exists()
    assert out.read_bytes() == original
    assert stat.S_IMODE(sibling.stat().st_mode) == 0o600
    rollout(home / ".codex", "b.jsonl", session="second")
    partial = subprocess.run(command + ["--limit", "1"], text=True, capture_output=True)
    assert partial.returncode == 1
    assert not json.loads(partial.stdout)["scan"]["complete"]


@pytest.mark.parametrize("kwargs", [{"limit": -1}, {"budget_seconds": 0},
    {"budget_seconds": float("nan")}, {"budget_seconds": 61},
    {"codex_profiles": [("bad\nkey", Path("/synthetic"))]}])
def test_invalid_arguments(tmp_path, kwargs):
    with pytest.raises(ValueError):
        catalog.build_catalog(tmp_path, **kwargs)
