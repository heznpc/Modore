"""Recovery tests use synthetic homes only, never the user's provider records."""
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import threading
import time

import pytest

import session_recovery as recovery


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")
    return path


def jsonl(path, *rows):
    return write(path, "".join(json.dumps(r) + "\n" for r in rows))


@pytest.fixture
def home(tmp_path):
    root = tmp_path / "home"
    meta = {"type": "session_meta", "payload": {
        "id": "codex-one", "cwd": "/fixture/project",
        "git": {"branch": "main", "commit_hash": "a" * 40}}}
    jsonl(root / ".codex/sessions/2026/01/fragment-a.jsonl", meta,
          {"type": "response_item", "payload": {"content": "private first fragment"}})
    jsonl(root / ".codex/sessions/2026/02/fragment-b.jsonl", meta,
          {"type": "response_item", "payload": {"content": "private second fragment"}})
    jsonl(root / ".codex/sessions/2026/02/unbound.jsonl",
          {"type": "session_meta", "payload": {"id": "codex-unbound"}})
    jsonl(root / ".claude/projects/-fixture-project/claude-one.jsonl",
          {"sessionId": "claude-one", "cwd": "/fixture/project", "type": "user",
           "message": {"content": "private Claude prompt"}})
    jsonl(root / ".claude/projects/-fixture-project/claude-one/subagents/agent-a.jsonl",
          {"type": "assistant", "message": {"content": "private subagent result"}})
    write(root / ".claude/projects/-fixture-project/claude-one/tool-results/.result.txt",
          "private tool output")
    write(root / ".claude/file-history/claude-one/snapshot@v1", "original file bytes")
    write(root / ".claude/image-cache/claude-one/image.png", "fixture image bytes")
    write(root / ".codex/auth.json", "must never be included")
    write(root / ".claude/projects/-fixture-project/.env", "must never be included")
    write(root / ".claude/projects/-fixture-project/node_modules/package/a.js", "excluded")
    return root


def do_backup(home, destination, ids=None):
    return recovery.backup(destination, ids or ["codex.sessions", "claude.projects",
                                               "claude.file-history", "claude.image-cache"],
                           home, include_sensitive=True)


def test_plan_metadata_only_covers_fragments_unbound_and_unsupported(home):
    jsonl(home / ".claude/projects/-fixture-project/claude-one/subagents/agent-with-id.jsonl",
          {"id": "message-id", "sessionId": "subagent-id", "cwd": "/fixture/project"})
    write(home / ".codex/sessions/2026/01/tool-result.json", '{"id":"tool-result-id"}')
    result = recovery.plan(home)
    assert result["schemaVersion"] == 1
    coverage = {row["provider"]: row for row in result["coverage"]}
    assert coverage["Codex"]["recordCount"] == 2
    assert coverage["Codex"]["gitLinkedCount"] == 1
    assert coverage["Codex"]["unassignedCount"] == 1
    assert coverage["Claude Code"]["folderLinkedCount"] == 1
    assert coverage["Claude Code"]["recordCount"] == 1
    assert "Unsupported" in coverage["Gemini"]["resumeSupport"]
    output = json.dumps(result)
    assert "private first fragment" not in output
    assert "private Claude prompt" not in output
    assert "not remote preservation" in output
    assert "uncommitted work" in output
    assert "custom CODEX_HOME" in output


def test_end_to_end_raw_bytes_sidecars_hidden_files_and_new_parent(home, tmp_path):
    source = home / ".claude/file-history/claude-one/snapshot@v1"
    source.chmod(0o640)
    os.utime(source, ns=(1234567890000000000, 1234567890000000000))
    bundle = tmp_path / "SSD/Backup/2026-09-27/fresh-bundle"
    receipt = do_backup(home, bundle)
    assert receipt["status"] == "verified"
    assert recovery.verify(bundle) == receipt
    manifest = json.loads((bundle / "manifest.json").read_text())
    assert next(c for c in manifest["coverage"] if c["provider"] == "Codex")["recordCount"] == 2
    included = {row["path"] for row in manifest["files"]}
    assert ".codex/sessions/2026/01/fragment-a.jsonl" in included
    assert ".codex/sessions/2026/02/fragment-b.jsonl" in included
    assert ".codex/sessions/2026/02/unbound.jsonl" in included
    assert ".claude/projects/-fixture-project/claude-one/subagents/agent-a.jsonl" in included
    assert ".claude/projects/-fixture-project/claude-one/tool-results/.result.txt" in included
    assert not any("auth.json" in p or "node_modules" in p or p.endswith(".env") for p in included)
    destination = tmp_path / "new-mac/recovered-home"
    restored = recovery.restore(bundle, destination)
    assert restored["status"] == "restored"
    assert restored["restoredRoot"] == str(destination)
    assert (destination / recovery.RESTORED_MANIFEST).is_file()
    for path in included:
        assert (destination / path).read_bytes() == (home / path).read_bytes()
    copied = destination / source.relative_to(home)
    assert copied.stat().st_mode & 0o777 == 0o640
    assert copied.stat().st_mtime_ns == source.stat().st_mtime_ns


