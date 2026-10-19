"""QuotaPie profile homes participate in the same Codex session contract."""
import json
import hashlib
import os
import time

import pytest

import scree


SESSION_ID = "01a00000-0000-7000-8000-000000000003"


def profile_home(home, profile="profile-a"):
    return home.joinpath(*scree.QUOTAPIE_CODEX_PROFILES, profile, "home")


def rollout(root, session_id=SESSION_ID):
    path = root / f"2026/10/19/rollout-{session_id}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        {"type": "session_meta", "payload": {"id": session_id, "cwd": "/work/modore"}},
        {"type": "response_item", "timestamp": "2026-10-19T10:00:00Z",
         "payload": {"type": "message", "id": "event-1", "role": "user",
                     "content": [{"type": "input_text", "text": "QuotaPie profile discovery needle"}]}},
    ]
    path.write_text("\n".join(json.dumps(line) for line in lines) + "\n")
    return path


@pytest.mark.parametrize("store", ["sessions", "archived_sessions"])
def test_profile_sessions_can_be_listed_searched_inspected_and_bound(tmp_path, store):
    source = rollout(profile_home(tmp_path) / store)
    index = scree.build_sessions(tmp_path)
    assert index["total"] == 1
    assert index["sessions"][0]["sessionId"] == SESSION_ID
    assert index["sessions"][0]["source"] == str(source)
    assert "discovery needle" not in json.dumps(index)

    current = scree.build_current_session(tmp_path, environ={"CODEX_THREAD_ID": SESSION_ID})
    assert current["found"] is True
    assert current["source"] == str(source)
    assert current["artifactCoverageComplete"] is True

    search = scree.build_search("discovery needle", tmp_path, provider="codex", workspace=("modore",))
    assert search["matches"][0]["sessionId"] == SESSION_ID
    assert search["matches"][0]["source"] == str(source)
    assert search["coverage"] == "complete"
    inspected = scree.build_inspect(source, tmp_path)
    assert inspected["provider"] == "codex"
    assert inspected["sessionId"] == SESSION_ID
    assert inspected["workspace"] == "/work/modore"
    assert inspected["turns"][0]["text"] == "QuotaPie profile discovery needle"
    bindings, complete = scree.bind_codex(tmp_path, "/work/modore", None)
    assert complete is True
    assert bindings[0]["source"] == str(source)
    candidates, coverage = scree._deep_scan_candidates(tmp_path)
    assert coverage["codex"] is True
    assert any(provider == "codex" and candidate.path == source for provider, candidate in candidates)


def test_profile_copies_join_existing_logical_conversation(tmp_path):
    sources = [rollout(tmp_path / ".codex/sessions"),
               rollout(profile_home(tmp_path, "one") / "sessions"),
               rollout(profile_home(tmp_path, "two") / "archived_sessions")]
    index = scree.build_sessions(tmp_path)
    assert index["total"] == 1
    assert index["artifactTotal"] == 3
    assert set(index["sessions"][0]["artifactSources"]) == set(map(str, sources))
    assert scree.build_inspect_many(sources, tmp_path)["messageCount"] == 1
    assert len(scree.build_search("discovery needle", tmp_path)["matches"]) == 1


@pytest.mark.parametrize("linked_component", ["profiles", "profile", "home", "sessions"])
def test_profile_links_are_not_traversed_and_report_incomplete(tmp_path, linked_component):
    home = tmp_path / "user"
    rollout(profile_home(home) / "sessions")
    parts = {"profiles": home.joinpath(*scree.QUOTAPIE_CODEX_PROFILES),
             "profile": profile_home(home).parent,
             "home": profile_home(home), "sessions": profile_home(home) / "sessions"}
    target = parts[linked_component]
    outside = tmp_path / "outside"
    target.rename(outside)
    target.symlink_to(outside, target_is_directory=True)
    records, coverage = scree.collect_codex(home)
    assert records == []
    assert coverage["status"] not in ("ok", "missing")
    assert scree.build_search("discovery needle", home)["coverage"] == "truncated"


def test_profile_enumeration_is_bounded_and_fingerprint_tracks_new_sessions(tmp_path, monkeypatch):
    rollout(profile_home(tmp_path, "one") / "sessions")
    before = scree.store_fingerprint(tmp_path)
    rollout(profile_home(tmp_path, "two") / "archived_sessions", "another-session")
    assert scree.store_fingerprint(tmp_path) != before
    monkeypatch.setattr(scree, "CODEX_PROFILE_MAX_ENTRIES", 1)
    _, coverage = scree.collect_codex(tmp_path)
    assert coverage["status"] == "truncated"
    assert scree.build_search("discovery needle", tmp_path)["coverage"] == "truncated"


def test_profile_listing_remains_metadata_only(tmp_path):
    source = rollout(profile_home(tmp_path) / "sessions")
    header = source.read_text().splitlines()[0]
    source.write_text(header + "\nTHIS BODY IS NOT JSON\n")
    records, coverage = scree.collect_codex(tmp_path)
    assert coverage["status"] == "ok"
    assert records[0]["session_id"] == SESSION_ID


@pytest.mark.parametrize("store", ["sessions", "archived_sessions"])
def test_profile_backup_keeps_exact_source_and_rejects_live_destination(tmp_path, store):
    home = tmp_path / "user"
    source = rollout(profile_home(home) / store)
    archive = tmp_path / "backup.zip"
    result = scree.build_session_backup(source, home, archive, include_sensitive=True)
    assert result["provider"] == "Codex"
    assert scree.verify_session_backup(archive)["sourceRelative"] == str(source.relative_to(home))
    with pytest.raises(ValueError, match="outside the live"):
        scree.build_session_backup(source, home, source.parent / "backup.zip", include_sensitive=True)


