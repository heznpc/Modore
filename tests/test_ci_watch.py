import importlib.util
import json
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location('ci_watch', Path(__file__).parents[1] / 'scripts/ci_watch.py')
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


def sample(number=1, conclusion='failure', signature='same', series='main'):
    return dict(series=series, repo='owner/repo', workflow='CI', branch='main', event='push',
                runId=number, attempt=f'{number}:1', order=[f'2026-09-{number:02}T00:00:00Z', number, 1],
                url=f'https://github.com/owner/repo/actions/runs/{number}', sha='a' * 40,
                status='completed', conclusion=conclusion, observedAt=ci.now(), streak=number,
                steps=['test: pytest'], excerpt='FAILED test_meaningful_contract', evidence='log',
                signature=signature, stepKey='pytest')


def apply(state, row, **kwargs):
    return ci.reconcile(state, [dict(repo='owner/repo', error=None, samples=[row],
                                   runsRead=1, limited=False, observedAt=ci.now())], **kwargs)


def test_baseline_is_silent_and_repeated_failure_updates_one_incident():
    state = apply(ci.empty_state(), sample(), notify=True)
    state = apply(state, sample(2), notify=True)
    state = apply(state, sample(2), notify=True)
    assert len(state['incidents']) == 1
    assert state['incidents'][0]['observedFailures'] == 2
    assert state['events'] == []


@pytest.mark.parametrize('conclusion', ['cancelled', 'skipped', 'neutral', None])
def test_interrupted_run_is_not_recovery(conclusion):
    state = apply(ci.empty_state(), sample())
    row = sample(2, conclusion)
    if conclusion is None:
        row['status'] = 'in_progress'
    state = apply(state, row, notify=True)
    assert state['incidents'][0]['state'] == 'open'
    assert not state['events']


def test_failed_collection_keeps_known_incident_and_exposes_error():
    state = apply(ci.empty_state(), sample())
    state = ci.reconcile(state, [dict(repo='owner/repo', error='offline', samples=[])], notify=True)
    assert state['incidents'][0]['state'] == 'open'
    assert state['repositories'][0]['error'] == 'offline'
    assert not state['events']


def test_recovery_requires_newer_success_in_same_lane_then_recurrence_notifies():
    state = apply(ci.empty_state(), sample(3))
    state = apply(state, sample(2, 'success'), notify=True)
    state = apply(state, sample(4, 'success', series='another-branch'), notify=True)
    assert state['incidents'][0]['state'] == 'open'
    state = apply(state, sample(4, 'success'), notify=True)
    assert state['incidents'][0]['state'] == 'recovered'
    assert len(state['events']) == 1
    state = apply(state, sample(4, 'success'), notify=True)
    assert len(state['events']) == 1
    state = apply(state, sample(3), notify=True)
    assert state['incidents'][0]['state'] == 'recovered'
    state = apply(state, sample(5), notify=True)
    assert state['incidents'][0]['state'] == 'open'
    assert [e['kind'] for e in state['events']] == ['failure']


def test_changed_diagnostic_is_not_reported_as_green_recovery():
    state = apply(ci.empty_state(), sample())
    state = apply(state, sample(2, signature='different-assertion'), notify=True)
    assert sorted(i['state'] for i in state['incidents']) == ['changed', 'open']
    assert [e['kind'] for e in state['events']] == ['failure']


def test_unavailable_log_preserves_known_evidence_without_fake_new_alert():
    state = apply(ci.empty_state(), sample())
    row = dict(sample(2), evidence='step', excerpt='', signature='steps-only')
    state = apply(state, row, notify=True)
    assert len(state['incidents']) == 1
    assert state['incidents'][0]['excerpt']
    assert not state['events']


def test_empty_or_capped_response_does_not_resolve_missing_lane():
    state = apply(ci.empty_state(), sample())
    ci.reconcile(state, [dict(repo='owner/repo', error=None, samples=[], limited=True)], notify=True)
    assert state['incidents'][0]['state'] == 'open'
    assert state['incidents'][0]['tracking'] == 'not_observed'


def test_closed_pr_is_retired_without_claiming_recovery():
    state = apply(ci.empty_state(), sample())
    state = apply(state, dict(sample(2), activePR=False), notify=True)
    assert state['incidents'][0]['state'] == 'inactive'
    assert not state['events']


