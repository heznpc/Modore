import importlib.util
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

if __name__=='__main__':unittest.main()
