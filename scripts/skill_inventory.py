#!/usr/bin/env python3
"""Local skill inventory and reversible, explicit per-installation quarantine.
Never executes skill content or changes host settings. All mutations require a
fresh filesystem fingerprint. The retained original and resolved copy are separate.
"""
import argparse
import contextlib
import ctypes
import difflib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import re
import shutil
import stat
import subprocess
import sys
import threading
import time
import uuid

try:
    import tomllib
except ImportError:
    tomllib = None

MAX_BYTES = 64 * 1024 * 1024
MAX_METADATA_BYTES = 2 * 1024 * 1024
MAX_MANIFEST_BYTES = 8 * 1024 * 1024
CONFIGS = ('.codex/config.toml', '.claude/settings.json', '.claude/plugins/installed_plugins.json')
SCOPE = '이 설치 경로만 제외합니다. 같은 스킬의 다른 복사본과 이미 열린 세션에는 남을 수 있습니다. 새 세션에서 다시 확인하세요. 호스트·플러그인 업데이트나 재설치로 파일이 다시 생길 수 있습니다. 설정·규칙·훅은 변경하지 않습니다.'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_limited(path, limit, nofollow=False, expected=None):
    """Reject special files and enforce the limit on bytes read, not only stat size."""
    flags = os.O_RDONLY | os.O_NONBLOCK | (os.O_NOFOLLOW if nofollow else 0)
    fd = os.open(path, flags)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode): raise ValueError('일반 파일이 아닙니다: ' + str(path))
        if expected and (before.st_dev, before.st_ino) != (expected.st_dev, expected.st_ino):
            raise ValueError('읽는 중 파일이 바뀌었습니다: ' + str(path))
        if before.st_size > limit: raise ValueError('파일 읽기 크기 제한 초과: ' + str(path))
        with os.fdopen(fd, 'rb', closefd=False) as stream: data = stream.read(limit + 1)
        if len(data) > limit: raise ValueError('파일 읽기 크기 제한 초과: ' + str(path))
        after = os.fstat(fd)
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError('읽는 중 파일이 바뀌었습니다: ' + str(path))
        return data
    finally: os.close(fd)


def read_json(path, default=None, nofollow=False):
    try: data = read_limited(path, MAX_MANIFEST_BYTES, nofollow=nofollow)
    except FileNotFoundError: return default
    return json.loads(data.decode('utf-8'))


def atomic_json(path, value):
    encoded = json.dumps(value, ensure_ascii=False, indent=2).encode('utf-8')
    if len(encoded) > MAX_MANIFEST_BYTES: raise ValueError('백업 기록 크기 제한을 초과했습니다.')
    tmp = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    try:
        with tmp.open('xb') as f:
            f.write(encoded)
            f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if tmp.exists(): tmp.unlink()


def tree(path, follow=True):
    """Bounded digest of contents, modes and links, including linked target bytes."""
    entries, budget = [], [0, 0]
    def walk(p, name, ancestors):
        budget[1] += 1
        if budget[1] > 10000: raise ValueError('스킬 파일 수 제한 초과 (10,000개)')
        s = p.lstat()
        info = [name, stat.S_IMODE(s.st_mode)]
        if stat.S_ISLNK(s.st_mode):
            entries.append(info + ['link', os.readlink(p)])
            if follow: walk(p.resolve(strict=True), name + '/@target', ancestors)
        elif stat.S_ISDIR(s.st_mode):
            inode = (s.st_dev, s.st_ino)
            if inode in ancestors: raise ValueError('순환 링크가 있습니다: ' + str(p))
            entries.append(info + ['dir'])
            for c in sorted(p.iterdir()): walk(c, name + '/' + c.name, ancestors | {inode})
        elif stat.S_ISREG(s.st_mode):
            if s.st_size > MAX_BYTES - budget[0]: raise ValueError('안전한 스킬 백업 크기 제한 초과 (64MB)')
            data = read_limited(p, MAX_BYTES - budget[0], nofollow=True, expected=s)
            budget[0] += len(data)
            entries.append(info + ['file', digest(data)])
        else: raise ValueError('일반 파일·폴더·링크가 아닌 항목: ' + str(p))
    walk(path, '.', set())
    return digest(json.dumps(entries, ensure_ascii=False).encode()), entries


