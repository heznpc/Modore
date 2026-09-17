"""Read LaunchServices identities; unregister exact records without deleting apps."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

def parse_dump(text):
    records=[]
    for block in re.split(r'^bundle id:',text,flags=re.M)[1:]:
        def field(key):
            m=re.search(r'^'+re.escape(key)+r':\s*([^\n]*)',block,re.M)
            return m.group(1).strip() if m else ''
        path=re.sub(r' \(0x[0-9a-f]+\)$','',field('path'))
        if not path.startswith('/') or not path.endswith('.app'):continue
        if '/Contents/' in path:continue  # Embedded helpers are not duplicate installations.
        if not field('identifier'):continue
        records.append(dict(path=path,name=field('name') or Path(path).stem,bundle=field('identifier'),version=field('version').split(' (')[0]))
    return list({(r['path'],r['bundle']):r for r in records}.values())

def rows(run, include_single=False):
    records=parse_dump(run([LSREGISTER,'-dump'],45).decode(errors='replace'))
    counts={}
    for r in records:counts[r['name'].casefold()]=counts.get(r['name'].casefold(),0)+1
    result=[]
    for r in records:
        if not include_single and counts[r['name'].casefold()]<2:continue
        p=Path(r['path']);identity=[];blocked=''
        try:
            st=p.stat();identity=[st.st_dev,st.st_ino,st.st_mtime_ns]
            info=p/'Contents/Info.plist'
            identity.append(hashlib.sha256(info.read_bytes()).hexdigest())
            state='실제 앱 복사본'
        except FileNotFoundError:
            state='앱 식별 정보 없음' if p.exists() else '파일 없는 등록'
            if p.exists():blocked='앱 번들 식별 정보 확인 필요'
        except OSError:state='경로 확인 불가';blocked='앱 경로를 확인할 수 없습니다'
        if p.is_symlink():blocked='심볼릭 링크 대상 확인 필요'
        key=hashlib.sha256((r['path']+'\0'+r['bundle']).encode()).hexdigest()
        fingerprint=hashlib.sha256(json.dumps([r,identity],sort_keys=True).encode()).hexdigest()
        result.append(dict(id='registration:'+key,target=r['bundle'],kind='registration',name=r['name'],platform=r['bundle'],runtime=r['version'],state=state,path=r['path'],project=r['name'].casefold(),bytes=None,fingerprint=fingerprint,invariant=blocked,warnings=['LaunchServices 등록 해제 · 앱 파일과 사용자 자료는 유지됩니다.','메뉴 막대 설정은 별도 저장소입니다. 이 작업의 성공만으로 해당 항목이 제거됐다고 판단하지 않습니다.']))
    return result
