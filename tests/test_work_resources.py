import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('resources', Path(__file__).parents[1] / 'scripts/work_resources.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


def fixture():
    return m.simulator_rows({'devices': {'ios-a': [
        {'udid': '1', 'name': 'shared', 'state': 'Booted', 'isAvailable': True, 'deviceTypeIdentifier': 'phone', 'dataPath': '/a'},
        {'udid': '2', 'name': 'audit', 'state': 'Shutdown', 'isAvailable': True, 'deviceTypeIdentifier': 'phone', 'dataPath': '/b'}],
        'ios-b': [{'udid': '3', 'name': 'shared', 'state': 'Shutdown', 'isAvailable': True, 'deviceTypeIdentifier': 'phone', 'dataPath': '/c'}]}})

class ResourceTests(unittest.TestCase):
    def test_duplicate_identity_uses_runtime_and_type_not_name(self):
        rows = fixture(); self.assertEqual(rows[0]['duplicates'], ['2']); self.assertEqual(rows[2]['duplicates'], [])
    def test_reuse_booted_and_never_create_for_missing_runtime(self):
        self.assertEqual(m.select_existing(fixture(), 'ios-a')['id'], '1')
        with self.assertRaises(ValueError): m.select_existing(fixture(), 'missing')
    def test_preferred_exact_match(self):
        self.assertEqual(m.select_existing(fixture(), 'ios-a', preferred='2')['id'], '2')
        self.assertEqual(m.select_existing(fixture(), 'ios-b', preferred='2')['id'], '3')
    def test_expiry_does_not_claim_live_ownership(self):
        state = {'leases': [{'resourceID':'a','expiresAt':10}, {'resourceID':'a','expiresAt':30}]}
        self.assertEqual(len(m.active_leases(state,'a',20)),1)
    def test_registry_acquire_heartbeat_release(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(m,'devices',return_value=fixture()), patch.object(m,'volumes',return_value=([],[])):
            root=Path(tmp)/'state'
            r=m.register({'session':'s','project':tmp,'runtime':'ios-a'},root)
            self.assertEqual(r['resource']['id'],'1')
            m.dispatch({'action':'release','session':'s'},root)
            with m.registry(root) as state:self.assertFalse(m.active_leases(state,'1'))
            m.dispatch({'action':'heartbeat','session':'s'},root)
            with m.registry(root) as state:self.assertFalse(m.active_leases(state,'1'))
            # A late heartbeat cannot resurrect a released registration.
            m.register({'session':'s','project':tmp,'runtime':'ios-a'},root)
            with m.registry(root) as state:self.assertTrue(m.active_leases(state,'1'))
    def test_changed_target_prevents_mutation(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(m,'devices',return_value=fixture()), patch.object(m,'volumes',return_value=([],[])), patch.object(m,'command') as cmd:
            with self.assertRaises(ValueError):m.mutate({'action':'shutdown','id':'1','fingerprint':'old'},Path(tmp))
            cmd.assert_not_called()
    def test_booted_duplicate_cannot_be_deleted(self):
        r=fixture()[0]
        with tempfile.TemporaryDirectory() as tmp, patch.object(m,'devices',return_value=fixture()), patch.object(m,'volumes',return_value=([],[])), patch.object(m,'command') as cmd:
            with self.assertRaises(ValueError):m.mutate({'action':'delete-duplicate','id':r['id'],'fingerprint':r['fingerprint']},Path(tmp))
            cmd.assert_not_called()
    def test_active_lease_warning_requires_override(self):
        r=fixture()[0]
        with tempfile.TemporaryDirectory() as tmp, patch.object(m,'devices',return_value=fixture()), patch.object(m,'volumes',return_value=([],[])), patch.object(m,'command') as cmd:
            root=Path(tmp)
            with m.registry(root) as s:s['leases']=[{'resourceID':'1','expiresAt':m.time.time()+500}]
            with self.assertRaises(ValueError):m.mutate({'action':'shutdown','id':'1','fingerprint':r['fingerprint']},root)
            cmd.assert_not_called()

class TurnResourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'registry'
        self.rows = fixture()
        self.calls = []
        self.event = {'hook_event_name': 'UserPromptSubmit', 'session_id': 'session-a',
                      'turn_id': 'turn-a', 'cwd': self.tmp.name}
        self.req = {'id': '2', 'provider': 'codex', 'session': 'session-a',
                    'project': self.tmp.name, 'turn': 'turn-a'}
        def command(args, timeout=20):
            self.calls.append(args)
            row = next(x for x in self.rows if x['id'] == args[-1])
            if args[2] == 'boot':
                row.update(state='Booted', lastBooted='new-boot')
            elif args[2] == 'shutdown':
                row['state'] = 'Shutdown'
            else:
                self.fail('unexpected resource mutation')
            return b''
        for name, kwargs in [('devices', {'side_effect': lambda *a: copy.deepcopy(self.rows)}),
                             ('volumes', {'return_value': ([], [])}),
                             ('command', {'side_effect': command})]:
            patcher = patch.object(m, name, **kwargs)
            patcher.start(); self.addCleanup(patcher.stop)
        m.turn_hook('codex', self.event, self.root)

    def stop(self, **fields):
        return m.turn_hook('codex', {**self.event, 'hook_event_name': 'Stop', **fields}, self.root)

    def test_turn_end_stops_only_managed_runtime_and_preserves_device(self):
        m.begin_test(self.req, self.root)
        self.stop()
        self.assertEqual(self.rows[1]['state'], 'Shutdown')
        self.assertEqual(self.rows[0]['state'], 'Booted')  # Unmanaged running device.
        self.assertEqual(len(self.rows), 3)
        self.assertEqual([x[2] for x in self.calls], ['boot', 'shutdown'])
        receipt = json.loads(next(self.root.glob('receipt-*.json')).read_text())
        self.assertTrue(receipt['verified'])
        self.assertEqual(receipt['action'], 'turn-shutdown')

    def test_expired_foreign_lease_still_prevents_shutdown(self):
        m.begin_test(self.req, self.root)
        m.register({'id':'2','session':'session-b','project':self.tmp.name}, self.root)
        with m.registry(self.root) as state:
            other = state['leases'][-1]
            other['updatedAt'] = m.time.time()-1800
            other['expiresAt'] = other['updatedAt']+900
        self.stop()
        self.assertEqual(self.rows[1]['state'], 'Booted')
        m.dispatch({'action':'release', 'session':'session-b'}, self.root)
        self.assertEqual(self.rows[1]['state'], 'Shutdown')

    def test_old_explicit_release_is_distinct_from_stale_heartbeat(self):
        with m.registry(self.root) as state:
            state['leases'] = [
                {'resourceID':'2','session':'old','updatedAt':100,'expiresAt':99},
                {'resourceID':'3','session':'stale','updatedAt':100,'expiresAt':1000}]
        with m.registry(self.root) as state:
            self.assertFalse(m.unresolved_leases(state,'2'))
            self.assertEqual(len(m.unresolved_leases(state,'3')),1)

    def test_unmanaged_booted_device_cannot_be_adopted_for_automatic_stop(self):
        with self.assertRaises(ValueError): m.begin_test({**self.req,'id':'1'},self.root)
        self.assertFalse(self.calls)

    def test_busy_device_is_not_booted_for_another_turn(self):
        m.register({'id':'2','session':'session-b','project':self.tmp.name},self.root)
        with self.assertRaises(ValueError):m.begin_test(self.req,self.root)
        self.assertFalse(self.calls)

    def test_repeated_begin_does_not_boot_twice(self):
        m.begin_test(self.req,self.root)
        self.assertTrue(m.begin_test(self.req,self.root)['reused'])
        self.assertEqual(len(self.calls),1)

    def test_unobserved_or_wrong_turn_cannot_boot(self):
        with self.assertRaises(ValueError):m.begin_test({**self.req,'turn':'old'},self.root)
        self.assertFalse(self.calls)

    def test_late_stop_cannot_end_new_turn(self):
        m.begin_test(self.req,self.root)
        m.turn_hook('codex',{**self.event,'turn_id':'turn-b'},self.root)
        self.stop()
        self.assertEqual(self.rows[1]['state'],'Booted')

    def test_other_provider_or_subagent_cannot_end_parent_turn(self):
        m.begin_test(self.req,self.root)
        m.turn_hook('claude',{**self.event,'hook_event_name':'Stop'},self.root)
        self.stop(agent_id='child')
        self.assertEqual(self.rows[1]['state'],'Booted')

    def test_pause_permission_compaction_or_session_end_is_not_turn_completion(self):
        m.begin_test(self.req,self.root)
        for event in ['Interrupt','PermissionRequest','PostCompact','SessionEnd','StopFailure']:
            self.assertEqual(m.turn_hook('codex',{**self.event,'hook_event_name':event},self.root),{})
        self.assertEqual(self.rows[1]['state'],'Booted')

    def test_hold_keeps_preview_until_explicit_release(self):
        m.begin_test(self.req,self.root)
        m.dispatch({**self.req,'action':'hold'},self.root)
        self.stop()
        self.assertEqual(self.rows[1]['state'],'Booted')
        m.dispatch({**self.req,'action':'release'},self.root)
        self.assertEqual(self.rows[1]['state'],'Shutdown')

    def test_changed_identity_or_external_reboot_prevents_stop(self):
        for field in ['fingerprint','lastBooted']:
            with self.subTest(field=field):
                self.rows[1]['state']='Shutdown'
                # Fresh isolated lease registry for each variant.
                root=self.root/field
                m.turn_hook('codex',self.event,root)
                m.begin_test(self.req,root)
                self.rows[1][field]='changed'
                m.turn_hook('codex',{**self.event,'hook_event_name':'Stop'},root)
                self.assertEqual(self.rows[1]['state'],'Booted')

    def test_failed_shutdown_records_failure_without_ending_ai_session(self):
        m.begin_test(self.req,self.root)
        with patch.object(m,'command',side_effect=ValueError('shutdown failed')):
            result=self.stop()
        self.assertNotIn('decision',result)
        self.assertNotIn('continue',result)
        self.assertIn('확인 필요',result['systemMessage'])
        receipt=json.loads(next(self.root.glob('receipt-*.json')).read_text())
        self.assertEqual(receipt['status'],'failed')
        self.assertFalse(receipt['verified'])
        self.stop()  # An explicit repeated Stop can retry a known pending run.
        self.assertEqual(self.rows[1]['state'],'Shutdown')

    def test_boot_timeout_keeps_uncertainty_in_registry(self):
        with patch.object(m,'command',side_effect=TimeoutError('boot timed out')):
            self.assertIn('error',m.begin_test(self.req,self.root))
        self.stop()
        with m.registry(self.root) as state:
            self.assertEqual(state['testRuns']['2']['status'],'boot-unverified')
        self.assertFalse(self.calls)

    def test_duplicate_stop_does_not_repeat_shutdown(self):
        m.begin_test(self.req,self.root)
        self.stop(); self.stop()
        self.assertEqual([x[2] for x in self.calls],['boot','shutdown'])

    def test_unrelated_turn_does_not_retry_another_sessions_pending_shutdown(self):
        m.begin_test(self.req,self.root)
        with patch.object(m,'command',side_effect=ValueError('busy')):
            self.stop()
        event={**self.event,'session_id':'other','turn_id':'other-turn'}
        m.turn_hook('codex',event,self.root)
        self.assertEqual(m.turn_hook('codex',{**event,'hook_event_name':'Stop'},self.root),{})
        self.assertEqual(self.rows[1]['state'],'Booted')

    def test_continuation_prompt_can_begin_test_again(self):
        m.begin_test(self.req,self.root)
        self.stop()
        m.turn_hook('codex',self.event,self.root)
        m.begin_test(self.req,self.root)
        self.assertEqual(self.rows[1]['state'],'Booted')
        self.stop()
        self.assertEqual(self.rows[1]['state'],'Shutdown')

    def test_installer_respects_disabled_hooks(self):
        home=Path(self.tmp.name)/'disabled-home'
        path=home/'.claude/settings.json'
        path.parent.mkdir(parents=True)
        path.write_text('{"disableAllHooks":true}')
        with self.assertRaises(ValueError):m.install_hooks('claude',root=self.root,home=home)
        self.assertEqual(json.loads(path.read_text()),{'disableAllHooks':True})

    def test_claude_turn_token_and_no_conversation_retention(self):
        event={**self.event,'last_assistant_message':'PRIVATE','prompt':'PRIVATE',
               'transcript_path':'/do/not/read'}
        event.pop('turn_id')
        m.turn_hook('claude',event,self.root)
        with m.registry(self.root) as state:
            token=state['turns'][m.turn_key('claude','session-a')]['token']
        m.begin_test({**self.req,'provider':'claude','turn':token},self.root)
        m.turn_hook('claude',{**event,'hook_event_name':'Stop'},self.root)
        self.assertEqual(self.rows[1]['state'],'Shutdown')
        for path in self.root.glob('*.json'):
            self.assertNotIn('PRIVATE',path.read_text())
            self.assertNotIn('/do/not/read',path.read_text())

    def test_installer_preserves_existing_hooks_and_never_trusts_them(self):
        home=Path(self.tmp.name)/'home'
        for provider,filename in [('claude','.claude/settings.json'),('codex','.codex/hooks.json')]:
            path=home/filename;path.parent.mkdir(parents=True)
            previous={'custom':{'keep':True},'hooks':{'Stop':[{'hooks':[{'type':'command','command':'existing'}]}]}}
            path.write_text(json.dumps(previous))
            kwargs={'root':self.root,'home':home,'executable':Path(__file__).parents[1]/'bin/modore'}
            result=m.install_hooks(provider,**kwargs)
            self.assertTrue(result['changed'])
            self.assertFalse(m.install_hooks(provider,**kwargs)['changed'])
            new=json.loads(path.read_text())
            self.assertEqual(new['custom'],previous['custom'])
            self.assertEqual(new['hooks']['Stop'][0],previous['hooks']['Stop'][0])
            self.assertEqual(len(new['hooks']['Stop']),2)
            self.assertNotIn('trusted_hash',path.read_text())
            self.assertEqual(json.loads(Path(result['backup']).read_text()),previous)


if __name__=='__main__':unittest.main()
