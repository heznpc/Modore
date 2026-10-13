#!/usr/bin/env python3
"""Read-only contracts for generated caches outside the original recipe list.

The cleanup harness owns approval, usage checks, staging, deletion and receipts.
This module only proves a narrowly scoped target and its recreation evidence.
"""
import argparse
import base64
import csv
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import zipfile
try:
    import tomllib
except ImportError:  # Development checkouts may still use macOS Python 3.9.
    tomllib = None

XCODE_OUTPUTS = {'Build', 'ModuleCache.noindex', 'Index.noindex',
                 'SDKStatCaches.noindex', 'CompilationCache.noindex'}
EVIDENCE_SUFFIXES = {'.xcresult', '.logarchive', '.trace', '.log', '.mov', '.mp4', '.jsonl', '.sqlite', '.sqlite3', '.ipynb'}
VERSION = re.compile(r'^\d+\.\d+\.\d+$')


def review_candidate(path, home=None):
    """Cheap discovery only. Approval still requires the complete inspect()."""
    home = Path(home or Path.home()); p = Path(path)
    if not p.is_dir() or not p.is_relative_to(home) or any(x.endswith('.app') for x in p.parts): return False
    if p.name == '.next': return (p.parent/'package.json').is_file()
    if p.name == '.venv': return (p/'pyvenv.cfg').is_file()
    if p.name in XCODE_OUTPUTS: return (p.parent/'info.plist').is_file()
    if p.name == 'test-products': return p.parent.parent == home/'Library/Developer/XcodeBuildMCP/workspaces'
    if p.parent == home/'.vscode/extensions':
        try: return package(p.parent/'.obsolete').get(p.name) is True
        except (OSError,ValueError): return False
    if p.name == 'engine' and p.parent.name == 'artifacts' and p.parent.parent.name == 'cache':
        return (p.parents[2]/'flutter').is_file()
    return p in {home/x for x in (
        '.dartServer/.analysis-driver', 'Library/Caches/node-gyp', 'Library/Caches/electron',
        'Library/Application Support/Code/CachedExtensionVSIXs',
        'Library/Application Support/Google/GoogleUpdater/crx_cache')}


def require(condition, message):
    if not condition: raise ValueError(message)


def physical(path):
    p = Path(path).absolute()
    require(p == p.resolve(), '심볼릭 링크가 포함된 경로는 직접 정리하지 않습니다.')
    return p


def regular(path):
    s = Path(path).lstat()
    require(stat.S_ISREG(s.st_mode) and s.st_uid in (0, os.getuid()) and s.st_nlink == 1,
            '원본·명세 파일의 소유권 또는 파일 형식을 확인하지 못했습니다.')
    require(not s.st_mode & 0o022, '다른 사용자가 변경할 수 있는 명세입니다.')
    return s


def read(path):
    require(regular(path).st_size <= 16_000_000, '명세 파일 크기가 검증 상한을 넘었습니다.')
    return Path(path).read_bytes()


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for data in iter(lambda: f.read(1024*1024), b''): h.update(data)
    return h.hexdigest()


def package(path):
    value = json.loads(read(path))
    require(isinstance(value, dict), '패키지 명세 형식이 올바르지 않습니다.')
    return value


def signed_app(home, name, identifier):
    for app in (home/'Applications'/name, Path('/Applications')/name):
        if not app.is_dir(): continue
        physical(app)
        verified = subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)], capture_output=True, timeout=25)
        description = subprocess.run(['/usr/bin/codesign','-d',str(app)], capture_output=True, text=True, timeout=5)
        if verified.returncode == 0 and f'Identifier={identifier}' in description.stderr.splitlines():
            return app/'Contents/Info.plist'
    raise ValueError('캐시를 재생성할 설치 앱의 서명을 확인하지 못했습니다.')


