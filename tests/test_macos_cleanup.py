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
    staged_remainders: list[str] = []
    for line in text.splitlines():
        if "\t" not in line:
            continue
        key, value = line.split("\t", 1)
        if key == "target":
            targets.append(value)
        elif key == "stagedRemainder":
            staged_remainders.append(value)
        else:
            values[key] = value
    values["targets"] = targets
    values["stagedRemainders"] = staged_remainders
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


def approval_token(payload: dict[str, object]) -> str:
    token = str(payload.get("approvalToken", ""))
    assert len(token) == 64
    return token


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

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
    )
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
        "--approval-token",
        "0" * 64,
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


def test_execute_rejects_target_drift_and_consumed_approval(project_root, tmp_path):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "_cacache" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"x" * 8192)

    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)
    token = approval_token(payload)
    cache_file.write_bytes(b"x" * (2 * 1024 * 1024))

    drifted = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        token,
    )

    assert drifted.returncode == 3
    assert parse_protocol(drifted.stdout)["status"] == "blocked"
    assert cache_file.exists()

    refreshed = run_cleanup(project_root, home, "--preview", "npm_cache")
    refreshed_payload = parse_protocol(refreshed.stdout)
    refreshed_token = approval_token(refreshed_payload)
    completed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        refreshed_token,
    )
    assert completed.returncode == 0, completed.stderr

    replayed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        refreshed_token,
    )
    assert replayed.returncode == 3


def test_destructive_rename_rechecks_recursive_size_immediately_before_move(
    project_root, tmp_path
):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"fixture")
    late_content = home / "late-content.bin"
    late_content.write_bytes(b"x" * (2 * 1024 * 1024))
    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env={
            "PCH_TEST_LATE_CONTENT_AT": "1",
            "PCH_TEST_LATE_CONTENT_FILE": str(late_content),
        },
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 3
    assert result["status"] == "blocked"
    assert cache_file.exists()
    assert (home / ".npm" / ".pch-test-late-content").is_file()
    assert not result["trashRun"]


def test_expired_approval_is_consumed_without_cleanup(project_root, tmp_path):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"fixture")
    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)
    token = approval_token(payload)
    manifest = (
        home
        / "Library"
        / "Application Support"
        / "PC Health Check"
        / "cleanup-approvals"
        / f"{token}.tsv"
    )
    lines = manifest.read_text(encoding="utf-8").splitlines()
    manifest.write_text(
        "\n".join("createdEpoch\t1" if line.startswith("createdEpoch\t") else line for line in lines)
        + "\n",
        encoding="utf-8",
    )

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        token,
    )

    assert executed.returncode == 3
    assert cache_file.exists()
    assert not manifest.exists()


def test_failed_staged_removal_reports_private_recovery_path(project_root, tmp_path):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"fixture")
    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)
    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env={"PCH_TEST_FAIL_STAGED_REMOVE_AT": "1"},
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 4
    assert result["status"] == "partial"
    assert len(result["stagedRemainders"]) == 1
    staged = Path(str(result["stagedRemainders"][0]))
    assert staged.is_dir()
    assert (staged / "entry").is_file()
    assert stat.S_IMODE(staged.parent.stat().st_mode) == 0o700
    receipt = Path(str(result["receipt"]))
    assert f"stagedRemainder\t{staged}" in receipt.read_text(encoding="utf-8")


def test_execute_rechecks_processes_at_destructive_boundary(project_root, tmp_path):
    home = tmp_path / "home"
    browser = home / "Library" / "Caches" / "ms-playwright" / "chromium" / "chrome"
    browser.parent.mkdir(parents=True)
    browser.write_text("fixture", encoding="utf-8")
    late_processes = home / "late-processes.txt"
    late_processes.write_text("/tmp/chrome --headless --remote-debugging-pipe\n", encoding="utf-8")

    preview = run_cleanup(project_root, home, "--preview", "playwright_browsers")
    payload = parse_protocol(preview.stdout)
    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "playwright_browsers",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env={"PCH_TEST_LATE_PROCESS_LIST_FILE": str(late_processes)},
    )

    assert executed.returncode == 3
    assert parse_protocol(executed.stdout)["status"] == "blocked"
    assert browser.exists()


