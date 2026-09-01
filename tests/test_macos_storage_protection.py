import json
import os
import signal
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest


def test_developer_sdk_bundle_is_excluded_from_generic_app_removal(project_root, tmp_path):
    app = tmp_path / "Developer Suite.app"
    (app / "Contents" / "Developer" / "Platforms").mkdir(parents=True)
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"

    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            '. "$1"; _pch_is_protected_developer_app "$2" "$3"',
            "bash",
            str(script),
            str(app),
            "org.example.developer-suite",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    assert result.returncode == 0, result.stderr


def test_codex_and_claude_work_records_are_protected_inventory(project_root):
    source = (project_root / "scripts" / "modules" / "macos" / "storage.sh").read_text(
        encoding="utf-8"
    )
    protected_paths = {
        '$HOME/.codex/sessions',
        '$HOME/.codex/archived_sessions',
        '$HOME/.codex/history.jsonl',
        '$HOME/.codex/session_index.jsonl',
        '$HOME/.codex/worktrees',
        '$HOME/.codex/shell_snapshots',
        '$HOME/.codex/sqlite',
        '$HOME/.codex/attachments',
        '$HOME/.codex/automations',
        '$HOME/.codex/generated_images',
        '$HOME/.codex/vendor_imports',
        '$HOME/.codex/visualizations',
        '$HOME/Library/Application Support/Claude/local-agent-mode-sessions',
        '$HOME/.claude/projects',
        '$HOME/.claude/sessions',
        '$HOME/.claude/history.jsonl',
        '$HOME/.claude/session-env',
        '$HOME/.claude/worktrees',
        '$HOME/.claude/shell-snapshots',
        '$HOME/.claude/tasks',
        '$HOME/.claude/plans',
        '$HOME/.claude/file-history',
        '$HOME/Library/Application Support/Claude/databases',
        '$HOME/Library/Application Support/Claude/claude-code-sessions',
        '$HOME/Library/Application Support/Claude/claude-code',
        '$HOME/Library/Application Support/Claude/claude-code-vm',
        '$HOME/Library/Application Support/Claude/IndexedDB',
        '$HOME/Library/Application Support/Claude/Local Storage',
        '$HOME/Library/Application Support/Claude/Session Storage',
        '$HOME/Library/Application Support/Claude/Partitions',
        '$HOME/Library/Application Support/Claude/WebStorage',
        '$HOME/Library/Application Support/Claude/shared_proto_db',
        '$HOME/Library/Application Support/Claude/pending-uploads',
    }

    for path in protected_paths:
        matching_lines = [line for line in source.splitlines() if f'"{path}"' in line]
        assert matching_lines, f"missing protected inventory path: {path}"
        assert all(
            'add_du_path "protected_history"' in line or 'add_du_path "ai_review"' in line
            for line in matching_lines
        ), f"work record is not classified as protected/manual review: {path}"


def test_browser_automation_roots_are_grouped_without_exposing_commands(project_root):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    process_snapshot = "\n".join(
        [
            "1 0 10-00:00:00 1024 /sbin/launchd",
            "999101 1 02:00:42 262144 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-pipe --user-data-dir=/tmp/profile?token=secret",
            "999102 999101 02:00:41 131072 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=renderer --remote-debugging-pipe",
            "999199 999198 03:00 1024 /sbin/worker",
            "999200 999199 02:30 2048 /Applications/Codex.app/Contents/MacOS/Codex",
            "999201 999200 02:15 196608 /Users/test/Library/Caches/ms-playwright/chromium-123/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing --no-startup-window --remote-debugging-pipe",
            "999301 999300 00:03 2048 /usr/local/bin/node playwright_chromiumdev_profile=/tmp/profile?token=secret",
            "999401 999400 05:00 327680 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        ]
    )

    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            '. "$1"; _pch_browser_automation_roots',
            "bash",
            str(script),
        ],
        input=process_snapshot,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    assert result.returncode == 0, result.stderr
    rows = [line.split("\t") for line in result.stdout.splitlines()]
    assert rows == [
        ["999101", "1", "02:00:42", "system", "orphan_candidate", "temporary", "other local process", "262144", "393216", "2"],
        ["999201", "999200", "02:15", "isolated", "active", "default", "Codex", "196608", "196608", "1"],
    ]
    assert "token=secret" not in result.stdout
    assert "remote-debugging-pipe" not in result.stdout
    assert "Google Chrome Helper" not in result.stdout


def test_browser_automation_analysis_caps_roots_without_repeated_ps(project_root):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    process_snapshot = ["1 0 10-00:00:00 1024 /sbin/launchd"]
    process_snapshot.extend(
        f"{50000 + index} 1 02:00:00 1024 "
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome "
        "--headless --remote-debugging-port=9222 --token=secret"
        for index in range(1000)
    )
    env = os.environ.copy()
    env.update(
        {
            "PCH_BROWSER_AUTOMATION_ROOT_LIMIT": "32",
            "PCH_BROWSER_ANALYSIS_WORK_LIMIT": "200000",
        }
    )

    started = time.monotonic()
    result = subprocess.run(
        ["/bin/bash", "-c", '. "$1"; _pch_browser_automation_roots', "bash", str(script)],
        input="\n".join(process_snapshot),
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=5,
    )
    elapsed = time.monotonic() - started

    assert result.returncode == 0, result.stderr
    rows = result.stdout.splitlines()
    assert rows[-1] == "__PCH_BROWSER_BOUNDED__"
    assert len(rows[:-1]) == 32
    assert elapsed < 3
    assert "secret" not in result.stdout


def _storage_tool(path: Path, body: str) -> Path:
    path.write_text("#!/bin/bash\nset -u\n" + body, encoding="utf-8")
    path.chmod(0o755)
    return path


def _process_parent_and_state() -> dict[int, tuple[int, str]]:
    snapshot = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,state="],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=True,
    ).stdout
    rows = {}
    for line in snapshot.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            rows[int(fields[0])] = (int(fields[1]), fields[2])
    return rows


def _descendant_pids(
    root_pid: int, rows: dict[int, tuple[int, str]]
) -> set[int]:
    descendants = set()
    parents = {root_pid}
    while parents:
        children = {
            pid
            for pid, (parent_pid, _) in rows.items()
            if parent_pid in parents and pid not in descendants
        }
        descendants.update(children)
        parents = children
    return descendants


