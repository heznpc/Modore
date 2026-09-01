import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest


def parse_protocol(text: str) -> dict[str, object]:
    values: dict[str, object] = {}
    targets: list[str] = []
    staged_remainders: list[str] = []
    shared_residue: list[str] = []
    review_residue: list[str] = []
    for line in text.splitlines():
        if "\t" not in line:
            continue
        key, value = line.split("\t", 1)
        if key == "target":
            targets.append(value)
        elif key == "stagedRemainder":
            staged_remainders.append(value)
        elif key == "sharedResidue":
            shared_residue.append(value)
        elif key == "reviewResidue":
            review_residue.append(value)
        else:
            values[key] = value
    values["targets"] = targets
    values["stagedRemainders"] = staged_remainders
    values["sharedResidue"] = shared_residue
    values["reviewResidue"] = review_residue
    return values


def run_cleanup(
    project_root: Path,
    home: Path,
    *args: str,
    processes: str = "",
    extra_env: dict[str, str] | None = None,
    pass_fds: tuple[int, ...] = (),
):
    applications_root = home / "ApplicationsRoot"
    applications_root.mkdir(parents=True, exist_ok=True)
    process_file = home / "processes.txt"
    process_file.parent.mkdir(parents=True, exist_ok=True)
    process_file.write_text(processes, encoding="utf-8")
    env = os.environ.copy()
    env.update(
        {
            "PCH_TEST_MODE": "1",
            "PCH_HOME_OVERRIDE": str(home),
            "PCH_PROCESS_LIST_FILE": str(process_file),
            "PCH_APPLICATIONS_ROOT_OVERRIDE": str(applications_root),
        }
    )
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [str(project_root / "scripts" / "cleanup.sh"), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        pass_fds=pass_fds,
    )


def approval_token(payload: dict[str, object]) -> str:
    token = str(payload.get("approvalToken", ""))
    assert len(token) == 64
    return token


def run_cleanup_with_token_file(
    project_root: Path,
    home: Path,
    recipe: str,
    token: str,
    *,
    processes: str = "",
    extra_env: dict[str, str] | None = None,
):
    with tempfile.TemporaryFile() as token_file:
        token_file.write(token.encode("ascii"))
        token_file.flush()
        token_file.seek(0)
        descriptor = token_file.fileno()
        return run_cleanup(
            project_root,
            home,
            "--execute",
            recipe,
            "--owner-approved",
            "--approval-token-file",
            f"/dev/fd/{descriptor}",
            processes=processes,
            extra_env=extra_env,
            pass_fds=(descriptor,),
        )


def project_residue_request(target: Path | str) -> bytes:
    return (
        "version\t1\n"
        "kind\tproject_residue\n"
        f"target\t{target}\n"
    ).encode("utf-8")


def run_project_residue_preview(
    project_root: Path,
    home: Path,
    target: Path | str,
    *,
    processes: str = "",
    processes_with_pid: str = "",
    process_cwds: str = "",
    request_data: bytes | None = None,
):
    extra_env: dict[str, str] = {}
    if processes_with_pid or process_cwds:
        home.mkdir(parents=True, exist_ok=True)
        pid_file = home / "project-processes-with-pid.txt"
        cwd_file = home / "project-process-cwds.tsv"
        pid_file.write_text(processes_with_pid, encoding="utf-8")
        cwd_file.write_text(process_cwds, encoding="utf-8")
        extra_env = {
            "PCH_PROCESS_LIST_WITH_PID_FILE": str(pid_file),
            "PCH_TEST_PROCESS_CWD_FILE": str(cwd_file),
        }
    with tempfile.TemporaryFile() as request_file:
        request_file.write(request_data or project_residue_request(target))
        request_file.flush()
        request_file.seek(0)
        descriptor = request_file.fileno()
        return run_cleanup(
            project_root,
            home,
            "--preview",
            "project_residue",
            "--request-file",
            f"/dev/fd/{descriptor}",
            processes=processes,
            extra_env=extra_env,
            pass_fds=(descriptor,),
        )


def run_project_residue_execute(
    project_root: Path,
    home: Path,
    target: Path | str,
    token: str,
    *,
    processes: str = "",
    request_data: bytes | None = None,
):
    with tempfile.TemporaryFile() as request_file, tempfile.TemporaryFile() as token_file:
        request_file.write(request_data or project_residue_request(target))
        request_file.flush()
        request_file.seek(0)
        token_file.write(token.encode("ascii"))
        token_file.flush()
        token_file.seek(0)
        request_descriptor = request_file.fileno()
        token_descriptor = token_file.fileno()
        return run_cleanup(
            project_root,
            home,
            "--execute",
            "project_residue",
            "--request-file",
            f"/dev/fd/{request_descriptor}",
            "--owner-approved",
            "--approval-token-file",
            f"/dev/fd/{token_descriptor}",
            processes=processes,
            pass_fds=(request_descriptor, token_descriptor),
        )


def test_macos_app_keeps_raw_approval_token_out_of_argv(project_root):
    source = (
        project_root
        / "macos/Modore/Sources/Modore/Services/CleanupExecutionService.swift"
    ).read_text(encoding="utf-8")

    # The Swift unit test exercises the constructed invocation. This source
    # boundary only guards the release against reintroducing the legacy raw
    # argv option, which would expose the token to process inspection.
    assert '"approval_token": Data(preview.approvalToken.utf8)' in source
    assert '"--approval-token-file", "@pch-pinned:approval_token"' in source
    assert '"--approval-token",' not in source


def test_macos_app_source_boundary_keeps_project_residue_request_out_of_argv(project_root):
    service = (
        project_root
        / "macos/Modore/Sources/Modore/Services/CleanupExecutionService.swift"
    ).read_text(encoding="utf-8")
    models = (
        project_root
        / "macos/Modore/Sources/Modore/Models/StorageRecoveryModels.swift"
    ).read_text(encoding="utf-8")
    # Exact argument construction is covered by CleanupExecutionServiceTests;
    # retain only the shipped-source boundary that the path travels through a
    # pinned descriptor and never becomes a command-line argument.
    assert 'requestFiles["cleanup_request"] = request.protocolData' in service
    assert '["--request-file", "@pch-pinned:cleanup_request"]' in service
    assert "request.target" not in service
    assert 'Data("version\\t1\\nkind\\tproject_residue\\ntarget\\t\\(target)\\n".utf8)' in models


def test_cleanup_preview_is_read_only_and_execute_requires_approval(project_root, tmp_path):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "_cacache" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"x" * 8192)

    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0
    assert payload["status"] == "ready"
    assert payload["recipeId"] == "npm_cache"
    assert payload["estimateMeasured"] == "true"
    assert int(str(payload["estimatedKB"])) > 0
    assert cache_file.exists()

    rejected = run_cleanup(project_root, home, "--execute", "npm_cache")
    assert rejected.returncode == 2
    assert cache_file.exists()

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert not (home / ".npm").exists()
    receipt = Path(str(result["receipt"]))
    assert receipt.is_file()
    assert stat.S_IMODE(receipt.stat().st_mode) == 0o600


def test_cleanup_rejects_token_minted_for_a_different_recipe(project_root, tmp_path):
    """An approval token is bound to the recipe it was previewed for; replaying
    it against a different recipe must not authorize anything."""
    home = tmp_path / "home"
    cache_file = home / ".npm" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"x" * 8192)

    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    token = approval_token(parse_protocol(preview.stdout))

    crossed = run_cleanup(
        project_root,
        home,
        "--execute",
        "playwright_browsers",
        "--owner-approved",
        "--approval-token",
        token,
    )

    assert crossed.returncode != 0, "cross-recipe token must be rejected"
    assert cache_file.exists(), "nothing may be deleted on a rejected token"


def test_cleanup_executes_with_exact_token_from_regular_fd(project_root, tmp_path):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"fixture")
    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    token = approval_token(parse_protocol(preview.stdout))

    executed = run_cleanup_with_token_file(project_root, home, "npm_cache", token)
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert not cache_file.exists()
    assert token not in executed.stdout
    assert token not in executed.stderr


@pytest.mark.parametrize("mutation", ["short", "newline", "long"])
def test_cleanup_rejects_non_exact_token_file(project_root, tmp_path, mutation):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"fixture")
    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    token = approval_token(parse_protocol(preview.stdout))
    candidate = {
        "short": token[:-1],
        "newline": token + "\n",
        "long": token + "0",
    }[mutation]

    executed = run_cleanup_with_token_file(project_root, home, "npm_cache", candidate)

    assert executed.returncode == 2
    assert cache_file.is_file()
    assert token not in executed.stdout
    assert token not in executed.stderr


def test_cleanup_blocks_live_related_process(project_root, tmp_path):
    home = tmp_path / "home"
    browser = home / "Library" / "Caches" / "ms-playwright" / "chromium" / "chrome"
    browser.parent.mkdir(parents=True)
    browser.write_text("fixture", encoding="utf-8")

    preview = run_cleanup(
        project_root,
        home,
        "--preview",
        "playwright_browsers",
        processes="/opt/pw/ms-playwright/chromium-9999/headless_shell --token=do-not-expose\n",
    )
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0
    assert payload["status"] == "blocked"
    assert "종료" in str(payload["blockedReason"])
    assert payload["runningProcesses"] == "Playwright"
    # 차단된 미리보기는 크기를 재지 않았으므로 estimatedKB 0을
    # 측정값으로 표시하지 못하도록 미측정을 명시해야 한다.
    assert payload["estimateMeasured"] == "false"
    assert payload["estimatedKB"] == "0"
    assert "do-not-expose" not in preview.stdout
    assert "/opt/pw" not in preview.stdout
    assert browser.exists()

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "playwright_browsers",
        "--owner-approved",
        "--approval-token",
        "0" * 64,
        processes="/opt/pw/ms-playwright/chromium-9999/headless_shell --token=do-not-expose\n",
    )
    assert executed.returncode == 3
    assert browser.exists()