def test_cleanup_never_follows_last_moment_symlink_swap(project_root, tmp_path):
    home = tmp_path / "home"
    cache_root = home / ".npm"
    cache_root.mkdir(parents=True)
    (cache_root / "cache.bin").write_bytes(b"x" * 8192)
    outside = home / "outside"
    outside.mkdir()
    protected_file = outside / "keep.txt"
    protected_file.write_text("keep", encoding="utf-8")

    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)
    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env={"PCH_TEST_SWAP_TARGET_WITH_SYMLINK_TO": str(outside)},
    )

    assert executed.returncode == 3
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


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("PCH_HOME_OVERRIDE", str(Path.home())),
        ("PCH_APPLICATIONS_ROOT_OVERRIDE", "/Applications"),
        ("PCH_VAR_FOLDERS_ROOT_OVERRIDE", "/private/var/folders"),
        ("PCH_PROCESS_LIST_FILE", "/tmp/outside-process-list"),
        ("PCH_SIMCTL_LIST_FILE", "/tmp/outside-simctl-list"),
        ("PCH_SIMCTL_DELETE_LOG", "/tmp/outside-delete-log"),
        ("PCH_TEST_LATE_PROCESS_LIST_FILE", "/tmp/outside-late-process-list"),
        ("PCH_TEST_LATE_SIMCTL_LIST_FILE", "/tmp/outside-late-simctl-list"),
        ("PCH_TEST_LATE_SIMULATOR_KEEP_FILE", "/tmp/outside-late-keep-list"),
        ("PCH_TEST_LATE_CONTENT_FILE", "/tmp/outside-late-content"),
        ("PCH_TEST_SWAP_TARGET_WITH_SYMLINK_TO", "/tmp"),
    ],
)
def test_test_hooks_cannot_escape_isolated_home(project_root, tmp_path, key, value):
    home = tmp_path / "home"
    (home / ".npm").mkdir(parents=True)

    result = run_cleanup(
        project_root,
        home,
        "--preview",
        "npm_cache",
        extra_env={key: value},
    )

    assert result.returncode == 64
    assert (home / ".npm").is_dir()


def test_production_home_must_match_current_account(project_root, tmp_path):
    fake_home = tmp_path / "fake-home"
    (fake_home / ".npm").mkdir(parents=True)
    env = os.environ.copy()
    env["HOME"] = str(fake_home)
    env.pop("PCH_TEST_MODE", None)

    result = subprocess.run(
        [str(project_root / "scripts" / "cleanup.sh"), "--preview", "npm_cache"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )

    assert result.returncode == 64
    assert (fake_home / ".npm").is_dir()


@pytest.mark.parametrize("recipe", ["user_caches", "cli_tool_caches"])
def test_broad_cache_roots_are_manual_review_only(project_root, tmp_path, recipe):
    home = tmp_path / "home"
    cache_root = home / "Library" / "Caches"
    (cache_root / "normal").mkdir(parents=True)
    (cache_root / ".hidden").write_text("fixture", encoding="utf-8")
    (cache_root / "normal" / "item").write_text("fixture", encoding="utf-8")

    result = run_cleanup(project_root, home, "--preview", recipe)

    assert result.returncode == 64
    assert "허용되지 않은 recipe ID" in result.stderr
    assert cache_root.is_dir()
    assert (cache_root / ".hidden").is_file()
    assert (cache_root / "normal" / "item").is_file()


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
        "--approval-token",
        approval_token(payload),
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert not app.exists()
    assert not residue.exists()
    trash_run = Path(str(result["trashRun"]))
    assert trash_run.is_dir()
    assert len(list(trash_run.iterdir())) == 2


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
@pytest.mark.parametrize("failure_index", [1, 2])
def test_app_uninstall_rolls_back_when_any_move_fails(
    project_root, tmp_path, failure_index
):
    home = tmp_path / "home"
    app = home / "ApplicationsRoot" / "Transactional App.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleIdentifier": "me.example.transactional",
                "CFBundleExecutable": "TransactionalApp",
            },
            handle,
        )
    residue = home / "Library" / "Caches" / "me.example.transactional"
    residue.mkdir(parents=True)
    (residue / "cache").write_text("fixture", encoding="utf-8")

    preview = run_cleanup(
        project_root, home, "--preview", "app_uninstall:me.example.transactional"
    )
    payload = parse_protocol(preview.stdout)
    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "app_uninstall:me.example.transactional",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env={"PCH_TEST_FAIL_TRASH_MOVE_AT": str(failure_index)},
    )

    assert executed.returncode == 3
    assert parse_protocol(executed.stdout)["status"] == "blocked"
    assert app.is_dir()
    assert residue.is_dir()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS plist tools are required")