def proof_tree(path, external_links=(), kind=''):
    """Never traverse linked trees; preserve execution evidence at any depth."""
    device = path.stat().st_dev
    count = 0; entries = []
    def fail(error): raise error
    for directory, dirs, files in os.walk(path, followlinks=False, onerror=fail):
        for name in dirs + files:
            p = Path(directory)/name; s = p.lstat(); count += 1
            require(count <= 150000, '파일 수가 검증 상한을 넘어 보존합니다.')
            require(s.st_uid == os.getuid() and s.st_dev == device, '다른 소유자·볼륨의 자료가 섞여 있습니다.')
            require(p.suffix.lower() not in EVIDENCE_SUFFIXES and not name.lower().startswith(('testresults','attachments','result-bundles','logs')),
                    '테스트·로그·영상 증거가 섞여 있어 폴더 전체를 보존합니다.')
            require(name not in ('.git','.env','.ssh'), '원본·비밀 설정이 섞여 있어 보존합니다.')
            if kind in ('next','xcode','xcode-tests'):
                known_build_db = kind.startswith('xcode') and name == 'build.db' and p.parent.name == 'XCBuildData'
                known_version = kind.startswith('xcode') and re.fullmatch(r'swift-version--[A-Z0-9]+\.txt',name)
                require(p.suffix.lower() not in ('.txt','.md','.rst','.csv','.tsv','.db','.pdf') or known_build_db or known_version,
                        '메모·문서·데이터 파일이 있어 생성 폴더 전체를 보존합니다.')
            require(stat.S_ISDIR(s.st_mode) or stat.S_ISREG(s.st_mode) or stat.S_ISLNK(s.st_mode), '특수 파일이 섞여 있습니다.')
            if p.is_symlink():
                require(p.resolve().is_relative_to(path) or p in external_links, '원본을 가리키는 외부 링크가 있어 보존합니다.')
            entries.append([str(p.relative_to(path)), s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns])
    return sorted(entries)


def xcode_source(parent, home):
    info = parent/'info.plist'
    value = plistlib.loads(read(info))
    source = physical(value.get('WorkspacePath', ''))
    require(source.is_relative_to(home) and source.suffix in ('.xcodeproj','.xcworkspace'), 'Xcode 원본 경로가 없습니다.')
    marker = source/('project.pbxproj' if source.suffix == '.xcodeproj' else 'contents.xcworkspacedata')
    read(marker)
    return [info, marker], source.parent


