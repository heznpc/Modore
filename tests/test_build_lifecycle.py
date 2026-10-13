"""Behavioral retention checks using only disposable fixture directories."""
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

import build_lifecycle as lifecycle


@pytest.mark.skipif(sys.platform != 'darwin', reason='real macOS signature verification')
def test_real_signed_modore_hash_is_available(tmp_path):
    app = tmp_path/'Modore.app'
    binary = app/'Contents/MacOS/Modore'
    binary.parent.mkdir(parents=True)
    shutil.copyfile('/usr/bin/true', binary)
    binary.chmod(0o755)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'me.heznpc.modore', 'CFBundleExecutable': 'Modore',
        'CFBundlePackageType': 'APPL', 'CFBundleName': 'Modore',
    }))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    assert lifecycle.app_hash(app)
    assert lifecycle.app_hash('/usr/bin/true') is None


@pytest.fixture
def setup(tmp_path, monkeypatch):
    # macOS pytest temp roots can be aliases through /var.
    root = tmp_path.resolve()
    repository = root / 'repository'
    repository.mkdir()
    output = repository / 'build' / 'macos'
    output.mkdir(parents=True)
    monkeypatch.setattr(lifecycle, 'CACHE', root / 'shared-cache')
    monkeypatch.setattr(lifecycle, 'usage_snapshot', lambda: [])
    monkeypatch.setattr(lifecycle, 'process_identity', lambda pid: 'same-process')
    monkeypatch.setattr(lifecycle, 'app_hash', lambda path: 'signed-'+str(path) if Path(path).exists() else None)
    store = lifecycle.Store(root / 'records')
    with store.locked():
        yield store, repository, output


def scratch(setup, success=True, name='swift'):
    store, repository, output = setup
    run = store.begin(repository, output, os.getpid())
    path = output / name
    path.mkdir()
    (path / 'compiler-output').write_text('rebuildable')
    store.track(run['id'], 'scratch', path, generated=True)
    if success is not None:
        store.finish(run['id'], success, 'fixture verification')
    return run, path


def row_for(store, path, reclaim=False):
    return next(x for x in store.report(reclaim)['items'] if x['path'] == str(path))


def test_successful_unused_scratch_is_reclaimed_with_receipt(setup):
    store, _, _ = setup
    run, path = scratch(setup)
    assert row_for(store, path)['eligible']
    assert row_for(store, path, reclaim=True)['reason'] == '회수 완료'
    assert not path.exists()
    assert store.load(run['id'])['artifacts'][0]['removedAt']


def test_manual_reclaim_only_removes_reviewed_identifiers(setup):
    store, _, _ = setup
    first, path1 = scratch(setup, name='first')
    _, path2 = scratch(setup, name='second')
    identifier = store.load(first['id'])['artifacts'][0]['id']
    store.report(reclaim=True, artifact_ids=[identifier])
    assert not path1.exists() and path2.exists()


def test_install_link_belongs_only_to_matching_artifact_and_revalidates(setup, monkeypatch):
    store, repository, output = setup
    app = output/'Modore.app'; app.mkdir()
    backup = output/'.pch-app-backup.fixture'; backup.mkdir()
    (backup/'Modore.app').mkdir(); (backup/'.pch-build-identity').write_text('fixture')
    installed = repository/'Installed.app'; installed.mkdir()
    monkeypatch.setattr(lifecycle, 'app_hash', lambda path: 'new' if Path(path) in (app, installed) else 'old')
    run = store.begin(repository, output, os.getpid())
    store.track(run['id'], 'app', app); store.track(run['id'], 'recovery', backup)
    store.finish(run['id'], True, 'passed'); store.link(run['id'], installed)
    assert row_for(store, app)['installedPaths'] == [str(installed)]
    assert row_for(store, backup)['installedPaths'] == []
    monkeypatch.setattr(lifecycle, 'app_hash', lambda path: 'changed')
    row = row_for(store, app)
    assert row['installedPaths'] == []
    assert row['previousInstalledPaths'] == [str(installed)]


@pytest.mark.parametrize('status', [False, None])
def test_failed_and_interrupted_outputs_survive(setup, monkeypatch, status):
    store, _, _ = setup
    _, path = scratch(setup, success=status)
    monkeypatch.setattr(lifecycle, 'process_identity', lambda pid: None)
    assert not row_for(store, path, reclaim=True)['eligible']
    assert path.exists()


@pytest.mark.parametrize('protection', ['changed', 'opened', 'unknown-use', 'evidence', 'live'])
def test_protected_outputs_are_preserved_with_reason(setup, monkeypatch, protection):
    store, repository, output = setup
    run, path = scratch(setup)
    if protection == 'changed': (path / 'compiler-output').write_text('changed')
    elif protection == 'opened': monkeypatch.setattr(lifecycle, 'usage_snapshot', lambda: [str(path/'compiler-output')])
    elif protection == 'unknown-use': monkeypatch.setattr(lifecycle, 'usage_snapshot', lambda: None)
    elif protection == 'evidence':
        record = store.load(run['id'])
        record['artifacts'][0]['kind'] = 'evidence'
        store.save(record)
    elif protection == 'live': store.begin(repository, output, os.getpid())
    row = row_for(store, path, reclaim=True)
    assert not row['eligible'] and row['reason'] != '회수 완료'
    assert path.exists()


