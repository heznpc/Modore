import hashlib
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import time

import pytest


def parse_protocol(text: str) -> dict[str, str]:
    values = {}
    for line in text.splitlines():
        if "\t" in line:
            key, value = line.split("\t", 1)
            values[key] = value
    return values


def wait_for_storage_watch_lock(state_dir):
    lock_dir = state_dir / ".storage-watch.lock"
    lock_file = state_dir / ".storage-watch.lockfile"
    for _ in range(100):
        if sys.platform == "darwin" and lock_file.is_file():
            probe = subprocess.run(
                [
                    "/usr/bin/lockf",
                    "-s",
                    "-t",
                    "0",
                    "-k",
                    "-n",
                    str(lock_file),
                    "/usr/bin/true",
                ],
                capture_output=True,
            )
            if probe.returncode == 75:
                return
        elif sys.platform != "darwin" and lock_dir.is_dir():
            return
        time.sleep(0.02)
    raise AssertionError("storage watcher did not acquire its lock")


def test_storage_watch_serializes_launchagent_and_manual_runs(project_root, tmp_path):
    state_dir = tmp_path / "state"
    base_env = os.environ.copy()
    base_env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(50 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "0",
            "PCH_TEST_HOLD_LOCK_SECONDS": "1",
        }
    )
    script = project_root / "scripts" / "storage_watch.sh"
    first = subprocess.Popen(
        [str(script)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        env=base_env,
    )
    lock_dir = state_dir / ".storage-watch.lock"
    wait_for_storage_watch_lock(state_dir)

    second_env = {**base_env, "PCH_TEST_HOLD_LOCK_SECONDS": "0"}
    second_env["PCH_TEST_FREE_KB"] = str(49 * 1024 * 1024)
    second = subprocess.run(
        [str(script)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=second_env,
        timeout=15,
    )
    first_stdout, first_stderr = first.communicate(timeout=15)

    assert first.returncode == 0, first_stderr
    assert second.returncode == 0, second.stderr
    assert parse_protocol(first_stdout)["freeKB"] == str(50 * 1024 * 1024)
    assert parse_protocol(second.stdout)["freeKB"] == str(49 * 1024 * 1024)
    history = (state_dir / "storage-samples.tsv").read_text(encoding="utf-8")
    assert len(history.splitlines()) == 2
    assert not lock_dir.exists()
    if sys.platform == "darwin":
        lock_file = state_dir / ".storage-watch.lockfile"
        assert lock_file.is_file()
        assert stat.S_IMODE(lock_file.stat().st_mode) == 0o600


def test_storage_watch_reports_busy_instead_of_silently_reusing_state(
    project_root, tmp_path
):
    state_dir = tmp_path / "state"
    base_env = os.environ.copy()
    base_env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(50 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "0",
            "PCH_TEST_HOLD_LOCK_SECONDS": "5",
        }
    )
    script = project_root / "scripts" / "storage_watch.sh"
    first = subprocess.Popen(
        [str(script)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        env=base_env,
    )
    wait_for_storage_watch_lock(state_dir)

    second_env = {**base_env, "PCH_TEST_HOLD_LOCK_SECONDS": "0"}
    second_env["PCH_TEST_WATCH_LOCK_ATTEMPTS"] = "2"
    second_env["PCH_TEST_WATCH_LOCK_SECONDS"] = "0"
    contenders = [
        subprocess.Popen(
            [str(script)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            env=second_env,
        )
        for _ in range(16)
    ]
    contender_results = []
    for contender in contenders:
        stdout, stderr = contender.communicate(timeout=5)
        contender_results.append((contender.returncode, stdout, stderr))
    _, first_stderr = first.communicate(timeout=10)

    assert first.returncode == 0, first_stderr
    assert {result[0] for result in contender_results} == {75}
    for _, stdout, stderr in contender_results:
        assert not stderr
        payload = parse_protocol(stdout)
        assert payload["watchStatus"] == "busy"
        assert "마지막 완료 기록" in payload["message"]


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS advisory lock contract")
def test_storage_watch_uses_a_persistent_kernel_lock(project_root):
    source = (project_root / "scripts" / "storage_watch.sh").read_text(
        encoding="utf-8"
    )

    assert "/usr/bin/lockf -s" in source
    assert '-k "$WATCH_LOCK_FILE"' in source
    assert "WATCH_LOCK_HOLDER_PID" in source
    assert "exec 9" not in source


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS advisory lock contract")
def test_storage_watch_lock_ceiling_stops_the_owner_before_unlocking(
    project_root, tmp_path
):
    state_dir = tmp_path / "state"
    env = {
        **os.environ,
        "PCH_TEST_MODE": "1",
        "PCH_STATE_DIR": str(state_dir),
        "PCH_TEST_FREE_KB": str(50 * 1024 * 1024),
        "PCH_WATCH_NOTIFY": "0",
        "PCH_TEST_HOLD_LOCK_SECONDS": "5",
        "PCH_TEST_WATCH_LOCK_HOLDER_SECONDS": "1",
    }
    watcher = subprocess.Popen(
        [str(project_root / "scripts" / "storage_watch.sh")],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        env=env,
    )
    wait_for_storage_watch_lock(state_dir)

    watcher.wait(timeout=5)
    if watcher.stdout is not None:
        watcher.stdout.close()
    if watcher.stderr is not None:
        watcher.stderr.close()

    assert watcher.returncode != 0
    lock_file = state_dir / ".storage-watch.lockfile"
    for _ in range(50):
        probe = subprocess.run(
            [
                "/usr/bin/lockf",
                "-s",
                "-t",
                "0",
                "-k",
                "-n",
                str(lock_file),
                "/usr/bin/true",
            ],
            capture_output=True,
        )
        if probe.returncode == 0:
            break
        time.sleep(0.02)
    else:
        raise AssertionError("watch lock remained held after its owner stopped")


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


def test_storage_watch_captures_private_tmp_swap_and_bounded_rss_metadata(
    project_root, tmp_path
):
    state_dir = tmp_path / "state"
    snapshot_root = tmp_path / "snapshot-roots"
    private_tmp = tmp_path / "private-tmp"
    snapshot_root.mkdir()
    modore_temps = [private_tmp / f"modore-build-{suffix}" for suffix in "abcde"]
    claude_tmp = private_tmp / f"claude-{os.getuid()}"
    ignored_tmp = private_tmp / "unrelated-tool"
    for directory in (*modore_temps, claude_tmp, ignored_tmp):
        directory.mkdir(parents=True)
    for index, directory in enumerate(modore_temps, start=1):
        (directory / "payload.bin").write_bytes(b"m" * (index * 64 * 1024))
    (claude_tmp / "payload.bin").write_bytes(b"c" * (512 * 1024))
    (ignored_tmp / "payload.bin").write_bytes(b"x" * (1024 * 1024))

    swap_fixture = tmp_path / "swap.txt"
    swap_fixture.write_text(
        "vm.swapusage: total = 4096.00M  used = 1024.00M  free = 3072.00M\n",
        encoding="utf-8",
    )
    rss_fixture = tmp_path / "rss.txt"
    codex_executable = "Codex Renderer"
    rss_fixture.write_text(
        f"42 800000 {codex_executable}\n"
        f"43 600000 {codex_executable}\n"
        "44 400000 python3\n"
        "not-a-pid 999999 must-not-appear\n",
        encoding="utf-8",
    )

    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(50 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "0",
            "PCH_WATCH_SNAPSHOT_ROOT": str(snapshot_root),
            "PCH_WATCH_PRIVATE_TMP_ROOT": str(private_tmp),
            "PCH_WATCH_SWAP_TEST_FILE": str(swap_fixture),
            "PCH_WATCH_RSS_TEST_FILE": str(rss_fixture),
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
    assert parse_protocol(baseline.stdout)["signalsRows"] == "0"
    assert not (state_dir / "storage-watch-signals.tsv").exists()

    env["PCH_TEST_FREE_KB"] = str(40 * 1024 * 1024)
    first_drop = subprocess.run(
        [str(script)], capture_output=True, text=True, encoding="utf-8", env=env
    )
    assert first_drop.returncode == 0, first_drop.stderr
    assert parse_protocol(first_drop.stdout)["signalsRows"] == "4"

    path_rows = [
        line.split("\t")
        for line in (state_dir / "storage-watch-paths.tsv")
        .read_text(encoding="utf-8")
        .splitlines()
    ]
    assert {row[3] for row in path_rows} == {"Modore 임시 작업", "Claude 임시 작업"}
    assert {row[4] for row in path_rows} == {
        str(claude_tmp),
        *(str(path) for path in modore_temps),
    }
    assert sum(row[3] == "Modore 임시 작업" for row in path_rows) == 5
    assert str(ignored_tmp) not in {row[4] for row in path_rows}

    # A second rapid drop replaces the previous signal event because the
    # configured event history is one. This fixes the retention bound as well
    # as the per-event row bound (one swap plus three unique executables max).
    swap_fixture.write_text(
        "vm.swapusage: total = 4096.00M  used = 2048.00M  free = 2048.00M\n",
        encoding="utf-8",
    )
    env["PCH_TEST_FREE_KB"] = str(30 * 1024 * 1024)
    second_drop = subprocess.run(
        [str(script)], capture_output=True, text=True, encoding="utf-8", env=env
    )
    assert second_drop.returncode == 0, second_drop.stderr
    payload = parse_protocol(second_drop.stdout)
    assert payload["signalsRows"] == "4"

    signals_file = state_dir / "storage-watch-signals.tsv"
    assert stat.S_IMODE(signals_file.stat().st_mode) == 0o600
    signal_rows = [
        line.split("\t") for line in signals_file.read_text(encoding="utf-8").splitlines()
    ]
    assert len(signal_rows) <= 4
    assert all(len(row) == 8 for row in signal_rows)
    assert len({row[0] for row in signal_rows}) == 1
    latest_at = signal_rows[-1][0]
    latest_rows = [row for row in signal_rows if row[0] == latest_at]
    assert len(latest_rows) == 4
    swap = next(row for row in latest_rows if row[1] == "swap")
    assert swap[2:5] == [str(2 * 1024 * 1024), str(4 * 1024 * 1024), "0"]
    rss_rows = [row for row in latest_rows if row[1] == "process_rss"]
    assert {(row[2], row[4], row[6], row[7]) for row in rss_rows} == {
        ("800000", "42", codex_executable, codex_executable),
        ("600000", "43", codex_executable, codex_executable),
        ("400000", "44", "python3", "python3"),
    }
    assert "must-not-appear" not in signals_file.read_text(encoding="utf-8")

    path_rows_after_second_drop = [
        line.split("\t")
        for line in (state_dir / "storage-watch-paths.tsv")
        .read_text(encoding="utf-8")
        .splitlines()
    ]
    assert len({row[0] for row in path_rows_after_second_drop}) == 1

    # Production asks ps for the short accounting name (`ucomm`) rather than
    # `comm` or `command`, either of which may contain argv on macOS.
    watch_source = script.read_text(encoding="utf-8")
    assert '-U "$(/usr/bin/id -u)"' in watch_source
    assert "pid=,rss=,ucomm=" in watch_source
    assert "pid=,rss=,comm=" not in watch_source
    assert "pid=,rss=,command=" not in watch_source


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS ps process-group contract")
def test_storage_watch_ps_timeout_keeps_partial_rss_and_reaps_descendants(
    project_root, tmp_path
):
    state_dir = tmp_path / "state"
    snapshot_root = tmp_path / "snapshot"
    snapshot_root.mkdir()
    swap_fixture = tmp_path / "swap.txt"
    swap_fixture.write_text(
        "vm.swapusage: total = 1024.00M used = 256.00M free = 768.00M\n",
        encoding="utf-8",
    )
    child_pid_file = tmp_path / "watch-ps-child.pid"
    fake_ps = tmp_path / "ps"
    fake_ps.write_text(
        "#!/bin/bash\n"
        "if [[ \"$*\" == *lstart=* ]]; then exec /bin/ps \"$@\"; fi\n"
        "printf '%s\\n' '42 800000 Codex Renderer'\n"
        "trap '' TERM\n"
        "( trap - TERM; exec /bin/sleep 30 ) &\n"
        "child=$!\n"
        f'printf "%s" "$child" > "{child_pid_file}"\n'
        "wait\n",
        encoding="utf-8",
    )
    fake_ps.chmod(0o755)
    env = {
        **os.environ,
        "PCH_TEST_MODE": "1",
        "PCH_STATE_DIR": str(state_dir),
        "PCH_TEST_FREE_KB": str(50 * 1024 * 1024),
        "PCH_WATCH_NOTIFY": "0",
        "PCH_WATCH_SNAPSHOT_ROOT": str(snapshot_root),
        "PCH_WATCH_SWAP_TEST_FILE": str(swap_fixture),
        "PCH_TEST_WATCH_PS_BIN": str(fake_ps),
        "PCH_TEST_WATCH_METADATA_TICKS": "10",
    }
    script = project_root / "scripts/storage_watch.sh"
    baseline = subprocess.run(
        [str(script)], capture_output=True, text=True, encoding="utf-8", env=env, timeout=5
    )
    assert baseline.returncode == 0, baseline.stderr

    env["PCH_TEST_FREE_KB"] = str(40 * 1024 * 1024)
    dropped = subprocess.run(
        [str(script)], capture_output=True, text=True, encoding="utf-8", env=env, timeout=5
    )

    assert dropped.returncode == 0, dropped.stderr
    rows = [
        line.split("\t")
        for line in (state_dir / "storage-watch-signals.tsv")
        .read_text(encoding="utf-8")
        .splitlines()
    ]
    rss = next(row for row in rows if row[1] == "process_rss")
    assert rss[2:7] == ["800000", "0", "42", "timed_out", "Codex Renderer"]
    child_pid = int(child_pid_file.read_text(encoding="utf-8"))
    for _ in range(50):
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.02)
    else:
        raise AssertionError("storage watcher left a timed-out ps descendant running")


def test_storage_watch_reserves_rows_for_transient_workspaces(project_root, tmp_path):
    state_dir = tmp_path / "state"
    private_tmp = tmp_path / "private-tmp"
    snapshot_root = tmp_path / "snapshot-roots"
    claude_tmp = private_tmp / f"claude-{os.getuid()}"
    claude_tmp.mkdir(parents=True)
    (claude_tmp / "payload.bin").write_bytes(b"c" * (32 * 1024))
    modore_temps = []
    for index in range(5):
        directory = private_tmp / f"modore-work-{index}"
        directory.mkdir(parents=True)
        (directory / "payload.bin").write_bytes(b"m" * ((index + 1) * 64 * 1024))
        modore_temps.append(directory)
    for index in range(10):
        directory = snapshot_root / f"persistent-{index}"
        directory.mkdir(parents=True)
        (directory / "payload.bin").write_bytes(b"p" * (1024 * 1024))

    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(50 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "0",
            "PCH_WATCH_PRIVATE_TMP_ROOT": str(private_tmp),
            "PCH_WATCH_SNAPSHOT_ROOT": str(snapshot_root),
            "PCH_WATCH_SNAPSHOT_TOTAL_SECONDS": "4",
            "PCH_WATCH_SNAPSHOT_ITEM_SECONDS": "1",
        }
    )
    script = project_root / "scripts" / "storage_watch.sh"
    baseline = subprocess.run(
        [str(script)], capture_output=True, text=True, encoding="utf-8", env=env
    )
    assert baseline.returncode == 0, baseline.stderr
    env["PCH_TEST_FREE_KB"] = str(40 * 1024 * 1024)
    dropped = subprocess.run(
        [str(script)], capture_output=True, text=True, encoding="utf-8", env=env
    )
    assert dropped.returncode == 0, dropped.stderr

    rows = [
        line.split("\t")
        for line in (state_dir / "storage-watch-paths.tsv")
        .read_text(encoding="utf-8")
        .splitlines()
    ]
    assert len(rows) == 8
    assert sum(row[3] == "Claude 임시 작업" for row in rows) == 1
    retained_modore = {row[4] for row in rows if row[3] == "Modore 임시 작업"}
    assert retained_modore == {str(path) for path in modore_temps[-3:]}


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS ps field contract")
def test_macos_ucomm_does_not_expose_a_secret_argv0(project_root):
    secret = f"secret-token-in-argv0-{os.getpid()}"
    process = subprocess.Popen(
        ["/bin/bash", "-c", 'exec -a "$1" /bin/sleep 5', "bash", secret]
    )
    try:
        time.sleep(0.1)
        result = subprocess.run(
            ["/bin/ps", "-p", str(process.pid), "-o", "ucomm="],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=True,
        )
        assert result.stdout.strip()
        assert secret not in result.stdout
        watch_source = (project_root / "scripts" / "storage_watch.sh").read_text(
            encoding="utf-8"
        )
        assert "pid=,rss=,ucomm=" in watch_source
    finally:
        process.terminate()
        process.wait(timeout=5)


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
        [
            "/usr/bin/env", "-i",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            # The wrapper's heartbeat write reads $HOME under `set -u`, same as
            # every real invocation (schedule.sh's generated plist always
            # supplies HOME explicitly) -- match that here instead of testing
            # an env shape that can't occur in production.
            f"HOME={tmp_path}",
            "/bin/bash", "-p", "-c", wrapper, "--", expected_hash, str(target),
        ],
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


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_wrapper_heartbeat_records_success(project_root, tmp_path):
    """A stuck/crashing watch and a disabled one both leave storage-samples.tsv
    without a fresh row -- the heartbeat is the only thing that tells them
    apart. A clean run must land all three fields, owner-only."""
    schedule = (project_root / "scripts" / "schedule.sh").read_text(encoding="utf-8")
    wrapper = schedule.split("WATCH_WRAPPER='", 1)[1].split("'\n", 1)[0]
    script = project_root / "scripts" / "storage_watch.sh"
    expected_hash = hashlib.sha256(script.read_bytes()).hexdigest()
    state_dir = tmp_path / "state"
    support_dir = tmp_path / "Library" / "Application Support" / "Modore"
    support_dir.mkdir(parents=True)
    heartbeat = support_dir / "storage-watch-heartbeat.tsv"

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
    assert heartbeat.is_file()
    assert stat.S_IMODE(heartbeat.stat().st_mode) == 0o600
    values = parse_protocol(heartbeat.read_text(encoding="utf-8"))
    assert values["lastAttemptAt"]
    assert values["lastExitCode"] == "0"
    assert values["lastFinishedAt"]


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_wrapper_heartbeat_records_attempt_on_hash_mismatch(project_root, tmp_path):
    """The heartbeat write happens before the hash check, on purpose: a
    tampered/corrupted pinned script must still count as "an attempt was
    made" so a stuck watch doesn't read identically to one that's never
    fired. Only lastAttemptAt should land -- the body never ran."""
    schedule = (project_root / "scripts" / "schedule.sh").read_text(encoding="utf-8")
    wrapper = schedule.split("WATCH_WRAPPER='", 1)[1].split("'\n", 1)[0]
    script = project_root / "scripts" / "storage_watch.sh"
    wrong_hash = hashlib.sha256(b"not the real script").hexdigest()
    support_dir = tmp_path / "Library" / "Application Support" / "Modore"
    support_dir.mkdir(parents=True)
    heartbeat = support_dir / "storage-watch-heartbeat.tsv"

    result = subprocess.run(
        [
            "/usr/bin/env", "-i",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            f"HOME={tmp_path}",
            "/bin/bash", "-p", "-c", wrapper, "--", wrong_hash, str(script),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    assert result.returncode == 78
    assert heartbeat.is_file()
    values = parse_protocol(heartbeat.read_text(encoding="utf-8"))
    assert values["lastAttemptAt"]
    assert "lastExitCode" not in values
    assert "lastFinishedAt" not in values


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_wrapper_heartbeat_records_body_exit_code(project_root, tmp_path):
    """The wrapper must surface the pinned body's real exit code to launchd
    (for launchd-level diagnostics) and record that same code in the
    heartbeat (for the app-level health signal) -- prove both from one run
    of a body that fails for a reason unrelated to hash pinning."""
    schedule = (project_root / "scripts" / "schedule.sh").read_text(encoding="utf-8")
    wrapper = schedule.split("WATCH_WRAPPER='", 1)[1].split("'\n", 1)[0]
    script = tmp_path / "crashing-body.sh"
    script.write_text("exit 42\n", encoding="utf-8")
    expected_hash = hashlib.sha256(script.read_bytes()).hexdigest()
    support_dir = tmp_path / "Library" / "Application Support" / "Modore"
    support_dir.mkdir(parents=True)
    heartbeat = support_dir / "storage-watch-heartbeat.tsv"

    result = subprocess.run(
        [
            "/usr/bin/env", "-i",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            f"HOME={tmp_path}",
            "/bin/bash", "-p", "-c", wrapper, "--", expected_hash, str(script),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    assert result.returncode == 42
    values = parse_protocol(heartbeat.read_text(encoding="utf-8"))
    assert values["lastExitCode"] == "42"
    assert values["lastAttemptAt"]
    assert values["lastFinishedAt"]


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_wrapper_heartbeat_never_follows_a_symlinked_target(project_root, tmp_path):
    """The write is mktemp-into-the-same-directory + atomic mv, mirroring
    storage_watch.sh's own STATE_FILE discipline, specifically so a symlink
    planted at the heartbeat path can never be followed and clobbered -- mv
    replaces the link itself rather than writing through it. Prove the
    stronger property directly: an attacker-controlled path the symlink
    points at must come out byte-for-byte untouched, and the link must
    survive (the wrapper skips the write entirely rather than replacing it),
    with no stray temp files left behind either way."""
    schedule = (project_root / "scripts" / "schedule.sh").read_text(encoding="utf-8")
    wrapper = schedule.split("WATCH_WRAPPER='", 1)[1].split("'\n", 1)[0]
    script = project_root / "scripts" / "storage_watch.sh"
    expected_hash = hashlib.sha256(script.read_bytes()).hexdigest()
    state_dir = tmp_path / "state"
    support_dir = tmp_path / "Library" / "Application Support" / "Modore"
    support_dir.mkdir(parents=True)
    heartbeat = support_dir / "storage-watch-heartbeat.tsv"
    sentinel = tmp_path / "sentinel-do-not-touch"
    sentinel.write_text("PRECIOUS DATA\n", encoding="utf-8")
    heartbeat.symlink_to(sentinel)

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
    assert sentinel.read_text(encoding="utf-8") == "PRECIOUS DATA\n"
    assert heartbeat.is_symlink()
    assert sorted(p.name for p in support_dir.iterdir()) == ["storage-watch-heartbeat.tsv"]


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_wrapper_heartbeat_silently_skips_when_support_dir_absent(project_root, tmp_path):
    """Library/Application Support/Modore is created by the app itself on
    first real launch, never by this wrapper. Until it exists, heartbeat
    writes must be silent no-ops that neither create the directory nor break
    the underlying watch run -- matching storage_watch.sh's own documented
    fail-silently-on-any-write-obstacle contract."""
    schedule = (project_root / "scripts" / "schedule.sh").read_text(encoding="utf-8")
    wrapper = schedule.split("WATCH_WRAPPER='", 1)[1].split("'\n", 1)[0]
    script = project_root / "scripts" / "storage_watch.sh"
    expected_hash = hashlib.sha256(script.read_bytes()).hexdigest()
    state_dir = tmp_path / "state"
    # Deliberately do NOT create tmp_path/Library/Application Support/Modore.

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
    assert parse_protocol(result.stdout)["status"] == "normal"
    assert not (tmp_path / "Library" / "Application Support" / "Modore").exists()


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
    # Extracted from the shipping source rather than hand-duplicated here: a
    # hardcoded copy of this hash-pinned wrapper is exactly what went stale
    # (silently, until CI's exact-equality assertion caught it) when the
    # heartbeat write was added to WATCH_WRAPPER in schedule.sh.
    schedule_source = (project_root / "scripts" / "schedule.sh").read_text(encoding="utf-8")
    wrapper = schedule_source.split("WATCH_WRAPPER='", 1)[1].split("'\n", 1)[0]
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
                "PCH_STORAGE_WATCH_APP_EXECUTABLE_SHA256=",
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
# under PCH_STORAGE_WATCH_APP_BUNDLE first and only accepts that route after
# the app confirms Notification Center accepted the request. These tests pin
# the private acknowledgement, signature/hash identity, and fallback behavior;
# they deliberately do not claim that an on-screen banner was rendered.

def _plist_only_app_bundle(root, *, identifier="me.heznpc.modore", suffix=".app"):
    bundle = root / f"Fake{suffix}"
    (bundle / "Contents").mkdir(parents=True)
    plist_path = bundle / "Contents" / "Info.plist"
    plist_path.write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
    return bundle


def _signed_app_bundle(root, *, identifier="me.heznpc.modore", suffix=".app"):
    bundle = root / f"Fake{suffix}"
    executable = bundle / "Contents" / "MacOS" / "Modore"
    executable.parent.mkdir(parents=True)
    (bundle / "Contents" / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": identifier,
                "CFBundleExecutable": "Modore",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
            }
        )
    )
    shutil.copyfile("/usr/bin/true", executable)
    executable.chmod(0o755)
    signed = subprocess.run(
        ["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(bundle)],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    assert signed.returncode == 0, signed.stderr
    return bundle


def _app_executable_hash(bundle):
    return hashlib.sha256((bundle / "Contents" / "MacOS" / "Modore").read_bytes()).hexdigest()


def _stub_binary(tmp_path, name, *, exit_code=0, acknowledge=False):
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
    acknowledgement = ""
    if acknowledge:
        acknowledgement = (
            'ack=""\n'
            'nonce=""\n'
            'new_instance=0\n'
            'while [[ "$#" -gt 0 ]]; do\n'
            '    case "$1" in\n'
            '        -n) new_instance=1 ;;\n'
            '        --storage-notice-ack) shift; ack="${1:-}" ;;\n'
            '        --storage-notice-nonce) shift; nonce="${1:-}" ;;\n'
            '    esac\n'
            '    shift || true\n'
            'done\n'
            'if [[ "$new_instance" == "1" && -n "$ack" && -n "$nonce" ]]; then\n'
            '    tmp="${ack}.tmp.$$"\n'
            '    /usr/bin/printf "%s" "$nonce" > "$tmp"\n'
            '    /bin/chmod 600 "$tmp"\n'
            '    /bin/mv -f "$tmp" "$ack"\n'
            'fi\n'
        )
    stub.write_text(
        f'#!/bin/bash\nprintf "%s\\n" "{name}" >> "{log}"\n'
        f"{acknowledgement}"
        f"exit {exit_code}\n",
        encoding="utf-8",
    )
    stub.chmod(0o755)
    return stub, log


def _run_watch_with_stubbed_notifiers(
    project_root, env, tmp_path, *, open_exit=0, open_ack=False, osascript_exit=0
):
    """Runs storage_watch.sh with both notification binaries stubbed out, and
    reports which one(s) were actually invoked — the only way to tell
    "rejected the bundle, correctly fell back" from "silently did neither"
    (e.g. a validation guard fixed as `return 0` instead of `return 1`, which
    would produce an equally quiet exit 0 with no notification attempted at
    all) without ever touching the real Notification Center."""
    open_stub, log = _stub_binary(
        tmp_path, "open", exit_code=open_exit, acknowledge=open_ack
    )
    osascript_stub, _ = _stub_binary(tmp_path, "osascript", exit_code=osascript_exit)
    env = {
        **env,
        "PCH_TEST_OPEN_BIN": str(open_stub),
        "PCH_TEST_OSASCRIPT_BIN": str(osascript_stub),
        "PCH_TEST_WATCH_NOTIFICATION_TICKS": "10",
    }
    script = project_root / "scripts" / "storage_watch.sh"
    result = subprocess.run([str(script)], capture_output=True, text=True, encoding="utf-8", env=env)
    calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    return result, "open" in calls, "osascript" in calls


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_accepts_app_notification_only_after_ack(project_root, tmp_path):
    state_dir = tmp_path / "state"
    bundle = _signed_app_bundle(tmp_path)
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "1",
            "PCH_STORAGE_WATCH_APP_BUNDLE": str(bundle),
            "PCH_STORAGE_WATCH_APP_EXECUTABLE_SHA256": _app_executable_hash(bundle),
        }
    )

    result, open_attempted, osascript_attempted = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path, open_exit=0, open_ack=True
    )

    assert result.returncode == 0, result.stderr
    assert parse_protocol(result.stdout)["status"] == "warning"
    assert int(parse_protocol((state_dir / "storage-watch.tsv").read_text())["lastNotify"]) > 0
    assert open_attempted, "a correctly pinned .app must reach the open call"
    assert not osascript_attempted, "a verified app acknowledgement must not fall back"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_falls_back_when_open_exits_zero_without_ack(project_root, tmp_path):
    """`open` only confirms launch dispatch. Without the app's private nonce
    acknowledgement it is not evidence that Notification Center accepted the
    request, so the watcher must still use the fallback."""
    state_dir = tmp_path / "state"
    bundle = _signed_app_bundle(tmp_path)
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
            "PCH_WATCH_NOTIFY": "1",
            "PCH_STORAGE_WATCH_APP_BUNDLE": str(bundle),
            "PCH_STORAGE_WATCH_APP_EXECUTABLE_SHA256": _app_executable_hash(bundle),
        }
    )

    result, open_attempted, osascript_attempted = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path, open_exit=0
    )

    assert result.returncode == 0, result.stderr
    assert parse_protocol(result.stdout)["status"] == "warning"
    assert int(parse_protocol((state_dir / "storage-watch.tsv").read_text())["lastNotify"]) > 0
    assert open_attempted, "a correctly pinned .app must reach the open call"
    assert osascript_attempted, "open success without an acknowledgement must fall back"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_does_not_rate_limit_a_notification_that_never_delivered(
    project_root, tmp_path
):
    state_dir = tmp_path / "state"
    bundle = _signed_app_bundle(tmp_path)
    env = {
        **os.environ,
        "PCH_TEST_MODE": "1",
        "PCH_STATE_DIR": str(state_dir),
        "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
        "PCH_WATCH_NOTIFY": "1",
        "PCH_STORAGE_WATCH_APP_BUNDLE": str(bundle),
        "PCH_STORAGE_WATCH_APP_EXECUTABLE_SHA256": _app_executable_hash(bundle),
    }

    first, first_open, first_osascript = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path, open_exit=1, osascript_exit=1
    )
    second, second_open, second_osascript = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path, open_exit=1, osascript_exit=1
    )

    assert first.returncode == second.returncode == 0
    assert first_open and first_osascript and second_open and second_osascript
    calls = (tmp_path / "notify-calls.log").read_text(encoding="utf-8").splitlines()
    assert calls.count("open") == 2
    assert calls.count("osascript") == 2
    assert parse_protocol((state_dir / "storage-watch.tsv").read_text())["lastNotify"] == "0"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