def _run_application_collector(
    project_root: Path,
    sandbox: Path,
    applications: Path,
    plist_tool: Path,
    mdls_tool: Path,
    *,
    extra_env=None,
) -> subprocess.CompletedProcess[str]:
    facts = sandbox / "facts"
    facts.mkdir(exist_ok=True)
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(sandbox / "home"),
            "TMP_DIR": str(facts),
            "PCH_TEST_MODE": "1",
            "PCH_TEST_STORAGE_TOOL_ROOT": str(sandbox),
            "PCH_TEST_STORAGE_APPLICATIONS_ROOT": str(applications),
            "PCH_TEST_STORAGE_PLISTBUDDY_BIN": str(plist_tool),
            "PCH_TEST_STORAGE_MDLS_BIN": str(mdls_tool),
            "PCH_STORAGE_APPLICATION_COMMAND_TIMEOUT": "1",
            "PCH_STORAGE_APPLICATION_TOTAL_BUDGET": "3",
        }
    )
    env.update(extra_env or {})
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    return subprocess.run(
        [
            "/bin/bash",
            "-c",
            (
                '. "$1"; seen="|"; '
                "add_sized_path() { printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "
                '"$1" "$2" "$3" "$4" "$5" "${6:-}" >> "$TMP_DIR/apps.tsv"; }; '
                "_pch_collect_storage_applications"
            ),
            "bash",
            str(script),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=6,
    )


def test_application_collector_rejects_special_linked_and_oversized_plists(
    project_root, tmp_path
):
    sandbox = tmp_path / "sandbox"
    applications = sandbox / "Applications"
    applications.mkdir(parents=True)
    trace = sandbox / "tools.trace"
    plist_tool = _storage_tool(
        sandbox / "plist-tool",
        f'printf "plist\\n" >> "{trace}"\nprintf "org.example.safe\\n"\n',
    )
    mdls_tool = _storage_tool(
        sandbox / "mdls-tool",
        f'printf "mdls\\n" >> "{trace}"\nprintf "1048576\\n"\n',
    )

    fifo_app = applications / "FIFO.app" / "Contents"
    fifo_app.mkdir(parents=True)
    os.mkfifo(fifo_app / "Info.plist")
    linked_app = applications / "Linked.app" / "Contents"
    linked_app.mkdir(parents=True)
    target = sandbox / "outside.plist"
    target.write_text("plist", encoding="utf-8")
    (linked_app / "Info.plist").symlink_to(target)
    hardlink_app = applications / "Hardlink.app" / "Contents"
    hardlink_app.mkdir(parents=True)
    os.link(target, hardlink_app / "Info.plist")
    oversized_app = applications / "Oversized.app" / "Contents"
    oversized_app.mkdir(parents=True)
    (oversized_app / "Info.plist").write_bytes(b"x" * (4 * 1024 * 1024 + 1))

    result = _run_application_collector(
        project_root, sandbox, applications, plist_tool, mdls_tool
    )

    assert result.returncode == 0, result.stderr
    assert not trace.exists()
    assert not (sandbox / "facts" / "apps.tsv").exists()


@pytest.mark.parametrize("slow_tool", ["plist", "mdls"])
def test_application_metadata_tools_have_process_group_timeout(
    project_root, tmp_path, slow_tool
):
    sandbox = tmp_path / "sandbox"
    applications = sandbox / "Applications"
    contents = applications / "Slow.app" / "Contents"
    contents.mkdir(parents=True)
    (contents / "Info.plist").write_text("plist", encoding="utf-8")
    child_pid = sandbox / "child.pid"
    slow_body = f'/bin/sleep 30 &\nprintf "%s" "$!" > "{child_pid}"\nwait\n'
    plist_body = slow_body if slow_tool == "plist" else 'printf "org.example.safe\\n"\n'
    mdls_body = slow_body if slow_tool == "mdls" else 'printf "1048576\\n"\n'
    plist_tool = _storage_tool(sandbox / "plist-tool", plist_body)
    mdls_tool = _storage_tool(sandbox / "mdls-tool", mdls_body)

    started = time.monotonic()
    result = _run_application_collector(
        project_root, sandbox, applications, plist_tool, mdls_tool
    )
    elapsed = time.monotonic() - started

    assert result.returncode == 0, result.stderr
    assert elapsed < 3
    assert child_pid.exists()
    pid = child_pid.read_text(encoding="utf-8")
    live = subprocess.run(
        ["/bin/ps", "-p", pid, "-o", "pid="], capture_output=True, text=True
    )
    assert not live.stdout.strip(), "timed-out metadata tool left a child process"


def test_application_metadata_output_and_app_count_are_bounded(project_root, tmp_path):
    sandbox = tmp_path / "sandbox"
    applications = sandbox / "Applications"
    for index in range(5):
        contents = applications / f"App-{index}.app" / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_text("plist", encoding="utf-8")
    trace = sandbox / "calls.trace"
    plist_tool = _storage_tool(
        sandbox / "plist-tool",
        f'printf "call\\n" >> "{trace}"\n/usr/bin/yes "org.example.too-large"\n',
    )
    mdls_tool = _storage_tool(sandbox / "mdls-tool", 'printf "1048576\\n"\n')

    started = time.monotonic()
    result = _run_application_collector(
        project_root,
        sandbox,
        applications,
        plist_tool,
        mdls_tool,
        extra_env={
            "PCH_STORAGE_APPLICATION_LIMIT": "2",
            "PCH_STORAGE_APPLICATION_OUTPUT_LIMIT_KB": "1",
        },
    )
    elapsed = time.monotonic() - started

    assert result.returncode == 0, result.stderr
    assert elapsed < 3
    assert trace.read_text(encoding="utf-8").splitlines() == ["call", "call"]
    assert not (sandbox / "facts" / "apps.tsv").exists()
    assert list((sandbox / "facts").glob("storage_app_*")) == []


def test_application_metadata_tools_share_total_budget(project_root, tmp_path):
    sandbox = tmp_path / "sandbox"
    applications = sandbox / "Applications"
    contents = applications / "Budget.app" / "Contents"
    contents.mkdir(parents=True)
    (contents / "Info.plist").write_text("plist", encoding="utf-8")
    child_pid = sandbox / "budget-child.pid"
    plist_tool = _storage_tool(
        sandbox / "plist-tool",
        f'/bin/sleep 30 &\nprintf "%s" "$!" > "{child_pid}"\nwait\n',
    )
    mdls_tool = _storage_tool(sandbox / "mdls-tool", 'printf "1048576\\n"\n')

    started = time.monotonic()
    result = _run_application_collector(
        project_root,
        sandbox,
        applications,
        plist_tool,
        mdls_tool,
        extra_env={
            "PCH_STORAGE_APPLICATION_COMMAND_TIMEOUT": "5",
            "PCH_STORAGE_APPLICATION_TOTAL_BUDGET": "1",
        },
    )
    elapsed = time.monotonic() - started

    assert result.returncode == 0, result.stderr
    assert elapsed < 3
    pid = child_pid.read_text(encoding="utf-8")
    assert not subprocess.run(
        ["/bin/ps", "-p", pid, "-o", "pid="], capture_output=True, text=True
    ).stdout.strip()


def test_fast_application_metadata_does_not_wait_for_watchdog(project_root, tmp_path):
    sandbox = tmp_path / "sandbox"
    applications = sandbox / "Applications"
    contents = applications / "Fast.app" / "Contents"
    contents.mkdir(parents=True)
    (contents / "Info.plist").write_text("plist", encoding="utf-8")
    plist_tool = _storage_tool(
        sandbox / "plist-tool", 'printf "org.example.fast\\n"\n'
    )
    mdls_tool = _storage_tool(sandbox / "mdls-tool", 'printf "1048576\\n"\n')

    started = time.monotonic()
    result = _run_application_collector(
        project_root,
        sandbox,
        applications,
        plist_tool,
        mdls_tool,
        extra_env={
            "PCH_STORAGE_APPLICATION_COMMAND_TIMEOUT": "20",
            "PCH_STORAGE_APPLICATION_TOTAL_BUDGET": "30",
        },
    )
    elapsed = time.monotonic() - started

    assert result.returncode == 0, result.stderr
    # Both metadata calls use a 20-second watchdog. A two-second ceiling still
    # proves the success path does not wait for it, without turning ordinary
    # scheduler contention into a 10-millisecond CI failure.
    assert elapsed < 2
    rows = (sandbox / "facts" / "apps.tsv").read_text(encoding="utf-8").splitlines()
    assert len(rows) == 1
    assert "org.example.fast" in rows[0]


@pytest.mark.parametrize(
    ("termination_scope", "termination_signal"),
    [
        ("group", signal.SIGTERM),
        ("group", signal.SIGKILL),
        ("collector", signal.SIGKILL),
    ],
    ids=["graceful-group-cancel", "forced-group-kill", "forced-parent-only-kill"],
)
def test_application_metadata_tool_is_reaped_when_collector_is_cancelled(
    project_root, tmp_path, termination_scope, termination_signal
):
    sandbox = tmp_path / "sandbox"
    applications = sandbox / "Applications"
    contents = applications / "Cancelled.app" / "Contents"
    contents.mkdir(parents=True)
    (contents / "Info.plist").write_text("plist", encoding="utf-8")
    child_pid_file = sandbox / "cancelled-child.pid"
    plist_tool = _storage_tool(
        sandbox / "plist-tool",
        f'/bin/sleep 30 &\nprintf "%s" "$!" > "{child_pid_file}"\nwait\n',
    )
    mdls_tool = _storage_tool(sandbox / "mdls-tool", 'printf "1048576\\n"\n')
    facts = sandbox / "facts"
    facts.mkdir()
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(sandbox / "home"),
            "TMP_DIR": str(facts),
            "PCH_TEST_MODE": "1",
            "PCH_TEST_STORAGE_TOOL_ROOT": str(sandbox),
            "PCH_TEST_STORAGE_APPLICATIONS_ROOT": str(applications),
            "PCH_TEST_STORAGE_PLISTBUDDY_BIN": str(plist_tool),
            "PCH_TEST_STORAGE_MDLS_BIN": str(mdls_tool),
            "PCH_STORAGE_APPLICATION_COMMAND_TIMEOUT": "20",
            "PCH_STORAGE_APPLICATION_TOTAL_BUDGET": "20",
        }
    )
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    command = [
        "/bin/bash",
        "-c",
        (
            '. "$1"; seen="|"; '
            "add_sized_path() { :; }; _pch_collect_storage_applications"
        ),
        "bash",
        str(script),
    ]
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        env=env,
        start_new_session=True,
    )
    child_pid = None
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and not child_pid_file.exists():
            time.sleep(0.02)
        assert child_pid_file.exists(), "slow metadata tool did not start"
        child_pid = child_pid_file.read_text(encoding="utf-8")
        if termination_scope == "group":
            os.killpg(process.pid, termination_signal)
        else:
            os.kill(process.pid, termination_signal)
        process.communicate(timeout=3)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            live = subprocess.run(
                ["/bin/ps", "-p", child_pid, "-o", "pid="],
                capture_output=True,
                text=True,
            ).stdout.strip()
            if not live:
                break
            time.sleep(0.05)
        assert not live, "cancelled collector left a metadata-tool child alive"
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        if child_pid:
            subprocess.run(
                ["/bin/kill", "-KILL", child_pid], capture_output=True, text=True
            )


