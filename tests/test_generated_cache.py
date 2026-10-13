"""Generated-cache contracts must reject lost evidence and changed sources."""
import base64
import hashlib
import json
import plistlib
import zipfile
from pathlib import Path

import pytest
import generated_cache as g


def put(path, data=b'x'):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())
    return path


def next_cache(home):
    p = home/'project/.next'
    put(p.parent/'package.json', '{"dependencies":{"next":"15.0.0"}}')
    put(p.parent/'package-lock.json', '{}')
    put(p/'build-manifest.json', '{}')
    put(p/'static/chunk.js')
    return p


def test_next_requires_lock_and_changes_invalidate_fingerprint(tmp_path):
    p = next_cache(tmp_path)
    before = g.inspect(p,tmp_path)
    assert before['kind'] == 'next' and before['scope'] == 'project'
    put(p/'static/chunk.js', b'changed payload')
    assert g.inspect(p,tmp_path)['fingerprint'] != before['fingerprint']
    (p.parent/'package-lock.json').unlink()
    with pytest.raises(ValueError, match='잠금'): g.inspect(p,tmp_path)


@pytest.mark.parametrize('name', ['proof.xcresult', 'nested/video.mov', 'attachments2/file', 'Logs/test.txt', '.env', 'run.jsonl'])
def test_evidence_inside_generated_tree_is_preserved(tmp_path,name):
    p=next_cache(tmp_path); put(p/name)
    with pytest.raises(ValueError): g.inspect(p,tmp_path)


def test_external_link_and_app_component_are_preserved(tmp_path):
    p=next_cache(tmp_path); source=put(tmp_path/'source.txt')
    (p/'linked').symlink_to(source)
    with pytest.raises(ValueError,match='외부 링크'): g.inspect(p,tmp_path)
    p=next_cache(tmp_path/'Tool.app')
    assert not g.review_candidate(p,tmp_path)
    with pytest.raises(ValueError,match='앱 내부'): g.inspect(p,tmp_path)


def venv(home):
    p=home/'python/.venv'; site=p/'lib/python3.11/site-packages'
    put(p/'pyvenv.cfg','home = /runtime/bin')
    put(p.parent/'requirements.txt','demo==1.0.0\n')
    target=put(site/'demo.py','print(1)')
    digest=base64.urlsafe_b64encode(hashlib.sha256(target.read_bytes()).digest()).rstrip(b'=').decode()
    metadata=put(site/'demo-1.0.0.dist-info/METADATA','Name: demo\nVersion: 1.0.0\n')
    md=base64.urlsafe_b64encode(hashlib.sha256(metadata.read_bytes()).digest()).rstrip(b'=').decode()
    put(site/'demo-1.0.0.dist-info/RECORD',f'demo.py,sha256={digest},8\ndemo-1.0.0.dist-info/METADATA,sha256={md},0\ndemo-1.0.0.dist-info/RECORD,,\n')
    return p,target


def test_venv_package_hash_and_unrecorded_files_are_checked(tmp_path):
    p,target=venv(tmp_path)
    assert g.inspect(p,tmp_path)['kind']=='venv'
    put(p/'bin/custom-script','personal source')
    with pytest.raises(ValueError,match='설치 목록 밖'): g.inspect(p,tmp_path)
    (p/'bin/custom-script').unlink()
    target.write_text('modified')
    with pytest.raises(ValueError,match='수정된'): g.inspect(p,tmp_path)


def test_editable_venv_is_preserved(tmp_path):
    p,_=venv(tmp_path); put(p.parent/'requirements.txt','-e ../local\n')
    with pytest.raises(ValueError,match='편집 가능'): g.inspect(p,tmp_path)


def test_intact_but_unlocked_installed_package_is_preserved(tmp_path):
    p,_=venv(tmp_path)
    put(p.parent/'requirements.txt','different-package==2.0.0\n')
    with pytest.raises(ValueError,match='설치 패키지 이름·버전'):g.inspect(p,tmp_path)


