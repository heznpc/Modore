"""Regressions across app bindings, CLI selection and host tool boundaries.

All inventories and command executors are fixtures; no device is accessed.
"""
import copy
import importlib.util
import json
from pathlib import Path
from unittest.mock import patch

import pytest

spec = importlib.util.spec_from_file_location('resources', Path(__file__).parents[1] / 'scripts/work_resources.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


@pytest.fixture
def env(tmp_path):
    rows = m.simulator_rows({'devices': {'ios': [
        {'udid': str(i), 'name': 'Fixture', 'state': 'Shutdown', 'isAvailable': True,
         'deviceTypeIdentifier': 'phone', 'dataPath': '/fixture/' + str(i)} for i in (1, 2)]}})
    root = tmp_path / 'state'
    req = {'provider': 'codex', 'session': 'session', 'project': str(tmp_path), 'runtime': 'ios'}
    with patch.object(m, 'devices', side_effect=lambda: copy.deepcopy(rows)), patch.object(m, 'volumes', return_value=([], [])):
        yield root, rows, req


def bind(root, rows, req, rid='2'):
    r = next(r for r in rows if r['id'] == rid)
    return m.dispatch({**req, 'action': 'bind', 'id': rid, 'fingerprint': r['fingerprint']}, root)


def payload(req, command='', tool='Bash', **data):
    return {'hook_event_name': 'PreToolUse', 'tool_name': tool,
            'tool_input': data or {'command': command}, 'cwd': req['project'], 'session_id': req['session']}


def test_app_binding_survives_release_and_is_in_next_prompt(env):
    root, rows, req = env
    bind(root, rows, req)
    assert m.register(req, root)['resource']['id'] == '2'
    m.dispatch({**req, 'action': 'release'}, root)
    assert m.register({**req, 'session': 'new-session'}, root)['resource']['id'] == '2'
    out = m.turn_hook('codex', {'hook_event_name': 'UserPromptSubmit', 'session_id': 'session',
        'cwd': req['project'], 'turn_id': 'next'}, root)
    context = out['hookSpecificOutput']['additionalContext']
    assert '"resourceID": "2"' in context
    assert 'physicalDeviceChanges' in context


def test_legacy_ui_identity_release_matches_cli(env):
    root, rows, req = env
    m.register({**req, 'id': '2', 'session': 'codex:session'}, root)
    m.dispatch({**req, 'action': 'release'}, root)
    with m.registry(root) as state:
        assert not m.active_leases(state, '2')


def test_same_session_precedes_global_preference(env):
    root, rows, req = env
    m.register({**req, 'id': '2'}, root)
    with m.registry(root) as state: state['preferred']['ios/'] = '1'
    assert m.register(req, root)['resource']['id'] == '2'


def test_begin_uses_preference_and_never_touches_other_device(env):
    root, rows, req = env
    with m.registry(root) as state: state['preferred']['ios/'] = '2'
    m.turn_hook('codex', {'hook_event_name': 'UserPromptSubmit', 'session_id': 'session', 'cwd': req['project'], 'turn_id': 't'}, root)
    def execute(args, timeout=20):
        assert args[-1] == '2'
        rows[1].update(state='Booted', lastBooted='fixture')
        return b''
    with patch.object(m, 'command', side_effect=execute):
        assert m.begin_test({**req, 'turn': 't'}, root)['resource']['id'] == '2'


def test_missing_preference_is_visible_and_not_replaced(env):
    root, rows, req = env
    with m.registry(root) as state: state['preferred']['ios/'] = 'missing'
    with pytest.raises(ValueError, match='지정된 기기'): m.register(req, root)
    assert any('missing' in w for w in m.snapshot(root, observe=False)['warnings'])


def test_bound_busy_device_does_not_fall_back(env):
    root, rows, req = env
    bind(root, rows, req)
    m.register({**req, 'id': '2', 'session': 'foreign'}, root)
    m.turn_hook('codex', {'hook_event_name': 'UserPromptSubmit', 'session_id': 'session', 'cwd': req['project'], 'turn_id': 't'}, root)
    with pytest.raises(ValueError, match='다른 세션'): m.begin_test({**req, 'turn': 't'}, root)


@pytest.mark.parametrize('command', [
    'xcrun devicectl device install app --device FAKE app.app',
    '/usr/bin/xcrun devicectl device process launch --device FAKE app.fake',
    "bash -lc 'xcrun devicectl device install app --device FAKE app.app'",
    "python3 -c \"import subprocess; subprocess.run(['xcrun','devicectl','device','install','app'])\"",
    'env TEST=1 /usr/bin/xcrun devicectl list devices',
])
def test_physical_and_literal_wrappers_denied_without_enumeration(env, command):
    root, rows, req = env
    with patch.object(m, 'devices', side_effect=AssertionError('must not query devices')):
        assert m.resource_guard('codex', payload(req, command), root)['hookSpecificOutput']['permissionDecision'] == 'deny'


def test_indirect_script_is_inspected_without_execution(env):
    root, rows, req = env
    script = Path(req['project'])/'delivery.py'
    script.write_text("import subprocess\nsubprocess.run(['xcrun','devicectl','device','install','app'])")
    assert m.resource_guard('codex', payload(req, 'python3 delivery.py'), root)['hookSpecificOutput']['permissionDecision'] == 'deny'


@pytest.mark.parametrize('tool,data', [
    ('mcp__xcodebuildmcp__install_app_device', {'deviceId':'FAKE'}),
    ('mcp__xcodebuildmcp__launch_app_device', {'deviceId':'FAKE'}),
    ('mcp__ios_simulator__tap', {'udid':'1'}),
    ('mcp__xcodebuildmcp__launch_app_sim', {'simulatorId':'1'}),
])
def test_mcp_cannot_switch_target(env, tool, data):
    root, rows, req = env
    bind(root, rows, req)
    assert m.resource_guard('codex', payload(req, tool=tool, **data), root)['hookSpecificOutput']['permissionDecision'] == 'deny'


def test_registered_bound_simulator_allowed_wrong_target_denied(env):
    root, rows, req = env
    bind(root, rows, req)
    m.register(req, root)
    assert m.resource_guard('codex', payload(req, 'xcrun simctl launch 2 app.fixture'), root) == {}
    assert m.resource_guard('codex', payload(req, 'xcrun simctl launch 1 app.fixture'), root)['hookSpecificOutput']['permissionDecision'] == 'deny'


def test_disabled_codex_hooks_not_reported_enabled(tmp_path):
    m.install_hooks('codex', home=tmp_path, root=tmp_path/'state')
    (tmp_path/'.codex/config.toml').write_text('[features]\nhooks = false\n')
    status = m.hook_status({}, tmp_path)[0]
    assert status['disabled'] and not status['recentlyObserved']
    assert status['trustStatus'] == 'untrusted'


def test_installer_replaces_old_guard_without_changing_other_hooks(tmp_path):
    m.install_hooks('codex', home=tmp_path, root=tmp_path/'state')
    path=tmp_path/'.codex/hooks.json'
    cfg=json.loads(path.read_text()); cfg['hooks']['PreToolUse'][-1]['matcher']='^Bash$'
    cfg['hooks']['PreToolUse'].insert(0, {'hooks':[{'type':'command','command':'other-policy'}]})
    path.write_text(json.dumps(cfg))
    m.install_hooks('codex', home=tmp_path, root=tmp_path/'state')
    hooks=json.loads(path.read_text())['hooks']['PreToolUse']
    assert hooks[0]['hooks'][0]['command']=='other-policy'
    assert len([h for h in hooks if 'resources guard' in h['hooks'][0]['command']]) == 1


def test_explicit_claim_cannot_replace_app_binding(env):
    root, rows, req = env
    bind(root, rows, req)
    with pytest.raises(ValueError, match='앱에 지정'): m.register({**req, 'id': '1'}, root)


def test_mcp_server_name_does_not_misclassify_simulator(env):
    root, rows, req = env
    bind(root, rows, req)
    m.register(req, root)
    assert m.resource_guard('codex', payload(req, tool='mcp__device_fixture__launch_app_sim', simulatorId='2'), root) == {}


@pytest.mark.parametrize('command', [
    "echo 'xcrun devicectl device install app' | sh",
    'xcrun xcodebuild test -destination id=FAKE',
    "xcodebuild test -destination 'platform=iOS,name=Personal'",
    "xcodebuild test -destination 'platform=iOS Simulator,id=1'",
    "xcodebuild test -destination 'platform=iOS Simulator,name=iPhone'",
])
def test_pipe_and_xcodebuild_cannot_bypass_binding(env, command):
    root, rows, req = env
    bind(root, rows, req)
    assert m.resource_guard('codex', payload(req, command), root)['hookSpecificOutput']['permissionDecision'] == 'deny'


def test_benign_python_heredoc_is_data_not_shell_quotes(env):
    root, rows, req = env
    command = "python3 - <<'PY'\nprint(\"account's hooks are trusted\")\nPY\ngit status --short"
    assert m.resource_guard('codex', payload(req, command), root) == {}


def test_python_heredoc_device_code_remains_denied(env):
    root, rows, req = env
    command = "python3 - <<'PY'\nimport subprocess\nsubprocess.run(['xcrun','devicectl','list','devices'])\nPY"
    assert m.resource_guard('codex', payload(req, command), root)['hookSpecificOutput']['permissionDecision'] == 'deny'


def test_quoted_heredoc_marker_is_not_a_redirection(env):
    root, rows, req = env
    assert m.resource_guard('codex', payload(req, 'echo "<<EOF"'), root) == {}
