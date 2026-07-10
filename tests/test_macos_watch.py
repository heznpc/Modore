import os
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
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(50 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "0",
        }
    )
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


def test_storage_watch_bounds_history(project_root, tmp_path):
    state_dir = tmp_path / "state"
    env = os.environ.copy()
    env.update(
        {
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
