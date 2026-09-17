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
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

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
        browser_runs = list(state.get('browserRuns', {}).values())
    return {'observedAt': time.time(), 'resources': rows, 'browsers': browser_runs, 'warnings': warnings,
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
    return project, session


def register(req, root=ROOT):
    project, session = project_session(req)
    rows = devices()
    vs, _ = volumes(); rows += vs
    with registry(root) as state:
        if req.get('id'):
            r = next((r for r in rows if r['id'] == req['id']), None)
            if r is None: raise ValueError('대상을 찾지 못했습니다.')
        else:
            runtime = req.get('runtime', '')
            if not runtime: raise ValueError('재사용할 runtime ID를 지정하세요.')
            key = runtime + '/' + req.get('deviceType', '')
            r = select_existing(rows, runtime, req.get('deviceType', ''), state['preferred'].get(key))
            state['preferred'][key] = r['id']
        if any(x['session'] == session and x['resourceID'] == r['id'] and
               x.get('lifetime') == 'turn' and not x.get('releasedAt') for x in state['leases']):
            raise ValueError('턴 테스트로 등록된 기기입니다. begin-test로 재사용하거나 hold로 유지하세요.')
        state['leases'] = [x for x in state['leases'] if not (x['session'] == session and x['resourceID'] == r['id'])]
        state['leases'].append({'resourceID': r['id'], 'session': session, 'project': project,
                               'updatedAt': time.time(), 'expiresAt': time.time() + 900})
        return {'resource': r, 'leases': active_leases(state, r['id']), 'instruction': '이 UDID를 모든 simctl/시뮬레이터 도구 호출에 명시하세요. 5분마다 heartbeat, 종료 시 release. 기기를 새로 만들지 마세요.'}


def turn_key(provider, session):
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
                       'It does not close ordinary Chrome, external browser tools, or unregistered browsers.')
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


def install_hooks(provider, root=ROOT, home=None, executable=None):
    """Merge only our two handlers. Never grant Codex hook trust programmatically."""
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
    command_text = shlex.quote(str(executable)) + ' resources hook --provider ' + provider
    for event in ('UserPromptSubmit', 'Stop'):
        groups = hooks.setdefault(event, [])
        expected = {'hooks': [{'type': 'command', 'command': command_text, 'timeout': 60}]}
        if expected not in groups:
            groups.append(expected)
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
            'instruction': 'Codex /hooks에서 두 Modore 훅을 검토·신뢰해야 실행됩니다.' if provider == 'codex' else '새 턴에서 훅 적용을 확인하세요. 실행 중 세션은 훅 설정 새로고침이 필요할 수 있습니다.'}


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
    if action in ('acquire', 'claim'): return register(req, root)
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
                if x['session'] == req['session'] and (not req.get('id') or x['resourceID'] == req['id']):
                    if req.get('provider') and x.get('provider') != req['provider']: continue
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
