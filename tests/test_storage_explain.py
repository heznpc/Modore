import importlib.util
import json
import math
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('explain', Path(__file__).parents[1]/'scripts/storage_explain.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class ExplanationTests(unittest.TestCase):
    def test_peak_baseline_and_explicit_date(self):
        with tempfile.TemporaryDirectory() as d:
            state=Path(d)
            (state/'storage-samples.tsv').write_text('2026-10-01T00:00:00Z\t200\n2026-10-02T00:00:00Z\t100\n')
            now=m.stamp('2026-10-03T00:00:00Z')
            self.assertEqual(m.baseline(state,now=now),(m.stamp('2026-10-01T00:00:00Z'),204800))
            self.assertEqual(m.baseline(state,since=m.stamp('2026-10-02T00:00:00Z'),now=now)[1],102400)

    def test_hardlinks_and_symlinks_not_double_counted(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); f=root/'data';f.write_bytes(b'x'*8192)
            os.link(f,root/'hard');(root/'symbol').symlink_to(f)
            row=m.scan('test',d,0,m.time.time()+1)
            self.assertEqual(row['files'],1)
            self.assertTrue(row['complete'])
            self.assertEqual(row['modifiedBytes']+row['createdBytes'],f.stat().st_blocks*512)

    def test_old_modified_file_is_not_counted_as_new_growth(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);f=root/'old';f.write_bytes(b'a'*4096)
            now=m.time.time()
            # Birth precedes the baseline, but an existing file was modified later.
            os.utime(f, (now+11, now+11))
            row=m.scan('test',d,now+10,now+20)
            self.assertEqual(row['createdBytes'],0)
            self.assertEqual(row['modifiedBytes'],f.stat().st_blocks*512)
            self.assertGreater(row['allocatedBytes'],0)

    def test_failed_and_stale_baselines_do_not_prove_growth(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);since=m.stamp('2026-10-02T00:00:00Z')
            (p/'storage-evidence-2026-10.tsv').write_text(
                'path\t2026-10-01T00:00:00Z\t20\tok\told\t/tmp/old\n'
                'path\t2026-10-02T00:00:00Z\t0\ttimed_out\tbad\t/tmp/bad\n'
                'path\t2026-10-02T00:00:00Z\t40\tok\tgood\t/tmp/good\n')
            measurements=m.past_measurements(p,since)
            self.assertEqual(list(measurements),[os.path.realpath('/tmp/good')])
            self.assertEqual(measurements[os.path.realpath('/tmp/good')][1],40960)

    def test_baseline_bounds_use_evidence_timestamp_precision(self):
        # The original direct float comparison intermittently rejected a
        # timestamp produced from this very same `since` value. Exercise both
        # rounding directions, both persisted producers, and the adjacent
        # microseconds so the fix cannot start accepting future/stale evidence.
        exact=m.stamp('2026-10-02T00:00:00.123457Z')
        for since in (math.nextafter(exact, -math.inf), math.nextafter(exact, math.inf)):
            with self.subTest(since=since), tempfile.TemporaryDirectory() as d:
                state=Path(d);reports=state/'storage-explanations';reports.mkdir()
                samples = [('edge', since), ('oldest', since-300),
                           ('future', exact+0.000001), ('stale', exact-300-0.000001)]
                evidence=[]
                for label, at in samples:
                    evidence.append(f'path\t{m.iso(at)}\t1\tok\t{label}\t/tmp/tsv-{label}\n')
                    (reports/f'{label}.json').write_text(json.dumps({
                        'capturedAt': m.iso(at),
                        'rows': [{'path': f'/tmp/json-{label}', 'complete': True,
                                  'allocatedBytes': 2048}],
                    }))
                (state/'storage-evidence-2026-10.tsv').write_text(''.join(evidence))
                measurements=m.past_measurements(state,since)
                self.assertEqual(set(measurements), {
                    os.path.realpath(f'/tmp/{producer}-{label}')
                    for producer in ('tsv', 'json') for label in ('edge', 'oldest')
                })

    def test_explanation_separates_measured_growth_from_metadata(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d).resolve();state=root/'state';state.mkdir();target=root/'target';target.mkdir()
            (target/'payload').write_bytes(b'x'*8192)
            since=m.time.time()-30
            (state/'storage-evidence-2026-10.tsv').write_text(
                f'path\t{m.iso(since)}\t1\tok\ttarget\t{target}\n')
            result=m.explain(home=root,state=state,since=since,targets=[('test',str(target))])
            row=result['rows'][0]
            self.assertEqual(row['measuredDeltaBytes'],row['allocatedBytes']-1024)
            self.assertEqual(row['recentDeltaBytes'],row['measuredDeltaBytes'])
            self.assertIsNone(result['freeDropBytes'])
            self.assertTrue((state/'storage-explanation-progress.json').exists())


class IsolatedScanTests(unittest.TestCase):
    def test_stalled_root_is_partial_and_next_root_still_runs(self):
        import time
        with tempfile.TemporaryDirectory() as d:
            with patch.object(m, 'scan', side_effect=lambda *args: time.sleep(2)):
                row = m.scan_isolated('stalled', d, 0, time.time(), set(), timeout=0.1)
            self.assertEqual(row['status'], 'timeout')
            self.assertFalse(row['complete'])
            Path(d, 'file').write_bytes(b'x' * 8192)
            row = m.scan_isolated('next', d, 0, time.time(), set())
            self.assertTrue(row['complete'])
            self.assertGreater(row['allocatedBytes'], 0)

    def test_hardlink_identity_survives_worker_boundary(self):
        import time
        with tempfile.TemporaryDirectory() as d:
            a = Path(d, 'a'); b = Path(d, 'b'); a.mkdir(); b.mkdir()
            (a/'file').write_bytes(b'x' * 8192); os.link(a/'file', b/'link')
            seen=set()
            first=m.scan_isolated('a',str(a),0,time.time(),seen)
            second=m.scan_isolated('b',str(b),0,time.time(),seen)
            self.assertGreater(first['allocatedBytes'], second['allocatedBytes'])
            self.assertEqual(second['files'], 0)