def test_log_fingerprint_ignores_duration_and_post_failure_cleanup():
    class API:
        def __init__(self, duration):
            self.duration = duration
        def get(self, endpoint, raw=False):
            if not raw:
                return {'jobs': [dict(id=1, name='test', conclusion='failure', steps=[])]}
            return (f'FAILED tests/test_timing.py::test_deadline - assert {self.duration} < 3\n'
                    f'1 failed, 10 passed in {self.duration}s\n'
                    '##[error]Process completed with exit code 1.\n'
                    'ERROR: deliberate database cleanup error\n')
    a = ci.failure_evidence(API(3.14), 'o/r', {'id': 1})
    b = ci.failure_evidence(API(4.62), 'o/r', {'id': 2})
    assert a['signature'] == b['signature']
    assert 'cleanup' not in a['excerpt']


def test_fork_and_event_are_part_of_recovery_identity():
    run = dict(workflow_id=1, head_branch='main', event='push', head_repository={'id': 1})
    assert ci.series_key('owner/repo', run) != ci.series_key('owner/repo', dict(run, event='pull_request'))
    assert ci.series_key('owner/repo', run) != ci.series_key('owner/repo', dict(run, head_repository={'id': 2}))


def test_redaction_drops_credentials_emails_and_home_usernames():
    text = ci.scrub('error: token=secret-value ghp_abc123 a.person@example.com /Users/private-person/repo https://host/x?secret=y')
    for secret in ['secret-value', 'ghp_abc123', 'a.person@example.com', 'private-person', 'secret=y']:
        assert secret not in text


def test_store_status_does_not_refresh_and_ack_is_selective(tmp_path):
    store = ci.Store(tmp_path / 'ci')
    assert ci.invoke({'action': 'status'}, store)['checkedAt'] is None
    assert not store.root.exists()
    state = apply(ci.empty_state(), sample())
    state = apply(state, sample(2, signature='changed'), notify=True)
    with store.locked():
        store.write(state)
    original = (store.root / 'state.json').read_bytes()
    ci.invoke({'action': 'status'}, store)
    assert (store.root / 'state.json').read_bytes() == original
    ci.invoke({'action': 'ack', 'ids': ['unknown']}, store)
    assert store.read()['events']
    ci.invoke({'action': 'ack', 'ids': [state['events'][0]['id']]}, store)
    assert not store.read()['events']


def test_symlinked_state_is_rejected(tmp_path):
    outside = tmp_path / 'outside'
    outside.write_text(json.dumps(ci.empty_state()))
    root = tmp_path / 'ci'
    root.mkdir()
    (root / 'state.json').symlink_to(outside)
    with pytest.raises(RuntimeError):
        ci.Store(root).read()


def test_collector_uses_latest_created_run_not_old_rerun_and_caches_log():
    class API:
        def get(self, endpoint, raw=False):
            if '/actions/runs?' in endpoint:
                return {'total_count': 100, 'workflow_runs': [
                    dict(id=1, run_number=1, created_at='2026-01-01', run_attempt=5,
                         workflow_id=1, head_branch='main', event='push', status='completed', conclusion='success'),
                    dict(id=2, run_number=2, created_at='2026-01-02', run_attempt=1,
                         workflow_id=1, head_branch='main', event='push', status='completed', conclusion='failure')
                ]}
            if endpoint.endswith('/jobs?per_page=100'):
                return {'jobs': [dict(id=90, name='test', conclusion='failure',
                                     steps=[dict(name='pytest', conclusion='failure')])]}
            if raw:
                return '2026-01-02T00:00:00Z FAILED tests/test_checkout.py::test_committed_content\n'
            raise AssertionError(endpoint)
    result = ci.collect_repo(API(), 'owner/repo', [])
    assert result['limited']
    assert result['samples'][0]['runId'] == 2
    assert result['samples'][0]['evidence'] == 'log'
    state = ci.reconcile(ci.empty_state(), [result])
    class CachedAPI(API):
        def get(self, endpoint, raw=False):
            assert '/jobs' not in endpoint
            return super().get(endpoint, raw)
    assert ci.collect_repo(CachedAPI(), 'owner/repo', state['incidents'])['samples'][0]['excerpt']


@pytest.mark.parametrize('repo', ['https://host/owner/repo', '../repo', 'owner/repo?token=x', 'a/b/c', '-bad'])
def test_repository_cannot_redirect_authenticated_api(repo):
    with pytest.raises(ValueError):
        ci.slug(repo)
