import json
import os
import shutil
import subprocess
import sys

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
            "999101 1 02:00:42 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-pipe --user-data-dir=/tmp/profile?token=secret",
            "999102 999101 02:00:41 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=renderer --remote-debugging-pipe",
            "999201 999200 02:15 /Users/test/Library/Caches/ms-playwright/chromium-123/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing --no-startup-window --remote-debugging-pipe",
            "999301 999300 00:03 /usr/local/bin/node playwright_chromiumdev_profile=/tmp/profile?token=secret",
            "999401 999400 05:00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
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
        ["999101", "1", "02:00:42", "system", "orphan_candidate", "custom", "other local process"],
        ["999201", "999200", "02:15", "isolated", "detached", "default", "parent unavailable"],
    ]
    assert "token=secret" not in result.stdout
    assert "remote-debugging-pipe" not in result.stdout
    assert "Google Chrome Helper" not in result.stdout


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
        "cache\tExecutable cache\t/Users/test/cache\t3145728\tok\t\tcache_recipe\n",
        encoding="utf-8",
    )
    executable_with_spaces = (
        "/tmp/PC Health Check Mac.app/Contents/MacOS/PCHealthCheckMac"
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
    raw_facts = json.loads(raw.read_text(encoding="utf-8"))
    assert raw_facts["sections"]["cpu"][0]["path"] == executable_with_spaces
    assert raw_facts["sections"]["cpu"][0]["name"] == "PCHealthCheckMac"


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
        "\t4242\t1\t02:10:00\tsystem\torphan_candidate\tdefault\tCodex\n",
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
    root = storage["runtimeSignals"][0]
    assert root["pid"] == 4242
    assert root["parentPid"] == 1
    assert root["elapsed"] == "02:10:00"
    assert root["channel"] == "system"
    assert root["state"] == "orphan_candidate"
    assert root["controller"] == "Codex"
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