def test_storage_helper_sigkill_closes_guardian_pipe_and_reaps_provider(
    project_root, tmp_path
):
    script = project_root / "scripts/modules/macos/storage.sh"
    provider_child_file = tmp_path / "provider-child.pid"
    helper_pid_file = tmp_path / "helper.pid"
    helper_finished_file = tmp_path / "helper-finished"
    provider = _storage_tool(
        tmp_path / "provider",
        (
            "/bin/sleep 30 &\n"
            "child=$!\n"
            f'printf "%s" "$child" > "{provider_child_file}"\n'
            "wait\n"
        ),
    )
    output = tmp_path / "provider.out"
    harness = r'''
. "$1"
_pch_storage_tool_to_file "$2" 20 "$3" &
helper=$!
/usr/bin/printf '%s' "$helper" > "$4"
wait "$helper" 2>/dev/null || true
: > "$5"
/bin/sleep 30
'''
    process = subprocess.Popen(
        [
            "/bin/bash", "-c", harness, "bash", str(script), str(output),
            str(provider), str(helper_pid_file), str(helper_finished_file),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    provider_child = None
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if helper_pid_file.exists() and provider_child_file.exists():
                break
            time.sleep(0.01)
        assert helper_pid_file.exists(), "bounded storage helper did not start"
        assert provider_child_file.exists(), "provider descendant did not start"
        helper_pid = int(helper_pid_file.read_text(encoding="utf-8"))
        provider_child = int(provider_child_file.read_text(encoding="utf-8"))
        # The provider cannot write its child PID until the guardian has opened
        # the start gate. Capture every real helper descendant at that point so
        # the assertion covers both private process groups without guessing a
        # guardian PID or matching a process command line.
        process_rows = _process_parent_and_state()
        helper_descendants = _descendant_pids(helper_pid, process_rows)
        assert provider_child in helper_descendants
        watched_pids = helper_descendants | {helper_pid}

        os.kill(helper_pid, signal.SIGKILL)
        live_pids = watched_pids
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            current_rows = _process_parent_and_state()
            live_pids = {
                pid
                for pid in watched_pids
                if pid in current_rows and "Z" not in current_rows[pid][1]
            }
            if not live_pids and helper_finished_file.exists():
                break
            time.sleep(0.02)

        assert helper_finished_file.exists(), "caller remained blocked on killed helper"
        assert not live_pids, (
            "killed helper left captured provider/guardian processes alive: "
            f"{sorted(live_pids)}"
        )
        assert process.poll() is None, "top-level collector exited unexpectedly"
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=3)
        if provider_child is not None:
            try:
                os.kill(provider_child, signal.SIGKILL)
            except ProcessLookupError:
                pass


def test_storage_du_budget_is_shared_by_simulators_and_later_paths(
    project_root, tmp_path
):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    home = tmp_path / "home"
    facts = tmp_path / "facts"
    facts.mkdir()
    uuids = [
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333",
    ]
    devices_root = home / "Library" / "Developer" / "CoreSimulator" / "Devices"
    for uuid in uuids:
        (devices_root / uuid).mkdir(parents=True)
    (home / ".npm").mkdir()

    simctl_list = tmp_path / "simctl.txt"
    simctl_list.write_text(
        "-- iOS 27.0 --\n"
        + "".join(
            f"    Budget Phone {index} ({uuid}) (Shutdown)\n"
            for index, uuid in enumerate(uuids, start=1)
        ),
        encoding="utf-8",
    )
    du_trace = tmp_path / "du-trace.tsv"
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "TMP_DIR": str(facts),
            "PCH_TEST_MODE": "1",
            "PCH_TEST_STORAGE_SIMCTL_LIST_FILE": str(simctl_list),
            "PCH_TEST_STORAGE_DU_DURATION_TICKS": "4",
            "PCH_TEST_STORAGE_DU_SIZE_KB": "4096",
            "PCH_TEST_STORAGE_DU_TRACE_FILE": str(du_trace),
            "PCH_STORAGE_DU_TIMEOUT": "5",
            "PCH_STORAGE_TOTAL_DU_BUDGET": "1",
        }
    )

    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            '. "$1"; collect_storage',
            "bash",
            str(script),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    simulator_rows = [
        line.split("\t")
        for line in (facts / "storage_simulators.tsv").read_text(
            encoding="utf-8"
        ).splitlines()
    ]
    assert [row[1] for row in simulator_rows] == uuids
    assert [row[4] for row in simulator_rows] == ["4096", "4096", "0"]
    assert [row[5] for row in simulator_rows] == ["ok", "ok", "timed_out"]

    path_rows = [
        line.split("\t")
        for line in (facts / "storage_paths.tsv").read_text(
            encoding="utf-8"
        ).splitlines()
    ]
    npm_row = next(row for row in path_rows if row[2] == str(home / ".npm"))
    assert npm_row[3:5] == ["0", "timed_out"]

    trace_rows = [
        line.split("\t")
        for line in du_trace.read_text(encoding="utf-8").splitlines()
    ]
    simulator_trace = trace_rows[:3]
    assert [row[0] for row in simulator_trace] == [
        str(devices_root / uuid) for uuid in uuids
    ]
    assert [row[1:] for row in simulator_trace] == [
        ["4", "4", "ok"],
        ["4", "4", "ok"],
        ["4", "2", "timed_out"],
    ]
    assert sum(int(row[2]) for row in trace_rows) == 10
    npm_trace = next(row for row in trace_rows if row[0] == str(home / ".npm"))
    assert npm_trace[1:] == ["4", "0", "timed_out"]


