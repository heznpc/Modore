#!/usr/bin/env python3
"""Receipts and conservative retirement for Modore-owned build products.

Unknown directories are not adopted by name. Failed/interrupted runs and evidence
remain protected. Only a completed run's unchanged, unused products may retire.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid

STATE = Path.home() / 'Library/Application Support/Modore/build-artifacts'
CACHE = Path.home() / 'Library/Caches/Modore/build-runtime/python'
KINDS = {'scratch', 'staging', 'app', 'recovery', 'runtime', 'evidence'}
ARCHIVE_NAME = re.compile(r'cpython-[0-9.]+\+[0-9]{8}-(aarch64|x86_64)-apple-darwin-install_only_stripped\.tar\.gz')


def artifact_app(item):
    path = Path(item['path'])
    return path if path.name == 'Modore.app' else path/'Modore.app'


def safe_path(path):
    p = Path(path).absolute()
    if p.resolve() != p or any(part in ('..', '.') for part in p.parts):
        raise ValueError('경로에 심볼릭 링크 또는 불명확한 구성요소가 있습니다.')
    return p


def owned(path):
    s = Path(path).lstat()
    if s.st_uid != os.getuid() or s.st_mode & 0o022 or stat.S_ISLNK(s.st_mode):
        raise ValueError('소유권·권한을 확인하지 못했습니다.')
    return s


def identity(path):
    s = owned(path)
    return [s.st_dev, s.st_ino]


def seal(path):
    """Metadata seal plus hashes of file contents; no symlink traversal."""
    p = safe_path(path); root = owned(p); h = hashlib.sha256(); size = 0
    entries = [p]
    if p.is_dir():
        for directory, dirs, files in os.walk(p, followlinks=False):
            entries.extend(Path(directory) / name for name in dirs + files)
    evidence = False
    for entry in sorted(entries):
        s = entry.lstat()
        if s.st_dev != root.st_dev or s.st_uid != os.getuid():
            raise ValueError('다른 볼륨·소유자의 파일이 섞여 있습니다.')
        if entry.suffix in ('.xcresult', '.logarchive', '.trace', '.mov', '.mp4', '.log'):
            evidence = True
        relative = str(entry.relative_to(p))
        h.update(json.dumps([relative, s.st_mode, s.st_size, s.st_mtime_ns], sort_keys=True).encode())
        if stat.S_ISLNK(s.st_mode):
            h.update(os.readlink(entry).encode())
        elif stat.S_ISREG(s.st_mode):
            if s.st_nlink != 1: raise ValueError('공유 하드링크가 있어 보존합니다.')
            with entry.open('rb') as source:
                for chunk in iter(lambda: source.read(1024*1024), b''): h.update(chunk)
            size += s.st_blocks * 512
        elif not stat.S_ISDIR(s.st_mode):
            raise ValueError('특수 파일이 있어 보존합니다.')
    return dict(digest=h.hexdigest(), bytes=size, evidence=evidence)


def process_identity(pid):
    try:
        result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'lstart='], capture_output=True, text=True, timeout=5)
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired): return None


def usage_snapshot():
    try:
        result = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-u', str(os.getuid()), '-Fpn'],
                                capture_output=True, text=True, timeout=20)
        if result.returncode not in (0, 1) or result.stderr.strip(): return None
        return [line[1:] for line in result.stdout.splitlines() if line.startswith('n') and line[1:].startswith('/')]
    except (OSError, subprocess.TimeoutExpired): return None


def app_hash(path):
    try:
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(path)],
                       capture_output=True, timeout=30, check=True)
        out = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(path)],
                             capture_output=True, text=True, timeout=10, check=True)
        if 'Identifier=me.heznpc.modore' not in out.stderr.splitlines(): return None
        return next(line.split('=', 1)[1] for line in out.stderr.splitlines() if line.startswith('CDHash='))
    except (OSError, StopIteration, subprocess.SubprocessError): return None


def file_hash(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()


class Store:
    def __init__(self, root=STATE): self.root = safe_path(root)

    @contextlib.contextmanager
    def locked(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700); owned(self.root)
        fd = os.open(self.root/'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            s = os.fstat(fd)
            if s.st_uid != os.getuid() or s.st_nlink != 1: raise ValueError('잠금 파일 검증 실패')
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally: os.close(fd)

    def file(self, key):
        uuid.UUID(key)
        return self.root/(key+'.json')

    def save(self, run):
        fd, name = tempfile.mkstemp(dir=self.root)
        try:
            with os.fdopen(fd, 'w') as out:
                json.dump(run, out, ensure_ascii=False); out.flush(); os.fsync(out.fileno())
            os.replace(name, self.file(run['id']))
        finally:
            if os.path.exists(name): os.unlink(name)

    def load(self, key):
        path = self.file(key); owned(path)
        if path.stat().st_size > 2_000_000: raise ValueError('빌드 기록이 너무 큽니다.')
        return json.loads(path.read_text())

    def runs(self):
        records = []
        for p in self.root.glob('*.json'):
            try: records.append(self.load(p.stem))
            except (ValueError, OSError): continue
        return sorted(records, key=lambda x: x['startedAt'], reverse=True)

    def begin(self, repository, output, pid):
        repository = safe_path(repository); output = safe_path(output)
        owned(repository); owned(output)
        temporary = Path(tempfile.gettempdir()).resolve()
        if not output.is_relative_to(repository/'build') and not (output != temporary and output.is_relative_to(temporary)):
            raise ValueError('출력은 저장소 build 또는 사용자 임시 폴더 아래에 있어야 합니다.')
        owner = process_identity(pid)
        if not owner: raise ValueError('실행 프로세스 식별 실패')
        run = dict(id=str(uuid.uuid4()), repository=str(repository), output=str(output),
                   startedAt=time.time(), finishedAt=None, status='running', pid=pid, processIdentity=owner,
                   validation='', artifacts=[], installedLinks=[])
        self.save(run); return run

    def track(self, key, kind, path, generated=False):
        run = self.load(key); p = safe_path(path)
        if run['status'] != 'running' or kind not in KINDS: raise ValueError('진행 중인 빌드만 생성물을 등록할 수 있습니다.')
        allowed = [Path(run['repository'])/'build', Path(tempfile.gettempdir()).resolve(), CACHE]
        if not any(p != parent and p.is_relative_to(parent) for parent in allowed):
            raise ValueError('관리 범위 밖의 생성물입니다.')
        s = owned(p)
        if kind in ('app', 'recovery'):
            app = artifact_app({'path': str(p)})
            if kind == 'app' and p.name != 'Modore.app': raise ValueError('Modore 앱 경로가 아닙니다.')
            if kind == 'recovery' and p.name != 'Modore.app':
                if not p.name.startswith('.pch-app-backup.') or {x.name for x in p.iterdir()} != {'Modore.app', '.pch-build-identity'}:
                    raise ValueError('복구본 컨테이너에 알 수 없는 파일이 있습니다.')
            if not app_hash(app): raise ValueError('검증된 Modore 앱만 등록할 수 있습니다.')
        if kind == 'runtime' and not ARCHIVE_NAME.fullmatch(p.name):
            raise ValueError('고정 Python 런타임 아카이브가 아닙니다.')
        # The packager's private staging marker is creation evidence. Existing
        # user directories cannot become disposable just by choosing a kind.
        if kind in ('scratch', 'staging') and not generated:
            marker = p/'.pch-build-identity'
            expected = hashlib.sha256((run['repository']+'\0'+run['output']+'\0').encode()).hexdigest()
            if not marker.is_file() or marker.read_text().strip() != expected:
                raise ValueError('생성 기록이 없는 경로는 자동 회수 대상으로 등록하지 않습니다.')
            if getattr(s, 'st_birthtime', s.st_ctime) < run['startedAt']-2:
                raise ValueError('이번 실행 전에 존재한 경로입니다.')
        artifact = dict(id=str(uuid.uuid4()), kind=kind, path=str(p), identity=identity(p),
                        createdAt=time.time(), seal=None, removedAt=None)
        run['artifacts'].append(artifact); self.save(run); return artifact

    def allocate_scratch(self, key, retry_failed=False):
        run = self.load(key); path = Path(run['output'])/'swift-verification'
        if retry_failed and path.exists():
            current = usage_snapshot()
            if current is None or any(q == str(path) or q.startswith(str(path)+'/') for q in current):
                raise ValueError('이전 검증 폴더의 미사용을 확인하지 못했습니다.')
            previous = next(((r, a) for r in self.runs() for a in r['artifacts']
                             if a['path'] == str(path) and a['identity'] == identity(path)
                             and (r['status'] == 'failed' or (r['status'] == 'running'
                                  and process_identity(r['pid']) != r['processIdentity']))), None)
            if previous is None: raise ValueError('보존할 실패·중단 기록을 확인하지 못했습니다.')
            old, item = previous
            failed = safe_path(Path(run['output'])/'failed')
            failed.mkdir(mode=0o700, exist_ok=True); owned(failed)
            destination = failed/old['id']
            if destination.exists(): raise ValueError('실패 기록 보존 경로가 이미 존재합니다.')
            path.rename(destination)
            item['path'] = str(destination); self.save(old)
        path.mkdir(mode=0o700)  # Refuse to overwrite a failed or occupied slot.
        return self.track(key, 'scratch', path, generated=True)

    def finish(self, key, success, validation):
        run = self.load(key)
        if run['status'] != 'running': raise ValueError('이미 종료된 빌드 기록입니다.')
        if process_identity(run['pid']) != run['processIdentity']: raise ValueError('원래 실행 프로세스가 종료되었습니다. 중단 기록을 보존합니다.')
        run.update(status='verified' if success else 'failed', finishedAt=time.time(), validation=validation)
        for item in run['artifacts']:
            if not Path(item['path']).exists(): continue
            try:
                if identity(item['path']) != item['identity']: raise ValueError('생성물 식별 변경')
                if success: item['seal'] = seal(item['path'])
                if item['kind'] in ('app', 'recovery'): item['appHash'] = app_hash(artifact_app(item))
            except (OSError, ValueError) as error: item['protection'] = str(error)
        self.save(run); return run

    def seed_runtime(self, repository):
        """Reuse archives attested by an existing signed product before download."""
        CACHE.mkdir(parents=True, exist_ok=True, mode=0o700); owned(safe_path(CACHE))
        seeded = []
        for cache in (safe_path(repository)/'build').glob('*/.python-runtime-cache'):
            if not app_hash(cache.parent/'Modore.app'): continue
            try:
                provenance = (cache.parent/'Modore.app/Contents/Resources/modore-python/ORIGIN.txt').read_text()
                for archive in cache.glob('cpython-*.tar.gz'):
                    if not ARCHIVE_NAME.fullmatch(archive.name): continue
                    owned(safe_path(archive)); digest = file_hash(archive)
                    destination = CACHE/archive.name
                    if digest not in provenance or destination.exists(): continue
                    fd, temporary = tempfile.mkstemp(dir=CACHE)
                    try:
                        with os.fdopen(fd, 'wb') as out, archive.open('rb') as source:
                            shutil.copyfileobj(source, out)
                        if file_hash(temporary) != digest: raise ValueError('복사 중 런타임 변경')
                        os.replace(temporary, destination); seeded.append(str(destination))
                    finally:
                        if os.path.exists(temporary): os.unlink(temporary)
            except (OSError, ValueError): continue
        return seeded

    def import_runtime_duplicates(self, repository):
        """Adopt only archives proven by a signed product AND the shared copy."""
        known = self.runs(); imported = []
        for cache in (safe_path(repository)/'build').glob('*/.python-runtime-cache'):
            output = cache.parent
            if any(r['output'] == str(output) and r['status'] != 'verified' for r in known): continue
            if not app_hash(output/'Modore.app'): continue
            origin = output/'Modore.app/Contents/Resources/modore-python/ORIGIN.txt'
            try: provenance = origin.read_text()
            except OSError: continue
            for archive in cache.glob('cpython-*.tar.gz'):
                if not ARCHIVE_NAME.fullmatch(archive.name): continue
                if any(a['path'] == str(archive) for r in known for a in r['artifacts']): continue
                try:
                    safe_path(archive); owned(archive); owned(CACHE/archive.name)
                    digest = file_hash(archive)
                    if digest not in provenance or digest != file_hash(CACHE/archive.name): continue
                    run = self.begin(repository, output, os.getpid())
                    self.track(run['id'], 'runtime', archive)
                    self.finish(run['id'], True, '서명된 기존 앱의 ORIGIN·공용 캐시 SHA256 일치')
                    imported.append(run['id'])
                except (OSError, ValueError): continue
        return imported

    def link(self, key, installed):
        run = self.load(key); installed = safe_path(installed); value = app_hash(installed)
        if not value or not any(a.get('appHash') == value for a in run['artifacts']):
            raise ValueError('설치본의 서명이 해당 빌드와 일치하지 않습니다.')
        run['installedLinks'] = [x for x in run['installedLinks'] if x['path'] != str(installed)]
        run['installedLinks'].append(dict(path=str(installed), appHash=value, observedAt=time.time()))
        self.save(run); return run

    def report(self, reclaim=False, artifact_ids=None):
        runs = self.runs(); opened = usage_snapshot(); rows = []; retained = set()
        cache_repositories = set(); needed_caches = set()
        # One final and one recovery bundle per repository across output names.
        for run in runs:
            if run['status'] != 'verified': continue
            if run['repository'] not in cache_repositories and any(a['kind'] == 'app' for a in run['artifacts']):
                cache_repositories.add(run['repository'])
                needed_caches.update(a['path'] for a in run['artifacts'] if a['kind'] == 'runtime')
            for a in run['artifacts']:
                slot = (run['repository'], a['kind'])
                if a['kind'] in ('app', 'recovery') and Path(a['path']).exists() and slot not in retained:
                    retained.add(slot); retained.add(a['id'])
        live = [r for r in runs if r['status'] == 'running' and process_identity(r['pid']) == r['processIdentity']]
        installed_hashes = set(); current_links = {}
        for run in runs:
            for link in run['installedLinks']:
                if link['path'] not in current_links: current_links[link['path']] = app_hash(link['path'])
                if current_links[link['path']] == link['appHash']: installed_hashes.add(link['appHash'])
        seen = set()
        for run in runs:
            for a in run['artifacts']:
                p = Path(a['path']); reason = ''; eligible = False
                if a['path'] in seen: continue
                seen.add(a['path'])
                if a.get('removedAt'): reason = '회수 완료'
                elif not p.exists(): reason = '이미 교체되었거나 경로가 없습니다'
                elif run['status'] != 'verified':
                    reason = ('실행 중' if run in live else '중단됨 · 검증 미완료') if run['status'] == 'running' else '실패한 실행 · 보존'
                elif a['kind'] == 'evidence': reason = '사용자·검증 증거 보존'
                elif a.get('protection'): reason = a['protection']
                elif not a.get('seal'): reason = '검증 완료 기록 없음'
                elif a['seal']['evidence']: reason = '테스트·진단 증거 포함 · 보존'
                elif a['kind'] == 'runtime' and a['path'] in needed_caches: reason = '현재 빌드가 사용하는 공용 런타임 캐시'
                elif any(r['status'] != 'verified' and any(x['path'] == a['path'] for x in r['artifacts']) for r in runs): reason = '실패·중단·진행 중 실행에서도 참조 · 보존'
                elif a['id'] in retained: reason = '최종본 1개·복구본 1개 보관 정책'
                elif a.get('appHash') in installed_hashes: reason = '현재 연결된 설치본의 빌드 · 보존'
                elif any(p.is_relative_to(Path(r['output'])) or Path(r['output']).is_relative_to(p) for r in live): reason = '다른 빌드 실행이 사용 중'
                elif opened is None: reason = '현재 사용 여부를 확인하지 못했습니다'
                elif str(Path(run['output'])/'.pch-build.lock') in opened: reason = '빌드 잠금 사용 중 · 보존'
                elif a['kind'] == 'runtime' and str(CACHE/'.pch-runtime-cache.lock') in opened: reason = '공용 런타임 캐시를 다른 빌드가 사용 중'
                elif any(q == str(p) or q.startswith(str(p)+'/') for q in opened): reason = '열린 파일·실행 프로세스가 사용 중'
                else:
                    try:
                        if identity(p) != a['identity'] or seal(p) != a['seal']: reason = '검증 이후 내용·식별 변경 · 보존'
                        elif a['kind'] in ('app', 'recovery') and not app_hash(artifact_app(a)): reason = '앱 서명 재검증 실패'
                        elif a['kind'] == 'runtime' and not p.is_relative_to(CACHE) and (not (CACHE/p.name).is_file() or file_hash(p) != file_hash(CACHE/p.name)):
                            reason = '동일한 공용 런타임을 확인하지 못했습니다'
                        else: eligible = True; reason = '검증 완료 · 변경·현재 사용 미관측'
                    except (OSError, ValueError) as error: reason = str(error)
                if eligible and reclaim and (artifact_ids is None or a['id'] in artifact_ids):
                    # Recheck usage immediately before the fd-safe recursive removal.
                    current = usage_snapshot()
                    locks = {str(Path(run['output'])/'.pch-build.lock')}
                    if a['kind'] == 'runtime': locks.add(str(CACHE/'.pch-runtime-cache.lock'))
                    if current is None or any(q in locks or q == str(p) or q.startswith(str(p)+'/') for q in current):
                        eligible = False; reason = '실행 직전 사용 상태 변경 · 보존'
                    elif identity(p) != a['identity'] or seal(p) != a['seal']:
                        eligible = False; reason = '실행 직전 내용·경로 식별 변경 · 보존'
                    else:
                        if p.is_dir():
                            if not shutil.rmtree.avoids_symlink_attacks: raise ValueError('안전한 디렉토리 회수를 지원하지 않는 실행환경')
                            shutil.rmtree(p)
                        else: p.unlink()
                        a['removedAt'] = time.time(); self.save(run)
                        eligible = False; reason = '회수 완료'
                rows.append(dict(id=a['id'], runID=run['id'], kind=a['kind'], path=str(p),
                                 bytes=(a.get('seal') or {}).get('bytes'), eligible=eligible,
                                 reason=reason, startedAt=run['startedAt'], finishedAt=run['finishedAt'],
                                 status=run['status'], validation=run['validation'],
                                 installedPaths=[x['path'] for x in run['installedLinks']
                                                 if a.get('appHash') == x['appHash'] == current_links.get(x['path'])],
                                 previousInstalledPaths=[x['path'] for x in run['installedLinks']
                                                         if a.get('appHash') == x['appHash'] != current_links.get(x['path'])]))
        for repository in {r['repository'] for r in runs}:
            for directory in (Path(repository)/'build').glob('*'):
                for name in ('Modore.app', '.python-runtime-cache', '.build', 'swift', *[x.name for x in directory.glob('.pch-app-backup.*')]):
                    p = directory/name
                    if p.exists() and str(p) not in seen:
                        rows.append(dict(id=hashlib.sha256(str(p).encode()).hexdigest(), runID='', kind='untracked', path=str(p),
                                         bytes=None, eligible=False, reason='생성·검증 기록 없음 · 자동 회수 제외',
                                         startedAt=0, finishedAt=None, status='untracked', validation='', installedPaths=[], previousInstalledPaths=[]))
        return dict(observedAt=time.time(), items=rows, sharedCache=str(CACHE),
                    policy='저장소별 최종 앱 1개·복구본 1개. 검증이 끝난 생성물만 회수하며 실패·중단·사용 중·변경·증거는 보존합니다.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['begin','track','finish','report','reclaim','link','test','import-runtime','seed-runtime'])
    parser.add_argument('--state', type=Path, default=STATE)
    parser.add_argument('--repository', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--pid', type=int, default=os.getppid())
    parser.add_argument('--id'); parser.add_argument('--kind'); parser.add_argument('--path', type=Path)
    parser.add_argument('--success', action='store_true'); parser.add_argument('--validation', default='')
    parser.add_argument('--value-only', action='store_true')
    parser.add_argument('--retry-failed', action='store_true')
    parser.add_argument('--artifact-id', action='append')
    args = parser.parse_args(); store = Store(args.state)
    if args.action == 'test':
        safe_path(args.output).mkdir(parents=True, exist_ok=True, mode=0o700)
        with store.locked():
            run = store.begin(args.repository, args.output, os.getpid())
            artifact = store.allocate_scratch(run['id'], retry_failed=args.retry_failed)
        print('Build verification receipt: '+run['id'], flush=True)
        environment = os.environ.copy()
        for name in ('SDKROOT', 'SWIFT_EXEC', 'TOOLCHAINS', 'SWIFT_DRIVER_SWIFT_FRONTEND_EXEC'):
            environment.pop(name, None)
        sdk = subprocess.check_output(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'], env=environment, text=True).strip()
        environment['SDKROOT'] = sdk
        result = subprocess.run(['/usr/bin/xcrun','swift','test','--package-path',str(args.repository/'macos/Modore'),
                                 '--scratch-path',artifact['path'], '--sdk', sdk,
                                 '--cache-path', artifact['path']+'/shared-cache',
                                 '--config-path', artifact['path']+'/configuration',
                                 '--security-path', artifact['path']+'/security'], env=environment, check=False)
        with store.locked():
            store.finish(run['id'], result.returncode == 0, 'swift test exit '+str(result.returncode))
            store.report(reclaim=result.returncode == 0)
        return result.returncode
    with store.locked():
        if args.action == 'begin': result = store.begin(args.repository,args.output,args.pid)
        elif args.action == 'track': result = store.track(args.id,args.kind,args.path)
        elif args.action == 'finish': result = store.finish(args.id,args.success,args.validation)
        elif args.action == 'link': result = store.link(args.id,args.path)
        elif args.action == 'import-runtime': result = {'imported':store.import_runtime_duplicates(args.repository)}
        elif args.action == 'seed-runtime': result = {'seeded':store.seed_runtime(args.repository)}
        else: result = store.report(reclaim=args.action == 'reclaim', artifact_ids=args.artifact_id)
    print(result['id'] if args.value_only else json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    try: sys.exit(main())
    except (OSError, ValueError) as error:
        print(json.dumps({'error':str(error)}, ensure_ascii=False), file=sys.stderr); sys.exit(1)
