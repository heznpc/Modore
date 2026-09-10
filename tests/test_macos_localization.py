"""Shipping catalog coverage and format safety; runs on Linux CI as well as macOS."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / 'macos/Modore/Sources/Modore'
LITERAL = r'"(?:[^"\\]|\\.)*"'


def catalogs():
    return {lang: {json.loads(k): json.loads(v) for k, v in re.findall(
        rf'^({LITERAL}) = ({LITERAL});$',
        (ROOT / f'Resources/{lang}.lproj/Localizable.strings').read_text(), re.M)}
        for lang in ('en', 'ko', 'ja')}


def signature(value):
    # Literal percent escapes are not arguments. Preserve ABI type and order.
    return re.findall(r'%(?:\d+\$)?[-+#0]*\d*(?:\.\d+)?(?:ll|l|z)?[@diufgs]', value.replace('%%', ''))


def test_catalog_keys_and_format_arguments_match():
    tables = catalogs()
    for lang, table in tables.items():
        assert table.keys() == tables['en'].keys(), lang
        for key, value in table.items():
            assert value, (lang, key)
            assert signature(key) == signature(value), (lang, key, value)


def test_every_swift_localization_key_is_shipped():
    table = catalogs()['en']
    missing = []
    for path in ROOT.rglob('*.swift'):
        for match in re.finditer(rf'L10n\.(?:text|format)\(\s*({LITERAL})', path.read_text()):
            key = json.loads(match[1])
            if key and key not in table:
                missing.append((path.name, key))
    assert not missing, missing


def test_no_new_korean_ui_literals_outside_localization():
    # Protocol classifiers and filenames intentionally retain their stable values.
    violations = []
    for path in (ROOT / 'Views').glob('*.swift'):
        for n, line in enumerate(path.read_text().splitlines(), 1):
            code = line.split('//')[0]
            if re.search('[가-힣]', code) and 'L10n.' not in code:
                if '.hasPrefix(' not in code:
                    violations.append((path.name, n, line))
    assert not violations, violations
