#!/usr/bin/env python3
"""Local GitHub Actions incident journal. Remote operations are GET requests only.

The native app owns opt-in polling and delivery. Status/MCP never refreshes or
acknowledges a notification. A green, newer run in the same workflow/branch/event
is the only recovery evidence; missing, cancelled and unreadable runs are not.
"""
import argparse
import concurrent.futures
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time

MAX_REPOS = 24
MAX_RUNS = 50
SLUG = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z')
FAILED = {'failure', 'timed_out', 'startup_failure', 'action_required'}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()[:24]


def scrub(value):
    value = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', str(value))
    value = re.sub(r'(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)', '[token]', value)
    value = re.sub(r'(?i)(authorization\s*[:=]\s*|(?:token|password|secret|api[_-]?key)\s*[:=]\s*)\S+', r'\1[redacted]', value)
    value = re.sub(r'[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}', '[email]', value)
    value = re.sub(r'(?:/Users/|/home/)[^\s/:]+', '/[user]', value)
    value = re.sub(r'https?://[^\s)]+', '[url]', value)
    return ''.join(c for c in value if c in '\n\t' or ord(c) >= 32)[:2000]


def command(argv, timeout=20, cap=4_000_000):
    env = dict(os.environ, GH_PROMPT_DISABLED='1', GH_PAGER='cat', GIT_TERMINAL_PROMPT='0')
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            env=env, start_new_session=True)
    chunks = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + timeout
            while selector.get_map():
                if time.monotonic() >= deadline:
                    raise RuntimeError('GitHub query timed out')
                for key, _ in selector.select(min(0.2, max(0, deadline - time.monotonic()))):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        selector.unregister(key.fileobj)
                    else:
                        chunks.extend(block)
                        if len(chunks) > cap:
                            raise RuntimeError('GitHub response exceeded the collection limit')
            code = proc.wait(timeout=max(0.1, deadline - time.monotonic()))
        if code:
            raise RuntimeError('GitHub query failed; check gh authentication and repository access')
        return chunks.decode('utf-8', errors='replace')
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        proc.stdout.close()


class GitHub:
    def __init__(self):
        self.deadline = time.monotonic() + 180
        self.path = next((p for p in ['/opt/homebrew/bin/gh', '/usr/local/bin/gh', '/usr/bin/gh']
                          if os.path.isfile(p) and os.access(p, os.X_OK)), None)
        if not self.path:
            raise RuntimeError('GitHub CLI (gh) is not installed')

    def get(self, endpoint, raw=False):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError('CI collection time limit reached; retry to refresh remaining repositories')
        data = command([self.path, 'api', '--hostname', 'github.com', '--method', 'GET', endpoint], timeout=min(20, remaining))
        return data if raw else json.loads(data)


def slug(value):
    if not isinstance(value, str) or not SLUG.fullmatch(value) or '..' in value:
        raise ValueError('Use a GitHub repository in owner/name form')
    return value.lower()


def project_repo(path):
    if not isinstance(path, str) or not path.startswith('/') or not os.path.isdir(path):
        return None
    try:
        remote = command(['/usr/bin/git', '--no-optional-locks', '-c', 'core.fsmonitor=false',
                          '-C', path, 'remote', 'get-url', 'origin'], timeout=3, cap=8192).strip()
        match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?', remote)
        return slug(match[1]) if match else None
    except (ValueError, RuntimeError, OSError):
        return None