@pytest.mark.parametrize('name',['notes.txt','research.db','notes.md'])
def test_private_material_in_generated_output_is_preserved(tmp_path,name):
    p=next_cache(tmp_path);put(p/name,'unique material')
    with pytest.raises(ValueError,match='메모·문서'):g.inspect(p,tmp_path)
    root=xcode(tmp_path);put(root/'Build'/name,'unique material')
    with pytest.raises(ValueError,match='메모·문서'):g.inspect(root/'Build',tmp_path)


def xcode(home):
    project=home/'source/App.xcodeproj'; put(project/'project.pbxproj')
    root=home/'Library/Developer/XcodeBuildMCP/workspaces/App-test/DerivedData/App-test'
    put(root/'info.plist',plistlib.dumps({'WorkspacePath':str(project)}))
    put(root/'Build/Products/app')
    put(root/'Logs/result.xcresult/data')
    return root


def test_xcode_only_selects_generated_child_and_preserves_sibling_evidence(tmp_path):
    root=xcode(tmp_path)
    assert g.inspect(root/'Build',tmp_path)['kind']=='xcode'
    assert not g.review_candidate(root,tmp_path)
    with pytest.raises(ValueError): g.inspect(root,tmp_path)
    put(root/'Build/result.xcresult/data')
    with pytest.raises(ValueError,match='증거'): g.inspect(root/'Build',tmp_path)


def test_xcode_missing_source_and_test_products_without_manifest_are_blocked(tmp_path):
    root=xcode(tmp_path); (tmp_path/'source/App.xcodeproj/project.pbxproj').unlink()
    with pytest.raises(OSError): g.inspect(root/'Build',tmp_path)
    put(tmp_path/'source/App.xcodeproj/project.pbxproj')
    p=root.parent.parent/'test-products'; p.mkdir()
    with pytest.raises(ValueError,match='xctestrun'): g.inspect(p,tmp_path)
    put(p/'App.xctestrun',plistlib.dumps({'TestConfigurations':[]}))
    assert g.inspect(p,tmp_path)['kind']=='xcode-tests'


def test_node_headers_require_version_signature(tmp_path):
    p=tmp_path/'Library/Caches/node-gyp'
    put(p/'22.1.0/installVersion',b'11')
    put(p/'22.1.0/include/node/node_version.h',b'#define NODE_MAJOR_VERSION 22\n')
    put(p/'22.1.0/include/node/node.h')
    assert g.inspect(p,tmp_path)['kind']=='node-gyp'
    put(p/'22.1.0/include/node/node_version.h',b'#define NODE_MAJOR_VERSION 20\n')
    with pytest.raises(ValueError,match='버전'): g.inspect(p,tmp_path)


def test_electron_archive_identity_and_unknown_material(tmp_path):
    p=tmp_path/'Library/Caches/electron';p.mkdir(parents=True)
    with zipfile.ZipFile(p/'electron-v40.0.0-darwin-arm64.zip','w') as z:
        z.writestr('Electron.app/Contents/Info.plist',plistlib.dumps({'CFBundleIdentifier':'com.github.Electron'}))
    assert g.inspect(p,tmp_path)['kind']=='electron'
    put(p/'notes.txt')
    with pytest.raises(ValueError,match='다운로드 외'): g.inspect(p,tmp_path)


def test_obsolete_extension_needs_registered_newer_replacement(tmp_path):
    root=tmp_path/'.vscode/extensions';p=root/'vendor.demo-1.0.0'
    put(p/'package.json',json.dumps(dict(name='demo',publisher='vendor',version='1.0.0')))
    put(root/'.obsolete',json.dumps({p.name:True}))
    put(root/'extensions.json',json.dumps([{'relativeLocation':'vendor.demo-2.0.0'}]))
    put(root/'vendor.demo-2.0.0/package.json',json.dumps(dict(name='demo',publisher='vendor',version='2.0.0')))
    assert g.inspect(p,tmp_path)['kind']=='vscode-obsolete'
    put(root/'extensions.json',json.dumps([{'relativeLocation':p.name}]))
    with pytest.raises(ValueError,match='현재 등록'): g.inspect(p,tmp_path)


