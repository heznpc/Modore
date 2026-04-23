#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""JSON I/O helpers with BOM-aware reading used across report/rule_engine/scanner_helper."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Optional


def load_json(path: Path, default: Any = None) -> Any:
    """Read a UTF-8 JSON file (with or without BOM). Returns default if missing.

    Raises JSONDecodeError on malformed JSON (by design — fail loudly).
    """
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8-sig"))


def dump_json(path: Path, data: Any, *, indent: int = 2) -> None:
    """Write JSON as UTF-8 (no BOM). Parent dirs must exist."""
    path.write_text(
        json.dumps(data, ensure_ascii=False, indent=indent),
        encoding="utf-8",
    )
