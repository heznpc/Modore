"""Destructive flows run only in a temporary home, never the user's skills."""
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

if sys.platform == 'win32':
    raise unittest.SkipTest('The macOS skill inventory requires POSIX filesystem APIs')

SPEC = importlib.util.spec_from_file_location('skill_inventory', Path(__file__).parents[1] / 'scripts/skill_inventory.py')
m = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(m)


def fixture_rename(source, target):
    """Exercise the state machine on POSIX CI; native atomicity is tested on macOS."""
    if os.path.lexists(target): raise FileExistsError(str(target))
    os.rename(source, target)


class SkillInventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name).resolve()
        self.manager = m.Skills(self.home)
        if sys.platform != 'darwin':
            rename = patch.object(m, 'rename_exclusive', side_effect=fixture_rename)
            rename.start(); self.addCleanup(rename.stop)

    def tearDown(self): self.tmp.cleanup()

    def skill(self, path='.codex/skills/example', body='Alpha', version='1'):
        p = self.home / path; p.mkdir(parents=True)
        (p / 'SKILL.md').write_text('---\nname: example\nversion: ' + version + '\n---\n' + body)
        (p / 'support.txt').write_text('support file')
        return p

    def request(self, path):
        row = next(x for x in self.manager.inventory() if x['path'] == str(path))
        return {'id': row['id'], 'fingerprint': row['fingerprint']}

    def disable(self, p):
        return self.manager.disable(self.request(p))['backups'][0]

    def test_copy_restore_including_support_and_settings(self):
        p = self.skill(); config = self.home / '.codex/config.toml'
        config.write_text('[features]\nhooks=false\n')
        backup = self.disable(p)
        self.assertFalse(p.exists()); self.assertEqual(backup['state'], 'disabled')
        dest = Path(backup['backupPath'])
        self.assertEqual((dest / 'content/support.txt').read_text(), 'support file')
        self.assertEqual((dest / 'settings/0-config.toml').read_text(), config.read_text())
        self.manager.restore({'id': backup['id']})
        self.assertEqual((p / 'support.txt').read_text(), 'support file')
        self.assertEqual(config.read_text(), '[features]\nhooks=false\n')
        self.assertEqual(self.manager.status()['backups'][0]['state'], 'restored')

    def test_relative_symlink_target_not_touched_and_link_restored(self):
        target = self.skill('external/example')
        p = self.home / '.agents/skills/example'; p.parent.mkdir(parents=True)
        relative = os.path.relpath(target, p.parent); p.symlink_to(relative)
        original = (target / 'SKILL.md').read_bytes()
        backup = self.disable(p)
        self.assertFalse(os.path.lexists(p)); self.assertEqual((target / 'SKILL.md').read_bytes(), original)
        self.manager.restore({'id': backup['id']})
        self.assertEqual(os.readlink(p), relative)

    def test_restore_conflict_even_dangling_symlink(self):
        p = self.skill(); backup = self.disable(p)
        p.symlink_to('/missing-test-target')
        with self.assertRaisesRegex(ValueError, '충돌'): self.manager.restore({'id': backup['id']})
        self.assertEqual(os.readlink(p), '/missing-test-target')
        self.assertIn('충돌', self.manager.status()['backups'][0]['error'])
        p.unlink(); self.manager.restore({'id': backup['id']})
        self.assertTrue(p.is_dir())

    def test_stale_selection_rejected(self):
        p = self.skill(); req = self.request(p)
        (p / 'support.txt').write_text('changed')
        with self.assertRaisesRegex(ValueError, '바뀌'): self.manager.disable(req)
        self.assertTrue(p.exists())

    def test_changed_link_target_refuses_restore(self):
        target = self.skill('outside/example'); p = self.home / '.codex/skills/example'
        p.parent.mkdir(parents=True); p.symlink_to(target)
        backup = self.disable(p); (target / 'SKILL.md').write_text('new content')
        with self.assertRaisesRegex(ValueError, '변경'): self.manager.restore({'id': backup['id']})
        self.assertFalse(os.path.lexists(p)); self.assertEqual((target / 'SKILL.md').read_text(), 'new content')
        self.assertTrue((Path(backup['backupPath']) / 'content/SKILL.md').is_file())

    def test_tampered_backup_refuses_restore(self):
        p = self.skill(); backup = self.disable(p)
        (Path(backup['backupPath']) / 'content/SKILL.md').write_text('tampered')
        with self.assertRaisesRegex(ValueError, '무결성'): self.manager.restore({'id': backup['id']})
        self.assertFalse(p.exists())

    def test_move_failure_is_recorded_and_original_preserved(self):
        p = self.skill()
        with patch.object(m, 'rename_exclusive', side_effect=OSError('cross-device')):
            with self.assertRaisesRegex(ValueError, 'cross-device'): self.disable(p)
        self.assertTrue(p.exists()); self.assertEqual(self.manager.status()['backups'][0]['state'], 'failed')

    def test_nested_link_fails_before_mutation(self):
        p = self.skill(); (p / 'link').symlink_to('support.txt')
        with self.assertRaisesRegex(ValueError, '내부 심볼릭'): self.disable(p)
        self.assertTrue(p.exists())

    def test_backup_ancestor_symlink_refused(self):
        p = self.skill(); other = self.home / 'other'; other.mkdir()
        (self.home / 'Library').symlink_to(other)
        with self.assertRaisesRegex(ValueError, '링크'): self.disable(p)
        self.assertTrue(p.exists())

    def test_duplicates_diff_and_versions_are_independent(self):
        a = self.skill(); b = self.skill('.claude/skills/example', 'Beta', '1')
        rows = self.manager.inventory()
        self.assertEqual([r['duplicates'] for r in rows], [2, 2])
        self.assertEqual([r['variants'] for r in rows], [2, 2])
        result = self.manager.compare({'ids': [self.request(a)['id'], self.request(b)['id']]})
        self.assertIn('-Alpha', result['diff']); self.assertIn('+Beta', result['diff'])

    def test_old_plugin_cache_never_claims_active(self):
        for v in ('1', '2'): self.skill('.claude/plugins/cache/market/plugin/' + v + '/skills/example', version=v)
        plugins = self.home / '.claude/plugins'
        (plugins / 'installed_plugins.json').write_text(json.dumps({'plugins': {'plugin@market': [
            {'installPath': str(plugins / 'cache/market/plugin/2')}]}}))
        (self.home / '.claude/settings.json').write_text(json.dumps({'enabledPlugins': {'plugin@market': True}}))
        rows = self.manager.inventory()
        self.assertIn('미선택 캐시', rows[0]['discovery'])
        self.assertIn('실제 발견 미확인', rows[1]['discovery'])

    def test_broken_link_visible(self):
        p = self.home / '.codex/skills/broken'; p.parent.mkdir(parents=True); p.symlink_to('/missing-skill')
        row = self.manager.inventory()[0]
        self.assertFalse(row['exists']); self.assertTrue(row['error'])

    def test_cli_reference_exposes_drift_without_being_mutable(self):
        target = self.skill('old/skills/modore-ops', 'old text')
        reference = self.skill('repo/skills/modore-ops', 'new text')
        executable = self.home / 'repo/bin/modore'; executable.parent.mkdir(); executable.write_text('launcher')
        cli = self.home / '.local/bin/modore'; cli.parent.mkdir(parents=True); cli.symlink_to(executable)
        installed = self.home / '.codex/skills/modore-ops'; installed.parent.mkdir(parents=True); installed.symlink_to(target)
        rows = self.manager.inventory()
        self.assertEqual(len(rows), 2); self.assertEqual(rows[0]['variants'], 2)
        row = next(r for r in rows if r['host'] == '참고')
        self.assertFalse(row['manageable'])
        with self.assertRaisesRegex(ValueError, '참고'): self.manager.disable({'id': row['id'], 'fingerprint': row['fingerprint']})
        self.assertTrue(reference.exists())

    def test_cycle_and_corrupt_backup_are_visible(self):
        p = self.home / '.codex/skills/cycle'; p.parent.mkdir(parents=True); p.symlink_to('cycle')
        self.assertTrue(self.manager.inventory()[0]['error'])
        broken = self.manager.bank / 'broken'; broken.mkdir(parents=True)
        (broken / 'manifest.json').write_text('{bad')
        self.assertTrue(self.manager.status()['warnings'])

    def test_bundle_includes_service_runtime(self):
        script = (Path(__file__).parents[1] / 'scripts/build_macos_swift_app.sh').read_text()
        self.assertNotIn('"scripts/skill_inventory.py"', script)
        service = (Path(__file__).parents[1] / 'macos/Modore/Sources/Modore/Services/SkillInventoryService.swift').read_text()
        self.assertIn('NativeOperationService.capture("skills"', service)

    def test_restore_rejects_manifest_path_outside_skill_roots(self):
        p = self.skill(); backup = self.disable(p)
        manifest = Path(backup['backupPath']) / 'manifest.json'
        record = json.loads(manifest.read_text()); record['original'] = str(self.home / 'unrelated')
        record['parentReal'] = str(self.home); manifest.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, '탐색 경로 밖'): self.manager.restore({'id': backup['id']})
        self.assertFalse((self.home / 'unrelated').exists())

    def test_recreated_skill_is_not_silently_reported_disabled(self):
        p = self.skill(); self.disable(p); p.mkdir(); (p / 'SKILL.md').write_text('reinstalled')
        status = self.manager.status()
        self.assertIn('원래 경로에 파일', status['backups'][0]['error'])
        self.assertEqual(len(status['items']), 1)

    @unittest.skipUnless(sys.platform == 'darwin', 'Native macOS no-replace rename')
    def test_no_replace_rename(self):
        a = self.home / 'a'; b = self.home / 'b'; a.write_text('A'); b.write_text('B')
        with self.assertRaises(OSError): m.rename_exclusive(a, b)
        self.assertEqual(b.read_text(), 'B'); self.assertEqual(a.read_text(), 'A')

    def test_malformed_settings_do_not_hide_installed_skills(self):
        self.skill()
        plugin = self.skill('.claude/plugins/cache/market/plugin/1/skills/example')
        for value in ([], None, {'plugins': []}, {'plugins': {'plugin@market': [None]}}):
            with self.subTest(value=value):
                (self.home / '.claude/plugins/installed_plugins.json').write_text(json.dumps(value))
                (self.home / '.claude/settings.json').write_text('[false]')
                result = self.manager.status()
                self.assertEqual(len(result['items']), 2)
                self.assertTrue(result['warnings'])
                self.assertTrue(any(x['path'] == str(plugin) for x in result['items']))
                row = next(x for x in result['items'] if x['path'] == str(plugin))
                self.assertIn('설치 기록 오류', row['discovery'])

    def test_invalid_toml_never_claims_enabled_plugin(self):
        self.skill('.codex/plugins/cache/market/plugin/1/skills/example')
        (self.home / '.codex/config.toml').write_text('[plugins."plugin@market"]\nenabled=true\nbroken=[')
        result = self.manager.status()
        self.assertNotIn('플러그인 활성 설정', result['items'][0]['discovery'])
        self.assertTrue(result['warnings'])

    def test_corrupt_backup_types_are_isolated_from_valid_backups(self):
        first = self.disable(self.skill())
        second = self.disable(self.skill('.claude/skills/example'))
        manifest = Path(second['backupPath']) / 'manifest.json'
        original = json.loads(manifest.read_text())
        for field, value in [('created', 'yesterday'), ('created', float('nan')), ('state', []), ('original', 5), ('error', {})]:
            with self.subTest(field=field, value=value):
                changed = dict(original); changed[field] = value
                manifest.write_text(json.dumps(changed))
                result = self.manager.status()
                self.assertEqual([x['id'] for x in result['backups']], [first['id']])
                self.assertTrue(result['warnings'])
                with self.assertRaises(ValueError): self.manager.restore({'id': second['id']})

    def test_linked_manifest_is_never_read_or_rewritten_by_restore(self):
        backup = self.disable(self.skill()); manifest = Path(backup['backupPath']) / 'manifest.json'
        external = self.home / 'external.json'; external.write_bytes(manifest.read_bytes())
        before = external.read_bytes(); manifest.unlink(); manifest.symlink_to(external)
        with self.assertRaises(OSError): self.manager.restore({'id': backup['id']})
        self.assertEqual(external.read_bytes(), before)
        self.assertTrue(self.manager.status()['warnings'])

    def test_fifo_and_oversized_skill_metadata_are_visible_errors(self):
        p = self.skill(); md = p / 'SKILL.md'; md.unlink(); os.mkfifo(md)
        self.assertIn('일반 파일', self.manager.inventory()[0]['error'])
        md.unlink(); md.write_bytes(b'x' * (m.MAX_METADATA_BYTES + 1))
        self.assertIn('크기 제한', self.manager.inventory()[0]['error'])

    def test_copy_limit_applies_if_source_grows_after_selection(self):
        p = self.skill(); request = self.request(p); copy = m.copy_skill
        def grow_then_copy(source, target):
            (source / 'support.txt').write_bytes(b'x' * 256)
            with patch.object(m, 'MAX_BYTES', 128): copy(source, target)
        with patch.object(m, 'copy_skill', side_effect=grow_then_copy):
            with self.assertRaisesRegex(ValueError, '크기 제한'): self.manager.disable(request)
        self.assertTrue(p.is_dir())
        self.assertEqual(self.manager.status()['backups'][0]['state'], 'failed')

    def test_copy_refuses_link_added_after_initial_check(self):
        p = self.skill(); request = self.request(p); copy = m.copy_skill
        external = self.home / 'external.txt'; external.write_text('must not be copied')
        def introduce_link(source, target):
            (source / 'late-link').symlink_to(external)
            return copy(source, target)
        with patch.object(m, 'copy_skill', side_effect=introduce_link):
            with self.assertRaisesRegex(ValueError, '내부 심볼릭'): self.manager.disable(request)
        self.assertTrue(p.is_dir()); self.assertEqual(external.read_text(), 'must not be copied')
        backup = self.manager.status()['backups'][0]
        self.assertFalse((Path(backup['backupPath']) / 'content/late-link').exists())

    def test_source_replaced_at_move_is_put_back(self):
        p = self.skill(); rename = m.rename_exclusive
        def replace_then_move(source, target):
            if source == p: (source / 'support.txt').write_text('changed immediately before move')
            return rename(source, target)
        with patch.object(m, 'rename_exclusive', side_effect=replace_then_move):
            with self.assertRaisesRegex(ValueError, '되돌렸습니다'): self.disable(p)
        self.assertEqual((p / 'support.txt').read_text(), 'changed immediately before move')
        self.assertEqual(self.manager.status()['backups'][0]['state'], 'failed')

    def test_changed_backup_at_restore_move_is_put_back(self):
        p = self.skill(); backup = self.disable(p); original = Path(backup['backupPath']) / 'original'
        rename = m.rename_exclusive
        def replace_then_move(source, target):
            if source == original: (source / 'support.txt').write_text('late backup change')
            return rename(source, target)
        with patch.object(m, 'rename_exclusive', side_effect=replace_then_move):
            with self.assertRaisesRegex(ValueError, '되돌렸습니다'): self.manager.restore({'id': backup['id']})
        self.assertFalse(p.exists()); self.assertEqual((original / 'support.txt').read_text(), 'late backup change')

    def test_disable_manifest_failure_keeps_recoverable_original(self):
        p = self.skill(); write = m.atomic_json
        def fail_final_write(path, value):
            if value.get('state') == 'disabled': raise OSError('disk write failure')
            return write(path, value)
        with patch.object(m, 'atomic_json', side_effect=fail_final_write):
            with self.assertRaisesRegex(ValueError, 'disk write failure'): self.disable(p)
        backup = self.manager.status()['backups'][0]
        self.assertEqual(backup['state'], 'needsAttention'); self.assertFalse(p.exists())
        self.manager.restore({'id': backup['id']})
        self.assertTrue((p / 'SKILL.md').is_file())

    def test_restore_manifest_failure_is_recognized_and_retryable(self):
        p = self.skill(); backup = self.disable(p); write = m.atomic_json
        def fail_final_write(path, value):
            if value.get('state') == 'restored': raise OSError('disk write failure')
            return write(path, value)
        with patch.object(m, 'atomic_json', side_effect=fail_final_write):
            with self.assertRaisesRegex(OSError, 'disk write failure'): self.manager.restore({'id': backup['id']})
        self.assertTrue((p / 'SKILL.md').is_file())
        observed = self.manager.status()['backups'][0]
        self.assertEqual(observed['state'], 'restored'); self.assertIn('기록 저장', observed['error'])
        self.manager.restore({'id': backup['id']})
        self.assertEqual(self.manager.status()['backups'][0]['error'], '')

    @unittest.skipUnless(sys.platform == 'darwin', 'Native macOS directory-handle rename')
    def test_rename_refuses_symlinked_parent(self):
        actual = self.home / 'actual'; actual.mkdir(); source = actual / 'source'; source.write_text('keep')
        alias = self.home / 'alias'; alias.symlink_to(actual)
        with self.assertRaises(OSError): m.rename_exclusive(alias / 'source', self.home / 'target')
        self.assertEqual(source.read_text(), 'keep'); self.assertFalse((self.home / 'target').exists())

    def test_compare_rejects_same_installation_and_content_changed_after_scan(self):
        a = self.skill(); b = self.skill('.claude/skills/example', 'Beta')
        ids = [self.request(a)['id'], self.request(b)['id']]
        with self.assertRaisesRegex(ValueError, '서로 다른'): self.manager.compare({'ids': [ids[0], ids[0]]})
        inventory = self.manager.inventory
        def scan_then_change():
            rows = inventory(); (b / 'SKILL.md').write_text('changed after scan'); return rows
        with patch.object(self.manager, 'inventory', side_effect=scan_then_change):
            with self.assertRaisesRegex(ValueError, '바뀌었습니다'): self.manager.compare({'ids': ids})

    def test_broken_cli_reference_does_not_break_inventory(self):
        self.skill(); cli = self.home / '.local/bin/modore'; cli.parent.mkdir(parents=True); cli.symlink_to('modore')
        result = self.manager.status()
        self.assertEqual(len(result['items']), 1); self.assertTrue(result['warnings'])

    @unittest.skipIf(os.geteuid() == 0, 'Root can read chmod 000 directories')
    def test_unreadable_installation_preserves_other_rows_and_backups(self):
        backup = self.disable(self.skill())
        readable = self.skill('.claude/skills/readable')
        for rel in ('.codex/skills/unreadable', '.codex/plugins/cache/market/plugin/1/skills/unreadable'):
            with self.subTest(path=rel):
                blocked = self.skill(rel); blocked.chmod(0)
                try:
                    result = self.manager.status()
                    row = next(x for x in result['items'] if x['path'] == str(blocked))
                    self.assertTrue(row['error']); self.assertFalse(row['exists']); self.assertFalse(row['fingerprint'])
                    self.assertTrue(any(x['path'] == str(readable) and x['exists'] for x in result['items']))
                    self.assertEqual([x['id'] for x in result['backups']], [backup['id']])
                finally: blocked.chmod(0o755)

    def test_unreadable_link_metadata_is_an_individual_error(self):
        readable = self.skill(); target = self.skill('external/example')
        link = self.home / '.agents/skills/linked'; link.parent.mkdir(parents=True); link.symlink_to(target)
        readlink = os.readlink
        def fail_one_link(path, *args, **kwargs):
            if Path(path) == link: raise PermissionError('link metadata denied')
            return readlink(path, *args, **kwargs)
        with patch.object(m.os, 'readlink', side_effect=fail_one_link):
            result = self.manager.status()
        row = next(x for x in result['items'] if x['path'] == str(link))
        self.assertIn('link metadata denied', row['error']); self.assertFalse(row['exists'])
        self.assertTrue(any(x['path'] == str(readable) and x['exists'] for x in result['items']))

    def test_existing_skill_metadata_is_distinct_from_unreadable_tree(self):
        p = self.skill(); (p / 'support-cycle').symlink_to('support-cycle')
        row = next(x for x in self.manager.inventory() if x['path'] == str(p))
        self.assertTrue(row['exists']); self.assertTrue(row['error']); self.assertFalse(row['fingerprint'])

    def test_probe_evidence_only_applies_to_exact_codex_installation(self):
        codex = self.skill()
        claude = self.home / '.claude/skills/alias'; claude.parent.mkdir(parents=True); claude.symlink_to(codex)
        shared = self.home / '.agents/skills/alias'; shared.parent.mkdir(parents=True); shared.symlink_to(codex)
        request = self.home / 'probe-request.json'; request.write_text(json.dumps({'action': 'probe'}))
        output = io.StringIO(); previous_umask = os.umask(0o077)
        try:
            with patch.object(m, 'Skills', return_value=self.manager), \
                 patch.object(m, 'probe_codex', return_value=[{'path': str(codex / 'SKILL.md'), 'enabled': True}]) as probe, \
                 patch.object(sys, 'argv', ['skill_inventory.py', '--request-file', str(request)]), \
                 contextlib.redirect_stdout(output):
                m.main()
            probe.assert_called_once_with(self.home)
        finally: os.umask(previous_umask)
        rows = {x['path']: x for x in json.loads(output.getvalue())['items']}
        self.assertIn('Codex 발견 확인 · 활성', rows[str(codex)]['discovery'])
        self.assertNotIn('Codex 발견 확인', rows[str(claude)]['discovery'])
        self.assertNotIn('Codex 발견 확인', rows[str(shared)]['discovery'])

    def test_large_tree_manifest_stays_readable_and_restorable(self):
        p = self.skill()
        for index in range(80):
            (p / ('support-' + str(index) + '-' + 'x' * 90)).write_text('small payload')
        # Long entry names used to make the serialized entries exceed this bound,
        # after the original had already been moved out of host discovery.
        with patch.object(m, 'MAX_MANIFEST_BYTES', 4096):
            backup = self.disable(p)
            manifest = Path(backup['backupPath']) / 'manifest.json'
            self.assertLessEqual(manifest.stat().st_size, m.MAX_MANIFEST_BYTES)
            self.assertNotIn('entries', json.loads(manifest.read_text()))
            self.assertFalse(self.manager.status()['warnings'])
            self.manager.restore({'id': backup['id']})
        self.assertEqual(len(list(p.iterdir())), 82)

    def test_manifest_limit_rejects_before_original_is_moved(self):
        p = self.skill(); request = self.request(p)
        with patch.object(m, 'MAX_MANIFEST_BYTES', 128):
            with self.assertRaisesRegex(ValueError, '기록 크기 제한'): self.manager.disable(request)
        self.assertEqual((p / 'support.txt').read_text(), 'support file')
        self.assertFalse(any(directory.name == 'original' for directory in self.manager.bank.glob('*/original')))


if __name__ == '__main__': unittest.main()
