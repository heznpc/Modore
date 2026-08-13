"""Contract tests for the read-only network observation window.

network_watch.sh takes two lsof samples separated by a wait, like
idle_cpu.sh's two-sample CPU delta. These tests pin the property that makes
it worth having: identity by (process, remote host:port) for established
connections -- ignoring the local ephemeral port -- so an ordinary reconnect
to an already-seen server isn't reported as a "new" connection, while a
genuinely new destination or listening port is.
"""

import os
import subprocess
from pathlib import Path

import pytest

LSOF_HEADER = "COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME"


def run_watcher(
    project_root: Path,
    tmp_path: Path,
    first_established: str,
    second_established: str,
    first_listen: str = "",
    second_listen: str = "",
    *args: str,
):
    files = {
        "first_established.txt": first_established,
        "second_established.txt": second_established,
        "first_listen.txt": first_listen,
        "second_listen.txt": second_listen,
    }
    paths = {}
    for name, content in files.items():
        path = tmp_path / name
        body = content if content.startswith(LSOF_HEADER) or not content else f"{LSOF_HEADER}\n{content}"
        path.write_text(body, encoding="utf-8")
        paths[name] = path

    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_NETWORK_WATCH_FIRST_ESTABLISHED": str(paths["first_established.txt"]),
            "PCH_NETWORK_WATCH_SECOND_ESTABLISHED": str(paths["second_established.txt"]),
            "PCH_NETWORK_WATCH_FIRST_LISTEN": str(paths["first_listen.txt"]),
            "PCH_NETWORK_WATCH_SECOND_LISTEN": str(paths["second_listen.txt"]),
        }
    )
    return subprocess.run(
        [str(project_root / "scripts" / "network_watch.sh"), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )


def parse_values(stdout: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in stdout.splitlines():
        if "\t" not in line:
            continue
        key, value = line.split("\t", 1)
        values[key] = value
    return values


def parse_rows(stdout: str, kind: str) -> list[list[str]]:
    return [
        line.split("\t")[1:]
        for line in stdout.splitlines()
        if line.startswith(f"{kind}\t")
    ]


def test_reconnect_to_the_same_host_on_a_new_local_port_is_not_reported(project_root, tmp_path):
    first = 'Chrome     1000 ren   23u  IPv4 0xaaa      0t0  TCP 192.168.0.156:51000->1.1.1.1:443 (ESTABLISHED)\n'
    second = 'Chrome     1000 ren   23u  IPv4 0xaaa      0t0  TCP 192.168.0.156:51999->1.1.1.1:443 (ESTABLISHED)\n'

    result = run_watcher(project_root, tmp_path, first, second, "--window", "5")

    assert result.returncode == 0, result.stderr
    assert parse_rows(result.stdout, "established") == []
    values = parse_values(result.stdout)
    assert values["newEstablished"] == "0"


def test_a_genuinely_new_remote_destination_is_reported(project_root, tmp_path):
    first = 'Chrome     1000 ren   23u  IPv4 0xaaa      0t0  TCP 192.168.0.156:51000->1.1.1.1:443 (ESTABLISHED)\n'
    second = (
        'Chrome     1000 ren   23u  IPv4 0xaaa      0t0  TCP 192.168.0.156:51999->1.1.1.1:443 (ESTABLISHED)\n'
        'Codex      2000 ren   24u  IPv4 0xbbb      0t0  TCP 192.168.0.156:52000->2.2.2.2:8080 (ESTABLISHED)\n'
    )

    result = run_watcher(project_root, tmp_path, first, second, "--window", "5")

    assert result.returncode == 0, result.stderr
    rows = parse_rows(result.stdout, "established")
    assert rows == [["Codex", "2000", "2.2.2.2:8080"]]
    values = parse_values(result.stdout)
    assert values["newEstablished"] == "1"


def test_a_new_listening_port_is_reported(project_root, tmp_path):
    first_listen = 'rapportd    658  ren   11u  IPv4 0x475      0t0  TCP *:49152 (LISTEN)\n'
    second_listen = (
        'rapportd    658  ren   11u  IPv4 0x475      0t0  TCP *:49152 (LISTEN)\n'
        'newsvc      3000 ren   9u   IPv4 0xccc      0t0  TCP *:9999 (LISTEN)\n'
    )

    result = run_watcher(project_root, tmp_path, "", "", first_listen, second_listen, "--window", "5")

    assert result.returncode == 0, result.stderr
    rows = parse_rows(result.stdout, "listen")
    assert rows == [["newsvc", "3000", "*:9999"]]
    values = parse_values(result.stdout)
    assert values["newListen"] == "1"


def test_no_changes_reports_zero_of_both(project_root, tmp_path):
    established = 'Chrome     1000 ren   23u  IPv4 0xaaa      0t0  TCP 192.168.0.156:51000->1.1.1.1:443 (ESTABLISHED)\n'
    listen = 'rapportd    658  ren   11u  IPv4 0x475      0t0  TCP *:49152 (LISTEN)\n'

    result = run_watcher(project_root, tmp_path, established, established, listen, listen, "--window", "5")

    assert result.returncode == 0, result.stderr
    values = parse_values(result.stdout)
    assert values["newEstablished"] == "0"
    assert values["newListen"] == "0"


def test_watcher_refuses_an_unbounded_window(project_root, tmp_path):
    result = run_watcher(project_root, tmp_path, "", "", "", "", "--window", "9000")

    assert result.returncode == 64
    assert "window" in result.stderr
