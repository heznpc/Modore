import hashlib
import os
import plistlib
import stat
import subprocess
import sys

import pytest


def parse_protocol(text: str) -> dict[str, str]:
    values = {}
    for line in text.splitlines():
        if "\t" in line:
            key, value = line.split("\t", 1)
            values[key] = value
    return values


def test_storage_watch_detects_large_drop_without_deleting(project_root, tmp_path):
    state_dir = tmp_path / "state"
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(50 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "0",
        }
    )
    injected = tmp_path / "bash-env-ran"
    payload = tmp_path / "payload.sh"
    payload.write_text(f'/usr/bin/touch "{injected}"\n', encoding="utf-8")
    env["BASH_ENV"] = str(payload)
    script = project_root / "scripts" / "storage_watch.sh"

    first = subprocess.run([str(script)], capture_output=True, text=True, encoding="utf-8", env=env)
    assert first.returncode == 0, first.stderr
    assert parse_protocol(first.stdout)["status"] == "normal"

    env["PCH_TEST_FREE_KB"] = str(40 * 1024 * 1024)
    second = subprocess.run([str(script)], capture_output=True, text=True, encoding="utf-8", env=env)
    payload = parse_protocol(second.stdout)

    assert second.returncode == 0, second.stderr
    assert payload["status"] == "warning"
    assert int(payload["dropKB"]) == 10 * 1024 * 1024
    state_file = state_dir / "storage-watch.tsv"
    assert state_file.is_file()
    assert stat.S_IMODE(state_file.stat().st_mode) == 0o600
    samples_file = state_dir / "storage-samples.tsv"
    samples = samples_file.read_text(encoding="utf-8").splitlines()
    assert len(samples) == 2
    assert samples[0].split("\t")[1] == str(50 * 1024 * 1024)
    assert samples[1].split("\t")[1:4] == [
        str(40 * 1024 * 1024),
        str(10 * 1024 * 1024),
        "warning",
    ]
    assert stat.S_IMODE(samples_file.stat().st_mode) == 0o600
    assert not list(tmp_path.rglob("*.deleted"))
    assert not injected.exists()


def test_storage_watch_warns_below_free_space_floor(project_root, tmp_path):
    """20GB free-space floor fires independently of the 8GB drop trigger."""
    state_dir = tmp_path / "state"
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(25 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "0",
        }
    )
    script = project_root / "scripts" / "storage_watch.sh"

    first = subprocess.run([str(script)], capture_output=True, text=True, encoding="utf-8", env=env)
    assert first.returncode == 0, first.stderr
    assert parse_protocol(first.stdout)["status"] == "normal"

    # Drop only 6GB (below the 8GB drop trigger) but cross under the 20GB floor.
    env["PCH_TEST_FREE_KB"] = str(19 * 1024 * 1024)
    second = subprocess.run([str(script)], capture_output=True, text=True, encoding="utf-8", env=env)
    payload = parse_protocol(second.stdout)

    assert second.returncode == 0, second.stderr
    assert payload["status"] == "warning"
    assert int(payload["dropKB"]) < 8 * 1024 * 1024, "drop must stay below the drop trigger"
    assert "아래입니다" in payload["message"], "warning must be the low-free-space floor, not the drop"


