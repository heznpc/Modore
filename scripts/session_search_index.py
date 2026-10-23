#!/usr/bin/env python3
"""Private, optional negative filter for canonical session-content searches.

Only a complete, stable parse may be recorded. The index stores file identity
and FTS5 trigram postings, never query strings, original text, or snippets.
A matching posting is only a candidate: callers still read and verify the
original transcript. Every unavailable/stale result falls back to that reader.
Construct SearchIndex inside the worker process; connections never cross fork.
"""
from __future__ import annotations

import json
import os
import sqlite3
import stat
import time
from pathlib import Path
from typing import Optional

SCHEMA_VERSION = 1
# Bump this whenever canonical visible-turn parsing or normalization changes.
PARSER_VERSION = "visible-turns-1:casefold-whitespace-1:trigram-candidates-1"
APPLICATION_ID = 0x4D445258  # MDRX
MAX_DB_BYTES = 512 * 1024 * 1024
MAX_TEXT_BYTES = 32 * 1024 * 1024
BUSY_TIMEOUT_MS = 100


class SearchIndex:
    """A disposable cache. False is authoritative only for this fingerprint."""

    def __init__(self, home: Path):
        self.stats = {"cacheHits": 0, "rejected": 0, "updated": 0, "unavailable": 0}
        self.path = Path(home) / "Library/Caches/Modore/session-search/index.sqlite3"
        self._pid = os.getpid()
        self._connection: Optional[sqlite3.Connection] = None
        self._directories: list[tuple[int, Optional[int], str, bool]] = []
        self._database_fd: Optional[int] = None
        self._recording_disabled = False
        try:
            if not hasattr(os, "geteuid") or not hasattr(os, "O_NOFOLLOW"):
                raise OSError("private no-follow filesystem operations unavailable")
            self._open_directories(Path(home))
            parent = self._directories[-1][0]
            flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
            try:
                descriptor = os.open("index.sqlite3", flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent)
            except FileExistsError:
                descriptor = os.open("index.sqlite3", flags, dir_fd=parent)
            self._database_fd = descriptor
            self._validate_paths()
            size = os.fstat(descriptor).st_size
            if size > MAX_DB_BYTES:
                raise OSError("index exceeds cache capacity")
            connection = sqlite3.connect(
                self.path.as_uri() + "?mode=rw", uri=True,
                timeout=BUSY_TIMEOUT_MS / 1000, isolation_level=None,
            )
            self._connection = connection
            self._validate_paths()
            connection.execute(f"PRAGMA busy_timeout={BUSY_TIMEOUT_MS}")
            connection.execute("PRAGMA temp_store=MEMORY")
            connection.execute("PRAGMA trusted_schema=OFF")
            if (connection.execute("PRAGMA user_version").fetchone()[0] == 0
                    and connection.execute("PRAGMA application_id").fetchone()[0] == 0
                    and connection.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone() is None):
                self._create_schema()
            self._verify_schema()
            # Avoid a WAL growing independently of the database capacity. A
            # short lock failure disables the cache, never the source search.
            mode = connection.execute("PRAGMA journal_mode=DELETE").fetchone()[0]
            if mode.lower() != "delete":
                raise sqlite3.DatabaseError("unsupported cache journal mode")
            page_size = connection.execute("PRAGMA page_size").fetchone()[0]
            page_count = connection.execute("PRAGMA page_count").fetchone()[0]
            if page_size <= 0 or page_count * page_size > MAX_DB_BYTES:
                raise sqlite3.DatabaseError("index exceeds cache capacity")
            limit = max(1, MAX_DB_BYTES // page_size)
            connection.execute(f"PRAGMA max_page_count={limit}")
            self._validate_paths()
        except (OSError, ValueError, sqlite3.Error):
            self._unavailable()

    @property
    def available(self) -> bool:
        return self._connection is not None and os.getpid() == self._pid

    def close(self) -> None:
        connection, self._connection = self._connection, None
        if connection is not None and os.getpid() == self._pid:
            try:
                connection.close()
            except sqlite3.Error:
                pass
        if self._database_fd is not None:
            os.close(self._database_fd)
            self._database_fd = None
        for descriptor, _, _, _ in reversed(self._directories):
            os.close(descriptor)
        self._directories.clear()

    def __enter__(self) -> SearchIndex:
        return self

    def __exit__(self, *_args) -> None:
        self.close()

    def lookup(self, source: str, fingerprint: tuple, query: str) -> Optional[bool]:
        """None bypasses the filter; False skips only unchanged source bytes."""
        signature = self._signature(source, fingerprint)
        if not self.available or signature is None or not isinstance(query, str):
            return None
        normalized = " ".join(query.split()).casefold()
        # FTS5 does not index one/two-character terms, and NUL terminates its
        # query grammar. Such a query must use the canonical reader instead.
        if len(normalized) < 3 or len(normalized) > 65_536 or "\0" in normalized:
            return None
        count = len(normalized) - 2
        samples = min(32, count)
        positions = (0,) if samples == 1 else (index * (count - 1) // (samples - 1) for index in range(samples))
        trigrams = dict.fromkeys(normalized[index:index + 3] for index in positions)
        # detail=none stores only artifact postings, not token positions. Each
        # sampled trigram is necessary for the literal substring; AND can admit
        # extra candidates but cannot reject a genuine canonical substring.
        literal = " AND ".join('"' + gram.replace('"', '""') + '"' for gram in trigrams)
        try:
            self._validate_paths()
            # One statement gives the fingerprint and posting one SQLite read
            # snapshot. A concurrent replacement cannot splice an old identity
            # together with new postings and cause a false-negative lookup.
            row = self._connection.execute(
                "SELECT t.rowid, EXISTS(SELECT 1 FROM artifact_terms "
                "WHERE artifact_terms MATCH ? AND rowid=a.id) "
                "FROM artifacts a LEFT JOIN artifact_terms t ON t.rowid=a.id "
                "WHERE a.source=? AND a.fingerprint=?",
                (literal, source, signature),
            ).fetchone()
            self._validate_paths()
            if row is None or row[0] is None:
                return None
            candidate = bool(row[1])
            self.stats["cacheHits"] += 1
            self.stats["rejected"] += int(not candidate)
            return candidate
        except (OSError, ValueError, UnicodeError, sqlite3.Error):
            self._unavailable()
            return None

    def record(self, source: str, fingerprint: tuple, text: str) -> bool:
        """Atomically replace postings after a full, stable canonical parse."""
        signature = self._signature(source, fingerprint)
        if not self.available or self._recording_disabled or signature is None:
            return False
        if not isinstance(text, str) or len(text) > MAX_TEXT_BYTES or "\0" in text:
            return False
        try:
            if len(text.encode("utf-8")) > MAX_TEXT_BYTES:
                return False
            self._validate_paths()
            connection = self._connection
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT id FROM artifacts WHERE source=?", (source,)).fetchone()
            updated = time.time_ns()
            if row:
                rowid = row[0]
                connection.execute("DELETE FROM artifact_terms WHERE rowid=?", (rowid,))
                connection.execute("UPDATE artifacts SET fingerprint=?,updated=? WHERE id=?",
                                   (signature, updated, rowid))
            else:
                rowid = connection.execute(
                    "INSERT INTO artifacts(source,fingerprint,updated) VALUES(?,?,?)",
                    (source, signature, updated),
                ).lastrowid
            connection.execute("INSERT INTO artifact_terms(rowid,text) VALUES(?,?)", (rowid, text))
            self._validate_paths()
            connection.execute("COMMIT")
            self.stats["updated"] += 1
            return True
        except (OSError, ValueError, UnicodeError, sqlite3.Error) as exc:
            self._rollback()
            if isinstance(exc, sqlite3.Error) and getattr(exc, "sqlite_errorcode", None) == sqlite3.SQLITE_FULL:
                # Existing entries remain useful when capacity has been reached.
                self._recording_disabled = True
                self.stats["unavailable"] += 1
            else:
                self._unavailable()
            return False

    @staticmethod
    def _signature(source: str, fingerprint: tuple) -> Optional[str]:
        if not isinstance(source, str) or not source.startswith("/") or "\0" in source:
            return None
        if not isinstance(fingerprint, tuple) or len(fingerprint) != 5:
            return None
        if any(type(value) is not int for value in fingerprint) or any(value < 0 for value in fingerprint[:3]):
            return None
        return json.dumps(fingerprint, separators=(",", ":"))

    def _create_schema(self) -> None:
        connection = self._connection
        connection.execute("BEGIN IMMEDIATE")
        try:
            # Another worker may have initialized the empty file while this
            # connection waited for the creation lock.
            version = connection.execute("PRAGMA user_version").fetchone()[0]
            if version == 0:
                if connection.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone():
                    raise sqlite3.DatabaseError("unrecognized cache schema")
                connection.execute("CREATE TABLE artifacts(id INTEGER PRIMARY KEY, source TEXT UNIQUE NOT NULL, fingerprint TEXT NOT NULL, updated INTEGER NOT NULL)")
                # SQLite requires the small per-document size table for
                # contentless_delete. columnsize=0 is incompatible with it;
                # detail=none still avoids storing every token position.
                connection.execute("CREATE VIRTUAL TABLE artifact_terms USING fts5(text, content='', contentless_delete=1, detail=none, tokenize='trigram case_sensitive 1')")
                connection.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                connection.execute("INSERT INTO metadata VALUES('parser_version',?)", (PARSER_VERSION,))
                connection.execute(f"PRAGMA application_id={APPLICATION_ID}")
                connection.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
            connection.execute("COMMIT")
        except (OSError, sqlite3.Error):
            self._rollback()
            raise

    def _verify_schema(self) -> None:
        connection = self._connection
        if connection.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID:
            raise sqlite3.DatabaseError("unrecognized cache owner")
        if connection.execute("PRAGMA user_version").fetchone()[0] != SCHEMA_VERSION:
            raise sqlite3.DatabaseError("unsupported cache schema")
        if connection.execute("SELECT value FROM metadata WHERE key='parser_version'").fetchone() != (PARSER_VERSION,):
            raise sqlite3.DatabaseError("stale parser schema")
        # Execute a real FTS query so unsupported extensions fail before the
        # caller elects to spend work warming an unusable cache.
        connection.execute("SELECT rowid FROM artifact_terms WHERE artifact_terms MATCH ? LIMIT 1", ('"fts"',)).fetchall()

    def _rollback(self) -> None:
        if self.available and self._connection.in_transaction:
            try:
                self._connection.execute("ROLLBACK")
            except sqlite3.Error:
                pass

    def _unavailable(self) -> None:
        self.stats["unavailable"] += 1
        self.close()

    @staticmethod
    def _check(metadata: os.stat_result, *, directory: bool, private: bool) -> None:
        correct_type = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
        if (not correct_type or metadata.st_uid != os.geteuid()
                or metadata.st_mode & (0o077 if private else 0o022)
                or (not directory and metadata.st_nlink != 1)):
            raise OSError("unsafe index path")

    def _open_directories(self, home: Path) -> None:
        if not home.is_absolute() or ".." in home.parts:
            raise OSError("home must be an absolute directory")
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
        descriptor = os.open(home, flags)
        self._directories.append((descriptor, None, str(home), False))
        self._check(os.fstat(descriptor), directory=True, private=False)
        for name, private in (("Library", False), ("Caches", False), ("Modore", True), ("session-search", True)):
            parent = descriptor
            try:
                os.mkdir(name, mode=0o700, dir_fd=parent)
            except FileExistsError:
                pass
            descriptor = os.open(name, flags, dir_fd=parent)
            self._directories.append((descriptor, parent, name, private))
            self._check(os.fstat(descriptor), directory=True, private=private)

    def _validate_paths(self) -> None:
        for descriptor, parent, name, private in self._directories:
            opened = os.fstat(descriptor)
            named = os.stat(name, dir_fd=parent, follow_symlinks=False)
            self._check(opened, directory=True, private=private)
            self._check(named, directory=True, private=private)
            if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
                raise OSError("index directory changed identity")
        parent = self._directories[-1][0]
        opened = os.fstat(self._database_fd)
        named = os.stat("index.sqlite3", dir_fd=parent, follow_symlinks=False)
        self._check(opened, directory=False, private=True)
        self._check(named, directory=False, private=True)
        if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
            raise OSError("index file changed identity")
        for suffix in ("-journal", "-wal", "-shm"):
            try:
                metadata = os.stat("index.sqlite3" + suffix, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                continue
            self._check(metadata, directory=False, private=True)
