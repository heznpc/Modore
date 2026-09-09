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
        fcntl.flock(fd, fcntl.LOCK_EX)
        path = root / 'leases.json'
        if path.is_symlink(): raise ValueError('Registry file is a symlink')
        state = json.loads(path.read_text()) if path.exists() else {'leases': [], 'preferred': {}}
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


def devices():
    return simulator_rows(json.loads(command(['/usr/bin/xcrun', 'simctl', 'list', 'devices', '--json'])))


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
    return [x for x in state['leases'] if x['resourceID'] == rid and x['expiresAt'] > now]


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
    return {'observedAt': time.time(), 'resources': rows, 'warnings': warnings,
            'coverage': '프로세스 연결은 열린 파일 관찰, 세션 연결은 명시적 사용 등록입니다. 미등록 세션의 소속은 알 수 없습니다.'}


def select_existing(rows, runtime='', device_type='', preferred=None):
    candidates = [r for r in rows if r['kind'] == 'simulator' and r['available']
                  and (not runtime or r['runtime'] == runtime) and (not device_type or r['deviceType'] == device_type)]
    if not candidates: raise ValueError('일치하는 기존 기기가 없습니다. 자동으로 새 기기를 만들지 않습니다.')
    return sorted(candidates, key=lambda r: (r['id'] != preferred, r['state'] != 'Booted', not bool(r['lastBooted']), r['id']))[0]


def register(req, root=ROOT):
    session = req.get('session', '').strip(); project = req.get('project', '').strip()
    if not session or len(session) > 256 or not os.path.isabs(project) or not Path(project).is_dir():
        raise ValueError('실제 프로젝트 절대 경로와 세션 ID가 필요합니다.')
    project = str(Path(project).resolve())
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
        state['leases'] = [x for x in state['leases'] if not (x['session'] == session and x['resourceID'] == r['id'])]
        state['leases'].append({'resourceID': r['id'], 'session': session, 'project': project,
                               'updatedAt': time.time(), 'expiresAt': time.time() + 900})
        return {'resource': r, 'leases': active_leases(state, r['id']), 'instruction': '이 UDID를 모든 simctl/시뮬레이터 도구 호출에 명시하세요. 5분마다 heartbeat, 종료 시 release. 기기를 새로 만들지 마세요.'}


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
    if action in ('heartbeat', 'release'):
        if not req.get('session'): raise ValueError('세션 ID가 필요합니다.')
        with registry(root) as state:
            for x in state['leases']:
                if x['session'] == req['session']:
                    x['updatedAt'] = time.time(); x['expiresAt'] = time.time() + (900 if action == 'heartbeat' else -1)
        return {'message': action}
    return mutate(req, root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', default='status')
    for flag in ['id','runtime','deviceType','session','project','fingerprint']:
        parser.add_argument('--'+flag, default='')
    parser.add_argument('--override', action='store_true')
    parser.add_argument('--request-file')
    args = vars(parser.parse_args())
    if args.get('request_file'): args = json.loads(Path(args['request_file']).read_text())
    try: print(json.dumps(dispatch(args), ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({'error': str(exc)}, ensure_ascii=False)); return 1
    return 0


if __name__ == '__main__': sys.exit(main())