def test_storage_provider_timeouts_keep_partial_ps_and_simctl_evidence(
    project_root, tmp_path
):
    script = project_root / "scripts/modules/macos/storage.sh"
    sandbox = tmp_path / "sandbox"
    home = sandbox / "home"
    facts = sandbox / "facts"
    applications = sandbox / "Applications"
    facts.mkdir(parents=True)
    applications.mkdir()
    sim_child_file = sandbox / "sim-child.pid"
    ps_child_file = sandbox / "ps-child.pid"
    uuid = "11111111-1111-4111-8111-111111111111"
    simctl = _storage_tool(
        sandbox / "simctl-tool",
        (
            "printf '%s\\n' '-- iOS 27.0 --'\n"
            f"printf '%s\\n' '    Partial Phone ({uuid}) (Shutdown)'\n"
            "trap '' TERM\n/bin/sleep 30 &\nchild=$!\n"
            f'printf "%s" "$child" > "{sim_child_file}"\nwait\n'
        ),
    )
    ps_tool = _storage_tool(
        sandbox / "ps-tool",
        (
            "printf '%s\\n' '42 1 00:10 1024 /Applications/Codex.app/Contents/MacOS/Codex'\n"
            "trap '' TERM\n/bin/sleep 30 &\nchild=$!\n"
            f'printf "%s" "$child" > "{ps_child_file}"\nwait\n'
        ),
    )
    env = {
        **os.environ,
        "HOME": str(home),
        "TMP_DIR": str(facts),
        "PCH_TEST_MODE": "1",
        "PCH_TEST_STORAGE_TOOL_ROOT": str(sandbox),
        "PCH_TEST_STORAGE_APPLICATIONS_ROOT": str(applications),
        "PCH_TEST_STORAGE_SIMCTL_BIN": str(simctl),
        "PCH_TEST_STORAGE_PS_BIN": str(ps_tool),
        "PCH_STORAGE_SIMCTL_TIMEOUT": "1",
        "PCH_STORAGE_PS_TIMEOUT": "1",
        "PCH_TEST_STORAGE_DU_DURATION_TICKS": "0",
        "PCH_TEST_STORAGE_DU_TRACE_FILE": str(sandbox / "du-trace.tsv"),
        "PCH_STORAGE_DU_TIMEOUT": "1",
        "PCH_STORAGE_TOTAL_DU_BUDGET": "1",
    }
    harness = (
        'record_collection_status() { printf "%s\\t%s\\t%s\\t%s\\t%s\\n" "$@" >> "$TMP_DIR/status.tsv"; }\n'
        '. "$1"\n'
        'collect_storage\n'
    )

    started = time.monotonic()
    result = subprocess.run(
        ["/bin/bash", "-c", harness, "bash", str(script)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=8,
    )
    elapsed = time.monotonic() - started

    assert result.returncode == 0, result.stderr
    assert elapsed < 5
    statuses = {
        row.split("\t")[0]: row.split("\t")
        for row in (facts / "status.tsv").read_text(encoding="utf-8").splitlines()
    }
    assert statuses["storage_simulators"][2] == "timed_out"
    assert statuses["runtime_processes"][2] == "timed_out"
    assert "일부" in statuses["storage_simulators"][4]
    assert "일부" in statuses["runtime_processes"][4]
    simulator_rows = (facts / "storage_simulators.tsv").read_text(encoding="utf-8")
    assert uuid in simulator_rows
    runtime_rows = (facts / "storage_runtime.tsv").read_text(encoding="utf-8")
    assert "Codex processes\t1\t" in runtime_rows

    for pid_file in (sim_child_file, ps_child_file):
        child_pid = int(pid_file.read_text(encoding="utf-8"))
        for _ in range(50):
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            raise AssertionError(f"provider deadline left descendant {child_pid} running")


def test_storage_provider_success_does_not_leave_background_descendant(
    project_root, tmp_path
):
    script = project_root / "scripts/modules/macos/storage.sh"
    child_pid_file = tmp_path / "child.pid"
    provider = _storage_tool(
        tmp_path / "provider",
        (
            "printf 'collected\\n'\n"
            "/bin/sleep 30 &\n"
            "child=$!\n"
            f'printf "%s" "$child" > "{child_pid_file}"\n'
            "exit 0\n"
        ),
    )
    output = tmp_path / "provider.out"
    harness = (
        '. "$1"\n'
        '_pch_storage_tool_to_file "$2" 2 "$3"\n'
        'printf "status=%s\\n" "$?"\n'
    )
    child_pid = None

    try:
        started = time.monotonic()
        result = subprocess.run(
            ["/bin/bash", "-c", harness, "bash", str(script), str(output), str(provider)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=5,
        )
        elapsed = time.monotonic() - started

        assert result.returncode == 0, result.stderr
        assert result.stdout == "status=0\n"
        assert elapsed < 3
        assert output.read_text(encoding="utf-8") == "collected\n"
        child_pid = int(child_pid_file.read_text(encoding="utf-8"))
        for _ in range(50):
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            raise AssertionError(
                f"successful provider left descendant {child_pid} running"
            )
    finally:
        if child_pid is not None:
            try:
                os.kill(child_pid, 9)
            except ProcessLookupError:
                pass


@pytest.mark.skipif(sys.platform != "darwin", reason="JXA scanner helper is macOS-only")
def test_jxa_recipe_less_ai_cache_surfaces_in_developer_toolchains_only(
    project_root, tmp_path
):
    """A large ai_cache row with no cleanupId (e.g. an Ollama model blob) must be
    visible somewhere in the app — but never enter cleanupCandidates, since no
    delete recipe exists for it."""
    if not shutil.which("osascript"):
        pytest.skip("osascript is unavailable")

    temp = tmp_path / "facts"
    temp.mkdir()
    (temp / "storage_df.txt").write_text(
        "/dev/disk 104857600 52428800 52428800 50% /\n", encoding="utf-8"
    )
    for name in (
        "net.txt", "listen.txt", "plists.txt", "security.txt", "load.txt",
        "storage_access.tsv", "storage_runtime.tsv", "storage_simulators.tsv",
    ):
        (temp / name).write_text("", encoding="utf-8")
    (temp / "storage_paths.tsv").write_text(
        "ai_cache\tOllama model blobs\t/Users/test/.ollama/models\t11534336\tok\t\t\n"
        "protected_history\tOllama SSH private key\t/Users/test/.ollama/id_ed25519\t4\tok\t\t\n",
        encoding="utf-8",
    )
    (temp / "ps.txt").write_text("999999 test 0.0 0.0 1024 /bin/bash\n", encoding="utf-8")
    output = tmp_path / "scan.json"
    raw = tmp_path / "raw.json"
    rules = tmp_path / "rules"
    rules.mkdir()
    env = os.environ.copy()
    env.update({
        "TMP_DIR": str(temp),
        "PCH_OUTPUT": str(output),
        "PCH_RAW_PATH": str(raw),
        "PCH_RULES_DIR": str(rules),
        "PCH_CONFIG_PATH": str(tmp_path / "config.json"),
        "PCH_WHITELIST_PATH": str(tmp_path / "whitelist.json"),
        "PCH_SIMULATOR_KEEP_PATH": str(tmp_path / "simulator-keep.txt"),
        "PCH_NO_VT": "true",
    })
    (tmp_path / "simulator-keep.txt").write_text("", encoding="utf-8")

    result = subprocess.run(
        ["osascript", "-l", "JavaScript", str(project_root / "scripts" / "scanner_helper.jxa.js")],
        capture_output=True, text=True, encoding="utf-8", env=env, timeout=30,
    )
    assert result.returncode == 0, result.stderr
    storage = json.loads(output.read_text(encoding="utf-8"))["sections"]["storage"]

    dev_labels = [item["label"] for item in storage["developerToolchains"]]
    assert "Ollama model blobs" in dev_labels
    cleanup_labels = [item["label"] for item in storage["cleanupCandidates"]]
    assert "Ollama model blobs" not in cleanup_labels  # no cleanupId → never a delete button
    review_labels = [item["label"] for item in storage["reviewCandidates"]]
    assert "Ollama SSH private key" in review_labels
    assert "Ollama model blobs" not in review_labels


@pytest.mark.skipif(sys.platform != "darwin", reason="JXA scanner helper is macOS-only")
def test_jxa_uses_uuid_keep_key_and_excludes_manual_paths_from_cleanup_total(
    project_root, tmp_path
):
    if not shutil.which("osascript"):
        pytest.skip("osascript is unavailable")

    temp = tmp_path / "facts"
    temp.mkdir()
    uuid = "5800AF4B-90D7-4F28-A8EC-80C8E2AE4B75"
    (temp / "storage_df.txt").write_text(
        "/dev/disk 104857600 52428800 52428800 50% /\n", encoding="utf-8"
    )
    (temp / "storage_simulators.tsv").write_text(
        f"Renamed QA Phone\t{uuid.lower()}\tiOS 27\tShutdown\t1048576\tok\n",
        encoding="utf-8",
    )
    (temp / "storage_paths.tsv").write_text(
        "temp\tManual temporary path\t/private/tmp\t3145728\tok\t\t\n"
        "cache\tExecutable cache\t/Users/test/cache\t3145728\tok\t\tcache_recipe\n"
        "cache\tSmall allowlisted cache\t/Users/test/small-cache\t1024\tok\t\tcleanup_small\n"
        "project_residue\tnode_modules · web\t/Users/test/web/node_modules"
        "\t5120\tok\t재생성 가능\tproject_residue\n",
        encoding="utf-8",
    )
    executable_with_spaces = (
        "/tmp/Modore.app/Contents/MacOS/Modore"
    )
    (temp / "ps.txt").write_text(
        f"999999 test 12.5 1.0 1024 {executable_with_spaces}\n",
        encoding="utf-8",
    )
    for name in (
        "net.txt",
        "listen.txt",
        "plists.txt",
        "security.txt",
        "load.txt",
        "storage_access.tsv",
        "storage_runtime.tsv",
    ):
        (temp / name).write_text("", encoding="utf-8")

    keep = tmp_path / "simulator-keep.txt"
    keep.write_text(f"{uuid}\n", encoding="utf-8")
    output = tmp_path / "scan.json"
    raw = tmp_path / "raw.json"
    rules = tmp_path / "rules"
    rules.mkdir()
    env = os.environ.copy()
    env.update(
        {
            "TMP_DIR": str(temp),
            "PCH_OUTPUT": str(output),
            "PCH_RAW_PATH": str(raw),
            "PCH_RULES_DIR": str(rules),
            "PCH_CONFIG_PATH": str(tmp_path / "config.json"),
            "PCH_WHITELIST_PATH": str(tmp_path / "whitelist.json"),
            "PCH_SIMULATOR_KEEP_PATH": str(keep),
            "PCH_NO_VT": "true",
        }
    )

    result = subprocess.run(
        [
            "osascript",
            "-l",
            "JavaScript",
            str(project_root / "scripts" / "scanner_helper.jxa.js"),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    scan = json.loads(output.read_text(encoding="utf-8"))
    simulator = scan["sections"]["storage"]["simulatorDevices"][0]
    assert simulator["uuid"] == uuid
    assert simulator["protected"] is True
    assert simulator["protectionReason"] == "사용자 보존 목록"
    cleanup = scan["sections"]["storage"]["cleanupCandidates"]
    assert [item["cleanupId"] for item in cleanup] == ["cache_recipe"]
    recovery = scan["sections"]["storage"]["recoveryCandidates"]
    assert {item["cleanupId"] for item in recovery} == {
        "cache_recipe",
        "cleanup_small",
        "project_residue",
    }
    raw_facts = json.loads(raw.read_text(encoding="utf-8"))
    assert raw_facts["sections"]["cpu"][0]["path"] == executable_with_spaces
    assert raw_facts["sections"]["cpu"][0]["name"] == "Modore"


@pytest.mark.skipif(sys.platform != "darwin", reason="JXA scanner helper is macOS-only")
def test_jxa_fixture_preserves_collection_and_browser_automation_contract(
    project_root, tmp_path
):
    if not shutil.which("osascript"):
        pytest.skip("osascript is unavailable")

    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "collection_status.tsv").write_text(
        "storage_volume\t시동 볼륨\tok\ttrue\t볼륨을 확인했습니다.\n"
        "security_privacy\t보안 개인정보 영역\tpermission_denied\ttrue\t권한이 없습니다.\n"
        "storage_inventory\t저장공간 경로 측정\ttimed_out\tfalse\t일부 측정이 지연됐습니다.\n",
        encoding="utf-8",
    )
    (facts / "storage_df.txt").write_text(
        "/dev/disk 104857600 52428800 52428800 50% /\n",
        encoding="utf-8",
    )
    (facts / "storage_paths.tsv").write_text(
        "cache\tPlaywright browser cache\t/Users/test/Library/Caches/ms-playwright"
        "\t0\ttimed_out\t시간 제한으로 측정을 보류했습니다.\tplaywright_browsers\n",
        encoding="utf-8",
    )
    (facts / "storage_runtime.tsv").write_text(
        "browser_automation_root\t잔류 후보 시스템 Chrome 자동화\t1\twarning"
        "\t소유 작업 재확인 후 종료 검토\t상위 작업을 확인할 수 없습니다."
        "\t4242\t1\t02:10:00\tsystem\torphan_candidate\ttemporary\tCodex"
        "\t262144\t393216\t2\n",
        encoding="utf-8",
    )
    (facts / "storage_access.tsv").write_text(
        "privacy_area\tMessages data\t/Users/test/Library/Messages"
        "\tblocked\tOperation not permitted\n",
        encoding="utf-8",
    )
    for name in (
        "ps.txt",
        "net.txt",
        "listen.txt",
        "plists.txt",
        "security.txt",
        "load.txt",
        "storage_simulators.tsv",
    ):
        (facts / name).write_text("", encoding="utf-8")

    output = tmp_path / "scan.json"
    raw = tmp_path / "raw.json"
    # Real rules/whitelist, not an empty stand-in: this test exercises the
    # storage/browser-automation TSV passthrough contract, not rule loading.
    # An empty rules dir and a never-written whitelist.json now (correctly)
    # surface as 6 additional required-and-failed collection issues of their
    # own, which would swamp the two this test actually asserts on.
    keep = tmp_path / "simulator-keep.txt"
    keep.write_text("", encoding="utf-8")
    env = os.environ.copy()
    env.update(
        {
            "TMP_DIR": str(facts),
            "PCH_OUTPUT": str(output),
            "PCH_RAW_PATH": str(raw),
            "PCH_RULES_DIR": str(project_root / "rules"),
            "PCH_CONFIG_PATH": str(tmp_path / "config.json"),
            "PCH_WHITELIST_PATH": str(project_root / "data" / "whitelist.json"),
            "PCH_SIMULATOR_KEEP_PATH": str(keep),
            "PCH_NO_VT": "true",
        }
    )

    result = subprocess.run(
        [
            "osascript",
            "-l",
            "JavaScript",
            str(project_root / "scripts" / "scanner_helper.jxa.js"),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    scan = json.loads(output.read_text(encoding="utf-8"))
    assert scan["summary"]["collectionComplete"] is False
    assert scan["collection"]["status"] == "incomplete"
    assert scan["collection"]["requiredCount"] == 2
    assert [issue["status"] for issue in scan["collection"]["issues"]] == [
        "permission_denied",
        "timed_out",
    ]

    storage = scan["sections"]["storage"]
    browser = storage["browserAutomation"]
    assert browser["verdict"] == "orphaned"
    assert browser["systemRootCount"] == 1
    assert browser["orphanedRootCount"] == 1
    assert browser["rootMemoryKB"] == 262144
    assert browser["treeMemoryKB"] == 393216
    root = storage["runtimeSignals"][0]
    assert root["pid"] == 4242
    assert root["parentPid"] == 1
    assert root["elapsed"] == "02:10:00"
    assert root["channel"] == "system"
    assert root["state"] == "orphan_candidate"
    assert root["controller"] == "Codex"
    assert root["memoryKB"] == 262144
    assert root["treeMemoryKB"] == 393216
    assert root["treeProcessCount"] == 2
    assert "command" not in root
    candidate = storage["cleanupCandidates"][0]
    assert candidate["cleanupId"] == "playwright_browsers"
    assert candidate["measureStatus"] == "timed_out"


def test_jxa_storage_notes_distinguish_session_records_from_workspaces(
    project_root, tmp_path
):
    if not shutil.which("osascript"):
        pytest.skip("osascript is unavailable")

    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "collection_status.tsv").write_text(
        "storage_volume\t시동 볼륨\tok\ttrue\t볼륨을 확인했습니다.\n",
        encoding="utf-8",
    )
    (facts / "storage_df.txt").write_text(
        "/dev/disk 104857600 52428800 52428800 50% /\n",
        encoding="utf-8",
    )
    (facts / "storage_paths.tsv").write_text(
        "protected_history\tClaude Code project sessions\t/Users/test/.claude/projects"
        "\t1048576\tok\t\t\n"
        "protected_history\tClaude local agent workspaces"
        "\t/Users/test/Library/Application Support/Claude/local-agent-mode-sessions"
        "\t1048576\tok\t\t\n"
        "ai_review\tCodex internal state databases\t/Users/test/.codex/sqlite"
        "\t1048576\tok\t\t\n"
        "ai_review\tCodex internal event log DB\t/Users/test/.codex/logs_2.sqlite"
        "\t1048576\tok\t\t\n",
        encoding="utf-8",
    )
    for name in (
        "ps.txt",
        "net.txt",
        "listen.txt",
        "plists.txt",
        "security.txt",
        "load.txt",
        "storage_simulators.tsv",
        "storage_runtime.tsv",
        "storage_access.tsv",
    ):
        (facts / name).write_text("", encoding="utf-8")

    output = tmp_path / "scan.json"
    raw = tmp_path / "raw.json"
    rules = tmp_path / "rules"
    rules.mkdir()
    keep = tmp_path / "simulator-keep.txt"
    keep.write_text("", encoding="utf-8")
    env = os.environ.copy()
    env.update(
        {
            "TMP_DIR": str(facts),
            "PCH_OUTPUT": str(output),
            "PCH_RAW_PATH": str(raw),
            "PCH_RULES_DIR": str(rules),
            "PCH_CONFIG_PATH": str(tmp_path / "config.json"),
            "PCH_WHITELIST_PATH": str(tmp_path / "whitelist.json"),
            "PCH_SIMULATOR_KEEP_PATH": str(keep),
            "PCH_NO_VT": "true",
        }
    )

    result = subprocess.run(
        [
            "osascript",
            "-l",
            "JavaScript",
            str(project_root / "scripts" / "scanner_helper.jxa.js"),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    scan = json.loads(output.read_text(encoding="utf-8"))
    notes = {
        item["label"]: item["note"]
        for item in scan["sections"]["storage"]["reviewCandidates"]
    }

    # 세션 기록은 세션 기록으로, 작업공간은 작업공간으로 설명해야 한다.
    assert "세션 기록" in notes["Claude Code project sessions"]
    assert "작업공간" not in notes["Claude Code project sessions"]
    assert "작업공간" in notes["Claude local agent workspaces"]

    # Codex 상태 DB는 이벤트 로그 DB 설명을 물려받으면 안 된다.
    assert "상태" in notes["Codex internal state databases"]
    assert "이벤트" not in notes["Codex internal state databases"]
    assert "이벤트" in notes["Codex internal event log DB"]


def test_browser_runtime_elapsed_time_is_parsed_as_decimal(project_root):
    script = project_root / "scripts/modules/macos/storage.sh"
    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            '. "$1"; _pch_elapsed_seconds "01-08:19:14"',
            "bash",
            str(script),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=5,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == "116354"


def test_project_residue_scan_surfaces_rebuildable_artifacts(project_root, tmp_path):
    """개발 프로젝트 내부의 재생성 가능한 빌드 산출물(gitignore 사각지대)을
    project_residue 행으로 표면화한다. 4MB 미만은 노이즈로 생략하고, 경로와 분리된
    고정 cleanup_id를 제공한다(실제 경로는 bounded FD 요청서로만 전달)."""
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    home = tmp_path / "home"
    facts = tmp_path / "facts"
    facts.mkdir()
    scan_root = home / "Documents"

    flutter = scan_root / "Fylish"
    (flutter / "build").mkdir(parents=True)
    (flutter / "build" / "app.blob").write_bytes(b"x" * (5 * 1024 * 1024))
    (flutter / ".dart_tool").mkdir()
    (flutter / ".dart_tool" / "pkg").write_bytes(b"y" * (5 * 1024 * 1024))
    (flutter / "pubspec.yaml").write_text("name: fylish\n", encoding="utf-8")

    node = scan_root / "webapp"
    (node / "node_modules").mkdir(parents=True)
    (node / "node_modules" / "dep.js").write_bytes(b"z" * (5 * 1024 * 1024))
    (node / "package.json").write_text("{}", encoding="utf-8")

    tiny = scan_root / "tiny"
    (tiny / "node_modules").mkdir(parents=True)
    (tiny / "node_modules" / "s.js").write_bytes(b"s" * 1024)
    (tiny / "package.json").write_text("{}", encoding="utf-8")

    simctl_list = tmp_path / "simctl.txt"
    simctl_list.write_text("", encoding="utf-8")
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "TMP_DIR": str(facts),
            "PCH_TEST_MODE": "1",
            "PCH_TEST_STORAGE_SIMCTL_LIST_FILE": str(simctl_list),
            "PCH_PROJECT_SCAN_ROOTS": str(scan_root),
            "PCH_STORAGE_DU_TIMEOUT": "5",
            "PCH_STORAGE_TOTAL_DU_BUDGET": "30",
        }
    )

    result = subprocess.run(
        ["/bin/bash", "-c", '. "$1"; collect_storage', "bash", str(script)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=60,
    )

    assert result.returncode == 0, result.stderr
    rows = [
        line.split("\t")
        for line in (facts / "storage_paths.tsv").read_text(encoding="utf-8").splitlines()
    ]
    residue = [row for row in rows if row[0] == "project_residue"]
    by_path = {row[2]: row for row in residue}

    flutter_build = by_path[str(flutter / "build")]
    assert "Flutter" in flutter_build[1] and "Fylish" in flutter_build[1]
    assert int(flutter_build[3]) >= 5 * 1024  # KB
    assert flutter_build[4] == "ok"
    assert "flutter clean" in flutter_build[5]
    assert flutter_build[6] == "project_residue"

    assert str(flutter / ".dart_tool") in by_path
    node_row = by_path[str(node / "node_modules")]
    assert "webapp" in node_row[1]
    assert "npm install" in node_row[5]
    assert all(row[6] == "project_residue" for row in residue)

    # 4MB 플로어: tiny 프로젝트는 생략
    assert str(tiny / "node_modules") not in by_path


def test_project_residue_scan_follows_git_index_to_nested_swift_packages(
    project_root, tmp_path
):
    """얕은 루트 검색으로 Git repo만 찾은 뒤에는 tracked Package.swift를 따라
    모노레포 안쪽의 .build를 찾는다. cleanup 계약의 marker는 각 .build 바로 위의
    Package.swift여야 하므로 저장소 루트의 marker로 뭉개지 않는다."""
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    home = tmp_path / "home"
    facts = tmp_path / "facts"
    facts.mkdir()
    scan_root = home / "IdeaProjects"
    repo = scan_root / "APP" / "monorepo"
    repo.mkdir(parents=True)

    package_dirs = [
        repo / "macos" / "Modore",
        repo / "shared" / "ModoreDomain",
        repo / "vendor" / "mothball",
    ]
    for package_dir in package_dirs:
        package_dir.mkdir(parents=True)
        (package_dir / "Package.swift").write_text(
            "// swift-tools-version: 6.0\n", encoding="utf-8"
        )
        (package_dir / ".build").mkdir()
        (package_dir / ".build" / "artifact.bin").write_bytes(
            b"x" * (5 * 1024 * 1024)
        )

    subprocess.run(["/usr/bin/git", "init", "-q", str(repo)], check=True)
    subprocess.run(
        [
            "/usr/bin/git",
            "-C",
            str(repo),
            "add",
            *[str(path.relative_to(repo) / "Package.swift") for path in package_dirs],
        ],
        check=True,
    )

    simctl_list = tmp_path / "simctl.txt"
    simctl_list.write_text("", encoding="utf-8")
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "TMP_DIR": str(facts),
            "PCH_TEST_MODE": "1",
            "PCH_TEST_STORAGE_SIMCTL_LIST_FILE": str(simctl_list),
            "PCH_PROJECT_SCAN_ROOTS": str(scan_root),
            # 기존 일반 project 32개 예산과 Git lineage 예산이 분리됐음을 고정한다.
            "PCH_PROJECT_SCAN_LIMIT": "1",
            "PCH_STORAGE_DU_TIMEOUT": "5",
            "PCH_STORAGE_TOTAL_DU_BUDGET": "30",
        }
    )

    result = subprocess.run(
        ["/bin/bash", "-c", '. "$1"; collect_storage', "bash", str(script)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=60,
    )

    assert result.returncode == 0, result.stderr
    rows = [
        line.split("\t")
        for line in (facts / "storage_paths.tsv").read_text(
            encoding="utf-8"
        ).splitlines()
    ]
    residue_by_path = {
        row[2]: row for row in rows if row[0] == "project_residue"
    }
    expected = {str(package_dir / ".build") for package_dir in package_dirs}
    assert expected <= residue_by_path.keys()
    for package_dir in package_dirs:
        row = residue_by_path[str(package_dir / ".build")]
        assert (Path(row[2]).parent / "Package.swift") == package_dir / "Package.swift"
        assert (Path(row[2]).parent / "Package.swift").is_file()
        assert package_dir.name in row[1]
        assert "바로 위 Package.swift" in row[5]
        assert row[6] == "project_residue"


def _run_project_residue_only(
    script: Path, env: dict[str, str]
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "/bin/bash",
            "-c",
            (
                '. "$1"; seen="|"; DU_SIZE_RESULT=5120; '
                'du_size_kb() { DU_SIZE_RESULT=5120; }; '
                "record_collection_status() { "
                "printf '%s\\t%s\\t%s\\n' \"$1\" \"$3\" \"$5\" "
                '> "$TMP_DIR/project_status.tsv"; }; '
                "_pch_collect_project_residue"
            ),
            "bash",
            str(script),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        timeout=8,
    )


def _make_nested_swift_repo(
    scan_root: Path, names: list[str]
) -> tuple[Path, list[Path]]:
    repo = scan_root / "monorepo"
    repo.mkdir(parents=True)
    packages = []
    for name in names:
        package = repo / "packages" / name
        package.mkdir(parents=True)
        (package / "Package.swift").write_text(
            "// swift-tools-version: 6.0\n", encoding="utf-8"
        )
        packages.append(package)
    subprocess.run(["/usr/bin/git", "init", "-q", str(repo)], check=True)
    subprocess.run(
        [
            "/usr/bin/git",
            "-C",
            str(repo),
            "add",
            *[str(package.relative_to(repo) / "Package.swift") for package in packages],
        ],
        check=True,
    )
    return repo, packages


def _project_git_test_env(
    tmp_path: Path, scan_root: Path, facts: Path, trace: Path
) -> dict[str, str]:
    env = os.environ.copy()
    env.pop("PCH_PROJECT_DIR", None)
    env.update(
        {
            "HOME": str(tmp_path / "home"),
            "TMP_DIR": str(facts),
            "PCH_TEST_MODE": "1",
            "PCH_PROJECT_SCAN_ROOTS": str(scan_root),
            "PCH_TEST_PROJECT_GIT_TRACE_FILE": str(trace),
            "PCH_PROJECT_GIT_COMMAND_TIMEOUT": "1",
            "PCH_PROJECT_GIT_TOTAL_BUDGET": "5",
        }
    )
    return env


@pytest.mark.parametrize("stalled_operation", ["rev-parse", "ls-files"])
def test_project_git_commands_have_individual_timeout(
    project_root, tmp_path, stalled_operation
):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "storage_paths.tsv").write_text("", encoding="utf-8")
    scan_root = tmp_path / "scan"
    _, packages = _make_nested_swift_repo(scan_root, ["deep-package"])
    (packages[0] / ".build").mkdir()
    trace = tmp_path / "git-trace.tsv"
    env = _project_git_test_env(tmp_path, scan_root, facts, trace)
    env.update(
        {
            "PCH_TEST_PROJECT_GIT_STALL_OPERATION": stalled_operation,
            "PCH_TEST_PROJECT_GIT_STALL_SECONDS": "6",
        }
    )

    started = time.monotonic()
    result = _run_project_residue_only(script, env)
    elapsed = time.monotonic() - started

    assert result.returncode == 0, result.stderr
    assert elapsed < 3
    trace_rows = [line.split("\t") for line in trace.read_text().splitlines()]
    stalled_row = next(row for row in trace_rows if row[0] == stalled_operation)
    assert stalled_row[1] == "command_timeout"
    assert list(facts.glob("project_git_*.out")) == []
    status = (facts / "project_status.tsv").read_text().split("\t")
    assert status[0:2] == ["project_residue", "timed_out"]


def test_project_git_commands_share_total_timeout(project_root, tmp_path):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "storage_paths.tsv").write_text("", encoding="utf-8")
    scan_root = tmp_path / "scan"
    _make_nested_swift_repo(scan_root, ["deep-package"])
    trace = tmp_path / "git-trace.tsv"
    env = _project_git_test_env(tmp_path, scan_root, facts, trace)
    env.update(
        {
            "PCH_PROJECT_GIT_COMMAND_TIMEOUT": "5",
            "PCH_PROJECT_GIT_TOTAL_BUDGET": "1",
            "PCH_TEST_PROJECT_GIT_STALL_OPERATION": "rev-parse",
            "PCH_TEST_PROJECT_GIT_STALL_SECONDS": "6",
        }
    )

    started = time.monotonic()
    result = _run_project_residue_only(script, env)
    elapsed = time.monotonic() - started

    assert result.returncode == 0, result.stderr
    assert elapsed < 3
    trace_rows = [line.split("\t") for line in trace.read_text().splitlines()]
    assert trace_rows[0][0:2] == ["rev-parse", "total_budget"]
    status = (facts / "project_status.tsv").read_text().split("\t")
    assert status[0:2] == ["project_residue", "timed_out"]


def test_project_git_corrupt_index_fails_closed_without_blocking(project_root, tmp_path):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "storage_paths.tsv").write_text("", encoding="utf-8")
    scan_root = tmp_path / "scan"
    repo, packages = _make_nested_swift_repo(scan_root, ["deep-package"])
    (packages[0] / ".build").mkdir()
    (repo / ".git" / "index").write_bytes(b"not a git index")
    trace = tmp_path / "git-trace.tsv"
    env = _project_git_test_env(tmp_path, scan_root, facts, trace)

    result = _run_project_residue_only(script, env)

    assert result.returncode == 0, result.stderr
    trace_rows = [line.split("\t") for line in trace.read_text().splitlines()]
    assert [row[0:2] for row in trace_rows] == [
        ["rev-parse", "ok"],
        ["ls-files", "failed"],
    ]
    assert (facts / "storage_paths.tsv").read_text(encoding="utf-8") == ""
    status = (facts / "project_status.tsv").read_text().split("\t")
    assert status[0:2] == ["project_residue", "failed"]
    assert "불완전" in status[2]


def test_project_git_manifest_output_is_size_bounded(project_root, tmp_path):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "storage_paths.tsv").write_text("", encoding="utf-8")
    scan_root = tmp_path / "scan"
    names = [f"package-{index:03d}-with-a-long-name" for index in range(120)]
    _, packages = _make_nested_swift_repo(scan_root, names)
    (packages[-1] / ".build").mkdir()
    trace = tmp_path / "git-trace.tsv"
    env = _project_git_test_env(tmp_path, scan_root, facts, trace)
    env["PCH_PROJECT_GIT_OUTPUT_LIMIT_KB"] = "1"

    result = _run_project_residue_only(script, env)

    assert result.returncode == 0, result.stderr
    trace_rows = [line.split("\t") for line in trace.read_text().splitlines()]
    assert [row[0:2] for row in trace_rows] == [
        ["rev-parse", "ok"],
        ["ls-files", "output_limit"],
    ]
    assert (facts / "storage_paths.tsv").read_text(encoding="utf-8") == ""
    assert list(facts.glob("project_git_*.out")) == []
    status = (facts / "project_status.tsv").read_text().split("\t")
    assert status[0:2] == ["project_residue", "failed"]
    assert "출력 상한" in status[2]