def test_storage_watch_captures_bounded_top_paths_only_after_large_drop(
    project_root, tmp_path
):
    state_dir = tmp_path / "state"
    snapshot_root = tmp_path / "snapshot-roots"
    larger = snapshot_root / "codex-cache"
    smaller = snapshot_root / "playwright-cache"
    larger.mkdir(parents=True)
    smaller.mkdir()
    (larger / "payload.bin").write_bytes(b"a" * (2 * 1024 * 1024))
    (smaller / "payload.bin").write_bytes(b"b" * (512 * 1024))

    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(50 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "0",
            "PCH_WATCH_SNAPSHOT_ROOT": str(snapshot_root),
            "PCH_WATCH_SNAPSHOT_TOTAL_SECONDS": "2",
            "PCH_WATCH_SNAPSHOT_ITEM_SECONDS": "1",
            "PCH_WATCH_SNAPSHOT_EVENT_LIMIT": "1",
        }
    )
    script = project_root / "scripts" / "storage_watch.sh"

    baseline = subprocess.run(
        [str(script)], capture_output=True, text=True, encoding="utf-8", env=env
    )
    assert baseline.returncode == 0, baseline.stderr
    assert parse_protocol(baseline.stdout)["snapshotRows"] == "0"
    assert not (state_dir / "storage-watch-paths.tsv").exists()

    env["PCH_TEST_FREE_KB"] = str(40 * 1024 * 1024)
    dropped = subprocess.run(
        [str(script)], capture_output=True, text=True, encoding="utf-8", env=env
    )
    assert dropped.returncode == 0, dropped.stderr
    payload = parse_protocol(dropped.stdout)
    assert int(payload["snapshotRows"]) == 2

    snapshot_file = state_dir / "storage-watch-paths.tsv"
    assert snapshot_file.is_file()
    assert stat.S_IMODE(snapshot_file.stat().st_mode) == 0o600
    rows = [line.split("\t") for line in snapshot_file.read_text(encoding="utf-8").splitlines()]
    assert all(len(row) == 5 for row in rows)
    assert [row[3] for row in rows] == ["codex-cache", "playwright-cache"]
    assert int(rows[0][1]) > int(rows[1][1]) > 0
    assert all(row[2] == "ok" for row in rows)
    assert all(str(snapshot_root) in row[4] for row in rows)


def test_storage_watch_bounds_history(project_root, tmp_path):
    state_dir = tmp_path / "state"
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(50 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "0",
            "PCH_WATCH_HISTORY_LIMIT": "2",
        }
    )
    script = project_root / "scripts" / "storage_watch.sh"

    for free_gb in (50, 49, 48):
        env["PCH_TEST_FREE_KB"] = str(free_gb * 1024 * 1024)
        result = subprocess.run([str(script)], capture_output=True, text=True, encoding="utf-8", env=env)
        assert result.returncode == 0, result.stderr

    samples = (state_dir / "storage-samples.tsv").read_text(encoding="utf-8").splitlines()
    assert len(samples) == 2
    assert [int(line.split("\t")[1]) for line in samples] == [
        49 * 1024 * 1024,
        48 * 1024 * 1024,
    ]


