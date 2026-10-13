#!/usr/bin/env python3
"""Modore environment retirement: observed inventory, exact approvals and receipts.
Only platform commands mutate simulator resources. No inferred session authority.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid
import app_registrations
import generated_cache

ROOT = Path.home() / 'Library/Application Support/Modore/environment-retirement'

def run(args, timeout=30):
    p = subprocess.run(args, capture_output=True, timeout=timeout)
    if p.returncode:
        raise ValueError(p.stderr.decode(errors='replace').strip() or 'Command failed: ' + str(p.returncode))
    return p.stdout

def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()

def save(path, value):
    if path.is_symlink(): raise ValueError('기록 경로 식별 실패')
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, ensure_ascii=False); f.flush(); os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)

@contextlib.contextmanager
def locked(root):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.is_symlink(): raise ValueError('기록 폴더 식별 실패')
    fd = os.open(root / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX); yield
    finally: os.close(fd)

def capacity():
    s = os.statvfs('/System/Volumes/Data')
    return {'totalBytes': s.f_blocks*s.f_frsize, 'freeBytes': s.f_bavail*s.f_frsize,
            'observedAt': time.time()}

def memory():
    output = run(['/usr/sbin/sysctl', 'vm.swapusage', 'kern.memorystatus_vm_pressure_level']).decode()
    return output.strip()

def allocated(path):
    try:
        return int(run(['/usr/bin/du', '-skx', str(path)], 25).split()[0])*1024
    except Exception: return None

def platform(device):
    t = device.get('deviceTypeIdentifier', '')
    if 'Watch' in t: return 'watchOS'
    if 'iPad' in t: return 'iPadOS'
    if 'iPhone' in t or 'iPod' in t: return 'iOS'
    return 'other'

def simulator_inventory(measure=True):
    payload = json.loads(run(['/usr/bin/xcrun', 'simctl', 'list', 'devices', '--json']))
    images = json.loads(run(['/usr/bin/xcrun', 'simctl', 'runtime', 'list', '-j']))
    rows = []
    for runtime, devices in payload['devices'].items():
        for d in devices:
            path = d.get('dataPath', '')
            identity = [d['udid'], runtime, d.get('deviceTypeIdentifier'), path, d.get('lastBootedAt'), d['state']]
            try:
                st = os.stat(path, follow_symlinks=False)
                identity += [st.st_dev, st.st_ino, st.st_mtime_ns]
            except OSError: identity += ['missing']
            rows.append({'id': 'device:'+d['udid'], 'target': d['udid'], 'kind': 'device',
                         'name': d['name'], 'platform': platform(d), 'runtime': runtime,
                         'state': d['state'], 'path': path, 'project': '',
                         'bytes': allocated(str(Path(path).parent)) if measure and path else None,
                         'fingerprint': digest(identity), 'warnings': ['기기 안의 앱·로그인·테스트 데이터가 영구 삭제됩니다.'],
                         'invariant': ''})
    keep=Path.home()/'Library/Application Support/Modore/simulator-keep.txt'
    kept=set(keep.read_text().upper().splitlines()) if keep.exists() else set()
    lease_path=Path.home()/'Library/Application Support/Modore/work-resources/leases.json'
    leases=json.loads(lease_path.read_text()).get('leases',[]) if lease_path.exists() else []
    for row in rows:
        if row['target'] in kept: row['warnings'].append('사용자가 유지 표시한 기기입니다. 이번 삭제를 직접 선택하면 계속할 수 있습니다.')
        active=[l for l in leases if l['resourceID']==row['target'] and l['expiresAt']>time.time()]
        row['project']=' · '.join(sorted({l['project'] for l in active}))
        row['warnings'] += ['연결된 작업: '+l['project']+' · 세션 '+l['session'] for l in active]
        if row['state']!='Shutdown': row['warnings'].append('실행 중입니다. 삭제를 선택하면 먼저 종료되어 현재 작업이 중단됩니다.')
    for rid, d in images.items():
        rows.append({'id':'runtime:'+rid,'target':rid,'kind':'runtime','name': d.get('version','')+' '+d.get('runtimeIdentifier','').split('.')[-1],
                     'platform':'watchOS' if 'watch' in d.get('platformIdentifier','').lower() else 'iOS / iPadOS',
                     'runtime':d.get('runtimeIdentifier',''), 'state':d['state'], 'path':d.get('path',''), 'project':'',
                     'bytes': d.get('sizeBytes'), 'fingerprint':digest([rid,d.get('build'),d.get('path'),d.get('lastUsedAt'),d['state']]),
                     'warnings':['런타임을 다시 다운로드해야 이 OS의 기기를 실행할 수 있습니다.', '연결 기기: '+', '.join(x['name'] for x in rows if x['kind']=='device' and x['runtime']==d.get('runtimeIdentifier'))],
                     'invariant':'' if d.get('deletable') and d['state']=='Ready' else '런타임의 삭제 가능 상태를 확인하지 못했습니다.'})
        rows.append({'id':'cache:'+rid,'target':d.get('runtimeIdentifier',''),'kind':'cache','name':d.get('version','')+' 재생성 캐시',
                     'platform':'watchOS' if 'watch' in d.get('platformIdentifier','').lower() else 'iOS / iPadOS',
                     'runtime':d.get('runtimeIdentifier',''),'state':d['state'],'path':'','project':'','bytes':None,
                     'fingerprint':digest([rid,d.get('build'),d.get('runtimeIdentifier')]),
                     'warnings':['다음 실행 때 다시 만들어져 첫 실행이 느려질 수 있습니다.'], 'invariant':''})
    return rows

def processes(projects):
    """PID + launch time + command + cwd, never a PID alone. User-owned servers only."""
    projects = [str(Path(p).resolve()) for p in projects if p.startswith('/') and p not in ('/',str(Path.home()),'/tmp','/private/tmp')]
    if not projects: return []
    raw = run(['/bin/ps','-axo','pid=,uid=,lstart=,comm=']).decode(errors='replace')
    cwd = {}; current = None
    p = subprocess.run(['/usr/sbin/lsof','-a','-u',str(os.getuid()),'-d','cwd','-Fpn'],capture_output=True,timeout=15)
    if p.returncode not in (0,1): raise ValueError('프로젝트 프로세스의 작업 폴더를 확인하지 못했습니다.')
    for line in p.stdout.decode(errors='replace').splitlines():
        if line.startswith('p'): current=int(line[1:])
        if line.startswith('n') and current: cwd[current]=line[1:]
    rows=[]
    for line in raw.splitlines():
        fields=line.split(None,7)
        if len(fields)!=8: continue
        pid, uid=int(fields[0]),int(fields[1]); executable=fields[7]
        name=Path(executable).name
        if uid!=os.getuid() or name not in ('node','python','python3','python3.11','python3.12','ruby','java','bun','deno','uvicorn','limactl'): continue
        if name=='limactl':
            args=run(['/bin/ps','-p',str(pid),'-o','command=']).decode().split()
            if len(args)<2 or args[1]!='usernet':continue
            name='Lima 네트워크 도우미'
        path=cwd.get(pid,'')
        project=next((x for x in sorted(projects,key=len,reverse=True) if path==x or path.startswith(x+'/')),None)
        if not project: continue
        rows.append({'id':'process:'+str(pid),'target':str(pid),'kind':'process','name':name,'platform':'프로젝트 서버',
                     'runtime':'','state':'Running','path':path,'project':project,'bytes':None,
                     'fingerprint':digest([pid,uid,fields[2:7],executable,path]),
                     'warnings':['선택한 서버에 정상 종료 신호를 보냅니다. 진행 중인 요청이 끊길 수 있습니다.'], 'invariant':''})
    return rows


def plist_json(payload):
    p=subprocess.run(['/usr/bin/plutil','-convert','json','-o','-','-'],input=payload,capture_output=True,check=True)
    return json.loads(p.stdout)

def volume_inventory():
    rows=[]
    for path in Path('/Volumes').iterdir():
        if path.is_symlink():continue
        d=plist_json(run(['/usr/sbin/diskutil','info','-plist',str(path)]))
        if d.get('Internal',True) or not d.get('VolumeUUID') or not d.get('MountPoint'):continue
        rows.append({'id':'volume:'+d['VolumeUUID'],'target':d['VolumeUUID'],'kind':'volume','name':d.get('VolumeName',path.name),
                     'platform':'외장 SSD','runtime':'','state':'Mounted','path':d['MountPoint'],'project':'','bytes':None,
                     'fingerprint':digest([d['VolumeUUID'],d['DeviceIdentifier'],d['MountPoint']]),
                     'warnings':['점유 중인 서버·VM을 먼저 선택해 정상 종료할 수 있습니다. 추출에 실패하면 점유 상태를 다시 확인합니다.','같은 물리 디스크의 다른 볼륨도 연결 해제될 수 있습니다.'], 'invariant':''})
    return rows

def vm_inventory():
    executable=next((p for p in ['/opt/homebrew/bin/limactl','/usr/local/bin/limactl'] if Path(p).is_file()),None)
    if not executable:return []
    import shlex
    lines=run(['/bin/ps','-axo','pid=,uid=,lstart=,command=']).decode(errors='replace').splitlines()
    rows=[]
    for line in lines:
        parts=line.split(None,7)
        if len(parts)!=8 or int(parts[1])!=os.getuid():continue
        try: args=shlex.split(parts[7])
        except ValueError:continue
        if len(args)<2 or args[0]!=executable or args[1]!='hostagent' or '--pidfile' not in args:continue
        pidfile=Path(args[args.index('--pidfile')+1]);directory=pidfile.parent;home=directory.parent
        env=dict(os.environ,LIMA_HOME=str(home))
        try:
            result=subprocess.run([executable,'list','--json'],env=env,stdin=subprocess.DEVNULL,capture_output=True,timeout=8)
            if result.returncode:raise ValueError(result.stderr.decode(errors='replace')[:500] or 'VM 목록 조회 실패')
        except (subprocess.TimeoutExpired, ValueError) as exc:
            rows.append({'id':'vm:'+digest([str(home),directory.name]),'target':directory.name,'kind':'vm','name':directory.name,
                         'platform':'Lima / Colima VM','runtime':executable,'state':'확인 필요','path':str(home),'project':'','bytes':None,
                         'fingerprint':digest([str(home),directory.name,parts[:7],'unverified']),
                         'warnings':['실행 프로세스는 관찰됐지만 VM 상태를 읽지 못했습니다. 폴더 접근 허용에서 해당 외장 SSD 폴더를 선택한 뒤 다시 측정하세요.'],
                         'invariant':'VM 상태 확인 필요 · 폴더 접근 허용 후 다시 측정'})
            continue
        for line in result.stdout.decode().splitlines():
            vm=json.loads(line)
            if vm.get('hostAgentPID')!=int(parts[0]) or vm.get('dir')!=str(directory) or vm.get('status')!='Running':continue
            rows.append({'id':'vm:'+digest([str(home),vm['name']]),'target':vm['name'],'kind':'vm','name':vm['name'],
                         'platform':'Lima / Colima VM','runtime':executable,'state':'Running','path':str(home),'project':'','bytes':None,
                         'fingerprint':digest([str(home),vm['name'],parts[:7],directory.stat().st_dev,directory.stat().st_ino]),
                         'warnings':['VM 안의 DB·컨테이너가 정상 종료됩니다. 저장된 디스크 데이터는 유지됩니다.','할당 메모리 '+str(round(vm.get('memory',0)/1073741824,1))+' GiB (실제 회수량 아님)'], 'invariant':''})
    return rows

def policy(root):
    p=root/'policy.json'
    return json.loads(p.read_text()) if p.exists() else {'platforms':['iOS','iPadOS','watchOS'], 'requirements':[], 'scheduleEnabled':False,'intervalHours':24,'minimumFreeGB':15,'cacheIDs':[]}

def annotate(rows, pol):
    needed=set(pol.get('platforms',[]))
    for row in rows:
        if row['kind']=='device' and row['platform'] in needed:
            row['warnings'].append(row['platform']+' 유지 요구가 있습니다. 삭제 후 같은 플랫폼의 기기가 남는지 확인하세요.')
        for req in pol.get('requirements',[]):
            if req.get('runtime')==row['runtime'] and (row['kind']!='device' or req.get('platform')==row['platform']):
                row['warnings'].append('프로젝트 요구: '+req.get('project','')+' · '+req.get('platform','')+' '+req['runtime'])
    return rows

def inventory(req, root, measure=True):
    warnings=[]
    try: rows=simulator_inventory(measure)
    except Exception as exc: rows=[];warnings.append('시뮬레이터 조회 불완전: '+str(exc))
    try: rows+=processes(req.get('projects',[]))
    except Exception as exc: warnings.append('프로젝트 조회 불완전: '+str(exc))
    try: rows+=vm_inventory()
    except Exception as exc: warnings.append('VM 조회 불완전: '+str(exc))
    try: rows+=volume_inventory()
    except Exception as exc: warnings.append('외장 드라이브 조회 불완전: '+str(exc))
    try: rows+=app_registrations.rows(run)
    except Exception as exc: warnings.append('앱 등록 조회 불완전: '+str(exc))
    pol=policy(root)
    missing=[p for p in pol['platforms'] if not any(x['kind']=='device' and x['platform']==p for x in rows)]
    return {'observedAt':time.time(),'capacity':capacity(),'memory':memory(),'items':annotate(rows,pol),'warnings':warnings,
            'missingPlatforms':missing,'policy':pol,'cacheBytes':allocated('/Library/Developer/CoreSimulator/Caches/dyld') if measure else None}

def plan_path(root, pid):
    uuid.UUID(pid)
    return root/('plan-'+pid+'.json')

def preview(req, root):
    snap=inventory(req,root)
    items=[]
    for row in snap['items']:
        row.update({'approved':False,'mutation':'pending','verification':'pending','error':'','changed':False})
        items.append(row)
    plan={'id':str(uuid.uuid4()),'createdAt':time.time(),'projects':req.get('projects',[]),'items':items,'before':snap['capacity'],
          'after':None,'memoryBefore':snap['memory'],'memoryAfter':'','warnings':snap['warnings'],'missingPlatforms':snap['missingPlatforms'],
          'policy':snap['policy'],'cacheBytes':snap['cacheBytes'],'cancelled':False}
    save(plan_path(root,plan['id']),plan);return plan

def observe_item(item, projects):
    if item['kind']=='registration':return next((r for r in app_registrations.rows(run,True) if r['id']==item['id']),None)
    rows=processes(projects) if item['kind']=='process' else (vm_inventory() if item['kind']=='vm' else (volume_inventory() if item['kind']=='volume' else simulator_inventory(False)))
    return next((r for r in rows if r['id']==item['id']),None)

def verify(item, projects):
    if item['kind']=='cache':
        # API success is not proof that aggregate bytes are immediately released.
        return 'requested'
    return 'verified' if observe_item(item,projects) is None else 'pending'

def execute(plan, root, selected):
    path=plan_path(root,plan['id']);cancel=root/('cancel-'+plan['id'])
    # Devices before runtime removal; disallow removing runtime under unselected running devices.
    for item in sorted(plan['items'], key=lambda i: {'process':0,'vm':1,'device':2,'cache':3,'runtime':4,'volume':5,'registration':6}[i['kind']]):
        if cancel.exists(): plan['cancelled']=True;break
        if item['id'] not in selected or not item['approved'] or item['changed']: continue
        if item['mutation']=='succeeded':
            try: item['verification']=verify(item,plan['projects'])
            except Exception as e: item['error']=str(e)
            continue
        try:
            current=observe_item(item,plan['projects'])
            if current is None and item['mutation']=='attempting' and item['kind']!='cache':
                item['mutation']='succeeded';item['verification']='verified';save(path,plan);continue
            if current is None or current['fingerprint']!=item['fingerprint']:
                item.update(changed=True,approved=False,error='대상 상태가 바뀌었습니다. 이 항목만 다시 확인하고 승인하세요.');save(path,plan);continue
            if current['invariant']: raise ValueError(current['invariant'])
            item['mutation']='attempting';save(path,plan)
            if item['kind']=='process': os.kill(int(item['target']),signal.SIGTERM)
            elif item['kind']=='vm':
                result=subprocess.run([item['runtime'],'stop',item['target']],env=dict(os.environ,LIMA_HOME=item['path']),capture_output=True,timeout=120)
                if result.returncode:raise ValueError(result.stderr.decode(errors='replace'))
            elif item['kind']=='registration':run([app_registrations.LSREGISTER,'-u',item['path']],45)
            elif item['kind']=='volume':run(['/usr/sbin/diskutil','eject',item['path']],60)
            elif item['kind']=='device':
                if current['state']!='Shutdown': run(['/usr/bin/xcrun','simctl','shutdown',item['target']],60)
                run(['/usr/bin/xcrun','simctl','delete',item['target']],60)
            elif item['kind']=='runtime': run(['/usr/bin/xcrun','simctl','runtime','delete',item['target']],60)
            else: run(['/usr/bin/xcrun','simctl','runtime','dyld_shared_cache','remove',item['target']],60)
            item['mutation']='succeeded';save(path,plan)
            item['verification']=verify(item,plan['projects']);item['error']=''
        except Exception as exc:
            if item['mutation']!='succeeded': item['mutation']='failed'
            item['error']=str(exc)
        save(path,plan)
    plan['after']=capacity();plan['memoryAfter']=memory();save(path,plan);return plan


def classify_storage(path):
    try:
        return _classify_storage(path)
    except OSError:
        return dict(classification='접근 확인 필요', evidence='내부 내용을 읽지 못해 삭제 가능성을 판단할 수 없습니다.', cleanupReview=False)


def _classify_storage(path):
    """Explain observed contents; never authorize deletion from a folder name."""
    p = Path(display_storage_path(str(path)))
    def result(kind, detail, review=False):
        return dict(classification=kind, evidence=detail, cleanupReview=review)
    if any(part.startswith('com_apple_MobileAsset_UAF_') for part in p.parts):
        if 'manifests' in p.parts:
            return result('시스템 자산 목록 메타데이터', '자산 목록·다운로드 메타데이터입니다. 모델 본체의 실제 할당량과 구분합니다.')
        return result('시스템 AI·언어 자산', 'Apple Intelligence·Siri·사진·언어 기능의 시스템 자산입니다. 제거하면 기능이 중단되거나 다시 다운로드될 수 있습니다. 메타데이터 크기는 실제 할당량·회수량과 다릅니다.')
    if 'http-tarballs' in p.parts and (p / 'bin/flutter').is_file():
        return result('설치된 Flutter SDK', '다운로드 보관 이름이어도 실행 가능한 SDK가 있습니다. 설치 경로의 심볼릭 링크가 이 원본을 사용할 수 있어 전체 삭제 대상으로 삼지 않습니다.')
    if p.name == 'cache' and p.parent.name == 'bin' and (p.parent / 'flutter').is_file():
        return result('Flutter SDK 재생성 캐시', 'Flutter 실행 파일을 확인했습니다. SDK 원본과 분리해 검토해야 하며, 다음 실행 때 다운로드·빌드가 필요합니다. 현재 사용 여부는 미확인입니다.')
    if generated_cache.review_candidate(p):
        return result('재생성 검증 대상', '지원하는 생성물 경로입니다. 선택 후 원본·복원 명세·캐시 형식·현재 사용·내부 보존 자료를 검사하며, 확인 실패 시 삭제를 차단합니다.', True)
    if p.name in ('DerivedData', 'test-products', 'result-bundles') and 'XcodeBuildMCP' in p.parts:
        return result('테스트·빌드 작업 자료', 'DerivedData·테스트 실행물·결과 묶음을 각각 검토하세요. 결과 묶음은 당시의 증거이며 재빌드로 복원되지 않습니다. 현재 사용 여부는 미확인입니다.')
    if p.name.endswith('.app-backup'):
        return result('앱 복구용 복사본', '이전 앱으로 되돌리기 위한 복사본일 수 있습니다. 현재 앱·복구 필요성을 확인한 뒤 개별 검토하세요.')
    if 'extensions' in p.parts and '.vscode' in p.parts:
        return result('편집기 확장 구성요소', '여러 버전이 있어도 현재 로드된 버전과 복구 필요성이 확인되지 않았습니다. 확장 관리 화면에서 검토하세요.')
    if any(part.endswith('.app') for part in p.parts):
        return result('앱 구성요소', '앱 번들의 일부입니다. 내부 의존성을 따로 지우면 앱이 손상될 수 있습니다.')
    if p.is_dir() and (p / 'PG_VERSION').is_file() and (p / 'base').is_dir():
        return result('실제 데이터베이스', 'PostgreSQL 버전 파일과 데이터 디렉터리가 있습니다. 백업·이관 확인이 필요합니다.')
    if p.suffix in ('.xcresult', '.logarchive', '.trace'):
        return result('테스트·진단 증거', '실행 당시 결과입니다. 재빌드로 같은 기록이 복원되지는 않습니다.')
    if p.suffix in ('.jsonl', '.sqlite', '.sqlite3', '.db'):
        return result('기록·데이터', '세션 또는 데이터 파일입니다. 캐시로 간주하지 않습니다.')
    if p.is_dir():
        try:
            with os.scandir(p) as children:
                for index, child in enumerate(children):
                    if index >= 512:
                        return result('내부 확인 미완료', '하위 항목 512개를 넘어 내용 검토가 필요합니다.')
                    if child.name.endswith(('.xcresult', '.logarchive', '.sqlite', '.db', '.jsonl')):
                        return result('기록이 섞인 폴더', '테스트 결과·세션·DB 파일이 함께 있습니다. 폴더 전체 삭제 후보에서 제외합니다.')
        except OSError:
            return result('접근 확인 필요', '내부 내용을 읽지 못해 삭제 가능성을 판단할 수 없습니다.')
    if p.is_dir() and (p / 'pyvenv.cfg').is_file():
        specs = [name for name in ('requirements.txt', 'uv.lock', 'poetry.lock')
                 if (p.parent / name).is_file()]
        return result('Python 실행 환경', 'pyvenv.cfg 확인. ' +
                      ('복원 명세: ' + ', '.join(specs) if specs else '부모 폴더에 복원 명세가 없습니다.') +
                      ' 설치 패키지와 로컬 수정 여부를 검토해야 합니다.')
    rules = {
        'node_modules': ('package.json', ('package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'bun.lock', 'bun.lockb')),
        'Pods': ('Podfile', ('Podfile.lock',)),
        '.build': ('Package.swift', ()),
        'target': ('Cargo.toml', ('Cargo.lock',)),
        '.dart_tool': ('pubspec.yaml', ('pubspec.lock',)),
        '.gradle': ('gradlew', ()),
    }
    rule = rules.get(p.name)
    if p.name == 'build':
        rule = next(((marker, ()) for marker in ('pubspec.yaml', 'gradlew', 'Package.swift')
                     if (p.parent / marker).is_file()), None)
    if p.is_dir() and rule and (p.parent / rule[0]).is_file():
        locks = [name for name in rule[1] if (p.parent / name).is_file()]
        if rule[1] and not locks:
            return result('의존성·산출물 추정', rule[0] + '는 있으나 잠금 파일이 없어 동일 버전 복원은 미확인입니다.')
        return result('재생성 근거 있음', '확인: ' + ', '.join([rule[0]] + locks)
                      + '. 사용 중 여부·Git 추적·내부 보존 자료를 정리 후보에서 재검증해야 합니다.', True)
    if p.suffix.lower() in ('.mp4', '.mov', '.wav', '.mp3', '.png', '.jpg', '.pdf'):
        return result('미디어·자료', '파일 형식을 확인했습니다. 원본이나 유일본 여부는 별도 확인이 필요합니다.')
    if p.name == '.git' or (p.is_dir() and (p / 'HEAD').is_file() and (p / 'objects').is_dir()):
        return result('Git 저장소', '원격에 없는 커밋·객체가 있을 수 있습니다. 동기화 확인 전 보존합니다.')
    return result('내용 확인 필요', '이름만으로 삭제 가능성을 판정하지 않았습니다. 하위 항목을 열어 확인하세요.')


def directory_contents(path):
    from concurrent.futures import ThreadPoolExecutor
    p=Path(path)
    if not p.is_absolute() or p.is_symlink() or not p.is_dir():raise ValueError('폴더 식별 실패')
    def measure(child):
        if child.is_symlink():return None
        value=allocated(child)
        display_path = str(child)
        if display_path.startswith('/System/Volumes/Data/Users/'):
            display_path = display_path.removeprefix('/System/Volumes/Data')
        return {'name':child.name,'path':display_path,'bytes':value,'complete':value is not None,'directory':child.is_dir(), **classify_storage(child)}
    with ThreadPoolExecutor(max_workers=3) as pool:
        entries=[x for x in pool.map(measure,list(p.iterdir())) if x]
    return {'path':str(p),'observedAt':time.time(),'entries':sorted(entries,key=lambda x:x['bytes'] or 0,reverse=True)}

def display_storage_path(path):
    # Data firmlinks refer to the same user paths; canonical keys avoid false new entries.
    prefix = '/System/Volumes/Data'
    return path[len(prefix):] if path.startswith(prefix + '/Users/') else path


def parse_disk_walk(output, errors, base):
    rows = {}
    for line in output.splitlines():
        try:
            size, name = line.split('\t', 1)
            if not name.startswith(str(base)) or int(size) < 0: continue
            rows[name] = int(size) * 1024
        except ValueError: continue
    issues = []
    for line in errors.splitlines():
        if line.startswith('du: '):
            name, _, reason = line[4:].rpartition(': ')
            if name.startswith(str(base)):
                issues.append({'path': name, 'reason': reason})
    return rows, issues


def measured_disk_walk(base, timeout=300):
    # One traversal, no cache allowlist. Keep partial output on timeout and never
    # follow symlinks or cross mounts. Spool output so large trees cannot fill RAM.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        try:
            proc = subprocess.run(['/usr/bin/du', '-x', '-k', '-d', '10', str(base)],
                                  stdout=output, stderr=errors, timeout=timeout)
            status = 'complete' if proc.returncode == 0 else 'partial'
        except subprocess.TimeoutExpired:
            status = 'timed_out'
        output.seek(0); errors.seek(0)
        rows, issues = parse_disk_walk(output.read().decode(errors='replace'),
                                      errors.read().decode(errors='replace'), base)
    return rows, issues, status


def disk_walk_evidence(rows, issues, status, base, previous=None, threshold=128*1024**2):
    previous = previous or {}
    old = {x['path']: x for x in previous.get('baselineObservations', previous.get('observations', [])) if x.get('complete')}
    issue_paths = [x['path'] for x in issues]
    def make(name, value):
        complete = status != 'timed_out' and not any(p == name or p.startswith(name + '/') for p in issue_paths)
        path = display_storage_path(name)
        before = old.get(path)
        return dict(name=Path(name).name, path=path, bytes=value, complete=complete,
                    directory=True, **classify_storage(name),
                    previousBytes=before['bytes'] if before else None,
                    previousAt=before.get('observedAt', previous.get('observedAt')) if before else None,
                    deltaBytes=value-before['bytes'] if before and complete and value is not None else None,
                    comparison='measured' if before and complete else 'no_baseline')
    # Include denied roots even when du could not emit a row for them.
    for issue in issues:
        rows.setdefault(issue['path'], None)
    directories = [make(p, n) for p, n in rows.items() if Path(p).parent == base]
    significant = {p for p, n in rows.items() if p != str(base) and n is not None and n >= threshold}
    children = {str(Path(p).parent) for p in significant}
    child_bytes = {}
    for p,n in rows.items():
        if n is not None:
            parent = str(Path(p).parent)
            child_bytes[parent] = child_bytes.get(parent, 0) + n
    classified = {}
    for p in sorted(significant, key=lambda x: len(Path(x).parts)):
        # Keep supported dependency roots intact; inspecting inside node_modules
        # must not turn bundled third-party packages into independent candidates.
        if any(p.startswith(parent + '/') for parent, item in classified.items() if item['cleanupReview']): continue
        item = make(p, rows[p])
        if p not in children or rows[p]-child_bytes.get(p, 0) >= threshold or item['cleanupReview'] or item['classification'] in (
                '설치된 Flutter SDK', 'Flutter SDK 재생성 캐시', '앱 복구용 복사본',
                '테스트·빌드 작업 자료') or Path(p).name.startswith('com_apple_MobileAsset_UAF_'):
            classified[p] = item
    for p, n in rows.items():
        if Path(p).name.startswith('com_apple_MobileAsset_UAF_') and 'manifests' not in Path(p).parts:
            classified[p] = make(p, n)
    assets = [x for p,x in classified.items() if Path(p).name.startswith('com_apple_MobileAsset_UAF_') and 'manifests' not in Path(p).parts]
    findings = sorted(classified.values(), key=lambda x: x['bytes'] or 0, reverse=True)[:150]
    findings += [x for x in assets if x not in findings]
    # Deltas also include parent paths so this diagnostic's own build growth is visible.
    observations = [dict(path=display_storage_path(p), bytes=n,
                         complete=status != 'timed_out' and not any(q == p or q.startswith(p + '/') for q in issue_paths))
                    for p, n in rows.items() if n is not None and n >= threshold]
    changes = []
    for row in observations:
        before = old.get(row['path'])
        if before and row['complete'] and abs(row['bytes']-before['bytes']) >= 16*1024**2:
            changes.append(dict(**row, previousBytes=before['bytes'], previousAt=before.get('observedAt', previous.get('observedAt')),
                                deltaBytes=row['bytes']-before['bytes']))
    return dict(directories=sorted(directories, key=lambda x: x['bytes'] or 0, reverse=True),
                findings=findings, observations=observations,
                changes=sorted(changes, key=lambda x: abs(x['deltaBytes']), reverse=True)[:80],
                accessIssues=[dict(path=display_storage_path(x['path']), reason=x['reason']) for x in issues],
                scannedAllocatedBytes=rows.get(str(base)), scanStatus=status)


def prior_disk_observations(root, previous):
    from datetime import datetime
    old = {x['path']: dict(x, observedAt=x.get('observedAt', previous.get('observedAt', 0)))
           for x in previous.get('baselineObservations', previous.get('observations', [])) if x.get('complete')}
    # The storage watcher already measures arbitrary paths. Reuse exact, complete
    # observations, never file birth time or an agent's inferred attribution.
    for file in sorted(root.parent.glob('storage-evidence-*.tsv'))[-2:]:
        try:
            with file.open() as source:
                for line in source:
                    fields = line.rstrip('\n').split('\t')
                    try:
                        if fields[0] != 'path' or fields[3] != 'ok': continue
                        at = datetime.fromisoformat(fields[1].replace('Z', '+00:00')).timestamp()
                        size = int(fields[2])*1024; path = display_storage_path(fields[5])
                        if size < 0 or at > time.time() or at < time.time()-30*86400: continue
                        if path not in old or at > old[path]['observedAt']:
                            old[path] = dict(path=path, bytes=size, complete=True, observedAt=at)
                    except (IndexError, ValueError): continue
        except OSError: continue
    return dict(previous, baselineObservations=list(old.values()))


def uaf_metadata(root):
    """Optional separately captured inventory; its logical sizes never enter totals."""
    audits = root.parent / 'storage-audits'
    for directory in sorted(audits.glob('*'), reverse=True)[:40]:
        file = directory / 'uaf-inventory.json'
        try:
            if file.is_symlink() or file.stat().st_size > 2_000_000: continue
            data = json.loads(file.read_text())
            values = data['bytes_by_asset_type']
            return dict(recordedAt=file.stat().st_mtime, source=str(file),
                        rows=[dict(name=k, logicalBytes=v) for k,v in values.items()
                              if isinstance(v, int) and v >= 0])
        except (OSError, ValueError, KeyError, TypeError): continue
    return None

def disk_balance(root, fresh=False):
    path=root/'disk-balance.json'
    previous = json.loads(path.read_text()) if path.exists() else {}
    if previous and not fresh:
        return previous
    previous = prior_disk_observations(root, previous)
    payload=run(['/usr/sbin/diskutil','apfs','list','-plist'])
    converted=subprocess.run(['/usr/bin/plutil','-convert','json','-o','-','-'],input=payload,capture_output=True,check=True)
    containers=json.loads(converted.stdout)['Containers']
    info=plist_json(run(['/usr/sbin/diskutil','info','-plist','/System/Volumes/Data']))
    container=next(c for c in containers if c['ContainerReference']==info['APFSContainerReference'])
    roles={'Data':'앱·사용자 자료','System':'macOS','Preboot':'부팅 지원','Recovery':'복구','VM':'VM·스왑'}
    volumes=[{'name':roles.get((v.get('Roles') or [''])[0],v.get('Name','기타')),'bytes':v['CapacityInUse']} for v in container['Volumes']]
    result={'schemaVersion':2,'observedAt':time.time(),'totalBytes':container['CapacityCeiling'],'freeBytes':container['CapacityFree'],'volumes':volumes,'warnings':[]}
    base=Path('/System/Volumes/Data')
    rows, issues, status = measured_disk_walk(base)
    save(root/'disk-walk-latest.json', dict(observedAt=result['observedAt'], rows=rows, issues=issues, status=status))
    result.update(disk_walk_evidence(rows, issues, status, base, previous))
    result['dataVolumeBytes'] = next((v['CapacityInUse'] for v in container['Volumes'] if v.get('DeviceIdentifier') == info.get('DeviceIdentifier')), None)
    allocated = result['scannedAllocatedBytes']
    result['accountingDifferenceBytes'] = result['dataVolumeBytes']-allocated if allocated is not None and result['dataVolumeBytes'] is not None else None
    result['uafMetadata'] = uaf_metadata(root)
    baselines = {x['path']: x for x in previous.get('baselineObservations', [])}
    for row in result['observations']:
        if row['complete']: baselines[row['path']] = dict(row, observedAt=result['observedAt'])
    result['baselineObservations'] = list(baselines.values())
    result['warnings'] = ['Data 볼륨 전체를 동일 파일시스템 안에서 순회했습니다. 128 MiB 이상 큰 경로 최대 150개와 시스템 AI 자산을 표시하며, 표시 깊이는 10단계입니다. 부모·자식 경로는 중복되므로 합산하지 않습니다.',
                          'APFS 사용량과 파일 할당량 차이는 접근 제한·스냅샷·공유 블록·동시 쓰기를 포함한 미설명 순차이입니다. 접근 불가 용량의 상한이나 정리 가능량이 아닙니다.',
                          '이전 동일 경로의 완전한 실측이 있을 때만 증감을 계산합니다. 첫 관측이나 생성 시각만으로 새로 설치됐거나 몰래 추가됐다고 판단하지 않습니다.']
    if status != 'complete': result['warnings'].append('접근 실패·시간 제한으로 전체 설명이 끝나지 않았습니다. 누락 경로와 미설명 차이를 확인하세요.')
    if previous: save(root/'disk-balance-previous.json', previous)
    result['finishedAt']=time.time();save(path,result);return result


def setup_options():
    runtimes=json.loads(run(['/usr/bin/xcrun','simctl','list','runtimes','--json']))['runtimes']
    return {'runtimes':[{'id':r['identifier'],'name':r['name'],'devices':[{'id':d['identifier'],'name':d['name'],'platform':platform({'deviceTypeIdentifier':d['identifier']})} for d in r.get('supportedDeviceTypes',[])]} for r in runtimes if r.get('isAvailable')]}

def setup(req,root):
    action=req['action']
    record={'action':action,'startedAt':time.time(),'before':capacity(),'mutation':'attempting','verification':'pending'}
    path=root/('setup-'+str(uuid.uuid4())+'.json');save(path,record)
    try:
        if action=='download-runtime':
            import re
            osname=req['platform'];version=req['version']
            if osname not in ('iOS','watchOS') or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}',version): raise ValueError('플랫폼과 OS 버전을 확인하세요.')
            record.update(platform=osname,version=version);save(path,record)
            run(['/usr/bin/xcodebuild','-downloadPlatform',osname,'-buildVersion',version,'-architectureVariant','arm64'],3300)
            record['mutation']='succeeded'
            fresh=json.loads(run(['/usr/bin/xcrun','simctl','list','runtimes','--json']))['runtimes']
            record['verification']='verified' if any(r.get('version')==version and r.get('isAvailable') for r in fresh) else 'pending'
        else:
            runtime=req['runtime'];kind=req['deviceType']
            options=setup_options()
            matched=next((r for r in options['runtimes'] if r['id']==runtime),None)
            dtype=next((d for d in matched['devices'] if d['id']==kind),None) if matched else None
            if not dtype:raise ValueError('이 OS에서 사용할 수 있는 기종인지 확인하지 못했습니다.')
            # Device names are presentation only; exact device type is authoritative.
            devices=json.loads(run(['/usr/bin/xcrun','simctl','list','devices','--json']))['devices'].get(runtime,[])
            existing=next((d for d in devices if d.get('deviceTypeIdentifier')==kind and d.get('isAvailable')),None)
            if existing:
                record['deviceID']=existing['udid'];record['mutation']='reused';record['verification']='verified'
            else:
                identifier=run(['/usr/bin/xcrun','simctl','create',dtype['name'],kind,runtime]).decode().strip()
                uuid.UUID(identifier);record['deviceID']=identifier;record['mutation']='succeeded';save(path,record)
                record['verification']='verified' if any(r['target']==identifier for r in simulator_inventory(False)) else 'pending'
        record['after']=capacity();save(path,record)
        return {'message':('기존 기기를 재사용합니다.' if record['mutation']=='reused' else '요청 처리 · 사후 확인 '+record['verification']),'receipt':str(path)}
    except Exception as exc:
        record['error']=str(exc);record['after']=capacity();save(path,record);raise

def dispatch(req,root=ROOT):
    action=req.get('action','preview')
    # Cancellation must not wait behind the executor lock.
    if action=='cancel':
        p=plan_path(root,req['id']); assert p.exists()
        (root/('cancel-'+req['id'])).touch();return {'message':'이후 항목 취소 요청'}
    with locked(root):
        if action=='setup-options': return setup_options()
        if action in ('download-runtime','ensure-device'): return setup(req,root)
        if action=='health': return {'capacity':capacity(),'memory':memory()}
        if action=='directory': return directory_contents(req['path'])
        if action=='balance': return disk_balance(root,req.get('fresh',False))
        if action=='preview': return preview(req,root)
        if action=='latest':
            paths=sorted(root.glob('plan-*.json'),key=lambda p:p.stat().st_mtime,reverse=True)
            if not paths: raise ValueError('이전 정리 기록이 없습니다.')
            return json.loads(paths[0].read_text())
        if action=='policy':
            pol=policy(root)
            for key in ('platforms','requirements','scheduleEnabled','intervalHours','minimumFreeGB','cacheIDs'):
                if key in req: pol[key]=req[key]
            if not set(pol['platforms']) <= {'iOS','iPadOS','watchOS','other'}: raise ValueError('지원하지 않는 플랫폼')
            pol['intervalHours']=max(1,min(168,float(pol['intervalHours'])))
            pol['minimumFreeGB']=max(1,min(200,float(pol['minimumFreeGB'])))
            save(root/'policy.json',pol);return {'message':'유지 요구·예약 정책 저장됨'}
        if action=='tick':
            pol=policy(root);now=time.time()
            if not pol.get('scheduleEnabled') or now<pol.get('nextRunAt',0): return {'message':'변경 없음'}
            pol['nextRunAt']=now+pol['intervalHours']*3600;save(root/'policy.json',pol)
            if capacity()['freeBytes']>=pol['minimumFreeGB']*1_000_000_000: return {'message':'목표 여유 공간 충족'}
            plan=preview({'projects':[]},root)
            selected=[i['id'] for i in plan['items'] if i['kind']=='cache' and i['id'] in pol.get('cacheIDs',[])]
            for i in plan['items']: i['approved']=i['id'] in selected
            save(plan_path(root,plan['id']),plan)
            result=execute(plan,root,selected)
            pol['lastPlan']=plan['id'];pol['lastFreeDelta']=result['after']['freeBytes']-result['before']['freeBytes']
            if pol['lastFreeDelta'] <= 0:
                pol['noEffectCount']=pol.get('noEffectCount',0)+1
                pol['nextRunAt']=now+min(168,max(pol['intervalHours'],24)*(2**min(pol['noEffectCount']-1,3)))*3600
                pol['lastStatus']='즉시 확보 효과 없음 · 재시도 간격을 늘렸습니다. 기록에서 지연 반환을 재측정할 수 있습니다.'
            else:
                pol['noEffectCount']=0;pol['lastStatus']='정리 후 실제 여유 공간이 늘었습니다.'
            save(root/'policy.json',pol)
            return {'message':'예약 정리 결과 기록됨','plan':plan['id']}
        p=plan_path(root,req['id']);plan=json.loads(p.read_text())
        if action=='focus-target':
            item=next(i for i in plan['items'] if i['id']==req['item'])
            current=observe_item(item,plan['projects'])
            if current is None or current['fingerprint']!=item['fingerprint']:raise ValueError('대상 상태 변경 · 다시 측정 후 확인하세요')
            pids=[]
            if item['kind']=='process':
                pid=int(item['target'])
                for _ in range(12):
                    if pid<=1 or pid in pids:break
                    pids.append(pid)
                    try:pid=int(run(['/bin/ps','-p',str(pid),'-o','ppid=']).strip())
                    except Exception:break
            return {'pids':pids}
        if action=='remeasure':
            for i in plan['items']:
                if i['mutation']=='succeeded':
                    try: i['verification']=verify(i,plan['projects'])
                    except Exception as exc:i['error']=str(exc)
            plan['after']=capacity();plan['memoryAfter']=memory();save(p,plan);return plan
        if action=='approve':
            ids=set(req['ids'])
            for i in plan['items']:
                if i['id'] in ids and not i['changed'] and not i['invariant']:i['approved']=True
            save(p,plan);return plan
        if action=='refresh':
            fresh=inventory({'projects':plan['projects']},root)
            lookup={x['id']:x for x in fresh['items']}
            for i,item in enumerate(plan['items']):
                if item['id'] in req['ids'] and item['id'] in lookup and item['mutation']!='succeeded':
                    replacement=lookup[item['id']]
                    replacement.update(approved=False,mutation='pending',verification='pending',error='',changed=False)
                    plan['items'][i]=replacement
            save(p,plan);return plan
        if action=='execute':
            (root/('cancel-'+plan['id'])).unlink(missing_ok=True);plan['cancelled']=False
            return execute(plan,root,set(req['ids']))
        if action=='status':return plan
        raise ValueError('지원하지 않는 작업')

if __name__=='__main__':
    p=argparse.ArgumentParser()
    mode=p.add_mutually_exclusive_group(required=True)
    mode.add_argument('--request-file');mode.add_argument('--inventory',action='store_true')
    p.add_argument('--project',action='append',default=[]);args=p.parse_args()
    try:
        if args.inventory:
            with locked(ROOT): result=inventory({'projects':args.project},ROOT,measure=False)
        else: result=dispatch(json.loads(Path(args.request_file).read_text()))
        print(json.dumps(result,ensure_ascii=False))
    except Exception as exc: print(json.dumps({'error':str(exc)},ensure_ascii=False));raise SystemExit(1)