def test_project_git_manifest_output_is_record_bounded(project_root, tmp_path):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "storage_paths.tsv").write_text("", encoding="utf-8")
    scan_root = tmp_path / "scan"
    names = [f"package-{index:03d}" for index in range(12)]
    _, packages = _make_nested_swift_repo(scan_root, names)
    (packages[-1] / ".build").mkdir()
    trace = tmp_path / "git-trace.tsv"
    env = _project_git_test_env(tmp_path, scan_root, facts, trace)
    env.update(
        {
            "PCH_PROJECT_GIT_OUTPUT_LIMIT_KB": "64",
            "PCH_PROJECT_GIT_RECORD_LIMIT": "5",
        }
    )

    result = _run_project_residue_only(script, env)

    assert result.returncode == 0, result.stderr
    trace_rows = [line.split("\t") for line in trace.read_text().splitlines()]
    assert [row[0:2] for row in trace_rows] == [
        ["rev-parse", "ok"],
        ["ls-files", "record_limit"],
    ]
    assert (facts / "storage_paths.tsv").read_text(encoding="utf-8") == ""
    assert list(facts.glob("project_git_*.out*")) == []
    status = (facts / "project_status.tsv").read_text().split("\t")
    assert status[0:2] == ["project_residue", "failed"]
    assert "출력 상한" in status[2]