def test_storage_watch_rejects_intermediate_state_symlink(project_root, tmp_path):
    outside = tmp_path / "outside"
    nested = outside / "nested" / "state"
    nested.mkdir(parents=True)
    victim = nested / "storage-watch.tsv"
    victim.write_text("do-not-replace\n", encoding="utf-8")
    link = tmp_path / "redirect"
    link.symlink_to(outside, target_is_directory=True)

    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(link / "nested" / "state"),
            "PCH_TEST_FREE_KB": str(50 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "0",
        }
    )

    result = subprocess.run(
        [str(project_root / "scripts" / "storage_watch.sh")],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )

    assert result.returncode != 0
    assert victim.read_text(encoding="utf-8") == "do-not-replace\n"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_wrapper_rejects_changed_script(project_root, tmp_path):
    schedule = (project_root / "scripts" / "schedule.sh").read_text(encoding="utf-8")
    prefix = "WATCH_WRAPPER='"
    wrapper = schedule.split(prefix, 1)[1].split("'\n", 1)[0]
    target = tmp_path / "watch.sh"
    marker = tmp_path / "marker"
    target.write_text(f'#!/bin/bash -p\n/usr/bin/touch "{marker}"\n', encoding="utf-8")
    expected_hash = hashlib.sha256(target.read_bytes()).hexdigest()
    target.write_text("#!/bin/bash -p\nexit 99\n", encoding="utf-8")

    result = subprocess.run(
        ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "/bin/bash", "-p", "-c", wrapper, "--", expected_hash, str(target)],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    assert result.returncode == 78
    assert not marker.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_runs_through_the_wrapper_the_launch_agent_uses(project_root, tmp_path):
    """The LaunchAgent pipes the script into `bash -p` on stdin, where BASH_SOURCE
    is unset. Every other test here runs it as a file path, so a top-level
    `source "$(dirname "${BASH_SOURCE[0]}")/..."` passed them all while aborting
    under `set -u` on every scheduled run. Exercise the real invocation."""
    schedule = (project_root / "scripts" / "schedule.sh").read_text(encoding="utf-8")
    wrapper = schedule.split("WATCH_WRAPPER='", 1)[1].split("'\n", 1)[0]
    script = project_root / "scripts" / "storage_watch.sh"
    expected_hash = hashlib.sha256(script.read_bytes()).hexdigest()
    state_dir = tmp_path / "state"

    result = subprocess.run(
        [
            "/usr/bin/env", "-i",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            f"HOME={tmp_path}",
            "PCH_TEST_MODE=1",
            f"PCH_STATE_DIR={state_dir}",
            "PCH_TEST_FREE_KB=" + str(50 * 1024 * 1024),
            "PCH_WATCH_NOTIFY=0",
            "/bin/bash", "-p", "-c", wrapper, "--", expected_hash, str(script),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    assert result.returncode == 0, f"stderr={result.stderr!r}"
    assert "unbound variable" not in result.stderr
    assert parse_protocol(result.stdout)["status"] == "normal"


def test_storage_watch_state_directory_name_matches_the_shared_module(project_root):
    """storage_watch.sh must stay self-contained because the wrapper hash-pins only
    that file and cannot source a sibling over stdin. Self-contained means the name
    is duplicated, so pin the two copies together."""
    module = (project_root / "scripts" / "modules" / "support_dir.sh").read_text(encoding="utf-8")
    watch = (project_root / "scripts" / "storage_watch.sh").read_text(encoding="utf-8")

    for name in ("SUPPORT_DIR_NAME", "LEGACY_SUPPORT_DIR_NAME"):
        declaration = next(
            line.strip() for line in module.splitlines() if line.startswith(f"{name}=")
        )
        assert declaration in watch, f"{name} drifted from modules/support_dir.sh"

    sourced = [
        line.strip()
        for line in watch.splitlines()
        if line.lstrip().startswith(("source ", ". "))
    ]
    assert not sourced, (
        "storage_watch.sh runs from stdin under the LaunchAgent, where BASH_SOURCE is "
        f"unset and the wrapper hash-pins only this file; found {sourced}"
    )


@pytest.mark.skipif(sys.platform != "darwin", reason="launchd plist tools are macOS-only")
def test_schedule_removes_the_agent_installed_before_the_rename(project_root, tmp_path):
    home = tmp_path / "home"
    launch_agents = home / "Library" / "LaunchAgents"
    state_dir = home / "Library" / "Application Support" / "Modore"
    launch_agents.mkdir(parents=True)
    legacy_plist = launch_agents / "me.heznpc.pchealthcheck.storage-watch.plist"
    legacy_plist.write_bytes(
        plistlib.dumps({"Label": "me.heznpc.pchealthcheck.storage-watch"})
    )
    legacy_plist.chmod(0o600)
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_HOME_OVERRIDE": str(home),
            "PCH_LAUNCH_AGENTS_DIR": str(launch_agents),
            "PCH_STATE_DIR": str(state_dir),
        }
    )

    installed = subprocess.run(
        [str(project_root / "scripts" / "schedule.sh"), "--install", "--owner-approved"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )

    assert installed.returncode == 0, installed.stderr
    # Leaving the old label loaded would run the hourly watch twice and hide the
    # stale agent from --status and --uninstall.
    assert not legacy_plist.exists()
    assert (launch_agents / "me.heznpc.modore.storage-watch.plist").is_file()


@pytest.mark.skipif(sys.platform != "darwin", reason="launchd plist tools are macOS-only")
def test_schedule_requires_approval_and_stays_inside_test_home(project_root, tmp_path):
    home = tmp_path / "home"
    launch_agents = home / "Library" / "LaunchAgents"
    state_dir = home / "Library" / "Application Support" / "Modore"
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_HOME_OVERRIDE": str(home),
            "PCH_LAUNCH_AGENTS_DIR": str(launch_agents),
            "PCH_STATE_DIR": str(state_dir),
        }
    )
    injected = tmp_path / "schedule-bash-env-ran"
    payload = tmp_path / "schedule-payload.sh"
    payload.write_text(f'/usr/bin/touch "{injected}"\n', encoding="utf-8")
    env["BASH_ENV"] = str(payload)
    script = project_root / "scripts" / "schedule.sh"

    rejected = subprocess.run(
        [str(script), "--install"], capture_output=True, text=True, encoding="utf-8", env=env
    )
    assert rejected.returncode == 2

    installed = subprocess.run(
        [str(script), "--install", "--owner-approved"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )
    assert installed.returncode == 0, installed.stderr
    assert parse_protocol(installed.stdout)["enabled"] == "true"
    plist = launch_agents / "me.heznpc.modore.storage-watch.plist"
    assert plist.is_file()
    assert not injected.exists()
    definition = plistlib.loads(plist.read_bytes())
    canonical_home = str(home.resolve())
    watcher = project_root / "scripts" / "storage_watch.sh"
    watcher_hash = hashlib.sha256(watcher.read_bytes()).hexdigest()
    wrapper = (
        'set -u; script="$2"; expected="$1"; [[ -f "$script" && ! -L "$script" ]] || exit 78; '
        'size=$(/usr/bin/stat -f "%z" "$script") || exit 78; [[ "$size" -le 1048576 ]] || exit 78; '
        'payload=$(/usr/bin/base64 < "$script") || exit 78; '
        'digest=$(/usr/bin/printf "%s" "$payload" | /usr/bin/base64 -D | /usr/bin/shasum -a 256) || exit 78; '
        'actual="${digest%% *}"; [[ "$actual" == "$expected" ]] || exit 78; '
        '/usr/bin/printf "%s" "$payload" | /usr/bin/base64 -D | /bin/bash -p'
    )
    assert definition == {
        "Label": "me.heznpc.modore.storage-watch",
        "ProgramArguments": [
            "/usr/bin/env",
            "-i",
            f"HOME={canonical_home}",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG=en_US.UTF-8",
            "LC_ALL=en_US.UTF-8",
            "PCH_STORAGE_WATCH_APP_BUNDLE=",
            "/bin/bash",
            "-p",
            "-c",
            wrapper,
            "--",
            watcher_hash,
            str(watcher),
        ],
        "StartInterval": 3600,
        "RunAtLoad": True,
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
    }

    plist.chmod(0o666)
    unsafe_status = subprocess.run(
        [str(script), "--status"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )
    assert unsafe_status.returncode == 0
    assert parse_protocol(unsafe_status.stdout)["enabled"] == "false"
    plist.chmod(0o600)

    removed = subprocess.run(
        [str(script), "--uninstall", "--owner-approved"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )
    assert removed.returncode == 0, removed.stderr
    assert parse_protocol(removed.stdout)["enabled"] == "false"
    assert not plist.exists()


# --- App-identity notification (PCH_STORAGE_WATCH_APP_BUNDLE) --------------------
# osascript's "display notification" can only ever post as com.apple.ScriptEditor2
# (an Apple-binary entitlement), so the watch now tries launching the app itself
# under PCH_STORAGE_WATCH_APP_BUNDLE first and only falls back to osascript if
# that path is unavailable or structurally wrong. These tests pin the safety
# property that actually matters here: no value of that variable — valid,
# malformed, or absent — can ever make the watch itself fail or change its
# reported status. They cannot observe whether a banner appeared on screen
# (that needs a live session), so they do not claim to.

def _fake_app_bundle(root, *, identifier="me.heznpc.modore", suffix=".app"):
    bundle = root / f"Fake{suffix}"
    (bundle / "Contents").mkdir(parents=True)
    plist_path = bundle / "Contents" / "Info.plist"
    plist_path.write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
    return bundle


def _stub_binary(tmp_path, name, *, exit_code=0):
    """Replaces the real /usr/bin/open or /usr/bin/osascript for a test via
    PCH_TEST_OPEN_BIN / PCH_TEST_OSASCRIPT_BIN (storage_watch.sh only honors
    these under PCH_TEST_MODE=1; production always uses the real absolute
    paths, unchanged). `display notification` and `open -a` are real OS calls
    with a real, on-screen effect — running the actual binaries from an
    automated test would post a genuine notification to whatever Mac the
    suite happens to run on, which is a real incident on a developer's own
    daily-use machine, not a harmless side effect. The stub only records that
    it was called and exits with a controllable status."""
    log = tmp_path / "notify-calls.log"
    stub = tmp_path / f"{name}-stub"
    stub.write_text(
        f'#!/bin/bash\nprintf "%s\\n" "{name}" >> "{log}"\nexit {exit_code}\n',
        encoding="utf-8",
    )
    stub.chmod(0o755)
    return stub, log


def _run_watch_with_stubbed_notifiers(project_root, env, tmp_path, *, open_exit=0, osascript_exit=0):
    """Runs storage_watch.sh with both notification binaries stubbed out, and
    reports which one(s) were actually invoked — the only way to tell
    "rejected the bundle, correctly fell back" from "silently did neither"
    (e.g. a validation guard fixed as `return 0` instead of `return 1`, which
    would produce an equally quiet exit 0 with no notification attempted at
    all) without ever touching the real Notification Center."""
    open_stub, log = _stub_binary(tmp_path, "open", exit_code=open_exit)
    osascript_stub, _ = _stub_binary(tmp_path, "osascript", exit_code=osascript_exit)
    env = {
        **env,
        "PCH_TEST_OPEN_BIN": str(open_stub),
        "PCH_TEST_OSASCRIPT_BIN": str(osascript_stub),
    }
    script = project_root / "scripts" / "storage_watch.sh"
    result = subprocess.run([str(script)], capture_output=True, text=True, encoding="utf-8", env=env)
    calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    return result, "open" in calls, "osascript" in calls


def test_storage_watch_posts_via_the_app_bundle_when_open_succeeds(project_root, tmp_path):
    state_dir = tmp_path / "state"
    bundle = _fake_app_bundle(tmp_path)
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "1",
            "PCH_STORAGE_WATCH_APP_BUNDLE": str(bundle),
        }
    )

    result, open_attempted, osascript_attempted = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path, open_exit=0
    )

    assert result.returncode == 0, result.stderr
    assert parse_protocol(result.stdout)["status"] == "warning"
    assert open_attempted, "a correctly identified .app must reach the open call"
    assert not osascript_attempted, "a successful open attempt must not also fall back"


