import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import time

import pytest

spec = importlib.util.spec_from_file_location("backup_reclaim", Path(__file__).resolve().parents[1] / "scripts/backup_reclaim.py")
reclaim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reclaim)


@pytest.fixture
def folders(tmp_path):
    root = tmp_path.resolve()
    home, backup, state = root / "home", root / "ssd", root / "records"
    local = home / "Documents"
    local.mkdir(parents=True)
    backup.mkdir()
    return home, local, backup, state


def pair(folders, name="report.txt", data=b"retained work"):
    _, local, backup, _ = folders
    for root in (local, backup):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return local / name, backup / name


def preview(folders, **kwargs):
    home, local, backup, state = folders
    return reclaim.scan(local, backup, home=home, state=state, opened=set(), require_external=False, **kwargs)


def apply(folders, plan, **kwargs):
    home, _, _, state = folders
    return reclaim.execute(plan["planID"], [r["id"] for r in plan["rows"] if r["status"] == "identical"],
                           approved=True, home=home, state=state, **kwargs)


def test_actual_delete_keeps_backup_and_receipts(folders):
    local, backup = pair(folders)
    plan = preview(folders)
    assert plan["rows"][0]["status"] == "identical"
    result = apply(folders, plan, opened=set())
    assert result["status"] == "finished"
    assert not local.exists()
    assert backup.read_bytes() == b"retained work"
    assert result["deletedBytes"] == len(b"retained work")
    assert Path(result["receiptPath"]).is_file()
    events = [json.loads(line)["event"] for line in Path(result["journalPath"]).read_text().splitlines()]
    assert events == ["stage-intent", "staged", "verified-delete-intent", "deleted"]
    with pytest.raises(FileExistsError):
        apply(folders, plan, opened=set())


@pytest.mark.parametrize("side", [0, 1])
def test_changed_file_cannot_use_old_approval(folders, side):
    paths = pair(folders)
    plan = preview(folders)
    paths[side].write_bytes(b"changed work!")
    result = apply(folders, plan, opened=set())
    assert result["items"][0]["status"] == "blocked"
    assert paths[0].exists() and paths[1].exists()


def test_equal_replacement_inode_is_blocked(folders):
    local, backup = pair(folders)
    plan = preview(folders)
    replacement = backup.parent / "replacement"
    replacement.write_bytes(backup.read_bytes())
    os.replace(replacement, backup)
    assert apply(folders, plan, opened=set())["deletedBytes"] == 0
    assert local.exists()


def test_open_file_and_unavailable_process_evidence_block(folders, monkeypatch):
    local, _ = pair(folders)
    plan = preview(folders)
    assert apply(folders, plan, opened={str(local)})["deletedBytes"] == 0
    def fail():
        raise reclaim.ReclaimError("process inspection failed")
    monkeypatch.setattr(reclaim, "visible_open_paths", fail)
    home, source, backup, state = folders
    result = reclaim.scan(source, backup, home=home, state=state, require_external=False)
    assert not result["processCheck"]
    assert result["rows"][0]["status"] == "unverified"


@pytest.mark.parametrize("name", ["project/.git/HEAD", "project/file.txt", ".env", "session.jsonl", "database.sqlite", "Photo.photoslibrary/photo.jpg", "DerivedData-Project/Index.noindex/file", "node_modules/package/index.js", "AuthKey_example.p8", "credentials.json"])
def test_protected_data_is_listed_and_not_selectable(folders, name):
    pair(folders, name)
    if name.startswith("project/"):
        (folders[1] / "project/.git").mkdir(exist_ok=True)
    plan = preview(folders)
    assert plan["rows"]
    assert all(row["status"] == "protected" for row in plan["rows"])


def test_ai_home_library_and_nested_repo_selection_protected(folders):
    home, _, backup, state = folders
    for relative in [".codex/sessions", ".claude/projects", "Library/Application Support/Codex", "Documents/repo/subdir"]:
        local = home / relative
        local.mkdir(parents=True)
        (local / "original.txt").write_text("keep")
        if "repo" in relative:
            (home / "Documents/repo/.git").write_text("gitdir: elsewhere")
        plan = reclaim.scan(local, backup, home=home, state=state, opened=set(), require_external=False)
        assert plan["rows"][0]["status"] == "protected"