@pytest.mark.skipif(sys.platform != "darwin", reason="migrates the macOS Application Support layout")
def test_cleanup_migrates_state_written_before_the_rename(project_root, tmp_path):
    home = tmp_path / "home"
    support = home / "Library" / "Application Support"
    legacy = support / "PC Health Check"
    (legacy / "cleanup-receipts").mkdir(parents=True)
    (legacy / "cleanup-receipts" / "earlier.tsv").write_text("kept", encoding="utf-8")
    (legacy / "config.json").write_text("{}", encoding="utf-8")
    cache_file = home / ".npm" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"fixture")

    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    token = approval_token(parse_protocol(preview.stdout))
    executed = run_cleanup_with_token_file(project_root, home, "npm_cache", token)
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    current = support / "Modore"
    # Receipts and configuration written under the old product name must follow
    # the rename rather than being orphaned or deleted.
    assert (current / "cleanup-receipts" / "earlier.tsv").read_text(encoding="utf-8") == "kept"
    assert (current / "config.json").is_file()
    assert not legacy.exists()
    assert str(current) in str(result["receipt"])


def test_rename_migration_never_merges_into_an_existing_directory(project_root, tmp_path):
    home = tmp_path / "home"
    support = home / "Library" / "Application Support"
    legacy = support / "PC Health Check"
    legacy.mkdir(parents=True)
    (legacy / "legacy-only.txt").write_text("old", encoding="utf-8")
    current = support / "Modore"
    current.mkdir(parents=True)
    (current / "current-only.txt").write_text("new", encoding="utf-8")
    cache_file = home / ".npm" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"fixture")

    preview = run_cleanup(project_root, home, "--preview", "npm_cache")

    assert preview.returncode == 0, preview.stderr
    # Merging two state directories needs a judgement the harness cannot make,
    # so the newer name wins and nothing is moved or removed.
    assert (legacy / "legacy-only.txt").read_text(encoding="utf-8") == "old"
    assert (current / "current-only.txt").read_text(encoding="utf-8") == "new"


def test_simulator_alone_does_not_block_xcode_derived_data(project_root, tmp_path):
    home = tmp_path / "home"
    derived = home / "Library" / "Developer" / "Xcode" / "DerivedData" / "App-abc"
    derived.mkdir(parents=True)
    (derived / "build.log").write_text("fixture", encoding="utf-8")

    # Simulator.app lives inside Xcode.app but never writes DerivedData. Matching
    # the bundle path blocked the cleanup for as long as a simulator stayed open.
    ready = run_cleanup(
        project_root,
        home,
        "--preview",
        "xcode_derived_data",
        processes=(
            "/Applications/Xcode.app/Contents/Developer/Applications/"
            "Simulator.app/Contents/MacOS/Simulator\n"
        ),
    )
    ready_payload = parse_protocol(ready.stdout)

    assert ready.returncode == 0, ready.stderr
    assert ready_payload["status"] == "ready"
    assert ready_payload["runningProcesses"] == ""

    blocked = run_cleanup(
        project_root,
        home,
        "--preview",
        "xcode_derived_data",
        processes="/Applications/Xcode.app/Contents/MacOS/Xcode\n",
    )
    blocked_payload = parse_protocol(blocked.stdout)

    # Xcode itself still blocks, since a build in flight owns this directory.
    assert blocked_payload["status"] == "blocked"
    assert derived.is_dir()


def pnpm_store_status(project_root, tmp_path, name: str, processes: str) -> str:
    home = tmp_path / name
    store = home / "Library" / "pnpm" / "store"
    store.mkdir(parents=True)
    (store / "package.tgz").write_bytes(b"fixture")
    preview = run_cleanup(project_root, home, "--preview", "pnpm_store", processes=processes)
    assert preview.returncode == 0, preview.stderr
    assert store.is_dir(), "a preview must never delete anything"
    return str(parse_protocol(preview.stdout)["status"])


def run_cleanup_with_pid_evidence(
    project_root: Path, home: Path, recipe: str, pid_lines: str
):
    """Drive the PID-prefixed evidence path the way `ps` actually formats it.

    `ps -axo pid=,command=` right-aligns the PID, so these lines begin with
    whitespace. Nothing exercised this path before, which is why an anchored
    pattern could silently produce no evidence for a block that did fire.
    """
    pid_file = home / "processes-with-pid.txt"
    pid_file.parent.mkdir(parents=True, exist_ok=True)
    pid_file.write_text(pid_lines, encoding="utf-8")
    # The gate reads `ps -axo command=`, which carries no PID, so the two
    # snapshots must be given in the format each one really sees.
    plain_lines = "".join(
        re.sub(r"^\s*\d+\s+", "", line) + "\n"
        for line in pid_lines.splitlines()
        if line.strip()
    )
    return run_cleanup(
        project_root,
        home,
        "--preview",
        recipe,
        processes=plain_lines,
        extra_env={"PCH_PROCESS_LIST_WITH_PID_FILE": str(pid_file)},
    )


def test_evidence_names_the_process_even_when_the_pattern_is_anchored(
    project_root, tmp_path
):
    home = tmp_path / "home"
    derived = home / "Library" / "Developer" / "Xcode" / "DerivedData" / "App"
    derived.mkdir(parents=True)
    (derived / "log").write_bytes(b"fixture")

    preview = run_cleanup_with_pid_evidence(
        project_root,
        home,
        "xcode_derived_data",
        "  901 /usr/bin/xcodebuild -scheme App build\n",
    )
    payload = parse_protocol(preview.stdout)

    # Blocking without naming the blocker leaves the owner with nothing to act
    # on, which is the same dead end an over-broad pattern produces.
    assert payload["status"] == "blocked"
    assert payload["runningProcesses"] == "Xcode/build tool · PID 901"
    assert derived.is_dir()


def test_pid_evidence_still_drops_the_tools_own_sizing_pass(project_root, tmp_path):
    home = tmp_path / "home"
    cache = home / "Library" / "Caches" / "ms-playwright"
    cache.mkdir(parents=True)
    (cache / "chromium").write_bytes(b"fixture")

    preview = run_cleanup_with_pid_evidence(
        project_root,
        home,
        "playwright_browsers",
        "  902 /usr/bin/du -sk /Users/x/Library/Caches/ms-playwright\n",
    )
    payload = parse_protocol(preview.stdout)

    assert payload["status"] == "ready"
    assert payload["runningProcesses"] == ""


def test_editor_node_processes_do_not_block_the_pnpm_store(project_root, tmp_path):
    # Language servers, MCP servers and Electron helpers all run as bare node and
    # never write this store, so blocking on them left no action the owner could
    # take.
    assert pnpm_store_status(
        project_root, tmp_path, "editors",
        "/Users/x/.local/share/mise/installs/node/22/bin/node /opt/lsp/tsserver.js\n"
        "/Applications/Editor.app/Contents/MacOS/Editor Helper --type=utility\n",
    ) == "ready"


def test_pnpm_still_blocks_however_it_was_launched(project_root, tmp_path):
    # Narrowing away bare node must not lose pnpm itself. corepack and standalone
    # installs run it as `node <pnpm.cjs>`, which the executable name alone misses,
    # and a binary running out of the store is holding the store.
    assert pnpm_store_status(
        project_root, tmp_path, "direct", "/opt/homebrew/bin/pnpm install\n"
    ) == "blocked"
    assert pnpm_store_status(
        project_root, tmp_path, "via-node",
        "/usr/local/bin/node /opt/pnpm/dist/pnpm.cjs install\n",
    ) == "blocked"
    assert pnpm_store_status(
        project_root, tmp_path, "from-store",
        "/Users/x/Library/pnpm/global/5/.bin/somecli\n",
    ) == "blocked"


def test_excluding_sizing_tools_never_hides_a_real_blocker(project_root, tmp_path):
    # The tool sizes these paths with du on an hourly schedule, so its own
    # measurement must not read as a blocker. Excluding by substring instead of
    # by whole command line would have suppressed a genuine pnpm install that
    # happened to run du in the same tree, which is worse than a false block.
    assert pnpm_store_status(
        project_root, tmp_path, "sizing-only",
        "/usr/bin/du -sk /Users/x/Library/pnpm\n",
    ) == "ready"
    assert pnpm_store_status(
        project_root, tmp_path, "sizing-beside-blocker",
        "/bin/sh -c pnpm install && /usr/bin/du -sk .\n"
        "/opt/homebrew/bin/pnpm install\n"
        "/usr/bin/du -sk /Users/x/Library/pnpm\n",
    ) == "blocked"


def cache_recipe_status(
    project_root, tmp_path, name: str, recipe: str, target_relpath: str, processes: str
) -> str:
    home = tmp_path / name
    target = home / target_relpath
    target.mkdir(parents=True)
    (target / "entry").write_bytes(b"fixture")
    preview = run_cleanup(project_root, home, "--preview", recipe, processes=processes)
    assert preview.returncode == 0, preview.stderr
    assert target.is_dir(), "a preview must never delete anything"
    return str(parse_protocol(preview.stdout)["status"])


def test_npm_still_blocks_when_launched_through_its_shebang_wrapper(project_root, tmp_path):
    # npm/npx are shebang scripts, so the kernel puts the interpreter first in
    # `ps` and an anchored pattern never sees "npm" at position zero. Both
    # lines below were captured directly from this machine's real npm: the
    # mise shim shows as bash mid-flight, then execs into node + npm-cli.js.
    assert cache_recipe_status(
        project_root, tmp_path, "shim-bash", "npm_cache", ".npm",
        "/usr/bin/env bash /Users/x/.local/share/mise/installs/node/22/bin/npm --version\n",
    ) == "blocked"
    assert cache_recipe_status(
        project_root, tmp_path, "node-final", "npm_cache", ".npm",
        "/Users/x/.local/share/mise/installs/node/bin/node "
        "/Users/x/.local/share/mise/installs/node/lib/node_modules/npm/bin/npm-cli.js install\n",
    ) == "blocked"


