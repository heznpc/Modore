"""룰 엔진 크로스 언어 패리티.

같은 raw_facts를 Python 레퍼런스 엔진과 macOS 런타임(JXA)에 넣어 정본 투영
(fact별 risk/note, findings, danger/warning 카운트, overall)이 일치함을 강제한다.
PowerShell(rule_engine.ps1)은 로컬 실행 환경이 없어 Windows CI job에서 검증한다.

메시지 문자열은 D7(coverage-aware summary) 역이식 전까지 정본 비교에서 제외한다.
"""
import json
import platform
import subprocess
import sys
from pathlib import Path

import pytest

PARITY_DIR = Path(__file__).resolve().parent / "fixtures" / "parity"
CASES = sorted(PARITY_DIR.glob("*.json"))


def _canonical(scan: dict) -> dict:
    facts = []
    for section in sorted(scan.get("sections", {})):
        value = scan["sections"][section]
        if isinstance(value, list):
            for fact in value:
                facts.append((section, fact.get("name"), fact.get("risk"), fact.get("note")))
    findings = sorted(
        (f.get("level"), f.get("category"), f.get("title"), f.get("detail"))
        for f in scan.get("findings", [])
    )
    summary = scan.get("summary", {})
    return {
        "facts": facts,
        "findings": findings,
        "summary": (
            summary.get("overall"),
            summary.get("dangerCount"),
            summary.get("warningCount"),
        ),
    }


def _python_result(project_root: Path, raw: dict) -> dict:
    sys.path.insert(0, str(project_root / "scripts"))
    from rule_engine import RuleEngine, apply_rules_to_raw

    engine = RuleEngine.from_dir(project_root / "rules", project_root / "data" / "whitelist.json")
    return apply_rules_to_raw(engine, raw)


def _jxa_result(project_root: Path, raw_path: Path, tmp_path: Path) -> dict:
    out = tmp_path / "scan_result.json"
    result = subprocess.run(
        [
            "/usr/bin/osascript", "-l", "JavaScript",
            str(project_root / "scripts" / "scanner_helper.jxa.js"),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        cwd=str(project_root),
        env={
            "PATH": "/usr/bin:/bin",
            "PCH_RULE_ENGINE_ONLY": "1",
            "PCH_RAW_PATH": str(raw_path),
            "PCH_OUTPUT": str(out),
            "PCH_RULES_DIR": str(project_root / "rules"),
            "PCH_WHITELIST_PATH": str(project_root / "data" / "whitelist.json"),
        },
    )
    assert result.returncode == 0, f"JXA engine-only failed: {result.stderr or result.stdout}"
    return json.loads(out.read_text(encoding="utf-8"))


@pytest.mark.parametrize("case", CASES, ids=[c.stem for c in CASES])
def test_python_matches_reference_projection(project_root, case):
    raw = json.loads(case.read_text(encoding="utf-8"))
    result = _python_result(project_root, raw)
    canonical = _canonical(result)
    # The Python engine is the reference; assert the fixture produced the graded
    # rows it is meant to exercise (sanity that the case is non-trivial).
    assert canonical["facts"], "no classified facts"
    assert any(risk == "danger" for _, _, risk, _ in canonical["facts"])


@pytest.mark.skipif(platform.system() != "Darwin", reason="JXA runtime requires macOS osascript")
@pytest.mark.parametrize("case", CASES, ids=[c.stem for c in CASES])
def test_python_and_jxa_agree(project_root, case, tmp_path):
    raw = json.loads(case.read_text(encoding="utf-8"))
    py = _canonical(_python_result(project_root, raw))
    jxa = _canonical(_jxa_result(project_root, case, tmp_path))
    assert py == jxa, f"Python vs JXA divergence in {case.name}:\nPython={py}\nJXA={jxa}"
