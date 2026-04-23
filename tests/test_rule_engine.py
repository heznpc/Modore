"""rule_engine 단위 테스트.

규칙 엔진의 매치 연산자·규칙 평가·화이트리스트 연동·템플릿 치환 전반.
"""
import json
from pathlib import Path

import pytest

from rule_engine import (
    RuleEngine,
    _get_nested,
    _match_condition,
    _merge_risks,
    _parse_condition_key,
    _format_template,
)


# ============================================================
# 유닛: 유틸 함수
# ============================================================
class TestGetNested:
    def test_simple_key(self):
        assert _get_nested({"a": 1}, "a") == 1

    def test_nested_key(self):
        assert _get_nested({"vt": {"malicious": 5}}, "vt.malicious") == 5

    def test_missing_returns_none(self):
        assert _get_nested({}, "missing") is None

    def test_missing_nested_returns_none(self):
        assert _get_nested({"vt": None}, "vt.malicious") is None

    def test_deeply_nested(self):
        obj = {"a": {"b": {"c": "found"}}}
        assert _get_nested(obj, "a.b.c") == "found"


class TestMatchCondition:
    def test_equals(self):
        assert _match_condition("equals", "danger", "danger")
        assert not _match_condition("equals", "danger", "safe")

    def test_iregex(self):
        assert _match_condition("iregex", r"^xmrig.*$", "XmRig123")
        assert not _match_condition("iregex", r"^xmrig.*$", "chrome")

    def test_regex_case_sensitive(self):
        assert _match_condition("regex", r"^Xmrig$", "Xmrig")
        assert not _match_condition("regex", r"^Xmrig$", "xmrig")

    def test_in(self):
        assert _match_condition("in", [3333, 4444], 3333)
        assert not _match_condition("in", [3333, 4444], 80)

    def test_contains(self):
        assert _match_condition("contains", "AppData", "C:\\Users\\x\\AppData\\foo")
        assert not _match_condition("contains", "AppData", "C:\\Windows")

    def test_startswith(self):
        assert _match_condition("startswith", "/System/", "/System/Library/x")
        assert not _match_condition("startswith", "/System/", "/Users/x")

    def test_gte_gt_lte_lt(self):
        assert _match_condition("gte", 3, 5)
        assert _match_condition("gte", 3, 3)
        assert not _match_condition("gte", 3, 2)
        assert _match_condition("gt", 3, 4)
        assert not _match_condition("gt", 3, 3)
        assert _match_condition("lte", 3, 3)
        assert _match_condition("lt", 3, 2)

    def test_exists(self):
        assert _match_condition("exists", True, "something")
        assert not _match_condition("exists", True, None)
        assert _match_condition("exists", False, None)

    def test_none_actual_never_matches_string_ops(self):
        assert not _match_condition("equals", "x", None)
        assert not _match_condition("iregex", "x", None)
        assert not _match_condition("gte", 1, None)


class TestParseConditionKey:
    def test_plain(self):
        assert _parse_condition_key("name") == ("name", "equals")

    def test_with_op(self):
        assert _parse_condition_key("name.iregex") == ("name", "iregex")

    def test_nested_with_op(self):
        assert _parse_condition_key("vt.malicious.gte") == ("vt.malicious", "gte")

    def test_unknown_op_treated_as_path(self):
        # 'fakeop' 같은 알려지지 않은 접미사는 경로 일부로 취급
        assert _parse_condition_key("vt.unknownfield") == ("vt.unknownfield", "equals")


class TestMergeRisks:
    def test_danger_wins(self):
        assert _merge_risks("safe", "danger") == "danger"
        assert _merge_risks("warning", "danger") == "danger"

    def test_warning_over_info(self):
        assert _merge_risks("info", "warning") == "warning"

    def test_lower_does_not_downgrade(self):
        assert _merge_risks("danger", "safe") == "danger"

    def test_unknown_to_any_on_first(self):
        # unknown은 "기본값"이므로 어떤 새 판정이든 받아들임
        assert _merge_risks("unknown", "safe") == "safe"
        assert _merge_risks("unknown", "info") == "info"
        assert _merge_risks("unknown", "danger") == "danger"

    def test_safe_not_downgraded_to_info(self):
        # whitelist에서 safe 판정 → Program Files 규칙이 info 반환해도 유지
        assert _merge_risks("safe", "info") == "safe"

    def test_info_to_safe_upgrade(self):
        # 경로 휴리스틱으로 info 판정 → 이후 whitelist safe → safe로 올라감
        assert _merge_risks("info", "safe") == "safe"


class TestFormatTemplate:
    def test_simple(self):
        assert _format_template("프로세스 {name}", {"name": "chrome"}) == "프로세스 chrome"

    def test_nested(self):
        assert _format_template("해시: {vt.hash}", {"vt": {"hash": "abc"}}) == "해시: abc"

    def test_missing(self):
        assert _format_template("{missing}", {}) == "?"


# ============================================================
# 통합: 실제 규칙 로드 및 평가
# ============================================================
@pytest.fixture
def engine(project_root):
    rules_dir = project_root / "rules"
    whitelist = project_root / "data" / "whitelist.json"
    return RuleEngine.from_dir(rules_dir, whitelist)