def failure_evidence(api, repo, run):
    steps, excerpts = [], []
    jobs = api.get('repos/' + repo + '/actions/runs/' + str(run['id']) + '/attempts/' + str(run.get('run_attempt', 1)) + '/jobs?per_page=100')['jobs']
    for job in jobs:
        if job.get('conclusion') not in FAILED:
            continue
        broken = [s['name'] for s in job.get('steps', []) if s.get('conclusion') in FAILED]
        steps.append(scrub(job['name'] + ': ' + ', '.join(broken or [job.get('conclusion', 'failure')])))
        if len(excerpts) >= 4:
            continue
        try:
            log = api.get('repos/' + repo + '/actions/jobs/' + str(job['id']) + '/logs', raw=True)
            lines = [re.sub(r'^\d{4}-\d\d-\d\dT\S+\s+', '', line).strip() for line in log.splitlines()]
            # Runner service teardown often emits deliberately triggered DB errors.
            # Those are not evidence of the step that already exited unsuccessfully.
            end = next((n for n, line in enumerate(lines) if '##[error]Process completed with exit code' in line), len(lines))
            lines = lines[:end]
            matched = [scrub(line) for line in lines if re.search(
                r'(?i)(?:##\[error\]|\berror:|\bFAILED\b|AssertionError|Error:|coverage too low|npm ERR!)', line)
                and not re.search(r'(?i)(?:\b0 failed\b|\b0 failures\b|^\+|^\d+\s+(?:failed|passed|skipped)|process completed with exit code)', line)]
            excerpts.extend(matched[-4:])
        except (RuntimeError, OSError, KeyError, ValueError):
            pass  # A failed log download never makes a known failed run healthy.
    if not steps:
        steps = [scrub(run.get('conclusion', 'failure'))]
    excerpts = list(dict.fromkeys(excerpts))[:6]
    normalized = []
    named_tests = [text.split(' - ', 1)[0] for text in excerpts if text.startswith('FAILED ') and '::' in text]
    for text in named_tests or excerpts:
        text = re.sub(r'\b[0-9a-f]{7,40}\b', '<hash>', text)
        text = re.sub(r'\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b', '<id>', text)
        text = re.sub(r':\d+(?::\d+)?', ':<line>', text)
        text = re.sub(r'\b\d+\.\d+\b', '<number>', text)
        normalized.append(text)
    return {'steps': steps, 'evidence': 'log' if excerpts else 'step', 'diagnosticVersion': 1,
            'excerpt': '\n'.join(excerpts), 'signature': digest([steps, normalized]),
            'stepKey': digest(steps)}


def series_key(repo, run):
    # PR and push runs are separate recovery lanes; forks cannot heal each other.
    return digest([repo.lower(), run.get('workflow_id', run.get('path')),
                   run.get('head_branch'), run.get('event'),
                   (run.get('head_repository') or {}).get('id')])


def run_order(run):
    return (run.get('created_at', ''), int(run.get('run_number') or 0), int(run.get('run_attempt') or 1))


def collect_repo(api, repo, prior):
    data = api.get('repos/' + repo + '/actions/runs?per_page=' + str(MAX_RUNS))
    runs = data.get('workflow_runs')
    if not isinstance(runs, list):
        raise RuntimeError('GitHub returned an invalid run list')
    lanes = {}
    for run in sorted(runs, key=run_order, reverse=True):
        lanes.setdefault(series_key(repo, run), []).append(run)
    open_prs = None
    if any(history[0].get('event') == 'pull_request' for history in lanes.values()):
        try:
            pulls = api.get('repos/' + repo + '/pulls?state=open&per_page=100')
            if isinstance(pulls, list) and len(pulls) < 100:
                open_prs = pulls
        except (RuntimeError, OSError, ValueError):
            pass  # Unknown PR state does not dismiss an incident.
    samples = []
    evidence_budget = 8
    for series, history in lanes.items():
        run = history[0]
        attempt = str(run['id']) + ':' + str(run.get('run_attempt', 1))
        sample = {'series': series, 'repo': repo, 'workflow': scrub(run.get('name', 'CI')),
                  'branch': scrub(run.get('head_branch') or ''), 'event': run.get('event', ''),
                  'runId': run['id'], 'attempt': attempt, 'order': list(run_order(run)),
                  'url': 'https://github.com/' + repo + '/actions/runs/' + str(run['id']),
                  'sha': run.get('head_sha', ''), 'status': run.get('status'),
                  'conclusion': run.get('conclusion'), 'observedAt': now(), 'streak': 0}
        if run.get('event') == 'pull_request' and open_prs is not None:
            numbers = {pr['number'] for pr in run.get('pull_requests', [])}
            origin = (run.get('head_repository') or {}).get('id')
            if numbers or origin:
                sample['activePR'] = any(pr['number'] in numbers or
                    (pr.get('head', {}).get('ref') == run.get('head_branch') and
                     (pr.get('head', {}).get('repo') or {}).get('id') == origin)
                    for pr in open_prs)
        for previous in history:
            if previous.get('status') != 'completed' or previous.get('conclusion') not in FAILED:
                break
            sample['streak'] += 1
        if sample['status'] == 'completed' and sample['conclusion'] in FAILED and sample.get('activePR') is not False:
            cached = next((i for i in prior if i['series'] == series and i['attempt'] == attempt and i.get('diagnosticVersion') == 1), None)
            if cached:
                sample.update({k: cached[k] for k in ('steps', 'evidence', 'excerpt', 'signature', 'stepKey', 'diagnosticVersion')})
            elif evidence_budget:
                sample.update(failure_evidence(api, repo, run))
                evidence_budget -= 1
            else:
                sample.update(steps=[sample['workflow']], evidence='workflow', excerpt='',
                              signature=digest(sample['workflow']), stepKey=digest(sample['workflow']))
        samples.append(sample)
    return {'repo': repo, 'observedAt': now(), 'runsRead': len(runs),
            'limited': data.get('total_count', 0) > len(runs), 'error': None, 'samples': samples}


