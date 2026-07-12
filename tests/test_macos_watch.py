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


@pytest.mark.skipif(sys.platform != "darwin", reason="launchd plist tools are macOS-only")
def test_schedule_requires_approval_and_stays_inside_test_home(project_root, tmp_path):
    home = tmp_path / "home"
    launch_agents = home / "Library" / "LaunchAgents"
    state_dir = home / "Library" / "Application Support" / "PC Health Check"
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
    plist = launch_agents / "me.heznpc.pchealthcheck.storage-watch.plist"
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
        "Label": "me.heznpc.pchealthcheck.storage-watch",
        "ProgramArguments": [
            "/usr/bin/env",
            "-i",
            f"HOME={canonical_home}",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG=en_US.UTF-8",
            "LC_ALL=en_US.UTF-8",
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