def test_project_git_scan_disables_repo_fsmonitor_execution(project_root, tmp_path):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "storage_paths.tsv").write_text("", encoding="utf-8")
    scan_root = tmp_path / "scan"
    repo, packages = _make_nested_swift_repo(scan_root, ["deep-package"])
    (packages[0] / ".build").mkdir()

    marker = tmp_path / "fsmonitor-ran"
    pid_file = tmp_path / "fsmonitor.pid"
    hook = tmp_path / "fsmonitor-hook.sh"
    hook.write_text(
        "#!/bin/sh\n"
        'printf "%s\\n" "$$" > "$PCH_TEST_FSMONITOR_PID_FILE"\n'
        ': > "$PCH_TEST_FSMONITOR_MARKER"\n'
        "/bin/sleep 6\n",
        encoding="utf-8",
    )
    hook.chmod(0o755)
    subprocess.run(
        [
            "/usr/bin/git",
            "-C",
            str(repo),
            "config",
            "core.fsmonitor",
            str(hook),
        ],
        check=True,
    )

    trace = tmp_path / "git-trace.tsv"
    env = _project_git_test_env(tmp_path, scan_root, facts, trace)
    env.update(
        {
            "PCH_TEST_FSMONITOR_MARKER": str(marker),
            "PCH_TEST_FSMONITOR_PID_FILE": str(pid_file),
        }
    )
    started = time.monotonic()
    result = _run_project_residue_only(script, env)
    elapsed = time.monotonic() - started

    hook_survived = False
    hook_pid = 0
    if pid_file.exists():
        try:
            hook_pid = int(pid_file.read_text().strip())
            os.kill(hook_pid, 0)
            hook_survived = True
        except (OSError, ValueError):
            pass
        finally:
            if hook_pid > 1:
                try:
                    os.kill(hook_pid, 9)
                except OSError:
                    pass

    assert result.returncode == 0, result.stderr
    assert elapsed < 3
    assert not marker.exists(), "repo-local core.fsmonitor hook was executed"
    assert not hook_survived, "fsmonitor hook survived the bounded Git command"
    trace_rows = [line.split("\t") for line in trace.read_text().splitlines()]
    assert [row[0:2] for row in trace_rows] == [
        ["rev-parse", "ok"],
        ["ls-files", "ok"],
    ]
    rows = [
        line.split("\t")
        for line in (facts / "storage_paths.tsv").read_text(
            encoding="utf-8"
        ).splitlines()
    ]
    assert str(packages[0] / ".build") in {
        row[2] for row in rows if row[0] == "project_residue"
    }


