"""Real filesystem tests for compatibility links; never touches user data."""
import importlib.util
import json
from pathlib import Path
import os
import pytest
import time

spec = importlib.util.spec_from_file_location("path_reconnect", Path(__file__).parents[1] / "scripts/path_reconnect.py")
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


@pytest.fixture
def setup(tmp_path):
    # macOS /var is an alias; tests use canonical fixture paths like the UI.
    root = tmp_path.resolve()
    home = root / "home"
    local = home / "Documents"
    local.mkdir(parents=True)
    work = root / "SSD" / "Work"
    work.mkdir(parents=True)
    target = work / "report.txt"
    target.write_text("preserve me")
    return home, local / "report.txt", target, home / "state"


def preview(setup):
    home, local, target, state = setup
    return r.preview(local, target, home=home, state=state, require_external=False)


def connect(setup):
    plan = preview(setup)
    home, _, _, state = setup
    return r.connect(plan["planID"], approved=True, home=home, state=state)


def test_real_file_link_working_copy_edit_and_undo(setup):
    home, local, target, state = setup
    result = connect(setup)
    assert result["status"] == "connected"
    assert local.is_symlink() and local.read_text() == "preserve me"
    local.write_text("new working content")
    assert target.read_text() == "new working content"
    assert r.status(result["connectionID"], home=home, state=state)["status"] == "connected"
    receipt = r.undo(result["connectionID"], approved=True, home=home, state=state)
    assert receipt["status"] == "disconnected"
    assert not local.exists() and not local.is_symlink()
    assert target.read_text() == "new working content"
    assert not list(local.parent.glob(".modore-reconnect-*"))


def test_directory_project_link(setup):
    home, local, target, state = setup
    target.unlink()
    target.mkdir()
    (target / "source.py").write_text("pass")
    (target / ".git").write_text("gitdir: /missing/worktree")
    result = connect(setup)
    assert result["targetKind"] == "directory"
    assert (local / "source.py").read_text() == "pass"
    assert (local / ".git").read_text() == "gitdir: /missing/worktree"
    r.undo(result["connectionID"], approved=True, home=home, state=state)
    assert (target / "source.py").exists()


@pytest.mark.parametrize("kind", ["file", "directory", "dangling-link", "live-link"])
def test_existing_original_never_overwritten(setup, kind):
    _, local, target, _ = setup
    if kind == "file":
        local.write_text("local")
    elif kind == "directory":
        local.mkdir()
    else:
        local.symlink_to(target if kind == "live-link" else target.parent / "missing")
    with pytest.raises(r.ReconnectError):
        preview(setup)
    assert os.path.lexists(local)


def test_conflict_between_preview_and_connect(setup):
    home, local, _, state = setup
    plan = preview(setup)
    local.write_text("new work")
    with pytest.raises(r.ReconnectError):
        r.connect(plan["planID"], approved=True, home=home, state=state)
    assert local.read_text() == "new work"


def test_target_modified_after_preview(setup):
    home, _, target, state = setup
    plan = preview(setup)
    target.write_text("modified")
    with pytest.raises(r.ReconnectError):
        r.connect(plan["planID"], approved=True, home=home, state=state)


def test_symlink_components_rejected(setup):
    home, local, target, state = setup
    actual = home / "actual"
    local.parent.rename(actual)
    local.parent.symlink_to(actual)
    with pytest.raises(OSError):
        preview(setup)
    local.parent.unlink()
    actual.rename(local.parent)
    work = target.parent.with_name("Actual")
    target.parent.rename(work)
    target.parent.symlink_to(work)
    with pytest.raises(OSError):
        preview(setup)


def test_parent_replaced_after_preview(setup):
    home, local, _, state = setup
    plan = preview(setup)
    local.parent.rename(home / "moved")
    local.parent.mkdir()
    with pytest.raises(r.ReconnectError):
        r.connect(plan["planID"], approved=True, home=home, state=state)
    assert not os.path.lexists(local)


def test_target_symlink_refused(setup):
    _, _, target, _ = setup
    actual = target.with_name("actual")
    target.rename(actual)
    target.symlink_to(actual)
    with pytest.raises(OSError):
        preview(setup)


def test_detached_target_status_and_undo(setup):
    home, local, target, state = setup
    result = connect(setup)
    detached = target.parent.with_name("unmounted")
    target.parent.rename(detached)
    assert r.status(result["connectionID"], home=home, state=state)["status"] == "ssd-unavailable"
    r.undo(result["connectionID"], approved=True, home=home, state=state)
    assert not os.path.lexists(local)
    assert (detached / target.name).read_text() == "preserve me"


