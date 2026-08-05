"""Contract tests for the macOS idle CPU observer.

The default scan reports `ps` %cpu, which is a decaying average over a process's
lifetime. These tests pin the two properties that make the observer worth having
instead: a rate measured between two samples, and attribution to the ancestor
actually responsible for the work.
"""

import os
import subprocess
import sys
from pathlib import Path

import pytest


@pytest.fixture(name="project_root")
def fixture_project_root() -> Path:
    return Path(__file__).resolve().parents[1]


def run_observer(project_root: Path, tmp_path: Path, first: str, second: str, *args: str):
    first_file = tmp_path / "first.txt"
    second_file = tmp_path / "second.txt"
    first_file.write_text(first, encoding="utf-8")
    second_file.write_text(second, encoding="utf-8")
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_IDLE_CPU_FIRST_SAMPLE": str(first_file),
            "PCH_IDLE_CPU_SECOND_SAMPLE": str(second_file),
        }
    )
    return subprocess.run(
        [str(project_root / "scripts" / "idle_cpu.sh"), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )


def parse_rows(stdout: str) -> list[list[str]]:
    return [
        line.split("\t")[1:]
        for line in stdout.splitlines()
        if line.startswith("process\t")
    ]


def parse_values(stdout: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in stdout.splitlines():
        if "\t" not in line or line.startswith("process\t"):
            continue
        key, value = line.split("\t", 1)
        values[key] = value
    return values


@pytest.mark.skipif(sys.platform != "darwin", reason="the idle CPU observer is macOS-only")
def test_rate_comes_from_the_delta_not_the_lifetime_average(project_root, tmp_path):
    # 4321 has burned a lot of CPU over its life but nothing during the window.
    # 4322 has a small lifetime total and consumed a full core during the window.
    first = "4321 1 10:00.00 /usr/bin/quiet-hog\n4322 1 0:00.00 /usr/bin/busy\n"
    second = "4321 1 10:00.00 /usr/bin/quiet-hog\n4322 1 0:05.00 /usr/bin/busy\n"

    result = run_observer(project_root, tmp_path, first, second, "--window", "5")
    rows = parse_rows(result.stdout)

    assert result.returncode == 0, result.stderr
    # The long-lived idle process must not appear at all, and the busy one is
    # reported at the rate it actually used, not its average since launch.
    assert [row[2] for row in rows] == ["busy"]
    assert rows[0][0] == "100.0"


@pytest.mark.skipif(sys.platform != "darwin", reason="the idle CPU observer is macOS-only")
def test_work_started_from_a_terminal_is_not_blamed_on_an_unrelated_app(
    project_root, tmp_path
):
    # A stray interpreter reading another app's files: the process name points at
    # node, while the responsible ancestor is the login shell that launched it.
    table = (
        "1 0 0:00.00 /sbin/launchd\n"
        "900 1 0:01.00 /bin/zsh\n"
        "901 900 {time} /usr/local/bin/node\n"
        "500 1 0:02.00 /Applications/Some.app/Contents/MacOS/Some\n"
    )
    first = table.format(time="0:00.00")
    second = table.format(time="0:04.00")

    result = run_observer(project_root, tmp_path, first, second, "--window", "4")
    rows = parse_rows(result.stdout)

    assert result.returncode == 0, result.stderr
    assert len(rows) == 1
    percent, pid, name, owner_pid, owner_name, from_shell = rows[0]
    assert (pid, name) == ("901", "node")
    assert percent == "100.0"
    assert (owner_pid, owner_name) == ("900", "zsh")
    # Flagging the shell origin is the point: closing the app whose files the
    # process touches would not stop it.
    assert from_shell == "true"


@pytest.mark.skipif(sys.platform != "darwin", reason="the idle CPU observer is macOS-only")
def test_ancestors_resolve_to_the_owning_application(project_root, tmp_path):
    table = (
        "1 0 0:00.00 /sbin/launchd\n"
        "2654 1 0:10.00 /Applications/Editor.app/Contents/MacOS/Electron\n"
        "3001 2654 0:05.00 /Applications/Editor.app/Contents/MacOS/Editor Helper\n"
        "3002 3001 {time} /Applications/Editor.app/Contents/MacOS/Editor Helper\n"
    )
    first = table.format(time="0:00.00")
    second = table.format(time="0:02.00")

    result = run_observer(project_root, tmp_path, first, second, "--window", "4")
    rows = parse_rows(result.stdout)

    assert result.returncode == 0, result.stderr
    assert len(rows) == 1
    _, pid, _, owner_pid, owner_name, from_shell = rows[0]
    assert pid == "3002"
    # A nested helper is attributed to the application process, not to itself and
    # not to launchd.
    assert (owner_pid, owner_name) == ("2654", "Electron")
    assert from_shell == "false"


@pytest.mark.skipif(sys.platform != "darwin", reason="the idle CPU observer is macOS-only")
def test_quiet_processes_and_row_limits_are_bounded(project_root, tmp_path):
    lines_first = ["1 0 0:00.00 /sbin/launchd"]
    lines_second = ["1 0 0:00.00 /sbin/launchd"]
    for index in range(1, 9):
        pid = 5000 + index
        lines_first.append(f"{pid} 1 0:00.00 /usr/bin/worker{index}")
        # Each worker uses a different amount, so ranking is observable.
        lines_second.append(f"{pid} 1 0:0{index}.00 /usr/bin/worker{index}")

    result = run_observer(
        project_root,
        tmp_path,
        "\n".join(lines_first) + "\n",
        "\n".join(lines_second) + "\n",
        "--window",
        "10",
        "--max-rows",
        "3",
        "--min-percent",
        "20",
    )
    rows = parse_rows(result.stdout)
    values = parse_values(result.stdout)

    assert result.returncode == 0, result.stderr
    # Ranked by rate, capped by --max-rows, and filtered by --min-percent, while
    # the summary still reports how many crossed the floor.
    assert [row[2] for row in rows] == ["worker8", "worker7", "worker6"]
    # Each worker used index seconds of a ten second window, so worker1 sits at
    # ten percent and is filtered while workers two through eight clear the floor.
    assert values["observed"] == "7"
    assert values["reported"] == "3"


def test_observer_refuses_an_unbounded_window(project_root, tmp_path):
    result = run_observer(
        project_root, tmp_path, "1 0 0:00.00 /sbin/launchd\n", "1 0 0:00.00 /sbin/launchd\n",
        "--window", "9000",
    )

    assert result.returncode == 64
    assert "window" in result.stderr
