import json
from concurrent.futures import ThreadPoolExecutor

import pytest

import tool_reuse as m


def installed(home, key, version='1.2.3', name='vercel', bins=None):
    folder = home / '.npm/_npx' / key / 'node_modules' / name
    folder.mkdir(parents=True)
    (folder / 'cli.js').write_text('console.log("fixture")')
    (folder / 'package.json').write_text(json.dumps({
        'name': name, 'version': version,
        'bin': bins or {'vercel': 'cli.js', 'vc': 'cli.js'},
    }))
    return folder


def test_duplicate_spellings_reuse_one_copy_across_concurrent_resolutions(tmp_path):
    first = installed(tmp_path, 'a')
    installed(tmp_path, 'b')
    before = sorted(str(p) for p in tmp_path.rglob('*'))
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: m.resolve('vercel@1.2.3', tmp_path, []), range(8)))
    assert {r['path'] for r in results} == {str(first)}
    assert all(r['copiesFound'] == 2 for r in results)
    assert sorted(str(p) for p in tmp_path.rglob('*')) == before


def test_versions_are_not_silently_substituted(tmp_path):
    installed(tmp_path, 'a', '1.2.3')
    installed(tmp_path, 'b', '2.0.0')
    assert m.resolve('vercel@2.0.0', tmp_path, [])['version'] == '2.0.0'
    for spec in ['vercel', 'vercel@latest', 'vercel@^1.2.3', 'vercel@3.0.0']:
        with pytest.raises(ValueError):
            m.resolve(spec, tmp_path, [])


def test_missing_package_does_not_install_or_create_cache(tmp_path):
    with pytest.raises(ValueError, match='Nothing was downloaded'):
        m.resolve('vercel@1.2.3', tmp_path, [])
    assert list(tmp_path.iterdir()) == []


def test_partial_or_broken_install_not_reused(tmp_path):
    broken = installed(tmp_path, 'a')
    (broken / 'cli.js').unlink()
    valid = installed(tmp_path, 'b')
    assert m.resolve('vercel', tmp_path, [])['path'] == str(valid)


def test_entrypoint_cannot_escape_package(tmp_path):
    installed(tmp_path, 'a', bins={'vercel': '../../../../outside.js'})
    (tmp_path / 'outside.js').write_text('outside')
    with pytest.raises(ValueError):
        m.resolve('vercel', tmp_path, [])


@pytest.mark.parametrize('command', [
    'npx --yes vercel@latest --prod',
    'npx vercel@1.2.3 --version',
    'npm exec --yes -- vercel@1.2.3 --version',
    'npm exec --package=vercel@latest -- vercel --version',
    'npm exec -p vercel@1.2.3 -- vercel --version',
    'cd /work && npx -y vercel@latest --prod',
    'cd /work\nnpx -y vercel@latest --prod',
    'env CI=1 /opt/homebrew/bin/npx vercel@latest',
])
def test_guard_blocks_installed_vercel_and_gives_reuse_command(tmp_path, command):
    installed(tmp_path, 'a')
    result = m.guard({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
                      'tool_input': {'command': command}}, tmp_path, [])
    output = result['hookSpecificOutput']
    assert output['permissionDecision'] == 'deny'
    assert 'modore tools run vercel@1.2.3' in output['permissionDecisionReason']
    assert 'latest version' in output['permissionDecisionReason']


@pytest.mark.parametrize('command', [
    'echo "npx vercel@latest"',
    'echo npx vercel@latest',
    'npm install',
    'npm ci',
    'npx other-package@latest',
    'npx vercel@2.0.0',
    'npx vercel@^2.0.0',
    'npx vercel@canary',
    'modore tools run vercel@1.2.3 -- --version',
    'python3 -c "print(\'npx vercel@latest\')"',
])
def test_guard_preserves_unrelated_commands_and_explicit_other_version(tmp_path, command):
    installed(tmp_path, 'a')
    assert m.guard({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
                    'tool_input': {'command': command}}, tmp_path, []) == {}


def test_guard_ignores_other_hook_events(tmp_path):
    installed(tmp_path, 'a')
    assert m.guard({'hook_event_name': 'Stop', 'tool_name': 'Bash',
                    'tool_input': {'command': 'npx vercel'}}, tmp_path, []) == {}


def test_bounded_inventory_reports_partial_coverage(tmp_path, monkeypatch):
    installed(tmp_path, 'a')
    installed(tmp_path, 'b')
    monkeypatch.setattr(m, 'MAX_ENTRIES', 1)
    assert m.inventory('vercel', tmp_path, [])['warnings']