def test_replaced_ssd_same_path_refused(setup):
    home, _, target, state = setup
    result = connect(setup)
    target.parent.rename(target.parent.with_name("detached"))
    target.parent.mkdir()
    target.write_text("impostor")
    assert r.status(result["connectionID"], home=home, state=state)["status"] == "target-replaced"


def test_replaced_original_undo_refused(setup):
    home, local, _, state = setup
    result = connect(setup)
    local.unlink()
    local.write_text("new work")
    assert r.status(result["connectionID"], home=home, state=state)["status"] == "conflict"
    with pytest.raises(r.ReconnectError):
        r.undo(result["connectionID"], approved=True, home=home, state=state)
    assert local.read_text() == "new work"


@pytest.mark.parametrize("relative", [".codex/sessions/one.jsonl", ".claude/projects", "Library/test", "Applications/example", "Documents/.env", "Documents/history.sqlite", "Documents/auth.json", "Documents/secret.pem"])
def test_protected_paths(setup, relative):
    home, _, target, state = setup
    with pytest.raises(r.ReconnectError):
        r.preview(home / relative, target, home=home, state=state, require_external=False)


def test_home_and_outside_refused(setup):
    home, _, target, state = setup
    for path in (home, home.parent / "outside"):
        with pytest.raises(r.ReconnectError):
            r.preview(path, target, home=home, state=state, require_external=False)


@pytest.mark.parametrize("dirname", ["Backup", "backups", "local-recovery-001"])
def test_archival_target_refused(setup, dirname):
    home, local, target, state = setup
    backup = target.parent / dirname
    backup.mkdir()
    archived = backup / "report.txt"
    archived.write_text("saved")
    with pytest.raises(r.ReconnectError):
        r.preview(local, archived, home=home, state=state, require_external=False)


def test_recovery_bundle_refused(setup):
    home, local, target, state = setup
    (target.parent / "payload").mkdir()
    (target.parent / "manifest.json").write_text("{}")
    with pytest.raises(r.ReconnectError):
        r.preview(local, target, home=home, state=state, require_external=False)


def test_production_requires_other_volume(setup):
    home, local, target, state = setup
    with pytest.raises(r.ReconnectError):
        r.preview(local, target, home=home, state=state)


def test_approval_expiry_single_use(setup):
    home, _, _, state = setup
    plan = preview(setup)
    with pytest.raises(r.ReconnectError):
        r.connect(plan["planID"], home=home, state=state)
    path = state / (plan["planID"] + ".plan.json")
    saved = json.loads(path.read_text())
    saved.update(createdAt=time.time()-4000, expiresAt=time.time()-400)
    path.write_text(json.dumps(saved))
    with pytest.raises(r.ReconnectError):
        r.connect(plan["planID"], approved=True, home=home, state=state)
    result = connect(setup)
    r.undo(result["connectionID"], approved=True, home=home, state=state)
    with pytest.raises(FileExistsError):
        r.connect(result["connectionID"], approved=True, home=home, state=state)


def test_interrupted_connect_status_can_recover_and_undo(setup):
    home, local, target, state = setup
    plan = preview(setup)
    def stop(event):
        if event == "after-link":
            raise KeyboardInterrupt()
    with pytest.raises(KeyboardInterrupt):
        r.connect(plan["planID"], approved=True, home=home, state=state, _hook=stop)
    assert local.read_text() == target.read_text()
    assert r.status(plan["planID"], home=home, state=state)["status"] == "connected"
    assert r.list_connections(home=home, state=state)["connections"][0]["connectionID"] == plan["planID"]
    r.undo(plan["planID"], approved=True, home=home, state=state)
    assert target.exists()


def test_interrupted_undo_restores_link(setup):
    home, local, target, state = setup
    result = connect(setup)
    def stop(event):
        if event == "after-stage":
            raise KeyboardInterrupt()
    with pytest.raises(KeyboardInterrupt):
        r.undo(result["connectionID"], approved=True, home=home, state=state, _hook=stop)
    assert local.is_symlink() and local.read_text() == target.read_text()
    assert r.status(result["connectionID"], home=home, state=state)["status"] == "connected"


def test_undo_race_preserves_new_file(setup):
    home, local, target, state = setup
    result = connect(setup)
    def replace(event):
        if event == "before-stage":
            local.unlink()
            local.write_text("new work")
    with pytest.raises(r.ReconnectError):
        r.undo(result["connectionID"], approved=True, home=home, state=state, _hook=replace)
    assert local.read_text() == "new work" and target.read_text() == "preserve me"


def test_record_path_and_permission_validation(setup):
    home, _, _, state = setup
    result = connect(setup)
    with pytest.raises(r.ReconnectError):
        r.status("../../record", home=home, state=state)
    path = state / (result["connectionID"] + ".receipt.json")
    saved = json.loads(path.read_text())
    saved["originalPath"] = str(home.parent / "escape")
    path.write_text(json.dumps(saved))
    with pytest.raises(r.ReconnectError):
        r.undo(result["connectionID"], approved=True, home=home, state=state)
    saved["originalPath"] = result["originalPath"]
    path.write_text(json.dumps(saved))
    path.chmod(0o644)
    with pytest.raises(r.ReconnectError):
        r.status(result["connectionID"], home=home, state=state)


