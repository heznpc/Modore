from pathlib import Path
import tempfile
from unittest.mock import patch
import app_registrations as a

def record(name,path,bundle='app.example'):
    return f'\nbundle id: {name} (0x12)\npath: {path} (0x23)\nname: {name}\nidentifier: {bundle}\nversion: 1.0 (data)\n'

def test_helpers_are_not_duplicate_installations():
    dump=record('App','/Applications/App.app')+record('App','/Applications/App.app/Contents/Frameworks/Helper.app','app.helper')
    assert len(a.parse_dump(dump))==1

def test_same_name_different_bundle_ids_remain_distinct():
    dump=record('App','/a/App.app','old.id')+record('App','/b/App.app','new.id')
    rows=a.rows(lambda *args:dump.encode())
    assert len(rows)==2
    assert {r['target'] for r in rows}=={'old.id','new.id'}
    assert all(r['state']=='파일 없는 등록' for r in rows)

def test_verification_still_sees_last_remaining_registration():
    dump=record('App','/a/App.app')
    assert a.rows(lambda *args:dump.encode())==[]
    assert len(a.rows(lambda *args:dump.encode(),include_single=True))==1

def test_reappearing_app_changes_approved_identity():
    with tempfile.TemporaryDirectory() as root:
        app=Path(root)/'App.app';dump=record('App',str(app))
        before=a.rows(lambda *args:dump.encode(),True)[0]
        (app/'Contents').mkdir(parents=True);(app/'Contents/Info.plist').write_text('identity')
        after=a.rows(lambda *args:dump.encode(),True)[0]
        assert before['id']==after['id']
        assert before['fingerprint']!=after['fingerprint']
        assert after['state']=='실제 앱 복사본'

def test_focus_rejects_changed_target_before_resolving_parent_apps():
    import environment_retirement as m
    import uuid
    with tempfile.TemporaryDirectory() as root:
        root=Path(root);item={'id':'process:123','kind':'process','target':'123','fingerprint':'old'}
        plan={'id':str(uuid.uuid4()),'items':[item],'projects':[]}
        m.save(m.plan_path(root,plan['id']),plan)
        with patch.object(m,'observe_item',return_value=dict(item,fingerprint='new')),patch.object(m,'run') as command:
            import pytest
            with pytest.raises(ValueError,match='대상 상태 변경'):m.dispatch({'action':'focus-target','id':plan['id'],'item':item['id']},root)
            command.assert_not_called()
