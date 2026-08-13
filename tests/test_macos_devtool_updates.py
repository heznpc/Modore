"""Contract tests for the read-only Homebrew update-status collector.

collect_devtool_updates() shells out to `brew outdated --verbose` with
HOMEBREW_NO_AUTO_UPDATE=1 so it never triggers a network tap refresh. These
tests stub the brew binary via PCH_TEST_BREW_BIN (gated on PCH_TEST_MODE=1,
mirroring login_items.sh's PCH_TEST_OSASCRIPT_BIN) rather than depending on
whatever Homebrew state happens to exist on the machine running the suite.
"""

import os
import subprocess
import textwrap


def run_collector(project_root, tmp_path, brew_script: str):
    module = project_root / "scripts" / "modules" / "macos" / "devtool_updates.sh"
    brew_bin = tmp_path / "fake-brew"
    brew_bin.write_text(brew_script, encoding="utf-8")
    brew_bin.chmod(0o755)

    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_TEST_BREW_BIN": str(brew_bin),
            "TMP_DIR": str(tmp_path),
        }
    )
    harness = (
        'record_collection_status() { printf "%s\\t%s\\t%s\\t%s\\t%s\\n" "$@" >> "$TMP_DIR/status.tsv"; }\n'
        '. "$1"\n'
        "collect_devtool_updates\n"
    )
    result = subprocess.run(
        ["/bin/bash", "-c", harness, "bash", str(module)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )
    out_file = tmp_path / "devtool_updates.txt"
    status_file = tmp_path / "status.tsv"
    return (
        result,
        out_file.read_text(encoding="utf-8") if out_file.exists() else None,
        status_file.read_text(encoding="utf-8") if status_file.exists() else None,
    )


def test_reports_outdated_packages_from_brew_output(project_root, tmp_path):
    brew_script = textwrap.dedent(
        """\
        #!/bin/bash
        printf 'ada-url (3.4.4) < 4.0.0\\n'
        printf 'claude-code (2.1.197) != 2.1.222\\n'
        exit 0
        """
    )

    result, out, status = run_collector(project_root, tmp_path, brew_script)

    assert result.returncode == 0, result.stderr
    assert out == "ada-url (3.4.4) < 4.0.0\nclaude-code (2.1.197) != 2.1.222\n"
    assert status is not None
    fields = status.strip("\n").split("\t")
    assert fields[0] == "devtool_updates"
    assert fields[2] == "ok"
    assert "2개" in fields[4]


def test_reports_ok_when_nothing_is_outdated(project_root, tmp_path):
    brew_script = "#!/bin/bash\nexit 0\n"

    result, out, status = run_collector(project_root, tmp_path, brew_script)

    assert result.returncode == 0, result.stderr
    assert out == ""
    fields = status.strip("\n").split("\t")
    assert fields[2] == "ok"
    assert "모두 최신" in fields[4]


def test_marks_unavailable_when_brew_exits_nonzero(project_root, tmp_path):
    brew_script = "#!/bin/bash\necho 'boom' >&2\nexit 1\n"

    result, out, status = run_collector(project_root, tmp_path, brew_script)

    assert result.returncode == 0, result.stderr
    # A failed brew invocation must not leave stale/partial output behind.
    assert out == ""
    fields = status.strip("\n").split("\t")
    assert fields[2] == "unavailable"


def test_never_disables_auto_update_opt_out(project_root, tmp_path):
    # The whole point of this collector is that it must not trigger a network
    # call. If HOMEBREW_NO_AUTO_UPDATE stops being passed, this is silent --
    # brew just starts fetching tap metadata instead of failing loudly.
    brew_script = textwrap.dedent(
        """\
        #!/bin/bash
        if [[ "${HOMEBREW_NO_AUTO_UPDATE:-}" != "1" ]]; then
            echo 'would have auto-updated' >&2
            exit 1
        fi
        exit 0
        """
    )

    result, out, status = run_collector(project_root, tmp_path, brew_script)

    assert result.returncode == 0, result.stderr
    fields = status.strip("\n").split("\t")
    assert fields[2] == "ok"