def test_app_uninstall_only_attributes_structurally_matching_launch_agent(
    project_root, tmp_path
):
    home = tmp_path / "home"
    app = home / "ApplicationsRoot" / "Example App.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleIdentifier": "me.example.owner",
                "CFBundleExecutable": "ExampleApp",
            },
            handle,
        )
    agents = home / "Library" / "LaunchAgents"
    agents.mkdir(parents=True)
    owned = agents / "me.example.owner.plist"
    unrelated = agents / "unrelated.plist"
    with owned.open("wb") as handle:
        plistlib.dump({"Label": "me.example.owner", "Program": "/usr/bin/true"}, handle)
    with unrelated.open("wb") as handle:
        plistlib.dump(
            {
                "Label": "unrelated.agent",
                "ProgramArguments": ["/usr/bin/printf", "me.example.owner"],
            },
            handle,
        )

    preview = run_cleanup(project_root, home, "--preview", "app_uninstall:me.example.owner")
    payload = parse_protocol(preview.stdout)

    assert str(owned) in payload["targets"]
    assert str(unrelated) not in payload["targets"]


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_xcode_bundle_ids_are_blocked_at_cleanup_script_boundary(project_root, tmp_path):
    home = tmp_path / "home"
    app = home / "ApplicationsRoot" / "Xcode.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": "com.apple.dt.Xcode"}, handle)

    result = run_cleanup(
        project_root, home, "--preview", "app_uninstall:com.apple.dt.Xcode"
    )

    assert result.returncode == 64
    assert app.is_dir()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_dynamic_app_recipe_blocks_embedded_developer_payload(project_root, tmp_path):
    home = tmp_path / "home"
    bundle_id = "me.example.custom-developer-suite"
    app = home / "ApplicationsRoot" / "Custom Developer Suite.app"
    info = app / "Contents" / "Info.plist"
    platforms = app / "Contents" / "Developer" / "Platforms"
    platforms.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)
    (platforms / "SDK.marker").write_text("protected", encoding="utf-8")

    result = run_cleanup(project_root, home, "--preview", f"app_uninstall:{bundle_id}")

    assert result.returncode == 64
    assert "허용되지 않은 recipe ID" in result.stderr
    assert (platforms / "SDK.marker").is_file()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_app_uninstall_excludes_prefix_matched_http_storage(project_root, tmp_path):
    home = tmp_path / "home"
    bundle_id = "me.example.owner"
    app = home / "ApplicationsRoot" / "Example App.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)
    exact = home / "Library" / "HTTPStorages" / bundle_id
    prefix_collision = home / "Library" / "HTTPStorages" / f"{bundle_id}.other-app"
    exact.mkdir(parents=True)
    prefix_collision.mkdir(parents=True)

    preview = run_cleanup(project_root, home, "--preview", f"app_uninstall:{bundle_id}")
    payload = parse_protocol(preview.stdout)

    assert str(exact) in payload["targets"]
    assert str(prefix_collision) not in payload["targets"]


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

    legacy = run_cleanup(
        project_root,
        home,
        "--preview",
        f"simulator_delete:{uuid}",
        extra_env=extra_env,
    )
    legacy_payload = parse_protocol(legacy.stdout)
    assert legacy_payload["status"] == "blocked"
    assert "UUID 형식" in str(legacy_payload["blockedReason"])
    assert device.exists()

    keep_file.write_text(f"{uuid.lower()}\n", encoding="utf-8")
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
    ready = run_cleanup(
        project_root,
        home,
        "--preview",
        f"simulator_delete:{uuid}",
        extra_env=extra_env,
    )
    ready_payload = parse_protocol(ready.stdout)
    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        f"simulator_delete:{uuid}",
        "--owner-approved",
        "--approval-token",
        approval_token(ready_payload),
        extra_env=extra_env,
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert result["actionMode"] == "simulator"
    assert not device.exists()
    assert delete_log.read_text(encoding="utf-8").strip() == uuid


@pytest.mark.parametrize(
    ("late_condition", "reason_fragment"),
    [
        ("booted", "Booted"),
        ("preserved", "보존 목록"),
        ("legacy", "이름 기반"),
    ],
)
def test_simulator_delete_rechecks_state_and_keep_file_at_final_boundary(
    project_root, tmp_path, late_condition, reason_fragment
):
    home = tmp_path / "home"
    uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    device = home / "Library" / "Developer" / "CoreSimulator" / "Devices" / uuid
    device.mkdir(parents=True)
    (device / "data.bin").write_bytes(b"fixture")
    support = home / "Library" / "Application Support" / "PC Health Check"
    support.mkdir(parents=True)
    simctl_list = home / "simctl.txt"
    simctl_list.write_text(
        "== Devices ==\n-- iOS 26.3 --\n"
        f"    Boundary Phone ({uuid}) (Shutdown)\n",
        encoding="utf-8",
    )
    delete_log = home / "simctl-delete.log"
    extra_env = {
        "PCH_SIMCTL_LIST_FILE": str(simctl_list),
        "PCH_SIMCTL_DELETE_LOG": str(delete_log),
    }

    if late_condition == "booted":
        late_simctl = home / "late-simctl.txt"
        late_simctl.write_text(
            "== Devices ==\n-- iOS 26.3 --\n"
            f"    Boundary Phone ({uuid}) (Booted)\n",
            encoding="utf-8",
        )
        extra_env["PCH_TEST_LATE_SIMCTL_LIST_FILE"] = str(late_simctl)
    else:
        late_keep = home / "late-keep.txt"
        late_keep.write_text(
            f"{uuid.lower()}\n" if late_condition == "preserved" else "Boundary Phone\n",
            encoding="utf-8",
        )
        extra_env["PCH_TEST_LATE_SIMULATOR_KEEP_FILE"] = str(late_keep)

    preview = run_cleanup(
        project_root,
        home,
        "--preview",
        f"simulator_delete:{uuid}",
        extra_env={
            "PCH_SIMCTL_LIST_FILE": str(simctl_list),
            "PCH_SIMCTL_DELETE_LOG": str(delete_log),
        },
    )
    payload = parse_protocol(preview.stdout)
    assert payload["status"] == "ready"

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        f"simulator_delete:{uuid}",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env=extra_env,
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 3
    assert result["status"] == "blocked"
    assert reason_fragment in str(result["blockedReason"])
    assert device.is_dir()
    assert not delete_log.exists()
