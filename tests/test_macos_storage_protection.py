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
            "101 1 00:42 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-pipe --user-data-dir=/tmp/profile?token=secret",
            "102 101 00:41 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=renderer --remote-debugging-pipe",
            "201 200 02:15 /Users/test/Library/Caches/ms-playwright/chromium-123/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing --no-startup-window --remote-debugging-pipe",
            "301 300 00:03 /usr/local/bin/node playwright_chromiumdev_profile=/tmp/profile?token=secret",
            "401 400 05:00 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
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
        ["101", "1", "00:42", "system", "orphaned"],
        ["201", "200", "02:15", "isolated", "active"],
    ]
    assert "token=secret" not in result.stdout
    assert "remote-debugging-pipe" not in result.stdout
    assert "Google Chrome Helper" not in result.stdout


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
