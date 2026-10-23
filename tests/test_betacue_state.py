import json
import os
import subprocess

import betacue_state
import mcp_server


NOW = 1_800_000_000
THREAD = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'


def fixture():
    return {
        'schemaVersion': 1, 'producer': 'BetaCue',
        'generatedAt': '2027-01-15T08:00:00Z', 'expiresAt': '2027-01-15T08:00:20Z',
        'connectionID': 'opaque-account',
        'runtime': {'instanceID': 'runtime-1', 'pid': 123, 'state': 'running', 'heartbeatAt': '2027-01-15T08:00:00Z'},
        'apps': [{'id': 'app-1', 'name': 'Example', 'bundleID': 'example.app',
                  'latestBuild': {'id': 'build-1', 'number': '42', 'marketingVersion': '1.0', 'displayVersion': '1.0 (42)'},
                  'status': {'code': 'ready', 'headline': 'Ready for group', 'description': 'Internal channel is open.'},
                  'fetchedAt': '2027-01-15T07:59:59Z', 'partial': False}],
        'watch': {'id': 'watch-1', 'appID': 'app-1', 'appName': 'Example', 'buildID': 'build-1',
                  'goal': {'channel': 'internal', 'groupID': 'group-1', 'groupName': 'Team'},
                  'phase': 'ready', 'headline': 'Ready for Team', 'detail': '', 'startedAt': '2027-01-15T07:50:00Z',
                  'observedAt': '2027-01-15T08:00:00Z', 'evidence': ['The selected group is attached.'],
                  'openURL': 'betacue://watch'},
        'workRecords': [{'id': 'record-1', 'title': 'Upload validation', 'threadID': THREAD,
                         'url': 'codex://threads/' + THREAD, 'projectPath': '/example/project',
                         'createdAt': '2027-01-15T07:50:00Z'}],
        'issues': [],
    }


def write_snapshot(tmp_path, value=None):
    root = tmp_path / 'integration'
    root.mkdir(mode=0o700, exist_ok=True)
    root.chmod(0o700)
    path = root / 'snapshot.json'
    path.write_text(json.dumps(fixture() if value is None else value))
    path.chmod(0o600)
    return path


def test_reads_only_explicit_projection_and_preserves_target_evidence(tmp_path):
    value = fixture()
    value['privateKey'] = 'must not escape'
    value['workRecords'][0]['body'] = 'full conversation must not escape'
    path = write_snapshot(tmp_path, value)
    before = path.read_bytes()
    result = betacue_state.status(path, now=NOW)
    assert result['freshness'] == 'current'
    assert result['snapshot']['watch']['goal']['groupID'] == 'group-1'
    assert result['snapshot']['watch']['evidence']
    assert result['snapshot']['workRecords'][0]['title'] == 'Upload validation'
    assert 'must not escape' not in json.dumps(result)
    assert path.read_bytes() == before


def test_missing_stale_stopped_and_future_are_not_current(tmp_path):
    assert betacue_state.status(tmp_path / 'missing' / 'snapshot.json', now=NOW)['freshness'] == 'missing'
    path = write_snapshot(tmp_path)
    assert betacue_state.status(path, now=NOW + 20)['freshness'] == 'stale'
    assert betacue_state.status(path, now=NOW - 61)['freshness'] == 'stale'
    value = fixture(); value['runtime']['state'] = 'stopped'
    path = write_snapshot(tmp_path, value)
    assert betacue_state.status(path, now=NOW)['freshness'] == 'stopped'


def test_rejects_symlink_file_parent_nonprivate_and_special_file(tmp_path):
    path = write_snapshot(tmp_path)
    link = path.parent / 'link.json'
    link.symlink_to(path)
    assert betacue_state.status(link)['freshness'] == 'invalid'
    parent_link = tmp_path / 'parent-link'
    parent_link.symlink_to(path.parent, target_is_directory=True)
    assert betacue_state.status(parent_link / path.name)['freshness'] == 'invalid'
    path.chmod(0o644)
    assert betacue_state.status(path)['freshness'] == 'invalid'
    path.chmod(0o600); path.parent.chmod(0o755)
    assert betacue_state.status(path)['freshness'] == 'invalid'
    path.parent.chmod(0o700)
    fifo = path.parent / 'pipe'; os.mkfifo(fifo, 0o600)
    assert betacue_state.status(fifo)['freshness'] == 'invalid'


