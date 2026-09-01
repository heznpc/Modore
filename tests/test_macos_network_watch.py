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
import sys
import time
from pathlib import Path

import pytest

LSOF_HEADER = "COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME"
# Every real Mac has listening sockets (launchd, rapportd, mDNSResponder), so
# a genuinely empty closing LISTEN read means the read failed. Tests that
# aren't about the listen delta still need a plausible baseline in both
# samples, or they'd be exercising the can't-read path by accident.
BASELINE_LISTEN = 'rapportd    658  ren   11u  IPv4 0x475      0t0  TCP *:49152 (LISTEN)\n'


def run_watcher(
    project_root: Path,
    tmp_path: Path,
    first_established: str,
    second_established: str,
    first_listen: str = BASELINE_LISTEN,
    second_listen: str = BASELINE_LISTEN,
    *args: str,
    sample_statuses=None,
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
    for key, value in (sample_statuses or {}).items():
        env[key] = str(value)
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


@pytest.mark.skipif(sys.platform != "darwin", reason="the network observer is macOS-only")
def test_reconnect_to_the_same_host_on_a_new_local_port_is_not_reported(project_root, tmp_path):
    first = 'Chrome     1000 ren   23u  IPv4 0xaaa      0t0  TCP 192.168.0.156:51000->1.1.1.1:443 (ESTABLISHED)\n'
    second = 'Chrome     1000 ren   23u  IPv4 0xaaa      0t0  TCP 192.168.0.156:51999->1.1.1.1:443 (ESTABLISHED)\n'

    result = run_watcher(project_root, tmp_path, first, second, "--window", "5")

    assert result.returncode == 0, result.stderr
    assert parse_rows(result.stdout, "established") == []
    values = parse_values(result.stdout)
    assert values["newEstablished"] == "0"


@pytest.mark.skipif(sys.platform != "darwin", reason="the network observer is macOS-only")
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


@pytest.mark.skipif(sys.platform != "darwin", reason="the network observer is macOS-only")
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


@pytest.mark.skipif(sys.platform != "darwin", reason="the network observer is macOS-only")
def test_no_changes_reports_zero_of_both(project_root, tmp_path):
    established = 'Chrome     1000 ren   23u  IPv4 0xaaa      0t0  TCP 192.168.0.156:51000->1.1.1.1:443 (ESTABLISHED)\n'
    listen = 'rapportd    658  ren   11u  IPv4 0x475      0t0  TCP *:49152 (LISTEN)\n'

    result = run_watcher(project_root, tmp_path, established, established, listen, listen, "--window", "5")

    assert result.returncode == 0, result.stderr
    values = parse_values(result.stdout)
    assert values["newEstablished"] == "0"
    assert values["newListen"] == "0"


@pytest.mark.skipif(sys.platform != "darwin", reason="the network observer is macOS-only")
def test_lsof_escaped_spaces_in_process_names_are_unescaped(project_root, tmp_path):
    # lsof escapes a space inside a COMMAND name as literal "\x20"
    # ("Codex " -> "Codex\x20") -- real output from this machine, not
    # hypothetical. Passed through verbatim it leaks into the app's UI;
    # the trailing space itself is 9-character truncation residue and is
    # trimmed rather than shown invisibly.
    first = 'Chrome     1000 ren   23u  IPv4 0xaaa      0t0  TCP 192.168.0.156:51000->1.1.1.1:443 (ESTABLISHED)\n'
    second = (
        'Chrome     1000 ren   23u  IPv4 0xaaa      0t0  TCP 192.168.0.156:51000->1.1.1.1:443 (ESTABLISHED)\n'
        'Codex\\x20  1142 ren   24u  IPv4 0xbbb      0t0  TCP 192.168.0.156:52000->2.2.2.2:8080 (ESTABLISHED)\n'
    )
    first_listen = BASELINE_LISTEN
    second_listen = BASELINE_LISTEN + 'Manus\\x20  2200 ren   11u  IPv4 0xccc      0t0  TCP *:9999 (LISTEN)\n'

    result = run_watcher(
        project_root, tmp_path, first, second, first_listen, second_listen, "--window", "5"
    )

    assert result.returncode == 0, result.stderr
    assert parse_rows(result.stdout, "established") == [["Codex", "1142", "2.2.2.2:8080"]]
    assert parse_rows(result.stdout, "listen") == [["Manus", "2200", "*:9999"]]


@pytest.mark.skipif(sys.platform != "darwin", reason="the network observer is macOS-only")
def test_a_failed_first_sample_does_not_suppress_new_reports(project_root, tmp_path):
    # When the first lsof invocation fails, `|| true` swallows it and the
    # first sample file is empty -- lsof also exits 1 with no output when
    # nothing matches, so an empty sample is a real production shape. The
    # original awk used the FNR==NR idiom, which misreads the second file
    # as the first when the first is empty: every connection made during
    # the window was registered as "already seen" and reporting went
    # silent. With no baseline the row can't be distinguished from a
    # genuinely new one, and over-reporting is the safe direction.
    second = 'Codex      1142 ren   24u  IPv4 0xbbb      0t0  TCP 192.168.0.156:52000->2.2.2.2:8080 (ESTABLISHED)\n'

    result = run_watcher(
        project_root, tmp_path, "", second, BASELINE_LISTEN, BASELINE_LISTEN, "--window", "5"
    )

    assert result.returncode == 0, result.stderr
    assert parse_rows(result.stdout, "established") == [["Codex", "1142", "2.2.2.2:8080"]]


@pytest.mark.skipif(sys.platform != "darwin", reason="the network observer is macOS-only")
def test_an_unreadable_closing_sample_is_reported_not_read_as_a_quiet_window(project_root, tmp_path):
    # The sample's exit status is carried separately from its output. An empty
    # successful sample is a quiet window; an empty failed sample is incomplete.
    established = 'Chrome     1000 ren   23u  IPv4 0xaaa      0t0  TCP 192.168.0.156:51000->1.1.1.1:443 (ESTABLISHED)\n'

    result = run_watcher(
        project_root,
        tmp_path,
        established,
        established,
        BASELINE_LISTEN,
        "",
        "--window",
        "5",
        sample_statuses={"PCH_NETWORK_WATCH_SECOND_LISTEN_STATUS": 2},
    )

    assert result.returncode == 0, result.stderr
    values = parse_values(result.stdout)
    assert "error" in values, values
    # A caller must not be able to read this as "0 new connections".
    assert "newEstablished" not in values
    assert "newListen" not in values


@pytest.mark.skipif(sys.platform != "darwin", reason="the network observer is macOS-only")
def test_failed_established_sample_is_not_hidden_by_a_healthy_listen_sample(
    project_root, tmp_path
):
    established = 'Chrome 1000 ren 23u IPv4 0xaaa 0t0 TCP 127.0.0.1:5000->1.1.1.1:443 (ESTABLISHED)\n'
    result = run_watcher(
        project_root,
        tmp_path,
        established,
        "",
        BASELINE_LISTEN,
        BASELINE_LISTEN,
        "--window",
        "5",
        sample_statuses={"PCH_NETWORK_WATCH_SECOND_ESTABLISHED_STATUS": 2},
    )

    assert result.returncode == 0, result.stderr
    values = parse_values(result.stdout)
    assert values["secondEstablishedStatus"] == "failed"
    assert values["secondListenStatus"] == "ok"
    assert "error" in values
    assert "newEstablished" not in values


@pytest.mark.skipif(sys.platform != "darwin", reason="the network observer is macOS-only")
def test_real_lsof_invocations_preserve_each_exit_status(project_root, tmp_path):
    counter = tmp_path / "lsof-count"
    fake_lsof = tmp_path / "lsof"
    fake_lsof.write_text(
        "#!/bin/bash\n"
        f'count="$(/bin/cat "{counter}" 2>/dev/null || printf 0)"\n'
        'count=$((count + 1))\n'
        f'/usr/bin/printf "%s" "$count" > "{counter}"\n'
        "if [[ \"$count\" -eq 3 ]]; then echo 'fault' >&2; exit 2; fi\n"
        f"printf '%s\\n' '{LSOF_HEADER}'\n"
        "if [[ \"$*\" == *LISTEN* ]]; then "
        f"printf '%s' '{BASELINE_LISTEN}'; fi\n",
        encoding="utf-8",
    )
    fake_lsof.chmod(0o755)
    env = {
        **os.environ,
        "PCH_TEST_MODE": "1",
        "PCH_TEST_LSOF_BIN": str(fake_lsof),
        "PCH_TEST_NETWORK_LSOF_TIMEOUT_TICKS": "5",
    }

    result = subprocess.run(
        [str(project_root / "scripts" / "network_watch.sh"), "--window", "1"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=5,
    )

    assert result.returncode == 0, result.stderr
    values = parse_values(result.stdout)
    assert counter.read_text(encoding="utf-8") == "4"
    assert values["firstEstablishedStatus"] == "ok"
    assert values["firstListenStatus"] == "ok"
    assert values["secondEstablishedStatus"] == "failed"
    assert values["secondListenStatus"] == "ok"
    assert "newEstablished" not in values


@pytest.mark.skipif(sys.platform != "darwin", reason="the network observer is macOS-only")
def test_network_watch_refuses_to_compute_from_output_limited_samples(
    project_root, tmp_path
):
    fake_lsof = tmp_path / "large-lsof"
    fake_lsof.write_text(
        "#!/bin/bash\n"
        f"printf '%s\\n' '{LSOF_HEADER}'\n"
        "i=0\n"
        "while [[ $i -lt 500 ]]; do printf 'x%080d\\n' \"$i\"; i=$((i + 1)); done\n",
        encoding="utf-8",
    )
    fake_lsof.chmod(0o755)
    env = {
        **os.environ,
        "PCH_TEST_MODE": "1",
        "PCH_TEST_LSOF_BIN": str(fake_lsof),
        "PCH_TEST_NETWORK_LSOF_TIMEOUT_TICKS": "10",
        "PCH_TEST_NETWORK_LSOF_OUTPUT_LIMIT_KB": "1",
    }

    result = subprocess.run(
        [str(project_root / "scripts/network_watch.sh"), "--window", "1"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=5,
    )

    assert result.returncode == 0, result.stderr
    values = parse_values(result.stdout)
    assert values["firstEstablishedStatus"] == "output_limited"
    assert values["secondListenStatus"] == "output_limited"
    assert "error" in values
    assert "newEstablished" not in values


def test_scanner_lsof_timeout_keeps_partial_rows_and_reaps_descendants(
    project_root, tmp_path
):
    module = project_root / "scripts/modules/macos/network.sh"
    child_pid_file = tmp_path / "scanner-lsof-child.pid"
    fake_lsof = tmp_path / "scanner-lsof"
    fake_lsof.write_text(
        "#!/bin/bash\n"
        f"printf '%s\\n' '{LSOF_HEADER}'\n"
        "printf '%s\\n' 'Codex 42 ren 2u IPv4 0x1 0t0 TCP 127.0.0.1:1->1.1.1.1:443 (ESTABLISHED)'\n"
        "trap '' TERM\n"
        "( trap - TERM; exec /bin/sleep 30 ) &\n"
        "child=$!\n"
        f'printf "%s" "$child" > "{child_pid_file}"\n'
        "wait\n",
        encoding="utf-8",
    )
    fake_lsof.chmod(0o755)
    env = {
        **os.environ,
        "TMP_DIR": str(tmp_path),
        "PCH_TEST_MODE": "1",
        "PCH_TEST_NETWORK_LSOF_BIN": str(fake_lsof),
        "PCH_NETWORK_COMMAND_TIMEOUT_TICKS": "5",
    }
    harness = (
        'record_collection_status() { printf "%s\\t%s\\t%s\\t%s\\t%s\\n" "$@" >> "$TMP_DIR/status.tsv"; }\n'
        'collection_failure_status() { [[ "$1" -eq 124 ]] && printf timed_out || printf failed; }\n'
        '. "$1"\n'
        'collect_network\n'
    )

    result = subprocess.run(
        ["/bin/bash", "-c", harness, "bash", str(module)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=5,
    )

    assert result.returncode == 0, result.stderr
    assert "Codex 42" in (tmp_path / "net.txt").read_text(encoding="utf-8")
    status = (tmp_path / "status.tsv").read_text(encoding="utf-8").split("\t")
    assert status[0] == "network_connections"
    assert status[2] == "timed_out"
    assert "일부 행" in status[4]
    child_pid = int(child_pid_file.read_text(encoding="utf-8"))
    for _ in range(50):
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.02)
    else:
        raise AssertionError("timed-out lsof left a descendant running")


def test_scanner_lsof_output_is_bounded_without_discarding_its_prefix(
    project_root, tmp_path
):
    module = project_root / "scripts/modules/macos/network.sh"
    fake_lsof = tmp_path / "scanner-lsof-large"
    fake_lsof.write_text(
        "#!/bin/bash\n"
        f"printf '%s\\n' '{LSOF_HEADER}'\n"
        "i=0\n"
        "while [[ $i -lt 500 ]]; do "
        "printf 'Codex %d ren 2u IPv4 0x1 0t0 TCP 127.0.0.1:1->1.1.1.1:443 (ESTABLISHED)\\n' \"$i\"; "
        "i=$((i + 1)); done\n",
        encoding="utf-8",
    )
    fake_lsof.chmod(0o755)
    env = {
        **os.environ,
        "TMP_DIR": str(tmp_path),
        "PCH_TEST_MODE": "1",
        "PCH_TEST_NETWORK_LSOF_BIN": str(fake_lsof),
        "PCH_NETWORK_COMMAND_TIMEOUT_TICKS": "20",
        "PCH_NETWORK_OUTPUT_LIMIT_KB": "1",
    }
    harness = (
        'record_collection_status() { printf "%s\\t%s\\t%s\\t%s\\t%s\\n" "$@" >> "$TMP_DIR/status.tsv"; }\n'
        'collection_failure_status() { [[ "$1" -eq 124 ]] && printf timed_out || printf failed; }\n'
        '. "$1"\ncollect_network\n'
    )

    result = subprocess.run(
        ["/bin/bash", "-c", harness, "bash", str(module)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=5,
    )

    assert result.returncode == 0, result.stderr
    output = (tmp_path / "net.txt").read_bytes()
    assert output.startswith(LSOF_HEADER.encode("utf-8"))
    assert 0 < len(output) <= 1024
    status = (tmp_path / "status.tsv").read_text(encoding="utf-8").split("\t")
    assert status[2] == "failed"
    assert "일부 행" in status[4]


def test_watcher_refuses_an_unbounded_window(project_root, tmp_path):
    result = run_watcher(project_root, tmp_path, "", "", "", "", "--window", "9000")

    assert result.returncode == 64
    assert "window" in result.stderr