class TestRuleEngineIntegration:
    def test_known_miner_is_danger(self, engine):
        r = engine.classify({"name": "xmrig", "path": "C:\\Temp\\xmrig.exe"}, "process")
        assert r["risk"] == "danger"
        assert len(r["findings"]) >= 1
        assert "채굴" in r["findings"][0]["title"] or "채굴" in r["findings"][0]["detail"]

    def test_miner_case_insensitive(self, engine):
        r = engine.classify({"name": "XMRig.exe"}, "process")
        assert r["risk"] == "danger"

    def test_whitelisted_chrome_is_safe(self, engine):
        r = engine.classify({"name": "chrome", "path": "C:\\Program Files\\Chrome\\chrome.exe"}, "process")
        assert r["risk"] == "safe"

    def test_whitelisted_with_exe_extension(self, engine):
        # 확장자 포함되어도 매칭되어야 함
        r = engine.classify({"name": "chrome.exe"}, "process")
        assert r["risk"] == "safe"

    def test_windows_system_path_is_safe(self, engine):
        r = engine.classify({
            "name": "unknown_process",
            "path": "C:\\Windows\\System32\\unknown.exe"
        }, "process")
        assert r["risk"] == "safe"

    def test_program_files_is_info(self, engine):
        r = engine.classify({
            "name": "unknown_installer",
            "path": "C:\\Program Files\\Random\\app.exe"
        }, "process")
        assert r["risk"] in ("info", "safe")

    def test_temp_folder_high_cpu_is_danger(self, engine):
        r = engine.classify({
            "name": "random",
            "path": "C:\\Users\\x\\AppData\\Local\\Temp\\x.exe",
            "cpu": 500
        }, "process")
        assert r["risk"] == "danger"

    def test_temp_folder_low_cpu_is_warning(self, engine):
        r = engine.classify({
            "name": "random",
            "path": "C:\\Users\\x\\AppData\\Local\\Temp\\x.exe",
            "cpu": 5
        }, "process")
        assert r["risk"] == "warning"

    def test_vt_malicious_many_is_danger(self, engine):
        r = engine.classify({
            "name": "unknown",
            "path": "C:\\foo",
            "vt": {"malicious": 10, "hash": "abc"},
        }, "process")
        assert r["risk"] == "danger"

    def test_vt_malicious_few_is_warning(self, engine):
        r = engine.classify({
            "name": "unknown",
            "path": "C:\\foo",
            "vt": {"malicious": 1, "hash": "abc"},
        }, "process")
        assert r["risk"] == "warning"

    def test_miner_pool_port_triggers_network(self, engine):
        r = engine.classify({
            "process": "random",
            "remoteAddress": "1.2.3.4",
            "remotePort": 3333,
        }, "network")
        assert r["risk"] == "danger"
        assert any("채굴풀" in f["title"] for f in r["findings"])

    def test_normal_port_is_unknown(self, engine):
        r = engine.classify({
            "process": "chrome",
            "remoteAddress": "1.2.3.4",
            "remotePort": 443,
        }, "network")
        # 별도 규칙 안 맞으면 unknown
        assert r["risk"] in ("unknown", "info", "safe")

    def test_defender_off_is_danger(self, engine):
        r = engine.classify({"realtimeEnabled": False, "antivirusEnabled": True}, "defender")
        assert r["risk"] == "danger"

    def test_defender_stale_signature_is_warning(self, engine):
        r = engine.classify({
            "realtimeEnabled": True,
            "antivirusEnabled": True,
            "signatureDaysOld": 30,
        }, "defender")
        assert r["risk"] == "warning"

    def test_autorun_ps_encoded_is_danger(self, engine):
        r = engine.classify({
            "entry": "suspicious",
            "launchString": "powershell -EncodedCommand AAAA",
            "verified": False,
        }, "autoruns")
        assert r["risk"] == "danger"

    def test_autorun_signed_ms_is_safe(self, engine):
        r = engine.classify({
            "entry": "OneDrive",
            "signer": "(Verified) Microsoft Corporation",
            "verified": True,
        }, "autoruns")
        assert r["risk"] == "safe"

    def test_banking_plugin_is_info_or_safe(self, engine):
        # IPinside 같은 뱅킹 플러그인
        r = engine.classify({"name": "i3gproc"}, "process")
        # whitelist에 safe-but-concerning 으로 되어있음 → info
        assert r["risk"] in ("info", "safe")


class TestApplyRulesToRaw:
    def test_full_pipeline(self, engine):
        from rule_engine import apply_rules_to_raw
        raw = {
            "schemaVersion": "1.0",
            "scannedAt": "2026-04-24 00:00:00",
            "findings": [],
            "sections": {
                "cpu": [
                    {"name": "xmrig", "path": "C:\\Temp\\x.exe", "cpu": 100, "pid_": 1234},
                    {"name": "chrome", "path": "C:\\Program Files\\Chrome\\chrome.exe", "cpu": 5, "pid_": 5678},
                ],
                "defender": {
                    "realtimeEnabled": False,
                    "antivirusEnabled": True,
                },
            },
        }
        result = apply_rules_to_raw(engine, raw)
        assert result["summary"]["overall"] == "danger"
        assert result["summary"]["dangerCount"] >= 2  # xmrig + defender off
        # CPU 섹션에 risk/note 주입 확인
        cpu_classified = result["sections"]["cpu"]
        assert cpu_classified[0]["risk"] == "danger"
        assert cpu_classified[1]["risk"] == "safe"