def reconcile(state, collections, notify=False, timestamp=None):
    stamp = timestamp or now()
    issues = {i['id']: dict(i) for i in state.get('incidents', [])}
    events = {e['id']: e for e in state.get('events', [])}
    baseline = state.get('initialized', False)
    for collection in collections:
        if collection.get('error'):
            continue
        visible_series = {s['series'] for s in collection['samples']}
        for issue in issues.values():
            if issue['repo'].lower() == collection['repo'].lower() and issue['state'] == 'open' and issue['series'] not in visible_series:
                issue['tracking'] = 'not_observed'
        for sample in collection['samples']:
            related = [i for i in issues.values() if i['series'] == sample['series'] and i['state'] == 'open']
            if sample.get('activePR') is False:
                for issue in related:
                    issue.update(state='inactive', tracking='closed_pr')
                continue
            if sample['status'] != 'completed' or sample['conclusion'] not in FAILED | {'success'}:
                for issue in related:
                    issue['tracking'] = sample['status'] if sample['status'] != 'completed' else sample['conclusion']
                continue
            if sample['conclusion'] == 'success':
                for issue in related:
                    if tuple(sample['order']) <= tuple(issue['order']):
                        continue
                    issue.update(state='recovered', recoveredAt=stamp, recoveryURL=sample['url'],
                                 recoveryOrder=sample['order'], tracking='success')
                    if notify and baseline:
                        eid = digest([issue['id'], 'recovered', sample['attempt']])
                        events[eid] = {'id': eid, 'incidentId': issue['id'], 'kind': 'recovered', 'repo': issue['repo']}
                continue
            if sample['evidence'] != 'log':
                prior = next((i for i in related if i['stepKey'] == sample['stepKey']), None)
                if prior:
                    sample = dict(sample, **{k: prior[k] for k in ('signature', 'excerpt', 'evidence')})
            iid = digest([sample['series'], sample['signature']])
            old = issues.get(iid)
            if old and old.get('recoveryOrder') and tuple(sample['order']) <= tuple(old['recoveryOrder']):
                continue
            if old and tuple(sample['order']) < tuple(old['order']):
                continue
            fresh = old is None or old['state'] != 'open'
            # A changed diagnostic supersedes the previous symptom, but is not a green recovery.
            for issue in related:
                if issue['id'] != iid and tuple(sample['order']) >= tuple(issue['order']):
                    issue.update(state='changed', tracking='changed', changedAt=stamp)
            count = old.get('observedFailures', 0) if old else 0
            if old is None or old['attempt'] != sample['attempt']:
                count += 1
            issues[iid] = dict(sample, id=iid, state='open', tracking='failure',
                               firstSeen=old['firstSeen'] if old else stamp,
                               lastSeen=stamp, observedFailures=count)
            if fresh and notify and baseline:
                eid = digest([iid, 'failure', sample['attempt']])
                events[eid] = {'id': eid, 'incidentId': iid, 'kind': 'failure', 'repo': sample['repo']}
    state['incidents'] = sorted(issues.values(), key=lambda i: i['lastSeen'], reverse=True)[:250]
    # Do not deliver obsolete failure alerts after recovery/change before delivery.
    state['events'] = [e for e in events.values() if e['incidentId'] in issues and
                       ((e['kind'] == 'failure' and issues[e['incidentId']]['state'] == 'open') or
                        (e['kind'] == 'recovered' and issues[e['incidentId']]['state'] == 'recovered'))][-100:]
    state['initialized'] = baseline or any(not c.get('error') for c in collections)
    state['checkedAt'] = stamp
    state['repositories'] = [{k: v for k, v in c.items() if k != 'samples'} for c in collections]
    return state


