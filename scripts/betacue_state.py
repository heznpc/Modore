#!/usr/bin/env python3
"""Read BetaCue's explicit local integration snapshot. Never contacts Apple or changes watches."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import stat
from urllib.parse import parse_qsl, urlsplit

MAX_BYTES = 1_048_576
MAX_LIFETIME_SECONDS = 3600
UUID = r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'


def boundary_path():
    return Path.home() / 'Library/Application Support/BetaCue/Integration/snapshot.json'


def _text(value, limit=500, optional=False, allow_empty=False):
    if value is None and optional:
        return None
    if not isinstance(value, str) or (not value and not allow_empty) or len(value) > limit or any(ord(c) < 32 and c not in '\n\t' for c in value):
        raise ValueError('Invalid text')
    return value


def _date(value):
    _text(value, 64)
    result = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('Missing time zone')
    return result.timestamp()


def _array(value, limit):
    if not isinstance(value, list) or len(value) > limit:
        raise ValueError('Invalid collection')
    return value


def safe_url(value, *, watch=False):
    if not isinstance(value, str) or len(value) > 2048:
        return None
    try:
        parts = urlsplit(value)
        if parts.username or parts.password or parts.port or parts.fragment:
            return None
        if watch:
            if parts.scheme != 'betacue' or parts.path:
                return None
            if parts.netloc == 'watch' and not parts.query:
                return value
            query = parse_qsl(parts.query, keep_blank_values=True)
            if parts.netloc == 'app' and len(query) == 1 and query[0][0] == 'id' and re.fullmatch(r'[A-Za-z0-9_-]{1,200}', query[0][1]):
                return value
            return None
        if parts.query:
            return None
        if parts.scheme == 'codex' and parts.netloc == 'threads' and re.fullmatch('/' + UUID, parts.path):
            return value
        prefixes = {'chatgpt.com': '/c/', 'claude.ai': '/chat/'}
        prefix = prefixes.get(parts.netloc)
        if parts.scheme == 'https' and prefix and re.fullmatch(re.escape(prefix) + UUID, parts.path):
            return value
    except ValueError:
        pass
    return None


def _build(value):
    if value is None:
        return None
    return {'id': _text(value['id'], 200), 'number': _text(value['number'], 200),
            'marketingVersion': _text(value.get('marketingVersion'), 200, optional=True),
            'displayVersion': _text(value['displayVersion'], 500)}


def normalize(value):
    """Project only the public integration fields; unknown content never reaches an agent."""
    if type(value.get('schemaVersion')) is not int or value['schemaVersion'] != 1 or value.get('producer') != 'BetaCue':
        raise ValueError('Unsupported snapshot')
    generated, expires = _date(value['generatedAt']), _date(value['expiresAt'])
    if not 0 < expires - generated <= MAX_LIFETIME_SECONDS:
        raise ValueError('Invalid lifetime')
    runtime = value['runtime']
    heartbeat = _date(runtime['heartbeatAt'])
    if runtime['state'] not in ('running', 'stopped') or type(runtime['pid']) is not int or runtime['pid'] <= 0 or abs(heartbeat - generated) > 60:
        raise ValueError('Invalid runtime')
    apps = []
    for app in _array(value['apps'], 200):
        _date(app['fetchedAt'])
        if type(app['partial']) is not bool:
            raise ValueError('Invalid coverage')
        status = app['status']
        apps.append({'id': _text(app['id'], 200), 'name': _text(app['name']),
                     'bundleID': _text(app['bundleID'], 500), 'latestBuild': _build(app.get('latestBuild')),
                     'status': {'code': _text(status['code'], 200), 'headline': _text(status['headline']),
                                'description': _text(status['description'], 4000)},
                     'fetchedAt': app['fetchedAt'], 'partial': app['partial']})
    if len({app['id'] for app in apps}) != len(apps):
        raise ValueError('Duplicate apps')
    watch = value.get('watch')
    if watch is not None:
        goal = watch['goal']
        if goal['channel'] not in ('any', 'internal', 'external') or watch['phase'] not in ('waitingForUpload', 'processing', 'waitingForApple', 'needsAction', 'ready', 'unavailable'):
            raise ValueError('Invalid watch')
        _date(watch['startedAt'])
        if watch.get('observedAt') is not None:
            _date(watch['observedAt'])
        watch = {'id': _text(watch['id'], 200), 'appID': _text(watch['appID'], 200),
                 'appName': _text(watch['appName']), 'buildID': _text(watch.get('buildID'), 200, optional=True),
                 'goal': {'channel': goal['channel'], 'groupID': _text(goal.get('groupID'), 200, optional=True),
                          'groupName': _text(goal.get('groupName'), 500, optional=True)},
                 'phase': watch['phase'], 'headline': _text(watch['headline']),
                 'detail': _text(watch['detail'], 4000, allow_empty=True),
                 'startedAt': watch['startedAt'], 'observedAt': watch.get('observedAt'),
                 'evidence': [_text(item, 2000) for item in _array(watch.get('evidence', []), 30)],
                 'openURL': safe_url(watch.get('openURL'), watch=True)}
    records = []
    for record in _array(value['workRecords'], 100):
        _date(record['createdAt'])
        records.append({'id': _text(record['id'], 200), 'title': _text(record['title']),
                        'threadID': _text(record.get('threadID'), 200, optional=True),
                        'url': safe_url(record.get('url')),
                        'projectPath': _text(record.get('projectPath'), 4096, optional=True),
                        'appID': _text(record.get('appID'), 200, optional=True),
                        'watchID': _text(record.get('watchID'), 200, optional=True),
                        'connectionID': _text(record.get('connectionID'), 200, optional=True),
                        'createdAt': record['createdAt']})
    if len({record['id'] for record in records}) != len(records):
        raise ValueError('Duplicate records')
    return {'schemaVersion': 1, 'producer': 'BetaCue', 'generatedAt': value['generatedAt'],
            'expiresAt': value['expiresAt'], 'connectionID': _text(value.get('connectionID'), 200, optional=True),
            'runtime': {'instanceID': _text(runtime['instanceID'], 200), 'pid': runtime['pid'],
                        'state': runtime['state'], 'heartbeatAt': runtime['heartbeatAt']},
            'apps': apps, 'watch': watch, 'workRecords': records,
            'issues': [_text(item, 200) for item in _array(value['issues'], 50)]}


def _read(path):
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        meta = os.fstat(parent)
        if meta.st_uid != os.getuid() or meta.st_mode & 0o077:
            raise ValueError('Snapshot directory is not private')
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
        try:
            meta = os.fstat(fd)
            if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o077 or meta.st_size > MAX_BYTES:
                raise ValueError('Snapshot is not a private bounded file')
            chunks = bytearray()
            while len(chunks) <= MAX_BYTES:
                block = os.read(fd, min(65536, MAX_BYTES + 1 - len(chunks)))
                if not block:
                    return bytes(chunks)
                chunks.extend(block)
            raise ValueError('Snapshot too large')
        finally:
            os.close(fd)
    finally:
        os.close(parent)


def status(path=None, now=None):
    now = datetime.datetime.now(datetime.timezone.utc).timestamp() if now is None else now
    try:
        snapshot = normalize(json.loads(_read(path or boundary_path())))
    except FileNotFoundError:
        return {'available': False, 'freshness': 'missing', 'message': 'BetaCue has not published a local snapshot.'}
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError):
        return {'available': False, 'freshness': 'invalid', 'message': 'BetaCue snapshot is unreadable or does not satisfy the integration contract.'}
    generated, expires = _date(snapshot['generatedAt']), _date(snapshot['expiresAt'])
    freshness = 'stopped' if snapshot['runtime']['state'] == 'stopped' else ('current' if generated <= now + 60 and expires > now else 'stale')
    return {'available': True, 'freshness': freshness, 'snapshot': snapshot}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', choices=['status'], default='status')
    parser.parse_args()
    print(json.dumps(status(), ensure_ascii=False))


if __name__ == '__main__':
    main()
