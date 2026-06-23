"""report.py 스모크 테스트.

샘플 scan_result.json을 넣어 HTML이 생성되고 최소 요소를 포함하는지 확인.
"""
import subprocess
import sys
from pathlib import Path


def test_report_generates_from_sample(fixtures_dir, project_root, tmp_path):
    """샘플 fixture로 report.py 실행 → HTML이 만들어지고 기본 요소 포함"""
    scan_path = fixtures_dir / "sample_scan_windows.json"
    output_path = tmp_path / "report.html"

    # report.py를 서브프로세스로 돌려 real CLI 동작 검증
    result = subprocess.run(
        [
            sys.executable,
            str(project_root / "scripts" / "report.py"),
            "--scan", str(scan_path),
            "--explain", str(project_root / "data" / "explain.json"),
            "--output", str(output_path),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    assert result.returncode == 0, f"report.py 실패: {result.stderr}"
    assert output_path.exists()

    html = output_path.read_text(encoding="utf-8")
    # 필수 요소
    assert "<!DOCTYPE html>" in html
    assert 'lang="ko"' in html
    # 판정 배지 클래스 중 하나는 반드시 렌더됨
    assert any(cls in html for cls in ("verdict-safe", "verdict-warning", "verdict-danger"))
    # 신호등 배지 클래스도 최소 하나
    assert any(cls in html for cls in ("badge danger", "badge warning", "badge safe"))


def test_schema_version_tracked(sample_windows_scan):
    """v1.0 스키마를 준수하는지"""
    assert sample_windows_scan.get("schemaVersion") in ("1.0", None), \
        "알려지지 않은 schemaVersion. report.py 호환성 갱신 필요."


def test_required_top_level_fields(sample_windows_scan):
    """scan_result.json의 필수 키"""
    required = {"scannedAt", "computerName", "userName", "osVersion", "findings", "sections", "summary"}
    missing = required - set(sample_windows_scan.keys())
    assert not missing, f"필수 필드 누락: {missing}"


def test_summary_shape(sample_windows_scan):
    s = sample_windows_scan["summary"]
    assert s["overall"] in ("safe", "warning", "danger")
    assert isinstance(s["dangerCount"], int)
    assert isinstance(s["warningCount"], int)


def test_findings_are_well_formed(sample_windows_scan):
    for f in sample_windows_scan.get("findings", []):
        assert f["level"] in ("danger", "warning", "info", "safe")
        assert "title" in f
        assert "detail" in f


def test_platform_scan_contracts(fixtures_dir):
    """Windows/macOS 최종 scan_result가 report.py가 기대하는 공통 계약을 지킨다."""
    for name in ("sample_scan_windows.json", "sample_scan_macos.json"):
        scan = __import__("json").loads((fixtures_dir / name).read_text(encoding="utf-8-sig"))
        assert scan["schemaVersion"] == "1.0"
        assert isinstance(scan["summary"], dict)
        assert scan["summary"]["overall"] in ("safe", "warning", "danger")
        assert isinstance(scan["sections"], dict)
        for section in ("cpu", "network", "recentInstalls", "systemLoad", "virustotal"):
            assert section in scan["sections"], f"{name}: missing {section}"


def test_report_includes_next_actions(fixtures_dir, project_root, tmp_path):
    scan_path = fixtures_dir / "sample_scan_macos.json"
    output_path = tmp_path / "mac-report.html"
    result = subprocess.run(
        [
            sys.executable,
            str(project_root / "scripts" / "report.py"),
            "--scan", str(scan_path),
            "--explain", str(project_root / "data" / "explain.json"),
            "--output", str(output_path),
            "--lang", "ko",
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )

    assert result.returncode == 0, result.stderr
    html = output_path.read_text(encoding="utf-8")
    assert "다음 행동" in html
    assert "개인 정보" in html