@pytest.mark.parametrize(
    "make_bundle",
    [
        pytest.param(lambda root: _signed_app_bundle(root, identifier="com.example.other"), id="wrong-identifier"),
        pytest.param(lambda root: _signed_app_bundle(root, suffix=""), id="missing-app-suffix"),
        pytest.param(lambda root: _plist_only_app_bundle(root), id="plist-only"),
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
            "PCH_STORAGE_WATCH_APP_EXECUTABLE_SHA256": "a" * 64,
        }
    )

    result, open_attempted, osascript_attempted = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path
    )

    assert result.returncode == 0, result.stderr
    assert parse_protocol(result.stdout)["status"] == "warning"
    assert not open_attempted, "an invalid bundle must be rejected before the open call"
    assert osascript_attempted, "rejecting the bundle must still fall back to osascript"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_never_reaches_open_for_a_symlinked_app_bundle_path(project_root, tmp_path):
    state_dir = tmp_path / "state"
    real_bundle = _signed_app_bundle(tmp_path / "real")
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
            "PCH_STORAGE_WATCH_APP_EXECUTABLE_SHA256": _app_executable_hash(real_bundle),
        }
    )

    result, open_attempted, osascript_attempted = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path
    )

    assert result.returncode == 0, result.stderr
    assert parse_protocol(result.stdout)["status"] == "warning"
    assert not open_attempted, "a symlinked bundle path must be rejected before the open call"
    assert osascript_attempted, "rejecting the bundle must still fall back to osascript"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
