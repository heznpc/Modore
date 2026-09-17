#!/usr/bin/env python3
"""Modore-owned asset retirement. No Taxi, quarantine, or implicit remote deletion.

Private per-transaction JSON stores approvals, original identities and receipts.
The UI approves exact previews. Warning overrides do not bypass identity checks.
"""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time
import uuid

GENERATED = {'node_modules', 'build', '.build', 'dist', 'cache', '.cache', '__pycache__', '.next', '.gradle'}


class Changed(Exception):
    pass


def run(args, cwd=None, data=None):
    p = subprocess.run(args, cwd=cwd, input=data, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=45)
    if p.returncode:
        raise RuntimeError(p.stderr.decode(errors='replace').strip()[:600] or 'command failed')
    return p.stdout


def git(path, *args, data=None):
    return run(['/usr/bin/git', '--no-optional-locks', '-c', 'core.fsmonitor=false', '-C', path, *args], data=data)


def identity(s):
    # Directory mtimes change as this transaction removes children.
    return [s.st_dev, s.st_ino, s.st_mode] if stat.S_ISDIR(s.st_mode) else [
        s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns]


@contextlib.contextmanager
def directory(path):
    """Open each absolute path component without following a symlink."""
    path = os.path.abspath(path)
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in Path(path).parts[1:]:
            nxt = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        yield fd
    finally:
        os.close(fd)


def inventory(path):
    entries = {}
    with directory(path) as root:
        root_id = identity(os.fstat(root))
        def walk(fd, prefix):
            for name in sorted(os.listdir(fd)):
                rel = prefix + name
                s = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if s.st_dev != root_id[0]:
                    raise Changed('대상 안에 다른 볼륨이 있습니다: ' + rel)
                entries[rel] = {'identity': identity(s), 'bytes': s.st_size if not stat.S_ISDIR(s.st_mode) else 0,
                                'directory': stat.S_ISDIR(s.st_mode)}
                if stat.S_ISDIR(s.st_mode):
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    try:
                        if identity(os.fstat(child)) != identity(s):
                            raise Changed('스캔 중 대상이 바뀌었습니다: ' + rel)
                        walk(child, rel + '/')
                    finally:
                        os.close(child)
        walk(root, '')
    return root_id, entries


def gh_executable():
    for p in ['/opt/homebrew/bin/gh', '/usr/local/bin/gh', '/usr/bin/gh']:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    raise RuntimeError('GitHub CLI(gh)를 찾지 못했습니다. 로컬 정리는 별도로 선택할 수 있습니다.')


def remote_state(slug):
    obj = json.loads(run([gh_executable(), 'api', '--hostname', 'github.com', 'repos/' + slug]))
    return {k: obj.get(k) for k in ('id', 'node_id', 'full_name', 'archived', 'updated_at', 'pushed_at', 'default_branch')}


def remote_slug(path):
    url = git(path, 'remote', 'get-url', 'origin').decode().strip()
    m = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([\w.-]+/[\w.-]+?)(?:\.git)?/?', url)
    if not m:
        raise RuntimeError('origin에서 github.com 레포를 식별하지 못했습니다.')
    return m[1]


