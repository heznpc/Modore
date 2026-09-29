#!/usr/bin/env python3
"""Reuse installed npm CLIs without invoking an installer or scanning file trees."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile
import time

PACKAGE = re.compile(r'^(?P<name>(?:@[a-z0-9._-]+/)?[a-z0-9._-]+)(?:@(?P<version>[^/\s]+))?$')
EXACT = re.compile(r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')
MAX_ENTRIES = 512


def split_spec(spec):
    match = PACKAGE.fullmatch(spec)
    if not match or '..' in match['name']:
        raise ValueError('npm package name and optional exact version required')
    return match['name'], match['version']


def inventory(spec, home=None, global_roots=None):
    name, requested = split_spec(spec)
    home = Path.home() if home is None else Path(home)
    roots = [Path(p) for p in (global_roots if global_roots is not None else
                              ['/opt/homebrew/lib/node_modules', '/usr/local/lib/node_modules'])]
    cache_root = os.environ.get('npm_config_cache') if home == Path.home() else None
    cache = (Path(cache_root).expanduser() if cache_root else home / '.npm') / '_npx'
    warnings = []
    entries = []
    if cache.is_dir():
        with os.scandir(cache) as scan:
            for entry in scan:
                if entry.is_dir(follow_symlinks=False):
                    entries.append(Path(entry.path) / 'node_modules')
                    if len(entries) > MAX_ENTRIES:
                        warnings.append('npm cache inventory limit reached; coverage is partial')
                        break
    roots += sorted(entries)[:MAX_ENTRIES]
    installed = []
    seen = set()
    for root in roots:
        folder = root / name
        manifest = folder / 'package.json'
        try:
            if manifest.stat().st_size > 1_048_576:
                warnings.append('oversized package manifest skipped')
                continue
            data = json.loads(manifest.read_text())
            if not isinstance(data, dict):
                warnings.append('invalid package manifest skipped')
                continue
            if data.get('name') != name or not EXACT.fullmatch(str(data.get('version', ''))):
                continue
            bins = data.get('bin', {})
            if isinstance(bins, str):
                bins = {name.rsplit('/', 1)[-1]: bins}
            if not isinstance(bins, dict):
                continue
            valid = {}
            for key, relative in bins.items():
                if not isinstance(relative, str):
                    continue
                target = (folder / relative).resolve()
                if folder.resolve() in target.parents and target.is_file():
                    valid[key] = str(target)
            identity = str(folder.resolve())
            if not valid or identity in seen:
                continue
            seen.add(identity)
            installed.append({'package': name, 'version': data['version'],
                              'path': identity, 'bins': valid})
        except FileNotFoundError:
            continue
        except (OSError, ValueError, TypeError):
            warnings.append('unreadable package manifest skipped')
    groups = {}
    for item in installed:
        groups.setdefault(item['version'], []).append(item['path'])
    return {'package': name, 'requestedVersion': requested, 'installed': installed,
            'duplicates': {v: paths for v, paths in groups.items() if len(paths) > 1},
            'warnings': warnings, 'installsPackages': False}


def resolve(spec, home=None, global_roots=None):
    result = inventory(spec, home, global_roots)
    name, requested = split_spec(spec)
    rows = result['installed']
    if requested is not None:
        if not EXACT.fullmatch(requested):
            raise ValueError('Tags/ranges are not resolved offline. Use tools status and choose an exact installed version.')
        rows = [row for row in rows if row['version'] == requested]
    versions = {row['version'] for row in rows}
    if not rows:
        raise ValueError('No installed CLI matches. Nothing was downloaded; provision the required version explicitly.')
    if len(versions) > 1:
        raise ValueError('Multiple installed versions exist; specify package@exact-version.')
    # Global installations take precedence, then the deterministic npm-cache path.
    chosen = rows[0]
    name_key = name.rsplit('/', 1)[-1]
    bins = chosen['bins']
    if name_key in bins:
        entry = bins[name_key]
    elif len(set(bins.values())) == 1:
        entry = next(iter(bins.values()))
    else:
        raise ValueError('Package has multiple CLI entrypoints; automatic selection is ambiguous.')
    return {**chosen, 'entrypoint': entry, 'reused': True, 'copiesFound': len(rows)}


def invocation_specs(command):
    """Recognize direct npx/npm-exec commands, not quoted data or script bodies.

    This is a guardrail, not a shell interpreter or an OS execution boundary.
    Only Vercel is guarded initially; project dependencies are outside this path.
    """
    if not isinstance(command, str) or len(command) > 131_072:
        return []
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|()<>\n')
        lexer.whitespace = ' \t\r'
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return []
    segments, part = [], []
    for token in tokens:
        if token and all(c in ';&|()<>\n' for c in token):
            if part:
                segments.append(part)
            part = []
        else:
            part.append(token)
    if part:
        segments.append(part)
    found = []
    for args in segments:
        while args and (re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', args[0]) or args[0] in ('env', 'command')):
            args = args[1:]
        if not args:
            continue
        exe = Path(args[0]).name
        if exe == 'npx':
            args = args[1:]
        elif exe == 'npm' and len(args) > 1 and args[1] in ('exec', 'x'):
            args = args[2:]
        else:
            continue
        candidates = []
        while args:
            word, args = args[0], args[1:]
            if word in ('--yes', '-y', '--no', '--offline', '--no-install') or word.startswith('--yes='):
                continue
            if word.startswith('--package='):
                candidates.append(word.partition('=')[2])
                continue
            if word in ('--package', '-p') and args:
                candidates.append(args.pop(0))
                continue
            if word in ('--cache', '--registry', '--userconfig') and args:
                args.pop(0)
                continue
            if word.startswith(('--cache=', '--registry=', '--userconfig=')):
                continue
            if word == '--':
                if args and not candidates:
                    candidates.append(args[0])
                break
            if not word.startswith('-') and not candidates:
                candidates.append(word)
            break
        for candidate in candidates:
            if candidate == 'vercel' or candidate.startswith('vercel@'):
                try:
                    split_spec(candidate)
                    found.append(candidate)
                except ValueError:
                    pass
    return found


def guard(payload, home=None, global_roots=None):
    if payload.get('hook_event_name') != 'PreToolUse' or payload.get('tool_name') not in ('Bash', 'exec_command'):
        return {}
    args = payload.get('tool_input', {})
    if not isinstance(args, dict):
        return {}
    for spec in invocation_specs(args.get('command', args.get('cmd'))):
        data = inventory(spec, home, global_roots)
        _, requested = split_spec(spec)
        if requested not in (None, 'latest') and not EXACT.fullmatch(requested):
            # Do not recommend an incompatible installed version for a range/tag.
            continue
        rows = data['installed']
        if requested and EXACT.fullmatch(requested):
            rows = [row for row in rows if row['version'] == requested]
        if not rows:
            continue
        versions = sorted({row['version'] for row in rows})
        commands = ', '.join('modore tools run vercel@' + version + ' -- <arguments>' for version in versions)
        reason = ('Modore: Vercel is already installed. Avoid another npx cache installation; reuse it with '
                  + commands + '. For a required upgrade, verify and request its exact version. '
                  'An installed version is not proof that it is the registry latest version.')
        return {'hookSpecificOutput': {'hookEventName': 'PreToolUse',
                'permissionDecision': 'deny', 'permissionDecisionReason': reason}}
    return {}


def adapter_sha256():
    # The native service supplies the digest of its sealed companion bytes.
    return globals().get('_ADAPTER_SHA256') or hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def receipt_path(provider, home=None):
    home = Path.home() if home is None else Path(home)
    return home / 'Library/Application Support/Modore/work-resources' / ('tool-guard-' + provider + '.json')


def record_hook(provider, payload, result, home=None, now=None):
    """Adapter observation, never an assertion that the host enforced a denial.

    No command text, arguments, cwd, session ID or transcript is retained.
    """
    if provider not in ('codex', 'claude') or payload.get('hook_event_name') != 'PreToolUse':
        return
    if payload.get('tool_name') not in ('Bash', 'exec_command'):
        return
    path = receipt_path(provider, home)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.is_symlink() or path.is_symlink():
        raise ValueError('Unsafe receipt path')
    value = {'observedAt': time.time() if now is None else now,
             'event': 'PreToolUse', 'tool': payload['tool_name'],
             'outcome': 'deny' if result.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny' else 'pass',
             'adapterSHA256': adapter_sha256(),
             'hostEnforcementVerified': False}
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f); f.flush()
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def hook_receipt(provider, home=None, now=None, changed_at=0):
    now = time.time() if now is None else now
    result = {'recentlyObserved': False, 'lastObservedAt': None, 'outcome': None,
              'hostEnforcementVerified': False}
    path = receipt_path(provider, home)
    try:
        if not path.exists():
            return result
        if path.is_symlink() or path.parent.is_symlink() or path.stat().st_size > 4096:
            raise ValueError('Unsafe receipt')
        value = json.loads(path.read_text())
        at = value.get('observedAt')
        if not isinstance(at, (int, float)) or not 0 < at <= now:
            raise ValueError('Invalid receipt timestamp')
        if value.get('outcome') not in ('deny', 'pass'):
            raise ValueError('Invalid receipt outcome')
        current = value.get('adapterSHA256') == adapter_sha256()
        result.update(lastObservedAt=at, outcome=value['outcome'],
                      recentlyObserved=current and at >= changed_at and now - at <= 900)
    except (OSError, ValueError, TypeError, AttributeError):
        result['error'] = 'CLI reuse receipt unavailable'
    return result


def node_binary():
    for p in [Path('/opt/homebrew/bin/node'), Path('/usr/local/bin/node')]:
        if p.is_file() and os.access(p, os.X_OK):
            return str(p.resolve())
    raise ValueError('An installed Node.js runtime is required; no runtime was downloaded.')


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ['hook']:
        hook_parser = argparse.ArgumentParser(description='Receive a PreToolUse event on stdin')
        hook_parser.add_argument('--provider', choices=['codex', 'claude'])
        hook_args = hook_parser.parse_args(argv[1:])
        try:
            raw = sys.stdin.buffer.read(2_097_153)
            if len(raw) > 2_097_152:
                raise ValueError('hook payload too large')
            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise ValueError('hook payload must be an object')
            result = guard(payload)
            try:
                record_hook(hook_args.provider, payload, result)
            except (OSError, ValueError):
                # Observability failure must never erase a computed denial.
                result['systemMessage'] = 'Modore: CLI guard receipt could not be saved.'
        except Exception:
            result = {'systemMessage': 'Modore: CLI reuse check unavailable; duplicate-install protection is unverified.'}
        print(json.dumps(result, ensure_ascii=False))
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['status', 'resolve', 'run'])
    parser.add_argument('package', nargs='?', default='vercel')
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        if args.action == 'status':
            result = inventory(args.package)
        else:
            result = resolve(args.package)
        if args.action == 'run':
            node = node_binary()
            rest = args.arguments[1:] if args.arguments[:1] == ['--'] else args.arguments
            env = dict(os.environ)
            env['PATH'] = str(Path(node).parent) + ':/opt/homebrew/bin:/usr/local/bin:' + env.get('PATH', '')
            print('Modore: reusing ' + result['package'] + '@' + result['version'], file=sys.stderr)
            os.execve(node, [node, result['entrypoint'], *rest], env)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ValueError) as exc:
        print(json.dumps({'error': str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