def test_project_discovery_timeout_bounds_large_unmatched_tree(project_root, tmp_path):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "storage_paths.tsv").write_text("", encoding="utf-8")
    scan_root = tmp_path / "scan"
    for group_index in range(32):
        group = scan_root / f"unmatched-{group_index:02d}"
        group.mkdir(parents=True)
        for file_index in range(64):
            (group / f"source-{file_index:02d}.txt").write_text(
                "not a project marker\n", encoding="utf-8"
            )

    trace = tmp_path / "git-trace.tsv"
    env = _project_git_test_env(tmp_path, scan_root, facts, trace)
    env.update(
        {
            "PCH_PROJECT_DISCOVERY_TIMEOUT": "1",
            # 많은 unmatched entry를 stat하는 느린 파일시스템을 재현한다.
            "PCH_TEST_PROJECT_DISCOVERY_STALL_SECONDS": "6",
        }
    )

    started = time.monotonic()
    result = _run_project_residue_only(script, env)
    elapsed = time.monotonic() - started

    assert result.returncode == 0, result.stderr
    assert elapsed < 3
    assert (facts / "storage_paths.tsv").read_text(encoding="utf-8") == ""
    assert list(facts.glob("project_discovery_*.out*")) == []
    status = (facts / "project_status.tsv").read_text().split("\t")
    assert status[0:2] == ["project_residue", "timed_out"]
    assert "시간·결과 예산" in status[2]


