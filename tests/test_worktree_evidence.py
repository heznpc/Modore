"""Real Git fixtures for preview evidence; never operate on user repositories."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest
import scree


@pytest.fixture
def inventory(tmp_path, monkeypatch):
    monkeypatch.setattr(scree, "WORKTREE_GIT_BUDGET_SECONDS", 30)
    monkeypatch.setattr(scree, "WORKTREE_GIT_COMMAND_TIMEOUT_SECONDS", 3)
    repo = tmp_path / "repo"
    repo.mkdir()
    env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
           "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
           "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}

    def git(*args, cwd=repo):
        return subprocess.check_output(["/usr/bin/git", *args], cwd=cwd, env=env, stderr=subprocess.PIPE).decode()

    git("init", "-b", "main")
    (repo / ".gitignore").write_text("private/\n.hidden-local\n")
    (repo / "tracked").write_text("base\n")
    git("add", ".")
    git("commit", "-m", "Initial fixture")
    origin = tmp_path / "origin.git"
    git("init", "--bare", str(origin))
    git("remote", "add", "origin", str(origin))
    git("push", "-u", "origin", "main")
    wt = tmp_path / ".codex" / "worktrees" / "space and\nnewline" / "repo"
    git("worktree", "add", "-b", "feature", str(wt))
    git("push", "origin", "feature")
    return repo, wt, git


def scan(repo, *workspaces):
    return scree.collect_worktrees(repo.parent, [{"workspace": str(p)} for p in (workspaces or (repo,))])


def item_for(result, path):
    return next(item for item in result["items"] if item["path"] == str(path))


def test_registry_follows_codex_and_sibling_paths_from_linked_cwd(inventory):
    repo, wt, git = inventory
    sibling = repo.parent / "sibling"
    git("worktree", "add", "--detach", str(sibling))
    result = scan(repo, wt)
    assert {str(wt), str(sibling)} <= {i["path"] for i in result["items"]}
    item = item_for(result, wt)
    assert item["verdict"] == "rebuildable"
    assert item["checked_out"] and item["registered"]
    assert item["session_references"] == 1
    assert item["live_usage"] == "unverified"
    assert item["cleanup_allowed"] is False
    assert result["reclaimed_bytes"] is None
    assert result["branch_count"] == 2
    assert next(b for b in result["branches"] if b["branch"] == "feature")["checked_out_path"] == str(wt)


def test_ignored_and_hidden_unique_material_is_protected(inventory):
    repo, wt, _ = inventory
    (wt / "private").mkdir()
    (wt / "private" / "only-copy").write_text("uncommitted local material")
    (wt / ".hidden-local").write_text("hidden ignored material")
    item = item_for(scan(repo), wt)
    assert item["dirty"] is False
    assert item["ignored_entries"] == 2  # directory summary + hidden file
    assert item["verdict"] == "protected"
    assert "requires_revalidation" not in item


def test_hidden_untracked_and_tracked_changes_are_dirty(inventory):
    repo, wt, _ = inventory
    (wt / ".untracked").write_text("only local")
    (wt / "tracked").write_text("changed")
    item = item_for(scan(repo), wt)
    assert item["dirty"] is True
    assert item["verdict"] == "protected"


def test_squash_merge_is_not_reported_as_unmerged(inventory):
    repo, wt, git = inventory
    (wt / "tracked").write_text("step one")
    git("commit", "-am", "Step one", cwd=wt)
    (wt / "tracked").write_text("step two")
    git("commit", "-am", "Step two", cwd=wt)
    git("merge", "--squash", "feature")
    git("commit", "-m", "Squashed fixture")
    git("push", "origin", "main")
    result = scan(repo)
    branch = next(b for b in result["branches"] if b["branch"] == "feature")
    assert branch["merge_state"] == "not_ancestor_merge_unknown"
    assert branch["merge_base"] == "refs/remotes/origin/main"
    assert branch["cleanup_allowed"] is False


def test_unavailable_volume_is_distinct_from_missing_local_path(inventory, monkeypatch):
    repo, wt, git = inventory
    volumes = repo.parent / "Volumes"
    external = volumes / "OfflineSSD" / "work"
    git("worktree", "add", "-b", "external", str(external))
    # Move the fixture volume aside, preserving its contents just like an unmount.
    (volumes / "OfflineSSD").rename(repo.parent / "retained-volume")
    monkeypatch.setattr(scree, "WORKTREE_VOLUME_ROOT", volumes)
    local = repo.parent / "missing-local"
    git("worktree", "add", "-b", "local", str(local))
    local.rename(repo.parent / "retained-local")
    result = scan(repo)
    assert item_for(result, external)["path_state"] == "volume_unavailable"
    assert item_for(result, external)["verdict"] == "unreadable"
    assert not any(i["path"] == str(external) for i in result["registered_missing"])
    assert any(i["path"] == str(local) for i in result["registered_missing"])


def test_error_reason_and_ignored_failure_never_become_clean(inventory, monkeypatch):
    repo, wt, _ = inventory
    original = scree._git

    def fail_ignored(args, cwd, **kwargs):
        if args[0] == "ls-files":
            scree._WORKTREE_GIT_ERROR = "command_timeout"
            return None
        return original(args, cwd, **kwargs)

    monkeypatch.setattr(scree, "_git", fail_ignored)
    item = item_for(scan(repo), wt)
    assert item["dirty"] is False
    assert item["ignored_entries"] is None
    assert item["verdict"] == "unreadable"
    assert any(e["reason"] == "command_timeout" and e["operation"] == "ls-files" for e in item["errors"])


def test_isolated_timeout_retains_completed_rows_and_known_pending_paths(inventory, monkeypatch):
    repo, wt, git = inventory
    later = repo.parent / "zz-slow"
    git("worktree", "add", "-b", "slow", str(later))
    original = scree._worktree_item

    def delay(path, *args, **kwargs):
        if path == later:
            time.sleep(5)
        return original(path, *args, **kwargs)

    monkeypatch.setattr(scree, "_worktree_item", delay)
    result = scree.collect_worktrees_isolated(repo.parent, [{"workspace": str(repo)}], timeout_seconds=1.5)
    assert result["stop_reason"] == "worker_timeout"
    assert result["truncated"] is True
    assert result["worker_leaked"] is False
    assert item_for(result, wt)["verdict"] == "rebuildable"
    assert item_for(result, later)["verdict"] == "unreadable"


def test_permission_error_is_not_path_missing(inventory, monkeypatch):
    repo, wt, _ = inventory
    original = scree._open_directory_nofollow

    def deny(path):
        if path == wt:
            raise PermissionError("fixture denial")
        return original(path)

    monkeypatch.setattr(scree, "_open_directory_nofollow", deny)
    result = scan(repo)
    item = item_for(result, wt)
    assert item["path_state"] == "permission_denied"
    assert item["errors"][0]["reason"] == "permission_denied"
    assert not result["registered_missing"]


def test_real_process_inventory_uses_same_isolated_entrypoint(inventory):
    repo, wt, _ = inventory
    program = """import json, sys; from pathlib import Path; import scree