def test_rejects_oversized_and_wrong_owner_files(tmp_path, monkeypatch):
    path = write_snapshot(tmp_path)
    path.write_bytes(b' ' * (betacue_state.MAX_BYTES + 1))
    assert betacue_state.status(path)['freshness'] == 'invalid'
    write_snapshot(tmp_path)
    monkeypatch.setattr(betacue_state.os, 'getuid', lambda: 999999)
    assert betacue_state.status(path)['freshness'] == 'invalid'


def test_invalid_schema_runtime_lifetime_and_duplicate_records_fail_closed(tmp_path):
    values = []
    for key, replacement in [('schemaVersion', True), ('producer', 'Other'), ('expiresAt', '2027-01-16T08:00:00Z')]:
        value = fixture(); value[key] = replacement; values.append(value)
    value = fixture(); value['runtime']['heartbeatAt'] = '2027-01-15T06:00:00Z'; values.append(value)
    value = fixture(); value['workRecords'] *= 2; values.append(value)
    value = fixture(); value['apps'][0]['partial'] = 0; values.append(value)
    value = fixture(); value['watch']['goal']['channel'] = 'automatically-distribute'; values.append(value)
    for value in values:
        assert betacue_state.status(write_snapshot(tmp_path, value), now=NOW)['freshness'] == 'invalid'


def test_only_navigation_urls_are_exposed(tmp_path):
    for bad in ['file:///etc/passwd', 'javascript:alert(1)', 'codex://threads/' + THREAD + '?execute=1',
                'https://chatgpt.com.evil.test/c/' + THREAD, 'https://user@chatgpt.com/c/' + THREAD]:
        assert betacue_state.safe_url(bad) is None
    for good in ['codex://threads/' + THREAD, 'https://chatgpt.com/c/' + THREAD, 'https://claude.ai/chat/' + THREAD]:
        assert betacue_state.safe_url(good) == good
    assert betacue_state.safe_url('betacue://watch', watch=True)
    assert betacue_state.safe_url('betacue://app?id=123', watch=True)
    assert betacue_state.safe_url('betacue://watch?start=true', watch=True) is None
    value = fixture(); value['workRecords'][0]['url'] = 'file:///private/transcript'
    result = betacue_state.status(write_snapshot(tmp_path, value), now=NOW)
    assert result['snapshot']['workRecords'][0]['url'] is None


def test_mcp_registered_tool_uses_fixed_read_only_adapter(monkeypatch):
    calls = []
    def run(script, arguments, timeout):
        calls.append((script.name, arguments, timeout))
        return {'available': False, 'freshness': 'missing'}
    monkeypatch.setattr(mcp_server, '_run_json', run)
    tool = next(item for item in mcp_server.TOOL_DESCRIPTORS if item['name'] == 'betacue_status')
    assert tool['annotations']['readOnlyHint'] is True
    result = mcp_server.handle_request('tools/call', {'name': 'betacue_status', 'arguments': {}})
    assert result['structuredContent']['freshness'] == 'missing'
    assert calls == [('betacue_state.py', ['status'], 5)]
    denied = mcp_server.handle_request('tools/call', {'name': 'betacue_status', 'arguments': {'path': '/other'}})
    assert denied['isError']
    assert len(calls) == 1


def test_actual_cli_status_and_mutation_rejection(project_root):
    command = [str(project_root / 'bin/modore'), 'betacue']
    read = subprocess.run(command + ['status'], capture_output=True, text=True, timeout=10)
    assert read.returncode == 0, read.stderr
    assert json.loads(read.stdout)['freshness'] in ('current', 'stale', 'stopped', 'missing', 'invalid')
    for args in [['start'], ['status', '--path', '/other'], ['distribute']]:
        result = subprocess.run(command + args, capture_output=True, text=True, timeout=10)
        assert result.returncode == 64
