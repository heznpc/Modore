"""Real filesystem/Git transactions; GitHub transport is injected for failure cases."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('asset_retirement', Path(__file__).resolve().parents[1] / 'scripts/asset_retirement.py')
ar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ar)


class RetirementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.repo = self.base / 'repo with spaces'
        self.repo.mkdir()
        self.g('init', '-q')
        self.g('config', 'user.name', 'heznpc')
        self.g('config', 'user.email', 'heznpc@users.noreply.github.com')
        (self.repo / '.gitignore').write_text('.env\nnode_modules/\nlocal/\n')
        (self.repo / 'source').write_text('tracked')
        self.g('add', '.')
        self.g('commit', '-qm', 'fixture')
        (self.repo / '.env').write_text('preserve exactly')
        (self.repo / 'node_modules').mkdir()
        (self.repo / 'node_modules/lib').write_text('generated')
        (self.repo / 'local').mkdir()
        (self.repo / 'local/data').write_bytes(b'\x00\xffprivate')
        self.receipt = self.base / 'transaction.json'
        self.cancel = self.base / 'cancel'

    def tearDown(self):
        self.temp.cleanup()

    def g(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.DEVNULL)

    def plan(self, **options):
        item = ar.preview_item(dict(path=str(self.repo), local=True, **options))
        item['approved'] = True
        plan = dict(id='fixture', items=[item], receipt=str(self.receipt))
        ar.save(self.receipt, plan)
        return plan, item

    def test_real_delete_preserves_ignored_bytes(self):
        plan, item = self.plan()
        ar.execute(plan, self.receipt, self.cancel)
        self.assertEqual(item['localMutation'], 'succeeded', item['error'])
        self.assertEqual(item['localVerification'], 'verified')
        self.assertFalse((self.repo / '.git').exists())
        self.assertFalse((self.repo / 'source').exists())
        self.assertEqual((self.repo / '.env').read_text(), 'preserve exactly')
        self.assertEqual((self.repo / 'local/data').read_bytes(), b'\x00\xffprivate')
        self.assertTrue((self.repo / 'node_modules/lib').exists())
        self.assertIsNotNone(item['afterFree'])

    def test_generated_is_separate_and_opt_in(self):
        plan, item = self.plan(deleteGenerated=True)
        self.assertGreater(ar.summary(plan)['items'][0]['generatedBytes'], 0)
        ar.execute(plan, self.receipt, self.cancel)
        self.assertFalse((self.repo / 'node_modules').exists())
        self.assertTrue((self.repo / '.env').exists())

    def test_mutation_after_approval_requires_confirmation(self):
        plan, item = self.plan()
        (self.repo / 'source').write_text('new work')
        ar.execute(plan, self.receipt, self.cancel)
        self.assertTrue(item['changed'])
        self.assertFalse(item['approved'])
        self.assertEqual((self.repo / 'source').read_text(), 'new work')

    def test_partial_failure_retries_without_reapproval(self):
        plan, item = self.plan()
        original = ar.unlink_entry
        count = 0
        def fail_once(i, n):
            nonlocal count
            count += 1
            if count == 2:
                raise PermissionError('fixture failure')
            return original(i, n)
        with patch.object(ar, 'unlink_entry', side_effect=fail_once):
            ar.execute(plan, self.receipt, self.cancel)
        self.assertTrue(item['approved'])
        self.assertTrue(item['deleted'])
        ar.execute(plan, self.receipt, self.cancel)
        self.assertEqual(item['localVerification'], 'verified', item['error'])

    def test_symlink_target_never_followed(self):
        outside = self.base / 'external'
        outside.mkdir()
        (outside / 'precious').write_text('keep')
        (self.repo / 'external-link').symlink_to(outside, target_is_directory=True)
        plan, item = self.plan()
        ar.execute(plan, self.receipt, self.cancel)
        self.assertEqual((outside / 'precious').read_text(), 'keep')
        self.assertFalse((self.repo / 'external-link').exists())

    def test_replaced_directory_is_not_deleted(self):
        plan, item = self.plan()
        old = self.base / 'old'
        self.repo.rename(old)
        self.repo.mkdir()
        (self.repo / 'new').write_text('keep')
        ar.execute(plan, self.receipt, self.cancel)
        self.assertTrue(item['changed'])
        self.assertTrue((self.repo / 'new').exists())

    def test_cancel_and_resume(self):
        plan, item = self.plan()
        self.cancel.touch()
        ar.execute(plan, self.receipt, self.cancel)
        self.assertTrue((self.repo / 'source').exists())
        self.cancel.unlink()
        ar.execute(plan, self.receipt, self.cancel)
        self.assertEqual(item['localMutation'], 'succeeded')

    def test_unselected_previously_approved_item_is_not_executed(self):
        plan, item = self.plan()
        ar.execute(plan, self.receipt, self.cancel, selected=[])
        self.assertTrue((self.repo / 'source').exists())

    def test_archive_success_verification_failure_keeps_mutation_result(self):
        state = dict(id=10, node_id='node', full_name='heznpc/fixture', archived=False,
                     updated_at='1', pushed_at='1', default_branch='main')
        with patch.object(ar, 'remote_slug', return_value='heznpc/fixture'), patch.object(ar, 'remote_state', return_value=state):
            plan, item = self.plan(archive=True)
        real_run = ar.run
        def transport(args, **kw):
            if 'graphql' in args:
                self.assertIn('id=node', args)
                return b'{"data":{"archiveRepository":{"repository":{"id":"node","isArchived":true}}}}'
            return real_run(args, **kw)
        with patch.object(ar, 'gh_executable', return_value='/fixture/gh'), patch.object(ar, 'run', side_effect=transport), patch.object(ar, 'remote_state', side_effect=[state, RuntimeError('verification unavailable')]):
            ar.execute(plan, self.receipt, self.cancel)
        self.assertEqual(item['archiveMutation'], 'succeeded')
        self.assertEqual(item['archiveVerification'], 'failed')
        self.assertTrue(item['approved'])
        self.assertTrue((self.repo / 'source').exists())
        archived = dict(state, archived=True, updated_at='2')
        with patch.object(ar, 'remote_state', return_value=archived):
            ar.execute(plan, self.receipt, self.cancel)
        self.assertEqual(item['archiveVerification'], 'verified')
        self.assertEqual(item['localVerification'], 'verified', item['error'])

    def test_remote_identity_change_requires_new_approval(self):
        state = dict(id=10, node_id='n', full_name='heznpc/fixture', archived=False,
                     updated_at='1', pushed_at='1', default_branch='main')
        with patch.object(ar, 'remote_slug', return_value='heznpc/fixture'), patch.object(ar, 'remote_state', return_value=state):
            plan, item = self.plan(archive=True)
        with patch.object(ar, 'remote_state', return_value=dict(state, id=99)):
            ar.execute(plan, self.receipt, self.cancel)
        self.assertTrue(item['changed'])
        self.assertTrue((self.repo / 'source').exists())

    def test_journal_recovers_unlink_before_checkpoint(self):
        plan, item = self.plan()
        ar.journal(self.receipt, item, 'attempt', 'source')
        ar.unlink_entry(item, 'source')
        restored = json.loads(self.receipt.read_text())
        ar.replay(self.receipt, restored)
        ar.execute(restored, self.receipt, self.cancel)
        self.assertEqual(restored['items'][0]['localVerification'], 'verified')

    def test_changed_item_does_not_stop_other_approved_item(self):
        import shutil
        plan, first = self.plan()
        other = self.base / 'other'
        shutil.copytree(self.repo, other)
        second = ar.preview_item(dict(path=str(other), local=True))
        second['approved'] = True
        plan['items'].append(second)
        (self.repo / 'new-work').write_text('changed')
        ar.execute(plan, self.receipt, self.cancel)
        self.assertTrue(first['changed'])
        self.assertEqual(second['localMutation'], 'succeeded')

    def test_no_space_for_journal_stops_before_unlink(self):
        plan, item = self.plan()
        with patch.object(ar, 'journal', side_effect=OSError(28, 'No space left')):
            ar.execute(plan, self.receipt, self.cancel)
        self.assertTrue((self.repo / 'source').exists())
        self.assertEqual(item['deleted'], [])
        self.assertEqual(item['localMutation'], 'failed')

    def test_ignored_empty_directory_survives(self):
        (self.repo / 'local/empty').mkdir()
        plan, item = self.plan()
        ar.execute(plan, self.receipt, self.cancel)
        self.assertTrue((self.repo / 'local/empty').is_dir())


if __name__ == '__main__':
    unittest.main()
