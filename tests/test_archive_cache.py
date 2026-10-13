"""Archive byte equality is separate from usage and cleanup authorization."""
import io
import os
import plistlib
import tarfile

import pytest

import archive_cache as a


def archive_fixture(tmp_path, entries=None, local=None):
    target = tmp_path / '.expo/ios-simulator-app-cache/Expo-Go-57.0.9.tar.app'
    archive = tmp_path / '.expo/expo-go' / ('a' * 64 + '-body.bin')
    target.mkdir(parents=True)
    archive.parent.mkdir(parents=True)
    info = plistlib.dumps(dict(CFBundleIdentifier='host.exp.Exponent',
                              CFBundleExecutable='Expo Go', CFBundleVersion='57.0.9',
                              CFBundleShortVersionString='57.0.9'))
    entries = entries or [('asset.bin', b'asset'), ('Expo Go', b'abcdefghijk'), ('Info.plist', info)]
    with tarfile.open(archive, 'w:gz') as bundle:
        for name, data in entries:
            if isinstance(data, tarfile.TarInfo):
                bundle.addfile(data)
                continue
            member = tarfile.TarInfo(name)
            member.size = len(data)
            bundle.addfile(member, io.BytesIO(data))
    if local is None:
        local = {'asset.bin': b'asset', 'Expo Go': b'abcdef'}
    for name, data in local.items():
        path = target / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return target, archive, entries


def test_partial_executable_is_exact_archive_prefix_and_source_remains(tmp_path):
    target, archive, _ = archive_fixture(tmp_path)
    original = archive.read_bytes()
    result = a.inspect(target, archive, tmp_path)
    assert result['classification'] == 'incomplete-archive-extraction'
    assert result['partialFiles'] == ['Expo Go']
    assert result['matchedFiles'] == 2 and result['missingFiles'] == 1
    assert result['preservePaths'] == [str(archive)]
    assert result['usage'] == 'unverified' and result['deletionAuthorized'] is False
    assert result['regeneration'] == 'unverified'
    assert archive.read_bytes() == original and (target / 'Expo Go').read_bytes() == b'abcdef'


def test_complete_duplicate_and_stable_fingerprint(tmp_path):
    target, archive, entries = archive_fixture(tmp_path)
    for name, data in entries:
        (target / name).write_bytes(data)
    first = a.inspect(target, archive, tmp_path)
    assert first['classification'] == 'duplicate-archive-extraction'
    assert first['partialFiles'] == []
    assert first['fingerprint'] == a.inspect(target, archive, tmp_path)['fingerprint']
    os.utime(target / 'asset.bin', ns=(1_000_000_000, 1_000_000_000))
    assert first['fingerprint'] != a.inspect(target, archive, tmp_path)['fingerprint']


@pytest.mark.parametrize('name,data', [('unique.txt', b'only copy'), ('asset.bin', b'ASSET'),
                                       ('Expo Go', b'abcXef')])
def test_extra_or_changed_local_bytes_are_preserved(tmp_path, name, data):
    target, archive, _ = archive_fixture(tmp_path)
    (target / name).write_bytes(data)
    with pytest.raises(ValueError):
        a.inspect(target, archive, tmp_path)


@pytest.mark.parametrize('bad', ['../outside', '/absolute', './sub/../../outside', 'a//b', 'a\\b'])
def test_archive_traversal_is_rejected_even_after_local_files(tmp_path, bad):
    target, archive, entries = archive_fixture(tmp_path)
    with tarfile.open(archive, 'w') as bundle:
        for name, data in entries + [(bad, b'material')]:
            member = tarfile.TarInfo(name)
            member.size = len(data)
            bundle.addfile(member, io.BytesIO(data))
    with pytest.raises(ValueError, match='아카이브'):
        a.inspect(target, archive, tmp_path)
    assert not (tmp_path / 'outside').exists()


@pytest.mark.parametrize('kind', [tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE])
def test_archive_links_and_special_members_are_preserved(tmp_path, kind):
    target, archive, entries = archive_fixture(tmp_path)
    with tarfile.open(archive, 'w') as bundle:
        for name, data in entries:
            member = tarfile.TarInfo(name)
            member.size = len(data)
            bundle.addfile(member, io.BytesIO(data))
        member = tarfile.TarInfo('linked')
        member.type = kind
        member.linkname = 'asset.bin'
        bundle.addfile(member)
    with pytest.raises(ValueError, match='링크·특수'):
        a.inspect(target, archive, tmp_path)


@pytest.mark.parametrize('kind', ['symlink', 'hardlink', 'directory'])
def test_unknown_local_structure_is_preserved(tmp_path, kind):
    target, archive, _ = archive_fixture(tmp_path)
    if kind == 'symlink':
        (target / 'link').symlink_to(target / 'asset.bin')
    elif kind == 'hardlink':
        os.link(target / 'asset.bin', target / 'link')
    else:
        (target / 'unique-directory').mkdir()
    with pytest.raises(ValueError):
        a.inspect(target, archive, tmp_path)