def consolidation(home, thread_ids=None):
    home = home.resolve()
    support = home / "Library/Application Support/QuotaPie"
    source_home = profile_home(home)
    source_data = source_home.parent / "app-data"
    primary_home = home / ".codex"
    primary_data = home / "Library/Application Support/Codex"
    for path in (support, source_home, source_data, primary_home, primary_data):
        path.mkdir(parents=True, exist_ok=True)
    manifest = support / "session-consolidation-journal/example/manifest.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text(json.dumps({"version": 1, "sourceHome": str(source_home),
                                    "primaryHome": str(primary_home), "threadIds": thread_ids or [SESSION_ID]}))
    manifest.chmod(0o600)
    marker = support / "session-consolidation.json"
    marker.write_text(json.dumps({
        "version": 1, "state": "complete", "completedAtMs": time.time() * 1000 - 1000,
        "primary": {"codexHome": str(primary_home), "appData": str(primary_data)},
        "sources": [{"codexHome": str(source_home), "appData": str(source_data),
                     "manifestPath": str(manifest), "manifestSHA256": hashlib.sha256(manifest.read_bytes()).hexdigest()}],
    }))
    marker.chmod(0o600)
    return marker, manifest


def copies_with_newer_retired(home):
    primary = rollout(home / ".codex/sessions")
    retired = rollout(profile_home(home) / "sessions")
    os.utime(primary, (100, 100))
    os.utime(retired, (200, 200))
    return primary, retired


def test_completed_manifest_selects_primary_even_if_preserved_source_is_newer(tmp_path):
    primary, retired = copies_with_newer_retired(tmp_path)
    before = scree.store_fingerprint(tmp_path)
    assert scree.build_current_session(tmp_path, environ={"CODEX_THREAD_ID": SESSION_ID})["source"] == str(retired)
    consolidation(tmp_path)
    assert scree.store_fingerprint(tmp_path) != before
    current = scree.build_current_session(tmp_path, environ={"CODEX_THREAD_ID": SESSION_ID})
    assert current["source"] == str(primary)
    assert current["workspace"] == "/work/modore"
    assert set(current["artifactSources"]) == {str(primary), str(retired)}
    assert current["segmentCount"] == 2
    assert current["artifactCoverageComplete"] is True
    index = scree.build_sessions(tmp_path)
    assert index["total"] == 1
    assert index["sessions"][0]["source"] == str(primary)
    assert scree.build_inspect_many([primary, retired], tmp_path)["messageCount"] == 1
    assert retired.stat().st_mtime == 200


@pytest.mark.parametrize("invalid", ["digest", "other-id", "primary", "source-home", "waiting", "writable", "symlink"])
def test_unverified_consolidation_keeps_existing_conservative_selection(tmp_path, invalid):
    primary, retired = copies_with_newer_retired(tmp_path)
    marker, manifest = consolidation(tmp_path, ["01a00000-0000-7000-8000-000000000004"] if invalid == "other-id" else None)
    value = json.loads(marker.read_text())
    if invalid == "digest":
        value["sources"][0]["manifestSHA256"] = "0" * 64
    elif invalid == "primary":
        value["primary"]["codexHome"] = str(profile_home(tmp_path))
    elif invalid == "source-home":
        content = json.loads(manifest.read_text())
        content["sourceHome"] = str(tmp_path / ".codex")
        manifest.write_text(json.dumps(content))
        value["sources"][0]["manifestSHA256"] = hashlib.sha256(manifest.read_bytes()).hexdigest()
    elif invalid == "waiting":
        value["state"] = "waiting-for-source-exit"
    marker.write_text(json.dumps(value))
    if invalid == "writable":
        marker.chmod(0o666)
    elif invalid == "symlink":
        actual = manifest.with_name("actual.json")
        manifest.rename(actual)
        manifest.symlink_to(actual)
    current = scree.build_current_session(tmp_path, environ={"CODEX_THREAD_ID": SESSION_ID})
    assert current["source"] == str(retired)
    assert set(current["artifactSources"]) == {str(primary), str(retired)}


def test_manifest_does_not_authorize_a_missing_primary_or_unrelated_copy(tmp_path):
    primary, retired = copies_with_newer_retired(tmp_path)
    consolidation(tmp_path)
    primary.unlink()
    assert scree.build_current_session(tmp_path, environ={"CODEX_THREAD_ID": SESSION_ID})["source"] == str(retired)
    primary = rollout(tmp_path / ".codex/sessions")
    third = rollout(profile_home(tmp_path, "unrelated") / "sessions")
    os.utime(third, (time.time() + 100, time.time() + 100))
    assert scree.build_current_session(tmp_path, environ={"CODEX_THREAD_ID": SESSION_ID})["source"] == str(third)


def test_manifest_read_revalidates_marker_before_primary_preference(tmp_path, monkeypatch):
    _, retired = copies_with_newer_retired(tmp_path)
    marker, manifest = consolidation(tmp_path)
    original = scree._read_regular_bytes_nofollow
    def replacing_read(path, *args, **kwargs):
        result = original(path, *args, **kwargs)
        if path == manifest:
            marker.write_text(marker.read_text() + " ")
        return result
    monkeypatch.setattr(scree, "_read_regular_bytes_nofollow", replacing_read)
    assert scree.build_current_session(tmp_path, environ={"CODEX_THREAD_ID": SESSION_ID})["source"] == str(retired)