def test_use_or_content_change_at_final_check_is_preserved(setup, monkeypatch):
    store, _, _ = setup
    _, path = scratch(setup)
    calls = iter([[], [str(path/'compiler-output')]])
    monkeypatch.setattr(lifecycle, 'usage_snapshot', lambda: next(calls))
    assert '실행 직전' in row_for(store, path, reclaim=True)['reason']
    assert path.exists()


def test_test_slot_cannot_overwrite_failed_run(setup):
    store, repository, output = setup
    first = store.begin(repository, output, os.getpid())
    artifact = store.allocate_scratch(first['id'])
    store.finish(first['id'], False, 'failed')
    second = store.begin(repository, output, os.getpid())
    with pytest.raises(FileExistsError): store.allocate_scratch(second['id'])
    assert Path(artifact['path']).exists()


def test_explicit_retry_preserves_failed_content_and_receipt(setup):
    store, repository, output = setup
    first = store.begin(repository, output, os.getpid())
    artifact = store.allocate_scratch(first['id'])
    (Path(artifact['path'])/'failure.log').write_text('diagnostic evidence')
    store.finish(first['id'], False, 'failed')
    second = store.begin(repository, output, os.getpid())
    replacement = store.allocate_scratch(second['id'], retry_failed=True)
    old = Path(store.load(first['id'])['artifacts'][0]['path'])
    assert old != Path(replacement['path'])
    assert (old/'failure.log').read_text() == 'diagnostic evidence'
    assert '실패' in row_for(store, old, reclaim=True)['reason']


def test_newest_final_and_recovery_retained_old_copies_retired(setup):
    store, repository, output = setup
    copies = []
    for version in ('old', 'new'):
        directory = output.parent / version
        directory.mkdir()
        run = store.begin(repository, directory, os.getpid())
        app = directory / 'Modore.app'
        app.mkdir(); (app/'binary').write_text(version)
        container = directory / '.pch-app-backup.fixture'
        container.mkdir(); (container/'.pch-build-identity').write_text('fixture')
        (container/'Modore.app').mkdir()
        store.track(run['id'], 'app', app)
        store.track(run['id'], 'recovery', container)
        store.finish(run['id'], True, 'passed')
        copies.append((app, container))
    store.report(reclaim=True)
    assert all(not p.exists() for p in copies[0])
    assert all(p.exists() for p in copies[1])


def test_missing_creation_record_never_adopted_as_scratch(setup):
    store, repository, output = setup
    run = store.begin(repository, output, os.getpid())
    path = output / '.build'
    path.mkdir(); (path/'user-evidence').write_text('keep')
    with pytest.raises(ValueError): store.track(run['id'], 'scratch', path)
    assert '생성·검증 기록 없음' in row_for(store, path, reclaim=True)['reason']
    assert path.exists()


def test_shared_runtime_seed_and_duplicate_reclaim_require_matching_provenance(setup):
    store, repository, output = setup
    app = output/'Modore.app'
    origin = app/'Contents/Resources/modore-python/ORIGIN.txt'
    origin.parent.mkdir(parents=True)
    cache = output/'.python-runtime-cache'; cache.mkdir()
    archive = cache/'cpython-3.11.16+20260825-aarch64-apple-darwin-install_only_stripped.tar.gz'
    archive.write_bytes(b'fixture archive')
    origin.write_text('incorrect provenance')
    assert store.seed_runtime(repository) == []
    origin.write_text(lifecycle.file_hash(archive))
    assert store.seed_runtime(repository) == [str(lifecycle.CACHE/archive.name)]
    assert store.import_runtime_duplicates(repository)
    assert row_for(store, archive, reclaim=True)['reason'] == '회수 완료'
    assert (lifecycle.CACHE/archive.name).read_bytes() == b'fixture archive'


def test_symlink_and_out_of_scope_paths_are_rejected(setup, tmp_path):
    store, repository, output = setup
    run = store.begin(repository, output, os.getpid())
    outside = tmp_path.resolve()/'personal'; outside.mkdir()
    link = output/'alias'; link.symlink_to(outside)
    with pytest.raises(ValueError): store.track(run['id'], 'scratch', link, generated=True)


def test_test_result_bundle_is_preserved(setup):
    store, repository, output = setup
    run = store.begin(repository, output, os.getpid())
    artifact = store.allocate_scratch(run['id'])
    path = Path(artifact['path'])
    (path/'Test.xcresult').mkdir()
    store.finish(run['id'], True, 'passed')
    assert '증거' in row_for(store, path, reclaim=True)['reason']
    assert path.exists()