def test_storage_watch_rejects_a_replaced_pinned_executable(project_root, tmp_path):
    state_dir = tmp_path / "state"
    bundle = _signed_app_bundle(tmp_path)
    pinned_hash = _app_executable_hash(bundle)
    executable = bundle / "Contents" / "MacOS" / "Modore"
    shutil.copyfile("/usr/bin/false", executable)
    executable.chmod(0o755)
    resigned = subprocess.run(
        ["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(bundle)],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    assert resigned.returncode == 0, resigned.stderr
    verified = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", str(bundle)],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    assert verified.returncode == 0, verified.stderr
    assert _app_executable_hash(bundle) != pinned_hash
    env = {
        **os.environ,
        "PCH_TEST_MODE": "1",
        "PCH_STATE_DIR": str(state_dir),
        "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
        "PCH_WATCH_NOTIFY": "1",
        "PCH_STORAGE_WATCH_APP_BUNDLE": str(bundle),
        "PCH_STORAGE_WATCH_APP_EXECUTABLE_SHA256": pinned_hash,
    }

    result, open_attempted, osascript_attempted = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path
    )

    assert result.returncode == 0, result.stderr
    assert not open_attempted, "a replaced executable must fail before app launch"
    assert osascript_attempted, "a rejected app must retain the notification fallback"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS watcher wrapper")
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


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS process-group contract")
def test_storage_watch_notification_deadline_stops_the_entire_process_tree(
    project_root, tmp_path
):
    state_dir = tmp_path / "state"
    child_pid_file = tmp_path / "notification-child.pid"
    hanging_notifier = tmp_path / "hanging-osascript"
    hanging_notifier.write_text(
        "#!/bin/bash\n"
        "/bin/sleep 20 &\n"
        "child=$!\n"
        f'/usr/bin/printf "%s\\n" "$child" > "{child_pid_file}"\n'
        # The leader exits successfully while its background child remains.
        # The deadline must therefore observe the whole process group.
        "exit 0\n",
        encoding="utf-8",
    )
    hanging_notifier.chmod(0o755)
    env = {
        **os.environ,
        "PCH_TEST_MODE": "1",
        "PCH_STATE_DIR": str(state_dir),
        "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
        "PCH_WATCH_NOTIFY": "1",
        "PCH_TEST_OSASCRIPT_BIN": str(hanging_notifier),
        "PCH_TEST_WATCH_NOTIFICATION_TICKS": "10",
    }
    env.pop("PCH_STORAGE_WATCH_APP_BUNDLE", None)

    started = time.monotonic()
    result = subprocess.run(
        [str(project_root / "scripts" / "storage_watch.sh")],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=5,
    )

    assert result.returncode == 0, result.stderr
    assert time.monotonic() - started < 4
    assert child_pid_file.is_file()
    child_pid = int(child_pid_file.read_text(encoding="utf-8").strip())
    for _ in range(50):
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.02)
    else:
        raise AssertionError("notification deadline left a descendant process running")


