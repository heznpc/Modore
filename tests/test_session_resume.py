"""Offline recovery preparation: no live provider home or model request."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

import session_resume as resume


SID = "11111111-2222-4333-8444-555555555555"
OTHER = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"


def put_restore(root, files):
    root.mkdir(parents=True, exist_ok=True)
    entries = []
    for relative, content in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        raw = content.encode() if isinstance(content, str) else content
        path.write_bytes(raw)
        entries.append({"path": relative, "kind": "file", "sha256": hashlib.sha256(raw).hexdigest(), "size": len(raw)})
    (root / resume.MANIFEST_NAME).write_text(json.dumps({
        "schemaVersion": 1, "format": "modore-session-recovery",
        "sourceHome": "/gone/mac/user", "files": entries,
    }))
    return root


def codex_log(sid=SID, cwd="/gone/mac/project"):
    return json.dumps({"type": "session_meta", "payload": {"id": sid, "cwd": cwd, "cli_version": "0.139.0"}}) + "\n" + json.dumps({"type": "response_item", "payload": {"text": "PRIVATE FIXTURE TEXT"}}) + "\n"


def claude_log(sid=SID, cwd="/gone/mac/project"):
    return json.dumps({"type": "user", "sessionId": sid, "cwd": cwd,
                       "version": "2.1.197", "message": {"content": "PRIVATE FIXTURE TEXT"}}) + "\n"


@pytest.fixture
def fake_cli(tmp_path):
    """A real subprocess fixture records argv; any resume launch is an error."""
    number = 0
    def make(provider="codex", version=None, compatible=True):
        nonlocal number
        number += 1
        script = tmp_path / f"fake {provider} cli {number}"
        version = version or ("codex-cli 0.139.0" if provider == "codex" else "2.1.197 (Claude Code)")
        help_text = ("Usage: codex resume [SESSION_ID] -C, --cd <DIR> --no-daemon"
                     if provider == "codex" else "Usage: claude --resume [value]") if compatible else "unsupported help"
        script.write_text(f"#!{sys.executable}\n" + "import json, os, sys\n" +
                          f"version={version!r}\nhelp_text={help_text!r}\n" +
                          "assert 'ANTHROPIC_API_KEY' not in os.environ\n" +
                          "assert 'OPENAI_API_KEY' not in os.environ\n" +
                          "assert os.path.isdir(os.environ['HOME'])\n" +
                          "if sys.argv[1:] == ['--version']: print(version)\n" +
                          "elif sys.argv[1:] in (['--help'], ['resume', '--help']): print(help_text)\n" +
                          "else: raise SystemExit('unexpected conversation launch')\n")
        script.chmod(0o700)
        return script
    return make


def test_list_metadata_only_and_never_reads_live_home(tmp_path, monkeypatch):
    restored = put_restore(tmp_path / "restore", {
        f".codex/sessions/2026/09/27/rollout-{SID}.jsonl": codex_log(),
        f".claude/projects/-gone-mac-project/{SID}.jsonl": claude_log(),
        ".codex/auth.json": '{"token":"do-not-copy"}',
    })
    monkeypatch.setenv("CODEX_HOME", str(tmp_path / "nonexistent-live"))
    result = resume.list_sessions(restored)
    assert {s["provider"] for s in result["sessions"]} == {"codex", "claude"}
    assert all(s["workspace"] == "/gone/mac/project" for s in result["sessions"])
    assert "PRIVATE FIXTURE TEXT" not in json.dumps(result)
    assert "do-not-copy" not in json.dumps(result)


def test_codex_copy_and_plan_survive_loss_of_original_restore(tmp_path, fake_cli, monkeypatch):
    relative = f".codex/archived_sessions/2026/09/27/rollout-{SID}.jsonl"
    original = codex_log()
    restored = put_restore(tmp_path / "restore", {
        relative: original, ".codex/auth.json": "PRIVATE AUTH",
        ".codex/state_5.sqlite": b"not-a-database", ".codex/config.toml": "hooks = 'unsafe'",
        f".codex/sessions/2026/09/27/rollout-{OTHER}.jsonl": codex_log(OTHER),
    })
    new_workspace = tmp_path / "new project; $(do-not-run)"
    new_workspace.mkdir()
    home = tmp_path / "isolated codex"
    monkeypatch.setenv("OPENAI_API_KEY", "must-not-enter-probe")
    executable = fake_cli()
    plan = resume.prepare_resume_plan(restored, "Codex", SID, {"/gone/mac": str(tmp_path)},
                                      workspace=new_workspace, provider_home=home, cli_path=executable)
    assert plan["status"] == "ready_to_try"
    assert plan["argv"] == [str(executable), "resume", SID, "-C", str(new_workspace), "--no-daemon"]
    assert plan["environment"] == {"CODEX_HOME": str(home), "HOME": str(home / "user-home")}
    assert plan["providerResumeVerified"] is False
    assert plan["launchRequiresUserAction"] is True
    copied = Path(plan["preparedPaths"][0])
    assert copied.read_text() == original
    assert "archived_sessions" not in str(copied)
    assert not (home / "auth.json").exists()
    assert not (home / "state_5.sqlite").exists()
    assert not (home / "config.toml").exists()
    assert not any(OTHER in str(p) for p in home.rglob("*"))
    restored.rename(tmp_path / "disconnected-backup")
    assert copied.read_text() == original
    assert str(restored) not in json.dumps(plan["argv"] + list(plan["environment"].values()))
    assert copied.stat().st_mode & 0o777 == 0o600


def test_claude_copies_known_sidecars_and_remaps_project(tmp_path, fake_cli):
    project = ".claude/projects/-gone-mac-project"
    restored = put_restore(tmp_path / "restore", {
        f"{project}/{SID}.jsonl": claude_log(),
        f"{project}/{SID}/subagents/agent-one.jsonl": "subagent fixture",
        f"{project}/{SID}/tool-results/result.txt": "tool fixture",
        f".claude/file-history/{SID}/snapshot": "file fixture",
        f".claude/image-cache/{SID}/image.png": b"image fixture",
        f".claude/uploads/{SID}/attachment.txt": "attachment fixture",
        f".claude/tasks/{SID}/1.json": "{}",
        ".claude/.credentials.json": "PRIVATE AUTH",
        ".claude/settings.json": '{"hooks":"unsafe"}',
        f"{project}/memory/MEMORY.md": "not automatically executed",
    })
    workspace = tmp_path / "new-workspace"
    workspace.mkdir()
    home = tmp_path / "claude-home"
    executable = fake_cli("claude")
    plan = resume.prepare_resume_plan(restored, "Claude Code", SID, provider_home=home,
                                      workspace=workspace, cli_path=executable)
    assert plan["status"] == "ready_to_try"
    assert plan["argv"] == [str(executable), "--resume", SID]
    project_name = resume.re.sub(r"[^a-zA-Z0-9]", "-", str(workspace))
    assert (home / "projects" / project_name / f"{SID}.jsonl").read_text() == claude_log()
    assert len(plan["preparedPaths"]) == 7
    assert (home / "file-history" / SID / "snapshot").is_file()
    assert not (home / ".credentials.json").exists()
    assert not (home / "settings.json").exists()
    assert not list(home.rglob("MEMORY.md"))


def test_modern_claude_uses_documented_project_override_for_unicode(tmp_path, fake_cli):
    restored = put_restore(tmp_path / "restore", {f".claude/projects/old/{SID}.jsonl": claude_log()})
    workspace = tmp_path / "새 작업 폴더"
    workspace.mkdir()
    plan = resume.prepare_resume_plan(restored, "claude", SID, workspace=workspace,
                                      provider_home=tmp_path / "isolated", cli_path=fake_cli("claude", "2.1.234 (Claude Code)"))
    assert plan["status"] == "ready_to_try"
    assert plan["environment"]["CLAUDE_CODE_PROJECT_DIR_NAME"] == "modore-" + SID


def test_legacy_claude_refuses_unverified_unicode_mapping(tmp_path, fake_cli):
    restored = put_restore(tmp_path / "restore", {f".claude/projects/old/{SID}.jsonl": claude_log()})
    workspace = tmp_path / "새 작업"
    workspace.mkdir()
    home = tmp_path / "isolated"
    plan = resume.prepare_resume_plan(restored, "claude", SID, workspace=workspace,
                                      provider_home=home, cli_path=fake_cli("claude"))
    assert plan["status"] == "unsupported"
    assert not home.exists()


@pytest.mark.parametrize("provider", ["claude-desktop", "cowork", "cursor", "unknown"])
def test_non_cli_provider_honestly_unsupported(tmp_path, provider):
    plan = resume.prepare_resume_plan(tmp_path, provider, SID, provider_home=tmp_path / "new")
    assert plan["status"] == "unsupported"
    assert not plan["argv"]
    assert not (tmp_path / "new").exists()


def test_refuses_existing_or_live_provider_home(tmp_path, fake_cli, monkeypatch):
    restored = put_restore(tmp_path / "restore", {f".codex/sessions/rollout-{SID}.jsonl": codex_log()})
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    live = tmp_path / "live-codex"
    live.mkdir()
    marker = live / "auth.json"
    marker.write_text("untouched")
    monkeypatch.setenv("CODEX_HOME", str(live))
    for home in (live, live / "new-child", restored / "provider-home"):
        plan = resume.prepare_resume_plan(restored, "codex", SID, workspace=workspace,
                                          provider_home=home, cli_path=fake_cli())
        assert plan["status"] == "unsupported"
    assert marker.read_text() == "untouched"


def test_case_alias_of_live_home_child_is_rejected(tmp_path, monkeypatch):
    live = tmp_path / "LiveProvider"
    live.mkdir()
    monkeypatch.setenv("CODEX_HOME", str(live))
    with pytest.raises(resume.ResumePreparationError, match="겹치는"):
        resume._new_home(tmp_path / "liveprovider" / "new-home", tmp_path / "restore")


def test_refuses_modified_transcript_and_does_not_create_home(tmp_path, fake_cli):
    relative = f".codex/sessions/rollout-{SID}.jsonl"
    restored = put_restore(tmp_path / "restore", {relative: codex_log()})
    (restored / relative).write_text(codex_log() + "tampered\n")
    home = tmp_path / "isolated"
    plan = resume.prepare_resume_plan(restored, "codex", SID, workspace=tmp_path,
                                      provider_home=home, cli_path=fake_cli())
    assert plan["status"] == "unsupported"
    assert "무결성" in plan["limitations"][0]
    assert not home.exists()


def test_symlink_transcript_cannot_escape_restored_tree(tmp_path, fake_cli):
    relative = f".codex/sessions/rollout-{SID}.jsonl"
    restored = put_restore(tmp_path / "restore", {relative: codex_log()})
    outside = tmp_path / "outside.jsonl"
    outside.write_text(codex_log())
    (restored / relative).unlink()
    (restored / relative).symlink_to(outside)
    assert not resume.list_sessions(restored)["sessions"]
    plan = resume.prepare_resume_plan(restored, "codex", SID, workspace=tmp_path,
                                      provider_home=tmp_path / "isolated", cli_path=fake_cli())
    assert plan["status"] == "unsupported"
    assert not (tmp_path / "isolated").exists()


def test_incompatible_cli_and_invalid_id_never_prepare(tmp_path, fake_cli):
    restored = put_restore(tmp_path / "restore", {f".codex/sessions/rollout-{SID}.jsonl": codex_log()})
    for sid, cli in ((SID, fake_cli(compatible=False)), ("--last", fake_cli())):
        plan = resume.prepare_resume_plan(restored, "codex", sid, workspace=tmp_path,
                                          provider_home=tmp_path / "isolated", cli_path=cli)
        assert plan["status"] == "unsupported"
        assert plan["argv"] == []


def test_longest_workspace_mapping_and_standalone_isolated_cli(tmp_path, fake_cli):
    restored = put_restore(tmp_path / "restore", {f".codex/sessions/rollout-{SID}.jsonl": codex_log()})
    workspace = tmp_path / "mapped"
    workspace.mkdir()
    plan = resume.prepare_resume_plan(restored, "codex", SID,
                                      {"/gone": "/does/not/exist", "/gone/mac/project": str(workspace)},
                                      provider_home=tmp_path / "isolated", cli_path=fake_cli())
    assert plan["workingDirectory"] == str(workspace)
    process = subprocess.run([sys.executable, "-I", "-B", resume.__file__, "list", str(restored)],
                             capture_output=True, text=True, check=True)
    assert json.loads(process.stdout)["sessions"][0]["sessionId"] == SID
    assert "PRIVATE FIXTURE TEXT" not in process.stdout


def test_missing_workspace_requires_explicit_new_location(tmp_path, fake_cli):
    restored = put_restore(tmp_path / "restore", {f".codex/sessions/rollout-{SID}.jsonl": codex_log()})
    plan = resume.prepare_resume_plan(restored, "codex", SID, provider_home=tmp_path / "isolated", cli_path=fake_cli())
    assert plan["status"] == "unsupported"
    assert not (tmp_path / "isolated").exists()


def test_backup_restore_prepare_end_to_end_without_original_mac(tmp_path, fake_cli):
    import session_recovery

    old_home = tmp_path / "old-mac-home"
    source = old_home / ".codex" / "sessions" / "2026" / "09" / "27" / f"rollout-{SID}.jsonl"
    source.parent.mkdir(parents=True)
    source.write_text(codex_log())
    auth = old_home / ".codex" / "auth.json"
    auth.write_text("never transfer credentials")
    bundle = tmp_path / "ssd-bundle"
    planned = session_recovery.plan(old_home)
    chosen = [item["id"] for item in planned["items"] if item["available"]]
    session_recovery.backup(bundle, chosen, old_home, include_sensitive=True)
    old_home.rename(tmp_path / "original-mac-unavailable")
    restored = tmp_path / "restored-records"
    receipt = session_recovery.restore(bundle, restored)
    assert receipt["restoredRoot"] == str(restored)
    assert resume.list_sessions(restored)["sessions"][0]["sessionId"] == SID
    workspace = tmp_path / "new-mac-project"
    workspace.mkdir()
    plan = resume.prepare_resume_plan(restored, "codex", SID, workspace=workspace,
                                      provider_home=tmp_path / "new-provider-home", cli_path=fake_cli())
    assert plan["status"] == "ready_to_try"
    assert not (Path(plan["providerHome"]) / "auth.json").exists()
    restored.rename(tmp_path / "restore-offline")
    bundle.rename(tmp_path / "ssd-disconnected")
    assert all(Path(path).is_file() for path in plan["preparedPaths"])
    assert plan["argv"][4] == str(workspace)


def test_codex_multiple_fragments_are_preserved_without_claiming_full_resume(tmp_path, fake_cli):
    restored = put_restore(tmp_path / "restore", {
        f".codex/sessions/2026/09/26/rollout-{SID}.jsonl": codex_log(),
        f".codex/sessions/2026/09/27/rollout-{SID}.jsonl": codex_log(),
    })
    plan = resume.prepare_resume_plan(restored, "codex", SID, workspace=tmp_path,
                                      provider_home=tmp_path / "isolated", cli_path=fake_cli())
    assert plan["status"] == "ready_to_try"
    assert len(plan["preparedPaths"]) == 2
    assert any("다중" in limitation and "미검증" in limitation for limitation in plan["limitations"])


def test_partial_copy_failure_retains_home_but_never_returns_runnable_plan(tmp_path, fake_cli, monkeypatch):
    restored = put_restore(tmp_path / "restore", {f".codex/sessions/rollout-{SID}.jsonl": codex_log()})
    home = tmp_path / "isolated"

    def fail_copy(*args, **kwargs):
        raise OSError("fixture interrupted copy")

    monkeypatch.setattr(resume.shutil, "copyfileobj", fail_copy)
    plan = resume.prepare_resume_plan(restored, "codex", SID, workspace=tmp_path,
                                      provider_home=home, cli_path=fake_cli())
    assert plan["status"] == "unsupported"
    assert plan["argv"] == [] and plan["environment"] == {}
    assert plan["providerHome"] == str(home)
    assert json.loads((home / "modore-resume-state.json").read_text())["state"] == "preparing"
    assert any("남아" in item for item in plan["limitations"])
