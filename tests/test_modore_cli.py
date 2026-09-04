import json
import os
import subprocess
import sys
import time

import pytest


def run_cli(project_root, *args, stdin=None, extra_env=None):
    env = {**os.environ, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    env.update(extra_env or {})
    return subprocess.run(
        [str(project_root / "bin" / "modore"), *args],
        input=stdin,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=10,
        env=env,
    )


def test_help_exposes_only_modore_owned_routes(project_root):
    result = run_cli(project_root, "--help")

    assert result.returncode == 0
    assert "modore sessions" in result.stdout
    assert "modore sessions current" in result.stdout
    assert "modore storage recovery" in result.stdout
    assert "modore cleanup list" in result.stdout
    assert "hydrojet" not in result.stdout.lower()
    assert "ship" not in result.stdout.lower()


@pytest.mark.skipif(sys.platform != "darwin", reason="cleanup catalog is macOS-only")
def test_cleanup_list_delegates_to_the_allowlisted_preview_harness(project_root):
    result = run_cli(project_root, "cleanup", "list")

    assert result.returncode == 0
    assert "recipe\tcodex_runtime_cache" in result.stdout
    assert "recipe\txcode_derived_data" in result.stdout


def test_cleanup_execute_is_not_an_agent_command(project_root):
    result = run_cli(project_root, "cleanup", "execute", "xcode_derived_data")

    assert result.returncode == 64
    assert "cleanup requires list" in result.stderr


def test_cleanup_preview_cannot_issue_an_approval_token(project_root):
    result = run_cli(project_root, "cleanup", "preview", "xcode_derived_data")

    assert result.returncode == 64
    assert "cleanup requires list" in result.stderr
    assert "approvalToken" not in result.stdout


def test_storage_scan_does_not_expand_into_a_full_system_scan(project_root):
    result = run_cli(project_root, "storage", "scan")

    assert result.returncode == 64
    assert "storage requires status or recovery" in result.stderr


def test_storage_status_rejects_target_or_approval_flags(project_root):
    result = run_cli(project_root, "storage", "status", "--approve", "anything")

    assert result.returncode == 64
    assert "accepts no additional arguments" in result.stderr


def test_storage_status_discards_the_watchers_duplicate_success_protocol(project_root):
    source = (project_root / "bin" / "modore").read_text(encoding="utf-8")

    assert '/bin/bash -p "$STORAGE_WATCH" >/dev/null' in source
    assert "watchStatus\\tbusy" in source
    assert '"lastEvidenceAt"' in source
    assert 'tail -n 1 "$EVIDENCE"' not in source


@pytest.mark.skipif(sys.platform != "darwin", reason="cleanup catalog is macOS-only")
def test_caller_cannot_redirect_a_pinned_shell_module(project_root, tmp_path):
    marker = tmp_path / "executed"
    injected = tmp_path / "injected.sh"
    injected.write_text(f"touch {marker}\n", encoding="utf-8")

    result = run_cli(
        project_root,
        "cleanup",
        "list",
        extra_env={"PCH_PINNED_SUPPORT_DIR_MODULE": str(injected)},
    )

    assert result.returncode == 0
    assert not marker.exists()


def test_python_entrypoints_ignore_pythonpath_sitecustomize(project_root, tmp_path):
    marker = tmp_path / "python-injected"
    (tmp_path / "sitecustomize.py").write_text(
        f"from pathlib import Path\nPath({str(marker)!r}).touch()\n",
        encoding="utf-8",
    )

    result = run_cli(
        project_root,
        "mcp",
        "tools",
        extra_env={"PYTHONPATH": str(tmp_path)},
    )

    assert result.returncode == 0
    assert not marker.exists()


def test_search_requires_stdin_instead_of_a_query_argument(project_root):
    result = run_cli(project_root, "search", "secret phrase")

    assert result.returncode != 0
    assert "send the query on stdin" in result.stderr


def test_sessions_rejects_lower_level_flags(project_root):
    result = run_cli(project_root, "sessions", "--raw")

    assert result.returncode == 64
    assert "sessions accepts current or --limit" in result.stderr


def test_sessions_current_is_a_bounded_metadata_only_route(project_root):
    result = run_cli(project_root, "sessions", "current", extra_env={
        "CODEX_THREAD_ID": "01a0476f-51b6-70d2-b416-9d5651cd8191",
        "CODEX_SESSION_ID": "11a0476f-51b6-70d2-b416-9d5651cd8191",
    })

    assert result.returncode == 0
    payload = json.loads(result.stdout)
    assert payload == {
        "found": False,
        "reason": "codex-context-conflict",
        "provider": "codex",
        "metadataOnly": True,
    }


def test_sessions_current_rejects_extra_options(project_root):
    result = run_cli(project_root, "sessions", "current", "--limit", "1")

    assert result.returncode == 64
    assert "sessions current accepts no additional arguments" in result.stderr


def test_agent_numeric_budgets_are_bounded(project_root):
    sessions = run_cli(project_root, "sessions", "--limit", "501")
    search = run_cli(
        project_root,
        "search",
        "--budget-seconds",
        "56",
        stdin="query",
    )

    assert sessions.returncode == 64
    assert "between 1 and 500" in sessions.stderr
    assert search.returncode == 64
    assert "between 1 and 55" in search.stderr


def test_bounded_exec_stops_a_spawned_process_group(project_root):
    started = time.monotonic()
    result = subprocess.run(
        [
            "/usr/bin/python3",
            "-I",
            "-B",
            str(project_root / "scripts" / "bounded_exec.py"),
            "1",
            "--",
            "/bin/sh",
            "-c",
            "trap '' TERM; sleep 30 & wait",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=4,
    )

    assert result.returncode == 124
    assert "timed out after 1 seconds" in result.stderr
    assert time.monotonic() - started < 3


def test_bounded_exec_forwards_termination_to_the_spawned_group(
    project_root, tmp_path
):
    child_pid_file = tmp_path / "child.pid"
    env = {**os.environ, "CHILD_PID_FILE": str(child_pid_file)}
    wrapper = subprocess.Popen(
        [
            "/usr/bin/python3",
            "-I",
            "-B",
            str(project_root / "scripts" / "bounded_exec.py"),
            "300",
            "--",
            "/bin/sh",
            "-c",
            'sleep 20 & echo "$!" > "$CHILD_PID_FILE"; wait',
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        env=env,
    )
    for _ in range(100):
        if child_pid_file.is_file():
            break
        time.sleep(0.02)
    assert child_pid_file.is_file()
    child_pid = int(child_pid_file.read_text(encoding="utf-8"))

    wrapper.terminate()
    _, stderr = wrapper.communicate(timeout=4)

    assert wrapper.returncode == 128 + 15
    assert not stderr
    for _ in range(100):
        try:
            os.kill(child_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.02)
    else:
        raise AssertionError("bounded child process survived wrapper termination")


def test_bounded_exec_catches_signal_during_process_start(project_root, tmp_path):
    """Inject SIGTERM after Popen creates the child but before it returns.

    This exercises the pending-signal handoff without depending on CPython's
    version-specific bytecode offsets. The helper cleans up independently if
    this ever regresses, so the test cannot leave its 30-second child behind.
    """
    child_pid_file = tmp_path / "assignment-race-child.pid"
    helper = r'''
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import time

module_path = Path(os.environ["BOUNDED_EXEC_MODULE"])
spec = importlib.util.spec_from_file_location("bounded_exec_race", module_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
real_popen = module.subprocess.Popen
pid_path = Path(os.environ["CHILD_PID_FILE"])

def popen_then_signal(*args, **kwargs):
    child = real_popen(*args, **kwargs)
    for _ in range(100):
        if pid_path.is_file():
            break
        time.sleep(0.01)
    os.kill(os.getpid(), signal.SIGTERM)
    return child

module.subprocess.Popen = popen_then_signal
escaped = None
result = None
try:
    result = module.main([
        str(module_path), "300", "--", "/bin/sh", "-c",
        'echo "$$" > "$CHILD_PID_FILE"; exec /bin/sleep 30',
    ])
except BaseException as error:
    escaped = type(error).__name__
finally:
    module.subprocess.Popen = real_popen

for _ in range(100):
    if pid_path.is_file():
        break
    time.sleep(0.01)
alive = False
child_pid = None
if pid_path.is_file():
    child_pid = int(pid_path.read_text(encoding="utf-8"))
    try:
        os.kill(child_pid, 0)
        alive = True
    except ProcessLookupError:
        pass
if alive and child_pid is not None:
    try:
        os.killpg(child_pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
print(json.dumps({"result": result, "escaped": escaped, "childAlive": alive}))
'''
    result = subprocess.run(
        [sys.executable, "-I", "-B", "-c", helper],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=5,
        env={
            **os.environ,
            "BOUNDED_EXEC_MODULE": str(project_root / "scripts" / "bounded_exec.py"),
            "CHILD_PID_FILE": str(child_pid_file),
        },
    )

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload == {"result": 143, "escaped": None, "childAlive": False}


def test_agent_routes_have_outer_wall_clock_limits(project_root):
    source = (project_root / "bin" / "modore").read_text(encoding="utf-8")

    assert '"$BOUNDED_EXEC" 30 --' in source
    assert '"$BOUNDED_EXEC" 60 --' in source
    assert "SEARCH_LIMIT=20" in source
    assert "SEARCH_BUDGET_SECONDS=30" in source
    assert "--first" in source


def test_search_query_has_a_hard_byte_bound(project_root):
    result = run_cli(project_root, "search", stdin="x" * 4097)

    assert result.returncode == 2
    assert "at most 4096 UTF-8 bytes" in result.stderr


def test_unknown_generic_status_route_is_rejected(project_root):
    result = run_cli(project_root, "status")

    assert result.returncode == 64
    assert "unknown command" in result.stderr
