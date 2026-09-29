#!/usr/bin/env python3
"""Modore session catalog v1: bounded local metadata, no execution authority."""
from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import time

# Support both ordinary source execution and python -I -B.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import scree

SCHEMA_VERSION = 1
DEFAULT_BUDGET_SECONDS = 30.0
PROVIDERS = {"Codex": "codex", "Claude": "claude", "Claude Desktop": "claude-desktop",
             "Gemini": "gemini"}
STORE_CODES = {**PROVIDERS, **scree.VSCODE_PROVIDER_IDS}


def _text(value, maximum=4096):
    if (not isinstance(value, str) or not value.strip() or len(value) > maximum
            or any(ord(c) < 32 or ord(c) == 127 for c in value)
            or not scree._is_utf8_text(value)):
        return None
    return value


def _path(path: Path) -> Path:
    # Do not resolve provider-controlled symlinks or network mounts. The scree
    # collectors enforce their own no-follow traversal at read time.
    return scree._physical_macos_root_alias(Path(os.path.abspath(path.expanduser())))


def _digest(parts) -> str:
    return hashlib.sha256(json.dumps(parts, ensure_ascii=True,
                                    separators=(",", ":")).encode()).hexdigest()


def _timestamp(value):
    if type(value) not in (float, int):
        return None
    try:
        if not math.isfinite(value):
            return None
        return datetime.fromtimestamp(value, timezone.utc).isoformat(
            timespec="microseconds").replace("+00:00", "Z")
    except (ValueError, OverflowError, OSError):
        return None


def _project(records, stores, home, profiles, errors):
    """Project whitelisted in-memory records; never open a session source."""
    grouped = defaultdict(list)
    identities = defaultdict(set)
    truncated = False
    for store in stores:
        code = STORE_CODES.get(store.get("store"), "discovery")
        status = store.get("status")
        if status not in ("ok", "missing"):
            safe_status = status if status in ("unreadable", "truncated", "unrecognized") else "unknown"
            errors.add(f"{code}:scan-{safe_status}")
        if store.get("unrecognized", 0):
            errors.add(f"{code}:unrecognized-metadata")
        truncated |= status == "truncated"

    for record in records:
        if record.get("kind") != "session":
            continue  # Editor workspace state is not a provider conversation.
        provider = PROVIDERS.get(record.get("tool"))
        source = _text(record.get("source"))
        if provider is None or source is None:
            errors.add("discovery:invalid-session-metadata")
            continue
        source_path = _path(Path(source))
        profile_key = None
        if provider == "codex":
            namespace = record.get("_catalog_root", str(home / ".codex"))
            profile_key = profiles.get(namespace)
        elif provider == "claude-desktop":
            # Desktop account/organization directories are independent unknown
            # profiles. Never merge identical IDs across these namespaces.
            namespace = str(source_path.parent)
        elif provider == "claude":
            namespace = str(home / ".claude")
        else:
            namespace = str(home / ".gemini")
        session_id = _text(record.get("session_id"), 256)
        if provider == "claude" and scree.CODEX_SESSION_ID_RE.fullmatch(source_path.stem):
            # Claude's top-level source filename is its durable UUID. Never
            # search messages for another ID, a title, or parent/child links.
            session_id = source_path.stem
        key = "modore:v1:" + _digest([
            provider, profile_key, namespace,
            ["session", session_id] if session_id else ["source", str(source_path)],
        ])
        if session_id:
            identities[(provider, session_id)].add((profile_key, namespace))
        grouped[key].append((record, provider, session_id, profile_key))

    for (provider, _), scopes in identities.items():
        if len(scopes) > 1:
            errors.add(f"{provider}:session-id-in-multiple-scopes")

    sessions = []
    for key, fragments in sorted(grouped.items()):
        _, provider, session_id, profile_key = fragments[0]
        workspaces = {_text(r.get("workspace")) for r, *_ in fragments}
        workspaces.discard(None)
        if len(workspaces) > 1:
            errors.add(f"session:{key}:workspace-conflict")
        times = [_timestamp(r.get("last_active")) for r, *_ in fragments]
        if any(value is None for value in times):
            errors.add(f"session:{key}:invalid-timestamp")
        valid_times = [value for value in times if value is not None]
        item = {
            "key": key,
            "provider": provider,
            "providerSessionId": session_id,
            "profileKey": profile_key,
            "workspacePath": next(iter(workspaces)) if len(workspaces) == 1 else None,
            "lastActivityAt": max(valid_times) if valid_times else None,
            "provenance": "local-metadata",
        }
        titles = {_text(r.get("desktop_metadata", {}).get("title")) for r, *_ in fragments}
        titles.discard(None)
        if len(titles) == 1:
            item["title"] = next(iter(titles))
        sessions.append(item)
    sessions.sort(key=lambda item: (item["lastActivityAt"] or "", item["key"]), reverse=True)
    return {"sessions": sessions, "scan": {
        "complete": not errors, "truncated": truncated, "errors": sorted(errors),
    }}