@pytest.mark.skipif(sys.platform != "darwin", reason="launchd plist tools are macOS-only")
def test_schedule_install_threads_the_app_bundle_path_into_the_plist(project_root, tmp_path):
    """The env var the app passes at install time must survive into the
    LaunchAgent definition unchanged, or the scheduled run can never find it."""
    home = tmp_path / "home"
    launch_agents = home / "Library" / "LaunchAgents"
    state_dir = home / "Library" / "Application Support" / "Modore"
    app_bundle = _signed_app_bundle(tmp_path)
    app_executable_hash = _app_executable_hash(app_bundle)
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
    assert (
        f"PCH_STORAGE_WATCH_APP_EXECUTABLE_SHA256={app_executable_hash}"
        in definition["ProgramArguments"]
    )

    status = subprocess.run(
        [str(script), "--status"], capture_output=True, text=True, encoding="utf-8", env=env
    )
    assert status.returncode == 0, status.stderr
    assert parse_protocol(status.stdout)["loadedDefinitionCurrent"] == "true", (
        "loaded_definition_is_current's expected_arguments must match install_agent's "
        "argument list byte-for-byte, including the new env entry"
    )


@pytest.mark.skipif(sys.platform != "darwin", reason="launchd plist tools are macOS-only")
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


@pytest.mark.skipif(sys.platform != "darwin", reason="launchd plist tools are macOS-only")
def test_schedule_rejects_a_plist_only_app_bundle(project_root, tmp_path):
    home = tmp_path / "home"
    launch_agents = home / "Library" / "LaunchAgents"
    state_dir = home / "Library" / "Application Support" / "Modore"
    app_bundle = _plist_only_app_bundle(tmp_path)
    env = {
        **os.environ,
        "PCH_TEST_MODE": "1",
        "PCH_HOME_OVERRIDE": str(home),
        "PCH_LAUNCH_AGENTS_DIR": str(launch_agents),
        "PCH_STATE_DIR": str(state_dir),
        "PCH_STORAGE_WATCH_APP_BUNDLE": str(app_bundle),
    }
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


