"""Persistent filtering is an optimization, never an alternative source of truth."""
import json
import os
import random
import sqlite3
import stat
import subprocess
import sys
import time
from pathlib import Path

import pytest

import session_search_index as search_index
from session_search_index import SearchIndex


FINGERPRINT = (1, 2, 100, 123456789, 987654321)
SOURCE = "/work/session.jsonl"


def normalized(text):
    return " ".join(text.split()).casefold()


def require_fts5():
    with sqlite3.connect(":memory:") as connection:
        try:
            connection.execute("CREATE VIRTUAL TABLE capability USING fts5(text, content='', contentless_delete=1, detail=none, tokenize='trigram case_sensitive 1')")
        except sqlite3.OperationalError:
            pytest.skip("SQLite FTS5 trigram + contentless_delete are unavailable")


@pytest.fixture
def index(tmp_path):
    require_fts5()
    value = SearchIndex(tmp_path)
    assert value.available, "supported SQLite must create a usable cache"
    yield value
    value.close()


@pytest.mark.parametrize("text, query", [
    ("exact literal needle in original", "literal needle"),
    ('quote "quoted" and sqlite OR NOT *', '"quoted"'),
    ('syntax a"b then normal', 'a"b'),
    ('three quotes """ are literal', '"""'),
    ("😀🪐🐈 and 👩‍💻 한국어 검색", "😀🪐🐈"),
    ("😀🪐🐈 and 👩‍💻 한국어 검색", "👩‍💻"),
    ("한글 문장 내용을 찾기", "문장 내용을"),
    ("Straße ΣΊΣΥΦΟΣ İSTANBUL", "STRASSE"),
    ("Straße ΣΊΣΥΦΟΣ İSTANBUL", "İSTANBUL"),
    ("combining e\u0301abc characters", "e\u0301abc"),
    ("첫 줄\n\t다음    줄 내용", "줄\n 다음"),
    ("prefix (AND OR) suffix", "(AND OR)"),
    ("prefix back\\slash [tag] *end", "\\slash"),
])
def test_unicode_and_fts_syntax_are_literal_candidates(index, text, query):
    assert index.record(SOURCE, FINGERPRINT, normalized(text))
    assert index.lookup(SOURCE, FINGERPRINT, query) is True


def test_every_unicode_substring_is_recalled_without_full_phrase_positions(index):
    rng = random.Random(716)
    alphabet = list('한글abc XYZ"*()-Σé\u0301😀🪐')
    text = normalized("".join(rng.choice(alphabet) for _ in range(600)))
    assert index.record(SOURCE, FINGERPRINT, text)
    for _ in range(200):
        start = rng.randrange(len(text) - 3)
        query = text[start:start + rng.randrange(3, 80)]
        if len(normalized(query)) >= 3:
            assert index.lookup(SOURCE, FINGERPRINT, query) is True, repr(query)


def test_misses_are_definitive_only_for_exact_fingerprint(index):
    assert index.record(SOURCE, FINGERPRINT, "ordinary original content")
    assert index.lookup(SOURCE, FINGERPRINT, "nonexistent phrase") is False
    assert index.lookup(SOURCE, FINGERPRINT, "original") is True
    for position in range(5):
        changed = tuple(value + int(at == position) for at, value in enumerate(FINGERPRINT))
        assert index.lookup(SOURCE, changed, "nonexistent phrase") is None
    assert index.lookup("/other", FINGERPRINT, "nonexistent phrase") is None
    assert index.stats == {"cacheHits": 2, "rejected": 1, "updated": 1, "unavailable": 0}


def test_literal_candidates_can_be_false_positive_but_are_never_claimed_matches(index):
    assert index.record(SOURCE, FINGERPRINT, "abc elsewhere bcd")
    assert index.lookup(SOURCE, FINGERPRINT, "abcd") is True
    # The caller must still read the transcript: its two necessary trigrams
    # are present but the requested substring is not.
    assert "abcd" not in "abc elsewhere bcd"


@pytest.mark.parametrize("query", ["", "a", "한글", "😀🪐", "a\0b", "a" * 65_537])
def test_unsupported_queries_bypass(index, query):
    assert index.record(SOURCE, FINGERPRINT, "something to search")
    assert index.lookup(SOURCE, FINGERPRINT, query) is None
    assert index.stats["cacheHits"] == 0


def test_same_size_and_mtime_rewrite_is_invalidated_by_ctime(index, tmp_path):
    source = tmp_path / "session.jsonl"
    source.write_text("old needle", encoding="utf-8")
    old = source.stat()
    signature = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    assert index.record(str(source), signature(old), "old needle")
    source.write_text("new needle", encoding="utf-8")
    os.utime(source, ns=(old.st_atime_ns, old.st_mtime_ns))
    updated = source.stat()
    assert updated.st_size == old.st_size
    assert updated.st_mtime_ns == old.st_mtime_ns
    assert updated.st_ctime_ns != old.st_ctime_ns
    assert index.lookup(str(source), signature(updated), "new needle") is None


