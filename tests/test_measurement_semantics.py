import json
import platform
import subprocess
import importlib.util
from pathlib import Path

import pytest


@pytest.mark.skipif(platform.system() != "Darwin", reason="macOS JXA scanner")
def test_scanner_storage_pressure_matches_live_byte_thresholds():
    root = Path(__file__).resolve().parents[1]
    source = (root / "scripts/scanner_helper.jxa.js").read_text()
    parser = source[source.index("function parseStorageDf("):source.index("function storageNote(")]
    helpers = "\n".join(line for line in source.splitlines()
                        if line.startswith(("function round1(", "function kbToGb(")))
    gib_kb = 1_048_576
    inputs = [
        f"disk {500 * gib_kb} 0 {free} {percent}% /"
        for free, percent in [
            (5 * gib_kb - 1, 90), (5 * gib_kb, 90),
            (20 * gib_kb - 1, 90), (20 * gib_kb, 90),
            (100 * gib_kb, 99),
        ]
    ] + ["", "disk 100 0 -1 1% /", "disk NaN 0 10 1% /", "disk 100 0 101 1% /"]
    script = helpers + "\n" + parser + "\nJSON.stringify(" + json.dumps(inputs) + ".map(parseStorageDf));"
    result = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
                            text=True, capture_output=True, check=True, timeout=10)
    values = json.loads(result.stdout)
    assert [value["risk"] for value in values] == [
        "danger", "warning", "warning", "safe", "safe",
        "unknown", "unknown", "unknown", "unknown",
    ]
    # Display rounding must not push 19.999 GiB over the 20 GiB threshold.
    assert values[2]["freeGB"] == 20
    assert values[2]["freeBytes"] == (20 * gib_kb - 1) * 1024
    assert values[2]["totalBytes"] == 500 * gib_kb * 1024
    assert values[2]["measured"] is True
    assert all(value["measured"] is False for value in values[5:])


@pytest.mark.skipif(platform.system() != "Darwin", reason="macOS JXA scanner")
def test_scanner_missing_measurements_do_not_become_zero():
    root = Path(__file__).resolve().parents[1]
    source = (root / "scripts/scanner_helper.jxa.js").read_text()
    parser = source[source.index("function measuredNumber("):source.index("raw.sections.systemLoad =")]
    script = parser + '\nJSON.stringify([undefined, "", " ", "NaN", "0", "25.5"].map(measuredNumber));'
    result = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
                            text=True, capture_output=True, check=True, timeout=10)
    assert json.loads(result.stdout) == [None, None, None, None, 0, 25.5]


def test_python_fallback_preserves_missing_values():
    source = Path(__file__).resolve().parents[1] / "scripts/scanner_helper.py"
    spec = importlib.util.spec_from_file_location("measurement_scanner_helper", source)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    values = [None, "", " ", "NaN", "inf", "0", "25.5"]
    assert [helper._measured_number(value) for value in values] == [None, None, None, None, None, 0, 25.5]


def test_report_distinguishes_memory_occupancy_from_os_pressure(monkeypatch):
    root = Path(__file__).resolve().parents[1]
    monkeypatch.syspath_prepend(str(root / "scripts"))
    from report_i18n import I18n
    from report_render import build_report

    i18n = I18n("en", json.loads((root / "data/report_i18n/en.json").read_text()), {})
    scan = {"platform": "macos", "sections": {"systemLoad": {
        "cpuPercent": None, "cpuMeasurement": "systemIntervalPercent",
        "memoryPercent": 99, "memoryMeasurement": "activeAndWiredPercent",
        "memoryPressure": 1, "totalMemoryGB": 16,
    }}}
    html = build_report(i18n, scan, None)
    assert "CPU over measurement interval Unknown%" in html
    assert "Active + wired memory 99%" in html
    assert "macOS memory pressure Normal" in html
    assert "Total memory 16 GiB" in html
    assert "None%" not in html
    scan["sections"]["systemLoad"]["memoryPressure"] = []
    assert "macOS memory pressure Unknown" in build_report(i18n, scan, None)