def test_storage_watch_captures_evidence_when_space_is_low_without_a_sudden_drop(
    project_root, tmp_path
):
    """빠른 감소에만 스냅샷을 찍고 절대 임계값 진입에는 안 찍으면, 며칠에
    걸쳐 25→19→14→8로 내려간 디스크는 매시간 경고만 받고 '그때 뭐가
    컸는지'라는 증거를 하나도 남기지 못한다. 경고가 제기하는 바로 그
    질문이다."""
    state_dir = tmp_path / "state"
    snapshot_root = tmp_path / "snapshot-roots"
    (snapshot_root / "codex-cache").mkdir(parents=True)
    (snapshot_root / "codex-cache" / "payload.bin").write_bytes(b"a" * (1024 * 1024))

    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_STATE_DIR": str(state_dir),
            "PCH_WATCH_NOTIFY": "0",
            "PCH_WATCH_SNAPSHOT_ROOT": str(snapshot_root),
            "PCH_WATCH_SNAPSHOT_TOTAL_SECONDS": "2",
            "PCH_WATCH_SNAPSHOT_ITEM_SECONDS": "1",
            "PCH_WATCH_SNAPSHOT_EVENT_LIMIT": "2",
            # 한 번에 8GB 이상 떨어지지 않도록 작은 폭으로만 내려간다.
            "PCH_WATCH_DROP_GB": "8",
            "PCH_WATCH_FREE_GB": "20",
        }
    )
    script = project_root / "scripts" / "storage_watch.sh"

    def run(free_gb):
        env["PCH_TEST_FREE_KB"] = str(free_gb * 1024 * 1024)
        result = subprocess.run(
            [str(script)], capture_output=True, text=True, encoding="utf-8", env=env
        )
        assert result.returncode == 0, result.stderr
        return parse_protocol(result.stdout)

    assert run(25)["status"] == "normal"

    # 5GB만 줄었으므로 급감 임계값에는 못 미치지만 20GB 아래로 들어간다.
    entered = run(20 - 0)
    entered = run(19)
    assert entered["status"] == "warning"
    assert entered["snapshotReason"] == "entered-low-free"
    assert int(entered["snapshotRows"]) >= 1
    assert (state_dir / "storage-watch-paths.tsv").is_file()

    # 계속 경고 상태로 남아 있다고 매시간 같은 루트를 다시 재지는 않는다.
    staying = run(18)
    assert staying["status"] == "warning"
    assert staying["snapshotReason"] == ""
    assert staying["snapshotRows"] == "0"

    # An installation upgraded from the path-only watcher has no signal file.
    # Seed it after a short floor rather than waiting the full six-hour low-space
    # cooldown; this fixture has no signal provider, but the capture reason and
    # path evidence still prove the upgrade branch ran.
    state_file = state_dir / "storage-watch.tsv"
    state_lines = state_file.read_text(encoding="utf-8").splitlines()
    state_file.write_text(
        "\n".join(
            "lastSnapshot\t0" if line.startswith("lastSnapshot\t") else line
            for line in state_lines
        )
        + "\n",
        encoding="utf-8",
    )
    seeded = run(18)
    assert seeded["snapshotReason"] == "missing-pressure-evidence"
    assert int(seeded["snapshotRows"]) >= 1