def test_sqlite_wal_online_snapshot_is_consistent_with_open_writer(home, tmp_path):
    database = home / ".codex/state_5.sqlite"
    writer = sqlite3.connect(database)
    writer.execute("PRAGMA journal_mode=WAL")
    writer.execute("PRAGMA wal_autocheckpoint=0")
    writer.execute("CREATE TABLE rows (id INTEGER PRIMARY KEY, data TEXT)")
    writer.executemany("INSERT INTO rows(data) VALUES (?)", [("x" * 1024,)] * 2000)
    writer.commit()
    assert Path(str(database) + "-wal").stat().st_size > 0
    stop = threading.Event()
    wrote = threading.Event()
    failures = []

    def concurrent_writer():
        try:
            with sqlite3.connect(database) as connection:
                while not stop.is_set():
                    connection.execute("INSERT INTO rows(data) VALUES ('during snapshot')")
                    connection.commit()
                    wrote.set()
                    stop.wait(0.005)
        except Exception as exc:
            failures.append(exc)

    thread = threading.Thread(target=concurrent_writer)
    thread.start()
    try:
        assert wrote.wait(5)
        bundle = tmp_path / "sqlite-bundle"
        do_backup(home, bundle, ["codex.databases"])
        restored = tmp_path / "sqlite-restored"
        recovery.restore(bundle, restored)
        with sqlite3.connect(restored / ".codex/state_5.sqlite") as snapshot:
            assert snapshot.execute("PRAGMA integrity_check").fetchone() == ("ok",)
            assert snapshot.execute("SELECT COUNT(*) FROM rows").fetchone()[0] >= 2001
        assert not list((bundle / "payload/.codex").glob("*-wal"))
        assert not list((bundle / "payload/.codex").glob("*-shm"))
    finally:
        stop.set()
        thread.join(5)
        writer.close()
    assert not failures


@pytest.mark.parametrize("suffix", ["-wal", "-shm", "-journal"])
def test_sqlite_external_companion_symlinks_are_rejected_before_connect(home, tmp_path, monkeypatch, suffix):
    database = home / ".codex/state_5.sqlite"
    connection = sqlite3.connect(database)
    connection.execute("CREATE TABLE records (id INTEGER)")
    connection.commit()
    connection.close()
    external = write(tmp_path / "outside-companion", "must not be opened as SQLite data")
    Path(str(database) + suffix).symlink_to(external)

    def never_connect(*args, **kwargs):
        raise AssertionError("unsafe SQLite companions must be rejected before SQLite opens them")

    monkeypatch.setattr(recovery.sqlite3, "connect", never_connect)
    bundle = tmp_path / "unsafe-db-bundle"
    with pytest.raises(recovery.RecoveryError, match="companion.*non-symlink"):
        do_backup(home, bundle, ["codex.databases"])
    assert not bundle.exists()
    assert external.read_text() == "must not be opened as SQLite data"


def test_sqlite_parent_namespace_is_checked_after_open(home, tmp_path, monkeypatch):
    database = home / ".codex/state_5.sqlite"
    connection = sqlite3.connect(database)
    connection.execute("CREATE TABLE records (id INTEGER)")
    connection.commit()
    connection.close()
    original_connect = recovery.sqlite3.connect
    moved = home / ".codex-moved"
    swapped = False

    def replace_parent(*args, **kwargs):
        nonlocal swapped
        connection = original_connect(*args, **kwargs)
        if not swapped:
            database.parent.rename(moved)
            database.parent.symlink_to(moved, target_is_directory=True)
            swapped = True
        return connection

    monkeypatch.setattr(recovery.sqlite3, "connect", replace_parent)
    bundle = tmp_path / "replaced-parent-bundle"
    with pytest.raises(OSError):
        do_backup(home, bundle, ["codex.databases"])
    assert not bundle.exists()
    assert (moved / database.name).is_file()


