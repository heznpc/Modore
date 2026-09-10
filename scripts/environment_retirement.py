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
    for item in sorted(plan['items'], key=lambda i: {'process':0,'vm':1,'device':2,'cache':3,'runtime':4,'volume':5}[i['kind']]):
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


def disk_balance(root, fresh=False):
    path=root/'disk-balance.json'
    if path.exists() and not fresh:
        return json.loads(path.read_text())
    payload=run(['/usr/sbin/diskutil','apfs','list','-plist'])
    converted=subprocess.run(['/usr/bin/plutil','-convert','json','-o','-','-'],input=payload,capture_output=True,check=True)
    containers=json.loads(converted.stdout)['Containers']
    info=plist_json(run(['/usr/sbin/diskutil','info','-plist','/System/Volumes/Data']))
    container=next(c for c in containers if c['ContainerReference']==info['APFSContainerReference'])
    roles={'Data':'앱·사용자 자료','System':'macOS','Preboot':'부팅 지원','Recovery':'복구','VM':'VM·스왑'}
    volumes=[{'name':roles.get((v.get('Roles') or [''])[0],v.get('Name','기타')),'bytes':v['CapacityInUse']} for v in container['Volumes']]
    result={'observedAt':time.time(),'totalBytes':container['CapacityCeiling'],'freeBytes':container['CapacityFree'],'volumes':volumes,'directories':[],'warnings':[]}
    save(path,result)
    # Disjoint first-level Data directories. Bound traversal, preserve unknowns.
    base=Path('/System/Volumes/Data')
    names=[p for p in base.iterdir() if p.is_dir() and not p.is_symlink() and p.stat().st_dev==base.stat().st_dev]
    import concurrent.futures
    def measure(p):
        try:
            measured=subprocess.run(['/usr/bin/du','-skx',str(p)],capture_output=True,timeout=300 if p.name=='Users' else 25)
            value=int(measured.stdout.split()[0])*1024 if measured.stdout.strip() else None
            return {'name':p.name,'path':str(p),'bytes':value,'complete':measured.returncode==0}
        except Exception:
            return {'name':p.name,'path':str(p),'bytes':None,'complete':False}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        result['directories']=list(pool.map(measure,names))
    result['directories'].sort(key=lambda x:x['bytes'] or 0,reverse=True)
    if any(not x['complete'] for x in result['directories']): result['warnings'].append('접근 제한이 있는 폴더는 확인된 최소량, 시간 초과는 미측정으로 표시합니다. 0으로 합산하지 않습니다.')
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