def test_flutter_engine_requires_original_sdk_and_exact_subtree(tmp_path):
    sdk=tmp_path/'flutter';p=sdk/'bin/cache/artifacts/engine'
    put(sdk/'bin/flutter');put(sdk/'bin/internal/engine.version','a'*40)
    put(sdk/'packages/flutter_tools/pubspec.yaml','name: flutter_tools')
    put(sdk/'packages/flutter_tools/lib/src/cache.dart','class EngineCache { /* engine */ }')
    put(p/'darwin-arm64/Flutter.framework/binary')
    assert g.inspect(p,tmp_path)['kind']=='flutter-engine'
    with pytest.raises(ValueError): g.inspect(sdk,tmp_path)
    put(p/'personal.txt')
    with pytest.raises(ValueError,match='엔진 외'): g.inspect(p,tmp_path)


def test_dart_bytestore_checksum_and_interrupted_data(tmp_path):
    sdk=tmp_path/'flutter/bin/cache/dart-sdk'
    put(sdk/'bin/dart');put(sdk/'bin/snapshots/analysis_server.dart.snapshot');put(sdk/'version','3.10.0')
    p=tmp_path/'.dartServer/.analysis-driver';data=b'cached analysis'
    a=sum(data)%255;b=sum((len(data)-i)*x for i,x in enumerate(data))%255
    entry=put(p/('a'*32+'.unlinked'),data+b'\x01\x00'+bytes((a,b)))
    assert g.inspect(p,tmp_path)['kind']=='dart-analysis'
    entry.write_bytes(entry.read_bytes()[:-1]+b'\xff')
    with pytest.raises(ValueError,match='체크섬'): g.inspect(p,tmp_path)


def test_vsix_requires_signed_installed_app_and_archive_manifest(tmp_path,monkeypatch):
    info=put(tmp_path/'Applications/Code.app/Contents/Info.plist')
    monkeypatch.setattr(g,'signed_app',lambda *_:info)
    p=tmp_path/'Library/Application Support/Code/CachedExtensionVSIXs';p.mkdir(parents=True)
    archive=p/'vendor.demo-1.0.0'
    with zipfile.ZipFile(archive,'w') as z:
        z.writestr('extension/package.json',json.dumps(dict(name='demo',publisher='vendor',version='1.0.0')))
        z.writestr('extension.vsixmanifest','<PackageManifest/>')
    assert g.inspect(p,tmp_path)['kind']=='vscode-download'
    put(p/'unknown.txt')
    with pytest.raises(zipfile.BadZipFile):g.inspect(p,tmp_path)


def test_google_crx_requires_updater_identity_and_payload_header(tmp_path,monkeypatch):
    import types
    p=tmp_path/'Library/Application Support/Google/GoogleUpdater/crx_cache'
    info=put(p.parent/'1.0/GoogleUpdater.app/Contents/Info.plist',plistlib.dumps({'CFBundleIdentifier':'com.google.GoogleUpdater'}))
    monkeypatch.setattr(g.subprocess,'run',lambda *a,**k:types.SimpleNamespace(returncode=0))
    put(p/'download',b'Cr24\x03\x00\x00\x00\x04\x00\x00\x00signPK\x03\x04body')
    assert g.inspect(p,tmp_path)['kind']=='google-crx'
    info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'another.app'}))
    with pytest.raises(ValueError,match='식별'):g.inspect(p,tmp_path)


def test_discovery_does_not_offer_current_extension_or_full_derived_data(tmp_path):
    root=xcode(tmp_path)
    assert not g.review_candidate(root,tmp_path)
    assert g.review_candidate(root/'Build',tmp_path)
    p=tmp_path/'.vscode/extensions/vendor.demo';p.mkdir(parents=True)
    put(p.parent/'.obsolete','{}')
    assert not g.review_candidate(p,tmp_path)


def test_signed_app_requests_identifier_in_verbose_codesign_output(tmp_path,monkeypatch):
    import types
    app=tmp_path/'Applications/Visual Studio Code.app';app.mkdir(parents=True)
    def codesign(args,**_):
        # codesign -d alone only emits Executable= on macOS.
        output='Identifier=com.microsoft.VSCode' if '--verbose=4' in args else 'Executable=Code'
        return types.SimpleNamespace(returncode=0,stderr=output)
    monkeypatch.setattr(g.subprocess,'run',codesign)
    assert g.signed_app(tmp_path,'Visual Studio Code.app','com.microsoft.VSCode')==app/'Contents/Info.plist'