def test_corruption_extra_payload_and_path_traversal_are_rejected(home, tmp_path):
    bundle = tmp_path / "bundle"
    do_backup(home, bundle)
    payload = bundle / "payload/.codex/sessions/2026/01/fragment-a.jsonl"
    original = payload.read_bytes()
    payload.write_bytes(original + b"changed")
    with pytest.raises(recovery.RecoveryError, match="SHA-256"):
        recovery.verify(bundle)
    payload.write_bytes(original)
    extra = write(bundle / "payload/unlisted.txt", "not in manifest")
    with pytest.raises(recovery.RecoveryError, match="inventory"):
        recovery.verify(bundle)
    extra.unlink()
    manifest_path = bundle / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["files"][0]["path"] = "../escape"
    manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(recovery.RecoveryError, match="relative path"):
        recovery.restore(bundle, tmp_path / "must-not-exist")
    assert not (tmp_path / "must-not-exist").exists()


def test_symlinks_preserved_without_following_and_roots_rejected(home, tmp_path):
    outside = write(tmp_path / "outside/secret.txt", "outside must not be read")
    link = home / ".claude/projects/-fixture-project/claude-one/external-link"
    link.symlink_to(outside)
    bundle = tmp_path / "bundle"
    do_backup(home, bundle)
    copied = bundle / "payload" / link.relative_to(home)
    assert copied.is_symlink()
    assert os.readlink(copied) == str(outside)
    manifest = json.loads((bundle / "manifest.json").read_text())
    assert all("secret.txt" not in row["path"] for row in manifest["files"])
    restored = tmp_path / "restored"
    recovery.restore(bundle, restored)
    assert (restored / link.relative_to(home)).is_symlink()
    (home / ".codex/uploads").symlink_to(outside.parent, target_is_directory=True)
    with pytest.raises(recovery.RecoveryError, match="roots cannot be symlinks"):
        do_backup(home, tmp_path / "no-root-link", ["codex.uploads"])
    linked_parent = tmp_path / "linked-parent"
    linked_parent.symlink_to(tmp_path / "outside", target_is_directory=True)
    with pytest.raises(OSError):
        do_backup(home, linked_parent / "new-bundle")
    with pytest.raises(OSError):
        recovery.verify(linked_parent / "bundle")


def test_source_change_causes_failure_and_removes_only_partial_bundle(home, tmp_path, monkeypatch):
    original_copy = recovery._copy_regular
    changed = False

    def changing_copy(root_fd, relative, target_fd, expected):
        nonlocal changed
        result = original_copy(root_fd, relative, target_fd, expected)
        if not changed:
            with (home / relative).open("ab") as file:
                file.write(b"\nchanged by provider\n")
            changed = True
        return result

    monkeypatch.setattr(recovery, "_copy_regular", changing_copy)
    bundle = tmp_path / "partial-bundle"
    with pytest.raises(recovery.RecoveryError, match="changed during backup"):
        do_backup(home, bundle)
    assert not bundle.exists()
    assert (home / ".codex/sessions/2026/01/fragment-a.jsonl").exists()


def test_no_overwrite_overlap_and_sensitive_consent(home, tmp_path):
    bundle = tmp_path / "bundle"
    with pytest.raises(recovery.RecoveryError, match="include-sensitive"):
        recovery.backup(bundle, ["codex.sessions"], home)
    do_backup(home, bundle)
    with pytest.raises(recovery.RecoveryError, match="already exists"):
        do_backup(home, bundle)
    with pytest.raises(recovery.RecoveryError, match="overlaps"):
        do_backup(home, home / ".codex/new-bundle")
    with pytest.raises(recovery.RecoveryError, match="overlaps"):
        do_backup(home, home / ".CODEX/new-bundle")
    with pytest.raises(recovery.RecoveryError, match="overlaps"):
        recovery.restore(bundle, bundle / "restored")
    with pytest.raises(recovery.RecoveryError, match="overlaps"):
        recovery.restore(bundle, bundle.with_name("BUNDLE") / "restored")
    with pytest.raises(recovery.RecoveryError, match="overlaps"):
        recovery.restore(bundle, home / ".CLAUDE/restored")
    with pytest.raises(recovery.RecoveryError, match="traversal"):
        recovery.verify(bundle / ".." / "bundle")
    existing = tmp_path / "existing"
    existing.mkdir()
    with pytest.raises(recovery.RecoveryError, match="already exists"):
        recovery.restore(bundle, existing)


@pytest.mark.parametrize("source_home", [None, {}, ["/home"], "relative/home", "/home/../other",
                                         "/home//other", "/", "/home/./other", "/home\\other"])
def test_manifest_source_home_must_be_an_absolute_normal_path(home, tmp_path, source_home):
    bundle = tmp_path / "bundle"
    do_backup(home, bundle)
    manifest_path = bundle / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["sourceHome"] = source_home
    manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(recovery.RecoveryError, match="sourceHome"):
        recovery.restore(bundle, tmp_path / "never-created")
    assert not (tmp_path / "never-created").exists()


