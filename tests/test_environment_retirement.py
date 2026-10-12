import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('environment_retirement',Path(__file__).parents[1]/'scripts/environment_retirement.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def row(id='device:a',kind='device',fingerprint='before'):
    return dict(id=id,target='a',kind=kind,name='Test',platform='iPadOS',runtime='ios-test',state='Shutdown',path='/test',project='',bytes=10,
                fingerprint=fingerprint,warnings=['loss'],invariant='',approved=False,mutation='pending',verification='pending',error='',changed=False)

class EnvironmentRetirementTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.cap=patch.object(m,'capacity',return_value={'freeBytes':100,'totalBytes':1000,'observedAt':0});self.cap.start()
        self.mem=patch.object(m,'memory',return_value='memory');self.mem.start()
    def tearDown(self):
        self.cap.stop();self.mem.stop();self.tmp.cleanup()
    def plan(self,rows):
        p=dict(id='aaf9fc3f-1bde-4773-9c85-5e050d944015',items=rows,projects=[],before={'freeBytes':100},after=None,cancelled=False)
        m.save(m.plan_path(self.root,p['id']),p);return p
    def test_unapproved_items_never_execute(self):
        p=self.plan([row()])
        with patch.object(m,'run') as command:
            m.execute(p,self.root,{'device:a'})
            command.assert_not_called()
    def test_pid_or_device_identity_change_revokes_only_that_approval(self):
        a=row();a['approved']=True;p=self.plan([a])
        with patch.object(m,'observe_item',return_value=row(fingerprint='replacement')),patch.object(m,'run') as command:
            m.execute(p,self.root,{'device:a'})
        self.assertTrue(a['changed']);self.assertFalse(a['approved']);command.assert_not_called()
    def test_partial_failure_retries_unchanged_without_reapproval(self):
        a=row();a['approved']=True;p=self.plan([a])
        with patch.object(m,'observe_item',return_value=row()),patch.object(m,'run',side_effect=ValueError('busy')):
            m.execute(p,self.root,{'device:a'})
        self.assertTrue(a['approved']);self.assertEqual(a['mutation'],'failed')
        with patch.object(m,'observe_item',side_effect=[row(),None]),patch.object(m,'run') as command:
            m.execute(p,self.root,{'device:a'})
        self.assertEqual(a['mutation'],'succeeded');self.assertEqual(a['verification'],'verified');self.assertEqual(command.call_count,1)
    def test_success_is_not_repeated_when_verification_is_pending(self):
        a=row();a.update(approved=True,mutation='succeeded');p=self.plan([a])
        with patch.object(m,'observe_item',return_value=row()),patch.object(m,'run') as command:
            m.execute(p,self.root,{'device:a'})
        command.assert_not_called();self.assertEqual(a['verification'],'pending')
    def test_restart_recovers_attempted_deletion_without_duplicate_mutation(self):
        a=row();a.update(approved=True,mutation='attempting');p=self.plan([a])
        with patch.object(m,'observe_item',return_value=None),patch.object(m,'run') as command:
            m.execute(p,self.root,{'device:a'})
        command.assert_not_called();self.assertEqual(a['verification'],'verified')
    def test_cancel_stops_remaining_items(self):
        a=row();a['approved']=True;p=self.plan([a]);(self.root/('cancel-'+p['id'])).touch()
        with patch.object(m,'run') as command:m.execute(p,self.root,{'device:a'})
        command.assert_not_called();self.assertTrue(p['cancelled'])
    def test_requirement_is_warning_not_executor_identity_block(self):
        a=row();m.annotate([a],{'platforms':['iPadOS'],'requirements':[{'project':'/ipad','platform':'iPadOS','runtime':'ios-test'}]})
        self.assertGreaterEqual(len(a['warnings']),3);self.assertEqual(a['invariant'],'')
    def test_platforms_are_not_collapsed_into_iphone(self):
        self.assertEqual(m.platform({'deviceTypeIdentifier':'com.apple.iPad-Pro'}),'iPadOS')
        self.assertEqual(m.platform({'deviceTypeIdentifier':'com.apple.Apple-Watch'}),'watchOS')
    def test_schedule_disabled_does_not_even_scan(self):
        with patch.object(m,'preview') as scan:m.dispatch({'action':'tick'},self.root)
        scan.assert_not_called()
    def test_schedule_never_expands_approval_to_devices_or_processes(self):
        m.dispatch({'action':'policy','scheduleEnabled':True,'cacheIDs':['cache:a','device:a','process:a']},self.root)
        rows=[row(),row('cache:a','cache'),row('process:a','process')];p=self.plan(rows)
        with patch.object(m,'preview',return_value=p),patch.object(m,'execute',return_value={'after':{'freeBytes':100},'before':{'freeBytes':100}}) as execute:
            m.dispatch({'action':'tick'},self.root)
        self.assertEqual(set(execute.call_args.args[2]),{'cache:a'})
        self.assertFalse(rows[0]['approved']);self.assertFalse(rows[2]['approved'])
    def test_schedule_cooldown_prevents_repeated_no_effect_cleanup(self):
        pol=m.policy(self.root);pol.update(scheduleEnabled=True,nextRunAt=m.time.time()+3600);m.save(self.root/'policy.json',pol)
        with patch.object(m,'preview') as preview:m.dispatch({'action':'tick'},self.root)
        preview.assert_not_called()
    def test_cache_command_success_is_not_free_space_verification(self):
        a=row('cache:a','cache');a['approved']=True;p=self.plan([a])
        with patch.object(m,'observe_item',return_value=a),patch.object(m,'run'):
            m.execute(p,self.root,{'cache:a'})
        self.assertEqual(a['verification'],'requested');self.assertEqual(p['after']['freeBytes'],100)
    def test_target_invariant_cannot_be_overridden(self):
        a=row();a.update(approved=True,invariant='unidentified');p=self.plan([a])
        with patch.object(m,'observe_item',return_value=a),patch.object(m,'run') as command:m.execute(p,self.root,{'device:a'})
        command.assert_not_called();self.assertEqual(a['mutation'],'failed')
    def test_record_directory_symlink_rejected(self):
        link=self.root/'link';link.symlink_to(self.root,target_is_directory=True)
        with self.assertRaises(ValueError):m.dispatch({'action':'tick'},link)
    def test_refresh_preserves_other_approvals(self):
        a=row();a.update(changed=True);b=row('device:b');b['approved']=True;p=self.plan([a,b])
        with patch.object(m,'inventory',return_value={'items':[row(fingerprint='new')]}):
            out=m.dispatch({'action':'refresh','id':p['id'],'ids':['device:a']},self.root)
        self.assertFalse(out['items'][0]['approved']);self.assertFalse(out['items'][0]['changed']);self.assertTrue(out['items'][1]['approved'])

    def test_unreadable_vm_remains_visible_without_false_running_verification(self):
        ps=f"42 {m.os.getuid()} Thu Sep 10 09:00:00 2026 /opt/homebrew/bin/limactl hostagent --pidfile /Volumes/Test/_lima/test/ha.pid test".encode()
        with patch.object(m.Path,'is_file',return_value=True),patch.object(m,'run',return_value=ps),patch.object(m.subprocess,'run',side_effect=m.subprocess.TimeoutExpired('limactl',8)):
            items=m.vm_inventory()
        self.assertEqual(len(items),1);self.assertEqual(items[0]['name'],'test')
        self.assertTrue(items[0]['invariant']);self.assertNotEqual(items[0]['state'],'Running')
    def test_setup_reuses_exact_type_even_if_device_has_custom_name(self):
        import json
        options={'runtimes':[{'id':'ios-test','devices':[{'id':'ipad-type','name':'iPad','platform':'iPadOS'}]}]}
        devices={'devices':{'ios-test':[{'udid':'existing','name':'My project iPad','deviceTypeIdentifier':'ipad-type','isAvailable':True}]}}
        with patch.object(m,'setup_options',return_value=options),patch.object(m,'run',return_value=json.dumps(devices).encode()) as run:
            result=m.setup({'action':'ensure-device','runtime':'ios-test','deviceType':'ipad-type'},self.root)
        self.assertIn('재사용',result['message']);self.assertEqual(run.call_count,1)
        self.assertNotIn('create',run.call_args.args[0])

if __name__=='__main__':unittest.main()


class StorageClassificationTests(unittest.TestCase):
    def test_permission_failure_in_content_probe_preserves_unknown(self):
        with patch.object(m.Path, 'is_file', side_effect=PermissionError('denied')):
            item=m.classify_storage('/private')
        self.assertEqual(item['classification'], '접근 확인 필요')
        self.assertFalse(item['cleanupReview'])

    def test_system_models_and_download_named_sdk_are_not_disposable(self):
        self.assertFalse(m.classify_storage('/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_GenerativeModels')['cleanupReview'])
        with tempfile.TemporaryDirectory() as root:
            sdk=Path(root)/'http-tarballs/hash';(sdk/'bin/cache').mkdir(parents=True)
            (sdk/'bin/flutter').write_text('sdk executable')
            self.assertEqual(m.classify_storage(sdk)['classification'], '설치된 Flutter SDK')
            self.assertFalse(m.classify_storage(sdk)['cleanupReview'])
            self.assertEqual(m.classify_storage(sdk/'bin/cache')['classification'], 'Flutter SDK 재생성 캐시')

    def test_app_dependencies_are_not_rebuild_candidates(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/'Tool.app/Contents/node_modules';p.mkdir(parents=True)
            (p.parent/'package.json').write_text('{}')
            (p.parent/'package-lock.json').write_text('{}')
            self.assertFalse(m.classify_storage(p)['cleanupReview'])
    def test_database_and_evidence_are_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root);(p/'PG_VERSION').write_text('16');(p/'base').mkdir()
            self.assertEqual(m.classify_storage(p)['classification'],'실제 데이터베이스')
            self.assertFalse(m.classify_storage(p/'test.xcresult')['cleanupReview'])
    def test_dependency_needs_manifest_and_lock(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/'node_modules';p.mkdir()
            (p.parent/'package.json').write_text('{}')
            self.assertFalse(m.classify_storage(p)['cleanupReview'])
            (p.parent/'package-lock.json').write_text('{}')
            self.assertTrue(m.classify_storage(p)['cleanupReview'])

    def test_mixed_build_evidence_is_not_a_whole_folder_candidate(self):
        with tempfile.TemporaryDirectory() as root:
            p=Path(root)/'.build';p.mkdir()
            (p.parent/'Package.swift').write_text('// package')
            (p/'test.xcresult').mkdir()
            self.assertFalse(m.classify_storage(p)['cleanupReview'])


class WholeDiskEvidenceTests(unittest.TestCase):
    def test_denied_models_remain_unknown_and_parent_totals_are_lower_bounds(self):
        base=Path('/Data')
        rows,issues=m.parse_disk_walk('9\t/Data/System\n10\t/Data\n',
            'du: /Data/System/com_apple_MobileAsset_UAF_FM_CodeLM: Operation not permitted\n',base)
        result=m.disk_walk_evidence(rows,issues,'partial',base,threshold=1)
        self.assertEqual(result['scannedAllocatedBytes'],10240)
        self.assertFalse(result['directories'][0]['complete'])
        asset=next(x for x in result['findings'] if x['name'].endswith('CodeLM'))
        self.assertIsNone(asset['bytes']);self.assertFalse(asset['complete'])
        self.assertFalse(asset['cleanupReview'])

    def test_arbitrary_project_outside_default_roots_connects_to_revalidation(self):
        with tempfile.TemporaryDirectory() as root:
            base=Path(root);project=base/'surprise-project';modules=project/'node_modules'
            (modules/'third-party/node_modules').mkdir(parents=True)
            (project/'package.json').write_text('{}');(project/'package-lock.json').write_text('{}')
            rows={str(base):800,str(project):800,str(modules):700,str(modules/'third-party'):600}
            result=m.disk_walk_evidence(rows,[],'complete',base,threshold=1)
            ready=[x for x in result['findings'] if x['cleanupReview']]
            self.assertEqual([x['path'] for x in ready],[str(modules)])
            self.assertFalse(any(x['path'].startswith(str(modules)+'/') for x in result['findings']))

    def test_only_complete_matching_observations_support_measured_delta(self):
        base=Path('/Data');amount=64*1024**2
        prior={'observedAt':10,'observations':[{'path':'/Data/project','bytes':amount,'complete':True}]}
        result=m.disk_walk_evidence({'/Data':amount*5,'/Data/project':amount*3,'/Data/new':amount*2},[], 'complete',base,prior,1)
        self.assertEqual(len(result['changes']),1)
        self.assertEqual(result['changes'][0]['deltaBytes'],amount*2)
        self.assertEqual(result['changes'][0]['previousAt'],10)
        result=m.disk_walk_evidence({'/Data/project':amount*3},[],'timed_out',base,prior,1)
        self.assertEqual(result['changes'],[])
        self.assertIsNone(result['scannedAllocatedBytes'])

    def test_watcher_baseline_keeps_exact_timestamp_and_ignores_failed_rows(self):
        from datetime import datetime,timezone
        with tempfile.TemporaryDirectory() as root:
            state=Path(root);env=state/'environment-retirement';env.mkdir()
            at=datetime.now(timezone.utc).isoformat()
            (state/'storage-evidence-test.tsv').write_text(f'path\t{at}\t123\tok\trepo\t/Users/test/project\npath\t{at}\t0\ttimed_out\tbad\t/Users/test/bad\n')
            result=m.prior_disk_observations(env,{})['baselineObservations']
            self.assertEqual(len(result),1);self.assertEqual(result[0]['bytes'],123*1024)
            self.assertEqual(result[0]['observedAt'],datetime.fromisoformat(at).timestamp())
