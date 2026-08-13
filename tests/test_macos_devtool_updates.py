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


def test_pinned_brew_lines_survive_the_scan_parser(project_root):
    """`brew outdated --verbose` appends " [pinned at X]" for a pinned
    formula or cask. An end-anchored latest-version capture dropped those rows
    entirely, so a pinned package's available update was invisible while the
    collector's own line count still included it -- the "N개 업데이트" total
    disagreed with the rows actually shown. The regex lives in the JXA
    scanner, so it is exercised through the real JavaScriptCore engine here
    rather than re-implemented in Python.
    """
    import re

    source = (project_root / "scripts" / "scanner_helper.jxa.js").read_text(encoding="utf-8")
    pattern = re.search(r"const m = line\.match\((/\^\(\\S\+\).*?)\);", source)
    assert pattern, "could not find the devtoolUpdates line regex"

    probe = f"""
    var lines = [
      "node (18.0.0) < 20.0.0 [pinned at 18.0.0]",
      "firefox (139.0) != 140.0.1 [pinned at 139.0]",
      "sqlite (3.53.2, 3.53.3) < 3.53.4",
      "virtualbox (7.2.8,173730) != 7.2.14,174565",
      "ada-url (3.4.4) < 4.0.0"
    ];
    var out = lines.map(function (line) {{
      var m = line.match({pattern.group(1)});
      if (!m) return "DROP";
      return m[1] + "|" + m[3] + "|" + !!m[4];
    }});
    console.log(out.join("\\n"));
    """
    result = subprocess.run(
        ["/usr/bin/osascript", "-l", "JavaScript", "-e", probe],
        capture_output=True, text=True, encoding="utf-8",
    )
    assert result.returncode == 0, result.stderr
    rows = result.stderr.strip().splitlines() or result.stdout.strip().splitlines()

    assert "DROP" not in rows, rows
    assert rows[0] == "node|20.0.0|true"
    assert rows[1] == "firefox|140.0.1|true"
    assert rows[2] == "sqlite|3.53.4|false"
    assert rows[3] == "virtualbox|7.2.14,174565|false"
    assert rows[4] == "ada-url|4.0.0|false"