print(json.dumps(scree.collect_worktrees_isolated(Path(sys.argv[1]), [{'workspace': sys.argv[1]}])))
"""
    result = subprocess.run([sys.executable, "-c", program, str(repo)],
                            env={**os.environ, "PYTHONPATH": str(Path(scree.__file__).parent)},
                            capture_output=True, text=True, timeout=15, check=True)
    report = json.loads(result.stdout)
    assert item_for(report, wt)["verdict"] == "rebuildable"
    assert report["truncated"] is False


def test_locked_worktree_is_protected_and_registry_failure_stays_unknown(inventory, monkeypatch):
    repo, wt, git = inventory
    git("worktree", "lock", str(wt))
    item = item_for(scan(repo), wt)
    assert item["locked"] is True
    assert item["verdict"] == "protected"
    original = scree._git

    def fail_registry(args, cwd, **kwargs):
        return None if args[:2] == ["worktree", "list"] else original(args, cwd, **kwargs)

    monkeypatch.setattr(scree, "_git", fail_registry)
    result = scan(repo)
    assert result["branches"]
    assert all(b["checkout_state"] == "unknown" for b in result["branches"])


def test_registry_failure_keeps_exact_recorded_codex_checkout(inventory, monkeypatch):
    repo, wt, _ = inventory
    original = scree._git

    def fail_registry(args, cwd, **kwargs):
        return None if args[:2] == ["worktree", "list"] else original(args, cwd, **kwargs)

    monkeypatch.setattr(scree, "_git", fail_registry)
    item = item_for(scan(repo, wt), wt)
    assert item["registered"] is None
    assert item["cleanup_allowed"] is False
    assert item["session_references"] == 1


def test_broken_git_pointer_reports_cause_without_raw_stderr(inventory):
    repo, wt, _ = inventory
    (wt / ".git").write_text("gitdir: /fixture/absent/gitdir\n")
    item = item_for(scan(repo), wt)
    assert item["verdict"] == "unreadable"
    assert {e["reason"] for e in item["errors"]} == {"invalid_git_checkout"}
    assert all("stderr" not in e for e in item["errors"])
