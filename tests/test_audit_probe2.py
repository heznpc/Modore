"""Throwaway probe: does a failed state-dir migration drop the simulator keep list?"""
import os
import stat
from pathlib import Path

import pytest

from test_macos_cleanup import parse_protocol, run_cleanup

UUID = "11111111-2222-3333-4444-555555555555"


@pytest.fixture()
def project_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _setup(home: Path) -> dict:
    device = home / "Library" / "Developer" / "CoreSimulator" / "Devices" / UUID
    device.mkdir(parents=True)
    (device / "data.bin").write_bytes(b"fixture")
    simctl_list = home / "simctl.txt"
    simctl_list.write_text(
        "== Devices ==\n-- iOS 26.3 --\n"
        f"    iPhone 17 Pro Max ({UUID}) (Shutdown)\n",
        encoding="utf-8",
    )
    return {"PCH_SIMCTL_LIST_FILE": str(simctl_list)}


def test_probe_migration_failure_drops_keep_list(project_root, tmp_path):
    home = tmp_path / "home"
    home.mkdir(parents=True)
    env = _setup(home)

    support_root = home / "Library" / "Application Support"
    legacy = support_root / "PC Health Check"
    legacy.mkdir(parents=True)
    # The owner marked this simulator "keep" before the product rename.
    (legacy / "simulator-keep.txt").write_text(f"{UUID.lower()}\n", encoding="utf-8")

    # Force the one-shot rename to fail the way a locked/!w parent would.
    original = stat.S_IMODE(os.stat(support_root).st_mode)
    os.chmod(support_root, 0o555)
    try:
        result = run_cleanup(
            project_root, home, "--preview", f"simulator_delete:{UUID}", extra_env=env
        )
    finally:
        os.chmod(support_root, original)

    payload = parse_protocol(result.stdout)
    print(f"\nmigration blocked by read-only parent:")
    print(f"  legacy keep list still on disk : {(legacy / 'simulator-keep.txt').exists()}")
    print(f"  migrated dir exists            : {(support_root / 'Modore').exists()}")
    print(f"  status                         : {payload.get('status')!r}")
    print(f"  blockedReason                  : {payload.get('blockedReason')!r}")
    print(f"  targets                        : {payload.get('targets')!r}")


def test_probe_migration_skipped_when_destination_exists(project_root, tmp_path):
    home = tmp_path / "home"
    home.mkdir(parents=True)
    env = _setup(home)

    support_root = home / "Library" / "Application Support"
    legacy = support_root / "PC Health Check"
    legacy.mkdir(parents=True)
    (legacy / "simulator-keep.txt").write_text(f"{UUID.lower()}\n", encoding="utf-8")
    # Any prior run of a newer build creates this, so the move is skipped entirely.
    (support_root / "Modore").mkdir(parents=True)

    result = run_cleanup(
        project_root, home, "--preview", f"simulator_delete:{UUID}", extra_env=env
    )
    payload = parse_protocol(result.stdout)
    print(f"\ndestination already existed (no-merge guard):")
    print(f"  status        : {payload.get('status')!r}")
    print(f"  blockedReason : {payload.get('blockedReason')!r}")
    print(f"  targets       : {payload.get('targets')!r}")