@pytest.mark.parametrize("invalid_epoch", ["9999999999", "99999999999"])
def test_storage_watch_normalizes_future_or_out_of_range_timestamps_and_retries(
    project_root, tmp_path, invalid_epoch
):
    state_dir = tmp_path / "state"
    state_dir.mkdir(mode=0o700)
    (state_dir / "storage-watch.tsv").write_text(
        "\n".join(
            [
                "version\t1",
                "status\twarning",
                f"freeKB\t{19 * 1024 * 1024}",
                f"lastNotify\t{invalid_epoch}",
                f"lastSnapshot\t{invalid_epoch}",
                "snapshotCompleteness\tcomplete",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (state_dir / "storage-watch.tsv").chmod(0o600)
    # Keep the test focused on the stored timestamp rather than the separate
    # missing-signal upgrade path.
    (state_dir / "storage-watch-signals.tsv").write_text(
        "2026-01-01T00:00:00Z\tswap\t1\t1\t0\tok\tmacOS swap\t/private/var/vm\n",
        encoding="utf-8",
    )
    (state_dir / "storage-watch-signals.tsv").chmod(0o600)
    snapshot_root = tmp_path / "snapshot-roots"
    (snapshot_root / "cache").mkdir(parents=True)
    env = {
        **os.environ,
        "PCH_TEST_MODE": "1",
        "PCH_STATE_DIR": str(state_dir),
        "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
        "PCH_WATCH_NOTIFY": "1",
        "PCH_WATCH_SNAPSHOT_ROOT": str(snapshot_root),
    }
    env.pop("PCH_STORAGE_WATCH_APP_BUNDLE", None)

    result, open_attempted, osascript_attempted = _run_watch_with_stubbed_notifiers(
        project_root, env, tmp_path
    )

    assert result.returncode == 0, result.stderr
    values = parse_protocol((state_dir / "storage-watch.tsv").read_text(encoding="utf-8"))
    assert not open_attempted
    assert osascript_attempted, "an invalid future lastNotify must not suppress retry"
    assert 0 < int(values["lastNotify"]) <= int(time.time())
    assert values["snapshotReason"] == "still-low-free"
    assert 0 < int(values["lastSnapshot"]) <= int(time.time())


def test_storage_watch_retries_partial_evidence_after_five_minutes(
    project_root, tmp_path
):
    state_dir = tmp_path / "state"
    snapshot_root = tmp_path / "snapshot-roots"
    (snapshot_root / "cache").mkdir(parents=True)
    du_stub = tmp_path / "du-stub"
    du_stub.write_text("#!/bin/bash\nexec /bin/sleep 5\n", encoding="utf-8")
    du_stub.chmod(0o755)
    env = {
        **os.environ,
        "PCH_TEST_MODE": "1",
        "PCH_STATE_DIR": str(state_dir),
        "PCH_TEST_FREE_KB": str(19 * 1024 * 1024),
        "PCH_WATCH_NOTIFY": "0",
        "PCH_WATCH_SNAPSHOT_ROOT": str(snapshot_root),
        "PCH_WATCH_SNAPSHOT_TOTAL_SECONDS": "1",
        "PCH_WATCH_SNAPSHOT_ITEM_SECONDS": "1",
        "PCH_TEST_WATCH_DU_BIN": str(du_stub),
    }
    script = project_root / "scripts" / "storage_watch.sh"

    first = subprocess.run(
        [str(script)], capture_output=True, text=True, encoding="utf-8", env=env, timeout=4
    )
    assert first.returncode == 0, first.stderr
    first_values = parse_protocol((state_dir / "storage-watch.tsv").read_text(encoding="utf-8"))
    assert first_values["snapshotCompleteness"] == "partial"
    assert "timed_out" in (state_dir / "storage-watch-paths.tsv").read_text(encoding="utf-8")

    du_stub.write_text(
        '#!/bin/bash\n/usr/bin/printf "1\\t%s\\n" "$2"\n', encoding="utf-8"
    )
    state_file = state_dir / "storage-watch.tsv"
    state_file.write_text(
        "\n".join(
            f"lastSnapshot\t{int(time.time()) - 301}"
            if line.startswith("lastSnapshot\t")
            else line
            for line in state_file.read_text(encoding="utf-8").splitlines()
        )
        + "\n",
        encoding="utf-8",
    )

    second = subprocess.run(
        [str(script)], capture_output=True, text=True, encoding="utf-8", env=env, timeout=4
    )

    assert second.returncode == 0, second.stderr
    second_values = parse_protocol(
        (state_dir / "storage-watch.tsv").read_text(encoding="utf-8")
    )
    assert second_values["snapshotReason"] == "incomplete-pressure-evidence"
    assert second_values["snapshotCompleteness"] == "complete"
    latest_event = second_values["lastEvidenceAt"]
    latest_rows = [
        line.split("\t")
        for line in (state_dir / "storage-watch-paths.tsv").read_text(encoding="utf-8").splitlines()
        if line.startswith(f"{latest_event}\t")
    ]
    assert latest_rows
    assert all(row[2] == "ok" for row in latest_rows)