def test_cocoapods_still_blocks_when_launched_through_its_shebang_wrapper(project_root, tmp_path):
    # The installed `pod` execs into a ruby script, so ps's leading token is
    # ruby, not pod. Captured directly from this machine's real CocoaPods.
    assert cache_recipe_status(
        project_root, tmp_path, "ruby-final", "cocoapods_cache", "Library/Caches/CocoaPods",
        "/opt/homebrew/opt/ruby/bin/ruby "
        "/opt/homebrew/Cellar/cocoapods/1.16.2_2/libexec/bin/pod install\n",
    ) == "blocked"


def test_pip_still_blocks_when_launched_through_its_polyglot_wrapper(project_root, tmp_path):
    # pip3 is a sh/python polyglot that execs into python3.13; ps shows the
    # interpreter first, never a leading "pip3". Captured from this machine.
    assert cache_recipe_status(
        project_root, tmp_path, "python-final", "pip_cache", "Library/Caches/pip",
        "/Users/x/.local/share/mise/installs/python/3.13/bin/python3.13 "
        "/Users/x/.local/share/mise/installs/python/3.13/bin/pip3 install requests\n",
    ) == "blocked"


def test_homebrew_still_blocks_across_its_two_stage_self_exec(project_root, tmp_path):
    # brew re-execs itself as `bash .../Homebrew/brew.sh` (brew.sh's own last
    # line). Neither stage's leading token is a bare "brew" an anchored
    # pattern would catch. Both stages captured from this machine's real brew.
    assert cache_recipe_status(
        project_root, tmp_path, "setup-stage", "homebrew_cache", "Library/Caches/Homebrew",
        "/bin/bash -pu /opt/homebrew/bin/brew install wget\n",
    ) == "blocked"
    assert cache_recipe_status(
        project_root, tmp_path, "brew-sh-stage", "homebrew_cache", "Library/Caches/Homebrew",
        "/bin/bash -p /opt/homebrew/Library/Homebrew/brew.sh install wget\n",
    ) == "blocked"


def test_headless_converters_do_not_block_chrome_clone_cleanup(project_root, tmp_path):
    home = tmp_path / "home"
    var_folders = home / "VarFoldersRoot" / "aa" / "bb" / "X"
    clone = var_folders / "com.google.Chrome.code_sign_clone"
    clone.mkdir(parents=True)
    (clone / "payload").write_bytes(b"fixture")

    # The same generic Chromium flags that over-blocked the Playwright cache were
    # still here, catching LibreOffice and Edge, while missing the Chrome updater
    # that actually creates and consumes this clone.
    ready = run_cleanup(
        project_root,
        home,
        "--preview",
        "chrome_code_sign_clones",
        processes=(
            "/Applications/LibreOffice.app/Contents/MacOS/soffice --headless --convert-to pdf\n"
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge --headless=new\n"
        ),
    )
    blocked = run_cleanup(
        project_root,
        home,
        "--preview",
        "chrome_code_sign_clones",
        processes="/Library/Google/GoogleSoftwareUpdate/ksadmin --print-tickets\n",
    )

    assert parse_protocol(ready.stdout)["status"] == "ready"
    assert parse_protocol(blocked.stdout)["status"] == "blocked"
    assert clone.is_dir()


def test_claude_code_cli_does_not_block_desktop_vm_bundles(project_root, tmp_path):
    home = tmp_path / "home"
    bundles = home / "Library" / "Application Support" / "Claude" / "vm_bundles"
    bundles.mkdir(parents=True)
    (bundles / "image.raw").write_bytes(b"fixture")

    # Claude Code is a different product and does not use these bundles, and
    # local-agent-mode named the very directory this recipe promises to preserve.
    ready = run_cleanup(
        project_root,
        home,
        "--preview",
        "claude_vm_bundles",
        processes=(
            "/Users/x/.local/bin/claude --print\n"
            "/usr/bin/du -sk /Users/x/Library/Application Support/Claude/local-agent-mode\n"
        ),
    )
    blocked = run_cleanup(
        project_root,
        home,
        "--preview",
        "claude_vm_bundles",
        processes="/Applications/Claude.app/Contents/MacOS/Claude\n",
    )

    assert parse_protocol(ready.stdout)["status"] == "ready"
    assert parse_protocol(blocked.stdout)["status"] == "blocked"
    assert bundles.is_dir()


def test_own_measurement_processes_never_block_a_cleanup(project_root, tmp_path):
    home = tmp_path / "home"
    cache = home / "Library" / "Caches" / "ms-playwright"
    cache.mkdir(parents=True)
    (cache / "chromium").write_bytes(b"fixture")

    # storage_watch.sh runs hourly and sizes these very paths with du. Matching a
    # whole command line meant the tool's own measurement blocked the cleanup,
    # naming a process the owner cannot close.
    preview = run_cleanup(
        project_root,
        home,
        "--preview",
        "playwright_browsers",
        processes="/usr/bin/du -sk /Users/x/Library/Caches/ms-playwright\n",
    )

    assert parse_protocol(preview.stdout)["status"] == "ready"
    assert parse_protocol(preview.stdout)["runningProcesses"] == ""


def test_unrelated_headless_browser_does_not_block_playwright_cache(project_root, tmp_path):
    home = tmp_path / "home"
    browser = home / "Library" / "Caches" / "ms-playwright" / "chromium" / "chrome"
    browser.parent.mkdir(parents=True)
    browser.write_text("fixture", encoding="utf-8")

    # Electron 앱과 자동화 도구는 이 캐시와 무관하게 같은 Chromium 플래그를 쓴다.
    # 그 프로세스까지 차단하면 사용자는 브라우저 창을 모두 닫아도 차단을 풀 수 없다.
    preview = run_cleanup(
        project_root,
        home,
        "--preview",
        "playwright_browsers",
        processes=(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless\n"
            "/Applications/Kiro.app/Contents/MacOS/Kiro Helper --remote-debugging-pipe\n"
        ),
    )
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0
    assert payload["status"] == "ready"
    assert payload["runningProcesses"] == ""
    assert payload["estimateMeasured"] == "true"
    assert browser.exists()


def test_cleanup_rejects_symlinked_target(project_root, tmp_path):
    home = tmp_path / "home"
    outside = tmp_path / "outside"
    home.mkdir()
    outside.mkdir()
    protected_file = outside / "keep.txt"
    protected_file.write_text("keep", encoding="utf-8")
    (home / ".npm").symlink_to(outside, target_is_directory=True)

    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)

    assert payload["status"] == "blocked"
    assert protected_file.read_text(encoding="utf-8") == "keep"


def make_node_project(home: Path, name: str = "webapp") -> tuple[Path, Path]:
    project = home / "Projects" / name
    target = project / "node_modules"
    target.mkdir(parents=True)
    (target / "dependency.js").write_bytes(b"rebuildable" * 1024)
    (project / "package.json").write_text('{"name":"fixture"}\n', encoding="utf-8")
    (project / "package-lock.json").write_text('{"lockfileVersion":3}\n', encoding="utf-8")
    return project, target


def test_project_residue_preview_and_execute_preserve_project_evidence(
    project_root, tmp_path
):
    home = tmp_path / "home"
    project, target = make_node_project(home)

    preview = run_project_residue_preview(project_root, home, target)
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0, preview.stderr
    assert payload["status"] == "ready"
    assert payload["recipeId"] == "project_residue"
    assert payload["targets"] == [str(target)]
    expires_epoch = int(str(payload["approvalExpiresEpoch"]))
    assert time.time() < expires_epoch <= time.time() + 901
    token = approval_token(payload)

    executed = run_project_residue_execute(project_root, home, target, token)
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert not target.exists()
    assert (project / "package.json").is_file()
    assert (project / "package-lock.json").is_file()
    receipt = Path(str(result["receipt"]))
    assert receipt.is_file()
    assert f"target\t{target}" in receipt.read_text(encoding="utf-8")

    replayed = run_project_residue_execute(project_root, home, target, token)
    assert replayed.returncode == 3
    assert parse_protocol(replayed.stdout)["status"] == "blocked"


@pytest.mark.parametrize(
    ("basename", "marker", "lockfile"),
    [
        ("node_modules", "package.json", "pnpm-lock.yaml"),
        ("target", "Cargo.toml", "Cargo.lock"),
        (".build", "Package.swift", "Package.resolved"),
        ("build", "pubspec.yaml", "pubspec.lock"),
        ("build", "gradlew", "gradle.lockfile"),
        (".dart_tool", "pubspec.yaml", "pubspec.lock"),
        (".gradle", "gradlew", "gradle.lockfile"),
        ("Pods", "Podfile", "Podfile.lock"),
    ],
)
def test_project_residue_accepts_only_scanner_artifact_marker_pairs(
    project_root, tmp_path, basename, marker, lockfile
):
    home = tmp_path / "home"
    project = home / "Projects" / f"fixture-{basename.replace('.', 'dot')}"
    target = project / basename
    target.mkdir(parents=True)
    (target / "output.bin").write_bytes(b"generated")
    (project / marker).write_text("marker\n", encoding="utf-8")
    (project / lockfile).write_text("lock\n", encoding="utf-8")

    preview = run_project_residue_preview(project_root, home, target)
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0, preview.stderr
    assert payload["status"] == "ready"
    assert payload["targets"] == [str(target)]


def test_project_residue_request_is_bounded_fd_protocol_not_raw_path(
    project_root, tmp_path
):
    home = tmp_path / "home"
    _, target = make_node_project(home)

    raw_argv = run_cleanup(
        project_root, home, "--preview", "project_residue", str(target)
    )
    assert raw_argv.returncode == 64

    request_path = home / "request.tsv"
    request_path.write_bytes(project_residue_request(target))
    named_file = run_cleanup(
        project_root,
        home,
        "--preview",
        "project_residue",
        "--request-file",
        str(request_path),
    )
    assert named_file.returncode == 64

    oversized = run_project_residue_preview(
        project_root,
        home,
        target,
        request_data=project_residue_request(target) + b"x" * 4096,
    )
    assert oversized.returncode == 64