def empty_state():
    return {'version': 1, 'initialized': False, 'checkedAt': None, 'incidents': [],
            'events': [], 'repositories': [], 'projects': {}, 'tracked': [], 'discoveryError': None}


class Store:
    def __init__(self, root=None):
        self.root = root or Path.home() / 'Library/Application Support/Modore/ci'

    def read(self):
        path = self.root / 'state.json'
        if not path.exists() and not path.is_symlink():
            return empty_state()
        if self.root.is_symlink() or path.is_symlink() or path.stat().st_uid != os.getuid() or path.stat().st_size > 4_000_000:
            raise RuntimeError('CI state is not a safe local file')
        state = json.loads(path.read_text())
        if state.get('version') != 1:
            raise RuntimeError('Unsupported CI state version')
        return state

    @contextlib.contextmanager
    def locked(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.root.is_symlink() or self.root.stat().st_uid != os.getuid():
            raise RuntimeError('CI state directory is not owned by this user')
        fd = os.open(str(self.root / 'lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)

    def write(self, state):
        fd, name = tempfile.mkstemp(prefix='.state-', dir=self.root)
        try:
            with os.fdopen(fd, 'w') as output:
                json.dump(state, output, ensure_ascii=False)
                output.flush()
                os.fsync(output.fileno())
            os.replace(name, self.root / 'state.json')
        finally:
            if os.path.exists(name):
                os.unlink(name)


def refresh(state, request, api):
    projects = {slug(k): v for k, v in state.get('projects', {}).items()}
    repos = [slug(r) for r in request.get('repos', [])]
    project_deadline = time.monotonic() + 12
    for path in request.get('projects', [])[:80]:
        if time.monotonic() > project_deadline:
            break
        repo = project_repo(path)
        if repo:
            projects.setdefault(repo, [])
            if path not in projects[repo]:
                projects[repo] = (projects[repo] + [path])[-8:]
            repos.append(repo)
    repos.extend(slug(r) for r in state.get('tracked', []))
    discovery_error = None
    if request.get('discover', False):
        try:
            notifications = api.get('notifications?all=true&per_page=100')
            if not isinstance(notifications, list):
                raise RuntimeError('Invalid notification response')
            repos.extend(slug(n['repository']['full_name']) for n in notifications
                         if n.get('subject', {}).get('type') == 'CheckSuite')
        except (RuntimeError, ValueError, KeyError) as error:
            discovery_error = scrub(error)
    repos = list(dict.fromkeys(repos))
    state['repositoryLimitReached'] = len(repos) > MAX_REPOS
    repos = repos[:MAX_REPOS]
    def collect(repo):
        try:
            return collect_repo(api, repo, state.get('incidents', []))
        except (RuntimeError, OSError, ValueError, KeyError) as error:
            return {'repo': repo, 'observedAt': None, 'runsRead': 0, 'limited': False,
                    'error': scrub(error), 'samples': []}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        collections = list(pool.map(collect, repos))
    state.update(projects=projects, tracked=repos, discoveryError=discovery_error)
    return reconcile(state, collections, notify=request.get('notify', False))


def invoke(request, store=None, api=None):
    store = store or Store()
    action = request.get('action', 'status')
    if action == 'status':
        return store.read()
    with store.locked():
        state = store.read()
        if action == 'refresh':
            state = refresh(state, request, api or GitHub())
        elif action == 'ack':
            ids = set(request.get('ids', []))
            state['events'] = [e for e in state['events'] if e['id'] not in ids]
        else:
            raise ValueError('Unknown CI action')
        store.write(state)
        return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', choices=['status', 'refresh'], default='status')
    parser.add_argument('--repo', action='append', default=[])
    parser.add_argument('--project', action='append', default=[])
    parser.add_argument('--discover', action='store_true')
    parser.add_argument('--request-file')
    args = parser.parse_args()
    try:
        if args.request_file:
            with open(args.request_file) as source:
                request = json.loads(source.read(100_000))
        else:
            request = {'action': args.action, 'repos': args.repo, 'projects': args.project, 'discover': args.discover}
        print(json.dumps(invoke(request), ensure_ascii=False))
    except (RuntimeError, ValueError, OSError, KeyError, TypeError) as error:
        print(json.dumps({'error': scrub(error)}, ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