def test_state_symlink_refused(setup):
    home, _, _, state = setup
    actual = home / "actual"
    actual.mkdir(mode=0o700)
    state.symlink_to(actual)
    with pytest.raises(OSError):
        preview(setup)


def test_candidate_requires_matching_plan_deleted_row_and_missing_source(setup):
    home, local, target, state = setup
    receipts = home / "receipts"
    receipts.mkdir(mode=0o700)
    plan_id = "a" * 48
    row = dict(id="row", path=local.name, status="identical", bytes=11)
    plan = dict(schemaVersion=1, planID=plan_id, home=str(home), localRoot=str(local.parent), backupRoot=str(target.parent), rows=[row])
    receipt = dict(schemaVersion=1, planID=plan_id, localRoot=str(local.parent), backupRoot=str(target.parent), items=[dict(row, status="deleted")])
    r.save_json(receipts / (plan_id + ".receipt.json"), receipt)
    assert r.missing_candidates(home, receipts)[0] == []
    r.save_json(receipts / (plan_id + ".json"), plan)
    candidates, _ = r.missing_candidates(home, receipts)
    assert len(candidates) == 1 and candidates[0]["originalPath"] == str(local)
    assert not os.path.lexists(local)
    receipt["items"][0]["path"] = "../escape"
    (receipts / (plan_id + ".receipt.json")).write_text(json.dumps(receipt))
    assert not r.missing_candidates(home, receipts)[0]
    receipt["items"][0]["path"] = local.name
    receipt["planID"] = "b" * 48
    (receipts / (plan_id + ".receipt.json")).write_text(json.dumps(receipt))
    assert not r.missing_candidates(home, receipts)[0]
    receipt["planID"] = plan_id
    (receipts / (plan_id + ".receipt.json")).write_text(json.dumps(receipt))
    local.write_text("new work")
    assert not r.missing_candidates(home, receipts)[0]


def test_connect_target_swap_never_returns_connected(setup):
    home, _, target, state = setup
    plan = preview(setup)
    def swap(event):
        if event == "before-link":
            target.rename(target.with_name("original"))
            target.write_text("replacement")
    result = r.connect(plan["planID"], approved=True, home=home, state=state, _hook=swap)
    assert result["status"] == "target-replaced"
    r.undo(plan["planID"], approved=True, home=home, state=state)
    assert target.read_text() == "replacement"


def test_archive_bundle_directory_itself_refused(setup):
    home, local, target, state = setup
    target.unlink()
    target.mkdir()
    (target / "payload").mkdir()
    (target / "manifest.json").write_text("{}")
    with pytest.raises(r.ReconnectError):
        preview(setup)


def test_post_crash_missing_link_identity_is_not_undoable(setup):
    home, local, target, state = setup
    plan = preview(setup)
    def stop(event):
        if event == "before-link":
            local.symlink_to(target)
            raise KeyboardInterrupt()
    with pytest.raises(KeyboardInterrupt):
        r.connect(plan["planID"], approved=True, home=home, state=state, _hook=stop)
    assert r.status(plan["planID"], home=home, state=state)["status"] == "recovery-needed"
    with pytest.raises(r.ReconnectError):
        r.undo(plan["planID"], approved=True, home=home, state=state)
    assert local.is_symlink() and target.exists()


def test_undo_retained_stage_is_visible_for_recovery(setup, monkeypatch):
    home, local, target, state = setup
    result = connect(setup)
    def stop(event):
        if event == "after-stage":
            raise KeyboardInterrupt()
    def cannot_restore(*args, **kwargs):
        raise PermissionError("simulated restore interruption")
    monkeypatch.setattr(r.os, "link", cannot_restore)
    with pytest.raises(KeyboardInterrupt):
        r.undo(result["connectionID"], approved=True, home=home, state=state, _hook=stop)
    result = r.status(result["connectionID"], home=home, state=state)
    assert result["status"] == "recovery-needed"
    retained = Path(result["recoveryPath"])
    assert retained.is_symlink() and retained.read_text() == target.read_text()
    assert not os.path.lexists(local)


def test_undo_marker_is_validated(setup):
    home, _, _, state = setup
    result = connect(setup)
    r.save_json(state / (result["connectionID"] + ".undone.json"), {"connectionID": "wrong", "disconnectedAt": 1})
    with pytest.raises(r.ReconnectError):
        r.status(result["connectionID"], home=home, state=state)
