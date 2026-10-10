"""Real collector scheduling and measurement-contract regressions."""
import json
import os
import shutil
import subprocess
import time

import pytest


def _run_collector(project_root, tmp_path, extra_env=None, overrides=""):
    home = tmp_path / "home"
    facts = tmp_path / "facts"
    home.mkdir(exist_ok=True)
    facts.mkdir(exist_ok=True)
    env = {
        **os.environ,
        "HOME": str(home),
        "TMP_DIR": str(facts),
        "PCH_TEST_MODE": "1",
        "PCH_TEST_STORAGE_TOOL_ROOT": str(tmp_path),
        "PCH_STORAGE_DU_TIMEOUT": "3",
        "PCH_STORAGE_TOTAL_DU_BUDGET": "3",
        **(extra_env or {}),
    }
    result = subprocess.run(
        ["/bin/bash", "-c", '. "$1"; ' + overrides + '; collect_storage', "bash",
         str(project_root / "scripts/modules/macos/storage.sh")],
        capture_output=True, text=True, env=env, timeout=15,
    )
    assert result.returncode == 0, result.stderr
    return {row[2]: row for row in (
        line.split("\t") for line in (facts / "storage_paths.tsv").read_text().splitlines()
    )}


def _fake_du(tmp_path, source):
    tool = tmp_path / "du-tool"
    tool.write_text("#!/bin/bash\n" + source)
    tool.chmod(0o700)
    return str(tool)


def test_slow_simulators_and_project_do_not_starve_fast_caches_on_repeated_scans(project_root, tmp_path):
    home = tmp_path / "home"
    device = home / "Library/Developer/CoreSimulator/Devices/11111111-1111-4111-8111-111111111111"
    build = home / "IdeaProjects/slow/.build"
    npm = home / ".npm"
    pip = home / "Library/Caches/pip"
    for path in (device, build, npm, pip):
        path.mkdir(parents=True)
    (build.parent / "Package.swift").write_text("// swift-tools-version: 6.0\n")
    du = _fake_du(tmp_path, '''target="${!#}"
case "$target" in */Devices/*|*/.build) exec /bin/sleep 20 ;; esac
printf '1048576\\t%s\\n' "$target"
''')
    env = {"PCH_TEST_STORAGE_DU_BIN": du, "PCH_PROJECT_SCAN_ROOTS": str(home / "IdeaProjects")}
    for _ in range(2):
        started = time.monotonic()
        rows = _run_collector(project_root, tmp_path, env, ":")
        assert rows[str(device.parent)][4] == "timed_out"
        assert rows[str(build)][4] == "timed_out"
        assert rows[str(npm)][3:5] == ["1048576", "ok"]
        assert rows[str(pip)][3:5] == ["1048576", "ok"]
        # Real sleep processes exceed the budget by 6x and must be cancelled.
        assert time.monotonic() - started < 8


def test_discovery_time_does_not_spend_the_measurement_deadline(project_root, tmp_path):
    target = tmp_path / "home/.npm"
    target.mkdir(parents=True)
    du = _fake_du(tmp_path, 'printf "0\\t%s\\n" "${!#}"\n')
    rows = _run_collector(project_root, tmp_path, {
        "PCH_TEST_STORAGE_DU_BIN": du,
        "PCH_STORAGE_TOTAL_DU_BUDGET": "1",
    }, '_pch_collect_storage_applications() { /bin/sleep 1.2; }')
    assert rows[str(target)][3:5] == ["0", "ok"]


def test_unattempted_paths_are_deferred_not_timed_out(project_root, tmp_path):
    home = tmp_path / "home"
    for index in range(20):
        (home / f"candidate-{index}").mkdir(parents=True)
    trace = tmp_path / "trace.tsv"
    rows = _run_collector(project_root, tmp_path, {
        "PCH_TEST_STORAGE_DU_DURATION_TICKS": "10",
        "PCH_TEST_STORAGE_DU_TRACE_FILE": str(trace),
        "PCH_STORAGE_TOTAL_DU_BUDGET": "1",
    }, '''_pch_collect_known_storage_paths() {
        for ((i=0; i<20; i++)); do add_du_path cache "Candidate $i" "$HOME/candidate-$i" npm_cache; done
    }''')
    assert len(rows) == 20
    assert [rows[str(home / f"candidate-{i}")][4] for i in range(20)] == ["timed_out"] * 10 + ["deferred"] * 10
    events = [line.split("\t") for line in trace.read_text().splitlines()]
    assert all(event[2:] == ["0", "deferred"] for event in events[10:])


@pytest.mark.parametrize("output,error,status", [
    ("", "Permission denied", "blocked"),
    ("4096", "Permission denied", "partial"),
    ("", "input/output error", "failed"),
])
def test_measurement_failures_preserve_their_cause(project_root, tmp_path, output, error, status):
    target = tmp_path / "home/.npm"
    target.mkdir(parents=True)
    du = _fake_du(tmp_path, f'printf "{output}\\t%s\\n" "${{!#}}"\nprintf "{error}\\n" >&2\nexit 1\n')
    rows = _run_collector(project_root, tmp_path, {"PCH_TEST_STORAGE_DU_BIN": du}, ":")
    assert rows[str(target)][4] == status


def test_jxa_measurement_contract_keeps_unknown_distinct_from_measured_zero(project_root, tmp_path):
    node = shutil.which("node")
    if not node:
        pytest.skip("Node is unavailable")
    source = (project_root / "scripts/scanner_helper.jxa.js").read_text()
    # Execute the production pure parser and aggregator without JXA host APIs.
    parser = source[source.index("function classifyStorageRow("):source.index("function parseStorageAccess(")]
    totals = source[source.index("function round1("):source.index("function escapeShell(")]
    harness = tmp_path / "contract.js"
    rows = "\n".join(f"cache\t{status}\t/{status}\t{size}\t{status}\tNote\tnpm_cache" for status, size in [
        ("ok", "0"), ("deferred", "0"), ("timed_out", "0"),
        ("blocked", "0"), ("partial", "1048576"), ("failed", "0"),
    ])
    harness.write_text(totals + parser + '\nfunction storageAction() { return ""; }\n' +
                       f'const rows = parseStoragePaths({json.dumps(rows)}, "safe");\n' +
                       'console.log(JSON.stringify({rows, total: uniqueStorageTotal(rows)}));\n')
    result = subprocess.run([node, str(harness)], text=True, capture_output=True, check=True)
    parsed = json.loads(result.stdout)
    by_status = {row["measureStatus"]: row for row in parsed["rows"]}
    assert by_status["ok"]["sizeGB"] == 0
    assert all(row["sizeGB"] is None for status, row in by_status.items() if status != "ok")
    assert by_status["partial"]["lowerBoundGB"] == 1
    assert parsed["total"] == 0
