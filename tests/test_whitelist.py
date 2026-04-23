"""whitelist.json 구조 검증 테스트."""
import json
from pathlib import Path

import pytest


@pytest.fixture
def whitelist(project_root):
    path = project_root / "data" / "whitelist.json"
    return json.loads(path.read_text(encoding="utf-8-sig"))


def test_whitelist_has_required_categories(whitelist):
    required_categories = {"system", "browser", "korean_common", "banking_security",
                           "dev_tools", "hardware", "cloud",
                           "miner_blacklist", "rat_blacklist", "miner_pool_ports"}
    missing = required_categories - set(whitelist.keys())
    assert not missing, f"필수 카테고리 누락: {missing}"


def test_whitelist_entries_have_required_fields(whitelist):
    """각 known-good 항목은 vendor/desc/risk 가짐"""
    for cat in ("system", "browser", "korean_common", "banking_security", "dev_tools", "hardware", "cloud"):
        for name, info in whitelist[cat].items():
            if name.startswith("_"):
                continue
            assert isinstance(info, dict), f"{cat}.{name}: dict 아님"
            for field in ("vendor", "desc", "risk"):
                assert field in info, f"{cat}.{name}: {field} 누락"
            assert info["risk"] in ("safe", "safe-but-noisy", "safe-but-concerning"), \
                f"{cat}.{name}: 알 수 없는 risk={info['risk']}"


def test_miner_blacklist_entries(whitelist):
    """채굴기 블랙리스트 항목 구조"""
    for name, info in whitelist["miner_blacklist"].items():
        if name.startswith("_"):
            continue
        assert info.get("type") == "miner", f"{name}: type=miner 여야 함"
        assert "desc" in info


def test_miner_pool_ports_are_ints(whitelist):
    ports = whitelist["miner_pool_ports"]
    assert all(isinstance(p, int) for p in ports)
    assert all(0 < p < 65536 for p in ports)


def test_no_duplicate_process_names_across_categories(whitelist):
    """같은 프로세스명이 여러 whitelist 카테고리에 중복 등록되지 않았는지"""
    seen = {}
    for cat in ("system", "browser", "korean_common", "banking_security", "dev_tools", "hardware", "cloud"):
        for name in whitelist[cat]:
            if name.startswith("_"):
                continue
            assert name not in seen, f"'{name}' 가 {seen[name]} 와 {cat} 양쪽에 있음"
            seen[name] = cat
