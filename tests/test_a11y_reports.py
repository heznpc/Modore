"""HTML 리포트 생성기의 접근성 계약 테스트.

report.py는 항상, report.jxa.js는 macOS에서 실제 실행해 생성 HTML이
viewport / main 랜드마크 / th scope / 반응형 표 / 포커스 스타일을 갖추는지 강제한다.
report.ps1은 PowerShell 5.1이 없는 환경이 많아 CI(Windows job)에서 검증한다.
"""
import platform
import re
import subprocess
import sys

import pytest


def _assert_a11y(html: str) -> None:
    assert '<meta name="viewport"' in html, "viewport meta missing"
    assert html.count("<main") == 1 and html.count("</main>") == 1, "single main landmark expected"
    ths = re.findall(r"<th\b[^>]*>", html)
    assert ths, "no table headers found"
    missing = [t for t in ths if "scope=" not in t]
    assert not missing, f"<th> without scope: {missing[:3]}"
    assert ":focus-visible" in html, "no visible focus style"
    assert "overflow-x" in html, "no responsive/scrollable table handling"


def test_python_report_meets_a11y_contract(fixtures_dir, project_root, tmp_path):
    output_path = tmp_path / "report.html"
    result = subprocess.run(
        [
            sys.executable,
            str(project_root / "scripts" / "report.py"),
            "--scan", str(fixtures_dir / "sample_scan_windows.json"),
            "--explain", str(project_root / "data" / "explain.json"),
            "--output", str(output_path),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    assert result.returncode == 0, f"report.py failed: {result.stderr}"
    _assert_a11y(output_path.read_text(encoding="utf-8"))


@pytest.mark.skipif(platform.system() != "Darwin", reason="JXA runtime requires macOS osascript")
def test_jxa_report_meets_a11y_contract(fixtures_dir, project_root, tmp_path):
    (tmp_path / "scan_result.json").write_text(
        (fixtures_dir / "sample_scan_macos.json").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    output_path = tmp_path / "report.html"
    result = subprocess.run(
        [
            "/usr/bin/osascript", "-l", "JavaScript",
            str(project_root / "scripts" / "report.jxa.js"),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        env={
            "PCH_PROJECT_DIR": str(tmp_path),
            "PCH_REPORT_OUTPUT": str(output_path),
            "PATH": "/usr/bin:/bin",
        },
    )
    assert result.returncode == 0, f"report.jxa.js failed: {result.stderr}"
    _assert_a11y(output_path.read_text(encoding="utf-8"))