@pytest.mark.parametrize("condition", ["no_marker", "target_symlink", "traversal", "outside_home"])
def test_project_residue_rejects_unproven_or_out_of_bounds_target(
    project_root, tmp_path, condition
):
    home = tmp_path / "home"
    home.mkdir()
    protected = tmp_path / "protected"
    protected.mkdir()
    (protected / "keep.txt").write_text("keep", encoding="utf-8")

    if condition == "no_marker":
        target = home / "Projects" / "unknown" / "node_modules"
        target.mkdir(parents=True)
        (target / "data").write_text("keep", encoding="utf-8")
    elif condition == "target_symlink":
        project = home / "Projects" / "linked"
        project.mkdir(parents=True)
        (project / "package.json").write_text("{}", encoding="utf-8")
        target = project / "node_modules"
        target.symlink_to(protected, target_is_directory=True)
    elif condition == "traversal":
        container = home / "Projects" / "container"
        project = home / "Projects" / "escaped"
        container.mkdir(parents=True)
        project.mkdir()
        (project / "package.json").write_text("{}", encoding="utf-8")
        real_target = project / "node_modules"
        real_target.mkdir()
        (real_target / "data").write_text("keep", encoding="utf-8")
        target = Path(str(container / ".." / "escaped" / "node_modules"))
    else:
        # Exact prefix collision that previously passed `$target == $HOME_ROOT*`.
        outside_project = Path(str(home) + "-escape") / "webapp"
        target = outside_project / "node_modules"
        target.mkdir(parents=True)
        (target / "data").write_text("keep", encoding="utf-8")
        (outside_project / "package.json").write_text("{}", encoding="utf-8")

    preview = run_project_residue_preview(project_root, home, target)
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0, preview.stderr
    assert payload["status"] == "blocked"
    assert Path(target).exists()
    assert (protected / "keep.txt").read_text(encoding="utf-8") == "keep"


def test_project_residue_rejects_tracked_target_and_broken_git_check(
    project_root, tmp_path
):
    tracked_home = tmp_path / "tracked-home"
    project, target = make_node_project(tracked_home)
    subprocess.run(["/usr/bin/git", "init", str(project)], check=True, capture_output=True)
    subprocess.run(
        ["/usr/bin/git", "-C", str(project), "add", "node_modules/dependency.js"],
        check=True,
        capture_output=True,
    )

    tracked = run_project_residue_preview(project_root, tracked_home, target)
    assert tracked.returncode == 0, tracked.stderr
    assert parse_protocol(tracked.stdout)["status"] == "blocked"
    assert target.exists()

    broken_home = tmp_path / "broken-home"
    broken_project, broken_target = make_node_project(broken_home)
    (broken_project / ".git").write_text(
        "gitdir: /definitely/missing/modore-test-gitdir\n", encoding="utf-8"
    )
    broken = run_project_residue_preview(
        project_root, broken_home, broken_target
    )
    assert broken.returncode == 0, broken.stderr
    assert parse_protocol(broken.stdout)["status"] == "blocked"
    assert broken_target.exists()


@pytest.mark.parametrize("drift", ["marker", "lock", "target"])
def test_project_residue_consumes_approval_when_evidence_drifts(
    project_root, tmp_path, drift
):
    home = tmp_path / "home"
    project, target = make_node_project(home)
    preview = run_project_residue_preview(project_root, home, target)
    payload = parse_protocol(preview.stdout)
    assert payload["status"] == "ready"
    token = approval_token(payload)

    if drift == "marker":
        (project / "package.json").write_text('{"name":"changed"}\n', encoding="utf-8")
    elif drift == "lock":
        (project / "package-lock.json").write_text('{"lockfileVersion":2}\n', encoding="utf-8")
    else:
        (target / "new-output.bin").write_bytes(b"changed" * 2048)

    executed = run_project_residue_execute(project_root, home, target, token)
    result = parse_protocol(executed.stdout)
    assert executed.returncode == 3
    assert result["status"] == "blocked"
    assert target.exists()

    replayed = run_project_residue_execute(project_root, home, target, token)
    assert replayed.returncode == 3
    assert "일회성 실행으로 잠그지 못했습니다" in str(
        parse_protocol(replayed.stdout)["blockedReason"]
    )


def test_project_residue_request_mismatch_consumes_approval(project_root, tmp_path):
    home = tmp_path / "home"
    _, first_target = make_node_project(home, "first")
    _, second_target = make_node_project(home, "second")
    preview = run_project_residue_preview(project_root, home, first_target)
    token = approval_token(parse_protocol(preview.stdout))

    mismatched = run_project_residue_execute(
        project_root, home, second_target, token
    )
    assert mismatched.returncode == 3
    assert parse_protocol(mismatched.stdout)["status"] == "blocked"
    assert first_target.exists() and second_target.exists()

    replayed = run_project_residue_execute(
        project_root, home, first_target, token
    )
    assert replayed.returncode == 3


def test_project_residue_blocks_process_that_names_the_project(project_root, tmp_path):
    home = tmp_path / "home"
    project, target = make_node_project(home)
    preview = run_project_residue_preview(
        project_root,
        home,
        target,
        processes=f"/usr/bin/node {project}/scripts/build.js\n",
    )
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0, preview.stderr
    assert payload["status"] == "blocked"
    assert "Node/npm" in str(payload["runningProcesses"])
    assert target.exists()


@pytest.mark.parametrize(
    ("basename", "marker", "command", "display_name"),
    [
        ("node_modules", "package.json", "/usr/local/bin/npm install", "Node/npm"),
        ("target", "Cargo.toml", "/Users/test/.cargo/bin/cargo build", "Cargo/Rust"),
        (".build", "Package.swift", "/usr/bin/swift build", "Swift build"),
        ("build", "pubspec.yaml", "/opt/flutter/bin/flutter build macos", "Dart/Flutter"),
        ("Pods", "Podfile", "/opt/homebrew/bin/pod install", "CocoaPods"),
        (".gradle", "gradlew", "./gradlew assemble", "Gradle"),
    ],
)
def test_project_residue_blocks_real_build_command_running_from_project_cwd(
    project_root, tmp_path, basename, marker, command, display_name
):
    home = tmp_path / "home"
    project = home / "Projects" / "active-build"
    target = project / basename
    target.mkdir(parents=True)
    (target / "output.bin").write_bytes(b"generated")
    (project / marker).write_text("marker\n", encoding="utf-8")

    preview = run_project_residue_preview(
        project_root,
        home,
        target,
        processes_with_pid=f"4242 {command}\n",
        process_cwds=f"4242\t{project}\n",
    )
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0, preview.stderr
    assert payload["status"] == "blocked"
    assert display_name in str(payload["runningProcesses"])
    assert target.exists()


def test_project_residue_does_not_block_same_tool_in_another_project_cwd(
    project_root, tmp_path
):
    home = tmp_path / "home"
    project, target = make_node_project(home)
    other_project = home / "Projects" / "other"
    other_project.mkdir()
    (other_project / "package.json").write_text("{}", encoding="utf-8")

    preview = run_project_residue_preview(
        project_root,
        home,
        target,
        processes_with_pid="4242 /usr/local/bin/npm install\n",
        process_cwds=f"4242\t{other_project}\n",
    )
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0, preview.stderr
    assert payload["status"] == "ready"
    assert payload["runningProcesses"] == ""


def test_execute_rejects_target_drift_and_consumed_approval(project_root, tmp_path):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "_cacache" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"x" * 8192)

    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)
    token = approval_token(payload)
    cache_file.write_bytes(b"x" * (2 * 1024 * 1024))

    drifted = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        token,
    )

    assert drifted.returncode == 3
    assert parse_protocol(drifted.stdout)["status"] == "blocked"
    assert cache_file.exists()

    replayed_blocked_attempt = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        token,
    )
    approvals = (
        home
        / "Library"
        / "Application Support"
        / "Modore"
        / "cleanup-approvals"
    )
    assert replayed_blocked_attempt.returncode == 3
    assert "일회성 실행으로 잠그지 못했습니다" in str(
        parse_protocol(replayed_blocked_attempt.stdout)["blockedReason"]
    )
    assert not (approvals / f"{token}.tsv").exists()
    assert not list(approvals.glob(f".executing-{token}-*.tsv"))

    refreshed = run_cleanup(project_root, home, "--preview", "npm_cache")
    refreshed_payload = parse_protocol(refreshed.stdout)
    refreshed_token = approval_token(refreshed_payload)
    completed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        refreshed_token,
    )
    assert completed.returncode == 0, completed.stderr

    replayed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        refreshed_token,
    )
    assert replayed.returncode == 3


def test_destructive_rename_rechecks_recursive_size_immediately_before_move(
    project_root, tmp_path
):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"fixture")
    late_content = home / "late-content.bin"
    late_content.write_bytes(b"x" * (2 * 1024 * 1024))
    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env={
            "PCH_TEST_LATE_CONTENT_AT": "1",
            "PCH_TEST_LATE_CONTENT_FILE": str(late_content),
        },
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 3
    assert result["status"] == "blocked"
    assert cache_file.exists()
    assert (home / ".npm" / ".pch-test-late-content").is_file()
    assert not result["trashRun"]


def test_expired_approval_is_consumed_without_cleanup(project_root, tmp_path):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"fixture")
    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)
    token = approval_token(payload)
    manifest = (
        home
        / "Library"
        / "Application Support"
        / "Modore"
        / "cleanup-approvals"
        / f"{token}.tsv"
    )
    lines = manifest.read_text(encoding="utf-8").splitlines()
    manifest.write_text(
        "\n".join("createdEpoch\t1" if line.startswith("createdEpoch\t") else line for line in lines)
        + "\n",
        encoding="utf-8",
    )

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        token,
    )

    assert executed.returncode == 3
    assert cache_file.exists()
    assert not manifest.exists()