def test_project_discovery_result_limit_is_reported_as_incomplete(
    project_root, tmp_path
):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "storage_paths.tsv").write_text("", encoding="utf-8")
    scan_root = tmp_path / "scan"
    projects = []
    for index in range(5):
        project = scan_root / f"web-{index}"
        (project / "node_modules").mkdir(parents=True)
        (project / "package.json").write_text("{}\n", encoding="utf-8")
        projects.append(project)

    trace = tmp_path / "git-trace.tsv"
    env = _project_git_test_env(tmp_path, scan_root, facts, trace)
    env["PCH_PROJECT_DISCOVERY_RESULT_LIMIT"] = "2"

    result = _run_project_residue_only(script, env)

    assert result.returncode == 0, result.stderr
    rows = [
        line.split("\t")
        for line in (facts / "storage_paths.tsv").read_text(
            encoding="utf-8"
        ).splitlines()
    ]
    residue_paths = {row[2] for row in rows if row[0] == "project_residue"}
    expected_paths = {str(project / "node_modules") for project in projects}
    assert len(residue_paths) == 2
    assert residue_paths <= expected_paths
    assert list(facts.glob("project_discovery_*.out*")) == []
    status = (facts / "project_status.tsv").read_text().split("\t")
    assert status[0:2] == ["project_residue", "timed_out"]
    assert "시간·결과 예산" in status[2]


def test_swiftpm_residue_limit_counts_only_real_build_directories(
    project_root, tmp_path
):
    script = project_root / "scripts" / "modules" / "macos" / "storage.sh"
    facts = tmp_path / "facts"
    facts.mkdir()
    (facts / "storage_paths.tsv").write_text("", encoding="utf-8")
    scan_root = tmp_path / "scan"
    _, packages = _make_nested_swift_repo(
        scan_root, ["a-no-build", "b-no-build", "c-symlink-build", "z-real-build"]
    )
    symlink_target = tmp_path / "shared-build"
    symlink_target.mkdir()
    (packages[2] / ".build").symlink_to(symlink_target, target_is_directory=True)
    (packages[3] / ".build").mkdir()
    trace = tmp_path / "git-trace.tsv"
    env = _project_git_test_env(tmp_path, scan_root, facts, trace)
    # 예산이 1이어도 앞의 manifest 세 개는 소모하지 않고 뒤의 실제
    # non-symlink .build가 있는 패키지까지 도달해야 한다.
    env["PCH_PROJECT_SWIFTPM_MANIFEST_LIMIT"] = "1"

    result = _run_project_residue_only(script, env)

    assert result.returncode == 0, result.stderr
    rows = [
        line.split("\t")
        for line in (facts / "storage_paths.tsv").read_text(
            encoding="utf-8"
        ).splitlines()
    ]
    residue_paths = [row[2] for row in rows if row[0] == "project_residue"]
    assert residue_paths == [str(packages[3] / ".build")]