def virtual_environment(p):
    evidence = [p/'pyvenv.cfg']
    require(b'home' in read(evidence[0]), 'Python 가상환경 설정을 확인하지 못했습니다.')
    locks = [p.parent/n for n in ('uv.lock','poetry.lock','requirements.txt') if (p.parent/n).is_file()]
    require(locks, '가상환경을 복원할 잠금 파일·고정 requirements가 없습니다.')
    locked = {}
    normalize = lambda name: re.sub(r'[-_.]+','-',name).lower()
    for lock in locks:
        content = read(lock).decode()
        require(not re.search(r'(?im)^\s*(-e\s|editable\s*=\s*true)|file://|\bpath\s*=', content), '로컬·편집 가능 의존성이 있어 보존합니다.')
        if lock.name == 'requirements.txt':
            lines = [x.strip() for x in content.splitlines() if x.strip() and not x.lstrip().startswith('#')]
            require(lines and all(re.match(r'^[A-Za-z0-9_.\[\],-]+==[A-Za-z0-9_.+-]+(?:\s*;.*)?$', x) for x in lines),
                    'requirements의 모든 의존성이 고정 버전이어야 합니다.')
            for line in lines:
                name,version=line.split(';',1)[0].strip().split('==',1)
                locked.setdefault(normalize(name.split('[',1)[0]),set()).add(version)
        else:
            require(tomllib is not None, '이 잠금 명세는 앱에 포함된 Python 3.11 이상으로 검증해야 합니다.')
            manifest=tomllib.loads(content)
            require(isinstance(manifest.get('package'),list), '잠금 명세에 패키지 목록이 없습니다.')
            for item in manifest['package']:
                require(isinstance(item.get('name'),str) and isinstance(item.get('version'),str), '잠금 명세의 이름·버전이 없습니다.')
                locked.setdefault(normalize(item['name']),set()).add(item['version'])
    evidence += locks
    if (p.parent/'pyproject.toml').is_file(): evidence.append(p.parent/'pyproject.toml')
    sites = list((p/'lib').glob('python*/site-packages'))
    require(sites, '가상환경 패키지 목록을 확인하지 못했습니다.')
    recorded = set()
    for site in sites:
        records = list(site.glob('*.dist-info/RECORD'))
        require(records, '설치 패키지의 RECORD 검증 자료가 없습니다.')
        for record in records:
            evidence.append(record)
            from email.parser import BytesParser
            metadata_path=record.parent/'METADATA'
            metadata=BytesParser().parsebytes(read(metadata_path),headersonly=True)
            name=metadata.get('Name',''); version=metadata.get('Version','')
            require(name and version and version in locked.get(normalize(name),set()),
                    '잠금 명세와 설치 패키지 이름·버전이 다릅니다. 현재 환경의 복원 명세를 갱신한 뒤 다시 조사하세요.')
            evidence.append(metadata_path)
            for row in csv.reader(read(record).decode().splitlines()):
                require(len(row) >= 2, '패키지 RECORD 형식 오류')
                target = (site/row[0]).resolve()
                require(target.is_relative_to(p), '가상환경 밖을 참조하는 RECORD입니다.')
                recorded.add(target)
                if not row[1]:
                    require(target == record or target.suffix == '.pyc', '해시 없는 설치 파일이 있어 보존합니다.')
                    continue
                require(row[1].startswith('sha256='), '지원하지 않는 패키지 검증 해시입니다.')
                regular(target)
                actual = base64.urlsafe_b64encode(bytes.fromhex(sha(target))).rstrip(b'=').decode()
                require(actual == row[1].split('=',1)[1], '설치 후 수정된 패키지 파일이 있어 보존합니다.')
        for item in site.rglob('*'):
            require(not item.is_symlink(), '가상환경에 연결된 로컬 패키지가 있어 보존합니다.')
            if item.is_file() and item.suffix != '.pyc':
                require(item in recorded, '설치 목록에 없는 사용자 파일이 있어 보존합니다.')
            if item.name == 'direct_url.json':
                direct = package(item)
                require(not direct.get('dir_info',{}).get('editable') and not direct.get('url','').startswith('file:'), '로컬 설치 패키지는 보존합니다.')
    # Keep unknown scripts and notebooks outside installed package RECORDs.
    links = []
    for item in p.rglob('*'):
        if item.is_dir() and not item.is_symlink(): continue
        if any(item.is_relative_to(site) for site in sites): continue
        if item.resolve() in recorded: continue
        relative = item.relative_to(p).as_posix()
        if relative == 'pyvenv.cfg': continue
        if relative == '.gitignore' and read(item).strip() in (b'*', b'# Created by venv automatically.\n*'): continue
        if relative == 'CACHEDIR.TAG' and read(item).startswith(b'Signature: 8a477f597d28d172789f06886806bc55'): continue
        if re.fullmatch(r'bin/python(?:[0-9.]+)?', relative):
            require(item.is_symlink() and item.resolve().is_file(), '가상환경 Python 원본을 확인하지 못했습니다.')
            links.append(item); continue
        if relative in ('bin/activate','bin/activate.csh','bin/activate.fish','bin/Activate.ps1'):
            require(b'VIRTUAL_ENV' in read(item), '가상환경 활성화 스크립트 형식이 다릅니다.')
            evidence.append(item); continue
        raise ValueError('설치 목록 밖의 가상환경 자료가 있어 보존합니다: '+relative)
    return evidence, links


def dart_cache(p, home):
    # Dart FileByteStoreValidator v1 appends version 01 00 + Fletcher-16.
    # Unknown/single-file database formats remain preserved.
    candidates = [home/'flutter/bin/cache/dart-sdk', home/'development/flutter/bin/cache/dart-sdk']
    candidates += list((home/'.local/share/mise/http-tarballs').glob('*/bin/cache/dart-sdk'))
    sdk = next((x for x in candidates if (x/'bin/snapshots/analysis_server.dart.snapshot').is_file()
                and (x/'bin/dart').is_file() and (x/'version').is_file()), None)
    require(sdk, '분석 캐시를 재생성할 Dart SDK를 확인하지 못했습니다.')
    require(re.match(rb'^\d+\.\d+\.\d+', read(sdk/'version')), 'Dart SDK 버전을 확인하지 못했습니다.')
    files = [x for x in p.rglob('*') if x.is_file()]
    require(files, '비어 있는 분석 캐시입니다.')
    for item in files:
        rel = item.relative_to(p)
        require(len(rel.parts) in (1,2) and re.fullmatch(r'[0-9a-f]{32,64}\.[A-Za-z0-9_]+',item.name)
                and (len(rel.parts)==1 or rel.parts[0]==item.name[:2]), '알 수 없는 분석 캐시 파일을 보존합니다.')
        data = read(item)
        require(len(data)>=4 and data[-4:-2]==b'\x01\x00', 'Dart 캐시 버전 서명 불일치')
        payload=data[:-4]; total=sum(payload)%255
        weighted=sum((len(payload)-i)*value for i,value in enumerate(payload))%255
        require(data[-2:]==bytes((total,weighted)), 'Dart 캐시 체크섬 불일치')
    return [sdk/'version'], sdk