def test_storage_watch_falls_back_to_osascript_when_open_fails(project_root, tmp_path):
    """A correctly identified bundle whose launch genuinely fails (moved, code
    changed, anything) — the whole point of the fallback is to survive this,
    not only a structurally invalid path."""
    state_dir = tmp_path / "state"
    bundle = _fake_app_bundle(tmp_path)
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "1",
            "PCH_STORAGE_WATCH_APP_BUNDLE": str(bundle),
        }
    )

    result, open_attempted, osascript_attempted = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path, open_exit=1
    )

    assert result.returncode == 0, result.stderr
    assert parse_protocol(result.stdout)["status"] == "warning"
    assert open_attempted, "a correctly identified .app must reach the open call"
    assert osascript_attempted, "a failed open attempt must still fall back to osascript"


@pytest.mark.parametrize(
    "make_bundle",
    [
        pytest.param(lambda root: _fake_app_bundle(root, identifier="com.example.other"), id="wrong-identifier"),
        pytest.param(lambda root: _fake_app_bundle(root, suffix=""), id="missing-app-suffix"),
        pytest.param(lambda root: root / "does-not-exist.app", id="missing-directory"),
        pytest.param(lambda root: str(root), id="not-an-app-path-at-all"),
    ],
)
def test_storage_watch_never_reaches_open_for_a_structurally_invalid_bundle(
    project_root, tmp_path, make_bundle
):
    state_dir = tmp_path / "state"
    bundle = make_bundle(tmp_path)
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "1",
            "PCH_STORAGE_WATCH_APP_BUNDLE": str(bundle),
        }
    )

    result, open_attempted, osascript_attempted = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path
    )

    assert result.returncode == 0, result.stderr
    assert parse_protocol(result.stdout)["status"] == "warning"
    assert not open_attempted, "an invalid bundle must be rejected before the open call"
    assert osascript_attempted, "rejecting the bundle must still fall back to osascript"