def test_failed_staged_removal_reports_private_recovery_path(project_root, tmp_path):
    home = tmp_path / "home"
    cache_file = home / ".npm" / "entry"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"fixture")
    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)
    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env={"PCH_TEST_FAIL_STAGED_REMOVE_AT": "1"},
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 4
    assert result["status"] == "partial"
    assert len(result["stagedRemainders"]) == 1
    staged = Path(str(result["stagedRemainders"][0]))
    assert staged.is_dir()
    assert (staged / "entry").is_file()
    assert stat.S_IMODE(staged.parent.stat().st_mode) == 0o700
    receipt = Path(str(result["receipt"]))
    assert f"stagedRemainder\t{staged}" in receipt.read_text(encoding="utf-8")


def test_staged_destination_swap_preserves_replacement_and_approved_object(
    project_root, tmp_path
):
    home = tmp_path / "home"
    approved = home / ".npm"
    approved.mkdir(parents=True)
    (approved / "approved.txt").write_text("approved", encoding="utf-8")
    replacement = home / "replacement"
    replacement.mkdir(parents=True)
    (replacement / "replacement.txt").write_text("replacement", encoding="utf-8")
    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    token = approval_token(parse_protocol(preview.stdout))

    executed = run_cleanup_with_token_file(
        project_root,
        home,
        "npm_cache",
        token,
        extra_env={
            "PCH_TEST_SWAP_STAGED_DESTINATION_AT": "1",
            "PCH_TEST_SWAP_STAGED_DESTINATION_WITH": str(replacement),
        },
    )
    result = parse_protocol(executed.stdout)
    remainders = [Path(str(path)) for path in result["stagedRemainders"]]

    assert executed.returncode == 4, executed.stderr
    assert result["status"] == "partial"
    assert "삭제 직전에 교체" in str(result["blockedReason"])
    assert len(remainders) == 2
    assert all(path.exists() for path in remainders)
    assert any((path / "replacement.txt").is_file() for path in remainders)
    assert any((path / "approved.txt").is_file() for path in remainders)
    assert token not in executed.stdout
    receipt = Path(str(result["receipt"]))
    receipt_text = receipt.read_text(encoding="utf-8")
    assert all(f"stagedRemainder\t{path}" in receipt_text for path in remainders)


def test_execute_rechecks_processes_at_destructive_boundary(project_root, tmp_path):
    home = tmp_path / "home"
    browser = home / "Library" / "Caches" / "ms-playwright" / "chromium" / "chrome"
    browser.parent.mkdir(parents=True)
    browser.write_text("fixture", encoding="utf-8")
    late_processes = home / "late-processes.txt"
    late_processes.write_text(
        "/opt/pw/ms-playwright/chromium-9999/headless_shell\n", encoding="utf-8"
    )

    preview = run_cleanup(project_root, home, "--preview", "playwright_browsers")
    payload = parse_protocol(preview.stdout)
    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "playwright_browsers",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env={"PCH_TEST_LATE_PROCESS_LIST_FILE": str(late_processes)},
    )

    assert executed.returncode == 3
    assert parse_protocol(executed.stdout)["status"] == "blocked"
    assert browser.exists()


def test_cleanup_never_follows_last_moment_symlink_swap(project_root, tmp_path):
    home = tmp_path / "home"
    cache_root = home / ".npm"
    cache_root.mkdir(parents=True)
    (cache_root / "cache.bin").write_bytes(b"x" * 8192)
    outside = home / "outside"
    outside.mkdir()
    protected_file = outside / "keep.txt"
    protected_file.write_text("keep", encoding="utf-8")

    preview = run_cleanup(project_root, home, "--preview", "npm_cache")
    payload = parse_protocol(preview.stdout)
    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "npm_cache",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env={"PCH_TEST_SWAP_TARGET_WITH_SYMLINK_TO": str(outside)},
    )

    assert executed.returncode == 3
    assert protected_file.read_text(encoding="utf-8") == "keep"


def test_cleanup_has_no_recipe_for_session_history(project_root, tmp_path):
    home = tmp_path / "home"
    session = home / ".codex" / "sessions" / "history.jsonl"
    session.parent.mkdir(parents=True)
    session.write_text("{}\n", encoding="utf-8")

    result = run_cleanup(project_root, home, "--preview", "codex_session_history")

    assert result.returncode == 64
    assert "허용되지 않은 recipe ID" in result.stderr
    assert session.read_text(encoding="utf-8") == "{}\n"


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("PCH_HOME_OVERRIDE", str(Path.home())),
        ("PCH_APPLICATIONS_ROOT_OVERRIDE", "/Applications"),
        ("PCH_VAR_FOLDERS_ROOT_OVERRIDE", "/private/var/folders"),
        ("PCH_PROCESS_LIST_FILE", "/tmp/outside-process-list"),
        ("PCH_SIMCTL_LIST_FILE", "/tmp/outside-simctl-list"),
        ("PCH_SIMCTL_DELETE_LOG", "/tmp/outside-delete-log"),
        ("PCH_TEST_LATE_PROCESS_LIST_FILE", "/tmp/outside-late-process-list"),
        ("PCH_TEST_LATE_SIMCTL_LIST_FILE", "/tmp/outside-late-simctl-list"),
        ("PCH_TEST_LATE_SIMULATOR_KEEP_FILE", "/tmp/outside-late-keep-list"),
        ("PCH_TEST_LATE_CONTENT_FILE", "/tmp/outside-late-content"),
        ("PCH_TEST_SWAP_TARGET_WITH_SYMLINK_TO", "/tmp"),
        ("PCH_TEST_SWAP_STAGED_DESTINATION_WITH", "/tmp"),
    ],
)
def test_test_hooks_cannot_escape_isolated_home(project_root, tmp_path, key, value):
    home = tmp_path / "home"
    (home / ".npm").mkdir(parents=True)

    result = run_cleanup(
        project_root,
        home,
        "--preview",
        "npm_cache",
        extra_env={key: value},
    )

    assert result.returncode == 64
    assert (home / ".npm").is_dir()


def test_production_home_must_match_current_account(project_root, tmp_path):
    fake_home = tmp_path / "fake-home"
    (fake_home / ".npm").mkdir(parents=True)
    env = os.environ.copy()
    env["HOME"] = str(fake_home)
    env.pop("PCH_TEST_MODE", None)

    result = subprocess.run(
        [str(project_root / "scripts" / "cleanup.sh"), "--preview", "npm_cache"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
    )

    assert result.returncode == 64
    assert (fake_home / ".npm").is_dir()


@pytest.mark.parametrize("recipe", ["user_caches", "cli_tool_caches"])
def test_broad_cache_roots_are_manual_review_only(project_root, tmp_path, recipe):
    home = tmp_path / "home"
    cache_root = home / "Library" / "Caches"
    (cache_root / "normal").mkdir(parents=True)
    (cache_root / ".hidden").write_text("fixture", encoding="utf-8")
    (cache_root / "normal" / "item").write_text("fixture", encoding="utf-8")

    result = run_cleanup(project_root, home, "--preview", recipe)

    assert result.returncode == 64
    assert "허용되지 않은 recipe ID" in result.stderr
    assert cache_root.is_dir()
    assert (cache_root / ".hidden").is_file()
    assert (cache_root / "normal" / "item").is_file()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_app_uninstall_moves_verified_bundle_and_exact_residue_to_trash(project_root, tmp_path):
    home = tmp_path / "home"
    app = home / "ApplicationsRoot" / "Example App.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleIdentifier": "me.example.cleanup",
                "CFBundleName": "Example App",
                "CFBundleExecutable": "ExampleApp",
            },
            handle,
        )
    (app / "Contents" / "MacOS").mkdir()
    (app / "Contents" / "MacOS" / "ExampleApp").write_text("fixture", encoding="utf-8")
    residue = home / "Library" / "Caches" / "me.example.cleanup"
    residue.mkdir(parents=True)
    (residue / "cache").write_text("fixture", encoding="utf-8")

    preview = run_cleanup(project_root, home, "--preview", "app_uninstall:me.example.cleanup")
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0, preview.stderr
    assert payload["status"] == "ready"
    assert payload["actionMode"] == "trash"
    assert str(app) in payload["targets"]
    assert str(residue) in payload["targets"]
    assert app.exists() and residue.exists()

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "app_uninstall:me.example.cleanup",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert not app.exists()
    assert not residue.exists()
    trash_run = Path(str(result["trashRun"]))
    assert trash_run.is_dir()
    assert len(list(trash_run.iterdir())) == 2


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
@pytest.mark.parametrize("failure_index", [1, 2])
def test_app_uninstall_rolls_back_when_any_move_fails(
    project_root, tmp_path, failure_index
):
    home = tmp_path / "home"
    app = home / "ApplicationsRoot" / "Transactional App.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleIdentifier": "me.example.transactional",
                "CFBundleExecutable": "TransactionalApp",
            },
            handle,
        )
    residue = home / "Library" / "Caches" / "me.example.transactional"
    residue.mkdir(parents=True)
    (residue / "cache").write_text("fixture", encoding="utf-8")

    preview = run_cleanup(
        project_root, home, "--preview", "app_uninstall:me.example.transactional"
    )
    payload = parse_protocol(preview.stdout)
    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "app_uninstall:me.example.transactional",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env={"PCH_TEST_FAIL_TRASH_MOVE_AT": str(failure_index)},
    )

    assert executed.returncode == 3
    assert parse_protocol(executed.stdout)["status"] == "blocked"
    assert app.is_dir()
    assert residue.is_dir()