def test_symlink_and_backup_symlink_and_hardlinks_blocked(folders):
    local, backup = pair(folders)
    backup.rename(backup.with_suffix(".keep"))
    backup.symlink_to(backup.with_suffix(".keep"))
    assert preview(folders)["rows"][0]["status"] == "unverified"
    backup.unlink()
    os.link(backup.with_suffix(".keep"), backup)
    assert preview(folders)["rows"][0]["status"] == "unverified"
    (local.parent / "linked").symlink_to(local)
    assert any(row["path"] == "linked" and row["status"] == "protected" for row in preview(folders)["rows"])


def test_xattr_mismatch_blocks_resource_fork_or_tags_loss(folders):
    local, _ = pair(folders)
    key = "com.apple.metadata:_kMDItemUserTags" if sys.platform == "darwin" else "user.tag"
    if sys.platform == "darwin":
        subprocess.run(["/usr/bin/xattr", "-w", key, "private-tag", str(local)], check=True)
    else:
        os.setxattr(local, key, b"private-tag")
    assert preview(folders)["rows"][0]["status"] == "metadata"


def test_compare_checks_same_size_content_and_missing_file(folders):
    _, backup = pair(folders)
    backup.write_bytes(b"different txt")
    assert preview(folders)["rows"][0]["status"] == "different"
    backup.unlink()
    assert preview(folders)["rows"][0]["status"] == "missing"


def test_partial_scan_reports_coverage_and_no_implicit_selection(folders):
    for name in ("a.txt", "b.txt", "c.txt"):
        pair(folders, name)
    plan = preview(folders, limit=1)
    assert not plan["complete"] and len(plan["rows"]) == 1
    assert plan["warnings"]


def test_expiry_approval_and_overlapping_volume_guards(folders):
    pair(folders)
    home, local, backup, state = folders
    with pytest.raises(reclaim.ReclaimError):
        reclaim.scan(local, backup, home=home, state=state, opened=set())
    with pytest.raises(reclaim.ReclaimError):
        reclaim.scan(local, local, home=home, state=state, opened=set(), require_external=False)
    plan = preview(folders)
    with pytest.raises(reclaim.ReclaimError):
        reclaim.execute(plan["planID"], [plan["rows"][0]["id"]], home=home, state=state)
    plan["expiresAt"] = time.time() - 1
    (state / (plan["planID"] + ".json")).write_text(json.dumps(plan))
    with pytest.raises(reclaim.ReclaimError):
        apply(folders, plan, opened=set())


def test_replaced_root_is_blocked(folders):
    pair(folders)
    plan = preview(folders)
    backup = folders[2]
    backup.rename(backup.with_name("old-ssd"))
    backup.mkdir()
    with pytest.raises(reclaim.ReclaimError):
        apply(folders, plan, opened=set())


def test_stop_after_staging_restores_source_without_deleting_backup(folders, monkeypatch):
    local, backup = pair(folders)
    plan = preview(folders)
    original = reclaim.digest
    calls = 0
    def stop(fd, deadline=None):
        nonlocal calls
        calls += 1
        if calls == 3:
            raise KeyboardInterrupt()
        return original(fd, deadline)
    monkeypatch.setattr(reclaim, "digest", stop)
    with pytest.raises(KeyboardInterrupt):
        apply(folders, plan, opened=set())
    assert local.read_bytes() == backup.read_bytes()
    receipt = json.loads((folders[3] / (plan["planID"] + ".receipt.json")).read_text())
    assert receipt["status"] == "interrupted"


def test_rename_race_never_deletes_unverified_replacement(folders, monkeypatch):
    local, backup = pair(folders)
    plan = preview(folders)
    original = os.rename
    def swap(src, dst, *, src_dir_fd, dst_dir_fd):
        original(local, local.with_name("kept-original"))
        local.write_bytes(b"new content must survive")
        return original(src, dst, src_dir_fd=src_dir_fd, dst_dir_fd=dst_dir_fd)
    monkeypatch.setattr(reclaim.os, "rename", swap)
    result = apply(folders, plan, opened=set())
    assert result["deletedBytes"] == 0
    recovered = list(local.parent.glob(".modore-reclaim-*/report.txt"))
    assert len(recovered) == 1
    assert recovered[0].read_bytes() == b"new content must survive"
    assert backup.read_bytes() == b"retained work"
