#!/usr/bin/env python3
"""Read-only disk attribution: measured deltas and surviving file metadata, never transcript bodies."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import stat
import signal
import tempfile
import time

STATE = Path.home() / 'Library/Application Support/Modore'

def stamp(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()

def iso(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat()

def roots(home):
    return [(label, str(path)) for label, path in [
        ('Codex 대화·실행 데이터', home/'.codex'),
        ('Claude 데이터', home/'.claude'),
        ('문서·AI 작업 결과', home/'Documents'),
        ('개발 프로젝트', home/'IdeaProjects'),
        ('시뮬레이터 기기', home/'Library/Developer/CoreSimulator/Devices'),
        ('시뮬레이터 런타임', Path('/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime')),
        ('시뮬레이터 공유 캐시', Path('/Library/Developer/CoreSimulator/Caches/dyld')),
        ('Xcode 데이터', home/'Library/Developer/Xcode'),
        ('npm 캐시', home/'.npm'), ('개발 실행환경', home/'.local'),
        ('추가 캐시', home/'.cache'), ('사용자 캐시', home/'Library/Caches'),
        ('앱 지원 데이터', home/'Library/Application Support'),
        ('메시지 데이터', home/'Library/Messages'), ('다운로드', home/'Downloads'),
        ('설치 앱', Path('/Applications')), ('Homebrew', Path('/opt/homebrew')),
        ('임시 빌드', Path('/private/tmp')), ('시스템 임시 데이터', Path('/private/var/folders')),
        ('스왑 볼륨', Path('/System/Volumes/VM')), ('절전 이미지', Path('/private/var/vm'))]]

def baseline(state, since=None, now=None):
    now = time.time() if now is None else now
    samples = []
    path = state/'storage-samples.tsv'
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                parts = line.split('\t'); at = stamp(parts[0]); size = int(parts[1])*1024
                if now-30*86400 <= at <= now and size >= 0: samples.append((at, size))
            except (ValueError, IndexError): continue
    if since is None:
        # Start from the most recent high-water mark in the retained month.
        return max(samples, key=lambda row: (row[1], row[0])) if samples else (now-7*86400, None)
    eligible = [s for s in samples if abs(s[0]-since) <= 300]
    return (since, min(eligible, key=lambda s: abs(s[0]-since))[1] if eligible else None)

def scan(label, path, since, now, seen=None):
    seen = set() if seen is None else seen
    total = created = modified = files = errors = 0
    buckets = {}
    stack = [Path(path)]
    try: device = os.lstat(path).st_dev
    except FileNotFoundError:
        return dict(label=label, path=path, allocatedBytes=0, createdBytes=0, modifiedBytes=0,
                    files=0, errors=0, complete=True, status='missing', candidates=[])
    except OSError:
        return dict(label=label, path=path, allocatedBytes=0, createdBytes=0, modifiedBytes=0,
                    files=0, errors=1, complete=False, status='inaccessible', candidates=[])
    while stack:
        current = stack.pop()
        try:
            s = current.lstat()
            if s.st_dev != device or stat.S_ISLNK(s.st_mode): continue
            if stat.S_ISREG(s.st_mode) and s.st_nlink > 1:
                identity = (s.st_dev, s.st_ino)
                if identity in seen: continue
                seen.add(identity)
            if stat.S_ISDIR(s.st_mode):
                total += s.st_blocks*512
                with os.scandir(current) as entries:
                    stack.extend(Path(e.path) for e in entries)
                continue
            if not stat.S_ISREG(s.st_mode): continue
            size = s.st_blocks*512; total += size; files += 1
            birth = getattr(s, 'st_birthtime', None)
            is_new = birth is not None and since <= birth <= now
            changed = since <= s.st_mtime <= now
            if is_new: created += size
            elif changed: modified += size
            if is_new or changed:
                relative = current.relative_to(path).parts
                # Aggregate by directory, not conversation/file contents.
                key = str(Path(path).joinpath(*relative[:min(2, max(1, len(relative)-1))]))
                b = buckets.setdefault(key, {'path': key, 'createdBytes': 0, 'modifiedBytes': 0})
                b['createdBytes' if is_new else 'modifiedBytes'] += size
        except OSError: errors += 1
    return dict(label=label, path=path, allocatedBytes=total, createdBytes=created,
                modifiedBytes=modified, files=files, errors=errors, complete=errors==0,
                status='measured' if errors==0 else 'partial',
                candidates=sorted(buckets.values(), key=lambda x:x['createdBytes']+x['modifiedBytes'], reverse=True))

def scan_isolated(label, path, since, now, seen, timeout=30):
    """A stalled filesystem open must not discard evidence from other roots."""
    with tempfile.TemporaryFile() as output:
        pid = os.fork()
        if pid == 0:
            try:
                before = set(seen)
                row = scan(label, path, since, now, seen)
                output.write(json.dumps([row, list(seen-before)]).encode())
                output.flush()
                os._exit(0)
            except BaseException:
                os._exit(1)
        deadline = time.monotonic() + timeout
        status = None
        try:
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    if status == 0:
                        output.seek(0)
                        row, identities = json.load(output)
                        seen.update(tuple(item) for item in identities)
                        return row
                    break
                time.sleep(0.05)
            else:
                status = None
        finally:
            if status is None:
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass
                os.waitpid(pid, 0)
        return dict(label=label, path=path, allocatedBytes=0, createdBytes=0,
                    modifiedBytes=0, files=0, errors=1, complete=False,
                    status='timeout' if status is None else 'failed', candidates=[])

def past_measurements(state, since, max_age=300):
    found = {}
    # Only a contemporaneous successful baseline supports a measured growth claim.
    for file in sorted(state.glob('storage-evidence-*.tsv')):
        with file.open() as source:
            for line in source:
                a = line.rstrip('\n').split('\t')
                try:
                    if a[0] != 'path' or a[3] != 'ok': continue
                    at = stamp(a[1]); size = int(a[2])*1024
                    if since-max_age <= at <= since and size >= 0:
                        key = os.path.realpath(a[5])
                        if key not in found or at > found[key][0]: found[key] = (at,size)
                except (ValueError, IndexError): continue
    for file in sorted((state/'storage-explanations').glob('*.json')):
        try:
            report = json.loads(file.read_text())
            at = stamp(report['capturedAt'])
            if not since-max_age <= at <= since: continue
            for row in report['rows']:
                key = os.path.realpath(row['path'])
                if row['complete'] and (key not in found or at > found[key][0]):
                    found[key] = (at, row['allocatedBytes'])
        except (OSError, ValueError, KeyError, TypeError): continue
    return found

def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.resolve() != path.parent.absolute() or path.parent.stat().st_uid != os.getuid():
        raise ValueError('Unsafe storage evidence directory')
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(data, out, ensure_ascii=False); out.flush(); os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def explain(home=Path.home(), state=STATE, since=None, targets=None):
    now = time.time(); start, free_before = baseline(state,since,now)
    previous = past_measurements(state,start)
    recent = past_measurements(state,now,30*86400)
    rows=[]; seen=set()
    selected = targets if targets is not None else roots(home)
    for label,path in selected:
        row=scan_isolated(label,path,start,now,seen)
        old=previous.get(os.path.realpath(path))
        latest=recent.get(os.path.realpath(path))
        row['previousMeasuredAt']=iso(latest[0]) if latest else None
        row['recentDeltaBytes']=row['allocatedBytes']-latest[1] if latest and row['complete'] else None
        row['measuredAt']=iso(time.time())
        row['baselineBytes']=old[1] if old else None
        row['measuredDeltaBytes']=row['allocatedBytes']-old[1] if old and row['complete'] else None
        rows.append(row)
        atomic(state/'storage-explanation-progress.json', dict(startedAt=iso(now),
               completed=len(rows), total=len(selected), label=label))
    fs=os.statvfs(home); free_now=fs.f_bavail*fs.f_frsize
    drop=max(0,free_before-free_now) if free_before is not None else None
    return dict(version=1, capturedAt=iso(time.time()), scanStartedAt=iso(now), since=iso(start),
        baselineFreeBytes=free_before, freeBytes=free_now, freeDropBytes=drop,
        rows=sorted(rows,key=lambda r:r['createdBytes'],reverse=True),
        coverage='선택한 경로의 파일 메타데이터 측정. 심볼릭 링크·다른 볼륨은 제외. 접근 실패는 항목별 표시.',
        interpretation='생성 후 남은 파일의 현재 할당량은 증가 원인 후보입니다. 수정된 기존 파일의 크기는 증가량이 아닙니다. APFS 공유 블록·삭제·동시 쓰기 때문에 합계를 여유 공간 감소량이나 회수 가능량으로 간주하지 않습니다.')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--since',help='ISO timestamp; default: largest free-space sample within 30 days')
    args=parser.parse_args()
    report=explain(since=stamp(args.since) if args.since else None)
    # Preserve complete reports, not just a fixed number of recent observations.
    atomic(STATE/'storage-explanations'/f'{time.time_ns()}.json',report)
    atomic(STATE/'storage-explanation.json',report)
    print(json.dumps(report,ensure_ascii=False))

if __name__=='__main__': main()
