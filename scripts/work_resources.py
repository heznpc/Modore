#!/usr/bin/env python3
"""Modore-owned live resource inventory and explicit project/session leases.
No transcript inference, shared Taxi authority, or implicit simulator creation.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import threading
import queue


def identity(session, provider=''):
    """UI row IDs are not provider session IDs. Accept legacy rows on read."""
    if not isinstance(session, str): raise ValueError('세션 ID가 필요합니다.')
    prefix, sep, raw = session.partition(':')
    if sep and prefix in ('codex', 'claude', 'gemini', 'kiro', 'claude desktop'):
        if provider and provider != prefix: raise ValueError('세션 제공자가 일치하지 않습니다.')
        return prefix, raw
    return provider, session


def same_session(row, session, provider=''):
    rp, rs = identity(row.get('session', ''), row.get('provider', ''))
    pp, ss = identity(session, provider)
    return rs == ss and (not rp or not pp or rp == pp)


def migrate_state(state):
    state.setdefault('bindings', [])
    for row in state.get('leases', []):
        provider, session = identity(row.get('session', ''), row.get('provider', ''))
        row['session'] = session
        if provider: row['provider'] = provider


def assigned_resource(state, req, rows):
    """One resolver for CLI, lifecycle and guards. Never silently replace a setting."""
    project, session = project_session(req)
    provider = req.get('provider', '')
    runtime, kind = req.get('runtime', ''), req.get('deviceType', '')
    compatible = lambda r: (r.get('kind') == 'simulator' and (not runtime or r['runtime'] == runtime)
                            and (not kind or r['deviceType'] == kind))
    by_id = {r['id']: r for r in rows}
    bindings = [b for b in state.get('bindings', []) if b['project'] == project
                and (not runtime or b['runtime'] == runtime) and (not kind or b['deviceType'] == kind)]
    own = [b for b in bindings if same_session(b, session, provider)]
    leases = [l for l in state['leases'] if same_session(l, session, provider)
              and l.get('project') == project and not l.get('releasedAt')
              and l['resourceID'] in by_id and compatible(by_id[l['resourceID']])]
    candidates = own or leases or bindings
    ids = {b['resourceID'] for b in candidates}
    if len(ids) > 1: raise ValueError('연결된 기기가 여러 대입니다. OS·기종 또는 기기 ID를 명시하세요.')
    rid = next(iter(ids), None)
    if not rid and runtime:
        rid = state['preferred'].get(runtime + '/' + kind)
        if not rid and kind:
            generic = state['preferred'].get(runtime + '/')
            if generic in by_id and compatible(by_id[generic]): rid = generic
    if rid:
        r = by_id.get(rid)
        if not r or not r['available']: raise ValueError('지정된 기기가 없거나 사용 불가입니다: ' + rid + '. 앱에서 연결을 확인하세요.')
        if not compatible(r): raise ValueError('지정된 기기의 OS·기종이 요청과 다릅니다.')
        binding = next((b for b in candidates if b['resourceID'] == rid and b.get('fingerprint')), None)
        if binding and binding['fingerprint'] != r['fingerprint']: raise ValueError('연결된 기기의 식별이 바뀌었습니다.')
        return r
    return None

ROOT = Path.home() / 'Library/Application Support/Modore/work-resources'


def command(args, timeout=20):
    r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if r.returncode:
        raise ValueError(r.stderr.decode(errors='replace').strip() or f'Command failed ({r.returncode})')
    return r.stdout


def atomic(path, value):
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, ensure_ascii=False); f.flush(); os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


@contextlib.contextmanager
def registry(root=ROOT):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.is_symlink(): raise ValueError('Registry directory is a symlink')
    fd = os.open(root / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError('다른 자원 작업이 진행 중입니다. 잠시 후 다시 확인하세요.')
                time.sleep(0.05)
        path = root / 'leases.json'
        if path.is_symlink(): raise ValueError('Registry file is a symlink')
        state = json.loads(path.read_text()) if path.exists() else {'leases': [], 'preferred': {}}
        migrate_state(state)
        for lease in state['leases']:
            # The old release action encoded explicit release as expiry before
            # updatedAt. Ordinary TTL expiry always remains after updatedAt.
            if not lease.get('releasedAt') and lease.get('expiresAt', 0) < lease.get('updatedAt', 0):
                lease['releasedAt'] = lease['updatedAt']
        yield state
        atomic(path, state)
    finally:
        os.close(fd)


def simulator_rows(payload):
    rows = []
    for runtime, devices in payload['devices'].items():
        for d in devices:
            rows.append({'id': d['udid'], 'kind': 'simulator', 'name': d['name'],
                'runtime': runtime, 'deviceType': d.get('deviceTypeIdentifier', ''),
                'state': d['state'], 'available': d.get('isAvailable', False),
                'path': d.get('dataPath', ''), 'lastBooted': d.get('lastBootedAt', ''),
                'fingerprint': hashlib.sha256((d['udid'] + runtime + d.get('deviceTypeIdentifier', '') + d.get('dataPath', '')).encode()).hexdigest()})
    for r in rows:
        r['duplicates'] = [x['id'] for x in rows if x['id'] != r['id'] and
                           x['runtime'] == r['runtime'] and x['deviceType'] == r['deviceType'] and r['deviceType']]
    return rows


def devices(timeout=20):
    return simulator_rows(json.loads(command(['/usr/bin/xcrun', 'simctl', 'list', 'devices', '--json'], timeout)))


def volumes():
    result, errors = [], []
    for path in Path('/Volumes').iterdir():
        if path.is_symlink(): continue
        try:
            payload = command(['/usr/sbin/diskutil', 'info', '-plist', str(path)], 5)
            converted = subprocess.run(['/usr/bin/plutil', '-convert', 'json', '-o', '-', '-'], input=payload, capture_output=True, timeout=5, check=True)
            d = json.loads(converted.stdout)
            if d.get('Internal', True) or not d.get('MountPoint') or not d.get('VolumeUUID'): continue
            result.append({'id': d['VolumeUUID'], 'kind': 'volume', 'name': d.get('VolumeName', path.name),
                'runtime': '', 'deviceType': '', 'state': 'Mounted', 'available': True,
                'path': d['MountPoint'], 'lastBooted': '', 'duplicates': [],
                'fingerprint': hashlib.sha256((d['VolumeUUID'] + d['DeviceIdentifier'] + d['MountPoint']).encode()).hexdigest()})
        except Exception as exc: errors.append(f'{path.name}: {exc}')
    return result, errors


def process_evidence(rows):
    """Open-file observation establishes usage, never ownership by a session."""
    warnings = []
    try:
        p = subprocess.run(['/usr/sbin/lsof', '-nP', '-Fpcfn'], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=8)
        if p.returncode not in (0, 1): warnings.append('일부 프로세스의 열린 파일을 확인하지 못했습니다.')
        if p.stderr: warnings.append('lsof 접근 제한: 관찰된 프로세스만 표시합니다.')
        text = p.stdout.decode(errors='replace')
    except subprocess.TimeoutExpired:
        return {}, ['프로세스 점유 측정 시간 초과 · 점유 없음으로 판단하지 않습니다.']
    processes, current, descriptor = {}, None, ''
    for line in text.splitlines():
        if not line: continue
        if line[0] == 'p':
            current = {'pid': int(line[1:]), 'name': '', 'cwd': '', 'resources': set()}
            processes[current['pid']] = current
        elif current is not None:
            if line[0] == 'c': current['name'] = line[1:]
            elif line[0] == 'f': descriptor = line[1:]
            elif line[0] == 'n':
                path = line[1:]
                if descriptor == 'cwd': current['cwd'] = path
                for r in rows:
                    base = r['path']
                    if base and (path == base or path.startswith(base.rstrip('/') + '/')):
                        current['resources'].add(r['id'])
    found = {}
    for p in processes.values():
        for rid in p.pop('resources'):
            found.setdefault(rid, []).append(dict(p))
    return found, warnings


def active_leases(state, rid, now=None):
    now = time.time() if now is None else now
    return [x for x in state['leases'] if x['resourceID'] == rid and x['expiresAt'] > now
            and not x.get('releasedAt')]


def unresolved_leases(state, rid):
    # Expiry is loss of evidence, not proof that another session has finished.
    # Old records without an explicit release marker remain protective.
    return [x for x in state['leases'] if x['resourceID'] == rid and not x.get('releasedAt')]


def codex_hook_settings(home):
    """Read only relevant config metadata, including older system Pythons without tomllib."""
    path = Path(home) / '.codex/config.toml'
    text = path.read_text() if path.exists() else ''
    feature = re.search(r'(?ms)^\[features\]\s*\n(.*?)(?=^\[|\Z)', text)
    disabled = bool(feature and re.search(r'(?m)^\s*(?:hooks|codex_hooks)\s*=\s*false\s*(?:#.*)?$', feature[1]))
    states = {}
    for match in re.finditer(r'(?ms)^\[hooks\.state\."([^"\n]+)"\]\s*\n(.*?)(?=^\[|\Z)', text):
        states[match[1]] = {'enabled': not bool(re.search(r'(?m)^enabled\s*=\s*false', match[2])),
                            'hasTrust': bool(re.search(r'(?m)^trusted_hash\s*=', match[2]))}
    return disabled, states


def hook_config_stamp(home):
    result = {}
    for name in ('.codex/config.toml', '.codex/hooks.json'):
        path = Path(home) / name
        result[name] = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
    return result


def diagnose_hooks(req, root=ROOT, home=None):
    """Ask the installed Codex runtime; never write trust or launch an AI turn."""
    home = Path.home() if home is None else Path(home)
    choices = [Path('/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'),
               Path('/Applications/Codex.app/Contents/Resources/codex'), Path(shutil.which('codex') or '/nonexistent')]
    executable = next((p for p in choices if p.is_file()), None)
    if executable is None: raise ValueError('Codex 실행 파일을 찾지 못했습니다.')
    cwd = str(Path(req.get('project') or Path.cwd()).resolve())
    proc = subprocess.Popen([str(executable), 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, cwd=cwd)
    messages = queue.Queue()
    def read():
        for line in proc.stdout:
            try: messages.put(json.loads(line))
            except ValueError: pass
    reader = threading.Thread(target=read, daemon=True); reader.start()
    try:
        for item in [dict(id=1, method='initialize', params={'clientInfo': {'name': 'modore_diagnostics', 'version': '1'}, 'capabilities': {'experimentalApi': True}}),
                     dict(method='initialized'), dict(id=2, method='hooks/list', params={'cwds': [cwd]})]:
            proc.stdin.write(json.dumps(item)+'\n'); proc.stdin.flush()
        deadline = time.monotonic()+15
        while time.monotonic() < deadline:
            try: reply = messages.get(timeout=max(.01, deadline-time.monotonic()))
            except queue.Empty: break
            if reply.get('id') != 2: continue
            if 'error' in reply: raise ValueError('Codex 훅 진단 실패: ' + str(reply['error'].get('message', 'unknown')))
            entry = reply['result']['data'][0]
            hooks = [h for h in entry['hooks'] if re.search(r'\bmodore[\'\"]?\s+(resources|tools)\s+(hook|guard)', h.get('command', ''))]
            result = {'observedAt': time.time(), 'cwd': cwd, 'executable': str(executable),
                      'stamp': hook_config_stamp(home), 'hooks': [{k: h.get(k) for k in ('key','eventName','enabled','trustStatus','currentHash')} for h in hooks],
                      'errors': entry.get('errors', [])}
            with registry(root) as state: state['codexHookDiagnosis'] = result
            return {'message': 'Codex 실행 설정을 확인했습니다.', 'diagnosis': result}
        raise ValueError('Codex 훅 진단 응답 시간 초과')
    finally:
        proc.terminate()
        try: proc.wait(timeout=3)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()
        proc.stdin.close(); proc.stdout.close(); reader.join(timeout=1)


def hook_status(state, home=None, now=None):
    """Configuration is not execution evidence. Read only bounded hook metadata."""
    home = Path.home() if home is None else Path(home)
    now = time.time() if now is None else now
    result = []
    for provider, filename in [('codex', '.codex/hooks.json'), ('claude', '.claude/settings.json')]:
        path = home / filename
        configured, disabled, changed_at, error = False, False, 0, None
        simulator_configured = False
        trust_status = 'unknown'
        diagnostics = []
        try:
            if path.exists():
                if path.is_symlink() or path.parent.is_symlink() or path.stat().st_size > 1_048_576:
                    raise ValueError('설정 파일을 안전하게 확인할 수 없습니다.')
                config = json.loads(path.read_text())
                changed_at = path.stat().st_mtime
                disabled = bool(config.get('disableAllHooks'))
                if provider == 'codex':
                    feature_disabled, states = codex_hook_settings(home)
                    disabled = disabled or feature_disabled
                    for event, groups in config.get('hooks', {}).items():
                        snake = re.sub(r'(?<!^)(?=[A-Z])', '_', event).lower()
                        for gi, group in enumerate(groups):
                            for hi, handler in enumerate(group.get('hooks', [])):
                                words = shlex.split(handler.get('command', ''))
                                if not words or Path(words[0]).name != 'modore': continue
                                if not Path(words[0]).is_file(): diagnostics.append('훅 실행 파일 없음: ' + words[0])
                                setting = states.get(str(path) + ':' + snake + ':' + str(gi) + ':' + str(hi), {})
                                if setting.get('enabled') is False: disabled = True
                                if not setting.get('hasTrust'): trust_status = 'untrusted'
                    diagnosis = state.get('codexHookDiagnosis', {})
                    if diagnosis.get('stamp') == hook_config_stamp(home):
                        hs = diagnosis.get('hooks', [])
                        if hs:
                            trust_status = 'trusted' if all(h['trustStatus'] in ('trusted','managed') for h in hs) else 'untrusted'
                            disabled = disabled or any(not h['enabled'] for h in hs)
                def registered(event):
                    for group in config.get('hooks', {}).get(event, []):
                        for hook in group.get('hooks', []):
                            if hook.get('type') != 'command':
                                continue
                            words = shlex.split(hook.get('command', ''))
                            if (len(words) == 5 and Path(words[0]).name == 'modore'
                                    and words[1:] == ['resources', 'hook', '--provider', provider]):
                                return True
                    return False
                configured = all(registered(event) for event in ('UserPromptSubmit', 'Stop'))
                simulator_configured = any(
                    shlex.split(hook.get('command', ''))[1:] == ['resources', 'guard', '--provider', provider]
                    for group in config.get('hooks', {}).get('PreToolUse', [])
                    for hook in group.get('hooks', []) if hook.get('type') == 'command')
        except (OSError, ValueError, TypeError, AttributeError):
            error = '연결 설정을 읽지 못했습니다.'
        receipt = state.get('hookObservations', {}).get(provider, {})
        observed_at = receipt.get('observedAt')
        if not isinstance(observed_at, (int, float)) or not 0 < observed_at <= now:
            observed_at = None
        recent = (configured and not disabled and error is None and observed_at is not None
                  and observed_at >= changed_at and now - observed_at <= 900)
        if provider == 'codex' and trust_status != 'trusted': recent = False
        if diagnostics: error = '; '.join(diagnostics); recent = False
        result.append({'provider': provider, 'configured': configured, 'disabled': disabled,
                       'lastObservedAt': observed_at, 'lastEvent': receipt.get('event'),
                       'recentlyObserved': bool(recent), 'error': error,
                       'trustStatus': trust_status,
                       'lastSession': receipt.get('session'),
                       'simulatorGuard': {'configured': simulator_configured and not disabled,
                                          'hostEnforcementVerified': False,
                                          'coverage': '실기기 접근·다른 시뮬레이터 조작을 지원 셸·MCP에서 검사합니다. 훅 신뢰 승인과 실제 호스트 검증이 필요합니다. 동적 코드·외부 앱 전체를 통제하는 OS 격리는 아닙니다.'}})
    return result


def snapshot(root=ROOT, observe=True):
    warnings = []
    try: rows = devices()
    except Exception as exc: rows = []; warnings.append('시뮬레이터 조회 실패: ' + str(exc))
    vs, errors = volumes(); rows += vs; warnings += errors
    evidence, errors = process_evidence(rows) if observe else ({}, [])
    warnings += errors
    with registry(root) as state:
        for r in rows:
            r['leases'] = active_leases(state, r['id'])
            r['expiredLeases'] = [x for x in state['leases'] if x['resourceID'] == r['id'] and x['expiresAt'] <= time.time()]
            r['processes'] = evidence.get(r['id'], [])
            r['preferred'] = r['id'] in state['preferred'].values()
            r['managedTest'] = state.get('testRuns', {}).get(r['id'])
            r['bindings'] = [b for b in state.get('bindings', []) if b['resourceID'] == r['id']]
        live = {r['id'] for r in rows if r['available']}
        for key, rid in state['preferred'].items():
            if rid not in live: warnings.append('기본 기기 확인 필요: ' + key + ' → ' + rid)
        for binding in state.get('bindings', []):
            if binding['resourceID'] not in live: warnings.append('프로젝트 연결 기기 확인 필요: ' + binding['project'] + ' → ' + binding['resourceID'])
        browser_runs = list(state.get('browserRuns', {}).values())
        hooks = hook_status(state)
    return {'observedAt': time.time(), 'resources': rows, 'browsers': browser_runs, 'warnings': warnings,
            'hookStatus': hooks,
            'coverage': '프로세스 연결은 열린 파일 관찰, 세션 연결은 명시적 사용 등록입니다. 미등록 세션의 소속은 알 수 없습니다.'}


def select_existing(rows, runtime='', device_type='', preferred=None):
    candidates = [r for r in rows if r['kind'] == 'simulator' and r['available']
                  and (not runtime or r['runtime'] == runtime) and (not device_type or r['deviceType'] == device_type)]
    if not candidates: raise ValueError('일치하는 기존 기기가 없습니다. 자동으로 새 기기를 만들지 않습니다.')
    return sorted(candidates, key=lambda r: (r['id'] != preferred, r['state'] != 'Booted', not bool(r['lastBooted']), r['id']))[0]


def project_session(req):
    session = req.get('session', ''); project = req.get('project', '')
    if not isinstance(session, str) or not isinstance(project, str):
        raise ValueError('프로젝트 경로와 세션 ID는 문자열이어야 합니다.')
    session = session.strip(); project = project.strip()
    if not session or len(session) > 256 or not os.path.isabs(project) or not Path(project).is_dir():
        raise ValueError('실제 프로젝트 절대 경로와 세션 ID가 필요합니다.')
    project = str(Path(project).resolve())
    return project, identity(session, req.get('provider', ''))[1]


def register(req, root=ROOT):
    project, session = project_session(req)
    rows = devices()
    vs, _ = volumes(); rows += vs
    with registry(root) as state:
        if req.get('id'):
            r = next((r for r in rows if r['id'] == req['id']), None)
            if r is None: raise ValueError('대상을 찾지 못했습니다.')
            if r['kind'] == 'simulator':
                assigned = assigned_resource(state, {**req, 'runtime': r['runtime'], 'deviceType': r['deviceType']}, rows)
                if assigned and assigned['id'] != r['id']:
                    raise ValueError('앱에 지정된 기기와 다릅니다: ' + assigned['id'])
                if any(not same_session(l, session, req.get('provider', '')) for l in unresolved_leases(state, r['id'])):
                    raise ValueError('지정된 기기를 다른 세션이 사용 중입니다.')
        else:
            runtime = req.get('runtime', '')
            if not runtime: raise ValueError('재사용할 runtime ID를 지정하세요.')
            r = assigned_resource(state, req, rows)
            if r and any(not same_session(l, session, req.get('provider', '')) for l in unresolved_leases(state, r['id'])):
                raise ValueError('지정된 기기를 다른 세션이 사용 중입니다.')
            if r is None:
                free = [r for r in rows if not any(not same_session(l, session, req.get('provider', '')) for l in unresolved_leases(state, r['id']))]
                r = select_existing(free, runtime, req.get('deviceType', ''))
        if any(x['session'] == session and x['resourceID'] == r['id'] and
               x.get('lifetime') == 'turn' and not x.get('releasedAt') for x in state['leases']):
            raise ValueError('턴 테스트로 등록된 기기입니다. begin-test로 재사용하거나 hold로 유지하세요.')
        state['leases'] = [x for x in state['leases'] if not (same_session(x, session, req.get('provider', '')) and x['resourceID'] == r['id'])]
        state['leases'].append({'resourceID': r['id'], 'session': session, 'project': project,
                               'provider': identity(req['session'], req.get('provider', ''))[0],
                               'updatedAt': time.time(), 'expiresAt': time.time() + 900})
        return {'resource': r, 'leases': active_leases(state, r['id']), 'instruction': '이 UDID를 모든 simctl/시뮬레이터 도구 호출에 명시하세요. 5분마다 heartbeat, 종료 시 release. 기기를 새로 만들지 마세요.'}


def turn_key(provider, session):
    provider, session = identity(session, provider)
    if provider not in ('codex', 'claude') or not isinstance(session, str) or not session or len(session) > 256:
        raise ValueError('codex 또는 claude 제공자와 실제 세션 ID가 필요합니다.')
    return hashlib.sha256((provider + '\0' + session).encode()).hexdigest()


def save_registry(root, state):
    # Commit intent before simctl: even a killed hook leaves a recoverable record.
    atomic(root / 'leases.json', state)


def playwright_runtime(req):
    """Use an already installed CLI; never install packages in a lifecycle hook."""
    candidates = ([Path(req['cli'])] if req.get('cli') else
                  list((Path.home() / '.npm/_npx').glob('*/node_modules/@playwright/cli/playwright-cli.js')) +
                  [Path('/opt/homebrew/lib/node_modules/@playwright/cli/playwright-cli.js')])
    candidates = [p.resolve() for p in candidates if p.is_file()]
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    cli = next((p for p in candidates if p.name == 'playwright-cli.js' and
                json.loads((p.parent / 'package.json').read_text()).get('name') == '@playwright/cli'), None)
    nodes = ([Path(req['node'])] if req.get('node') else
             [Path(shutil.which('node') or '/nonexistent'), Path('/opt/homebrew/bin/node'),
              Path('/usr/local/bin/node')] +
             sorted((Path.home() / '.local/share/mise/installs/node').glob('*/bin/node'), reverse=True))
    node = next((p.resolve() for p in nodes if p.is_file() and os.access(p, os.X_OK)), None)
    if not cli or not node:
        raise ValueError('설치된 Playwright CLI와 Node가 필요합니다. --cli와 --node로 절대 경로를 지정할 수 있습니다.')
    return [str(node), str(cli)]


def browser_command(run, args, timeout=10):
    # A private workspace prevents project configs from selecting a user's
    # normal profile/CDP connection. No package download or updater on Stop.
    env = {k: v for k, v in os.environ.items() if not k.startswith(('PLAYWRIGHT_', 'PWTEST_', 'NODE_'))}
    env.update(CI='1', NO_UPDATE_NOTIFIER='1')
    p = subprocess.run(run['cli'] + ['-s=' + run['name']] + args + ['--json'],
                       cwd=run['workspace'], env=env, capture_output=True, timeout=timeout)
    if p.returncode:
        raise ValueError(p.stderr.decode(errors='replace')[-1000:] or 'Playwright command failed')
    return json.loads(p.stdout)


def browser_process(pid):
    p = subprocess.run(['/bin/ps', '-p', str(int(pid)), '-o', 'lstart=', '-o', 'command='],
                       capture_output=True, timeout=2)
    if p.returncode not in (0, 1): raise ValueError('브라우저 프로세스 확인 실패')
    return p.stdout.decode(errors='replace').strip()


def browser_identity(run):
    base = Path.home() / 'Library/Caches/ms-playwright/daemon'
    files = list(base.glob('*/' + run['name'] + '.session'))
    if len(files) != 1 or files[0].is_symlink():
        raise ValueError('Playwright 실행 식별 파일을 확인하지 못했습니다.')
    path = files[0]
    stat = path.stat()
    return {'path': str(path), 'inode': stat.st_ino,
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


def browser_children(pid):
    """Record browser children too: a dead daemon alone is not successful cleanup."""
    pairs = command(['/bin/ps', '-axo', 'pid=,ppid='], 2).decode().splitlines()
    parents = {int(parts[0]): int(parts[1]) for line in pairs if len(parts := line.split()) == 2}
    descendants = {pid}
    while True:
        found = {child for child, parent in parents.items() if parent in descendants}
        if found <= descendants: break
        descendants |= found
    return {str(child): identity for child in descendants - {pid}
            if (identity := browser_process(child))}


def begin_browser_test(req, root=ROOT):
    project, session = project_session(req)
    key = turn_key(req.get('provider'), session)
    with registry(root) as state:
        turn = state.get('turns', {}).get(key)
        if not turn or turn.get('finishedAt') or turn['project'] != project or turn['token'] != req.get('turn'):
            raise ValueError('현재 턴 훅의 provider·session·project·turn 값이 필요합니다.')
        for lease in state['leases']:
            if lease.get('turnKey') == key and lease.get('turn') == turn['token'] and not lease.get('releasedAt'):
                run = state.get('browserRuns', {}).get(lease['resourceID'])
                if run:
                    if (run['status'] != 'open' or browser_process(run['pid']) != run['processIdentity'] or
                            browser_identity(run) != run['identity']):
                        raise ValueError('이 턴의 기존 브라우저 실행이 미확인 상태입니다. 중복 실행하지 않습니다.')
                    return browser_result(run, reused=True)
        cli = playwright_runtime(req)
        rid = 'browser-' + uuid.uuid4().hex
        workspace = root / 'browser-workspaces' / rid
        config = workspace / '.playwright' / 'cli.config.json'
        config.parent.mkdir(mode=0o700, parents=True)
        atomic(config, {'browser': {'browserName': 'chromium', 'launchOptions': {'channel': 'chromium'}}})
        now = time.time()
        run = {'id': rid, 'name': rid, 'cli': cli, 'workspace': str(workspace),
               'project': project, 'session': session, 'provider': req['provider'],
               'startedAt': now, 'status': 'open-pending', 'stopRequested': False}
        state.setdefault('browserRuns', {})[rid] = run
        state['leases'].append({'resourceID': rid, 'runID': rid, 'project': project, 'session': session,
                                'provider': req['provider'], 'turnKey': key, 'turn': turn['token'],
                                'lifetime': 'turn', 'updatedAt': now, 'expiresAt': now + 900})
        save_registry(root, state)
        try:
            url = req.get('url') or 'about:blank'
            if not isinstance(url, str) or not url.startswith(('http://', 'https://', 'file://', 'about:')):
                raise ValueError('지원하지 않는 테스트 URL입니다.')
            result = browser_command(run, ['open', url] + (['--headed'] if req.get('headed') else []), 30)
            run['pid'] = int(result['pid'])
            run['processIdentity'] = browser_process(run['pid'])
            if 'cliDaemon.js ' + rid not in run['processIdentity']:
                raise ValueError('새로 시작한 Playwright 프로세스를 확인하지 못했습니다.')
            run['identity'] = browser_identity(run)
            run['children'] = browser_children(run['pid'])
            if not run['children']:
                raise ValueError('테스트 브라우저의 자식 프로세스를 확인하지 못했습니다.')
            run['status'] = 'open'
            return browser_result(run)
        except Exception as exc:
            run.update(status='open-unverified', error=str(exc))
            return {'error': str(exc), 'id': rid, 'verified': False}


def browser_result(run, reused=False):
    return {'id': run['id'], 'name': run['name'], 'reused': reused,
            'cwd': run['workspace'], 'argv': run['cli'] + ['-s=' + run['name']],
            'instruction': '반환된 cwd에서 argv에 snapshot/click/goto 등 Playwright 명령을 추가하세요. 같은 턴은 이 브라우저를 재사용합니다. Stop이 정상 종료합니다. 사용자 미리보기는 resources hold --id <id>로 유지하세요. 테스트 쿠키와 임시 화면 상태는 종료 시 사라집니다.'}


def settle_browsers(state, root, resource_ids):
    results = []
    deadline = time.monotonic() + 14
    for rid, run in state.get('browserRuns', {}).items():
        if rid not in resource_ids or not run.get('stopRequested') or run['status'] == 'closed': continue
        if unresolved_leases(state, rid):
            results.append({'id': rid, 'status': 'kept', 'reason': 'unreleased-session'}); continue
        if time.monotonic() > deadline - 10:
            results.append({'id': rid, 'status': 'pending', 'reason': 'time-budget'}); continue
        receipt = {'id': str(uuid.uuid4()), 'resourceID': rid, 'action': 'turn-browser-close',
                   'startedAt': time.time(), 'status': 'attempting', 'verified': False}
        path = root / ('receipt-' + receipt['id'] + '.json')
        atomic(path, receipt)
        try:
            if run['status'] not in ('open', 'stop-pending'):
                raise ValueError('시작이 미확인된 브라우저는 자동 종료하지 않습니다.')
            identity = browser_process(run['pid'])
            if identity:
                if identity != run['processIdentity'] or browser_identity(run) != run['identity']:
                    raise ValueError('브라우저 실행 식별이 바뀌어 자동 종료하지 않았습니다.')
                run['status'] = 'stop-pending'
                save_registry(root, state)
                browser_command(run, ['close'], 6)
                until = time.monotonic() + 1.5
                while browser_process(run['pid']) == identity and time.monotonic() < until:
                    time.sleep(0.1)
            survivors = [pid for pid, expected in run.get('children', {}).items()
                         if browser_process(int(pid)) == expected]
            receipt['survivingChildren'] = survivors
            receipt['verified'] = not browser_process(run['pid']) and not survivors
            receipt['status'] = 'succeeded' if receipt['verified'] else 'unverified'
            run['status'] = 'closed' if receipt['verified'] else 'stop-pending'
        except Exception as exc:
            receipt.update(status='failed', error=str(exc))
        receipt['finishedAt'] = time.time()
        atomic(path, receipt)
        run['receipt'] = str(path)
        results.append({'id': rid, 'status': receipt['status'], 'verified': receipt['verified'], 'receipt': str(path)})
    return results


def settle_tests(state, root, resource_ids):
    """Stop only runs booted by Modore whose consumers explicitly finished."""
    results = []
    deadline = time.monotonic() + 40
    for rid, run in state.get('testRuns', {}).items():
        if rid not in resource_ids: continue
        if not run.get('stopRequested') or run.get('status') not in ('booted', 'stop-pending'):
            continue
        blockers = unresolved_leases(state, rid)
        if blockers:
            run['blockedReason'] = 'unreleased-session'
            results.append({'id': rid, 'status': 'kept', 'reason': 'unreleased-session'})
            continue
        if time.monotonic() > deadline - 20:
            results.append({'id': rid, 'status': 'pending', 'reason': 'time-budget'})
            continue
        receipt = {'id': str(uuid.uuid4()), 'resourceID': rid, 'action': 'turn-shutdown',
                   'startedAt': time.time(), 'status': 'attempting', 'verified': False}
        path = root / ('receipt-' + receipt['id'] + '.json')
        try:
            r = next((x for x in devices(5) if x['id'] == rid), None)
            if r is None or r['fingerprint'] != run['fingerprint']:
                raise ValueError('시뮬레이터 식별이 바뀌어 자동 종료하지 않았습니다.')
            # Detect a shutdown/reboot outside Modore when simctl exposes it.
            if r['state'] != 'Shutdown' and (not run.get('lastBooted') or r['lastBooted'] != run['lastBooted']):
                raise ValueError('부팅 식별을 확인할 수 없어 자동 종료하지 않았습니다.')
            run['status'] = 'stop-pending'
            save_registry(root, state)
            atomic(path, receipt)
            if r['state'] == 'Booted':
                command(['/usr/bin/xcrun', 'simctl', 'shutdown', rid], 10)
            elif r['state'] != 'Shutdown':
                raise ValueError('시뮬레이터가 상태 전환 중입니다.')
            fresh = next((x for x in devices(5) if x['id'] == rid), None)
            receipt['verified'] = bool(fresh and fresh['fingerprint'] == run['fingerprint'] and fresh['state'] == 'Shutdown')
            receipt['status'] = 'succeeded' if receipt['verified'] else 'unverified'
            run['status'] = 'shutdown' if receipt['verified'] else 'stop-pending'
            run.pop('blockedReason', None)
        except Exception as exc:
            receipt['status'] = 'failed'
            receipt['error'] = str(exc)
        receipt['finishedAt'] = time.time()
        atomic(path, receipt)
        run['receipt'] = str(path)
        results.append({'id': rid, 'status': receipt['status'], 'verified': receipt['verified'], 'receipt': str(path)})
    return results


def begin_test(req, root=ROOT):
    """Register and boot an existing, unused device for exactly one observed turn."""
    project, session = project_session(req)
    key = turn_key(req.get('provider'), session)
    with registry(root) as state:
        turn = state.get('turns', {}).get(key)
        if not turn or turn.get('finishedAt') or turn['project'] != project or turn['token'] != req.get('turn'):
            raise ValueError('현재 턴 훅의 provider·session·project·turn 값이 필요합니다.')
        rows = devices()
        assigned = assigned_resource(state, req, rows)
        if req.get('id') and assigned and req['id'] != assigned['id']:
            raise ValueError('앱에 지정된 기기와 다릅니다: ' + assigned['id'])
        if assigned:
            req = {**req, 'id': assigned['id']}
        owned = [x for x in state['leases'] if x.get('turnKey') == key and x.get('turn') == turn['token']
                 and x.get('lifetime') == 'turn' and not x.get('releasedAt')]
        if req.get('id'):
            candidates = [r for r in rows if r['id'] == req['id'] and r['available']]
        else:
            if not req.get('runtime'):
                raise ValueError('기존 기기의 ID 또는 runtime을 지정하세요.')
            candidates = [r for r in rows if r['available'] and r['runtime'] == req['runtime']
                          and (not req.get('deviceType') or r['deviceType'] == req['deviceType'])]
        for r in candidates:
            run = state.get('testRuns', {}).get(r['id'], {})
            if any(x['resourceID'] == r['id'] for x in owned):
                if run.get('status') == 'booted' and run.get('fingerprint') == r['fingerprint'] and r['state'] == 'Booted' and run.get('lastBooted') == r['lastBooted']:
                    return {'resource': r, 'turn': turn['token'], 'reused': True}
                raise ValueError('관리 중인 기기의 상태가 바뀌었습니다. 새로 확인하세요.')
        # A persistent assignment does not authorize taking over a foreign run.
        for r in candidates:
            leases = unresolved_leases(state, r['id'])
            own_manual = [l for l in leases if same_session(l, session, req['provider']) and not l.get('turnKey')]
            foreign = [l for l in leases if not same_session(l, session, req['provider'])]
            if foreign:
                if req.get('id'): raise ValueError('지정된 기기를 다른 세션이 사용 중입니다.')
                continue
            if r['state'] == 'Booted' and own_manual:
                for l in own_manual: l.update(updatedAt=time.time(), expiresAt=time.time()+900)
                return {'resource': r, 'turn': turn['token'], 'reused': True, 'automaticStop': False,
                        'instruction': '기존 세션 기기를 재사용합니다. 이 실행은 자동 종료하지 않습니다.'}
            if r['state'] == 'Shutdown' and own_manual:
                for l in own_manual: l['releasedAt'] = time.time()
        candidates = [r for r in candidates if r['state'] == 'Shutdown' and not unresolved_leases(state, r['id'])]
        if not candidates:
            raise ValueError('명시적 사용 등록이 없는 꺼진 기존 기기가 없습니다. 다른 세션의 기기를 끄거나 새로 만들지 않습니다.')
        r = select_existing(candidates, req.get('runtime', ''), req.get('deviceType', ''))
        rid = r['id']; now = time.time()
        # Keep one current row per session/device for the app's stable identity.
        # Completed execution history remains in the mutation receipts.
        state['leases'] = [x for x in state['leases'] if not (
            x['resourceID'] == rid and x['session'] == session and x.get('releasedAt'))]
        run_id = str(uuid.uuid4())
        lease = {'resourceID': rid, 'session': session, 'project': project, 'runID': run_id,
                 'provider': req['provider'], 'turnKey': key, 'turn': turn['token'],
                 'lifetime': 'turn', 'updatedAt': now, 'expiresAt': now + 900}
        state['leases'].append(lease)
        run = {'id': run_id, 'fingerprint': r['fingerprint'], 'startedAt': now, 'status': 'boot-pending', 'stopRequested': False}
        state.setdefault('testRuns', {})[rid] = run
        save_registry(root, state)
        try:
            command(['/usr/bin/xcrun', 'simctl', 'boot', rid], 20)
            fresh = next((x for x in devices() if x['id'] == rid), None)
            if not fresh or fresh['state'] != 'Booted' or fresh['fingerprint'] != r['fingerprint'] or not fresh['lastBooted']:
                raise ValueError('부팅 식별을 확인하지 못했습니다. 자동 종료는 보류합니다.')
            run.update(status='booted', lastBooted=fresh['lastBooted'])
            return {'resource': fresh, 'turn': turn['token'], 'reused': False,
                    'instruction': '이 UDID를 모든 액션에 명시하세요. Stop 훅은 이 테스트 실행만 종료합니다. 사용자 검토용으로 유지할 때는 resources hold --id ... --provider ... --session ... --turn ... 를 호출하세요.'}
        except Exception as exc:
            run['status'] = 'boot-unverified'; run['error'] = str(exc)
            return {'error': str(exc), 'resource': r, 'verified': False}


def turn_hook(provider, payload, root=ROOT):
    """Consume only lifecycle metadata; never retain hook text or read transcripts."""
    event = payload.get('hook_event_name')
    if event not in ('UserPromptSubmit', 'Stop') or payload.get('agent_id'):
        return {}
    project, session = project_session({'project': payload.get('cwd'), 'session': payload.get('session_id')})
    key = turn_key(provider, session)
    wire_turn = payload.get('turn_id')
    if provider == 'codex' and (not isinstance(wire_turn, str) or not wire_turn or len(wire_turn) > 256):
        raise ValueError('Codex turn_id가 없어 자동 처리를 보류합니다.')
    with registry(root) as state:
        observation = {'event': event, 'observedAt': time.time(), 'session': session, 'turn': wire_turn}
        state.setdefault('hookObservations', {})[provider] = observation
        state.setdefault('sessionObservations', {})[key] = observation
        turns = state.setdefault('turns', {})
        old = turns.get(key)
        if event == 'UserPromptSubmit':
            # Claude does not supply turn_id. Synchronous hooks serialize its
            # prompt/Stop lifecycle; never configure this bridge as async.
            token = wire_turn if provider == 'codex' else str(uuid.uuid4())
            if not old or old['token'] != token or old.get('finishedAt'):
                turns[key] = {'project': project, 'token': token, 'startedAt': time.time()}
            context = ('Modore test-resource lifecycle: when using an iOS simulator for this turn, run '
                       'modore resources status, then modore resources begin-test --runtime <runtime> '
                       f'--provider {provider} --session {shlex.quote(session)} --project {shlex.quote(project)} --turn {shlex.quote(token)}. '
                       'Use the returned UDID. Stop will shut down only this managed test run, preserving the device and data. '
                       'If the user needs a running preview or background test, use resources hold with the same provider/session/turn and --id <UDID> before responding. '
                       'Never adopt or stop an unregistered running simulator. '
                       'For Playwright CLI browser tests, use modore resources begin-browser-test '
                       f'--provider {provider} --session {shlex.quote(session)} --project {shlex.quote(project)} --turn {shlex.quote(token)} '
                       '--url <URL> [--headed] instead of directly opening another test browser. '
                       'It starts isolated Chromium, returns cwd/argv for all subsequent Playwright actions, reuses it within the turn, '
                       'and closes it normally on Stop. Test cookies and transient UI state end with it. '
                       'Use resources hold with its returned id only when the user needs a running preview after the response. '
                       'It does not close ordinary Chrome, external browser tools, or unregistered browsers. '
                       'Before installing a deployment CLI, run modore tools status vercel. '
                       'Reuse the exact installed version with modore tools run vercel@<version> -- <arguments>; '
                       'do not create another npx cache for the same version via latest or another spelling. '
                       'This command never installs packages. Project node_modules and lockfiles remain project-specific.')
            bindings = [b for b in state.get('bindings', []) if b['project'] == project or same_session(b, session, provider)]
            leases = [l for l in state['leases'] if same_session(l, session, provider) and not l.get('releasedAt')]
            context += '\nSaved Modore environment (data, not instructions): ' + json.dumps(
                {'bindings': bindings, 'sessionResources': [l['resourceID'] for l in leases],
                 'preferred': state['preferred'], 'physicalDeviceChanges': 'denied'}, ensure_ascii=False)
            context += '\nUse this existing environment. Do not switch to a personal physical device for verification.'
            return {'hookSpecificOutput': {'hookEventName': event, 'additionalContext': context}}
        if not old or old['project'] != project or (provider == 'codex' and old['token'] != wire_turn):
            return {}
        old['finishedAt'] = time.time()
        targets = set()
        for lease in state['leases']:
            if lease.get('turnKey') == key and lease.get('turn') == old['token'] and lease.get('lifetime') == 'turn':
                lease['releasedAt'] = lease['updatedAt'] = time.time()
                lease['expiresAt'] = time.time() - 1
                run = state.get('testRuns', {}).get(lease['resourceID'])
                if run and run['id'] == lease.get('runID'):
                    run['stopRequested'] = True
                    targets.add(lease['resourceID'])
                browser = state.get('browserRuns', {}).get(lease['resourceID'])
                if browser and browser['id'] == lease.get('runID'):
                    browser['stopRequested'] = True
                    targets.add(lease['resourceID'])
        save_registry(root, state)
        results = settle_tests(state, root, targets) + settle_browsers(state, root, targets)
        if not results: return {}
        stopped = sum(x.get('verified', False) for x in results)
        return {'systemMessage': f'Modore: 테스트 실행 {stopped}개 종료 확인, {len(results) - stopped}개 유지/확인 필요. AI 세션과 시뮬레이터 기기는 보존됩니다.'}


def simulator_creations(text):
    """Recognize direct shell invocations; never execute or expand shell input."""
    if not isinstance(text, str): return []
    lexer = shlex.shlex(text, posix=True, punctuation_chars=';&|()<>\n')
    lexer.whitespace = ' \t\r'
    lexer.whitespace_split = True
    segments, part = [], []
    for token in lexer:
        if token and all(c in ';&|()<>\n' for c in token):
            if part: segments.append(part)
            part = []
        else: part.append(token)
    if part: segments.append(part)
    found = []
    for args in segments:
        while args and (re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', args[0]) or
                        args[0] in ('env', 'command', 'exec', 'sudo')):
            args = args[1:]
        if not args: continue
        if Path(args[0]).name in ('sh', 'bash', 'zsh') and len(args) >= 3 and args[1] in ('-c', '-lc'):
            found.extend(simulator_creations(args[2]))
            continue
        if Path(args[0]).name == 'xcrun':
            args = args[1:]
            while args and args[0].startswith('-'):
                option = args.pop(0)
                if option in ('--sdk', '-sdk', '--toolchain', '-toolchain') and args: args.pop(0)
        if len(args) >= 2 and Path(args[0]).name == 'simctl' and args[1] in ('create', 'clone'):
            found.append(args[1:])
    return found


def simulator_guard(provider, payload):
    if payload.get('hook_event_name') != 'PreToolUse': return {}
    if payload.get('tool_name') not in ('Bash', 'exec_command', 'functions.exec_command'): return {}
    data = payload.get('tool_input') or {}
    text = data.get('command', data.get('cmd', ''))
    requests = simulator_creations(text)
    if not requests: return {}
    def deny(reason):
        return {'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                'permissionDecision': 'deny', 'permissionDecisionReason': reason}}
    try:
        inventory = json.loads(command(['/usr/bin/xcrun', 'simctl', 'list', '--json'], 8))
        rows = simulator_rows(inventory)
    except Exception:
        return deny('Modore: 기존 시뮬레이터 조회에 실패해 중복 여부를 확인할 수 없습니다. resources status로 확인한 뒤 다시 시도하세요.')
    for args in requests:
        if args[0] == 'clone':
            matches = [r for r in rows if r['id'] == args[1] or r['name'] == args[1]] if len(args) > 1 else []
        else:
            if len(args) < 3: continue  # simctl itself rejects missing arguments
            kind = args[2]
            kind = next((d['identifier'] for d in inventory.get('devicetypes', [])
                         if kind in (d['identifier'], d['name'])), kind)
            runtime = args[3] if len(args) > 3 else ''
            runtime = next((r['identifier'] for r in inventory.get('runtimes', [])
                            if runtime in (r['identifier'], r['name'], r.get('version'))), runtime)
            # Without a runtime, require an explicit choice from existing configurations.
            matches = [r for r in rows if r['available'] and r['deviceType'] == kind
                       and (not runtime or r['runtime'] == runtime)]
        if not matches: continue
        details = '\n'.join(f"- {r['name']} | UDID {r['id']} | {r['runtime']} | {r['state']} | 경로 {r['path']}" for r in matches)
        chosen = matches[0]
        cli = str(Path(__file__).resolve().parents[1] / 'bin/modore')
        reuse = [cli, 'resources', 'acquire', '--id', chosen['id'],
                 '--project', payload.get('cwd') or '<project-path>',
                 '--session', payload.get('session_id') or '<session-id>']
        return deny('Modore: 동일 OS·기종이 이미 있어 중복 생성을 차단했습니다. 기존 기기:\n' + details +
                    '\n먼저 resources status로 사용 등록과 점유를 확인하세요. 기존 기기 등록 명령: ' + shlex.join(reuse) +
                    '\n턴 훅이 연결돼 있으면 resources begin-test를 사용하세요. 위 목록은 다른 세션이 사용하지 않는다는 보장이 아닙니다.')
    return {}


def shell_segments(text, depth=0, cwd=None):
    """Inspect literal wrappers and local scripts without evaluating shell/code."""
    if depth > 4: raise ValueError('중첩된 명령을 확인할 수 없습니다.')
    # A heredoc body is data for its receiving command, not shell tokens. In
    # particular, Python apostrophes must not break shell quote parsing. Retain
    # interpreter bodies for the same bounded device-code inspection as scripts.
    lines = text.splitlines(keepends=True)
    shell_lines, embedded, i = [], [], 0
    def heredoc_start(line):
        quote, escaped = None, False
        for offset, char in enumerate(line):
            if escaped: escaped = False; continue
            if char == '\\' and quote != "'": escaped = True; continue
            if quote:
                if char == quote: quote = None
                continue
            if char in ("'", '"'): quote = char; continue
            if char == '#' and (offset == 0 or line[offset-1].isspace()): break
            if char == '<' and (offset == 0 or line[offset-1] != '<'):
                match = re.match(r"<<(-?)[ \t]*(?:'([A-Za-z_][A-Za-z_0-9]*)'|\"([A-Za-z_][A-Za-z_0-9]*)\"|([A-Za-z_][A-Za-z_0-9]*))", line[offset:])
                if match: return match
        return None
    while i < len(lines):
        line = lines[i]; i += 1
        match = heredoc_start(line)
        shell_lines.append(line)
        if not match: continue
        delimiter = next(x for x in match.groups()[1:] if x is not None)
        body = []
        while i < len(lines):
            content = lines[i]; i += 1
            end = content.rstrip('\r\n')
            if (end.lstrip('\t') if match[1] else end) == delimiter: break
            body.append(content)
        else: raise ValueError('heredoc 종료를 확인할 수 없습니다.')
        if re.search(r'(?:^|[\s/|;&])(?:python[0-9.]*|node|sh|bash|zsh)(?:\s|$)', line):
            embedded.append(['embedded-code', ''.join(body)])
    text = ''.join(shell_lines)
    lexer = shlex.shlex(text, posix=True, punctuation_chars=';&|()<>\n')
    lexer.whitespace = ' \t\r'; lexer.whitespace_split = True
    parts, part = [], []
    for word in lexer:
        if word and all(c in ';&|()<>\n' for c in word):
            if part: parts.append(part)
            part = []
        else: part.append(word)
    if part: parts.append(part)
    result = embedded
    for args in parts:
        while args and (args[0] in ('env','command','exec','sudo') or re.match(r'^[\w]+=', args[0])): args = args[1:]
        if not args: continue
        name = Path(args[0]).name
        if name in ('sh','bash','zsh') and len(args)>2 and args[1] in ('-c','-lc'):
            result.extend(shell_segments(args[2], depth+1, cwd)); continue
        result.append(args)
        script_arg = (args[1] if name in ('python','python3','node','sh','bash','zsh') and len(args)>1 and not args[1].startswith('-')
                      else args[0] if '/' in args[0] else None)
        if script_arg:
            script = Path(script_arg)
            if not script.is_absolute(): script = Path(cwd or Path.cwd()) / script
            if script.is_file() and script.stat().st_size <= 262144:
                # Only inspect device-related scripts. Never run/import them.
                source = script.read_text(errors='replace')
                if re.search(r'devicectl|simctl|ios-deploy|ideviceinstaller', source): result.append(['embedded-code', source])
    return result


def resource_guard(provider, payload, root=ROOT):
    if payload.get('hook_event_name') != 'PreToolUse': return {}
    name = payload.get('tool_name', '')
    data = payload.get('tool_input') or {}
    if not isinstance(data, dict): return {}
    def deny(reason):
        return {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                                       'permissionDecisionReason': 'Modore: ' + reason}}
    target = None
    shell = name in ('Bash','exec_command','functions.exec_command')
    if shell:
        text = data.get('command', data.get('cmd', ''))
        if isinstance(text, list): text = shlex.join(text)
        if re.search(r'\|\s*(?:/\S+/)?(?:sh|bash|zsh|python3?|node)\b', text) and re.search(r'devicectl|simctl|ios-deploy|ideviceinstaller', text):
            return deny('기기 명령을 인터프리터에 전달하는 대신 명시적인 시뮬레이터 명령을 사용하세요.')
        # File paths are resolved against the host-provided cwd, not the hook process.
        for args in shell_segments(text, cwd=payload.get('cwd')):
            command_name = Path(args[0]).name
            if command_name in ('echo','printf','cat','rg','grep','sed','head','tail'): continue
            combined = ' '.join(args)
            physical = any(Path(a).name in ('devicectl','ios-deploy','ideviceinstaller','idevicedebug') for a in args)
            embedded = command_name in ('python','python3','node','embedded-code')
            if physical or (embedded and re.search(r'devicectl|ios-deploy|ideviceinstaller|idevicedebug', combined)):
                return deny('개인 실기기 접근은 허용되지 않습니다. 앱에 연결한 시뮬레이터를 사용하세요.')
            if any(Path(a).name == 'xcodebuild' for a in args):
                destination = next((args[i+1] for i,a in enumerate(args[:-1]) if a == '-destination'), '')
                simulator = 'Simulator' in destination
                if destination and not simulator and re.search(r'(?:^|,)\s*(?:id=|platform=(?:iOS|watchOS|tvOS|visionOS)(?:,|$))', destination):
                    return deny('실기기 빌드 대상은 허용되지 않습니다. 시뮬레이터 대상을 지정하세요.')
                if simulator or any(a in ('test','test-without-building') for a in args):
                    match = re.search(r'(?:^|,)\s*id=([^,]+)', destination)
                    if not simulator or not match: return deny('테스트 대상에 시뮬레이터 UDID를 명시하세요.')
                    current = match[1].strip()
                    if target and target != current: return deny('한 호출에서 서로 다른 기기를 변경할 수 없습니다.')
                    target = current
            if embedded and 'simctl' in combined:
                return deny('스크립트 내부 기기 조작 대신 명시적인 시뮬레이터 명령을 사용하세요.')
            sim = next((i for i,a in enumerate(args) if Path(a).name == 'simctl'), None)
            if sim is not None and len(args)>sim+1:
                action = args[sim+1]
                if action in ('list','help'): continue
                if action in ('create','clone'): return simulator_guard(provider, payload)
                if action in ('delete','erase','shutdown') and (len(args)<=sim+2 or args[sim+2]=='all'):
                    return deny('전체 시뮬레이터 변경은 허용되지 않습니다.')
                if len(args)<=sim+2: return deny('명시적인 시뮬레이터 UDID가 필요합니다.')
                current = args[sim+2]
                if target and current != target: return deny('한 호출에서 서로 다른 기기를 변경할 수 없습니다.')
                target = current
    elif name.startswith('mcp__'):
        operation = name.rsplit('__', 1)[-1]
        physical = re.search(r'(?:install|launch|run|stop|terminate|uninstall|debug|copy|tap|swipe|list).*device|device.*(?:install|launch|run|stop|terminate|uninstall|debug|copy|tap|swipe)', operation, re.I)
        if physical: return deny('실기기 MCP 조작은 허용되지 않습니다. 시뮬레이터 도구를 사용하세요.')
        if re.search(r'simulator|simctl|_sim(?:_|$)', name, re.I):
            if re.search(r'(?:list|read|status|get_).*', name) and not any(k in data for k in ('action','operation')): return {}
            target = next((data[k] for k in ('udid','simulatorId','simulatorUDID','deviceId','deviceUDID') if data.get(k)), None)
            if not target: return deny('시뮬레이터 MCP 호출에 UDID를 명시하세요.')
    if target:
        if target in ('booted','all'): return deny('booted/all 대신 앱에 연결한 기기 UDID를 명시하세요.')
        req = {'project': payload.get('cwd'), 'session': payload.get('session_id'), 'provider': provider}
        rows = devices()
        r = next((r for r in rows if r['id'] == target and r['available']), None)
        if r is None: return deny('시뮬레이터로 확인되지 않는 대상입니다.')
        req.update(runtime=r['runtime'], deviceType=r['deviceType'])
        with registry(root) as state:
            expected = assigned_resource(state, req, rows)
            if expected and expected['id'] != target: return deny('앱에 지정한 기기와 다릅니다: ' + expected['id'])
            leases = unresolved_leases(state, target)
            if any(not same_session(l, req['session'], provider) for l in leases): return deny('다른 세션이 사용하는 기기입니다.')
            if not any(same_session(l, req['session'], provider) for l in leases): return deny('먼저 modore resources acquire 또는 begin-test로 기존 기기를 등록하세요.')
            state.setdefault('guardObservations', {})[turn_key(provider, req['session'])] = {
                'observedAt': time.time(), 'resourceID': target, 'turn': payload.get('turn_id')}
    return {}


def install_hooks(provider, root=ROOT, home=None, executable=None):
    """Merge our lifecycle and CLI guard handlers; never grant Codex hook trust."""
    turn_key(provider, 'install')
    home = Path.home() if home is None else Path(home)
    executable = Path(__file__).resolve().parents[1] / 'bin/modore' if executable is None else Path(executable)
    path = home / ('.codex/hooks.json' if provider == 'codex' else '.claude/settings.json')
    if not executable.is_file() or not executable.is_absolute():
        raise ValueError('실제 Modore 명령 경로가 필요합니다.')
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError('심볼릭 링크 설정은 자동 수정하지 않습니다.')
    path.parent.mkdir(parents=True, exist_ok=True)
    before = path.read_bytes() if path.exists() else None
    config = json.loads(before) if before else {}
    if config.get('disableAllHooks'):
        raise ValueError('Claude 훅이 비활성화돼 있습니다. 사용자 설정을 유지합니다.')
    hooks = config.setdefault('hooks', {})
    # Replace our old definitions instead of accumulating obsolete guards.
    for event in ('UserPromptSubmit', 'Stop', 'PreToolUse'):
        cleaned = []
        for group in hooks.get(event, []):
            keep = []
            for handler in group.get('hooks', []):
                words = shlex.split(handler.get('command', ''))
                ours = words and Path(words[0]).name == 'modore' and words[1:3] in (['resources','hook'], ['resources','guard'], ['tools','hook'])
                if not ours: keep.append(handler)
            if keep: cleaned.append({**group, 'hooks': keep})
        hooks[event] = cleaned
    command_text = shlex.quote(str(executable)) + ' resources hook --provider ' + provider
    for event in ('UserPromptSubmit', 'Stop'):
        groups = hooks.setdefault(event, [])
        expected = {'hooks': [{'type': 'command', 'command': command_text, 'timeout': 60}]}
        if expected not in groups:
            groups.append(expected)
    guard = {'matcher': '^Bash$', 'hooks': [{'type': 'command',
             'command': shlex.quote(str(executable)) + ' tools hook', 'timeout': 5}]}
    if guard not in hooks.setdefault('PreToolUse', []):
        hooks['PreToolUse'].append(guard)
    simulator = {'matcher': '*', 'hooks': [{'type': 'command',
                 'command': shlex.quote(str(executable)) + ' resources guard --provider ' + provider, 'timeout': 15}]}
    if simulator not in hooks['PreToolUse']:
        hooks['PreToolUse'].append(simulator)
    changed = not before or json.loads(before) != config
    backup = None
    if changed:
        with registry(root):
            if (path.read_bytes() if path.exists() else None) != before:
                raise ValueError('설정이 다른 작업에서 바뀌었습니다. 다시 실행하세요.')
            if before:
                backup = root / (provider + '-hooks-backup-' + str(uuid.uuid4()) + '.json')
                atomic(backup, json.loads(before))
            atomic(path, config)
    return {'config': str(path), 'changed': changed, 'backup': str(backup) if backup else None,
            'reviewRequired': provider == 'codex',
            'instruction': 'Codex /hooks에서 Modore 수명주기 훅과 CLI 재사용 훅을 검토·신뢰해야 실행됩니다. 설정 저장은 실행 확인이 아닙니다.' if provider == 'codex' else '새 턴에서 훅 적용을 확인하세요. 실행 중 세션은 훅 설정 새로고침이 필요할 수 있습니다.'}


def mutate(req, root=ROOT):
    action = req['action']; rid = req.get('id')
    if action not in ('boot', 'shutdown', 'delete-duplicate', 'eject', 'prefer'): raise ValueError('지원하지 않는 동작')
    # Serialize mutations with lease registration. Re-observe immediately before use.
    with registry(root) as state:
        rows = devices(); vs, _ = volumes(); rows += vs
        r = next((x for x in rows if x['id'] == rid), None)
        if r is None or r['fingerprint'] != req.get('fingerprint'):
            raise ValueError('대상 식별이 바뀌었습니다. 새로 확인하세요.')
        if active_leases(state, rid) and action in ('shutdown', 'delete-duplicate', 'eject') and not req.get('override'):
            raise ValueError('연결된 세션이 있습니다. 영향 경고를 확인하고 계속할 수 있습니다.')
        if action == 'prefer':
            if r['kind'] != 'simulator': raise ValueError('시뮬레이터만 기본 지정 가능')
            state['preferred'][r['runtime'] + '/' + r['deviceType']] = rid
            state['preferred'][r['runtime'] + '/'] = rid
            return {'message': '공용 재사용 기기로 지정했습니다.'}
        if action == 'eject':
            if r['kind'] != 'volume': raise ValueError('외장 볼륨만 추출 가능')
            args = ['/usr/sbin/diskutil', 'eject', r['path']]
        else:
            if r['kind'] != 'simulator': raise ValueError('시뮬레이터만 조작 가능')
            if action == 'delete-duplicate':
                if r['state'] != 'Shutdown' or not r['duplicates']:
                    raise ValueError('꺼진 동일 OS·기종 중복 기기만 삭제할 수 있습니다.')
                pairs = json.loads(command(['/usr/bin/xcrun', 'simctl', 'list', 'pairs', '--json']))
                if rid in json.dumps(pairs): raise ValueError('페어링을 먼저 해제해야 합니다.')
            args = ['/usr/bin/xcrun', 'simctl', {'delete-duplicate': 'delete'}.get(action, action), rid]
        receipt = {'id': str(uuid.uuid4()), 'resource': r, 'action': action,
                   'startedAt': time.time(), 'status': 'attempting',
                   'freeBytesBefore': os.statvfs(str(Path.home())).f_bavail * os.statvfs(str(Path.home())).f_frsize}
        root.mkdir(parents=True, exist_ok=True)
        path = root / ('receipt-' + receipt['id'] + '.json'); atomic(path, receipt)
        try:
            receipt['output'] = command(args, 45).decode(errors='replace')
            receipt['status'] = 'succeeded'
        except Exception as exc:
            receipt['status'] = 'failed'; receipt['output'] = str(exc)
        receipt['finishedAt'] = time.time()
        try:
            if r['kind'] == 'simulator':
                fresh = devices()
            else:
                fresh, errors = volumes()
                if errors: raise ValueError('추출 후 볼륨 조회 불완전')
            item = next((x for x in fresh if x['id'] == rid), None)
            receipt['verified'] = ((item is None) if action in ('eject', 'delete-duplicate') else
                                   item is not None and item['state'] == ('Booted' if action == 'boot' else 'Shutdown'))
        except Exception:
            receipt['verified'] = False
        receipt['freeBytesAfter'] = os.statvfs(str(Path.home())).f_bavail * os.statvfs(str(Path.home())).f_frsize
        atomic(path, receipt)
        return {'message': receipt['status'] + ' · 사후 확인 ' + str(receipt['verified']), 'receipt': str(path), 'result': receipt}


def dispatch(req, root=ROOT):
    action = req.get('action', 'status')
    if action == 'status': return snapshot(root)
    if action == 'diagnose-hooks': return diagnose_hooks(req, root)
    if action in ('acquire', 'claim'): return register(req, root)
    if action in ('bind', 'unbind'):
        project, session = project_session(req)
        provider, session = identity(req['session'], req.get('provider', ''))
        if not provider: raise ValueError('연결할 세션의 제공자가 필요합니다.')
        with registry(root) as state:
            if action == 'unbind':
                state['bindings'] = [b for b in state['bindings'] if not (b['project'] == project and same_session(b, session, provider) and b['resourceID'] == req.get('id'))]
            else:
                rows = devices(); vs, _ = volumes(); rows += vs
                r = next((r for r in rows if r['id'] == req.get('id')), None)
                if not r or r['fingerprint'] != req.get('fingerprint'): raise ValueError('기기 식별이 바뀌었습니다.')
                state['bindings'] = [b for b in state['bindings'] if not (b['project'] == project and same_session(b, session, provider)
                    and b['runtime'] == r['runtime'] and b['deviceType'] == r['deviceType'])]
                state['bindings'].append({'resourceID': r['id'], 'project': project, 'provider': provider, 'session': session,
                    'runtime': r['runtime'], 'deviceType': r['deviceType'], 'fingerprint': r['fingerprint']})
        return {'message': '프로젝트 기기 설정을 저장했습니다. 사용 등록이 만료돼도 유지됩니다.' if action == 'bind' else '프로젝트 기기 연결을 해제했습니다.'}
    if action == 'begin-test': return begin_test(req, root)
    if action == 'begin-browser-test': return begin_browser_test(req, root)
    if action == 'install-hooks': return install_hooks(req.get('provider'), root)
    if action == 'hold':
        key = turn_key(req.get('provider'), req.get('session'))
        with registry(root) as state:
            found = False
            for lease in state['leases']:
                if (lease['resourceID'] == req.get('id') and lease.get('turnKey') == key and
                        lease.get('turn') == req.get('turn') and not lease.get('releasedAt')):
                    lease['lifetime'] = 'session'; found = True
            if not found: raise ValueError('현재 턴에 등록된 테스트 자원을 찾지 못했습니다.')
        return {'message': '사용자 검토/백그라운드 테스트용으로 유지합니다. 사용이 끝나면 release가 필요합니다.'}
    if action in ('heartbeat', 'release'):
        if not req.get('session'): raise ValueError('세션 ID가 필요합니다.')
        with registry(root) as state:
            targets = set()
            for x in state['leases']:
                if same_session(x, req['session'], req.get('provider', '')) and (not req.get('id') or x['resourceID'] == req['id']):
                    if action == 'heartbeat' and x.get('releasedAt'): continue
                    x['updatedAt'] = time.time(); x['expiresAt'] = time.time() + (900 if action == 'heartbeat' else -1)
                    if action == 'release':
                        x['releasedAt'] = time.time()
                        targets.add(x['resourceID'])
                        if x.get('turnKey'):
                            run = state.get('testRuns', {}).get(x['resourceID'])
                            if run and run['id'] == x.get('runID'): run['stopRequested'] = True
                            browser = state.get('browserRuns', {}).get(x['resourceID'])
                            if browser and browser['id'] == x.get('runID'): browser['stopRequested'] = True
            results = []
            if action == 'release':
                save_registry(root, state)
                results = settle_tests(state, root, targets) + settle_browsers(state, root, targets)
        return {'message': action, 'results': results}
    return mutate(req, root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', default='status')
    for flag in ['id','runtime','deviceType','session','project','fingerprint','provider','turn','cli','node','url']:
        parser.add_argument('--'+flag, default='')
    parser.add_argument('--override', action='store_true')
    parser.add_argument('--headed', action='store_true')
    parser.add_argument('--request-file')
    args = vars(parser.parse_args())
    if args['action'] == 'guard':
        try:
            raw = sys.stdin.buffer.read(2_097_153)
            if len(raw) > 2_097_152: raise ValueError('hook input too large')
            result = resource_guard(args['provider'], json.loads(raw))
        except Exception:
            result = {'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                      'permissionDecision': 'deny', 'permissionDecisionReason': 'Modore: 작업 환경 검사 실패. 명령과 resources status를 확인하세요.'}}
        print(json.dumps(result, ensure_ascii=False))
        return 0
    if args['action'] == 'hook':
        # A hook must not continue, interrupt or block the AI session on failure.
        # In particular, never return exit 2 or a Stop decision field.
        try:
            raw = sys.stdin.buffer.read(2_097_153)
            if len(raw) > 2_097_152: raise ValueError('hook input too large')
            payload = json.loads(raw)
            if not isinstance(payload, dict): raise ValueError('hook input must be an object')
            result = turn_hook(args['provider'], payload)
        except Exception:
            result = {'systemMessage': 'Modore: 턴 자원 연결을 확인하지 못했습니다. 자동 종료를 보류합니다.'}
        print(json.dumps(result, ensure_ascii=False))
        return 0
    try:
        if args.get('request_file'): args = json.loads(Path(args['request_file']).read_text())
        result = dispatch(args)
        print(json.dumps(result, ensure_ascii=False))
        return 1 if 'error' in result else 0
    except Exception as exc:
        print(json.dumps({'error': str(exc)}, ensure_ascii=False)); return 1


if __name__ == '__main__': sys.exit(main())