def _collect(home: Path, codex_profiles):
    records, stores = scree.collect_session_metadata(home)
    errors = set()
    roots = defaultdict(set)
    labels = defaultdict(set)
    for label, root in codex_profiles:
        root = str(_path(root))
        roots[root].add(label)
        labels[label].add(root)
    profiles = {}
    for root, names in roots.items():
        if len(names) > 1:
            errors.add("codex:profile-root-conflict")
        profiles[root] = next(iter(names)) if len(names) == 1 else None
    if any(len(paths) > 1 for paths in labels.values()):
        errors.add("codex:profile-key-conflict")
    default_root = str(home / ".codex")
    for root in sorted(roots):
        if root == default_root:
            continue  # Label the existing inventory; do not scan it twice.
        extra, coverage = scree.collect_codex(home, store_root=Path(root))
        if coverage.get("status") == "missing":
            errors.add("codex:explicit-profile-missing")
        records.extend({**record, "_catalog_root": root} for record in extra)
        stores.append(coverage)
    if default_root in roots and any(
            store.get("store") == "Codex" and store.get("status") == "missing"
            for store in stores):
        errors.add("codex:explicit-profile-missing")
    return _project(records, stores, home, profiles, errors)


def build_catalog(home: Path, *, codex_profiles=(), limit=0,
                  budget_seconds=DEFAULT_BUDGET_SECONDS):
    """Read only scree metadata, with a hard scan deadline and private scope IDs."""
    if type(limit) is not int or limit < 0:
        raise ValueError("limit must be a nonnegative integer")
    if not math.isfinite(budget_seconds) or not 0 < budget_seconds <= 60:
        raise ValueError("budget must be greater than zero and at most 60 seconds")
    if any(_text(label, 256) is None for label, _ in codex_profiles):
        raise ValueError("profile keys must be bounded nonempty text")
    # Normalize inside the worker: even the explicitly supplied home can be on
    # unavailable storage. No auth/config file is opened to infer an account.
    result, status = scree._isolated_content_json(
        time.monotonic() + budget_seconds,
        lambda: _collect(_path(home), codex_profiles),
        max_bytes=scree.SESSION_INDEX_ISOLATION_MAX_BYTES,
    )
    if result is None:
        result = {"sessions": [], "scan": {
            "complete": False, "truncated": True,
            "errors": [f"discovery:worker-{status}"],
        }}
    if limit and len(result["sessions"]) > limit:
        result["sessions"] = result["sessions"][:limit]
        result["scan"]["complete"] = False
        result["scan"]["truncated"] = True
        result["scan"]["errors"] = sorted(set(result["scan"]["errors"]) | {"catalog:limit"})
    return {"schemaVersion": SCHEMA_VERSION,
            "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "source": "modore", **result}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home(),
                        help="home containing the standard local provider stores")
    parser.add_argument("--codex-profile", action="append", nargs=2, default=[],
                        metavar=("KEY", "ROOT"), help="explicit local Codex profile key and CODEX_HOME; repeatable")
    parser.add_argument("--limit", type=int, default=0, help="maximum logical sessions; 0 means all")
    parser.add_argument("--budget-seconds", type=float, default=DEFAULT_BUDGET_SECONDS)
    parser.add_argument("--out", type=Path, help="create a private 0600 JSON file; never replace an existing file")
    args = parser.parse_args(argv)
    try:
        catalog = build_catalog(args.home,
            codex_profiles=[(label, Path(root)) for label, root in args.codex_profile],
            limit=args.limit, budget_seconds=args.budget_seconds)
        encoded = json.dumps(catalog, ensure_ascii=True, indent=2) + "\n"
        if args.out is None:
            sys.stdout.write(encoded)
        else:
            actual = scree._write_preserve_output(args.out, encoded)
            # The standard scree writer returns a fresh sibling on collision.
            # Report the actual filename, never imply that a stale file changed.
            sys.stdout.write(json.dumps({"outputPath": str(actual), "scan": catalog["scan"]}) + "\n")
    except (OSError, ValueError):
        # Filesystem exception text can contain private names or raw data.
        sys.stderr.write("session-catalog: invalid arguments or private output unavailable\n")
        return 2
    return 0 if catalog["scan"]["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