def copy_skill(source, target):
    """Copy a bounded snapshot without following any nested links, even after a race."""
    budget = [0, 0]
    def copy_directory(source_fd, output):
        before = os.fstat(source_fd)
        output.mkdir(mode=0o700)
        for name in sorted(os.listdir(source_fd)):
            budget[1] += 1
            if budget[1] > 10000: raise ValueError('스킬 파일 수 제한 초과 (10,000개)')
            info = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
            if stat.S_ISLNK(info.st_mode): raise ValueError('내부 심볼릭 링크가 있는 스킬은 안전한 복구를 지원하지 않습니다.')
            if not stat.S_ISDIR(info.st_mode) and not stat.S_ISREG(info.st_mode):
                raise ValueError('일반 파일·폴더가 아닌 스킬 항목입니다: ' + name)
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if stat.S_ISDIR(info.st_mode): flags |= os.O_DIRECTORY
            fd = os.open(name, flags, dir_fd=source_fd)
            try:
                opened = os.fstat(fd)
                if (opened.st_dev, opened.st_ino, opened.st_mode) != (info.st_dev, info.st_ino, info.st_mode):
                    raise ValueError('백업 중 파일이 바뀌었습니다: ' + name)
                if stat.S_ISDIR(info.st_mode): copy_directory(fd, output / name)
                else:
                    if info.st_size > MAX_BYTES - budget[0]: raise ValueError('안전한 스킬 백업 크기 제한 초과 (64MB)')
                    with os.fdopen(fd, 'rb', closefd=False) as stream: data = stream.read(MAX_BYTES - budget[0] + 1)
                    budget[0] += len(data)
                    if budget[0] > MAX_BYTES: raise ValueError('안전한 스킬 백업 크기 제한 초과 (64MB)')
                    after = os.fstat(fd)
                    if (info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                        raise ValueError('백업 중 파일이 바뀌었습니다: ' + name)
                    with (output / name).open('xb') as stream: stream.write(data)
                    os.chmod(output / name, stat.S_IMODE(info.st_mode))
                    os.utime(output / name, ns=(info.st_atime_ns, info.st_mtime_ns))
            finally: os.close(fd)
        after = os.fstat(source_fd)
        if (before.st_mtime_ns, before.st_ctime_ns) != (after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError('백업 중 폴더가 바뀌었습니다.')
        os.chmod(output, stat.S_IMODE(before.st_mode))
        os.utime(output, ns=(before.st_atime_ns, before.st_mtime_ns))
    # The installation itself may be a link. Its retained original remains a link.
    fd = os.open(source.resolve(strict=True), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try: copy_directory(fd, target)
    finally: os.close(fd)


def metadata(text, key, fallback=''):
    front = text.split('---', 2)
    if len(front) < 3 or front[0].strip(): return fallback
    m = re.search(r'^' + key + r':\s*[\"\']?([^\n]+)', front[1], re.M)
    return m[1].strip().strip('\"\'') if m else fallback


class Skills:
    def __init__(self, home=None):
        self.home = Path(home or Path.home()).absolute()
        self.bank = self.home / 'Library/Application Support/Modore/skill-backups'
        self.warnings = []
        self.invalid_configs = set()

    def children(self, path):
        try: return sorted(path.iterdir()) if path.exists() else []
        except (OSError, RuntimeError) as e:
            self.warnings.append(str(e)); return []

    def is_directory(self, path):
        try: return path.is_dir()
        except (OSError, RuntimeError) as e:
            self.warnings.append(str(path) + '\n' + str(e)); return False

    def config(self, rel):
        try:
            data = json.loads(read_limited(self.home / rel, MAX_METADATA_BYTES).decode('utf-8'))
            if not isinstance(data, dict): raise ValueError('설정의 최상위 값이 객체가 아닙니다.')
            return data
        except FileNotFoundError: return {}
        except (ValueError, OSError) as e:
            self.invalid_configs.add(rel)
            self.warnings.append(rel + '\n' + str(e)); return {}

    def mapping(self, value, label):
        if isinstance(value, dict): return value
        self.warnings.append(label + ': 객체 형식이 아니므로 상태를 확인하지 못했습니다.')
        return {}

    def inventory(self):
        self.warnings = []
        self.invalid_configs = set()
        rows = []
        def add(folder, host, source, origin, version='', discovery='탐색 경로에 존재 · 발견/활성 미확인'):
            md = folder / 'SKILL.md'
            text, error, fingerprint, link = '', '', '', ''
            real_path, exists = str(md), False
            try:
                try: kind = folder.lstat().st_mode
                except FileNotFoundError: return
                if not stat.S_ISDIR(kind) and not stat.S_ISLNK(kind): return
                if stat.S_ISLNK(kind): link = os.readlink(folder)
                try: md.lstat()
                except FileNotFoundError:
                    if not link: return
                real_path = str(md.resolve())
                exists = stat.S_ISREG(md.stat().st_mode)
                text = read_limited(md, MAX_METADATA_BYTES).decode('utf-8')
                fingerprint, _ = tree(folder)
            except (OSError, ValueError, RuntimeError) as e: error = str(e)
            rows.append(dict(id=digest(str(folder).encode()), name=metadata(text, 'name', folder.name),
                description=metadata(text, 'description'), host=host, source=source, origin=origin,
                path=str(folder), filePath=str(md), realPath=real_path,
                link=link,
                version=metadata(text, 'version', version or '명시 없음'), hash=digest(text.encode()) if text else '',
                fingerprint=fingerprint, manageable=host != '참고', discovery=discovery, session='미확인 · 현재 대화 로드 상태는 조회하지 않음',
                exists=exists, error=error, duplicates=0, variants=0))
        for rel, host, source in [('.codex/skills', 'Codex', '개인 설치'), ('.agents/skills', 'Codex', '공유 개인 설치'),
                                  ('.claude/skills', 'Claude', '개인 설치'), ('.codex/skills/.system', 'Codex', '시스템 기본')]:
            for p in self.children(self.home / rel):
                if not p.name.startswith('.'): add(p, host, source, rel)
        registry = '.claude/plugins/installed_plugins.json'
        claude_value = self.config(registry).get('plugins', {})
        claude_valid = registry not in self.invalid_configs and isinstance(claude_value, dict)
        claude = self.mapping(claude_value, 'Claude 설치 목록')
        enabled = self.mapping(self.config('.claude/settings.json').get('enabledPlugins', {}), 'Claude 활성 설정')
        try: codex = read_limited(self.home / '.codex/config.toml', MAX_METADATA_BYTES).decode('utf-8')
        except FileNotFoundError: codex = ''
        except (OSError, ValueError) as e: self.warnings.append(str(e)); codex = ''
        plugin_flags = {}
        if codex:
            try:
                if tomllib is None: raise ValueError('TOML 해석기를 사용할 수 없어 활성 설정은 미확인입니다.')
                plugins = self.mapping(tomllib.loads(codex).get('plugins', {}), 'Codex 플러그인 설정')
                for key, settings in plugins.items():
                    flag = self.mapping(settings, 'Codex 플러그인 ' + key).get('enabled')
                    if isinstance(flag, bool): plugin_flags[key] = flag
            except ValueError as e: self.warnings.append('.codex/config.toml\n' + str(e))
        for host, rel in [('Codex', '.codex/plugins/cache'), ('Claude', '.claude/plugins/cache')]:
            for market in self.children(self.home / rel):
                for plugin in self.children(market):
                    if not self.is_directory(plugin): continue
                    key = plugin.name + '@' + market.name
                    versions = [v for v in self.children(plugin) if self.is_directory(v) and not v.name.startswith('.')]
                    for v in versions:
                        discovery = '캐시 파일 · 선택 버전/활성 미확인'
                        if host == 'Codex':
                            flag = plugin_flags.get(key)
                            if flag is False: discovery = '설정에서 플러그인 비활성 · 캐시 보존'
                            elif flag is True: discovery = '플러그인 활성 설정 · 이 버전의 선택 여부 미확인'
                            else:
                                try:
                                    if (plugin / '.codex-remote-plugin-install.json').exists():
                                        discovery = '원격 설치 표식 · 이 버전의 선택/활성 미확인'
                                except (OSError, RuntimeError) as e: self.warnings.append(str(plugin) + '\n' + str(e))
                        else:
                            installed = claude.get(key, [])
                            if not claude_valid or not isinstance(installed, list) or any(not isinstance(x, dict) for x in installed):
                                self.warnings.append('Claude 플러그인 ' + key + ': 설치 기록 형식이 올바르지 않습니다.')
                                installed = []
                                discovery = '설치 기록 오류 · 선택 버전/활성 미확인'
                            registered = any(x.get('installPath') == str(v) for x in installed)
                            if registered:
                                discovery = ('등록된 버전 · 활성 설정 (실제 발견 미확인)' if enabled.get(key) is True else
                                             '등록된 버전 · 비활성 설정' if enabled.get(key) is False else '등록된 버전 · 활성 설정 미확인')
                            elif not discovery.startswith('설치 기록 오류'): discovery = '미선택 캐시 버전 · 설치 레지스트리에 없음'
                        # Standard plugin skill roots only; no recursive walk of arbitrary cache files.
                        for p in self.children(v / 'skills'):
                            add(p, host, '플러그인 제공', key, v.name, discovery)
        # The installed CLI symlink identifies its repository without executing it.
        cli = self.home / '.local/bin/modore'
        try:
            if cli.is_symlink():
                resolved_cli = cli.resolve(strict=True)
                reference = resolved_cli.parent.parent / 'skills/modore-ops'
                add(reference, '참고', 'CLI 작업본', str(cli) + ' → ' + str(resolved_cli),
                    discovery='CLI 연결 작업본의 참고 파일 · 호스트 설치 아님')
        except (OSError, RuntimeError) as e: self.warnings.append(str(cli) + '\n' + str(e))
        groups = {}
        for row in rows: groups.setdefault(row['name'], []).append(row)
        for group in groups.values():
            for row in group:
                row['duplicates'] = len(group)
                row['variants'] = len({r['hash'] for r in group if r['hash']})
        return sorted(rows, key=lambda x: (x['name'].lower(), x['path']))

    def backup_record(self, directory):
        if directory.is_symlink(): raise ValueError('백업 경로가 링크입니다.')
        rec = read_json(directory / 'manifest.json', nofollow=True)
        if not isinstance(rec, dict): raise ValueError('백업 메타데이터가 객체가 아닙니다.')
        required = ('id', 'name', 'original', 'realPath', 'link', 'host', 'origin', 'state', 'error', 'parentReal', 'fingerprint')
        if any(not isinstance(rec.get(key), str) for key in required):
            raise ValueError('백업 메타데이터가 불완전하거나 필드 형식이 잘못되었습니다.')
        if str(uuid.UUID(rec['id'])) != directory.name or rec['id'] != directory.name:
            raise ValueError('백업 식별자가 폴더와 다릅니다.')
        if rec['state'] not in ('preparing', 'backedUp', 'disabled', 'needsAttention', 'failed', 'restored'):
            raise ValueError('지원하지 않는 백업 상태입니다.')
        for key in ('created', 'restored', 'restoreStarted'):
            if key not in rec and key != 'created': continue
            value = rec.get(key)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                raise ValueError('백업 시각 형식이 잘못되었습니다.')
        for key in ('fingerprint', 'contentHash', 'originalHash'):
            if key in rec and (not isinstance(rec[key], str) or not re.fullmatch(r'[0-9a-f]{64}', rec[key])):
                raise ValueError('백업 무결성 정보가 잘못되었습니다.')
        self.validate_original(Path(rec['original']))
        return rec

    def restore_finished(self, rec, directory):
        """Recognize a successful move whose final manifest write was interrupted."""
        if not rec.get('restoreStarted') or os.path.lexists(directory / 'original'): return False
        p = Path(rec['original'])
        if not os.path.lexists(p) or p.parent.resolve() != p.parent or str(p.parent) != rec['parentReal']: return False
        return tree(p, follow=False)[0] == rec.get('originalHash')

    def status(self):
        rows = self.inventory()
        backups = []
        for d in self.children(self.bank):
            try:
                if not d.is_dir() or d.is_symlink(): continue
                rec = self.backup_record(d)
                rec['backupPath'] = str(d)
                if rec['state'] != 'restored' and self.restore_finished(rec, d):
                    rec['state'] = 'restored'
                    rec['error'] = '원래 경로에 복구된 파일을 확인했습니다. 마지막 기록 저장은 중단되었습니다.'
                elif rec['state'] in ('disabled', 'backedUp', 'needsAttention') and os.path.lexists(rec['original']):
                    rec['error'] = (rec['error'] + '\n' if rec['error'] else '') + '현재 원래 경로에 파일이 있습니다. 재설치·재생성 여부를 확인하세요. 복구는 덮어쓰지 않습니다.'
                backups.append(rec)
            except (OSError, ValueError, RuntimeError) as e: self.warnings.append(str(d) + '\n백업 기록 읽기 실패\n' + str(e))
        return dict(items=rows, backups=sorted(backups, key=lambda x: x['created'], reverse=True),
                    warnings=list(dict.fromkeys(self.warnings)), scope=SCOPE, observed=time.time())

    @contextlib.contextmanager
    def locked(self):
        # Refuse symlinked backup ancestors, including the bank itself.
        current = self.home
        for part in self.bank.relative_to(self.home).parts:
            current = current / part
            if current.is_symlink(): raise ValueError('백업 경로에 심볼릭 링크가 있습니다: ' + str(current))
            current.mkdir(mode=0o700, exist_ok=True)
            if current.stat().st_uid != os.getuid(): raise ValueError('백업 경로 소유자가 다릅니다.')
        os.chmod(self.bank, 0o700)
        fd = os.open(self.bank / '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX); yield
        finally: os.close(fd)

    def selected(self, request):
        row = next((x for x in self.inventory() if x['id'] == request.get('id')), None)
        if not row: raise ValueError('설치 항목이 사라졌습니다. 새로고침하세요.')
        if not row['manageable']: raise ValueError('참고 작업본은 비활성화 대상이 아닙니다.')
        if row['error'] or not row['fingerprint']: raise ValueError(row['error'] or '백업할 수 없는 항목')
        if request.get('fingerprint') != row['fingerprint']: raise ValueError('선택 후 파일이 바뀌었습니다. 새로고침하고 다시 선택하세요.')
        return row

    def disable(self, request):
        with self.locked():
            row = self.selected(request)
            p = Path(row['path'])
            self.validate_original(p)
            # Nested links may refer to mutable external state; preserve them in a
            # backup only after a future adapter can restore those dependencies.
            for base, dirs, files in os.walk(p.resolve(), followlinks=False):
                if any((Path(base) / name).is_symlink() for name in dirs + files):
                    raise ValueError('내부 심볼릭 링크가 있는 스킬은 아직 안전한 복구를 지원하지 않습니다. 원본을 변경하지 않았습니다.')
            if p.parent.resolve() != p.parent: raise ValueError('상위 탐색 폴더가 링크입니다. 이 경로는 변경하지 않습니다.')
            resolved = p.resolve(strict=True)
            if self.bank == resolved or resolved in self.bank.parents or self.bank in resolved.parents:
                raise ValueError('스킬과 백업 폴더가 겹칩니다.')
            ident = str(uuid.uuid4()); dest = self.bank / ident; dest.mkdir(mode=0o700)
            rec = dict(id=ident, name=row['name'], original=row['path'], realPath=row['realPath'], link=row['link'],
                       host=row['host'], origin=row['origin'], created=time.time(), state='preparing', error='',
                       fingerprint=row['fingerprint'], parentReal=str(p.parent.resolve()), scope=SCOPE)
            atomic_json(dest / 'manifest.json', rec)
            try:
                # Resolved payload is independently usable even if the external link target later disappears.
                copy_skill(p, dest / 'content')
                rec['contentHash'], _ = tree(dest / 'content')
                rec['originalHash'], _ = tree(p, follow=False)
                configs = dest / 'settings'; configs.mkdir(mode=0o700)
                rec['settings'] = []
                for index, rel in enumerate(CONFIGS):
                    source = self.home / rel
                    if source.is_file():
                        filename = str(index) + '-' + source.name
                        (configs / filename).write_bytes(read_limited(source, MAX_METADATA_BYTES))
                        rec['settings'].append(dict(original=str(source), backup=filename, realPath=str(source.resolve())))
                if tree(p)[0] != row['fingerprint']: raise ValueError('백업 중 원본이 바뀌었습니다. 비활성화하지 않았습니다.')
                # A second bounded snapshot detects source changes during the first copy.
                check = dest / 'verification'
                copy_skill(p, check)
                if tree(check)[0] != rec['contentHash']: raise ValueError('백업 내용 검증 실패')
                shutil.rmtree(check)
                rec['state'] = 'backedUp'; atomic_json(dest / 'manifest.json', rec)
                if tree(p)[0] != row['fingerprint']: raise ValueError('이동 전 원본이 바뀌었습니다.')
                rename_exclusive(p, dest / 'original')
                if tree(dest / 'original', follow=False)[0] != rec['originalHash']:
                    # A same-path replacement between verification and rename must
                    # be put back without clobbering any newly created installation.
                    rename_exclusive(dest / 'original', p)
                    raise ValueError('이동 중 원본이 바뀌어 원래 위치로 되돌렸습니다.')
                rec['state'] = 'disabled'
                atomic_json(dest / 'manifest.json', rec)
            except Exception as e:
                rec['state'] = 'needsAttention' if os.path.lexists(dest / 'original') else 'failed'
                rec['error'] = str(e)
                try: atomic_json(dest / 'manifest.json', rec)
                except (OSError, ValueError) as write_error:
                    raise ValueError('백업 ' + ident + '\n' + str(e) + '\n상태 기록 저장 실패\n' + str(write_error)) from e
                raise ValueError('백업 ' + ident + '\n' + str(e))
        return self.status()

    def validate_original(self, path):
        if not path.is_absolute() or '..' in path.parts or path != Path(os.path.normpath(path)):
            raise ValueError('복구 경로가 올바르지 않습니다.')
        for root in ('.codex/skills', '.codex/skills/.system', '.agents/skills', '.claude/skills'):
            if path.parent == self.home / root and not path.name.startswith('.'):
                return
        for root in ('.codex/plugins/cache', '.claude/plugins/cache'):
            try: parts = path.relative_to(self.home / root).parts
            except ValueError: continue
            if len(parts) == 5 and parts[3] == 'skills' and all(not p.startswith('.') for p in parts):
                return
        raise ValueError('복구 경로가 지원하는 스킬 탐색 경로 밖입니다.')

    def restore(self, request):
        with self.locked():
            ident = str(uuid.UUID(request['id'])); dest = self.bank / ident
            rec = self.backup_record(dest)
            try:
                if rec['state'] == 'restored': raise ValueError('이미 복구된 백업입니다.')
                p = Path(rec['original'])
                if self.restore_finished(rec, dest):
                    rec['state'] = 'restored'; rec['error'] = ''; rec['restored'] = time.time()
                    atomic_json(dest / 'manifest.json', rec)
                    return self.status()
                if rec['state'] not in ('disabled', 'backedUp', 'needsAttention'):
                    raise ValueError('비활성화가 완료되지 않은 백업은 복구할 수 없습니다. 원래 경로를 확인하세요.')
                if any(not rec.get(key) for key in ('originalHash', 'contentHash')):
                    raise ValueError('백업 무결성 정보가 불완전합니다.')
                if os.path.lexists(p): raise ValueError('복구 충돌: 원래 위치에 파일 또는 링크가 있습니다. 덮어쓰지 않았습니다.')
                if not p.parent.is_dir() or p.parent.resolve() != p.parent or str(p.parent.resolve()) != rec['parentReal']:
                    raise ValueError('원래 상위 폴더가 없거나 경로가 바뀌었습니다.')
                original = dest / 'original'
                if tree(original, follow=False)[0] != rec['originalHash']: raise ValueError('보관 원본의 무결성 검증 실패')
                if tree(dest / 'content')[0] != rec['contentHash']: raise ValueError('백업 내용의 무결성 검증 실패')
                # Relative symlinks only resolve correctly at the original location.
                if rec['link']:
                    target = Path(rec['link'])
                    if not target.is_absolute(): target = p.parent / target
                    if not target.exists(): raise ValueError('링크 대상이 없습니다. content 백업은 보존되어 있습니다.')
                    check = dest / ('restore-check-' + uuid.uuid4().hex)
                    try:
                        copy_skill(target, check)
                        if tree(check)[0] != rec['contentHash']: raise ValueError('링크 대상 내용이 변경되었습니다. 자동 복구를 중단합니다.')
                    finally:
                        if check.exists(): shutil.rmtree(check)
                rec['restoreStarted'] = time.time()
                atomic_json(dest / 'manifest.json', rec)
                rename_exclusive(original, p)
                if tree(p, follow=False)[0] != rec['originalHash']:
                    rename_exclusive(p, original)
                    raise ValueError('복구 중 보관 원본이 바뀌어 백업 위치로 되돌렸습니다.')
                rec['state'] = 'restored'; rec['error'] = ''; rec['restored'] = time.time()
            except Exception as e:
                rec['error'] = str(e); atomic_json(dest / 'manifest.json', rec)
                raise
            atomic_json(dest / 'manifest.json', rec)
        return self.status()

    def compare(self, request):
        ids = request.get('ids')
        if not isinstance(ids, list) or len(ids) != 2 or ids[0] == ids[1]:
            raise ValueError('비교할 서로 다른 설치 두 개를 선택하세요.')
        items = self.inventory()
        selected = [next((r for r in items if r['id'] == ident), None) for ident in ids]
        if len(selected) != 2 or any(x is None for x in selected): raise ValueError('비교할 설치 두 개를 선택하세요.')
        a, b = selected
        if any(r['error'] for r in selected): raise ValueError('읽기 오류가 있는 파일은 비교할 수 없습니다.')
        texts = []
        for row in selected:
            text = read_limited(Path(row['filePath']), MAX_METADATA_BYTES).decode('utf-8')
            if digest(text.encode()) != row['hash']: raise ValueError('비교 중 파일이 바뀌었습니다. 새로고침하세요.')
            texts.append(text.splitlines())
        return dict(diff='\n'.join(difflib.unified_diff(*texts, fromfile=a['filePath'], tofile=b['filePath'], lineterm='')) or 'SKILL.md 내용이 같습니다.',
                    same=a['hash'] == b['hash'])


def rename_exclusive(source, target):
    """Atomic no-replace move through directory handles that never follow links."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform != 'darwin':
        raise ValueError('스킬 이동·복구는 macOS에서 지원합니다.')
    def directory_fd(path):
        if not path.is_absolute() or '..' in path.parts: raise ValueError('이동 경로가 올바르지 않습니다.')
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        fd = os.open(path.anchor, flags)
        try:
            for part in path.parts[1:]:
                child = os.open(part, flags, dir_fd=fd)
                os.close(fd); fd = child
            return fd
        except Exception:
            os.close(fd); raise
    fn = libc.renameatx_np
    fn.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    fn.restype = ctypes.c_int
    source_fd = directory_fd(source.parent)
    try:
        target_fd = directory_fd(target.parent)
        try:
            if fn(source_fd, os.fsencode(source.name), target_fd, os.fsencode(target.name), 0x00000004):
                number = ctypes.get_errno()
                raise OSError(number, os.strerror(number), str(target))
        finally: os.close(target_fd)
    finally: os.close(source_fd)


def probe_codex(home):
    choices = [Path('/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'),
               Path('/Applications/Codex.app/Contents/Resources/codex')]
    executable = next((p for p in choices if p.is_file()), None)
    if executable is None: raise ValueError('설치된 Codex app-server 실행 파일을 찾지 못했습니다.')
    proc = subprocess.Popen([str(executable), 'app-server'], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, cwd=home)
    replies = queue.Queue()
    def read():
        for line in proc.stdout:
            try: replies.put(json.loads(line))
            except ValueError: pass
    reader = threading.Thread(target=read, daemon=True); reader.start()
    try:
        def send(message):
            proc.stdin.write(json.dumps(message) + '\n'); proc.stdin.flush()
        def receive(ident):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                try: reply = replies.get(timeout=max(.01, deadline - time.monotonic()))
                except queue.Empty: break
                if reply.get('id') == ident:
                    if 'error' in reply: raise ValueError(str(reply['error']))
                    return reply['result']
            raise ValueError('Codex 발견 조회 시간 초과')
        send(dict(id=1, method='initialize', params={'clientInfo': {'name': 'modore_skills', 'version': '1'}}))
        receive(1); send(dict(method='initialized'))
        send(dict(id=2, method='skills/list', params={'cwds': [str(home)], 'forceReload': True}))
        result = receive(2)
        skills = [s for group in result.get('data', []) for s in group.get('skills', [])]
        return skills
    finally:
        proc.terminate()
        try: proc.wait(timeout=3)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()
        proc.stdin.close(); proc.stdout.close(); reader.join(timeout=1)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(); parser.add_argument('--request-file', required=True)
    args = parser.parse_args(); req = read_json(Path(args.request_file))
    if not isinstance(req, dict): raise ValueError('작업 요청이 객체 형식이 아닙니다.')
    # Fixture mode creates its own isolated home, never accepts arbitrary mutation roots.
    manager = Skills()
    if req.get('demo'):
        root = Path.home() / 'Library/Application Support/Modore/skill-demo'
        current = Path.home()
        for part in root.relative_to(current).parts:
            current = current / part
            if current.is_symlink(): raise ValueError('검증 자료 경로에 링크가 있습니다.')
            current.mkdir(mode=0o700, exist_ok=True)
        manager = Skills(root)
        if req.get('action') == 'demo-create':
            for rel, suffix in [('.codex/skills/sample-skill', 'Codex'), ('.claude/skills/sample-skill', 'Claude')]:
                p = root / rel
                current = root
                for part in Path(rel).parts:
                    current = current / part
                    if current.is_symlink(): raise ValueError('검증 자료 안에 링크가 있습니다.')
                    current.mkdir(mode=0o700, exist_ok=True)
                if not (p / 'SKILL.md').exists():
                    if (p / 'SKILL.md').is_symlink(): raise ValueError('검증 파일이 링크입니다.')
                    (p / 'SKILL.md').write_text('---\nname: sample-skill\nversion: 1.0\ndescription: 격리된 검증 자료\n---\n' + suffix + ' 전용 안내\n')
            req['action'] = 'status'
    action = req.get('action', 'status')
    if action == 'status': result = manager.status()
    elif action == 'probe':
        result = manager.status()
        if req.get('demo'): raise ValueError('검증 자료는 호스트에 등록되지 않습니다.')
        found = probe_codex(manager.home)
        for row in result['items']:
            # Discovery is evidence for the queried host and installation path.
            # Another host or symlink alias sharing those bytes is not confirmed.
            if row['host'] != 'Codex': continue
            match = next((s for s in found if isinstance(s, dict) and s.get('path') == row['filePath']), None)
            if match:
                row['discovery'] = 'Codex 발견 확인 · ' + ('활성' if match.get('enabled') is True else '비활성' if match.get('enabled') is False else '활성 미확인')
        result['warnings'].append('별도 Codex app-server의 홈 범위에서 %d개 발견 응답을 확인했습니다. 데스크톱의 원격 플러그인·프로젝트 범위·현재 세션 로드 상태를 증명하지 않습니다.' % len(found))
    elif action == 'disable': result = manager.disable(req)
    elif action == 'restore': result = manager.restore(req)
    elif action == 'compare': result = manager.compare(req)
    else: raise ValueError('지원하지 않는 작업')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try: main()
    except Exception as exc:
        print(json.dumps({'error': str(exc)}, ensure_ascii=False)); sys.exit(1)
