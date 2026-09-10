import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from report_i18n import I18n, detect_lang, load_i18n


def test_locale_precedence_and_unknown_fallback(monkeypatch):
    for key in ('PCH_LANG', 'LC_ALL', 'LC_MESSAGES', 'LANG'):
        monkeypatch.delenv(key, raising=False)
    assert detect_lang() == 'en'
    monkeypatch.setenv('LANG', 'ja_JP.UTF-8')
    assert detect_lang() == 'ja'
    monkeypatch.setenv('LC_ALL', 'ar_SA.UTF-8')
    assert detect_lang() == 'en'
    monkeypatch.setenv('PCH_LANG', 'ko-KR')
    assert detect_lang() == 'ko'


def test_missing_key_falls_back_without_format_crash():
    catalog = I18n('ja', {}, {})
    catalog.fallback = {'status': {'label': 'Count: {count}'}}
    assert catalog.t('status.label', count=1) == 'Count: 1'
    assert catalog.t('status.label', other=1) == 'Count: {count}'
    assert catalog.t('unknown') == 'unknown'


def test_unsupported_and_regional_catalogs():
    root = Path(__file__).resolve().parents[1]
    for tag, expected in [('ar', 'en'), ('fr-FR', 'en'), ('ja-JP', 'ja'), ('ko_KR', 'ko')]:
        assert load_i18n(tag, root, root / 'data/explain.json').lang == expected


def test_native_report_localizes_static_text_and_preserves_names(tmp_path):
    import json
    import os
    import subprocess
    import pytest
    if sys.platform != 'darwin':
        pytest.skip('Native report renderer requires macOS')
    root = Path(__file__).resolve().parents[1]
    fixture = json.loads((root / 'tests/fixtures/sample_scan_macos.json').read_text())
    fixture['computerName'] = '위험 항목 사용자이름'
    scan = tmp_path / 'scan.json'
    scan.write_text(json.dumps(fixture))
    for language, expected, label in [('en', 'en', 'Next actions'), ('ja-JP', 'ja', '次の操作'), ('ar', 'en', 'Next actions'), ('ko', 'ko', '다음 행동')]:
        output = tmp_path / f'{language}.html'
        result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', str(root / 'scripts/report.jxa.js')],
            env={**os.environ, 'PCH_LANG': language, 'PCH_SCAN': str(scan), 'PCH_REPORT_OUTPUT': str(output)},
            capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        html = output.read_text()
        assert f'lang="{expected}"' in html
        assert label in html
        assert '위험 항목 사용자이름' in html
