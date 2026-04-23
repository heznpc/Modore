#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PC 건강검진 - 규칙 엔진

설계:
  - 순수 함수 라이브러리: 부작용 없음, 파일 I/O 없음 (로더 함수만 제외)
  - rules/*.json 규칙을 로드해 raw fact에 적용, 등급(risk)과 findings 반환
  - 신호등 우선순위: danger > warning > info > safe

인터페이스:
  engine = RuleEngine.from_dir(rules_dir, whitelist=...)
  classification = engine.classify(fact, category="process")
  # classification = {
  #     "risk": "danger",
  #     "note": "...",
  #     "findings": [ {level, category, title, detail}, ... ]
  # }

규칙 파일 문서: rules/README.md
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from _jsonutil import dump_json, load_json


# ============================================================
# 상수
# ============================================================
# 우선순위: 높을수록 "더 주의가 필요". unknown은 중간값(판단 보류).
# safe > info 인 이유: safe 판정은 whitelist/서명 등 확정적 신호이고
# info는 "단서만 있음"이므로, 일단 safe가 나오면 info로 downgrade 안 됨.
RISK_PRIORITY = {"danger": 4, "warning": 3, "unknown": 2, "safe": 1, "info": 0}
VALID_RISKS = set(RISK_PRIORITY.keys())

# 카테고리 -> 규칙 파일 매핑
CATEGORY_FILES = {
    "process": "process.json",
    "network": "network.json",
    "autoruns": "autoruns.json",
    "defender": "defender.json",
    "installs": "installs.json",
}


# ============================================================
# 유틸: 점 표기법 경로 조회
# ============================================================
def _get_nested(obj: Any, path: str) -> Any:
    """
    'vt.malicious' 같은 점 표기법으로 중첩 조회. 없으면 None.
    dict 와 object 모두 지원.
    """
    if obj is None:
        return None
    cur = obj
    for key in path.split("."):
        if cur is None:
            return None
        if isinstance(cur, dict):
            cur = cur.get(key)
        else:
            cur = getattr(cur, key, None)
    return cur


def _format_template(template: str, fact: Dict[str, Any]) -> str:
    """'경로: {path}, hash: {vt.hash}' 에 값 치환. 누락된 키는 '?' 로."""
    def repl(m):
        path = m.group(1)
        v = _get_nested(fact, path)
        if v is None:
            return "?"
        return str(v)
    return re.sub(r"\{([^}]+)\}", repl, template)


# ============================================================
# 매칭 연산자
# ============================================================
def _match_condition(operator: str, expected: Any, actual: Any) -> bool:
    """
    단일 조건 평가.
    operator: 'equals', 'iregex', 'regex', 'in', 'contains', 'startswith',
              'exists', 'gte', 'gt', 'lte', 'lt'

    Note: for regex operators, `expected` may already be a compiled re.Pattern
    (precompiled by RuleEngine at load time).
    """
    if operator == "exists":
        if expected:
            return actual is not None
        return actual is None

    if actual is None:
        return False

    if operator == "equals":
        return actual == expected

    if operator in ("iregex", "regex"):
        # expected는 precompile 되어 re.Pattern이거나 string (테스트에서 직접 호출 시)
        if isinstance(expected, re.Pattern):
            return expected.search(str(actual)) is not None
        flags = re.IGNORECASE if operator == "iregex" else 0
        try:
            return re.search(expected, str(actual), flags) is not None
        except re.error:
            return False

    if operator == "in":
        return actual in expected

    if operator == "contains":
        return str(expected) in str(actual)

    if operator == "startswith":
        return str(actual).startswith(str(expected))

    if operator in ("gte", "gt", "lte", "lt"):
        try:
            a = float(actual)
            e = float(expected)
        except (TypeError, ValueError):
            return False
        if operator == "gte": return a >= e
        if operator == "gt":  return a > e
        if operator == "lte": return a <= e
        if operator == "lt":  return a < e

    return False


def _parse_condition_key(key: str) -> tuple:
    """
    'vt.malicious.gte' -> (path='vt.malicious', op='gte')
    'name.iregex'      -> (path='name', op='iregex')
    'name'             -> (path='name', op='equals')
    """
    # 알려진 연산자로 끝나는 경우
    KNOWN_OPS = ("iregex", "regex", "contains", "startswith", "exists",
                 "gte", "gt", "lte", "lt", "equals", "in")
    for op in KNOWN_OPS:
        suffix = "." + op
        if key.endswith(suffix):
            return (key[:-len(suffix)], op)
    return (key, "equals")


# ============================================================
# 규칙 평가
# ============================================================
def _rule_matches(rule: Dict[str, Any], fact: Dict[str, Any]) -> bool:
    """규칙의 'when' 절이 fact와 모두 일치하면 True (AND)."""
    when = rule.get("when") or {}
    for key, expected in when.items():
        path, op = _parse_condition_key(key)
        actual = _get_nested(fact, path)
        if not _match_condition(op, expected, actual):
            return False
    return True


def _merge_risks(current: str, new: str) -> str:
    """
    새 judgment을 merge.
    - unknown (기본값) -> 첫 판정 받아들임
    - 그 외: severity 업그레이드만 허용 (다운그레이드 없음)
    """
    if current == "unknown":
        return new
    c = RISK_PRIORITY.get(current, 2)
    n = RISK_PRIORITY.get(new, 2)
    return new if n > c else current


# ============================================================
# 엔진
# ============================================================
class RuleEngine:
    """
    usage:
        engine = RuleEngine.from_dir(Path('rules'), whitelist_path=Path('data/whitelist.json'))
        result = engine.classify(fact, category="process")
    """

    def __init__(self, rules_by_category: Dict[str, List[Dict[str, Any]]],
                 whitelist: Optional[Dict[str, Any]] = None):
        self.rules_by_category = rules_by_category
        self.whitelist = whitelist or {}
        self._build_whitelist_index()

    @classmethod
    def from_dir(cls, rules_dir: Path, whitelist_path: Optional[Path] = None) -> "RuleEngine":
        rules_by_category: Dict[str, List[Dict[str, Any]]] = {}
        for category, filename in CATEGORY_FILES.items():
            path = rules_dir / filename
            rules = load_json(path, default=None)
            if rules is None:
                rules_by_category[category] = []
                continue
            if not isinstance(rules, list):
                raise ValueError(f"{path} 는 규칙의 배열이어야 합니다.")
            for r in rules:
                cls._validate_rule(r, path)
                cls._precompile_regex(r, path)
            rules_by_category[category] = rules

        whitelist = load_json(whitelist_path) if whitelist_path else None
        return cls(rules_by_category, whitelist)

    @staticmethod
    def _precompile_regex(rule: Dict[str, Any], source: Path):
        """when 절의 iregex/regex 조건을 re.Pattern으로 미리 컴파일."""
        when = rule.get("when") or {}
        for key, expected in list(when.items()):
            _, op = _parse_condition_key(key)
            if op not in ("iregex", "regex"):
                continue
            if isinstance(expected, re.Pattern):
                continue
            try:
                flags = re.IGNORECASE if op == "iregex" else 0
                when[key] = re.compile(expected, flags)
            except re.error as e:
                raise ValueError(f"{source}: 규칙 {rule.get('id')}의 {op} 패턴 컴파일 실패: {e}")

    @staticmethod
    def _validate_rule(rule: Dict[str, Any], source: Path):
        if not isinstance(rule, dict):
            raise ValueError(f"{source}: 규칙은 객체여야 합니다.")
        if "id" not in rule:
            raise ValueError(f"{source}: 규칙에 id 필요.")
        if "when" not in rule or "then" not in rule:
            raise ValueError(f"{source}: 규칙 {rule.get('id')}에 when/then 필요.")
        risk = rule["then"].get("risk")
        if risk not in VALID_RISKS:
            raise ValueError(f"{source}: 규칙 {rule['id']}의 risk '{risk}' 가 잘못됨. {VALID_RISKS} 중 하나여야 함.")

    def _build_whitelist_index(self):
        """빠른 조회용 known-good 인덱스 구축"""
        self._known_good: Dict[str, Dict[str, Any]] = {}
        if not self.whitelist:
            return
        for cat in ("system", "browser", "korean_common", "banking_security",
                    "dev_tools", "hardware", "cloud"):
            for name, info in (self.whitelist.get(cat) or {}).items():
                if name.startswith("_"):
                    continue
                if isinstance(info, dict):
                    self._known_good[name.lower()] = {**info, "wl_category": cat}

    def _apply_whitelist(self, fact: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """프로세스 이름이 화이트리스트에 있으면 바로 safe/info 반환"""
        name = (fact.get("name") or "").lower()
        if not name:
            return None
        # 확장자 떼고 다시 시도 (chrome.exe -> chrome)
        base = name.rsplit(".", 1)[0]
        for key in (name, base):
            info = self._known_good.get(key)
            if info:
                risk = info.get("risk", "info")
                # 매핑: safe -> safe, safe-but-noisy -> safe,
                #       safe-but-concerning -> info
                if risk == "safe":
                    return {"risk": "safe", "note": f"{info.get('vendor','')} - {info.get('desc','')}".strip(" -")}
                if risk == "safe-but-noisy":
                    return {"risk": "safe", "note": f"{info.get('desc','')} (가끔 CPU 많이 씀)"}
                if risk == "safe-but-concerning":
                    return {"risk": "info", "note": f"{info.get('vendor','')} - {info.get('desc','')}".strip(" -")}
        return None

    # ------------------------------------------------------------
    # 외부 API
    # ------------------------------------------------------------
    def classify(self, fact: Dict[str, Any], category: str = "process") -> Dict[str, Any]:
        """
        fact를 주어진 카테고리의 규칙으로 평가.
        반환: {'risk': 'danger'|'warning'|'info'|'safe'|'unknown',
               'note': str, 'findings': [...]}
        """
        rules = self.rules_by_category.get(category, [])

        # 화이트리스트 먼저 체크 (process 카테고리만)
        final_risk = "unknown"
        notes: List[str] = []
        findings: List[Dict[str, Any]] = []

        if category == "process":
            wl = self._apply_whitelist(fact)
            if wl:
                final_risk = wl["risk"]
                notes.append(wl["note"])

        # 규칙 순차 평가 (모두 평가하여 다중 발동 가능)
        for rule in rules:
            if not _rule_matches(rule, fact):
                continue
            then = rule["then"]
            r_risk = then.get("risk", "info")
            final_risk = _merge_risks(final_risk, r_risk)
            note = then.get("note")
            if note:
                rendered = _format_template(note, fact)
                if rendered not in notes:
                    notes.append(rendered)

            finding_spec = then.get("finding")
            if finding_spec:
                findings.append({
                    "level": r_risk,
                    "category": finding_spec.get("category", category),
                    "title": _format_template(finding_spec.get("title", ""), fact),
                    "detail": _format_template(finding_spec.get("detail", ""), fact),
                    "ruleId": rule["id"],
                })

        # 규칙 하나도 안 맞으면 default = unknown
        note_text = " / ".join(notes) if notes else "처음 보는 프로그램 - 확인 필요"
        return {
            "risk": final_risk,
            "note": note_text,
            "findings": findings,
        }

    def classify_batch(self, facts: Iterable[Dict[str, Any]], category: str = "process") -> List[Dict[str, Any]]:
        """여러 fact를 한 번에 평가. 각 fact에 risk/note/findings 병합된 dict 반환."""
        results = []
        for f in facts:
            cls = self.classify(f, category)
            merged = dict(f)
            merged["risk"] = cls["risk"]
            merged["note"] = cls["note"]
            merged["_findings"] = cls["findings"]
            results.append(merged)
        return results


# ============================================================
# CLI: 스캐너가 뱉은 raw_facts.json을 읽어 rules 적용 후 scan_result.json 생성
# ============================================================
def main():
    import argparse

    parser = argparse.ArgumentParser(description="PC 건강검진 규칙 엔진")
    parser.add_argument("--raw", required=True, help="scanner가 생성한 raw_facts.json")
    parser.add_argument("--rules", help="rules/ 디렉터리 (기본: 프로젝트 rules)")
    parser.add_argument("--whitelist", help="whitelist.json 경로 (기본: data/whitelist.json)")
    parser.add_argument("--output", help="최종 scan_result.json 출력 경로")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    project_dir = script_dir.parent
    rules_dir = Path(args.rules) if args.rules else project_dir / "rules"
    whitelist_path = Path(args.whitelist) if args.whitelist else project_dir / "data" / "whitelist.json"
    raw_path = Path(args.raw)
    output_path = Path(args.output) if args.output else project_dir / "scan_result.json"

    engine = RuleEngine.from_dir(rules_dir, whitelist_path)
    raw = load_json(raw_path)

    result = apply_rules_to_raw(engine, raw)

    dump_json(output_path, result)
    print(f"규칙 엔진 완료: {output_path}")
    print(f"  위험: {result['summary']['dangerCount']} / 확인: {result['summary']['warningCount']}")


def apply_rules_to_raw(engine: RuleEngine, raw: Dict[str, Any]) -> Dict[str, Any]:
    """
    raw_facts 구조를 받아 규칙 적용.
    반환 구조는 기존 scan_result.json과 동일 (findings + sections 결합).

    섹션별 카테고리 매핑:
      cpu           -> process
      network       -> network
      listeningPorts -> process  (프로세스 이름 기반)
      autoruns      -> autoruns
      defender      -> defender
      macosSecurity -> defender
      recentInstalls -> installs
    """
    result = {k: v for k, v in raw.items() if k != "sections"}
    result.setdefault("findings", [])
    sections = raw.get("sections", {}) or {}
    out_sections = {}

    section_to_category = {
        "cpu": "process",
        "network": "network",
        "listeningPorts": "process",
        "autoruns": "autoruns",
        "recentInstalls": "installs",
    }

    for sect_name, facts in sections.items():
        if isinstance(facts, list):
            category = section_to_category.get(sect_name, "process")
            classified = engine.classify_batch(facts, category)
            cleaned = []
            for f in classified:
                # _findings 를 top-level findings로 수확
                for finding in f.pop("_findings", []):
                    result["findings"].append({
                        "level": finding["level"],
                        "category": finding["category"],
                        "title": finding["title"],
                        "detail": finding["detail"],
                    })
                cleaned.append(f)
            out_sections[sect_name] = cleaned
        elif isinstance(facts, dict) and sect_name in ("defender", "macosSecurity"):
            # 딕셔너리 섹션 = 단일 fact 취급
            cls = engine.classify(facts, "defender")
            for finding in cls["findings"]:
                result["findings"].append({
                    "level": finding["level"],
                    "category": finding["category"],
                    "title": finding["title"],
                    "detail": finding["detail"],
                })
            out_sections[sect_name] = facts
        else:
            out_sections[sect_name] = facts

    result["sections"] = out_sections

    # summary 재계산
    danger = sum(1 for f in result["findings"] if f.get("level") == "danger")
    warning = sum(1 for f in result["findings"] if f.get("level") == "warning")
    overall = "danger" if danger else ("warning" if warning else "safe")
    if danger:
        msg = f"긴급 확인 필요: {danger} 건의 위험 신호가 발견되었습니다."
    elif warning:
        msg = f"확인 권장: {warning} 건의 항목을 살펴보세요."
    else:
        msg = "특별한 이상 징후가 발견되지 않았습니다."
    result["summary"] = {
        "overall": overall,
        "dangerCount": danger,
        "warningCount": warning,
        "message": msg,
    }
    return result


if __name__ == "__main__":
    main()