def test_hardlinks_are_copied_independently_and_forged_parent_rejected(home, tmp_path):
    source = home / ".codex/sessions/2026/01/fragment-a.jsonl"
    linked = source.parent / "same-inode.jsonl"
    os.link(source, linked)
    bundle = tmp_path / "bundle"
    do_backup(home, bundle)
    copied = bundle / "payload" / source.relative_to(home)
    copied_link = bundle / "payload" / linked.relative_to(home)
    assert copied.read_bytes() == copied_link.read_bytes()
    assert copied.stat().st_ino != copied_link.stat().st_ino
    restored = tmp_path / "restored"
    recovery.restore(bundle, restored)
    assert (restored / source.relative_to(home)).stat().st_ino != (restored / linked.relative_to(home)).stat().st_ino
    manifest_path = bundle / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    first = manifest["files"][0]
    manifest["files"].append({**first, "path": first["path"] + "/nested"})
    manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(recovery.RecoveryError, match="directory"):
        recovery.verify(bundle)


def test_plan_separates_changing_metadata_from_available_stores(home, monkeypatch):
    original = recovery._metadata

    def changing_metadata(root, entry):
        if entry["path"].endswith("fragment-a.jsonl"):
            raise recovery.RecoveryError("source changed during metadata planning")
        return original(root, entry)

    monkeypatch.setattr(recovery, "_metadata", changing_metadata)
    result = recovery.plan(home)
    item = next(i for i in result["items"] if i["id"] == "codex.sessions")
    assert item["available"] is True
    assert item["fileCount"] == 3
    assert "Available" in item["reason"]
    assert "association counts incomplete" in item["reason"]
    assert "Unavailable" not in item["reason"]
    assert any("association counts are incomplete" in w for w in result["warnings"])


def test_desktop_local_records_are_included_cloud_and_runtime_are_not(home, tmp_path):
    base = home / "Library/Application Support/Claude/local-agent-mode-sessions/user/org/local_abc"
    write(base.with_suffix(".json"), json.dumps({"id": "local_abc", "userSelectedFolders": ["/work"]}))
    write(base / "outputs/note.md", "local result")
    write(base / "runtime/huge.img", "excluded runtime")
    write(base / "machine.qcow2", "excluded VM")
    bundle = tmp_path / "desktop"
    result = do_backup(home, bundle, ["desktop.local-agent"])
    assert result["providers"] == ["Claude Desktop"]
    manifest = json.loads((bundle / "manifest.json").read_text())
    assert len(manifest["files"]) == 2
    assert next(c for c in manifest["coverage"] if c["provider"] == "Claude Desktop")["recordCount"] == 1
    assert any("Desktop" in warning and "cloud-only" in warning for warning in result["warnings"])


def test_cli_json_only_and_isolated_stdlib_runtime(home, tmp_path):
    script = Path(recovery.__file__)
    proc = subprocess.run([sys.executable, "-I", "-B", str(script), "plan", "--home", str(home)],
                          text=True, capture_output=True, check=True)
    assert json.loads(proc.stdout)["status"] == "planned"
    assert not proc.stderr
    invalid = subprocess.run([sys.executable, "-I", "-B", str(script), "backup"],
                             text=True, capture_output=True)
    assert invalid.returncode == 1
    assert json.loads(invalid.stdout)["status"] == "error"
    assert not invalid.stderr


@pytest.mark.parametrize("cancel_signal", [signal.SIGTERM, signal.SIGINT])
def test_process_cancellation_runs_cleanup_and_returns_json(home, tmp_path, cancel_signal):
    marker = tmp_path / "copy-started"
    bundle = tmp_path / "cancelled-bundle"
    code = """
import sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import session_recovery as r
original = r._copy_regular
def slow_copy(*args):
    Path(sys.argv[4]).write_text('started')
    time.sleep(30)
    return original(*args)
r._copy_regular = slow_copy
raise SystemExit(r.main(['backup', '--home', sys.argv[2], '--destination', sys.argv[3],
                        '--items-json', '["codex.sessions"]', '--include-sensitive']))
"""
    process = subprocess.Popen([sys.executable, "-I", "-B", "-c", code,
                                str(Path(recovery.__file__).parent), str(home),
                                str(bundle), str(marker)],
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 5
        while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        assert marker.exists()
        process.send_signal(cancel_signal)
        stdout, stderr = process.communicate(timeout=5)
        assert process.returncode == 1
        assert json.loads(stdout)["cancelled"] is True
        assert not stderr
        assert not bundle.exists()
        assert (home / ".codex/sessions/2026/01/fragment-a.jsonl").exists()
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()