def test_rollback_trash_transaction_reports_items_it_could_not_restore(project_root, tmp_path):
    """If rollback_single_move itself fails partway through undoing a
    transaction (e.g. something now occupies the original path), the item
    stays at its staged trash destination -- exactly the "content survives
    somewhere, but not where it should" state every other partial-failure
    path in cleanup.sh already reports via STAGED_REMAINDERS/stagedRemainder.
    Before this fix, a failed rollback was invisible: the receipt would say
    "partial" but STAGED_REMAINDERS stayed empty, giving the caller nothing
    to act on -- worse information than a *successful* rollback, which gets
    a specific human-readable reason.

    Extracts the real rollback_single_move/record_staged_remainder/
    rollback_trash_transaction functions by line range (not a hand-
    duplicated copy) and drives them directly with two moved items: one
    that rolls back cleanly, one that can't because its original path was
    reoccupied in the meantime."""
    source_lines = (project_root / "scripts" / "cleanup.sh").read_text(encoding="utf-8").splitlines()

    def extract(start_marker, end_marker):
        start = next(i for i, line in enumerate(source_lines) if line.startswith(start_marker))
        end = next(i for i, line in enumerate(source_lines[start:], start) if line == end_marker) + 1
        return "\n".join(source_lines[start:end])

    rollback_single_move_src = extract("rollback_single_move() {", "}")
    record_staged_remainder_src = extract("record_staged_remainder() {", "}")
    rollback_trash_transaction_src = extract("rollback_trash_transaction() {", "}")
    for src in (rollback_single_move_src, record_staged_remainder_src, rollback_trash_transaction_src):
        assert src.endswith("}"), "extraction boundary moved; update this test"

    home = tmp_path / "home"
    home.mkdir()
    # Item 1: rolls back cleanly -- original path is empty, staged copy exists.
    source1 = home / "clean-rollback-original"
    destination1 = home / "clean-rollback-staged"
    destination1.write_text("clean payload", encoding="utf-8")
    # Item 2: cannot roll back -- something reoccupied the original path
    # after the move but before the rollback attempt.
    source2 = home / "blocked-rollback-original"
    source2.write_text("something else appeared here", encoding="utf-8")
    destination2 = home / "blocked-rollback-staged"
    destination2.write_text("stranded payload", encoding="utf-8")

    journal_path = tmp_path / "journal.tsv"
    harness_path = tmp_path / "rollback-harness.sh"
    harness_path.write_text(
        f"""#!/bin/bash
set -u
{rollback_single_move_src}

{record_staged_remainder_src}

{rollback_trash_transaction_src}

MOVED_SOURCES=("{source1}" "{source2}")
MOVED_DESTINATIONS=("{destination1}" "{destination2}")
MOVED_TARGETS=("x -> {destination1}" "x -> {destination2}")
MOVED_TARGETS_COUNT=2
STAGED_REMAINDERS=()

exec 9> "{journal_path}"
rollback_trash_transaction
ec=$?
exec 9>&-

echo "EXIT=$ec"
echo "REMAINDER_COUNT=${{#STAGED_REMAINDERS[@]}}"
for r in "${{STAGED_REMAINDERS[@]:-}}"; do
    echo "REMAINDER=$r"
done
""",
        encoding="utf-8",
    )
    harness_path.chmod(0o700)

    result = subprocess.run(["/bin/bash", str(harness_path)], capture_output=True, text=True, encoding="utf-8", timeout=10)
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    assert "EXIT=1" in result.stdout, "a partially-failed rollback must report failure, not silent success"
    assert "REMAINDER_COUNT=1" in result.stdout, f"expected exactly one stranded item, got:\n{result.stdout}"
    assert f"REMAINDER={destination2}" in result.stdout, "the item that could not be restored must be the one recorded"
    assert f"REMAINDER={destination1}" not in result.stdout, "the item that rolled back cleanly must not be reported as stranded"

    # The clean item actually rolled back: content is back at its original path.
    assert source1.read_text(encoding="utf-8") == "clean payload"
    assert not destination1.exists()
    # The blocked item's pre-existing content at the original path is untouched
    # (never clobbered), and its staged copy is still there -- recoverable via
    # the stagedRemainder path the receipt will carry.
    assert source2.read_text(encoding="utf-8") == "something else appeared here"
    assert destination2.read_text(encoding="utf-8") == "stranded payload"

    journal = journal_path.read_text(encoding="utf-8")
    assert "status\trollback-failed" in journal


def test_write_receipt_strips_embedded_tabs_from_target_paths(project_root, tmp_path):
    """A path containing a literal tab character (unusual, but the
    filesystem doesn't forbid it) used to go straight into the TSV row
    unsanitized for target/moved/stagedRemainder -- unlike the label field a
    few lines above it, which already strips tabs/CR/LF for exactly this
    reason. An embedded tab silently injects an extra column into that row,
    corrupting the field alignment for anyone parsing the receipt back.

    Extracts the real prepare_private_directory/write_receipt functions by
    line range and drives write_receipt directly with a target path that
    contains an embedded tab, checking the emitted line has exactly the two
    tab-separated fields (key, sanitized value) a TSV row must have."""
    def extract(path, start_marker):
        source_lines = path.read_text(encoding="utf-8").splitlines()
        start = next(i for i, line in enumerate(source_lines) if line.startswith(start_marker))
        end = next(i for i, line in enumerate(source_lines[start:], start) if line == "}") + 1
        return "\n".join(source_lines[start:end])

    # prepare_private_directory now lives in the shared approval_token.sh
    # module (cleanup.sh and login_items.sh both source it) rather than in
    # cleanup.sh itself -- see that module's own header comment for why.
    prepare_private_directory_src = extract(
        project_root / "scripts" / "modules" / "approval_token.sh", "prepare_private_directory() {"
    )
    write_receipt_src = extract(project_root / "scripts" / "cleanup.sh", "write_receipt() {")
    for src in (prepare_private_directory_src, write_receipt_src):
        assert src.endswith("}"), "extraction boundary moved; update this test"

    home = tmp_path / "home"
    home.mkdir()
    receipt_dir = home / "receipts"
    tabby_target = "/tmp/weird\tdirectory/with-a-tab"

    harness_path = tmp_path / "receipt-harness.sh"
    harness_path.write_text(
        f"""#!/bin/bash
set -u
PROTOCOL_VERSION="1"
RECEIPT_DIR="{receipt_dir}"
RECIPE_ID="npm_cache"
LABEL="npm 캐시"
REMOVE_MODE="trash"
TRASH_RUN="{tmp_path}/trash-run"
TARGETS=("{tabby_target}")
MOVED_TARGETS_COUNT=0
MOVED_TARGETS=()
STAGED_REMAINDERS=()

{prepare_private_directory_src}

{write_receipt_src}

write_receipt "complete" 100 100 100
echo "RECEIPT_PATH=$RECEIPT_PATH"
""",
        encoding="utf-8",
    )
    harness_path.chmod(0o700)

    result = subprocess.run(["/bin/bash", str(harness_path)], capture_output=True, text=True, encoding="utf-8", timeout=10)
    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    receipt_path_line = next(line for line in result.stdout.splitlines() if line.startswith("RECEIPT_PATH="))
    receipt_path = Path(receipt_path_line.split("=", 1)[1])
    receipt_text = receipt_path.read_text(encoding="utf-8")

    target_line = next(line for line in receipt_text.splitlines() if line.startswith("target\t"))
    fields = target_line.split("\t")
    assert len(fields) == 2, f"embedded tab injected an extra TSV column: {fields!r}"
    assert fields[1] == "/tmp/weirddirectory/with-a-tab"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS plist tools are required")
def test_app_uninstall_only_attributes_structurally_matching_launch_agent(
    project_root, tmp_path
):
    home = tmp_path / "home"
    app = home / "ApplicationsRoot" / "Example App.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump(
            {
                "CFBundleIdentifier": "me.example.owner",
                "CFBundleExecutable": "ExampleApp",
            },
            handle,
        )
    agents = home / "Library" / "LaunchAgents"
    agents.mkdir(parents=True)
    owned = agents / "me.example.owner.plist"
    unrelated = agents / "unrelated.plist"
    with owned.open("wb") as handle:
        plistlib.dump({"Label": "me.example.owner", "Program": "/usr/bin/true"}, handle)
    with unrelated.open("wb") as handle:
        plistlib.dump(
            {
                "Label": "unrelated.agent",
                "ProgramArguments": ["/usr/bin/printf", "me.example.owner"],
            },
            handle,
        )

    preview = run_cleanup(project_root, home, "--preview", "app_uninstall:me.example.owner")
    payload = parse_protocol(preview.stdout)

    assert str(owned) in payload["targets"]
    assert str(unrelated) not in payload["targets"]


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_xcode_bundle_ids_are_blocked_at_cleanup_script_boundary(project_root, tmp_path):
    home = tmp_path / "home"
    app = home / "ApplicationsRoot" / "Xcode.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": "com.apple.dt.Xcode"}, handle)

    result = run_cleanup(
        project_root, home, "--preview", "app_uninstall:com.apple.dt.Xcode"
    )

    assert result.returncode == 64
    assert app.is_dir()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_dynamic_app_recipe_blocks_embedded_developer_payload(project_root, tmp_path):
    home = tmp_path / "home"
    bundle_id = "me.example.custom-developer-suite"
    app = home / "ApplicationsRoot" / "Custom Developer Suite.app"
    info = app / "Contents" / "Info.plist"
    platforms = app / "Contents" / "Developer" / "Platforms"
    platforms.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)
    (platforms / "SDK.marker").write_text("protected", encoding="utf-8")

    result = run_cleanup(project_root, home, "--preview", f"app_uninstall:{bundle_id}")

    assert result.returncode == 64
    assert "허용되지 않은 recipe ID" in result.stderr
    assert (platforms / "SDK.marker").is_file()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_app_uninstall_excludes_prefix_matched_http_storage(project_root, tmp_path):
    home = tmp_path / "home"
    bundle_id = "me.example.owner"
    app = home / "ApplicationsRoot" / "Example App.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)
    exact = home / "Library" / "HTTPStorages" / bundle_id
    prefix_collision = home / "Library" / "HTTPStorages" / f"{bundle_id}.other-app"
    exact.mkdir(parents=True)
    prefix_collision.mkdir(parents=True)

    preview = run_cleanup(project_root, home, "--preview", f"app_uninstall:{bundle_id}")
    payload = parse_protocol(preview.stdout)

    assert str(exact) in payload["targets"]
    assert str(prefix_collision) not in payload["targets"]