def test_atomic_replacement_removes_old_postings(index):
    changed = (*FINGERPRINT[:-1], FINGERPRINT[-1] + 1)
    assert index.record(SOURCE, FINGERPRINT, "obsolete purple elephant")
    assert index.record(SOURCE, changed, "replacement orange tiger")
    assert index.lookup(SOURCE, FINGERPRINT, "obsolete") is None
    assert index.lookup(SOURCE, changed, "obsolete") is False
    assert index.lookup(SOURCE, changed, "replacement") is True
    with sqlite3.connect(index.path) as connection:
        assert connection.execute("SELECT count(*) FROM artifacts").fetchone() == (1,)
        assert connection.execute("SELECT count(*) FROM artifact_terms").fetchone() == (1,)


def test_contentless_cache_has_no_original_text_snippets_or_queries(index):
    original = "private transcript with an unusual complete sentence that should never be retained as source text"
    query = "a query whose entire sentence must never be retained"
    assert index.record(SOURCE, FINGERPRINT, original)
    assert index.lookup(SOURCE, FINGERPRINT, query) is False
    with sqlite3.connect(index.path) as connection:
        assert connection.execute("SELECT text FROM artifact_terms").fetchall() == [(None,)]
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert "artifact_terms_content" not in tables
        columns = [row[1] for row in connection.execute("PRAGMA table_info(artifacts)")]
        assert columns == ["id", "source", "fingerprint", "updated"]
        assert "detail=none" in connection.execute("SELECT sql FROM sqlite_master WHERE name='artifact_terms'").fetchone()[0]
    index.close()
    stored = index.path.read_bytes()
    assert original.encode() not in stored
    assert query.encode() not in stored
    assert not index.path.with_name(index.path.name + "-wal").exists()


