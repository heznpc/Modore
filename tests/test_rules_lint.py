"""rules/*.json 이식성 린트.

세 엔진(Python/PowerShell/JXA)이 같은 규칙을 다르게 해석하는 것을 원천 차단한다.
- `in` 연산자는 배열 멤버십 전용(D6): 문자열 expected 금지(Python은 부분 문자열로 동작).
- 정규식은 이식 가능한 부분집합만(D8): lookaround·인라인 플래그·역참조 금지
  (.NET/JS/Python 정규식 방언이 갈리는 지점).
"""
import json
import re
from pathlib import Path

import pytest

RULES_DIR = Path(__file__).resolve().parent.parent / "rules"
RULE_FILES = sorted(RULES_DIR.glob("*.json"))

_NON_PORTABLE_REGEX = (
    ("(?=", "lookahead"),
    ("(?!", "negative lookahead"),
    ("(?<", "lookbehind / named group"),
    ("(?i)", "inline flag"),
    ("(?m)", "inline flag"),
    ("(?s)", "inline flag"),
)


def _iter_conditions():
    for path in RULE_FILES:
        rules = json.loads(path.read_text(encoding="utf-8"))
        assert isinstance(rules, list), f"{path.name} must be a list of rules"
        for rule in rules:
            for key, expected in (rule.get("when") or {}).items():
                yield path.name, rule.get("id"), key, expected


@pytest.mark.parametrize("file", RULE_FILES, ids=[f.name for f in RULE_FILES])
def test_rule_files_are_nonempty_lists(file):
    rules = json.loads(file.read_text(encoding="utf-8"))
    assert isinstance(rules, list) and rules, f"{file.name} must be a non-empty rule list"


def test_in_operator_requires_array():
    for fname, rid, key, expected in _iter_conditions():
        if key.endswith(".in"):
            assert isinstance(expected, list), (
                f"{fname}:{rid} `{key}` must use an array (string expected is "
                f"interpreted as substring by Python only)"
            )


def test_regex_uses_portable_subset():
    for fname, rid, key, expected in _iter_conditions():
        _, _, op = key.rpartition(".")
        if op not in ("regex", "iregex"):
            continue
        pattern = str(expected)
        for token, label in _NON_PORTABLE_REGEX:
            assert token not in pattern, f"{fname}:{rid} `{key}` uses non-portable {label}: {pattern!r}"
        assert not re.search(r"\\[1-9]", pattern), (
            f"{fname}:{rid} `{key}` uses a backreference: {pattern!r}"
        )
        # The pattern must compile under Python at minimum.
        re.compile(pattern)
