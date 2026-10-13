#!/usr/bin/env python3
"""Read-only evidence for Expo caches duplicated in a retained local archive.

This does not establish that a path is unused or authorize deletion. Callers
must retain the archive, check live consumers, and compare a fresh fingerprint
before acting through their existing approval/receipt flow. No extraction,
network request, or filesystem mutation is performed here.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import sys
import tarfile
import time
import unicodedata


MAX_ENTRIES = 20_000
MAX_ARCHIVE_BYTES = 2_000_000_000
MAX_EXPANDED_BYTES = 8_000_000_000
MAX_SECONDS = 60
CHUNK_BYTES = 1024 * 1024
ALLOWED_ATTRIBUTES = {'com.apple.provenance', 'com.apple.quarantine'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identity(value):
    return [value.st_dev, value.st_ino, value.st_mode, value.st_uid,
            value.st_gid, value.st_nlink, value.st_size, value.st_mtime_ns,
            value.st_ctime_ns, getattr(value, 'st_flags', 0)]


def physical(path):
    p = Path(path).absolute()
    require(p == p.resolve(strict=True), '심볼릭 링크·비정규 경로는 보존합니다.')
    require(not any(ord(c) < 32 for c in str(p)), '제어 문자가 있는 경로는 보존합니다.')
    return p


def owned(value, directory=False):
    require(value.st_uid == os.getuid() and not value.st_mode & 0o022,
            '소유권·쓰기 권한을 확인하지 못해 보존합니다.')
    require(stat.S_ISDIR(value.st_mode) if directory else stat.S_ISREG(value.st_mode),
            '링크·특수 파일은 보존합니다.')
    if not directory:
        require(value.st_nlink == 1, '하드 링크 파일은 보존합니다.')


@contextmanager
def open_stable(path, expected):
    # O_NOFOLLOW and the descriptor identity prevent a substituted final link
    # or file from being read between enumeration and opening.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        owned(os.fstat(stream.fileno()))
        require(identity(os.fstat(stream.fileno())) == expected,
                '검증 직전 파일이 변경되어 보존합니다.')
        yield stream
        require(identity(os.fstat(stream.fileno())) == expected,
                '검증 중 파일이 변경되어 보존합니다.')


def tree_snapshot(root, check_time):
    root_stat = root.lstat()
    owned(root_stat, directory=True)
    result = {'.': identity(root_stat)}

    def fail(error):
        raise error

    for directory, dirs, files in os.walk(root, followlinks=False, onerror=fail):
        check_time()
        for name in dirs + files:
            require(not any(ord(c) < 32 for c in name), '제어 문자가 있는 파일명은 보존합니다.')
            path = Path(directory) / name
            value = path.lstat()
            owned(value, directory=stat.S_ISDIR(value.st_mode))
            require(value.st_dev == root_stat.st_dev, '다른 볼륨의 자료가 섞여 있습니다.')
            result[path.relative_to(root).as_posix()] = identity(value)
            require(len(result) <= MAX_ENTRIES, '파일 수가 검증 상한을 넘어 보존합니다.')
    return result


def attributes(root, paths):
    """Resource forks and unknown attributes are unique data, not cache proof."""
    result = []
    if sys.platform == 'darwin':
        command = subprocess.run(['/usr/bin/xattr', '-r', str(root)],
                                 capture_output=True, text=True, timeout=10)
        require(command.returncode == 0 and not command.stderr,
                '확장 속성을 확인하지 못해 보존합니다.')
        require(len(command.stdout) < 2_000_000, '확장 속성 검증 상한을 넘었습니다.')
        for line in command.stdout.splitlines():
            path, separator, name = line.rpartition(': ')
            require(separator and name in ALLOWED_ATTRIBUTES,
                    '원본에 없는 확장 속성·리소스 포크가 있어 보존합니다.')
            relative = Path(path).relative_to(root).as_posix()
            require(relative in paths, '확장 속성 검사 중 대상이 변경되었습니다.')
            result.append([relative, name])
    else:
        require(hasattr(os, 'listxattr'), '확장 속성 검증을 지원하지 않는 환경입니다.')
        for relative in paths:
            path = root if relative == '.' else root / relative
            for name in os.listxattr(path, follow_symlinks=False):
                require(name in ALLOWED_ATTRIBUTES,
                        '원본에 없는 확장 속성·리소스 포크가 있어 보존합니다.')
                result.append([relative, name])
    return sorted(result)


def member_path(member):
    name = member.name
    require(not any(ord(c) < 32 for c in name) and '\\' not in name,
            '안전하지 않은 아카이브 경로입니다.')
    if name in ('.', './'):
        require(member.isdir(), '아카이브 루트 형식이 올바르지 않습니다.')
        return '.'
    if name.startswith('./'):
        name = name[2:]
    if member.isdir() and name.endswith('/'):
        name = name[:-1]
    require(name and not name.startswith('/') and
            all(part not in ('', '.', '..') for part in name.split('/')),
            '아카이브 경로 이탈·중복 구분자는 보존합니다.')
    require(member.isfile() or member.isdir(), '아카이브 링크·특수 멤버는 보존합니다.')
    require(not member.issparse(), '희소 아카이브 멤버는 지원하지 않습니다.')
    return name


def inspect(path, archive, home=None):
    """Prove exact bytes against one retained Expo tar; never approve cleanup.

    Incomplete caches must be the archive's ordered initial file sequence.
    Only its final observed file may be partial, only when it is the Expo
    executable, and every byte must equal a nonempty archive prefix. All tar
    members, including missing local members, are validated and fully read.
    """
    started = time.monotonic()

    def check_time():
        require(time.monotonic() - started <= MAX_SECONDS,
                '검증 시간 한도를 넘어 보존합니다.')

    home = physical(home or Path.home())
    target = physical(path)
    source = physical(archive)
    require(target.parent == home / '.expo/ios-simulator-app-cache' and
            re.fullmatch(r'Expo-Go-[0-9]+\.[0-9]+\.[0-9]+\.tar\.app', target.name),
            '지원하는 Expo 추출 캐시 경계 밖입니다.')
    require(source.parent == home / '.expo/expo-go' and
            re.fullmatch(r'[0-9a-f]{64}-body\.bin', source.name),
            '별도로 보존할 Expo 다운로드 원본 경계 밖입니다.')
    require(not source.is_relative_to(target), '보존할 원본이 정리 대상 안에 있습니다.')
    for parent in (target.parent, source.parent):
        owned(parent.lstat(), directory=True)
    source_stat = source.lstat()
    owned(source_stat)
    require(0 < source_stat.st_size <= MAX_ARCHIVE_BYTES, '원본 크기가 검증 범위를 벗어났습니다.')
    source_identity = identity(source_stat)
    before = tree_snapshot(target, check_time)
    attrs = attributes(target, before)
    local_files = {name: value for name, value in before.items() if stat.S_ISREG(value[2])}
    require(local_files, '대조할 로컬 파일이 없어 보존합니다.')

    archive_files = []
    archive_dirs = {'.'}
    directory_positions = {}
    names = set()
    folded_names = set()
    proofs = []
    member_hashes = []
    partials = []
    info = None
    total_bytes = 0
    member_count = 0
    with open_stable(source, source_identity) as raw:
        with tarfile.open(fileobj=raw, mode='r|*') as bundle:
            for position, member in enumerate(bundle):
                check_time()
                member_count += 1
                require(member_count <= MAX_ENTRIES, '아카이브 멤버 수가 상한을 넘었습니다.')
                name = member_path(member)
                folded = unicodedata.normalize('NFD', name).casefold()
                require(name not in names and folded not in folded_names,
                        '아카이브에 중복·충돌 경로가 있습니다.')
                names.add(name)
                folded_names.add(folded)
                if member.isdir():
                    archive_dirs.add(name)
                    directory_positions[name] = position
                    continue
                require(0 <= member.size <= MAX_EXPANDED_BYTES, '아카이브 파일 크기 상한 초과입니다.')
                total_bytes += member.size
                require(total_bytes <= MAX_EXPANDED_BYTES, '아카이브 전체 크기 상한 초과입니다.')
                archive_files.append((name, position))
                for parent in PurePosixPath(name).parents:
                    archive_dirs.add(parent.as_posix())
                    directory_positions.setdefault(parent.as_posix(), position)
                local = local_files.get(name)
                if local is not None:
                    require(local[6] <= member.size, '로컬 파일이 원본보다 커서 보존합니다.')
                    if local[6] < member.size:
                        require(local[6] > 0, '비어 있는 부분 파일은 증거가 부족합니다.')
                        partials.append(name)
                require(len(partials) <= 1, '둘 이상의 부분 파일은 지원하지 않습니다.')
                digest = hashlib.sha256()
                local_digest = hashlib.sha256()
                metadata = bytearray() if name == 'Info.plist' else None
                if metadata is not None:
                    require(member.size <= 1_000_000, '앱 명세 크기가 상한을 넘었습니다.')
                with bundle.extractfile(member) as body:
                    def compare(local_stream=None):
                        consumed = 0
                        while consumed < member.size:
                            check_time()
                            block = body.read(min(CHUNK_BYTES, member.size - consumed))
                            require(block, '아카이브 본문이 잘려 있어 보존합니다.')
                            digest.update(block)
                            if metadata is not None:
                                metadata.extend(block)
                            if local_stream is not None and consumed < local[6]:
                                size = min(len(block), local[6] - consumed)
                                actual = local_stream.read(size)
                                require(actual == block[:size], '원본과 다른 로컬 파일이 있어 보존합니다.')
                                local_digest.update(actual)
                            consumed += len(block)
                        if local_stream is not None:
                            require(local_stream.read(1) == b'', '검증 중 로컬 파일이 변경되었습니다.')
                    if local is None:
                        compare()
                    else:
                        with open_stable(target / name, local) as local_stream:
                            compare(local_stream)
                        proofs.append(dict(path=name, localBytes=local[6], archiveBytes=member.size,
                                           sha256=local_digest.hexdigest(), complete=local[6] == member.size))
                member_hashes.append([name, member.size, digest.hexdigest()])
                if metadata is not None:
                    info = plistlib.loads(metadata)
        raw.seek(0)
        archive_hash = hashlib.sha256()
        while True:
            check_time()
            block = raw.read(CHUNK_BYTES)
            if not block:
                break
            archive_hash.update(block)

    require(isinstance(info, dict) and info.get('CFBundleIdentifier') == 'host.exp.Exponent'
            and info.get('CFBundleExecutable') == 'Expo Go', '보존 원본의 Expo 앱 식별을 확인하지 못했습니다.')
    require(info.get('CFBundleVersion') and info.get('CFBundleShortVersionString'), '앱 버전 명세가 없습니다.')
    ordered_files = [name for name, _ in archive_files]
    require('Expo Go' in ordered_files, '원본에 Expo 실행 파일이 없습니다.')
    require(not set(ordered_files) & archive_dirs, '아카이브 파일·디렉터리 경로가 충돌합니다.')
    require(set(local_files) == set(ordered_files[:len(local_files)]),
            '미등록 파일 또는 순서가 맞지 않는 추출 부분집합은 보존합니다.')
    if partials:
        require(partials == [ordered_files[len(local_files) - 1]] and partials == ['Expo Go']
                and 'Info.plist' not in local_files and len(proofs) > 1,
                '부분 파일은 마지막 Expo 실행 파일의 정확한 앞부분만 지원합니다.')
    # A partially written executable cannot be followed by any later material.
    if partials:
        boundary = archive_files[len(local_files) - 1][1]
    elif len(local_files) < len(archive_files):
        boundary = archive_files[len(local_files)][1] - 1
    else:
        boundary = member_count
    for name, value in before.items():
        if stat.S_ISDIR(value[2]):
            require(name in archive_dirs and directory_positions.get(name, -1) <= boundary,
                    '원본 추출 순서 밖의 디렉터리는 보존합니다.')
    require(before == tree_snapshot(target, check_time) and attrs == attributes(target, before),
            '검증 중 대상 또는 확장 속성이 변경되었습니다.')
    require(identity(source.lstat()) == source_identity and physical(source) == source,
            '보존 원본이 검증 중 변경되었습니다.')
    complete = not partials and set(before) == set(ordered_files) | archive_dirs
    fingerprint_data = [str(target), str(source), source_identity, archive_hash.hexdigest(),
                        sorted(before.items()), attrs, proofs, member_hashes]
    fingerprint = hashlib.sha256(json.dumps(fingerprint_data, sort_keys=True).encode()).hexdigest()
    return dict(kind='expo-archive-extraction', classification=(
                    'duplicate-archive-extraction' if complete else 'incomplete-archive-extraction'),
                candidatePath=str(target), preservePaths=[str(source)],
                retainedArchive=dict(path=str(source), sha256=archive_hash.hexdigest(), identity=source_identity),
                archiveMembers=member_count, archiveFiles=len(archive_files), matchedFiles=len(proofs),
                archiveExpandedBytes=total_bytes,
                archiveApp={key: info[key] for key in ('CFBundleIdentifier', 'CFBundleExecutable',
                            'CFBundleVersion', 'CFBundleShortVersionString')},
                missingFiles=len(archive_files)-len(proofs), partialFiles=partials,
                matchedBytes=sum(item['localBytes'] for item in proofs), fileProofs=proofs,
                fingerprint=fingerprint, usage='unverified', regeneration='unverified',
                deletionAuthorized=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path')
    parser.add_argument('--archive', required=True)
    parser.add_argument('--home', required=True)
    arguments = parser.parse_args()
    try:
        result = inspect(arguments.path, arguments.archive, arguments.home)
    except (OSError, ValueError, EOFError, tarfile.TarError, plistlib.InvalidFileException,
            subprocess.SubprocessError) as error:
        print(json.dumps(dict(status='preserved', reason=str(error)), ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