def test_fresh_process_reuses_existing_postings(index, tmp_path):
    assert index.record(SOURCE, FINGERPRINT, "persisted matching phrase")
    script = """
import json,sys
from pathlib import Path
from session_search_index import SearchIndex
with SearchIndex(Path(sys.argv[1])) as index:
    print(json.dumps([index.available,index.lookup('/work/session.jsonl',(1,2,100,123456789,987654321),'matching phrase'),index.lookup('/work/session.jsonl',(1,2,100,123456789,987654321),'absent phrase'),index.stats]))
"""
    env = {**os.environ, "PYTHONPATH": str(Path(search_index.__file__).parent)}
    processes = [subprocess.Popen([sys.executable, "-c", script, str(tmp_path)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(4)]
    for process in processes:
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stderr
        available, present, absent, stats = json.loads(stdout)
        assert available and present is True and absent is False
        assert stats["cacheHits"] == 2


def test_lock_failure_is_bounded_and_falls_back_without_changing_source(index):
    assert index.record(SOURCE, FINGERPRINT, "existing content")
    lock = sqlite3.connect(index.path, isolation_level=None)
    try:
        lock.execute("BEGIN EXCLUSIVE")
        start = time.monotonic()
        assert index.lookup(SOURCE, FINGERPRINT, "existing") is None
        assert time.monotonic() - start < 1
        assert not index.available
    finally:
        lock.execute("ROLLBACK")
        lock.close()


def test_busy_record_preserves_the_committed_entry(index, tmp_path):
    assert index.record(SOURCE, FINGERPRINT, "existing content")
    lock = sqlite3.connect(index.path, isolation_level=None)
    try:
        lock.execute("BEGIN IMMEDIATE")
        assert not index.record(SOURCE, (*FINGERPRINT[:-1], 111), "replacement content")
    finally:
        lock.execute("ROLLBACK")
        lock.close()
    with SearchIndex(tmp_path) as reopened:
        assert reopened.lookup(SOURCE, FINGERPRINT, "existing") is True


def test_corrupt_and_foreign_schema_fail_open_without_overwriting(tmp_path):
    with SearchIndex(tmp_path) as initial:
        path = initial.path
    path.write_bytes(b"not a sqlite database")
    with SearchIndex(tmp_path) as corrupt:
        assert not corrupt.available
        assert corrupt.lookup(SOURCE, FINGERPRINT, "anything") is None
    assert path.read_bytes() == b"not a sqlite database"
    path.unlink()
    with sqlite3.connect(path) as connection:
        connection.execute("CREATE TABLE user_data(value TEXT)")
        connection.execute("INSERT INTO user_data VALUES('keep')")
    path.chmod(0o600)
    with SearchIndex(tmp_path) as foreign:
        assert not foreign.available
    with sqlite3.connect(path) as connection:
        assert connection.execute("SELECT value FROM user_data").fetchone() == ("keep",)


def test_unsupported_sqlite_extension_fails_open(monkeypatch, tmp_path):
    def unsupported(self):
        raise sqlite3.OperationalError("no such module: fts5")
    monkeypatch.setattr(SearchIndex, "_create_schema", unsupported)
    with SearchIndex(tmp_path) as index:
        assert not index.available
        assert index.lookup(SOURCE, FINGERPRINT, "anything") is None
        assert not index.record(SOURCE, FINGERPRINT, "anything")


def test_parser_version_change_never_trusts_old_postings(index, monkeypatch, tmp_path):
    assert index.record(SOURCE, FINGERPRINT, "old canonical parser text")
    monkeypatch.setattr(search_index, "PARSER_VERSION", "next-visible-parser")
    with SearchIndex(tmp_path) as future:
        assert not future.available
        assert future.lookup(SOURCE, FINGERPRINT, "new parser content") is None


@pytest.mark.parametrize("relative", ["Library", "Library/Caches", "Library/Caches/Modore", "Library/Caches/Modore/session-search"])
def test_symlink_in_directory_chain_is_refused(tmp_path, relative):
    outside = tmp_path / "outside"
    outside.mkdir()
    destination = tmp_path / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.symlink_to(outside, target_is_directory=True)
    with SearchIndex(tmp_path) as index:
        assert not index.available
    assert list(outside.iterdir()) == []


@pytest.mark.parametrize("suffix", ["", "-journal", "-wal", "-shm"])
def test_database_or_sidecar_symlink_is_refused(index, tmp_path, suffix):
    path = index.path
    index.close()
    outside = tmp_path / "untouched"
    outside.write_text("preserve")
    candidate = path.with_name(path.name + suffix)
    if candidate.exists():
        candidate.unlink()
    candidate.symlink_to(outside)
    with SearchIndex(tmp_path) as rejected:
        assert not rejected.available
    assert outside.read_text() == "preserve"
    assert candidate.is_symlink()


def test_new_paths_are_private_and_unsafe_existing_paths_are_not_chmodded(index, tmp_path):
    assert stat.S_IMODE(index.path.stat().st_mode) == 0o600
    assert stat.S_IMODE(index.path.parent.stat().st_mode) == 0o700
    assert stat.S_IMODE(index.path.parent.parent.stat().st_mode) == 0o700
    index.path.chmod(0o644)
    assert index.lookup(SOURCE, FINGERPRINT, "anything") is None
    assert not index.available
    with SearchIndex(tmp_path) as rejected:
        assert not rejected.available
    assert stat.S_IMODE(index.path.stat().st_mode) == 0o644


def test_hardlinked_database_and_world_writable_parent_are_refused(index, tmp_path):
    os.link(index.path, tmp_path / "database-link")
    assert index.lookup(SOURCE, FINGERPRINT, "anything") is None
    assert not index.available
    (tmp_path / "database-link").unlink()
    cache = tmp_path / "Library/Caches"
    cache.chmod(0o777)
    with SearchIndex(tmp_path) as rejected:
        assert not rejected.available
    assert stat.S_IMODE(cache.stat().st_mode) == 0o777


def test_foreign_owner_is_refused_without_touching_paths(index, monkeypatch, tmp_path):
    real_uid = os.geteuid()
    monkeypatch.setattr(search_index.os, "geteuid", lambda: real_uid + 1)
    with SearchIndex(tmp_path) as rejected:
        assert not rejected.available


def test_replaced_database_identity_is_not_used(index):
    path = index.path
    assert index.record(SOURCE, FINGERPRINT, "original content")
    replacement = path.with_name("replacement.sqlite3")
    replacement.write_bytes(path.read_bytes())
    replacement.chmod(0o600)
    os.replace(replacement, path)
    assert index.lookup(SOURCE, FINGERPRINT, "original") is None
    assert not index.available


def test_record_size_limit_leaves_existing_entry_usable(index, monkeypatch):
    assert index.record(SOURCE, FINGERPRINT, "initial content")
    monkeypatch.setattr(search_index, "MAX_TEXT_BYTES", 20)
    assert not index.record(SOURCE, (*FINGERPRINT[:-1], 111), "가" * 10)
    assert index.lookup(SOURCE, FINGERPRINT, "initial") is True
    assert not index.record(SOURCE, FINGERPRINT, "invalid\0text")
    assert index.lookup(SOURCE, FINGERPRINT, "initial") is True


def test_database_capacity_rolls_back_new_record_and_preserves_earlier_rows(tmp_path, monkeypatch):
    monkeypatch.setattr(search_index, "MAX_DB_BYTES", 128 * 1024)
    require_fts5()
    with SearchIndex(tmp_path) as index:
        assert index.available
        assert index.record(SOURCE, FINGERPRINT, "existing small record")
        rng = random.Random(817)
        text = "".join(chr(rng.randrange(0x4E00, 0x9FFF)) for _ in range(100_000))
        assert not index.record("/large", FINGERPRINT, text)
        assert index.available
        assert index.path.stat().st_size <= search_index.MAX_DB_BYTES
        assert index.lookup(SOURCE, FINGERPRINT, "existing") is True
        assert index.lookup("/large", FINGERPRINT, "large") is None


def test_module_is_in_both_mac_release_and_sealed_runtime_allowlists(project_root):
    import release_smoke
    assert "scripts/session_search_index.py" in release_smoke.MACOS_BASE_FILES
    builder = (project_root / "scripts/build_macos_swift_app.sh").read_text()
    assert '"scripts/session_search_index.py"' in builder
