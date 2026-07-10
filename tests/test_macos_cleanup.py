import os
import plistlib
import stat
import subprocess
import sys
from pathlib import Path

import pytest


def parse_protocol(text: str) -> dict[str, object]:
    values: dict[str, object] = {}
    targets: list[str] = []
    for line in text.splitlines():
        if "\t" not in line:
            continue
        key, value = line.split("\t", 1)
        if key == "target":
            targets.append(value)
        else:
            values[key] = value
    values["targets"] = targets
    return values


def run_cleanup(
    project_root: Path,
    home: Path,
    *args: str,
    processes: str = "",
    extra_env: dict[str, str] | None = None,
):
    applications_root = home / "ApplicationsRoot"
    applications_root.mkdir(parents=True, exist_ok=True)
    process_file = home / "processes.txt"
    process_file.parent.mkdir(parents=True, exist_ok=True)
    process_file.write_text(processes, encoding="utf-8")
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_HOME_OVERRIDE": str(home),
            "PCH_PROCESS_LIST_FILE": str(process_file),
            "PCH_APPLICATIONS_ROOT_OVERRIDE": str(applications_root),
        }
    )
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [str(project_root / "scripts" / "cleanup.sh"), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )


def test_cleanup_preview_is_read_only_and_execute_requires_approval(project_root, tmp_path):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "_cacache" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"x" * 8192)

    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0
    assert payload["status"] == "ready"
    assert payload["recipeId"] == "npm_cache"
    assert cache_file.exists()

    rejected = run_cleanup(project_root, home, "--execute", "npm_cache")
    assert rejected.returncode == 2
    assert cache_file.exists()

    executed = run_cleanup(project_root, home, "--execute", "npm_cache", "--owner-approved")
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert not (home / ".npm").exists()
    receipt = Path(str(result["receipt"]))
    assert receipt.is_file()
    assert stat.S_IMODE(receipt.stat().st_mode) == 0o600


def test_cleanup_blocks_live_related_process(project_root, tmp_path):
    home = tmp_path / "home"
    browser = home / "Library" / "Caches" / "ms-playwright" / "chromium" / "chrome"
    browser.parent.mkdir(parents=True)
    browser.write_text("fixture", encoding="utf-8")

    preview = run_cleanup(
        project_root,
        home,
        "--preview",
        "playwright_browsers",
        processes="/tmp/chrome --headless --remote-debugging-pipe\n",
    )
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0
    assert payload["status"] == "blocked"
    assert "종료" in str(payload["blockedReason"])
    assert browser.exists()

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "playwright_browsers",
        "--owner-approved",
        processes="/tmp/chrome --headless --remote-debugging-pipe\n",
    )
    assert executed.returncode == 3
    assert browser.exists()


def test_cleanup_rejects_symlinked_target(project_root, tmp_path):
    home = tmp_path / "home"
    outside = tmp_path / "outside"
    home.mkdir()
    outside.mkdir()
    protected_file = outside / "keep.txt"
    protected_file.write_text("keep", encoding="utf-8")
    (home / ".npm").symlink_to(outside, target_is_directory=True)

    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)

    assert payload["status"] == "blocked"
    assert protected_file.read_text(encoding="utf-8") == "keep"


def test_cleanup_has_no_recipe_for_session_history(project_root, tmp_path):
    home = tmp_path / "home"
    session = home / ".codex" / "sessions" / "history.jsonl"
    session.parent.mkdir(parents=True)
    session.write_text("{}\n", encoding="utf-8")

    result = run_cleanup(project_root, home, "--preview", "codex_session_history")

    assert result.returncode == 64
    assert "허용되지 않은 recipe ID" in result.stderr
    assert session.read_text(encoding="utf-8") == "{}\n"


def test_user_cache_recipe_preserves_cache_root(project_root, tmp_path):
    home = tmp_path / "home"
    cache_root = home / "Library" / "Caches"
    (cache_root / "normal").mkdir(parents=True)
    (cache_root / ".hidden").write_text("fixture", encoding="utf-8")
    (cache_root / "normal" / "item").write_text("fixture", encoding="utf-8")

    result = run_cleanup(project_root, home, "--execute", "user_caches", "--owner-approved")

    assert result.returncode == 0, result.stderr
    assert cache_root.is_dir()
    assert list(cache_root.iterdir()) == []


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_app_uninstall_moves_verified_bundle_and_exact_residue_to_trash(project_root, tmp_path):
    home = tmp_path / "home"
    app = home / "ApplicationsRoot" / "Example App.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleIdentifier": "me.example.cleanup",
                "CFBundleName": "Example App",
                "CFBundleExecutable": "ExampleApp",
            },
            handle,
        )
    (app / "Contents" / "MacOS").mkdir()
    (app / "Contents" / "MacOS" / "ExampleApp").write_text("fixture", encoding="utf-8")
    residue = home / "Library" / "Caches" / "me.example.cleanup"
    residue.mkdir(parents=True)
    (residue / "cache").write_text("fixture", encoding="utf-8")

    preview = run_cleanup(project_root, home, "--preview", "app_uninstall:me.example.cleanup")
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0, preview.stderr
    assert payload["status"] == "ready"
    assert payload["actionMode"] == "trash"
    assert str(app) in payload["targets"]
    assert str(residue) in payload["targets"]
    assert app.exists() and residue.exists()

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "app_uninstall:me.example.cleanup",
        "--owner-approved",
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert not app.exists()
    assert not residue.exists()
    trash_run = Path(str(result["trashRun"]))
    assert trash_run.is_dir()
    assert len(list(trash_run.iterdir())) == 2


def test_simulator_recipe_honors_keep_list_and_deletes_only_verified_uuid(project_root, tmp_path):
    home = tmp_path / "home"
    uuid = "11111111-2222-3333-4444-555555555555"
    device = home / "Library" / "Developer" / "CoreSimulator" / "Devices" / uuid
    device.mkdir(parents=True)
    (device / "data.bin").write_bytes(b"fixture")
    support = home / "Library" / "Application Support" / "PC Health Check"
    support.mkdir(parents=True)
    keep_file = support / "simulator-keep.txt"
    keep_file.write_text("iPhone 17 Pro Max\n", encoding="utf-8")
    simctl_list = home / "simctl.txt"
    simctl_list.write_text(
        "== Devices ==\n-- iOS 26.3 --\n"
        f"    iPhone 17 Pro Max ({uuid}) (Shutdown)\n",
        encoding="utf-8",
    )
    delete_log = home / "simctl-delete.log"
    extra_env = {
        "PCH_SIMCTL_LIST_FILE": str(simctl_list),
        "PCH_SIMCTL_DELETE_LOG": str(delete_log),
    }

    protected = run_cleanup(
        project_root,
        home,
        "--preview",
        f"simulator_delete:{uuid}",
        extra_env=extra_env,
    )
    protected_payload = parse_protocol(protected.stdout)
    assert protected_payload["status"] == "blocked"
    assert "보존 목록" in str(protected_payload["blockedReason"])
    assert device.exists()

    keep_file.unlink()
    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        f"simulator_delete:{uuid}",
        "--owner-approved",
        extra_env=extra_env,
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert result["actionMode"] == "simulator"
    assert not device.exists()
    assert delete_log.read_text(encoding="utf-8").strip() == uuid
