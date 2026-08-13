"""login_items.sh contract tests: preview/execute approval-token flow,
single-use token consumption, name-mismatch and TTL rejection, and the
post-delete existence recheck that distinguishes "osascript exited 0" from
"the login item is actually gone."

osascript is always faked here (PCH_TEST_OSASCRIPT_BIN, honored only under
PCH_TEST_MODE=1 -- production always uses the real absolute path, unchanged)
so the suite never creates or deletes a real login item on the machine
running it. The real end-to-end flow (real osascript, a real disposable
login item) was verified manually against this exact script before these
tests were written; see the PR description for that transcript.
"""
import os
import stat
import subprocess
import tempfile


def parse_protocol(text: str) -> dict[str, str]:
    values = {}
    for line in text.splitlines():
        if "\t" in line:
            key, value = line.split("\t", 1)
            values[key] = value
    return values


def _failing_query_osascript(tmp_path, *, initial_items, healthy_queries):
    """System Events answers `healthy_queries` list reads, then fails every
    later one (no output, non-zero exit) -- the shape of Automation being
    revoked or System Events going unscriptable between preview and execute.
    Deletes always fail, so the item genuinely survives."""
    state_file = tmp_path / "login-items-state.txt"
    state_file.write_text(initial_items, encoding="utf-8")
    counter = tmp_path / "query-count.txt"
    counter.write_text("0", encoding="utf-8")
    stub = tmp_path / "osascript-failing-stub"
    stub.write_text(
        f"""#!/bin/bash
        script="$2"
        case "$script" in
            *"get the name of every login item"*)
                n=$(( $(cat "{counter}") + 1 ))
                printf '%s' "$n" > "{counter}"
                [[ "$n" -gt {healthy_queries} ]] && exit 1
                cat "{state_file}"
                ;;
            *"delete login item"*)
                exit 1
                ;;
        esac
        exit 0
        """,
        encoding="utf-8",
    )
    stub.chmod(0o755)
    return stub, state_file


def _fake_osascript(tmp_path, *, initial_items, delete_is_noop=False):
    """A stateful System Events stand-in. `state_file` holds the current
    comma-separated login item list; `get` reads it, `delete` mutates it
    (unless delete_is_noop, which simulates a delete that reports success
    but changes nothing -- exactly the gap the post-delete recheck exists
    to catch)."""
    state_file = tmp_path / "login-items-state.txt"
    state_file.write_text(initial_items, encoding="utf-8")
    calls_log = tmp_path / "osascript-calls.log"
    stub = tmp_path / "osascript-stub"
    noop_flag = "1" if delete_is_noop else "0"
    stub.write_text(
        f"""#!/bin/bash
        script="$2"
        printf '%s\\n' "$script" >> "{calls_log}"
        case "$script" in
            *"get the name of every login item"*)
                cat "{state_file}"
                ;;
            *"delete login item"*)
                if [[ "{noop_flag}" == "1" ]]; then
                    exit 0
                fi
                name=$(printf '%s' "$script" | sed -E 's/.*delete login item "(.*)".*/\\1/')
                current=$(cat "{state_file}")
                new=$(printf '%s' "$current" | tr ',' '\\n' | sed 's/^ *//;s/ *$//' \\
                    | grep -v -F -x "$name" | paste -sd, -)
                printf '%s' "$new" > "{state_file}"
                ;;
        esac
        exit 0
        """,
        encoding="utf-8",
    )
    stub.chmod(0o755)
    return stub, state_file, calls_log


