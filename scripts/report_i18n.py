#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PC 건강검진 리포트 - 로컬라이제이션(i18n) 로더."""
import os
from pathlib import Path

from _jsonutil import load_json


SUPPORTED_SCHEMA = {"1.0"}
SUPPORTED_LANGS = {"ko", "en", "ja"}


# ============================================================
# i18n
# ============================================================
class I18n:
    def __init__(self, lang: str, bundle: dict, explain: dict):
        self.lang = lang
        self.bundle = bundle
        self.explain = explain

    def t(self, key: str, **kwargs) -> str:
        """점 표기법 키 조회 + format 치환. 없으면 키 자체 반환."""
        cur = self.bundle
        for k in key.split("."):
            if not isinstance(cur, dict) or k not in cur:
                return key
            cur = cur[k]
        if not isinstance(cur, str):
            return key
        if kwargs:
            try:
                return cur.format(**kwargs)
            except (KeyError, IndexError):
                return cur
        return cur

    def badge(self, risk: str) -> str:
        label = self.t(f"badges.{risk or 'unknown'}")
        cls = risk if risk in ("danger", "warning", "info", "safe") else "unknown"
        return f'<span class="badge {cls}">{label}</span>'


def load_i18n(lang: str, project_dir: Path, explain_path: Path) -> I18n:
    if lang not in SUPPORTED_LANGS:
        print(f"경고: 지원하지 않는 언어 '{lang}'. 'ko'로 폴백.", file=sys.stderr)
        lang = "ko"
    i18n_path = project_dir / "data" / "report_i18n" / f"{lang}.json"
    if not i18n_path.exists():
        print(f"경고: 번역 파일 없음 {i18n_path}. 'ko' 폴백.", file=sys.stderr)
        i18n_path = project_dir / "data" / "report_i18n" / "ko.json"
        lang = "ko"
    bundle = load_json(i18n_path, default={})
    explain = load_json(explain_path, default={})
    return I18n(lang, bundle, explain)


def detect_lang() -> str:
    """env/CLI 에서 언어 결정."""
    env_lang = os.environ.get("PCH_LANG", "").lower()
    if env_lang in SUPPORTED_LANGS:
        return env_lang
    # LANG/LC_ALL 에서 접두어 추출
    for var in ("LANG", "LC_ALL"):
        val = (os.environ.get(var) or "").lower()
        for code in SUPPORTED_LANGS:
            if val.startswith(code):
                return code
    return "ko"


