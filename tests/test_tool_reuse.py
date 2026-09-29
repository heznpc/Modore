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


@pytest.mark.parametrize('command', [
    'npx --package=vercel@1.2.3 --yes -- vercel --version',
    'npm exec --package other --package vercel@1.2.3 -- vercel --version',
    'npx --cache /tmp/example --yes=true vercel@1.2.3 --version',
    'npm x --registry=https://registry.npmjs.org -- vercel@1.2.3 --version',
])
def test_guard_handles_common_package_option_order(tmp_path, command):
    installed(tmp_path, 'one')
    assert m.guard({'hook_event_name': 'PreToolUse', 'tool_name': 'exec_command',
                    'tool_input': {'cmd': command}}, tmp_path, [])['hookSpecificOutput']['permissionDecision'] == 'deny'


def test_indirect_scripts_and_simultaneous_first_installs_remain_outside_guard(tmp_path):
    for command in ['bash -c "npx vercel"', './deploy.sh', 'npm run deploy', 'npx vercel@1.2.3']:
        assert m.guard({'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
                        'tool_input': {'command': command}}, tmp_path, []) == {}
    def missing(_):
        with pytest.raises(ValueError, match='Nothing was downloaded'):
            m.resolve('vercel@1.2.3', tmp_path, [])
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(missing, range(3)))
    assert list(tmp_path.iterdir()) == []


def test_receipt_separates_adapter_observation_from_host_enforcement(tmp_path):
    payload = {'hook_event_name': 'PreToolUse', 'tool_name': 'Bash',
               'session_id': 'private-session', 'cwd': '/private-project',
               'tool_input': {'command': 'npx vercel --token private-token'}}
    denied = {'hookSpecificOutput': {'permissionDecision': 'deny'}}
    m.record_hook('codex', payload, denied, tmp_path, now=1000)
    p = m.receipt_path('codex', tmp_path)
    assert not any(secret in p.read_text() for secret in ('private-token', 'private-session', 'private-project', 'command'))
    assert p.stat().st_mode & 0o777 == 0o600
    receipt = m.hook_receipt('codex', tmp_path, now=1001)
    assert receipt['recentlyObserved'] and receipt['outcome'] == 'deny'
    assert not receipt['hostEnforcementVerified']
    assert not m.hook_receipt('codex', tmp_path, now=1901)['recentlyObserved']
    assert not m.hook_receipt('codex', tmp_path, now=1001, changed_at=1001)['recentlyObserved']
    content = json.loads(p.read_text()); content['adapterSHA256'] = 'old'; p.write_text(json.dumps(content))
    assert not m.hook_receipt('codex', tmp_path, now=1001)['recentlyObserved']


def test_concurrent_receipts_stay_valid_and_do_not_persist_arguments(tmp_path):
    payload = {'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_input': {'command': 'true'}}
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda _: m.record_hook('codex', payload, {}, tmp_path), range(20)))
    assert m.hook_receipt('codex', tmp_path)['recentlyObserved']
    assert len(list(m.receipt_path('codex', tmp_path).parent.iterdir())) == 1


def test_receipt_failure_does_not_erase_denial(tmp_path, monkeypatch, capsys):
    import io
    payload = {'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_input': {'command': 'npx vercel'}}
    monkeypatch.setattr(m.sys, 'stdin', io.TextIOWrapper(io.BytesIO(json.dumps(payload).encode())))
    monkeypatch.setattr(m, 'guard', lambda p: {'hookSpecificOutput': {'permissionDecision': 'deny'}})
    def broken(*a): raise OSError('read-only state directory')
    monkeypatch.setattr(m, 'record_hook', broken)
    assert m.main(['hook', '--provider', 'codex']) == 0
    output = json.loads(capsys.readouterr().out)
    assert output['hookSpecificOutput']['permissionDecision'] == 'deny'
    assert 'receipt' in output['systemMessage']


def test_environment_cache_override_is_reused(tmp_path, monkeypatch):
    custom = tmp_path / 'custom-cache'
    home = tmp_path / 'home'; home.mkdir()
    installed(tmp_path, 'one').parents[3].rename(custom)
    monkeypatch.setattr(m.Path, 'home', lambda: home)
    monkeypatch.setenv('npm_config_cache', str(custom))
    assert m.resolve('vercel@1.2.3', global_roots=[])['reused']
