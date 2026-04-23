"""pytest configuration + shared fixtures.

scripts/ 디렉터리를 sys.path에 추가해 모듈 import 가능하게 한다.
(pip install 없이 동작하도록 의존성 없음)
"""
import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = PROJECT_ROOT / "scripts"
FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"

sys.path.insert(0, str(SCRIPTS_DIR))


import pytest  # noqa: E402


@pytest.fixture
def fixtures_dir():
    return FIXTURES_DIR


@pytest.fixture
def sample_windows_scan():
    path = FIXTURES_DIR / "sample_scan_windows.json"
    if not path.exists():
        pytest.skip("sample fixture missing")
    return json.loads(path.read_text(encoding="utf-8-sig"))


@pytest.fixture
def project_root():
    return PROJECT_ROOT