def inspect(path, home=None, contents=True):
    home = physical(home or Path.home()); p = physical(path)
    require(p.is_relative_to(home) and p != home and p.is_dir(), '홈 아래의 검증된 생성 폴더만 지원합니다.')
    require(not any(x.endswith('.app') for x in p.parts), '앱 내부 구성요소는 개별 정리하지 않습니다.')
    st = p.lstat()
    require(st.st_uid == os.getuid() and not st.st_mode & 0o022, '대상 소유권·권한을 확인하지 못했습니다.')
    evidence = []; links = []; source = p.parent; scope = 'global'; kind = ''; tools = ''
    if p.name == '.next':
        spec = p.parent/'package.json'; data = package(spec)
        require('next' in {**data.get('dependencies',{}), **data.get('devDependencies',{})}, 'Next.js 원본 명세가 없습니다.')
        locks = [p.parent/n for n in ('package-lock.json','pnpm-lock.yaml','yarn.lock','bun.lock','bun.lockb') if (p.parent/n).is_file()]
        require(locks, 'Next.js 의존성 잠금 파일이 없습니다.')
        manifests = [p/n for n in ('build-manifest.json','server/app-paths-manifest.json','routes-manifest.json') if (p/n).is_file()]
        require(manifests, 'Next.js 생성 매니페스트가 없습니다.')
        for manifest in manifests: package(manifest)
        evidence = [spec]+locks+manifests; kind = 'next'; scope = 'project'; tools = '(^|/)(node|next|npm|pnpm|yarn|bun)( |$)'
    elif p.name == '.venv':
        evidence, links = virtual_environment(p); kind = 'venv'; scope = 'project'; tools = '(^|/)(python[0-9.]*|uv|pip[0-9.]*|poetry)( |$)'
    elif p.name in XCODE_OUTPUTS and (p.parent/'info.plist').is_file():
        evidence, source = xcode_source(p.parent,home)
        require(p.parent.name == 'build' or 'DerivedData' in p.parts, '등록된 Xcode 출력 경로가 아닙니다.')
        kind = 'xcode'; tools = 'xcodebuild|XcodeBuildMCP|xctest|/Xcode.app/'
    elif p.name == 'test-products' and p.parent.parent == home/'Library/Developer/XcodeBuildMCP/workspaces':
        manifests = list(p.rglob('*.xctestrun'))
        require(manifests, '테스트 실행물의 xctestrun 명세가 없습니다.')
        for manifest in manifests: require(isinstance(plistlib.loads(read(manifest)),dict), 'xctestrun 형식 오류')
        origins = list((p.parent/'DerivedData').glob('*/info.plist'))
        require(len(origins) == 1, '테스트 실행물의 원본 프로젝트를 하나로 확인하지 못했습니다.')
        evidence, source = xcode_source(origins[0].parent,home); evidence += manifests
        kind = 'xcode-tests'; tools = 'xcodebuild|XcodeBuildMCP|xctest|/Xcode.app/'
    elif p == home/'.dartServer/.analysis-driver':
        evidence,source = dart_cache(p,home); kind='dart-analysis'; tools='dart|flutter|analysis_server'
    elif p == home/'Library/Caches/node-gyp':
        versions = list(p.iterdir()); require(versions, '비어 있는 캐시입니다.')
        for version in versions:
            require(VERSION.fullmatch(version.name) and version.is_dir(), 'node-gyp 버전 출력 외의 자료가 있습니다.')
            marker = version/'installVersion'; header = version/'include/node/node_version.h'
            require(all(x.name in ('include','installVersion') for x in version.iterdir()), 'Node 헤더 외 자료가 있어 보존합니다.')
            require(read(marker).strip().isdigit(), 'node-gyp 설치 표식이 없습니다.')
            require(re.search(rb'#define\s+NODE_MAJOR_VERSION\s+'+version.name.split('.')[0].encode()+rb'\b',read(header)), 'Node 헤더와 캐시 버전이 다릅니다.')
            read(version/'include/node/node.h'); evidence += [marker,header]
        kind='node-gyp'; tools='node-gyp|(^|/)(npm|pnpm|yarn|node)( |$)'
    elif p == home/'Library/Caches/electron':
        archives = list(p.rglob('*.zip')); require(archives, 'Electron 다운로드 아카이브가 없습니다.')
        for archive in archives:
            require(re.fullmatch(r'electron-v[0-9.]+-darwin-(arm64|x64)\.zip',archive.name), 'Electron 버전·플랫폼이 명확하지 않습니다.')
            with zipfile.ZipFile(archive) as z:
                info=z.getinfo('Electron.app/Contents/Info.plist'); require(info.file_size<1000000,'아카이브 명세 상한 초과')
                require(plistlib.loads(z.read(info)).get('CFBundleIdentifier')=='com.github.Electron', 'Electron 앱 아카이브가 아닙니다.')
            evidence.append(archive)
        require(all(x.is_dir() or x.suffix=='.zip' or x.name=='SHASUMS256.txt' for x in p.rglob('*')), '다운로드 외 자료가 있어 보존합니다.')
        kind='electron'; tools='electron|(^|/)(npm|pnpm|yarn)( |$)'
    elif p == home/'Library/Application Support/Code/CachedExtensionVSIXs':
        evidence.append(signed_app(home,'Visual Studio Code.app','com.microsoft.VSCode'))
        files=list(p.iterdir()); require(files, '비어 있는 캐시입니다.')
        for item in files:
            require(item.is_file() and not item.is_symlink(), '확장 아카이브 외 자료가 있습니다.')
            with zipfile.ZipFile(item) as z:
                info=z.getinfo('extension/package.json'); require(info.file_size<1000000,'확장 명세 상한 초과')
                spec=json.loads(z.read(info)); require(all(spec.get(k) for k in ('publisher','name','version')), '확장 출처·버전이 없습니다.')
                require('extension.vsixmanifest' in z.namelist(), 'VSIX 형식 표식이 없습니다.')
            evidence.append(item)
        kind='vscode-download';tools='Visual Studio Code|Code Helper|/bin/code( |$)'
    elif p.parent == home/'.vscode/extensions':
        obsolete=p.parent/'.obsolete'; registry=p.parent/'extensions.json'; spec=package(p/'package.json')
        require(package(obsolete).get(p.name) is True, '사용 종료 표시가 없는 확장은 보존합니다.')
        current=json.loads(read(registry)); require(isinstance(current,list), '현재 확장 목록 형식 오류')
        require(not any(x.get('relativeLocation')==p.name or x.get('location',{}).get('path')==str(p) for x in current), '현재 등록된 확장입니다.')
        require(VERSION.fullmatch(spec.get('version','')), '확장 버전 순서를 확인하지 못했습니다.')
        replacement=None
        for x in current:
            relative=x.get('relativeLocation','')
            if not relative or '/' in relative: continue
            candidate=p.parent/relative/'package.json'
            if not candidate.is_file(): continue
            other=package(candidate)
            if all(other.get(k)==spec.get(k) for k in ('name','publisher')) and VERSION.fullmatch(other.get('version','')):
                if tuple(map(int,other['version'].split('.'))) > tuple(map(int,spec['version'].split('.'))): replacement=candidate; break
        require(replacement, '현재 등록된 더 새 버전이 없습니다.')
        evidence=[obsolete,registry,p/'package.json',replacement]; kind='vscode-obsolete'; tools='Visual Studio Code|Code Helper|/bin/code( |$)|'+re.escape(str(p))
    elif p.name == 'engine' and p.parent.name == 'artifacts' and p.parent.parent.name == 'cache' and p.parents[2].name == 'bin':
        sdk=p.parents[3]; engine=sdk/'bin/internal/engine.version'; cache=sdk/'packages/flutter_tools/lib/src/cache.dart'
        require((sdk/'bin/flutter').is_file() and (sdk/'packages/flutter_tools/pubspec.yaml').is_file(), 'Flutter SDK 원본이 없습니다.')
        require(re.fullmatch(rb'[0-9a-f]{40}',read(engine).strip()), 'Flutter 엔진 버전이 없습니다.')
        require(b'engine' in read(cache), 'Flutter 캐시 재생성 코드를 확인하지 못했습니다.')
        require(all(re.match(r'^(android|ios|darwin|linux|windows|common|LICENSE)',x.name) for x in p.iterdir()), 'Flutter 엔진 외 자료가 있습니다.')
        evidence=[engine,cache,sdk/'packages/flutter_tools/pubspec.yaml'];source=sdk; kind='flutter-engine';tools='flutter|dart-sdk/bin/dart'
    elif p == home/'Library/Application Support/Google/GoogleUpdater/crx_cache':
        applications=sorted(x for x in p.parent.glob('*/GoogleUpdater.app') if not x.parent.is_symlink())
        require(applications,'GoogleUpdater 원본 앱이 없습니다.')
        app=applications[0]
        verified=subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],capture_output=True,timeout=25)
        require(verified.returncode==0,'GoogleUpdater 앱 서명 검증 실패')
        info=app/'Contents/Info.plist';require(plistlib.loads(read(info)).get('CFBundleIdentifier')=='com.google.GoogleUpdater','GoogleUpdater 앱 식별 실패')
        evidence=[info]
        for item in p.iterdir():
            regular(item)
            with item.open('rb') as f:
                header=f.read(12)
                require(len(header)==12 and header[:8]==b'Cr24\x03\x00\x00\x00', 'CRX3 다운로드 형식을 확인하지 못한 파일이 있습니다.')
                size=int.from_bytes(header[8:12],'little')
                require(0<size<1000000, 'CRX3 헤더 크기 오류')
                f.seek(12+size); require(f.read(4)==b'PK\x03\x04', 'CRX 압축 본문을 확인하지 못했습니다.')
            evidence.append(item)
        require(len(evidence)>1,'비어 있는 캐시입니다.')
        kind='google-crx';tools='GoogleUpdater|GoogleSoftwareUpdate|ksadmin'
    else:
        raise ValueError('이 경로의 재생성 명세·캐시 형식 검증은 아직 지원하지 않습니다.')
    tree = proof_tree(p, links, kind) if contents else []
    # Hash source evidence as well as generated manifests. Large archives are
    # streamed; no private contents are emitted in the result.
    hashes=[]
    for item in evidence:
        before=regular(item); digest=sha(item); after=regular(item)
        require((before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)==
                (after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns), '검증 중 명세가 변경되었습니다.')
        hashes.append([str(item),digest])
    if contents: require(tree == proof_tree(p, links, kind), '검증 중 대상 내용이 변경되어 보존합니다.')
    fingerprint=hashlib.sha256(json.dumps([str(p),kind,hashes,tree],sort_keys=True).encode()).hexdigest()
    return dict(kind=kind,source=str(source),scope=scope,processPattern=tools,
                fingerprint=fingerprint,evidence=[str(x) for x in evidence])


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path');parser.add_argument('--home',required=True)
    args=parser.parse_args()
    def timed_out(*_): raise ValueError('검증 시간 한도를 넘어 보존합니다. 관련 도구를 종료한 뒤 다시 조사하세요.')
    signal.signal(signal.SIGALRM,timed_out); signal.alarm(25)
    try:
        result=inspect(args.path,args.home)
        for key in ('kind','source','scope','processPattern','fingerprint'):
            value=result[key]; require(not any(x in value for x in ('\n','\r','\t')), '잘못된 증거 값')
            print(key+'\t'+value)
    except (OSError,ValueError,KeyError,TypeError,zipfile.BadZipFile,subprocess.SubprocessError) as error:
        print('error\t'+str(error).replace('\n',' ').replace('\t',' ')); return 1
    return 0


if __name__=='__main__': raise SystemExit(main())