def preview_item(options):
    path = os.path.realpath(os.path.expanduser(options['path']))
    top = git(path, 'rev-parse', '--show-toplevel').decode().strip()
    if os.path.realpath(top) != path or path in ('/', os.path.expanduser('~')):
        raise Changed('레포 루트의 실제 경로를 선택하세요: ' + top)
    root_id, entries = inventory(path)
    if '.git' not in entries:
        raise Changed('Git 루트 식별자가 없습니다.')
    names = [n for n in entries if n != '.git' and not n.startswith('.git/')]
    # --others excludes tracked files even if a later ignore rule matches them.
    ignored = set(os.fsdecode(n) for n in git(path, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z').split(b'\0') if n)
    # Empty ignored directories also need preservation.
    if names:
        p = subprocess.run(['/usr/bin/git', '-C', path, 'check-ignore', '-z', '--stdin'],
                           input=b'\0'.join(os.fsencode(n) for n in names) + b'\0',
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
        if p.returncode not in (0, 1):
            raise RuntimeError(p.stderr.decode(errors='replace'))
        ignored.update(os.fsdecode(n) for n in p.stdout.split(b'\0') if n and entries.get(os.fsdecode(n), {}).get('directory'))
    ignored_dirs = {n.rstrip('/') for n in ignored if n.endswith('/') or entries.get(n, {}).get('directory')}
    ignored.update(n for n in entries if any(str(p) in ignored_dirs for p in Path(n).parents))
    generated = {n for n in ignored if any(c in GENERATED for c in Path(n).parts)}
    keep = ignored - generated if options.get('deleteGenerated', False) else ignored
    keep = set(keep)
    for n in list(keep):
        keep.update(str(p) for p in Path(n).parents if str(p) != '.')
    for n, e in entries.items():
        e['keep'] = n in keep
        e['generated'] = n in generated
    warnings = []
    if git(path, 'status', '--porcelain', '--untracked-files=normal').strip():
        warnings.append('미커밋·미추적 파일이 있습니다. 삭제 시 로컬 변경이 사라집니다.')
    if git(path, 'stash', 'list').strip():
        warnings.append('stash가 있습니다. Git 메타데이터 삭제 시 함께 사라집니다.')
    try:
        unpushed = git(path, 'log', '--branches', '--not', '--remotes', '--oneline').strip()
    except RuntimeError:
        unpushed = b'unknown'
    if unpushed:
        warnings.append('원격 추적 참조에 없는 커밋이 있습니다. 원격 최신 상태는 fetch하지 않았습니다.')
    worktrees = git(path, 'worktree', 'list', '--porcelain').decode(errors='replace')
    if worktrees.count('worktree ') > 1:
        warnings.append('연결된 워크트리가 있습니다. 공용 .git 삭제 시 연결이 끊길 수 있습니다.\n' + worktrees)
    try:
        refs = run(['/usr/sbin/lsof', '-nP', '-a', '+d', path], data=None).decode(errors='replace')
        warnings.append('현재 루트 폴더를 참조하는 프로세스:\n' + refs[:2000])
    except Exception:
        pass
    warnings.append('세션·프로세스·외부 심볼릭 링크 참조는 전체 확인되지 않았습니다. 참조가 있어도 선택한 삭제를 실행합니다.')
    remote = None
    if options.get('archive', False):
        remote = remote_state(remote_slug(path))
    return dict(id=options.get('id', str(uuid.uuid4())), path=path, rootIdentity=root_id,
                archive=options.get('archive', False), local=options.get('local', True),
                deleteGenerated=options.get('deleteGenerated', False), remote=remote,
                entries=entries, warnings=warnings, approved=False, deleted=[], attempted=None,
                archiveMutation='pending', archiveVerification='pending',
                localMutation='pending', localVerification='pending', error='', changed=False,
                beforeFree=None, afterFree=None)


def save(path, plan):
    temp = path.with_suffix('.tmp')
    with open(temp, 'w') as f:
        os.chmod(temp, 0o600)
        json.dump(plan, f, ensure_ascii=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)


def validate_local(item):
    root_id, now = inventory(item['path'])
    if root_id != item['rootIdentity']:
        raise Changed('폴더의 실제 식별자가 바뀌었습니다. 다시 확인하세요.')
    # Recover a process interruption between unlink and receipt persistence.
    attempt = item.get('attempted')
    if attempt and attempt not in now:
        if attempt not in item['deleted']:
            item['deleted'].append(attempt)
        item['attempted'] = None
    deleted = set(item['deleted'])
    expected = {n: e for n, e in item['entries'].items() if n not in deleted}
    if set(now) != set(expected) or any(now[n]['identity'] != expected[n]['identity'] for n in now):
        raise Changed('승인 이후 파일·Git 상태가 바뀌었습니다. 변경된 항목을 다시 확인하세요.')
    return now


def unlink_entry(item, rel):
    with directory(item['path']) as root:
        if identity(os.fstat(root)) != item['rootIdentity']:
            raise Changed('루트 식별자가 바뀌었습니다.')
        fd = os.dup(root)
        try:
            parts = Path(rel).parts
            for i, part in enumerate(parts[:-1]):
                nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = nxt
                if identity(os.fstat(fd)) != item['entries']['/'.join(parts[:i + 1])]['identity']:
                    raise Changed('상위 폴더 식별자가 바뀌었습니다: ' + rel)
            s = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
            if identity(s) != item['entries'][rel]['identity']:
                raise Changed('대상 상태가 바뀌었습니다: ' + rel)
            if stat.S_ISDIR(s.st_mode):
                os.rmdir(parts[-1], dir_fd=fd)
            else:
                os.unlink(parts[-1], dir_fd=fd)
        finally:
            os.close(fd)


def journal(path, item, operation, name):
    with open(path.with_suffix('.journal'), 'a') as f:
        os.chmod(f.name, 0o600)
        f.write(json.dumps([item['id'], operation, name]) + '\n')
        f.flush()
        os.fsync(f.fileno())


def replay(path, plan):
    log = path.with_suffix('.journal')
    if not log.exists():
        return
    items = {item['id']: item for item in plan['items']}
    deleted_sets = {item['id']: set(item['deleted']) for item in plan['items']}
    for line in log.read_text().splitlines():
        try:
            iid, operation, name = json.loads(line)
        except ValueError:
            break  # torn last write did not precede an authorized unlink
        item = items.get(iid)
        if item is None or name not in item['entries']:
            continue
        if operation == 'attempt':
            item['attempted'] = name
        else:
            if name not in deleted_sets[iid]:
                item['deleted'].append(name)
                deleted_sets[iid].add(name)
            item['attempted'] = None


def execute(plan, path, cancel, selected=None):
    for item in plan['items']:
        if cancel.exists():
            break
        if not item['approved'] or (selected is not None and item['id'] not in selected):
            continue
        if (not item['archive'] or item['archiveVerification'] == 'verified') and (not item['local'] or item['localVerification'] == 'verified'):
            continue
        item['error'] = ''
        item['changed'] = False
        stage = 'validation'
        try:
            if item['local']:
                validate_local(item)
            if item['archive']:
                current = remote_state(item['remote']['full_name'])
                if current != item['remote']:
                    # A previous in-flight archive can succeed before a crash.
                    attempted = item['archiveMutation'] in ('attempting', 'succeeded')
                    same = all(current[k] == item['remote'][k] for k in ('id', 'node_id', 'full_name', 'pushed_at', 'default_branch'))
                    if not (attempted and same and current['archived']):
                        raise Changed('GitHub 레포 상태가 바뀌었습니다. 다시 확인하세요.')
                if current['archived']:
                    item['archiveMutation'] = 'succeeded'
                    item['archiveVerification'] = 'verified'
                    item['remote'] = current
                else:
                    stage = 'archiveMutation'
                    item['archiveMutation'] = 'attempting'
                    save(path, plan)
                    # GitHub's stable node ID binds the mutation even if a
                    # repository is renamed between revalidation and dispatch.
                    query = 'mutation($id: ID!) { archiveRepository(input: {repositoryId: $id}) { repository { id isArchived } } }'
                    result = json.loads(run([gh_executable(), 'api', '--hostname', 'github.com', 'graphql',
                                             '-f', 'query=' + query, '-f', 'id=' + current['node_id']]))
                    if result.get('errors'):
                        raise RuntimeError(str(result['errors'])[:600])
                    archived_result = result['data']['archiveRepository']['repository']
                    if archived_result['id'] != current['node_id'] or not archived_result['isArchived']:
                        raise Changed('아카이브 응답의 대상 식별자가 일치하지 않습니다.')
                    item['archiveMutation'] = 'succeeded'
                    save(path, plan)
                    stage = 'archiveVerification'
                    verified = remote_state(current['full_name'])
                    if verified['id'] != current['id'] or not verified['archived']:
                        raise Changed('아카이브 요청은 성공했지만 사후 대상 확인에 실패했습니다.')
                    item['archiveVerification'] = 'verified'
                    item['remote'] = verified
            save(path, plan)
            if item['local']:
                validate_local(item)
                stage = 'localMutation'
                if item['beforeFree'] is None:
                    item['beforeFree'] = shutil.disk_usage(item['path']).free
                deleted = set(item['deleted'])
                targets = [n for n, e in item['entries'].items() if not e['keep'] and n not in deleted]
                # .git last: failures preserve Git until normal working files finish.
                targets.sort(key=lambda n: (n == '.git' or n.startswith('.git/'), -len(Path(n).parts), n))
                item['localMutation'] = 'attempting'
                save(path, plan)
                for rel in targets:
                    if cancel.exists():
                        item['localMutation'] = 'partial'
                        break
                    item['attempted'] = rel
                    item['localMutation'] = 'attempting'
                    journal(path, item, 'attempt', rel)
                    unlink_entry(item, rel)
                    item['deleted'].append(rel)
                    journal(path, item, 'deleted', rel)
                    item['attempted'] = None
                else:
                    item['localMutation'] = 'succeeded'
                save(path, plan)
                stage = 'localVerification'
                validate_local(item)
                item['localVerification'] = 'verified' if item['localMutation'] == 'succeeded' else 'partial'
        except Changed as e:
            if stage == 'localVerification':
                item['localVerification'] = 'failed'
            item['changed'] = True
            item['approved'] = False
            item['error'] = str(e)
        except Exception as e:
            item['error'] = str(e)
            if stage in ('archiveVerification', 'localVerification'):
                item[stage] = 'failed'
            elif stage == 'localMutation':
                item[stage] = 'partial' if item['deleted'] else 'failed'
            # A failed archive HTTP response can still have mutated GitHub.
            # Keep 'attempting' until a fresh read resolves that uncertainty.
        finally:
            if item['local']:
                try:
                    item['afterFree'] = shutil.disk_usage(item['path']).free
                except OSError:
                    item['afterFree'] = None
            plan['updatedAt'] = time.time()
            save(path, plan)
    return plan


def summary(plan):
    result = {k: v for k, v in plan.items() if k != 'items'}
    result['items'] = []
    for item in plan['items']:
        row = {k: v for k, v in item.items() if k not in ('entries', 'rootIdentity', 'deleted', 'attempted')}
        row['deleteBytes'] = sum(e['bytes'] for e in item['entries'].values() if not e['keep']) if item['local'] else 0
        row['keepBytes'] = sum(e['bytes'] for e in item['entries'].values() if e['keep'])
        row['generatedBytes'] = sum(e['bytes'] for e in item['entries'].values() if e['generated'])
        row['deletedCount'] = len(item['deleted'])
        row['files'] = [{'path': n, 'keep': e['keep'], 'generated': e['generated'], 'bytes': e['bytes']} for n, e in sorted(item['entries'].items(), key=lambda pair: (pair[0].startswith('.git/'), not pair[1]['keep'], pair[0])) if not e['directory']][:200]
        result['items'].append(row)
    return result


def dispatch(request):
    store = Path(os.path.expanduser('~/Library/Application Support/Modore/asset-retirement'))
    store.mkdir(parents=True, exist_ok=True, mode=0o700)
    action = request['action']
    tid = request.get('transaction', str(uuid.uuid4()))
    if not re.fullmatch(r'[a-f0-9-]{36}', tid):
        raise ValueError('잘못된 transaction ID')
    path = store / (tid + '.json')
    if action == 'status':
        plan = json.loads(path.read_text())
        replay(path, plan)
        return summary(plan)
    if action == 'latest':
        files = sorted(store.glob('*.json'), key=lambda p: p.stat().st_mtime)
        if not files:
            return {'id': tid, 'items': [], 'receipt': ''}
        plan = json.loads(files[-1].read_text())
        replay(files[-1], plan)
        return summary(plan)
    with open(store / (tid + '.lock'), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if action == 'preview':
            plan = {'id': tid, 'items': [], 'receipt': str(path), 'updatedAt': time.time()}
            for options in request['items']:
                try:
                    item = preview_item(options)
                except Exception as e:
                    # One unreadable/unresolvable asset must not discard the
                    # other independently reviewable items in this batch.
                    item = dict(id=str(uuid.uuid4()), path=os.path.realpath(os.path.expanduser(options['path'])),
                                rootIdentity=None, archive=options.get('archive', False), local=options.get('local', True),
                                deleteGenerated=options.get('deleteGenerated', False), remote=None, entries={}, warnings=[],
                                approved=False, deleted=[], attempted=None, archiveMutation='pending',
                                archiveVerification='pending', localMutation='pending', localVerification='pending',
                                error=str(e), changed=True, beforeFree=None, afterFree=None)
                if any(os.path.commonpath([item['path'], other['path']]) in (item['path'], other['path']) for other in plan['items']):
                    raise Changed('중첩된 레포는 별도 트랜잭션으로 실행하세요.')
                plan['items'].append(item)
        else:
            plan = json.loads(path.read_text())
            replay(path, plan)
            if action == 'approve':
                for item in plan['items']:
                    if item['id'] in request['ids']:
                        if item['changed']:
                            raise Changed('변경된 대상은 미리보기를 갱신한 뒤 승인하세요.')
                        item['approved'] = True
            elif action == 'refresh':
                save(path, plan)
                path.with_suffix('.journal').unlink(missing_ok=True)
                # Rebuild only the changed item's remaining files. No Git needed
                # after a partial .git deletion; preserve the approved keep map.
                for item in plan['items']:
                    if item['id'] not in request['ids']:
                        continue
                    if item['rootIdentity'] is None:
                        item.update(preview_item(item))
                        continue
                    root_id, now = inventory(item['path'])
                    if root_id != item['rootIdentity']:
                        raise Changed('대상이 교체됐습니다. 폴더를 새로 추가하세요.')
                    if not item['deleted'] and '.git' in now:
                        replacement = preview_item(item)
                        item.update(replacement)
                    else:
                        for n, e in now.items():
                            previous = item['entries'].get(n)
                            e['keep'] = previous['keep'] if previous else True
                            e['generated'] = previous['generated'] if previous else False
                        item['entries'] = now
                        item['deleted'] = []
                        item['attempted'] = None
                        item['approved'] = False
                        item['changed'] = False
                        item['error'] = ''
                        if item['archive']:
                            item['remote'] = remote_state(item['remote']['full_name'])
            elif action == 'execute':
                cancel = store / (tid + '.cancel')
                return summary(execute(plan, path, cancel, request.get('ids')))
            else:
                raise ValueError('알 수 없는 action')
        save(path, plan)
        return summary(plan)


if __name__ == '__main__':
    try:
        request = json.load(open(sys.argv[1]))
        print(json.dumps(dispatch(request), ensure_ascii=True))
    except Exception as e:
        print(json.dumps({'error': str(e)}, ensure_ascii=True))
        sys.exit(1)