def test_simulator_recipe_honors_keep_list_and_deletes_only_verified_uuid(project_root, tmp_path):
    home = tmp_path / "home"
    uuid = "11111111-2222-3333-4444-555555555555"
    device = home / "Library" / "Developer" / "CoreSimulator" / "Devices" / uuid
    device.mkdir(parents=True)
    (device / "data.bin").write_bytes(b"fixture")
    sibling_uuid = "66666666-7777-4888-9999-AAAAAAAAAAAA"
    sibling = device.parent / sibling_uuid
    sibling.mkdir()
    (sibling / "must-stay.bin").write_bytes(b"sibling fixture")
    support = home / "Library" / "Application Support" / "Modore"
    support.mkdir(parents=True)
    keep_file = support / "simulator-keep.txt"
    keep_file.write_text("iPhone 17 Pro Max\n", encoding="utf-8")
    simctl_list = home / "simctl.txt"
    simctl_list.write_text(
        "== Devices ==\n-- iOS 26.3 --\n"
        f"    iPhone 17 Pro Max ({uuid}) (Shutdown)\n"
        f"    Sibling Phone ({sibling_uuid}) (Shutdown)\n",
        encoding="utf-8",
    )
    delete_log = home / "simctl-delete.log"
    extra_env = {
        "PCH_SIMCTL_LIST_FILE": str(simctl_list),
        "PCH_SIMCTL_DELETE_LOG": str(delete_log),
    }

    legacy = run_cleanup(
        project_root,
        home,
        "--preview",
        f"simulator_delete:{uuid}",
        extra_env=extra_env,
    )
    legacy_payload = parse_protocol(legacy.stdout)
    assert legacy_payload["status"] == "blocked"
    assert "UUID 형식" in str(legacy_payload["blockedReason"])
    assert device.exists()

    keep_file.write_text(f"{uuid.lower()}\n", encoding="utf-8")
    protected = run_cleanup(
        project_root,
        home,
        "--preview",
        f"simulator_delete:{uuid}",
        extra_env=extra_env,
    )
    protected_payload = parse_protocol(protected.stdout)
    assert protected_payload["status"] == "blocked"
    assert "보존 목록" in str(protected_payload["blockedReason"])
    assert device.exists()

    keep_file.unlink()
    ready = run_cleanup(
        project_root,
        home,
        "--preview",
        f"simulator_delete:{uuid}",
        extra_env=extra_env,
    )
    ready_payload = parse_protocol(ready.stdout)
    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        f"simulator_delete:{uuid}",
        "--owner-approved",
        "--approval-token",
        approval_token(ready_payload),
        extra_env=extra_env,
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert result["actionMode"] == "simulator"
    assert not device.exists()
    assert (sibling / "must-stay.bin").read_bytes() == b"sibling fixture"
    assert delete_log.read_text(encoding="utf-8").strip() == uuid


@pytest.mark.parametrize("state", ["Booted", "Creating", "Shutting Down"])
def test_simulator_preview_allows_only_shutdown_devices(project_root, tmp_path, state):
    home = tmp_path / "home"
    uuid = "12345678-1234-4234-8234-123456789ABC"
    device = home / "Library/Developer/CoreSimulator/Devices" / uuid
    device.mkdir(parents=True)
    simctl_list = home / "simctl.txt"
    simctl_list.write_text(
        f"-- iOS 27.0 --\n    State Phone ({uuid}) ({state})\n",
        encoding="utf-8",
    )

    preview = run_cleanup(
        project_root,
        home,
        "--preview",
        f"simulator_delete:{uuid}",
        extra_env={"PCH_SIMCTL_LIST_FILE": str(simctl_list)},
    )
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0, preview.stderr
    assert payload["status"] == "blocked"
    assert state in str(payload["blockedReason"])
    assert device.is_dir()


@pytest.mark.parametrize(
    "keep_shape", ["symlink", "hardlink", "oversized", "unreadable", "many-lines"]
)
def test_simulator_preview_fails_closed_for_untrusted_keep_files(
    project_root, tmp_path, keep_shape
):
    home = tmp_path / "home"
    uuid = "12345678-1234-4234-8234-123456789ABC"
    device = home / "Library/Developer/CoreSimulator/Devices" / uuid
    device.mkdir(parents=True)
    support = home / "Library/Application Support/Modore"
    support.mkdir(parents=True)
    keep = support / "simulator-keep.txt"
    source = support / "keep-source.txt"
    source.write_text("", encoding="utf-8")
    if keep_shape == "symlink":
        keep.symlink_to(source)
    elif keep_shape == "hardlink":
        os.link(source, keep)
    elif keep_shape == "oversized":
        keep.write_bytes(b"x" * 65537)
    elif keep_shape == "many-lines":
        keep.write_text("\n" * 5000, encoding="utf-8")
    else:
        keep.write_text("", encoding="utf-8")
        keep.chmod(0)
    simctl_list = home / "simctl.txt"
    simctl_list.write_text(
        f"-- iOS 27.0 --\n    Protected Phone ({uuid}) (Shutdown)\n",
        encoding="utf-8",
    )

    preview = run_cleanup(
        project_root,
        home,
        "--preview",
        f"simulator_delete:{uuid}",
        extra_env={"PCH_SIMCTL_LIST_FILE": str(simctl_list)},
    )
    payload = parse_protocol(preview.stdout)

    assert preview.returncode == 0, preview.stderr
    assert payload["status"] == "blocked"
    assert "안전하게 읽을 수 없어" in str(payload["blockedReason"])
    assert device.is_dir()


@pytest.mark.parametrize(
    ("late_condition", "reason_fragment"),
    [
        ("booted", "Booted"),
        ("preserved", "보존 목록"),
        ("legacy", "이름 기반"),
        ("invalid", "안전하게 읽을 수 없어"),
    ],
)
def test_simulator_delete_rechecks_state_and_keep_file_at_final_boundary(
    project_root, tmp_path, late_condition, reason_fragment
):
    home = tmp_path / "home"
    uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    device = home / "Library" / "Developer" / "CoreSimulator" / "Devices" / uuid
    device.mkdir(parents=True)
    (device / "data.bin").write_bytes(b"fixture")
    support = home / "Library" / "Application Support" / "Modore"
    support.mkdir(parents=True)
    simctl_list = home / "simctl.txt"
    simctl_list.write_text(
        "== Devices ==\n-- iOS 26.3 --\n"
        f"    Boundary Phone ({uuid}) (Shutdown)\n",
        encoding="utf-8",
    )
    delete_log = home / "simctl-delete.log"
    extra_env = {
        "PCH_SIMCTL_LIST_FILE": str(simctl_list),
        "PCH_SIMCTL_DELETE_LOG": str(delete_log),
    }

    if late_condition == "booted":
        late_simctl = home / "late-simctl.txt"
        late_simctl.write_text(
            "== Devices ==\n-- iOS 26.3 --\n"
            f"    Boundary Phone ({uuid}) (Booted)\n",
            encoding="utf-8",
        )
        extra_env["PCH_TEST_LATE_SIMCTL_LIST_FILE"] = str(late_simctl)
    else:
        late_keep = home / "late-keep.txt"
        if late_condition == "invalid":
            late_keep.write_bytes(b"x" * 65537)
        else:
            late_keep.write_text(
                f"{uuid.lower()}\n"
                if late_condition == "preserved"
                else "Boundary Phone\n",
                encoding="utf-8",
            )
        extra_env["PCH_TEST_LATE_SIMULATOR_KEEP_FILE"] = str(late_keep)

    preview = run_cleanup(
        project_root,
        home,
        "--preview",
        f"simulator_delete:{uuid}",
        extra_env={
            "PCH_SIMCTL_LIST_FILE": str(simctl_list),
            "PCH_SIMCTL_DELETE_LOG": str(delete_log),
        },
    )
    payload = parse_protocol(preview.stdout)
    assert payload["status"] == "ready"

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        f"simulator_delete:{uuid}",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env=extra_env,
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 3
    assert result["status"] == "blocked"
    assert reason_fragment in str(result["blockedReason"])
    assert device.is_dir()
    assert not delete_log.exists()


