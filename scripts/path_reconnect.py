#!/usr/bin/env python3
"""Restore an absent home path with a recorded link to an SSD working copy.

JSON CLI: preview --original PATH --target PATH; connect --plan-id ID
--owner-approved; list; status --connection-id ID; undo --connection-id ID
--owner-approved. Never edits provider databases, moves user data, creates
missing parent directories, or promises native session resume. SSD edits through
the link affect the working copy, so archival backup roots are refused.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import signal
import stat
import sys
import time

VERSION = 1
TTL = 3600
MAX_HISTORY = 100
MAX_CANDIDATES = 500
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
ID_PATTERN = r"[a-f0-9]{48}"
IMPACT = "기존 경로에 SSD 작업 사본을 가리키는 링크를 만듭니다. 이 경로로 저장·삭제하면 SSD 작업 사본이 변경됩니다. SSD를 분리하면 경로를 사용할 수 없습니다. 앱의 북마크·보안 권한·내부 세션 연결은 별도 재선택이 필요할 수 있습니다."


class ReconnectError(Exception):
    pass


def account_home():
    return Path(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))


def absolute(value):
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts or any(c in str(path) for c in "\n\r\0"):
        raise ReconnectError("올바른 절대경로가 필요합니다.")
    return path


@contextmanager
def directory(path):
    path = absolute(path)
    fd = os.open("/", DIR_FLAGS)
    try:
        for part in path.parts[1:]:
            nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nxt
        yield fd
    finally:
        os.close(fd)


def identity(info):
    return [info.st_dev, info.st_ino]


def stamp(info):
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
            info.st_ctime_ns, info.st_mode, info.st_uid, info.st_gid, info.st_nlink]


def directory_identity(path):
    with directory(path) as fd:
        return identity(os.fstat(fd))


def protected(original, home):
    try:
        parts = original.relative_to(home).parts
    except ValueError:
        return "기존 경로는 현재 사용자 홈 안이어야 합니다."
    if not parts:
        return "홈 폴더 자체는 연결할 수 없습니다."
    if parts[0] in {"Library", "Applications"} or any(p.startswith(".") for p in parts):
        return "숨김 설정·AI 세션·앱 관리 폴더는 직접 연결하지 않습니다."
    if any(p.lower().endswith((".app", ".photoslibrary", ".photolibrary", ".musiclibrary", ".imovielibrary", ".theater", ".tvlibrary", ".pvm", ".sparsebundle")) for p in parts):
        return "앱과 앱 관리 패키지는 직접 연결하지 않습니다."
    if original.suffix.lower() in {".jsonl", ".ndjson", ".sqlite", ".sqlite3", ".db", ".p8", ".p12", ".pfx", ".pem", ".key", ".keychain", ".keychain-db"} or original.name.endswith(("-wal", "-shm", "-journal")) or original.name in {"auth.json", "credentials.json"}:
        return "세션·데이터베이스·인증 자료의 경로는 직접 연결하지 않습니다."
    return None


def ensure_original(original, home):
    original = absolute(original)
    reason = protected(original, home)
    if reason:
        raise ReconnectError(reason)
    return original


def reject_archive(target):
    # Conservative names cover the manual backup layout and recovery bundles.
    if any(p.casefold() in {"backup", "backups", "백업", "backups.backupdb"} or p.casefold().startswith("local-recovery-") for p in target.parts):
        raise ReconnectError("보관용 백업에는 연결할 수 없습니다. 백업과 별도의 SSD 작업 사본을 선택하세요.")
    with directory(target.parent) as fd:
        is_directory = stat.S_ISDIR(os.stat(target.name, dir_fd=fd, follow_symlinks=False).st_mode)
    for parent in ((target, *target.parents) if is_directory else target.parents):
        # Inspect names only, never open arbitrary manifests or follow links.
        with directory(parent) as fd:
            names = set()
            for name in (".modore-recovery-manifest.json", "manifest.json", "payload"):
                try:
                    os.stat(name, dir_fd=fd, follow_symlinks=False)
                    names.add(name)
                except FileNotFoundError:
                    pass
            if ".modore-recovery-manifest.json" in names or {"manifest.json", "payload"} <= names:
                raise ReconnectError("복원·백업 번들에는 연결할 수 없습니다. 별도의 SSD 작업 사본을 선택하세요.")


def target_snapshot(target):
    with directory(target.parent) as parent:
        fd = os.open(target.name, FILE_FLAGS, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if stat.S_ISDIR(info.st_mode):
                kind, size, sha = "directory", None, None
            elif stat.S_ISREG(info.st_mode):
                if info.st_nlink != 1:
                    raise ReconnectError("하드링크 대상은 연결하지 않습니다.")
                kind, size = "file", info.st_size
                before = stamp(info)
                digest = hashlib.sha256()
                deadline = time.monotonic() + 180
                while block := os.read(fd, 1024 * 1024):
                    if time.monotonic() > deadline:
                        raise ReconnectError("파일 검증 시간이 초과됐습니다.")
                    digest.update(block)
                if stamp(os.fstat(fd)) != before:
                    raise ReconnectError("검증 중 SSD 파일이 변경됐습니다.")
                sha = digest.hexdigest()
            else:
                raise ReconnectError("일반 파일 또는 폴더만 연결할 수 있습니다.")
            if identity(os.stat(target.name, dir_fd=parent, follow_symlinks=False)) != identity(info):
                raise ReconnectError("SSD 대상이 교체됐습니다.")
            return dict(targetKind=kind, bytes=size, sha256=sha,
                        targetIdentity=identity(info), targetStamp=stamp(info),
                        targetParentIdentity=identity(os.fstat(parent)))
        finally:
            os.close(fd)


def external_check(original_parent, target, require_external):
    target_parent = directory_identity(target.parent)
    if require_external and (original_parent[0] == target_parent[0] or len(target.parts) < 4 or target.parts[1] != "Volumes"):
        raise ReconnectError("대상은 /Volumes 아래에 마운트된 다른 SSD 볼륨이어야 합니다.")
    return target_parent


def state_directory(home, override=None):
    path = absolute(override or home / "Library/Application Support/Modore/path-reconnect")
    fd = os.open("/", DIR_FLAGS)
    try:
        for part in path.parts[1:]:
            try:
                nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                os.mkdir(part, 0o700, dir_fd=fd)
                nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nxt
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            raise ReconnectError("연결 기록 폴더의 권한이 안전하지 않습니다.")
    finally:
        os.close(fd)
    return path


def save_json(path, value):
    with directory(path.parent) as parent:
        fd = os.open(path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, "w") as out:
            json.dump(value, out, ensure_ascii=False)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.fsync(parent)


def read_json(path, limit=1_000_000):
    with directory(path.parent) as parent:
        fd = os.open(path.name, FILE_FLAGS, dir_fd=parent)
        with os.fdopen(fd) as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077 or info.st_size > limit:
                raise ReconnectError("연결 기록의 형식·권한·크기가 유효하지 않습니다.")
            result = json.load(source)
            if not isinstance(result, dict):
                raise ReconnectError("연결 기록이 올바르지 않습니다.")
            return result


def checked_id(value):
    if not isinstance(value, str) or not re.fullmatch(ID_PATTERN, value):
        raise ReconnectError("연결 식별자가 올바르지 않습니다.")
    return value


def absent(parent, name):
    try:
        os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise ReconnectError("기존 경로에 항목이 있습니다. 기존 파일·폴더·링크는 덮어쓰지 않습니다.")


def preview(original, target, *, home=None, state=None, require_external=True):
    home = home or account_home()
    original, target = ensure_original(original, home), absolute(target)
    if original == target or original in target.parents or target in original.parents:
        raise ReconnectError("기존 경로와 SSD 대상이 서로 겹칩니다.")
    with directory(original.parent) as parent:
        absent(parent, original.name)
        parent_id = identity(os.fstat(parent))
    external_check(parent_id, target, require_external)
    reject_archive(target)
    snapshot = target_snapshot(target)
    plan_id = secrets.token_hex(24)
    now = time.time()
    plan = dict(schemaVersion=VERSION, planID=plan_id, createdAt=now, expiresAt=now+TTL,
                home=str(home), originalPath=str(original), targetPath=str(target),
                originalParentIdentity=parent_id, requireExternal=require_external,
                warnings=["SSD 작업 사본을 통한 변경은 보관용 백업에 자동 반영되지 않습니다.",
                          "앱이 심볼릭 링크를 허용하지 않거나 파일 북마크를 쓰면 앱에서 대상 폴더를 다시 선택해야 합니다.",
                          "파일 경로의 접근만 연결합니다. AI 앱의 세션 재개와 Git 워크트리의 .git 공통 저장소 경로 복구는 별도 확인이 필요합니다."],
                impact=IMPACT, **snapshot)
    save_json(state_directory(home, state) / (plan_id + ".plan.json"), plan)
    return plan


def validate_record(record, connection_id, home):
    if record.get("schemaVersion") != VERSION or record.get("connectionID") != connection_id or record.get("home") != str(home):
        raise ReconnectError("연결 기록이 유효하지 않습니다.")
    original = ensure_original(record["originalPath"], home)
    target = absolute(record["targetPath"])
    if original == target or original in target.parents or target in original.parents:
        raise ReconnectError("연결 기록 경로가 겹칩니다.")
    for key in ("originalParentIdentity", "targetIdentity", "targetParentIdentity"):
        if not isinstance(record.get(key), list) or len(record[key]) != 2 or any(type(x) is not int for x in record[key]):
            raise ReconnectError("연결 기록의 파일 정체성이 유효하지 않습니다.")
    return original, target


def journal_event(state, connection_id, event, **extra):
    with directory(state) as parent:
        fd = os.open(connection_id + ".journal.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, "a") as out:
            json.dump(dict(at=time.time(), event=event, **extra), out, ensure_ascii=False)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())


def connect(plan_id, *, approved=False, home=None, state=None, _hook=None):
    checked_id(plan_id)
    if not approved:
        raise ReconnectError("SSD 작업 사본이 변경된다는 영향을 확인하고 연결을 승인하세요.")
    testing = home is not None
    home = home or account_home()
    state = state_directory(home, state)
    plan = read_json(state / (plan_id + ".plan.json"))
    record = dict(plan, connectionID=plan_id)
    original, target = validate_record(record, plan_id, home)
    if plan.get("planID") != plan_id or not plan["createdAt"] <= time.time() < plan["expiresAt"] or plan["expiresAt"] - plan["createdAt"] > TTL:
        raise ReconnectError("연결 계획이 만료되거나 유효하지 않습니다. 다시 확인하세요.")
    reject_archive(target)
    external_check(plan["originalParentIdentity"], target, plan["requireExternal"] if testing else True)
    snapshot = target_snapshot(target)
    for key in ("targetKind", "targetIdentity", "targetParentIdentity", "targetStamp", "sha256"):
        if snapshot[key] != plan[key]:
            raise ReconnectError("미리보기 이후 SSD 대상이 변경됐습니다. 다시 확인하세요.")
    with directory(original.parent) as parent:
        if identity(os.fstat(parent)) != plan["originalParentIdentity"]:
            raise ReconnectError("기존 경로의 상위 폴더가 교체됐습니다.")
        absent(parent, original.name)
        save_json(state / (plan_id + ".used.json"), {"usedAt": time.time()})
        record.update(status="recovery-needed", reason="연결 시작 기록입니다. 상태를 확인하세요.", receiptPath=str(state / (plan_id + ".receipt.json")))
        # Durable intent survives a hard stop after symlink creation. Receipt
        # without linkIdentity is deliberately never eligible for automatic undo.
        save_json(state / (plan_id + ".intent.json"), record)
        journal_event(state, plan_id, "connect-intent", originalPath=str(original), targetPath=str(target))
        if _hook:
            _hook("before-link")
        os.symlink(str(target), original.name, dir_fd=parent)
        os.fsync(parent)
        link_id = identity(os.stat(original.name, dir_fd=parent, follow_symlinks=False))
        record.update(linkIdentity=link_id, connectedAt=time.time())
        # Persist inode evidence before optional callbacks / further I/O.
        save_json(state / (plan_id + ".created.json"), record)
        journal_event(state, plan_id, "connected", linkIdentity=link_id)
        if _hook:
            _hook("after-link")
        record.update(status="connected", reason="기존 경로가 SSD 작업 사본에 연결돼 있습니다.")
        save_json(state / (plan_id + ".receipt.json"), record)
    return status(plan_id, home=home, state=state)


def load_connection(connection_id, home, state):
    checked_id(connection_id)
    for ending in (".receipt.json", ".created.json", ".intent.json"):
        try:
            value = read_json(state / (connection_id + ending))
            validate_record(value, connection_id, home)
            return value
        except FileNotFoundError:
            continue
    raise ReconnectError("연결 기록을 찾을 수 없습니다.")


def staged_recovery(state, connection_id, record):
    """Find a proven link retained by an interrupted undo, without following it."""
    try:
        with directory(state) as parent:
            fd = os.open(connection_id + ".journal.jsonl", FILE_FLAGS, dir_fd=parent)
            with os.fdopen(fd) as source:
                info = os.fstat(source.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077 or info.st_size > 1_000_000:
                    return None
                events = [json.loads(line) for line in source if line.strip()]
        pending = None
        for event in events:
            if event.get("event") in {"undo-intent", "undo-recovery-needed"}:
                pending = event.get("stagingPath")
            elif event.get("event") in {"undo-restored", "disconnected"}:
                pending = None
        if not pending:
            return None
        staged, original = absolute(pending), absolute(record["originalPath"])
        if (staged.name != original.name or staged.parent.parent != original.parent
                or not re.fullmatch(r"\.modore-reconnect-[a-f0-9]{24}", staged.parent.name)):
            return None
        with directory(staged.parent) as parent:
            info = os.stat(staged.name, dir_fd=parent, follow_symlinks=False)
            if (stat.S_ISLNK(info.st_mode) and identity(info) == record.get("linkIdentity")
                    and os.readlink(staged.name, dir_fd=parent) == record["targetPath"]):
                return str(staged)
    except (OSError, ValueError, KeyError, TypeError, ReconnectError):
        pass
    return None


def status(connection_id, *, home=None, state=None):
    home = home or account_home()
    state = state_directory(home, state)
    record = load_connection(connection_id, home, state)
    original, target = validate_record(record, connection_id, home)

    def result(code, reason):
        return dict(record, status=code, reason=reason)

    try:
        marker = read_json(state / (connection_id + ".undone.json"))
    except FileNotFoundError:
        marker = None
    if marker is not None:
        if marker.get("connectionID") != connection_id or not isinstance(marker.get("disconnectedAt"), (int, float)):
            raise ReconnectError("연결 해제 기록이 유효하지 않습니다.")
        return result("disconnected", "Modore 연결을 해제했습니다. SSD 원본은 유지됩니다.")
    try:
        with directory(original.parent) as parent:
            if identity(os.fstat(parent)) != record["originalParentIdentity"]:
                return result("conflict", "기존 경로의 상위 폴더가 교체됐습니다.")
            try:
                info = os.stat(original.name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                recovery_path = staged_recovery(state, connection_id, record)
                if recovery_path:
                    return dict(result("recovery-needed", "연결 해제 중 남은 링크의 복구 경로: " + recovery_path), recoveryPath=recovery_path)
                return result("original-missing", "기존 경로에 연결이 없습니다.")
            if not record.get("linkIdentity"):
                return result("recovery-needed", "연결 중 중단됐습니다. 링크 정체성 기록이 없어 자동 해제하지 않습니다.")
            if not stat.S_ISLNK(info.st_mode) or identity(info) != record["linkIdentity"] or os.readlink(original.name, dir_fd=parent) != str(target):
                return result("conflict", "기존 경로가 다른 항목으로 바뀌었습니다. 변경하지 않습니다.")
    except OSError:
        return result("conflict", "기존 경로 또는 상위 폴더를 확인할 수 없습니다.")
    try:
        with directory(target.parent) as parent:
            info = os.stat(target.name, dir_fd=parent, follow_symlinks=False)
            if identity(os.fstat(parent)) != record["targetParentIdentity"] or identity(info) != record["targetIdentity"] or stat.S_ISLNK(info.st_mode):
                return result("target-replaced", "SSD 대상 또는 상위 폴더가 교체됐습니다. 다시 확인하세요.")
    except FileNotFoundError:
        return result("ssd-unavailable", "SSD가 분리됐거나 대상 경로가 없습니다.")
    except OSError:
        return result("ssd-unavailable", "SSD 대상 경로에 접근할 수 없습니다.")
    return result("connected", "기존 경로가 SSD 작업 사본에 연결돼 있습니다.")


def undo(connection_id, *, approved=False, home=None, state=None, _hook=None):
    checked_id(connection_id)
    if not approved:
        raise ReconnectError("기존 경로의 연결 해제를 승인하세요.")
    home = home or account_home()
    state = state_directory(home, state)
    record = load_connection(connection_id, home, state)
    original, target = validate_record(record, connection_id, home)
    if status(connection_id, home=home, state=state)["status"] not in {"connected", "ssd-unavailable", "target-replaced"}:
        raise ReconnectError("Modore가 만든 정확한 링크를 확인할 수 없어 해제하지 않습니다.")
    with directory(original.parent) as parent:
        if identity(os.fstat(parent)) != record["originalParentIdentity"]:
            raise ReconnectError("상위 폴더가 교체됐습니다.")
        stage_name = ".modore-reconnect-" + secrets.token_hex(12)
        os.mkdir(stage_name, 0o700, dir_fd=parent)
        stage = os.open(stage_name, DIR_FLAGS, dir_fd=parent)
        moved = False
        stage_path = original.parent / stage_name / original.name
        try:
            journal_event(state, connection_id, "undo-intent", stagingPath=str(stage_path))
            if _hook:
                _hook("before-stage")
            os.rename(original.name, original.name, src_dir_fd=parent, dst_dir_fd=stage)
            moved = True
            info = os.stat(original.name, dir_fd=stage, follow_symlinks=False)
            if not stat.S_ISLNK(info.st_mode) or identity(info) != record["linkIdentity"] or os.readlink(original.name, dir_fd=stage) != str(target):
                raise ReconnectError("연결 해제 직전에 경로가 바뀌었습니다. 삭제하지 않습니다.")
            if _hook:
                _hook("after-stage")
            os.unlink(original.name, dir_fd=stage)
            moved = False
            os.fsync(parent)
            save_json(state / (connection_id + ".undone.json"), {"disconnectedAt": time.time(), "connectionID": connection_id})
            journal_event(state, connection_id, "disconnected")
        except BaseException:
            if moved:
                try:
                    # A hard link to a symlink preserves the symlink itself and
                    # fails instead of overwriting a newly created source entry.
                    os.link(original.name, original.name, src_dir_fd=stage, dst_dir_fd=parent, follow_symlinks=False)
                    os.unlink(original.name, dir_fd=stage)
                    moved = False
                    journal_event(state, connection_id, "undo-restored")
                except OSError:
                    journal_event(state, connection_id, "undo-recovery-needed", stagingPath=str(stage_path))
            raise
        finally:
            os.close(stage)
            if not moved:
                os.rmdir(stage_name, dir_fd=parent)
    return status(connection_id, home=home, state=state)


def missing_candidates(home, receipts=None):
    """Metadata hints only; never infer that an archived file is a working copy."""
    root = absolute(receipts or home / "Library/Application Support/Modore/backup-reclaim")
    rows, warnings, seen = [], [], set()
    try:
        with directory(root) as fd:
            names = sorted([n for n in os.listdir(fd) if re.fullmatch(ID_PATTERN + r"\.receipt\.json", n)],
                           key=lambda n: os.stat(n, dir_fd=fd, follow_symlinks=False).st_mtime, reverse=True)
        if len(names) > MAX_HISTORY:
            warnings.append("최근 100개 삭제 기록만 확인했습니다.")
        for name in names[:MAX_HISTORY]:
            try:
                receipt = read_json(root / name, 12_000_000)
                plan_id = name.split(".")[0]
                plan = read_json(root / (plan_id + ".json"), 12_000_000)
                if (receipt.get("schemaVersion") != VERSION or plan.get("schemaVersion") != VERSION
                        or receipt.get("planID") != plan_id or plan.get("planID") != plan_id
                        or plan.get("home") != str(home)
                        or receipt.get("localRoot") != plan.get("localRoot")
                        or receipt.get("backupRoot") != plan.get("backupRoot")):
                    raise ReconnectError("삭제 기록과 비교 계획이 일치하지 않습니다.")
                local, backup = absolute(receipt["localRoot"]), absolute(receipt["backupRoot"])
                verified = {row["id"]: row for row in plan.get("rows", [])[:5000]
                            if row.get("status") == "identical"}
                for item in receipt.get("items", [])[:5000]:
                    proof = verified.get(item.get("id"))
                    if (item.get("status") != "deleted" or not proof
                            or item.get("path") != proof.get("path")
                            or item.get("bytes") != proof.get("bytes")):
                        continue
                    relative = Path(item["path"])
                    if relative.is_absolute() or ".." in relative.parts:
                        continue
                    original = ensure_original(local / relative, home)
                    if str(original) in seen or os.path.lexists(original):
                        continue
                    # Parent components must still be real local directories.
                    directory_identity(original.parent)
                    seen.add(str(original))
                    rows.append(dict(originalPath=str(original), targetPath=str(backup / relative),
                                     bytes=item.get("bytes"), receiptPath=str(root / name)))
                    if len(rows) >= MAX_CANDIDATES:
                        warnings.append("최대 500개 누락 경로를 표시합니다.")
                        return rows, warnings
            except (OSError, ValueError, KeyError, TypeError, ReconnectError):
                warnings.append("일부 삭제 기록을 검증하지 못해 제외했습니다.")
    except FileNotFoundError:
        pass
    return rows, list(dict.fromkeys(warnings))


def list_connections(*, home=None, state=None, receipts=None):
    home = home or account_home()
    state = state_directory(home, state)
    with directory(state) as fd:
        ids = {n.split(".")[0] for n in os.listdir(fd) if re.fullmatch(ID_PATTERN + r"\.(receipt|created|intent)\.json", n)}
    records, warnings = [], []
    for connection_id in sorted(ids, key=lambda i: (state / (i + ".intent.json")).stat().st_mtime if (state / (i + ".intent.json")).exists() else 0, reverse=True)[:MAX_HISTORY]:
        try:
            records.append(status(connection_id, home=home, state=state))
        except (OSError, ValueError, KeyError, TypeError, ReconnectError):
            warnings.append("일부 연결 기록을 검증하지 못해 제외했습니다.")
    if len(ids) > MAX_HISTORY:
        warnings.append("최근 100개 연결만 표시합니다.")
    candidates, more = missing_candidates(home, receipts)
    return dict(schemaVersion=VERSION, connections=records, candidates=candidates,
                warnings=list(dict.fromkeys(warnings + more)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("preview")
    command.add_argument("--original", required=True)
    command.add_argument("--target", required=True)
    command = commands.add_parser("connect")
    command.add_argument("--plan-id", required=True)
    command.add_argument("--owner-approved", action="store_true")
    commands.add_parser("list")
    command = commands.add_parser("status")
    command.add_argument("--connection-id", required=True)
    command = commands.add_parser("undo")
    command.add_argument("--connection-id", required=True)
    command.add_argument("--owner-approved", action="store_true")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        if args.command == "preview":
            result = preview(args.original, args.target)
        elif args.command == "connect":
            result = connect(args.plan_id, approved=args.owner_approved)
        elif args.command == "list":
            result = list_connections()
        elif args.command == "status":
            result = status(args.connection_id)
        else:
            result = undo(args.connection_id, approved=args.owner_approved)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError, TypeError, ReconnectError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())