def test_storage_watch_never_reaches_open_for_a_symlinked_app_bundle_path(project_root, tmp_path):
    state_dir = tmp_path / "state"
    real_bundle = _fake_app_bundle(tmp_path / "real")
    linked = tmp_path / "Linked.app"
    linked.symlink_to(real_bundle)
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "1",
            "PCH_STORAGE_WATCH_APP_BUNDLE": str(linked),
        }
    )

    result, open_attempted, osascript_attempted = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path
    )

    assert result.returncode == 0, result.stderr
    assert parse_protocol(result.stdout)["status"] == "warning"
    assert not open_attempted, "a symlinked bundle path must be rejected before the open call"
    assert osascript_attempted, "rejecting the bundle must still fall back to osascript"


def test_storage_watch_never_reaches_open_when_no_app_bundle_is_configured(project_root, tmp_path):
    """The default, unset case — every install predating this feature, and
    every test above this line in the file. Must fall straight to osascript,
    exactly as before this notification path existed."""
    state_dir = tmp_path / "state"
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "1",
        }
    )
    env.pop("PCH_STORAGE_WATCH_APP_BUNDLE", None)

    result, open_attempted, osascript_attempted = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path
    )

    assert result.returncode == 0, result.stderr
    assert parse_protocol(result.stdout)["status"] == "warning"
    assert not open_attempted, "no configured bundle path must never reach the open call"
    assert osascript_attempted, "an unconfigured bundle path must still fall back to osascript"