def test_simulator_delete_postcondition_check_detects_leftover_data(project_root, tmp_path):
    home = tmp_path / "home"
    uuid = "ABCDEF12-3456-4789-8ABC-DEF123456789"
    device = home / "Library/Developer/CoreSimulator/Devices" / uuid
    device.mkdir(parents=True)
    (device / "leftover.bin").write_bytes(b"leftover device data")
    simctl_list = home / "simctl.txt"
    simctl_list.write_text(
        f"-- iOS 27.0 --\n    Leftover Phone ({uuid}) (Shutdown)\n",
        encoding="utf-8",
    )
    calls = home / "fake-simctl.calls"
    fake_simctl = home / "fake-simctl"
    fake_simctl.write_text(
        "#!/bin/bash\n"
        f'printf "%s\\n" "$*" >> "{calls}"\n'
        "exit 0\n",
        encoding="utf-8",
    )
    fake_simctl.chmod(0o700)
    preview = run_cleanup(
        project_root,
        home,
        "--preview",
        f"simulator_delete:{uuid}",
        extra_env={"PCH_SIMCTL_LIST_FILE": str(simctl_list)},
    )
    payload = parse_protocol(preview.stdout)
    assert payload["status"] == "ready"

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        f"simulator_delete:{uuid}",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
        extra_env={
            "PCH_SIMCTL_LIST_FILE": str(simctl_list),
            "PCH_TEST_SIMCTL_DELETE_BIN": str(fake_simctl),
        },
    )
    result = parse_protocol(executed.stdout)

    assert executed.returncode == 4
    assert result["status"] == "partial"
    assert result["reclaimedKB"] == "0"
    assert "실제로 지워지지 않았습니다" in str(result["blockedReason"])
    assert (device / "leftover.bin").read_bytes() == b"leftover device data"
    assert calls.read_text(encoding="utf-8").strip() == f"delete {uuid}"


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_app_uninstall_collects_bundle_keyed_residue_created_after_install(
    project_root, tmp_path
):
    home = tmp_path / "home"
    bundle_id = "me.example.ledger"
    app = home / "ApplicationsRoot" / "Ledger App.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)
    cookies = home / "Library" / "Cookies" / f"{bundle_id}.binarycookies"
    storage_cookies = (
        home / "Library" / "HTTPStorages" / f"{bundle_id}.binarycookies"
    )
    updater = home / "Library" / "Caches" / f"{bundle_id}.ShipIt"
    for residue in (cookies, storage_cookies):
        residue.parent.mkdir(parents=True, exist_ok=True)
        residue.write_bytes(b"fixture")
    updater.mkdir(parents=True)
    (updater / "staged").write_text("fixture", encoding="utf-8")
    preview = run_cleanup(
        project_root, home, "--preview", f"app_uninstall:{bundle_id}"
    )
    payload = parse_protocol(preview.stdout)
    assert preview.returncode == 0, preview.stderr
    for residue in (cookies, storage_cookies, updater):
        assert str(residue) in payload["targets"]


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_group_container_is_removed_only_when_no_other_app_declares_it(
    project_root, tmp_path
):
    home = tmp_path / "home"
    bundle_id = "me.example.solo"
    app = home / "ApplicationsRoot" / "Solo App.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)
    group = "ABCDE12345.me.example.solo"
    group_path = home / "Library" / "Group Containers" / group
    group_path.mkdir(parents=True)
    (group_path / "data").write_text("fixture", encoding="utf-8")
    groups_file = home / "groups.txt"
    groups_file.write_text(f"{bundle_id}|{group}\n", encoding="utf-8")
    preview = run_cleanup(
        project_root,
        home,
        "--preview",
        f"app_uninstall:{bundle_id}",
        extra_env={"PCH_TEST_APP_GROUPS_FILE": str(groups_file)},
    )
    payload = parse_protocol(preview.stdout)
    assert preview.returncode == 0, preview.stderr
    assert str(group_path) in payload["targets"]
    assert str(group_path) not in payload["sharedResidue"]


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_shared_group_container_is_reported_but_never_removed(project_root, tmp_path):
    home = tmp_path / "home"
    bundle_id = "me.example.suite.editor"
    sibling_id = "me.example.suite.viewer"
    for name, identifier in (
        ("Suite Editor.app", bundle_id),
        ("Suite Viewer.app", sibling_id),
    ):
        info = home / "ApplicationsRoot" / name / "Contents" / "Info.plist"
        info.parent.mkdir(parents=True)
        with info.open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": identifier}, handle)
    group = "ABCDE12345.me.example.suite"
    group_path = home / "Library" / "Group Containers" / group
    group_path.mkdir(parents=True)
    (group_path / "shared.db").write_text("fixture", encoding="utf-8")
    groups_file = home / "groups.txt"
    groups_file.write_text(
        f"{bundle_id}|{group}\n{sibling_id}|{group}\n", encoding="utf-8"
    )
    preview = run_cleanup(
        project_root,
        home,
        "--preview",
        f"app_uninstall:{bundle_id}",
        extra_env={"PCH_TEST_APP_GROUPS_FILE": str(groups_file)},
    )
    payload = parse_protocol(preview.stdout)
    assert preview.returncode == 0, preview.stderr
    assert str(group_path) in payload["sharedResidue"]
    assert str(group_path) not in payload["targets"]
    assert group_path.is_dir()


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS bundle tools are required")
def test_name_derived_residue_is_review_only(project_root, tmp_path):
    home = tmp_path / "home"
    bundle_id = "me.example.named"
    app = home / "ApplicationsRoot" / "Named App.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)
    guessed = home / "Library" / "Application Support" / "Named App"
    guessed.mkdir(parents=True)
    (guessed / "state.json").write_text("fixture", encoding="utf-8")
    exact = home / "Library" / "Application Support" / bundle_id
    exact.mkdir(parents=True)
    preview = run_cleanup(
        project_root, home, "--preview", f"app_uninstall:{bundle_id}"
    )
    payload = parse_protocol(preview.stdout)
    assert preview.returncode == 0, preview.stderr
    assert str(exact) in payload["targets"]
    assert str(guessed) in payload["reviewResidue"]
    assert str(guessed) not in payload["targets"]
    assert guessed.is_dir()


# --- New reclaimable-cache recipes (uv / SwiftPM / Homebrew / pip) --------------
# These are the "cache umbrella" additions: pure download/build caches that the
# owning tool regenerates on its own. Each must be wired through three sources that
# can drift apart silently — the scanner (storage.sh cleanup_id), the executor
# (cleanup.sh recipe case), and the app catalog (Swift fixedRecipes).

NEW_CACHE_RECIPES = {
    "uv_cache": ".cache/uv",
    "swiftpm_cache": "Library/Caches/org.swift.swiftpm",
    "homebrew_cache": "Library/Caches/Homebrew",
    "pip_cache": "Library/Caches/pip",
    "ollama_models": ".ollama/models",
}


@pytest.mark.parametrize("recipe,rel", sorted(NEW_CACHE_RECIPES.items()))
def test_new_cache_recipe_previews_and_executes_with_approval(
    project_root, tmp_path, recipe, rel
):
    home = tmp_path / "home"
    cache_file = home / rel / "sub" / "entry.bin"
    cache_file.parent.mkdir(parents=True)
    cache_file.write_bytes(b"x" * 8192)

    preview = run_cleanup(project_root, home, "--preview", recipe)
    payload = parse_protocol(preview.stdout)
    assert preview.returncode == 0, preview.stderr
    assert payload["status"] == "ready"
    assert payload["recipeId"] == recipe
    assert int(str(payload["estimatedKB"])) > 0
    assert cache_file.exists(), "preview must not delete"

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        recipe,
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
    )
    result = parse_protocol(executed.stdout)
    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert not (home / rel).exists()


def test_ollama_models_recipe_never_touches_the_ssh_keypair(project_root, tmp_path):
    """~/.ollama holds both the model blobs (reclaimable) and an SSH keypair
    (never reclaimable) as siblings. The recipe targets .ollama/models only —
    pin that the keypair survives a real execute, not just that the target
    string looks right."""
    home = tmp_path / "home"
    models = home / ".ollama" / "models" / "blob"
    models.mkdir(parents=True)
    (models / "sha256-abc").write_bytes(b"x" * 8192)
    private_key = home / ".ollama" / "id_ed25519"
    public_key = home / ".ollama" / "id_ed25519.pub"
    private_key.write_text("fixture-private-key", encoding="utf-8")
    public_key.write_text("fixture-public-key", encoding="utf-8")

    preview = run_cleanup(project_root, home, "--preview", "ollama_models")
    payload = parse_protocol(preview.stdout)
    assert preview.returncode == 0, preview.stderr

    executed = run_cleanup(
        project_root,
        home,
        "--execute",
        "ollama_models",
        "--owner-approved",
        "--approval-token",
        approval_token(payload),
    )
    result = parse_protocol(executed.stdout)
    assert executed.returncode == 0, executed.stderr
    assert result["status"] == "complete"
    assert not (home / ".ollama" / "models").exists()
    assert private_key.read_text(encoding="utf-8") == "fixture-private-key"
    assert public_key.read_text(encoding="utf-8") == "fixture-public-key"


def _scanner_cache_cleanup_ids(project_root: Path) -> set[str]:
    text = (project_root / "scripts" / "modules" / "macos" / "storage.sh").read_text(
        encoding="utf-8"
    )
    ids = set()
    for match in re.finditer(
        r'add_du_path\s+"(?:cache|ai_cache)"\s+"[^"]*"\s+"[^"]*"\s+"([a-z_]+)"', text
    ):
        ids.add(match.group(1))
    return ids


def _swift_fixed_recipes(project_root: Path) -> set[str]:
    text = (
        project_root / "macos" / "Modore" / "Sources" / "Modore" / "Models" / "StorageModels.swift"
    ).read_text(encoding="utf-8")
    block = text.split("fixedRecipes: Set<String> = [", 1)[1].split("]", 1)[0]
    return set(re.findall(r'"([a-z_]+)"', block))


def _cleanup_recipe_ids(project_root: Path) -> set[str]:
    """Recipe ids the executor validates — the third case arm that pins each id to
    its exact target path (`recipe) [[ "$target" == ... ]] ;;`)."""
    text = (project_root / "scripts" / "cleanup.sh").read_text(encoding="utf-8")
    return set(re.findall(r'^\s{8}([a-z_]+)\)\s*\[\[\s*"\$target"', text, re.MULTILINE))


def test_new_cache_recipes_are_wired_through_all_three_sources(project_root):
    scanner = _scanner_cache_cleanup_ids(project_root)
    swift = _swift_fixed_recipes(project_root)
    executor = _cleanup_recipe_ids(project_root)
    for recipe in NEW_CACHE_RECIPES:
        assert recipe in scanner, f"{recipe} missing from storage.sh add_du_path"
        assert recipe in swift, f"{recipe} missing from Swift fixedRecipes"
        assert recipe in executor, f"{recipe} missing from cleanup.sh recipe case"


def test_every_scanned_cache_cleanup_id_has_an_executor_recipe(project_root):
    """A cache row that advertises a cleanup_id the executor does not know would
    render an enabled cleanup button that fails on click. Pin the scanner's cache
    cleanup_ids to the executor's recipe set so the two cannot drift apart."""
    scanner = _scanner_cache_cleanup_ids(project_root)
    executor = _cleanup_recipe_ids(project_root)
    orphaned = scanner - executor
    assert not orphaned, f"scanner emits cleanup_ids with no executor recipe: {orphaned}"