def _run(project_root, tmp_path, args, *, osascript_stub=None, home=None, pass_fds=()):
    env = os.environ.copy()
    env["PCH_TEST_MODE"] = "1"
    if osascript_stub is not None:
        env["PCH_TEST_OSASCRIPT_BIN"] = str(osascript_stub)
    env["HOME"] = str(home if home is not None else (tmp_path / "home"))
    script = project_root / "scripts" / "login_items.sh"
    return subprocess.run(
        [str(script), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        pass_fds=pass_fds,
    )


def _preview(project_root, tmp_path, name, *, osascript_stub, home):
    result = _run(project_root, tmp_path, ["--preview", name], osascript_stub=osascript_stub, home=home)
    return result, parse_protocol(result.stdout)


def _execute(project_root, tmp_path, name, token, *, osascript_stub, home):
    # login_items.sh only accepts /dev/fd/N (matching cleanup.sh's own
    # approval-token-file contract, and how the real app passes it via
    # LocalProcessRunner's pinned-file mechanism) -- a plain path fails its
    # regex check outright, so the token must ride a real inherited fd.
    with tempfile.TemporaryFile() as token_file:
        token_file.write(token.encode("ascii"))
        token_file.flush()
        token_file.seek(0)
        descriptor = token_file.fileno()
        result = _run(
            project_root,
            tmp_path,
            ["--execute", name, "--owner-approved", "--approval-token-file", f"/dev/fd/{descriptor}"],
            osascript_stub=osascript_stub,
            home=home,
            pass_fds=(descriptor,),
        )
    return result, parse_protocol(result.stdout)


def test_preview_issues_token_for_an_existing_item(project_root, tmp_path):
    home = tmp_path / "home"
    stub, _, _ = _fake_osascript(tmp_path, initial_items="Foo, Bar, Baz")

    result, payload = _preview(project_root, tmp_path, "Bar", osascript_stub=stub, home=home)

    assert result.returncode == 0, result.stderr
    assert payload["status"] == "ready"
    assert payload["name"] == "Bar"
    token = payload["approvalToken"]
    assert len(token) == 64
    assert all(c in "0123456789abcdef" for c in token)
    token_path = home / "Library" / "Application Support" / "Modore" / "login-item-approvals" / f"{token}.tsv"
    assert token_path.is_file()
    assert stat.S_IMODE(token_path.stat().st_mode) == 0o600
    assert stat.S_IMODE(token_path.parent.stat().st_mode) == 0o700


def test_preview_refuses_a_name_that_is_not_actually_a_login_item(project_root, tmp_path):
    home = tmp_path / "home"
    stub, _, _ = _fake_osascript(tmp_path, initial_items="Foo, Bar")

    result, payload = _preview(project_root, tmp_path, "NotThere", osascript_stub=stub, home=home)

    assert result.returncode == 1
    assert payload["status"] == "not_found"
    approvals_dir = home / "Library" / "Application Support" / "Modore" / "login-item-approvals"
    assert not approvals_dir.exists() or not list(approvals_dir.glob("*.tsv"))


def test_execute_removes_the_item_and_confirms_it_is_actually_gone(project_root, tmp_path):
    home = tmp_path / "home"
    stub, state_file, _ = _fake_osascript(tmp_path, initial_items="Foo, Bar, Baz")

    _, preview_payload = _preview(project_root, tmp_path, "Bar", osascript_stub=stub, home=home)
    result, payload = _execute(
        project_root, tmp_path, "Bar", preview_payload["approvalToken"], osascript_stub=stub, home=home
    )

    assert result.returncode == 0, result.stderr
    assert payload["status"] == "ok"
    remaining = [n.strip() for n in state_file.read_text(encoding="utf-8").split(",")]
    assert "Bar" not in remaining
    assert "Foo" in remaining and "Baz" in remaining


def test_execute_reports_failed_when_the_item_survives_the_delete_call(project_root, tmp_path):
    """osascript exiting 0 must not be trusted as proof of removal -- only a
    real recheck of the live list can tell "deleted" from "command accepted,
    nothing actually changed"."""
    home = tmp_path / "home"
    stub, state_file, _ = _fake_osascript(tmp_path, initial_items="Foo, Bar", delete_is_noop=True)

    _, preview_payload = _preview(project_root, tmp_path, "Bar", osascript_stub=stub, home=home)
    result, payload = _execute(
        project_root, tmp_path, "Bar", preview_payload["approvalToken"], osascript_stub=stub, home=home
    )

    assert result.returncode == 1
    assert payload["status"] == "failed"
    assert "Bar" in state_file.read_text(encoding="utf-8")


def test_execute_rejects_reusing_an_already_consumed_token(project_root, tmp_path):
    home = tmp_path / "home"
    stub, _, _ = _fake_osascript(tmp_path, initial_items="Foo, Bar")

    _, preview_payload = _preview(project_root, tmp_path, "Bar", osascript_stub=stub, home=home)
    token = preview_payload["approvalToken"]
    first, _ = _execute(project_root, tmp_path, "Bar", token, osascript_stub=stub, home=home)
    assert first.returncode == 0

    second, second_payload = _execute(project_root, tmp_path, "Bar", token, osascript_stub=stub, home=home)

    assert second.returncode == 1
    assert second_payload["status"] == "blocked"


def test_execute_rejects_a_token_approved_for_a_different_name(project_root, tmp_path):
    home = tmp_path / "home"
    stub, state_file, _ = _fake_osascript(tmp_path, initial_items="Foo, Bar")

    _, preview_payload = _preview(project_root, tmp_path, "Foo", osascript_stub=stub, home=home)
    result, payload = _execute(
        project_root, tmp_path, "Bar", preview_payload["approvalToken"], osascript_stub=stub, home=home
    )

    assert result.returncode == 1
    assert payload["status"] == "mismatch"
    remaining = [n.strip() for n in state_file.read_text(encoding="utf-8").split(",")]
    assert "Foo" in remaining and "Bar" in remaining


def test_execute_rejects_an_expired_token(project_root, tmp_path):
    home = tmp_path / "home"
    stub, state_file, _ = _fake_osascript(tmp_path, initial_items="Foo, Bar")

    _, preview_payload = _preview(project_root, tmp_path, "Bar", osascript_stub=stub, home=home)
    token = preview_payload["approvalToken"]
    token_path = (
        home / "Library" / "Application Support" / "Modore" / "login-item-approvals" / f"{token}.tsv"
    )
    old_epoch = 1
    lines = token_path.read_text(encoding="utf-8").splitlines()
    rewritten = [
        f"createdEpoch\t{old_epoch}" if line.startswith("createdEpoch\t") else line for line in lines
    ]
    token_path.write_text("\n".join(rewritten) + "\n", encoding="utf-8")

    result, payload = _execute(project_root, tmp_path, "Bar", token, osascript_stub=stub, home=home)

    assert result.returncode == 1
    assert payload["status"] == "expired"
    assert "Bar" in state_file.read_text(encoding="utf-8")


def test_execute_reports_already_gone_when_item_vanished_before_execute(project_root, tmp_path):
    home = tmp_path / "home"
    stub, state_file, calls_log = _fake_osascript(tmp_path, initial_items="Foo, Bar")

    _, preview_payload = _preview(project_root, tmp_path, "Bar", osascript_stub=stub, home=home)
    # Simulate the item being removed some other way (System Settings, the
    # app itself) between preview and execute.
    state_file.write_text("Foo", encoding="utf-8")
    calls_before = calls_log.read_text(encoding="utf-8") if calls_log.exists() else ""

    result, payload = _execute(
        project_root, tmp_path, "Bar", preview_payload["approvalToken"], osascript_stub=stub, home=home
    )

    assert result.returncode == 0, result.stderr
    assert payload["status"] == "already_gone"
    calls_after = calls_log.read_text(encoding="utf-8")
    assert "delete login item" not in calls_after[len(calls_before):]


def test_execute_does_not_call_a_failed_query_already_gone(project_root, tmp_path):
    """A failed System Events read and a genuinely removed item are the same
    exit status, and treating the first as the second told the owner a
    persistence mechanism was gone while it was still installed. Only a
    successful read may assert absence."""
    home = tmp_path / "home"
    # Query 1 is the preview; every query from the execute onward fails.
    stub, state_file = _failing_query_osascript(tmp_path, initial_items="Foo, Bar", healthy_queries=1)

    _, preview_payload = _preview(project_root, tmp_path, "Bar", osascript_stub=stub, home=home)
    assert preview_payload["status"] == "ready"

    result, payload = _execute(
        project_root, tmp_path, "Bar", preview_payload["approvalToken"], osascript_stub=stub, home=home
    )

    assert payload["status"] == "blocked", payload
    assert result.returncode == 1
    assert "Bar" in state_file.read_text(encoding="utf-8")


def test_execute_does_not_report_ok_when_the_post_delete_recheck_fails(project_root, tmp_path):
    """The recheck exists to distinguish "osascript accepted the command"
    from "the item is actually gone". If the recheck itself cannot run, the
    outcome is unknown -- which is a failure to confirm removal, not a
    removal."""
    home = tmp_path / "home"
    # Queries 1 (preview) and 2 (pre-delete check) succeed; the post-delete
    # recheck fails, and the delete itself failed too, so the item survives.
    stub, state_file = _failing_query_osascript(tmp_path, initial_items="Foo, Bar", healthy_queries=2)

    _, preview_payload = _preview(project_root, tmp_path, "Bar", osascript_stub=stub, home=home)
    result, payload = _execute(
        project_root, tmp_path, "Bar", preview_payload["approvalToken"], osascript_stub=stub, home=home
    )

    assert payload["status"] == "failed", payload
    assert result.returncode == 1
    assert "Bar" in state_file.read_text(encoding="utf-8")


def test_preview_does_not_call_a_failed_query_not_found(project_root, tmp_path):
    """not_found means "this is not a login item". A failed read means we do
    not know, and must not issue an approval token off it either way."""
    home = tmp_path / "home"
    stub, _ = _failing_query_osascript(tmp_path, initial_items="Foo, Bar", healthy_queries=0)

    result, payload = _preview(project_root, tmp_path, "Bar", osascript_stub=stub, home=home)

    assert payload["status"] == "blocked", payload
    assert result.returncode == 1
    assert "approvalToken" not in payload


def test_execute_requires_owner_approved_flag(project_root, tmp_path):
    home = tmp_path / "home"
    stub, _, _ = _fake_osascript(tmp_path, initial_items="Foo")
    token_file = tmp_path / "token"
    token_file.write_text("0" * 64, encoding="utf-8")

    result = _run(
        project_root,
        tmp_path,
        ["--execute", "Foo", "--approval-token-file", str(token_file)],
        osascript_stub=stub,
        home=home,
    )

    assert result.returncode == 64


def test_execute_requires_an_approval_token_file(project_root, tmp_path):
    home = tmp_path / "home"
    stub, _, _ = _fake_osascript(tmp_path, initial_items="Foo")

    result = _run(
        project_root, tmp_path, ["--execute", "Foo", "--owner-approved"], osascript_stub=stub, home=home
    )

    assert result.returncode == 64