def test_schedule_install_threads_the_app_bundle_path_into_the_plist(project_root, tmp_path):
    """The env var the app passes at install time must survive into the
    LaunchAgent definition unchanged, or the scheduled run can never find it."""
    home = tmp_path / "home"
    launch_agents = home / "Library" / "LaunchAgents"
    state_dir = home / "Library" / "Application Support" / "Modore"
    app_bundle = tmp_path / "Modore.app"
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_HOME_OVERRIDE": str(home),
            "PCH_LAUNCH_AGENTS_DIR": str(launch_agents),
            "PCH_STATE_DIR": str(state_dir),
            "PCH_STORAGE_WATCH_APP_BUNDLE": str(app_bundle),
        }
    )
    script = project_root / "scripts" / "schedule.sh"

    installed = subprocess.run(
        [str(script), "--install", "--owner-approved"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )
    assert installed.returncode == 0, installed.stderr

    plist = launch_agents / "me.heznpc.modore.storage-watch.plist"
    definition = plistlib.loads(plist.read_bytes())
    assert f"PCH_STORAGE_WATCH_APP_BUNDLE={app_bundle}" in definition["ProgramArguments"]

    status = subprocess.run(
        [str(script), "--status"], capture_output=True, text=True, encoding="utf-8", env=env
    )
    assert status.returncode == 0, status.stderr
    assert parse_protocol(status.stdout)["loadedDefinitionCurrent"] == "true", (
        "loaded_definition_is_current's expected_arguments must match install_agent's "
        "argument list byte-for-byte, including the new env entry"
    )


def test_schedule_rejects_an_app_bundle_path_without_the_app_suffix(project_root, tmp_path):
    home = tmp_path / "home"
    launch_agents = home / "Library" / "LaunchAgents"
    state_dir = home / "Library" / "Application Support" / "Modore"
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_HOME_OVERRIDE": str(home),
            "PCH_LAUNCH_AGENTS_DIR": str(launch_agents),
            "PCH_STATE_DIR": str(state_dir),
            "PCH_STORAGE_WATCH_APP_BUNDLE": "/Applications/NotAnApp",
        }
    )
    script = project_root / "scripts" / "schedule.sh"

    result = subprocess.run(
        [str(script), "--install", "--owner-approved"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )
    assert result.returncode != 0
    assert not (launch_agents / "me.heznpc.modore.storage-watch.plist").exists()
