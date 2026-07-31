"""Throwaway probe: verify 93eb3f4 gating claims end-to-end. Deleted after the audit."""
from pathlib import Path

import pytest

from test_macos_cleanup import parse_protocol, run_cleanup


@pytest.fixture()
def project_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _status(project_root, home, recipe, processes):
    result = run_cleanup(project_root, home, "--preview", recipe, processes=processes)
    payload = parse_protocol(result.stdout)
    return payload.get("status"), payload.get("runningProcesses", "")


def test_probe_corepack_pnpm_is_not_blocked(project_root, tmp_path):
    home = tmp_path / "home"
    (home / "Library" / "pnpm" / "store").mkdir(parents=True)
    status, procs = _status(
        project_root,
        home,
        "pnpm_store",
        "/Users/x/.local/share/mise/installs/node/22/bin/node "
        "/Users/x/.local/share/mise/installs/node/22/lib/node_modules/corepack/dist/pnpm.js install\n",
    )
    print(f"\ncorepack pnpm install -> status={status!r} procs={procs!r}")


def test_probe_du_wrapped_pnpm_install_is_not_blocked(project_root, tmp_path):
    home = tmp_path / "home"
    (home / "Library" / "pnpm" / "store").mkdir(parents=True)
    status, procs = _status(
        project_root,
        home,
        "pnpm_store",
        "/bin/sh -c /opt/homebrew/bin/pnpm install && /usr/bin/du -sk node_modules\n",
    )
    print(f"\npnpm install piped through du -> status={status!r} procs={procs!r}")


def test_probe_source_built_app_self_block(project_root, tmp_path):
    home = tmp_path / "home"
    (home / "Library" / "pnpm").mkdir(parents=True)
    status, procs = _status(
        project_root,
        home,
        "pnpm_store",
        "/Users/x/IdeaProjects/pc-health-check/.build/debug/Modore\n",
    )
    print(f"\nswift-run Modore vs pnpm_store -> status={status!r} procs={procs!r}")


def test_probe_wrapped_xcodebuild(project_root, tmp_path):
    home = tmp_path / "home"
    (home / "Library" / "Developer" / "Xcode" / "DerivedData" / "App-abc").mkdir(parents=True)
    for label, line in [
        ("fastlane", "/usr/bin/ruby /opt/homebrew/bin/fastlane build_app --scheme App\n"),
        ("xcrun", "/usr/bin/xcrun xcodebuild -scheme App build\n"),
        ("sh -c pipe", "/bin/sh -c set -o pipefail && xcodebuild -scheme App | xcpretty\n"),
        ("direct", "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme App\n"),
    ]:
        status, procs = _status(project_root, home, "xcode_derived_data", line)
        print(f"\nxcode_derived_data via {label:12} -> status={status!r} procs={procs!r}")


def test_probe_ksadmin_blocks_chrome_clone(project_root, tmp_path):
    home = tmp_path / "home"
    clone = home / "VarFoldersRoot" / "aa" / "bb" / "X" / "com.google.Chrome.code_sign_clone"
    clone.mkdir(parents=True)
    for label, line in [
        ("ksadmin", "/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/Helpers/ksadmin --print-tickets\n"),
        ("chrome main", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n"),
    ]:
        status, procs = _status(project_root, home, "chrome_code_sign_clones", line)
        print(f"\nchrome clone vs {label:12} -> status={status!r} procs={procs!r}")