def test_subset_gap_and_material_after_partial_file_are_preserved(tmp_path):
    target, archive, entries = archive_fixture(tmp_path)
    (target / 'asset.bin').unlink()
    with pytest.raises(ValueError, match='부분집합'):
        a.inspect(target, archive, tmp_path)
    (target / 'asset.bin').write_bytes(b'asset')
    (target / 'Info.plist').write_bytes(dict(entries)['Info.plist'])
    with pytest.raises(ValueError, match='부분 파일'):
        a.inspect(target, archive, tmp_path)


@pytest.mark.parametrize('changes', [{'asset.bin': b'ass'}, {'Expo Go': b''},
                                     {'asset.bin': b'ass', 'Expo Go': b'abc'}])
def test_prefix_rule_only_allows_one_nonempty_final_executable(tmp_path, changes):
    target, archive, _ = archive_fixture(tmp_path)
    for name, data in changes.items():
        (target / name).write_bytes(data)
    with pytest.raises(ValueError):
        a.inspect(target, archive, tmp_path)


def test_complete_initial_files_can_stop_between_members(tmp_path):
    target, archive, _ = archive_fixture(tmp_path, local={'asset.bin': b'asset'})
    result = a.inspect(target, archive, tmp_path)
    assert result['partialFiles'] == [] and result['missingFiles'] == 2
    assert result['classification'] == 'incomplete-archive-extraction'


def test_duplicate_archive_member_is_rejected(tmp_path):
    target, archive, entries = archive_fixture(tmp_path)
    with tarfile.open(archive, 'w') as bundle:
        for name, data in entries + [('asset.bin', b'asset')]:
            member = tarfile.TarInfo(name)
            member.size = len(data)
            bundle.addfile(member, io.BytesIO(data))
    with pytest.raises(ValueError, match='중복'):
        a.inspect(target, archive, tmp_path)


def test_mutation_during_proof_revokes_evidence(tmp_path, monkeypatch):
    target, archive, _ = archive_fixture(tmp_path)
    original = a.tree_snapshot
    calls = 0

    def changed(*args):
        nonlocal calls
        calls += 1
        if calls == 2:
            (target / 'unique.txt').write_bytes(b'new user data')
        return original(*args)

    monkeypatch.setattr(a, 'tree_snapshot', changed)
    with pytest.raises(ValueError, match='검증 중 대상'):
        a.inspect(target, archive, tmp_path)


def test_archive_replacement_changes_fingerprint(tmp_path):
    target, archive, entries = archive_fixture(tmp_path)
    first = a.inspect(target, archive, tmp_path)['fingerprint']
    with tarfile.open(archive, 'w') as bundle:
        for name, data in entries:
            member = tarfile.TarInfo(name)
            member.size = len(data)
            bundle.addfile(member, io.BytesIO(data))
    assert first != a.inspect(target, archive, tmp_path)['fingerprint']


def test_source_cannot_be_symlink(tmp_path):
    target, archive, _ = archive_fixture(tmp_path)
    retained = archive.with_name('original')
    archive.rename(retained)
    archive.symlink_to(retained)
    with pytest.raises(ValueError, match='심볼릭'):
        a.inspect(target, archive, tmp_path)


def test_source_mutation_during_proof_is_rejected(tmp_path, monkeypatch):
    target, archive, _ = archive_fixture(tmp_path)
    original = a.tree_snapshot
    calls = 0

    def changed(*args):
        nonlocal calls
        calls += 1
        if calls == 2:
            with archive.open('ab') as stream:
                stream.write(b'changed while inspecting')
        return original(*args)

    monkeypatch.setattr(a, 'tree_snapshot', changed)
    with pytest.raises(ValueError, match='보존 원본'):
        a.inspect(target, archive, tmp_path)


def test_resource_fork_is_preserved(tmp_path, monkeypatch):
    target, archive, _ = archive_fixture(tmp_path)
    monkeypatch.setattr(a.sys, 'platform', 'darwin')

    def attributed(*args, **kwargs):
        from types import SimpleNamespace
        return SimpleNamespace(returncode=0, stderr='',
                               stdout=f'{target}/asset.bin: com.apple.ResourceFork\n')

    monkeypatch.setattr(a.subprocess, 'run', attributed)
    with pytest.raises(ValueError, match='리소스 포크'):
        a.inspect(target, archive, tmp_path)


def test_truncated_archive_is_preserved(tmp_path):
    target, archive, _ = archive_fixture(tmp_path)
    archive.write_bytes(archive.read_bytes()[:100])
    with pytest.raises((ValueError, EOFError, tarfile.TarError)):
        a.inspect(target, archive, tmp_path)


def test_wrong_archive_bundle_identity_is_preserved(tmp_path):
    target, archive, entries = archive_fixture(tmp_path)
    with tarfile.open(archive, 'w') as bundle:
        for name, data in entries:
            if name == 'Info.plist':
                info = plistlib.loads(data)
                info['CFBundleIdentifier'] = 'unrelated.user.app'
                data = plistlib.dumps(info)
            member = tarfile.TarInfo(name)
            member.size = len(data)
            bundle.addfile(member, io.BytesIO(data))
    with pytest.raises(ValueError, match='Expo 앱 식별'):
        a.inspect(target, archive, tmp_path)
