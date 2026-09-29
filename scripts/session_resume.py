#!/usr/bin/env python3
"""Prepare an isolated, interactive CLI resume attempt from a verified restore.

This module never launches a conversation, changes a provider database, or reads
the live session home. A preserved transcript and a successful provider resume
are deliberately separate outcomes. ``ready_to_try`` means that local files,
workspace mapping and installed CLI flags are ready; authentication, transcript
compatibility, attachments and actual continuation still need user validation.

Provider references:
https://learn.chatgpt.com/docs/developer-commands?surface=cli
https://learn.chatgpt.com/docs/config-file/config-advanced
https://code.claude.com/docs/en/cli-reference
https://code.claude.com/docs/en/env-vars
https://code.claude.com/docs/en/claude-directory
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unicodedata
import uuid
from pathlib import Path


MANIFEST_NAME = ".modore-recovery-manifest.json"
MAX_METADATA_BYTES = 2 * 1024 * 1024
MAX_METADATA_LINES = 64
ALIASES = {"codex": "codex", "claude": "claude", "claude code": "claude",
           "claude-code": "claude", "claude desktop": "claude-desktop"}
GENERAL_LIMITATIONS = [
    "기록 보존과 제공사 CLI의 실제 재개 성공은 별도입니다. 실제 재개는 아직 미검증입니다.",
    "인증 파일·키체인·API 키를 복사하지 않습니다. 새 환경에서 제공사 로그인이 필요합니다.",
    "프로젝트 파일, 도구, 모델 접근 권한과 외부 연결은 별도로 복원해야 합니다.",
    "기록 본문 속 과거 절대경로는 바꾸지 않습니다. 첨부·체크포인트의 이전 경로는 수동 확인이 필요할 수 있습니다.",
    "설정·후크·플러그인·앱 데이터베이스는 재개용 홈으로 가져오지 않습니다.",
]


class ResumePreparationError(ValueError):
    """The requested restore cannot safely produce a resume plan."""


def _provider(value: str) -> str:
    return ALIASES.get(value.strip().lower(), value.strip().lower())


def _session_id(value: object) -> str | None:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        return None


def _regular_source(root: Path, relative: str) -> Path:
    rel = Path(relative)
    if rel.is_absolute() or not rel.parts or ".." in rel.parts:
        raise ResumePreparationError("복원 목록에 허용되지 않는 상대경로가 있습니다.")
    path = root / rel
    current = root
    for part in rel.parts:
        current = current / part
        if current.is_symlink():
            raise ResumePreparationError("재개 준비에는 심볼릭 링크 원본을 사용할 수 없습니다.")
    if not stat.S_ISREG(path.stat().st_mode):
        raise ResumePreparationError("복원 기록이 일반 파일이 아닙니다.")
    return path


def _manifest(root: Path) -> dict:
    path = _regular_source(root, MANIFEST_NAME)
    if path.stat().st_size > 64 * 1024 * 1024:
        raise ResumePreparationError("복원 목록이 너무 커서 재개 준비를 중단했습니다.")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if (manifest.get("format") != "modore-session-recovery"
            or manifest.get("schemaVersion") != 1
            or not isinstance(manifest.get("files"), list)):
        raise ResumePreparationError("지원되는 Modore 복원 목록이 필요합니다.")
    seen = set()
    for entry in manifest["files"]:
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            raise ResumePreparationError("복원 파일 목록 형식이 올바르지 않습니다.")
        if entry["path"] in seen:
            raise ResumePreparationError("복원 목록에 중복 경로가 있습니다.")
        seen.add(entry["path"])
    return manifest


def _metadata(path: Path, provider: str) -> dict | None:
    """Bounded header parsing; no message text is returned to the caller."""
    read_bytes = 0
    with path.open("rb") as stream:
        for _ in range(MAX_METADATA_LINES):
            line = stream.readline(MAX_METADATA_BYTES - read_bytes + 1)
            read_bytes += len(line)
            if not line or read_bytes > MAX_METADATA_BYTES:
                break
            try:
                row = json.loads(line)
            except (ValueError, UnicodeDecodeError):
                continue
            if not isinstance(row, dict):
                continue
            if provider == "codex":
                if row.get("type") != "session_meta" or not isinstance(row.get("payload"), dict):
                    continue
                info = row["payload"]
                sid = _session_id(info.get("id"))
            else:
                info = row
                sid = _session_id(info.get("sessionId"))
            if sid:
                cwd = info.get("cwd")
                return {"sessionId": sid, "workspace": cwd if isinstance(cwd, str) else None,
                        "recordedVersion": info.get("cli_version") or info.get("version")}
    return None


def list_sessions(restored_root: str | Path) -> dict:
    """List only session identity/workspace metadata from the restored manifest."""
    result: dict = {"sessions": [], "warnings": []}
    try:
        root = Path(restored_root).expanduser().resolve(strict=True)
        manifest = _manifest(root)
        grouped: dict[tuple[str, str], dict] = {}
        for entry in manifest["files"]:
            rel = entry["path"]
            parts = Path(rel).parts
            provider = None
            if len(parts) >= 3 and parts[:2] in ((".codex", "sessions"), (".codex", "archived_sessions")):
                provider = "codex"
            elif len(parts) == 4 and parts[:2] == (".claude", "projects"):
                provider = "claude"
            if provider is None or not rel.endswith(".jsonl") or entry.get("kind") == "symlink":
                continue
            # Orphaned/superseded transcripts are preserved but not a resume target.
            if provider == "claude" and _session_id(Path(rel).stem) is None:
                continue
            try:
                info = _metadata(_regular_source(root, rel), provider)
            except (OSError, ValueError) as error:
                result["warnings"].append(f"기록 메타데이터 확인 불가: {rel}: {error}")
                continue
            if info is None:
                result["warnings"].append(f"지원되는 세션 헤더를 찾지 못했습니다: {rel}")
                continue
            key = (provider, info["sessionId"])
            if key not in grouped:
                grouped[key] = {"id": f"{provider}:{info['sessionId']}", "provider": provider,
                                **info, "label": f"{provider} · {info['sessionId']}",
                                "sourcePath": rel, "sourcePaths": []}
            grouped[key]["sourcePaths"].append(rel)
        result["sessions"] = sorted(grouped.values(), key=lambda item: item["id"])
        result["warnings"].append("Claude Desktop·Cowork·다른 IDE의 앱 자동 재개는 지원하지 않습니다. 해당 기록은 복원본에서 보존됩니다.")
    except (OSError, ValueError) as error:
        result["warnings"].append(str(error))
    return result


def _executable(provider: str, override: str | Path | None) -> str | None:
    candidates = [str(override)] if override else [
        shutil.which("codex" if provider == "codex" else "claude"),
        f"/opt/homebrew/bin/{provider}", f"/usr/local/bin/{provider}",
        str(Path.home() / ".local" / "bin" / provider),
    ]
    if provider == "codex" and not override:
        candidates.append("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    for candidate in candidates:
        if candidate:
            path = Path(candidate).expanduser()
            if path.is_absolute() and path.is_file() and os.access(path, os.X_OK):
                return str(path.resolve())
    return None


def _probe_cli(executable: str, provider: str) -> dict:
    """Only --version/--help, in disposable homes without inherited auth."""
    with tempfile.TemporaryDirectory(prefix="modore-resume-probe-") as temp:
        env = {key: os.environ[key] for key in ("PATH", "LANG", "LC_ALL", "TERM", "TMPDIR") if key in os.environ}
        env.update(HOME=temp, CODEX_HOME=temp + "/codex", CLAUDE_CONFIG_DIR=temp + "/claude",
                   CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1")
        for subdir in ("codex", "claude"):
            Path(temp, subdir).mkdir(mode=0o700)
        results = []
        for arguments in (["--version"], ["resume", "--help"] if provider == "codex" else ["--help"]):
            process = subprocess.run([executable, *arguments], env=env, cwd=temp,
                                     stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
            if process.returncode != 0:
                raise ResumePreparationError("설치된 CLI의 도움말 확인에 실패했습니다.")
            results.append(process.stdout)
    version, help_text = results
    if provider == "codex" and not ("SESSION_ID" in help_text and ("--cd" in help_text or "-C" in help_text)):
        raise ResumePreparationError("설치된 Codex CLI에서 세션 ID와 작업 폴더 지정 지원을 확인하지 못했습니다.")
    if provider == "claude" and "--resume" not in help_text:
        raise ResumePreparationError("설치된 Claude Code CLI에서 --resume 지원을 확인하지 못했습니다.")
    return {"version": version.strip()[:200], "help": help_text}


def _mapped_workspace(original: str | None, mapping: dict | None, override: str | Path | None) -> Path:
    destination = str(override) if override is not None else None
    if destination is None and original and mapping:
        for old, new in sorted(mapping.items(), key=lambda item: len(item[0]), reverse=True):
            if original == old or original.startswith(old.rstrip("/") + "/"):
                destination = str(new).rstrip("/") + original[len(old.rstrip("/")):]
                break
    if not destination:
        raise ResumePreparationError("복원한 프로젝트의 새 작업 폴더를 지정해 주세요.")
    path = Path(destination).expanduser()
    if not path.is_absolute() or not path.is_dir():
        raise ResumePreparationError("새 작업 폴더는 실제 존재하는 절대경로여야 합니다.")
    return path.resolve()


def _new_home(value: str | Path, restored_root: Path) -> Path:
    raw = Path(value).expanduser()
    if not raw.is_absolute() or raw.exists() or raw.is_symlink():
        raise ResumePreparationError("재개용 홈은 아직 존재하지 않는 새 절대경로여야 합니다.")
    home = raw.resolve()
    protected = [restored_root, Path.home() / ".codex", Path.home() / ".claude"]
    for variable in ("CODEX_HOME", "CLAUDE_CONFIG_DIR"):
        if os.environ.get(variable):
            protected.append(Path(os.environ[variable]).expanduser())
    for boundary in protected:
        boundary = boundary.resolve()
        # Path.resolve() follows links but need not normalize spelling on a
        # case-insensitive macOS volume. Protect aliases conservatively even on
        # a case-sensitive test filesystem, including Unicode normalization.
        home_key = unicodedata.normalize("NFC", str(home)).casefold().rstrip(os.sep)
        boundary_key = unicodedata.normalize("NFC", str(boundary)).casefold().rstrip(os.sep)
        if (home_key == boundary_key or home_key.startswith(boundary_key + os.sep)
                or boundary_key.startswith(home_key + os.sep)):
            raise ResumePreparationError("실사용 홈 또는 원본 복원 폴더와 겹치는 위치는 사용할 수 없습니다.")
    if not home.parent.is_dir():
        raise ResumePreparationError("재개용 홈의 상위 폴더가 존재해야 합니다.")
    return home


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _claude_project_name(workspace: Path, version: str, session_id: str) -> tuple[str, dict]:
    match = re.search(r"\b(\d+)\.(\d+)\.(\d+)\b", version)
    numbers = tuple(map(int, match.groups())) if match else None
    if numbers and numbers >= (2, 1, 234):
        name = "modore-" + session_id
        return name, {"CLAUDE_CODE_PROJECT_DIR_NAME": name}
    # Legacy Claude Code project directories encode every non-ASCII-alphanumeric
    # character as '-'. Restrict the fallback to the bounded ASCII format tested
    # against installed 2.1.x; newer CLIs support the explicit override above.
    if numbers is None or numbers < (2, 1, 0) or not str(workspace).isascii() or len(str(workspace)) > 180:
        raise ResumePreparationError("이 Claude Code 버전에서 새 작업 폴더 매핑을 확인할 수 없습니다. 최신 CLI가 필요합니다.")
    return re.sub(r"[^a-zA-Z0-9]", "-", str(workspace)), {}


def prepare_resume_plan(restored_root: str | Path, provider: str, session_id: str,
                        workspace_map: dict | None = None, *, provider_home: str | Path,
                        workspace: str | Path | None = None,
                        cli_path: str | Path | None = None) -> dict:
    """Copy one selected session into a new home and return argv, never execute it."""
    provider = _provider(provider)
    plan = {"provider": provider, "sessionId": session_id, "argv": [], "environment": {},
            "workingDirectory": None, "providerHome": None, "status": "unsupported",
            "limitations": list(GENERAL_LIMITATIONS), "sourcePaths": [], "preparedPaths": [],
            "providerResumeVerified": False, "launchRequiresUserAction": True}
    try:
        if provider not in ("codex", "claude"):
            raise ResumePreparationError("이 제공사는 기록 복원만 지원하며 앱 자동 재개는 지원하지 않습니다.")
        sid = _session_id(session_id)
        if sid is None:
            raise ResumePreparationError("재개할 세션의 UUID가 올바르지 않습니다.")
        root = Path(restored_root).expanduser().resolve(strict=True)
        manifest = _manifest(root)
        candidates = [s for s in list_sessions(root)["sessions"] if s["provider"] == provider and s["sessionId"] == sid]
        if len(candidates) != 1:
            raise ResumePreparationError("복원본에서 선택한 세션 기록을 확인할 수 없습니다.")
        session = candidates[0]
        if provider == "claude" and len(session["sourcePaths"]) != 1:
            raise ResumePreparationError("서로 다른 프로젝트에 같은 Claude 세션 ID가 있어 자동 선택하지 않았습니다.")
        working = _mapped_workspace(session.get("workspace"), workspace_map, workspace)
        home = _new_home(provider_home, root)
        executable = _executable(provider, cli_path)
        if executable is None:
            raise ResumePreparationError("호환되는 제공사 CLI를 먼저 설치해 주세요.")
        probe = _probe_cli(executable, provider)
        plan["cliVersion"] = probe["version"]
        environment = {"CODEX_HOME" if provider == "codex" else "CLAUDE_CONFIG_DIR": str(home)}
        # Keep legacy ~/.claude.json and every other home-relative provider write
        # out of the live home as well. No auth/config files are seeded here.
        environment["HOME"] = str(home / "user-home")
        selected: dict[str, Path] = {}
        if provider == "codex":
            for relative in session["sourcePaths"]:
                parts = Path(relative).parts
                selected[relative] = Path("sessions", *parts[2:])
            argv = [executable, "resume", sid, "-C", str(working)]
            if "--no-daemon" in probe["help"]:
                argv.append("--no-daemon")
            plan["limitations"].append("Codex 앱의 SQLite 색인·UI 상태·다른 세션은 옮기지 않습니다. CLI가 이 로그 형식을 읽을 수 있는지는 실제 재개 시 확인합니다.")
            plan["limitations"].append("Codex 첨부·업로드·이미지는 복원 폴더에만 보존하며 재개용 홈으로 복사하지 않습니다. 기록 속 첨부 경로를 다시 연결하기 전에는 첨부를 사용할 수 없을 수 있습니다.")
            if len(session["sourcePaths"]) > 1:
                plan["limitations"].append("동일 ID의 다중 기록 조각을 모두 보존했지만, 제공사 앱의 조각 결합과 전체 문맥 재개는 미검증입니다.")
        else:
            project_name, project_env = _claude_project_name(working, probe["version"], sid)
            environment.update(project_env)
            source = Path(session["sourcePaths"][0])
            selected[str(source)] = Path("projects", project_name, sid + ".jsonl")
            project_prefix = source.parent / sid
            sidecar_roots = [Path(".claude", kind, sid) for kind in ("file-history", "image-cache", "uploads", "tasks")]
            for entry in manifest["files"]:
                relative = Path(entry["path"])
                if project_prefix in relative.parents:
                    selected[str(relative)] = Path("projects", project_name, sid) / relative.relative_to(project_prefix)
                elif any(prefix in relative.parents for prefix in sidecar_roots):
                    selected[str(relative)] = Path(*relative.parts[1:])
            argv = [executable, "--resume", sid]
            plan["limitations"].append("Claude의 선택 세션과 복원본에 있는 subagents·tool-results·file-history·image-cache·uploads·tasks만 준비합니다. 자동 메모리·임시 첨부·다른 세션은 포함하지 않습니다.")
        entries = {entry["path"]: entry for entry in manifest["files"]}
        verified = []
        destinations = set()
        for relative, destination in selected.items():
            entry = entries[relative]
            if entry.get("kind") not in ("file", "sqlite"):
                raise ResumePreparationError("선택 세션에 일반 파일이 아닌 조각이 있어 자동 재개 준비를 중단했습니다.")
            source = _regular_source(root, relative)
            expected = entry.get("sha256")
            digest = _sha256(source)
            if not isinstance(expected, str) or digest != expected:
                raise ResumePreparationError("복원 기록의 무결성이 달라졌습니다. 다시 검증·복원해 주세요.")
            if destination in destinations:
                raise ResumePreparationError("재개용 경로가 중복되어 원본을 자동 선택하지 않았습니다.")
            destinations.add(destination)
            verified.append((source, destination, digest))
        # Exclusive directory creation prevents overwriting another prepared home.
        home.mkdir(mode=0o700)
        plan["providerHome"] = str(home)
        (home / "user-home").mkdir(mode=0o700)
        state_path = home / "modore-resume-state.json"
        state_path.write_text(json.dumps({"state": "preparing", "provider": provider,
                                          "sessionId": sid}), encoding="utf-8")
        state_path.chmod(0o600)
        for source, relative, digest in verified:
            destination = home / relative
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with source.open("rb") as incoming, destination.open("xb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)
            destination.chmod(0o600)
            if _sha256(destination) != digest:
                raise ResumePreparationError("재개 준비 중 파일이 변경되었습니다. 생성된 폴더를 보존하고 재검토해 주세요.")
            plan["preparedPaths"].append(str(destination))
        plan.update(providerHome=str(home), workingDirectory=str(working),
                    originalWorkspace=session.get("workspace"), sessionId=sid,
                    argv=argv, environment=environment, status="ready_to_try",
                    sourcePaths=list(selected))
        receipt = home / "modore-resume-plan.json"
        receipt.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        receipt.chmod(0o600)
        state_path.write_text(json.dumps({"state": "prepared", "provider": provider,
                                          "sessionId": sid}), encoding="utf-8")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        plan["status"] = "unsupported"
        plan["argv"] = []
        plan["environment"] = {}
        plan["limitations"].insert(0, str(error))
        if plan["providerHome"]:
            plan["limitations"].append("새 재개용 폴더에 일부 준비 파일이 남아 있습니다. 자동으로 지우지 않았습니다.")
    return plan


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list", help="복원본에서 세션 메타데이터만 읽습니다")
    listing.add_argument("restored_root")
    prepare = commands.add_parser("prepare", help="격리된 새 홈과 재개 명령을 준비합니다. 실행하지 않습니다")
    prepare.add_argument("restored_root")
    prepare.add_argument("--provider", required=True)
    prepare.add_argument("--session-id", required=True)
    prepare.add_argument("--workspace", required=True)
    prepare.add_argument("--provider-home", required=True)
    prepare.add_argument("--cli-path")
    args = parser.parse_args(argv)
    def cancelled(signum, frame):
        raise ResumePreparationError("재개 준비가 중단되었습니다. 새 폴더에 일부 파일이 남아 있을 수 있습니다.")

    previous = signal.signal(signal.SIGTERM, cancelled)
    try:
        if args.command == "list":
            result = list_sessions(args.restored_root)
        else:
            result = prepare_resume_plan(args.restored_root, args.provider, args.session_id,
                                         workspace=args.workspace, provider_home=args.provider_home,
                                         cli_path=args.cli_path)
    finally:
        signal.signal(signal.SIGTERM, previous)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
