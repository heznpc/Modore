#!/usr/bin/env python3
"""Compare explicitly paired folders, then remove only approved local duplicates.

Not exposed by bin/modore or MCP. The native app owns selection and approval.
Never removes directories, follows links, or alters the retained backup. Live AI
state, application-managed data, hidden configuration and Git work are protected.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import signal
import stat
import subprocess
import sys
import time

VERSION = 1
MAX_ROWS = 5000
MAX_SELECTION = 1000
TTL = 3600
IGNORED_XATTRS = {"com.apple.provenance", "com.apple.quarantine", "com.apple.lastuseddate#PS"}
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
PERSONAL_IMPACT = "로컬 경로에서 파일이 사라집니다. 최근 항목·앱·스크립트가 이 경로를 쓰면 SSD 사본으로 다시 연결해야 합니다."


class ReclaimError(Exception):
    pass


def account_home():
    return Path(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))


def absolute(path):
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts or any(c in str(path) for c in "\n\r\0"):
        raise ReclaimError("절대경로와 일반 파일명이 필요합니다.")
    return path


@contextmanager
def directory(path):
    """Pin every component; /var-style symlink aliases must be resolved by UI."""
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


@contextmanager
def regular(path):
    path = absolute(path)
    with directory(path.parent) as parent:
        fd = os.open(path.name, FILE_FLAGS, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise ReclaimError("일반 파일만 비교할 수 있습니다.")
            yield fd, parent, path.name
        finally:
            os.close(fd)


def identity(info):
    return [info.st_dev, info.st_ino]


def stamp(info):
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
            info.st_ctime_ns, info.st_mode, info.st_uid, info.st_gid, info.st_nlink,
            getattr(info, "st_flags", 0)]


def root_identity(path):
    with directory(path) as fd:
        return identity(os.fstat(fd))


def digest(fd, deadline=None):
    before = stamp(os.fstat(fd))
    os.lseek(fd, 0, os.SEEK_SET)
    result = hashlib.sha256()
    while True:
        if deadline is not None and time.monotonic() > deadline:
            raise ReclaimError("검사 시간 한도에 도달했습니다. 더 작은 폴더를 선택하세요.")
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        result.update(block)
    if stamp(os.fstat(fd)) != before:
        raise ReclaimError("읽는 동안 파일이 변경됐습니다.")
    return result.hexdigest(), before


def xattr_digests(fd):
    if sys.platform != "darwin":
        return {name: hashlib.sha256(os.getxattr(fd, name)).hexdigest()
                for name in os.listxattr(fd) if name not in IGNORED_XATTRS}
    # CPython exposes os.*xattr on Linux, not on macOS. Use descriptor-based
    # Darwin calls so checking metadata cannot follow a replaced pathname.
    libc = ctypes.CDLL(None, use_errno=True)
    libc.flistxattr.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    libc.flistxattr.restype = ctypes.c_ssize_t
    libc.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.fgetxattr.restype = ctypes.c_ssize_t
    count = libc.flistxattr(fd, None, 0, 0)
    if count < 0 or count > 1024 * 1024:
        raise ReclaimError("확장 속성 목록을 확인하지 못했습니다.")
    names = ctypes.create_string_buffer(max(count, 1))
    if libc.flistxattr(fd, names, count, 0) != count:
        raise ReclaimError("확장 속성 목록이 변경됐습니다.")
    result = {}
    for name in names.raw[:count].split(b"\0"):
        if not name or os.fsdecode(name) in IGNORED_XATTRS:
            continue
        size = libc.fgetxattr(fd, name, None, 0, 0, 0)
        if size < 0 or size > 16 * 1024 * 1024:
            raise ReclaimError("확장 속성을 검증할 수 없거나 검사 한도를 넘었습니다.")
        value = ctypes.create_string_buffer(max(size, 1))
        if libc.fgetxattr(fd, name, value, size, 0, 0) != size:
            raise ReclaimError("확장 속성이 변경됐습니다.")
        result[os.fsdecode(name)] = hashlib.sha256(value.raw[:size]).hexdigest()
    return result


def metadata(fd):
    info = os.fstat(fd)
    attrs = xattr_digests(fd)
    result = {"mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid,
              "gid": info.st_gid, "xattrs": attrs}
    if sys.platform == "darwin":
        libc = ctypes.CDLL(None, use_errno=True)
        libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        libc.acl_get_fd_np.restype = ctypes.c_void_p
        libc.acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ssize_t)]
        libc.acl_to_text.restype = ctypes.c_void_p
        libc.acl_free.argtypes = [ctypes.c_void_p]
        acl = libc.acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED in sys/acl.h.
        if not acl:
            if ctypes.get_errno() == errno.ENOENT:
                result["aclSHA256"] = None  # File exists, but has no extended ACL.
                return result
            raise ReclaimError("ACL 권한을 확인하지 못했습니다.")
        try:
            length = ctypes.c_ssize_t()
            text = libc.acl_to_text(acl, ctypes.byref(length))
            if not text:
                raise OSError(ctypes.get_errno(), "ACL text inspection failed")
            try:
                result["aclSHA256"] = hashlib.sha256(ctypes.string_at(text, length.value)).hexdigest()
            finally:
                libc.acl_free(text)
        finally:
            libc.acl_free(acl)
    return result


def policy(path, home):
    """Deletion policy is deliberately independent of byte equality."""
    try:
        rel = path.relative_to(home)
    except ValueError:
        return "홈 폴더 밖의 시스템·공유 자료는 이 기능으로 삭제하지 않습니다."
    parts = rel.parts
    if not parts:
        return None
    if parts[0] in {".codex", ".claude", ".gemini", ".cursor"}:
        return "AI 대화·재개·설정·첨부물·실행 자산을 보호합니다. 캐시도 세션 사용 중에는 별도 정리 절차가 필요합니다."
    if parts[0] in {"Library", "Applications"}:
        return "앱이 관리하는 데이터·설정·캐시입니다. 앱별 정리 기능에서 영향을 확인하세요."
    if any(p.startswith(".") for p in parts):
        return "숨김 설정·인증·앱 자료일 수 있어 보호합니다. 숨김 항목도 검사 범위에 표시됩니다."
    if any(p in {"node_modules", "Pods", "Carthage", "ModuleCache.noindex", "Index.noindex"}
           or p.startswith("DerivedData") for p in parts):
        return "빌드 도구가 관리하는 의존성·색인·캐시입니다. 삭제하면 다운로드·재빌드가 필요하므로 전용 캐시 정리에서 다룹니다."
    if any(p.lower().endswith((".app", ".photoslibrary", ".musiclibrary", ".photolibrary", ".pvm", ".vmwarevm", ".sparsebundle", ".xcodeproj", ".xcworkspace")) for p in parts):
        return "앱 또는 앱이 관리하는 패키지입니다. 내부 파일 단위로 지우지 않습니다."
    if path.suffix.lower() in {".p8", ".p12", ".pfx", ".pem", ".key", ".keychain", ".keychain-db"} or path.name in {"auth.json", "credentials.json"}:
        return "로그인·서명·배포에 쓰일 수 있는 인증 자료입니다. 백업이 있어도 로컬 사용 경로를 보호합니다."
    if path.suffix.lower() in {".sqlite", ".sqlite3", ".db", ".jsonl"} or path.name.endswith(("-wal", "-shm", "-journal")):
        return "대화 기록·데이터베이스일 수 있습니다. 본문이 같아도 앱 단위 복원과 사용 여부를 확인해야 합니다."
    current = path if path.is_dir() else path.parent
    while current == home or home in current.parents:
        if os.path.lexists(current / ".git"):
            return "Git 저장소·워크트리입니다. 코드·미커밋 작업·세션 작업 경로 보호를 위해 프로젝트 정리에서 다룹니다."
        if current == home:
            break
        current = current.parent
    return None


def visible_open_paths():
    """Open-file evidence is a veto, never proof that an unobserved app is idle."""
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-Fpn"], capture_output=True, timeout=30)
    if result.returncode != 0:
        raise ReclaimError("열린 파일 관찰을 완료하지 못했습니다. 삭제 후보를 승인할 수 없습니다.")
    return {line[1:] for line in result.stdout.decode("utf-8", "replace").splitlines()
            if line.startswith("n/")}


def validate_roots(local, backup, home, require_external):
    local, backup = absolute(local), absolute(backup)
    if local != home and home not in local.parents:
        raise ReclaimError("로컬 폴더는 현재 사용자 홈 안에서 선택하세요.")
    if local == backup or local in backup.parents or backup in local.parents:
        raise ReclaimError("로컬과 백업은 서로 겹치지 않는 폴더여야 합니다.")
    a, b = root_identity(local), root_identity(backup)
    if require_external and a[0] == b[0]:
        raise ReclaimError("백업은 로컬과 다른 볼륨에서 선택하세요.")
    return local, backup, a, b


def compare(local, backup, opened, deadline=None):
    if str(local) in opened or str(backup) in opened:
        raise ReclaimError("프로세스가 파일을 열고 있습니다.")
    with regular(local) as (a, _, _), regular(backup) as (b, _, _):
        x, y = os.fstat(a), os.fstat(b)
        if identity(x) == identity(y) or x.st_nlink != 1 or y.st_nlink != 1:
            raise ReclaimError("같은 파일 또는 하드링크는 회수량과 다른 경로 영향을 확정할 수 없습니다.")
        if x.st_uid != os.getuid():
            raise ReclaimError("현재 사용자 소유 파일만 정리할 수 있습니다.")
        if x.st_size != y.st_size:
            return {"status": "different", "reason": "파일 크기가 다릅니다."}
        left, left_stamp = digest(a, deadline)
        right, right_stamp = digest(b, deadline)
        if stamp(os.fstat(a)) != left_stamp or stamp(os.fstat(b)) != right_stamp:
            raise ReclaimError("비교 중 파일이 변경됐습니다.")
        if left != right:
            return {"status": "different", "reason": "파일 내용이 다릅니다."}
        ma, mb = metadata(a), metadata(b)
        if stamp(os.fstat(a)) != left_stamp or stamp(os.fstat(b)) != right_stamp:
            raise ReclaimError("속성 검사 중 파일이 변경됐습니다.")
        proof = {"sha256": left, "localStamp": left_stamp, "backupStamp": right_stamp,
                 "metadata": ma}
        if ma != mb:
            return dict(proof, status="metadata", reason="본문은 같지만 권한·태그·리소스 등 복원 속성이 다릅니다.")
        return dict(proof, status="identical", reason=PERSONAL_IMPACT)


def state_directory(home, override=None):
    path = absolute(override or home / "Library/Application Support/Modore/backup-reclaim")
    # Create each missing component without following a pre-existing link.
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
            raise ReclaimError("정리 기록 폴더는 현재 사용자만 접근할 수 있어야 합니다.")
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


def scan(local, backup, *, home=None, state=None, opened=None, require_external=True,
         limit=MAX_ROWS, seconds=180):
    home = home or account_home()
    local, backup, lid, bid = validate_roots(local, backup, home, require_external)
    state = state_directory(home, state)
    rows, warnings = [], []
    deadline = time.monotonic() + seconds
    complete = True
    try:
        opened = visible_open_paths() if opened is None else opened
        process_check = True
    except (ReclaimError, OSError, subprocess.TimeoutExpired) as error:
        opened, process_check = set(), False
        warnings.append(str(error))

    def add(path, status, reason, **values):
        rel = str(path.relative_to(local))
        rows.append(dict(id=hashlib.sha256(rel.encode()).hexdigest()[:32], path=rel,
                         status=status, reason=reason, bytes=values.pop("bytes", None), **values))

    def walk(path):
        nonlocal complete
        if len(rows) >= limit or time.monotonic() > deadline:
            complete = False
            return
        try:
            info = path.lstat()
            reason = policy(path, home)
            if stat.S_ISLNK(info.st_mode):
                add(path, "protected", "심볼릭 링크는 따라가거나 삭제하지 않습니다.")
            elif reason:
                add(path, "protected", reason, bytes=info.st_size if stat.S_ISREG(info.st_mode) else None)
            elif stat.S_ISDIR(info.st_mode):
                with directory(path) as fd:
                    for name in sorted(os.listdir(fd)):
                        walk(path / name)
                        if not complete:
                            break
            elif stat.S_ISREG(info.st_mode):
                if not process_check:
                    add(path, "unverified", "열린 파일을 관찰하지 못해 비교·삭제 승인을 보류합니다.", bytes=info.st_size)
                    return
                try:
                    result = compare(path, backup / path.relative_to(local), opened, deadline)
                    add(path, bytes=info.st_size, **result)
                except FileNotFoundError:
                    add(path, "missing", "대응하는 SSD 파일 또는 원본이 없습니다.", bytes=info.st_size)
                except (OSError, ReclaimError) as error:
                    add(path, "unverified", str(error), bytes=info.st_size)
            else:
                add(path, "protected", "일반 파일이 아닌 실행·특수 항목입니다.")
        except (OSError, ValueError, ReclaimError) as error:
            add(path, "unverified", str(error))

    walk(local)
    if not complete:
        warnings.append("시간·항목 한도까지 검사했습니다. 더 작은 폴더를 선택해 나머지를 확인하세요.")
    plan_id = secrets.token_hex(24)
    plan = dict(schemaVersion=VERSION, planID=plan_id, createdAt=time.time(), expiresAt=time.time()+TTL,
                localRoot=str(local), backupRoot=str(backup), localIdentity=lid, backupIdentity=bid,
                home=str(home), requireExternal=require_external, complete=complete, rows=rows,
                identicalBytes=sum(row["bytes"] or 0 for row in rows if row["status"] == "identical"),
                processCheck=process_check, warnings=warnings,
                coverage="같은 상대경로의 일반 파일을 SHA-256과 복원 속성으로 비교합니다. 보호 폴더 내부는 비교하지 않습니다. 이름이 바뀐 중복은 찾지 않습니다. 열린 파일 관찰에는 권한상 한계가 있습니다.")
    save_json(state / (plan_id + ".json"), plan)
    return plan


def delete_one(local, backup, proof, opened, event):
    """Stage by atomic rename, verify what actually moved, then unlink that inode.

    On interruption/failure a staged file is retained with its exact recovery
    path in a synced journal. No recursive removal or overwrite-style rollback.
    """
    fresh = compare(local, backup, opened)
    if fresh.get("status") != "identical" or any(fresh[k] != proof[k] for k in ("sha256", "localStamp", "backupStamp", "metadata")):
        raise ReclaimError("미리보기 이후 원본 또는 백업이 변경됐습니다. 다시 비교하세요.")
    staging_name = ".modore-reclaim-" + secrets.token_hex(12)
    staging_path = local.parent / staging_name / local.name
    with directory(local.parent) as parent, regular(backup) as (saved, _, _):
        if stamp(os.stat(local.name, dir_fd=parent, follow_symlinks=False)) != proof["localStamp"]:
            raise ReclaimError("이동 직전 원본이 변경됐습니다.")
        os.mkdir(staging_name, 0o700, dir_fd=parent)
        stage = os.open(staging_name, DIR_FLAGS, dir_fd=parent)
        moved = False
        try:
            event("stage-intent", stagingPath=str(staging_path))
            os.rename(local.name, local.name, src_dir_fd=parent, dst_dir_fd=stage)
            moved = True
            event("staged", stagingPath=str(staging_path))
            fd = os.open(local.name, FILE_FLAGS, dir_fd=stage)
            try:
                current = os.fstat(fd)
                if not stat.S_ISREG(current.st_mode) or identity(current) != proof["localStamp"][:2] or current.st_nlink != 1:
                    raise ReclaimError("이동된 파일의 정체성이 바뀌었습니다. 복구 경로에 보존했습니다.")
                left, ls = digest(fd)
                right, rs = digest(saved)
                if left != proof["sha256"] or right != left or rs != proof["backupStamp"]:
                    raise ReclaimError("최종 내용 또는 백업이 바뀌어 삭제하지 않았습니다.")
                if metadata(fd) != proof["metadata"] or metadata(saved) != proof["metadata"]:
                    raise ReclaimError("최종 복원 속성이 바뀌어 삭제하지 않았습니다.")
                if stamp(os.fstat(fd)) != ls or stamp(os.fstat(saved)) != rs or stamp(os.stat(local.name, dir_fd=stage, follow_symlinks=False)) != ls:
                    raise ReclaimError("최종 검사 중 파일이 변경됐습니다.")
                event("verified-delete-intent", stagingPath=str(staging_path), sha256=left)
                os.unlink(local.name, dir_fd=stage)
                moved = False
                event("deleted", bytes=current.st_size)
                return current.st_size
            finally:
                os.close(fd)
        except BaseException:
            if moved:
                # Link restores a regular file without clobbering a newly
                # created source path. A changed/symlink entry stays staged.
                try:
                    info = os.stat(local.name, dir_fd=stage, follow_symlinks=False)
                    if stat.S_ISREG(info.st_mode) and identity(info) == proof["localStamp"][:2]:
                        os.link(local.name, local.name, src_dir_fd=stage, dst_dir_fd=parent, follow_symlinks=False)
                        os.unlink(local.name, dir_fd=stage)
                        moved = False
                        event("restored-after-stop")
                except OSError:
                    pass
                if moved:
                    event("retained-for-recovery", stagingPath=str(staging_path))
            raise
        finally:
            os.close(stage)
            if not moved:
                try:
                    os.rmdir(staging_name, dir_fd=parent)
                except OSError:
                    pass


def execute(plan_id, selected, *, approved=False, home=None, state=None, opened=None):
    if not approved or not re.fullmatch(r"[a-f0-9]{48}", plan_id):
        raise ReclaimError("앱에서 비교 결과와 선택 항목의 삭제를 승인해야 합니다.")
    if not selected or len(selected) > MAX_SELECTION or len(set(selected)) != len(selected):
        raise ReclaimError("중복 없는 파일을 1~1000개 선택하세요.")
    testing = home is not None
    home = home or account_home()
    state = state_directory(home, state)
    with regular(state / (plan_id + ".json")) as (fd, _, _):
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or info.st_size > 12_000_000 or stat.S_IMODE(info.st_mode) & 0o077:
            raise ReclaimError("비교 계획의 권한·크기를 확인하지 못했습니다.")
        with os.fdopen(os.dup(fd)) as source:
            plan = json.load(source)
    if plan.get("schemaVersion") != VERSION or plan.get("planID") != plan_id or plan.get("home") != str(home) or not plan.get("processCheck") or not plan["createdAt"] <= time.time() < plan["expiresAt"]:
        raise ReclaimError("비교 계획이 만료되거나 유효하지 않습니다.")
    local, backup, lid, bid = validate_roots(plan["localRoot"], plan["backupRoot"], home,
                                           plan["requireExternal"] if testing else True)
    if lid != plan["localIdentity"] or bid != plan["backupIdentity"]:
        raise ReclaimError("로컬 또는 SSD 폴더가 교체됐습니다. 다시 비교하세요.")
    rows = {row["id"]: row for row in plan["rows"]}
    if any(i not in rows or rows[i]["status"] != "identical" for i in selected):
        raise ReclaimError("삭제 가능한 비교 결과에 없는 선택입니다.")
    live_evidence = opened is None
    opened = visible_open_paths() if live_evidence else opened
    evidence_at = time.monotonic()
    # Exclusive creation makes approval single-use, including interrupted runs.
    save_json(state / (plan_id + ".used.json"), {"consumedAt": time.time(), "selected": selected})
    receipt_path = state / (plan_id + ".receipt.json")
    journal_path = state / (plan_id + ".journal.jsonl")
    journal_fd = os.open(journal_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    receipt = dict(schemaVersion=VERSION, planID=plan_id, localRoot=str(local), backupRoot=str(backup),
                   startedAt=time.time(), status="finished", deletedBytes=0, items=[],
                   receiptPath=str(receipt_path), journalPath=str(journal_path),
                   freeBytesBefore=os.statvfs(local).f_bavail * os.statvfs(local).f_frsize)
    try:
        for item_id in selected:
            row = rows[item_id]
            relative = Path(row["path"])
            if relative.is_absolute() or ".." in relative.parts:
                raise ReclaimError("잘못된 상대경로입니다.")
            source, retained = local / relative, backup / relative

            def event(kind, **values):
                payload = dict(at=time.time(), id=item_id, path=row["path"], event=kind, **values)
                encoded = (json.dumps(payload, ensure_ascii=False) + "\n").encode()
                with os.fdopen(os.dup(journal_fd), "ab") as stream:
                    stream.write(encoded)
                    stream.flush()
                    os.fsync(stream.fileno())

            try:
                reason = policy(source, home)
                if reason:
                    raise ReclaimError(reason)
                if root_identity(local) != lid or root_identity(backup) != bid:
                    raise ReclaimError("로컬 또는 SSD 연결이 변경됐습니다.")
                # Bounded refresh; absence from lsof never proves app inactivity.
                if live_evidence and time.monotonic() - evidence_at >= 2:
                    opened = visible_open_paths()
                    evidence_at = time.monotonic()
                amount = delete_one(source, retained, row, opened, event)
                receipt["deletedBytes"] += amount
                receipt["items"].append(dict(id=item_id, path=row["path"], status="deleted", bytes=amount))
            except (OSError, ReclaimError, subprocess.TimeoutExpired) as error:
                event("blocked", reason=str(error))
                receipt["items"].append(dict(id=item_id, path=row["path"], status="blocked", reason=str(error), bytes=0))
                receipt["status"] = "partial"
    except BaseException:
        receipt["status"] = "interrupted"
        raise
    finally:
        os.close(journal_fd)
        receipt["finishedAt"] = time.time()
        try:
            space = os.statvfs(local)
            receipt["freeBytesAfter"] = space.f_bavail * space.f_frsize
        except OSError:
            receipt["freeBytesAfter"] = None
        save_json(receipt_path, receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preview = commands.add_parser("compare")
    preview.add_argument("--local", required=True)
    preview.add_argument("--backup", required=True)
    delete = commands.add_parser("delete")
    delete.add_argument("--plan-id", required=True)
    delete.add_argument("--selected", nargs="+", required=True)
    delete.add_argument("--owner-approved", action="store_true")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        result = scan(args.local, args.backup) if args.command == "compare" else execute(args.plan_id, args.selected, approved=args.owner_approved)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ReclaimError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())
