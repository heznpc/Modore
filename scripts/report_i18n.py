#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Modore 리포트 - 로컬라이제이션(i18n) 로더."""
import os
import sys
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
        self.fallback = {}

    def t(self, key: str, **kwargs) -> str:
        """점 표기법 키 조회 + format 치환. 없으면 키 자체 반환."""
        def lookup(bundle):
            value = bundle
            for part in key.split("."):
                value = value.get(part) if isinstance(value, dict) else None
            return value if isinstance(value, str) else None

        value = lookup(self.bundle) or lookup(self.fallback) or key
        if kwargs:
            try:
                return value.format(**kwargs)
            except (KeyError, IndexError, ValueError):
                pass
        return value

    def badge(self, risk: str) -> str:
        label = self.t(f"badges.{risk or 'unknown'}")
        cls = risk if risk in ("danger", "warning", "info", "safe") else "unknown"
        return f'<span class="badge {cls}">{label}</span>'


def load_i18n(lang: str, project_dir: Path, explain_path: Path) -> I18n:
    lang = (lang or "").replace("_", "-").split("-")[0].lower()
    if lang not in SUPPORTED_LANGS:
        print(f"Unsupported language {lang!r}; using English.", file=sys.stderr)
        lang = "en"
    i18n_path = project_dir / "data" / "report_i18n" / f"{lang}.json"
    if not i18n_path.exists():
        print(f"Missing translation file {i18n_path}; using English.", file=sys.stderr)
        i18n_path = project_dir / "data" / "report_i18n" / "en.json"
        lang = "en"
    bundle = load_json(i18n_path, default={})
    explain = load_json(explain_path, default={})
    result = I18n(lang, bundle, explain)
    result.fallback = load_json(project_dir / "data" / "report_i18n" / "en.json", default={})
    return result


def detect_lang() -> str:
    """env/CLI 에서 언어 결정."""
    for variable in ("PCH_LANG", "LC_ALL", "LC_MESSAGES", "LANG"):
        value = os.environ.get(variable, "").strip()
        if value:
            base = value.replace("_", "-").split("-")[0].split(".")[0].lower()
            return base if base in SUPPORTED_LANGS else "en"
    return "en"
