#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scree 계약 테스트: 교차 도구 조인, 고아·보존·워크트리 판정, 메타데이터 전용 보장."""
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest

import scree


def _jsonl(*objs) -> str:
    return "\n".join(json.dumps(obj) for obj in objs) + "\n"


def _write(path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


@pytest.fixture
def scree_home(tmp_path):
    """가짜 홈: 5개 도구가 같은 워크스페이스를 만졌고, Claude 세션 하나는 고아."""
    home = tmp_path / "home"
    ws1 = tmp_path / "work" / "proj-a"
    ws1.mkdir(parents=True)
    ws2 = tmp_path / "gone" / "proj-b"  # 일부러 만들지 않음 → 고아

    _write(home / ".codex" / "sessions" / "2026" / "08" / "rollout-1.jsonl", _jsonl(
        {"timestamp": "2026-08-01T10:00:00Z", "type": "session_meta", "payload": {
            "id": "s1", "cwd": str(ws1),
            "git": {"branch": "main", "commit_hash": "abc",
                    "repository_url": "git@github.com:heznpc/proj-a.git"}}},
        {"type": "response_item", "payload": {"content": "SECRET_CODEX_CONTENT"}},
    ))
    _write(home / ".claude" / "projects" / str(ws1).replace("/", "-") / "a.jsonl", _jsonl(
        {"type": "summary", "customTitle": "t", "sessionId": "c1"},
        {"type": "user", "cwd": str(ws1), "gitBranch": "main",
         "message": {"content": "SECRET_CLAUDE_CONTENT"}},
    ))
    _write(home / ".claude" / "projects" / str(ws1).replace("/", "-")
           / "c1" / "subagents" / "agent-x.jsonl", _jsonl(
        {"type": "assistant", "message": {"content": "SECRET_SUBAGENT_CONTENT"}},
    ))
    _write(home / ".claude" / "projects" / str(ws2).replace("/", "-") / "b.jsonl", _jsonl(
        {"type": "user", "cwd": str(ws2)},
    ))
    for fork_dir in ("Code", "Kiro"):
        _write(home / "Library" / "Application Support" / fork_dir / "User"
               / "workspaceStorage" / "h1" / "workspace.json",
               json.dumps({"folder": ws1.as_uri()}))
    _write(home / ".gemini" / "projects.json",
           json.dumps({"projects": {str(ws1): {}}}))
    return home, ws1, ws2


def test_cross_tool_group_joins_by_repo(scree_home):
    home, ws1, _ = scree_home
    result = scree.build_scree(home)
    group = next(g for g in result["groups"] if g["key"] == "github.com/heznpc/proj-a")
    assert group["grouped_by"] == "repo"
    assert set(group["tools"]) == {"Codex", "Claude", "VS Code", "Kiro", "Gemini"}
    assert group["tools"]["Claude"] == 1  # weight-0 subtranscript aggregate must not inflate
    assert group["cross_tool"] is True
    assert group["orphan"] is False
    assert group["workspaces"] == [str(ws1)]


def test_subtranscripts_counted_by_size_without_opening(scree_home):
    home, _, _ = scree_home
    result = scree.build_scree(home)
    claude_store = next(s for s in result["stores"] if s["store"] == "Claude")
    assert claude_store["count"] == 2
    assert claude_store["subtranscripts"] == 1
    group = next(g for g in result["groups"] if g["key"] == "github.com/heznpc/proj-a")
    assert group["size_bytes"] > 0


def test_orphan_workspace_is_flagged(scree_home):
    home, _, ws2 = scree_home
    result = scree.build_scree(home)
    group = next(g for g in result["groups"] if g["key"] == f"ws:{ws2}")
    assert group["orphan"] is True
    assert group["orphan_basis"] == "path_missing"  # 판정 근거를 데이터로 명시
    assert group["cross_tool"] is False


def test_cross_tool_group_joins_by_repo_despite_case_variant_workspace(scree_home):
    """Real Gemini registries have been observed recording the identical
    working directory under a different casing than Claude/Codex used for
    the same session (case-insensitive filesystem, e.g. macOS default).
    Before the casefold fix, build_scree's join keys were exact-string, so
    Gemini's differently-cased record silently started its own solo group
    instead of joining the repo-keyed group the other tools shared."""
    home, ws1, _ = scree_home
    variant = str(ws1).replace("proj-a", "PROJ-a")
    assert variant != str(ws1)
    _write(home / ".gemini" / "projects.json",
           json.dumps({"projects": {str(ws1): {}, variant: {}}}))

    result = scree.build_scree(home)
    matches = [g for g in result["groups"] if g["key"] == "github.com/heznpc/proj-a"]
    assert len(matches) == 1
    group = matches[0]
    assert set(group["workspaces"]) == {str(ws1), variant}
    assert group["tools"]["Gemini"] == 2
    assert group["cross_tool"] is True


def test_workspace_only_group_joins_case_variants_without_a_repo_url(tmp_path):
    """No tool in this scenario ever recorded a repo_url (e.g. no git
    remote), so build_scree falls back to its own 'ws:<workspace>' key --
    a separate code path from build_lineage's already-casefolded grouping,
    easy to assume was fixed the same way when it never was."""
    home = tmp_path / "home"
    ws = tmp_path / "work" / "proj-nogit"
    ws.mkdir(parents=True)
    variant = str(ws).replace("proj-nogit", "PROJ-nogit")
    _write(home / ".claude" / "projects" / str(ws).replace("/", "-") / "a.jsonl", _jsonl(
        {"type": "user", "cwd": str(ws)},
    ))
    _write(home / ".gemini" / "projects.json",
           json.dumps({"projects": {variant: {}}}))

    result = scree.build_scree(home)
    ws_groups = [g for g in result["groups"] if g["grouped_by"] == "workspace"]
    assert len(ws_groups) == 1
    group = ws_groups[0]
    assert set(group["workspaces"]) == {str(ws), variant}
    assert group["cross_tool"] is True
    assert set(group["tools"]) == {"Claude", "Gemini"}


def test_vscode_fork_case_duplicate_workspaces_merge_into_one_group(tmp_path):
    """Real VS Code workspaceStorage on this machine independently recorded
    the same project directory twice under different casing (once opened as
    'recipick', once as 'Recipick') -- not a cross-tool scenario, proving
    the casefold gap bites even within a single tool's own records."""
    home = tmp_path / "home"
    ws = tmp_path / "work" / "recipick"
    ws.mkdir(parents=True)
    variant = str(ws).replace("recipick", "Recipick")
    for index, folder in enumerate((str(ws), variant)):
        _write(home / "Library" / "Application Support" / "Code" / "User"
               / "workspaceStorage" / f"h{index}" / "workspace.json",
               json.dumps({"folder": Path(folder).as_uri()}))

    result = scree.build_scree(home)
    ws_groups = [g for g in result["groups"] if g["grouped_by"] == "workspace"]
    assert len(ws_groups) == 1
    assert ws_groups[0]["tools"]["VS Code"] == 2


def test_scree_never_carries_session_content(scree_home):
    home, _, _ = scree_home
    dumped = json.dumps(scree.build_scree(home), ensure_ascii=False)
    assert "SECRET_CODEX_CONTENT" not in dumped
    assert "SECRET_CLAUDE_CONTENT" not in dumped
    assert "SECRET_SUBAGENT_CONTENT" not in dumped
    assert "customTitle" not in dumped


def test_store_statuses_report_missing_tools(scree_home):
    home, _, _ = scree_home
    result = scree.build_scree(home)
    by_name = {s["store"]: s for s in result["stores"]}
    assert by_name["Cursor"]["status"] == "missing"
    assert by_name["Codex"]["count"] == 1
    assert by_name["Claude"]["count"] == 2


@pytest.fixture
def retention_home(tmp_path):
    """보존 판정용: 나이가 통제된 Claude 세션 5개와 살아있는/사라진 워크스페이스."""
    home = tmp_path / "home"
    ws_live = tmp_path / "alive" / "proj"
    ws_live.mkdir(parents=True)
    ws_gone = tmp_path / "gone" / "proj"  # 일부러 만들지 않음
    now = time.time()

    def session(name, workspace, age_days):
        path = (home / ".claude" / "projects"
                / str(workspace).replace("/", "-") / f"{name}.jsonl")
        _write(path, _jsonl({"type": "user", "cwd": str(workspace)}))
        stamp = now - age_days * 86400
        os.utime(path, (stamp, stamp))

    session("s30", ws_live, 30)   # 관측 최고령 → 윈도우 앵커, D-0
    session("s24", ws_live, 24)   # D-6: 살아있는 이야기의 만료 임박
    session("s25", ws_gone, 25)   # D-5: 고아의 만료 임박
    session("s02a", ws_live, 2)   # 안전
    session("s02b", ws_live, 2)
    return home, ws_live, ws_gone


def test_retention_infers_rolling_window(retention_home):
    home, _, _ = retention_home
    retention = scree.build_scree(home)["retention"]
    claude = next(s for s in retention["stores"] if s["store"] == "Claude")
    assert claude["mode"] == "rolling"
    assert claude["window_days"] == 30
    assert claude["stalled"] is False


def test_retention_flags_precarious_boundary(retention_home):
    home, ws_live, ws_gone = retention_home
    expiring = scree.build_scree(home)["retention"]["expiring"]
    assert len(expiring) == 3  # D-0, D-6(살아있음), D-5(고아) — 신선한 세션은 제외
    assert expiring[0]["days_left"] == 0  # 임박순 정렬
    assert all(e["source"].endswith(".jsonl") for e in expiring)  # 보존 실행에 쓸 실물 경로
    alive = [e for e in expiring if e["story_alive"]]
    assert {e["workspace"] for e in alive} == {str(ws_live)}
    gone = next(e for e in expiring if not e["story_alive"])
    assert gone["workspace"] == str(ws_gone)
    assert gone["days_left"] == 5


def test_retention_insufficient_on_small_stores(scree_home):
    home, _, _ = scree_home
    retention = scree.build_scree(home)["retention"]
    claude = next(s for s in retention["stores"] if s["store"] == "Claude")
    assert claude["mode"] == "insufficient"
    assert retention["expiring"] == []


def test_retention_prefers_configured_indefinite_over_guessed_window(retention_home):
    """The bug this guards: a user who set cleanupPeriodDays to effectively
    indefinite a few days ago must never see scree call a 30-day-old, still
    growing session store 'D-day' — that is scree contradicting a fact it
    could have just read instead of guessing."""
    home, _, _ = retention_home
    _write(home / ".claude" / "settings.json", json.dumps({"cleanupPeriodDays": 36500}))
    retention = scree.build_scree(home)["retention"]
    claude = next(s for s in retention["stores"] if s["store"] == "Claude")
    assert claude["mode"] == "configured"
    assert claude["configured_days"] == 36500
    assert "window_days" not in claude
    assert retention["expiring"] == []


def test_retention_uses_configured_window_when_short(retention_home):
    """A real, short configured window is MORE accurate than the observed-age
    guess, not just a way to suppress false positives — every session is
    judged against the real 3-day boundary instead of the guessed 30-day one,
    including the four that are already well past it (negative days_left is
    correct here: they are overdue against the real window, not "about to
    expire" — a stronger signal than the guess would ever have produced)."""
    home, _, _ = retention_home
    _write(home / ".claude" / "settings.json", json.dumps({"cleanupPeriodDays": 3}))
    retention = scree.build_scree(home)["retention"]
    claude = next(s for s in retention["stores"] if s["store"] == "Claude")
    assert claude["mode"] == "configured"
    assert claude["configured_days"] == 3
    expiring = retention["expiring"]
    assert {round(e["days_left"]) for e in expiring} == {1, -21, -22, -27}


def test_retention_local_settings_override_shared_settings(retention_home):
    """settings.local.json overrides settings.json — Claude Code's own
    precedence order, and the only order a local override is worth reading in."""
    home, _, _ = retention_home
    _write(home / ".claude" / "settings.json", json.dumps({"cleanupPeriodDays": 3}))
    _write(home / ".claude" / "settings.local.json", json.dumps({"cleanupPeriodDays": 36500}))
    retention = scree.build_scree(home)["retention"]
    claude = next(s for s in retention["stores"] if s["store"] == "Claude")
    assert claude["configured_days"] == 36500


@pytest.mark.parametrize("payload", [
    "not json at all",
    json.dumps([1, 2, 3]),
    json.dumps({"cleanupPeriodDays": "forever"}),
    json.dumps({"cleanupPeriodDays": -5}),
    json.dumps({"cleanupPeriodDays": True}),
    json.dumps({}),
])
def test_retention_falls_back_to_heuristic_on_unusable_config(retention_home, payload):
    """Any config shape scree cannot trust falls open to the pre-existing
    observed-age heuristic rather than crashing or silently going quiet."""
    home, _, _ = retention_home
    _write(home / ".claude" / "settings.json", payload)
    retention = scree.build_scree(home)["retention"]
    claude = next(s for s in retention["stores"] if s["store"] == "Claude")
    assert claude["mode"] == "rolling"
    assert claude["window_days"] == 30


def test_retention_missing_config_falls_back_to_heuristic(retention_home):
    """No settings.json at all (the case every pre-existing test already
    exercises) must keep behaving exactly as before this change."""
    home, _, _ = retention_home
    retention = scree.build_scree(home)["retention"]
    claude = next(s for s in retention["stores"] if s["store"] == "Claude")
    assert claude["mode"] == "rolling"


@pytest.fixture
def worktree_home(tmp_path):
    """앵커 판정용: 실제 git 레포 + 에이전트 워크트리."""
    if not shutil.which("git"):
        pytest.skip("git 미설치 환경")
    home = tmp_path / "home"
    repo = home / "IdeaProjects" / "repoA"
    repo.mkdir(parents=True)
    config = tmp_path / "gitconfig"
    config.write_text("[user]\n\temail = t@example.com\n\tname = t\n"
                      "[init]\n\tdefaultBranch = main\n", encoding="utf-8")
    env = {**os.environ, "HOME": str(home),
           "GIT_CONFIG_GLOBAL": str(config), "GIT_CONFIG_SYSTEM": "/dev/null"}

    def git(*args, cwd=repo):
        subprocess.run(["git", *args], cwd=cwd, check=True,
                       capture_output=True, env=env)

    git("init", "-q")
    (repo / "f.txt").write_text("x", encoding="utf-8")
    git("add", ".")
    git("commit", "-qm", "init")
    git("worktree", "add", "-q", str(repo / ".claude" / "worktrees" / "wt1"),
        "-b", "feat1")
    return home, repo, git


def test_worktree_protected_without_remote(worktree_home):
    home, _, _ = worktree_home
    items = scree.collect_worktrees(home)["items"]
    wt1 = next(i for i in items if i["path"].endswith("wt1"))
    assert wt1["verdict"] == "protected"  # 원격 어디에도 없는 커밋 = 유일본
    assert wt1["registered"] is True
    assert wt1["unpushed_commits"] >= 1


def test_worktree_rebuildable_after_push_then_dirty_flips_back(worktree_home, tmp_path):
    home, repo, git = worktree_home
    bare = tmp_path / "origin.git"
    git("init", "-q", "--bare", str(bare), cwd=tmp_path)
    git("remote", "add", "origin", str(bare))
    git("push", "-q", "origin", "--all")
    items = scree.collect_worktrees(home)["items"]
    wt1 = next(i for i in items if i["path"].endswith("wt1"))
    assert wt1["verdict"] == "rebuildable"  # 전부 푸시됨 + clean
    assert wt1["evidence"] == "preview"
    assert wt1["requires_revalidation"] is True  # 파괴적 소비자는 재검증 의무
    (repo / ".claude" / "worktrees" / "wt1" / "new.txt").write_text("d", encoding="utf-8")
    items = scree.collect_worktrees(home)["items"]
    wt1 = next(i for i in items if i["path"].endswith("wt1"))
    assert wt1["verdict"] == "protected"  # dirty → 다시 유일본
    assert "requires_revalidation" not in wt1


def test_primary_checkout_stranded_on_feature_branch_is_judged(worktree_home):
    home, repo, git = worktree_home
    items = scree.collect_worktrees(home)["items"]
    assert not any(i.get("stray_checkout") for i in items)  # main 위에선 이탈 아님
    git("checkout", "-q", "-b", "feature/stranded")
    items = scree.collect_worktrees(home)["items"]
    stray = next(i for i in items if i.get("stray_checkout"))
    assert stray["branch"] == "feature/stranded"
    assert stray["verdict"] == "protected"  # 원격에 없는 커밋 = 유일본
    assert stray["path"] == str(repo)


@pytest.mark.parametrize(
    "dirty,unpushed,expected",
    [
        # Both confirmed clean/pushed: the only combination actually safe.
        (False, 0, "rebuildable"),
        # Positive evidence on either side alone is already enough to protect,
        # even with the other signal unknown -- one confirmed risk doesn't
        # need the other check to also have succeeded.
        (True, None, "protected"),
        (None, 5, "protected"),
        (True, 0, "protected"),
        (False, 3, "protected"),
        # Not protected must not be conflated with confirmed safe: if either
        # signal is unknown and neither shows positive evidence, this is the
        # bug scree actually shipped with -- a git command failing partway
        # through (e.g. status succeeds confirming clean, rev-list against
        # remotes fails) used to fall straight through to "rebuildable".
        (False, None, "unreadable"),
        (None, 0, "unreadable"),
        (None, None, "unreadable"),
    ],
)
def test_worktree_verdict_never_calls_partial_information_rebuildable(dirty, unpushed, expected):
    assert scree._worktree_verdict(dirty, unpushed) == expected


def test_worktree_partial_git_failure_is_unreadable_not_rebuildable(worktree_home, monkeypatch):
    """End-to-end proof, not just the isolated helper: collect_worktrees
    itself must produce unreadable when one of its git calls fails, even
    though the repo would otherwise look clean and rebuildable. Pushes the
    fixture's worktree so a real, unpatched run would call it rebuildable,
    then monkeypatches scree._git to fail only the rev-list call -- status
    and log still run for real -- and confirms the verdict flips."""
    home, repo, git = worktree_home
    bare = repo.parent / "origin.git"
    git("init", "-q", "--bare", str(bare), cwd=repo.parent)
    git("remote", "add", "origin", str(bare))
    git("push", "-q", "origin", "--all")

    unpatched = scree._git

    def selectively_failing_git(args, cwd):
        if args and args[0] == "rev-list":
            return None
        return unpatched(args, cwd)

    monkeypatch.setattr(scree, "_git", selectively_failing_git)
    items = scree.collect_worktrees(home)["items"]
    wt1 = next(i for i in items if i["path"].endswith("wt1"))

    assert wt1["dirty"] is False  # status still ran for real and confirmed clean
    assert wt1["unpushed_commits"] is None  # rev-list was the one forced to fail
    assert wt1["verdict"] == "unreadable"
    assert "requires_revalidation" not in wt1  # that flag is rebuildable-only


def test_worktree_anchor_breaks_are_reported(worktree_home):
    home, repo, git = worktree_home
    (repo / ".claude" / "worktrees" / "ghost").mkdir()
    git("worktree", "add", "-q", str(repo / ".claude" / "worktrees" / "wt2"),
        "-b", "feat2")
    shutil.rmtree(repo / ".claude" / "worktrees" / "wt2")
    result = scree.collect_worktrees(home)
    ghost = next(i for i in result["items"] if i["path"].endswith("ghost"))
    assert ghost["registered"] is False
    assert any(e["path"].endswith("wt2") for e in result["registered_missing"])


@pytest.mark.parametrize("raw,expected", [
    ("git@github.com:heznpc/proj-a.git", "github.com/heznpc/proj-a"),
    ("https://github.com/heznpc/proj-a.git", "github.com/heznpc/proj-a"),
    ("ssh://git@github.com:22/heznpc/proj-a", "github.com/heznpc/proj-a"),
])
def test_repo_url_normalization(raw, expected):
    assert scree.normalize_repo_url(raw) == expected


def test_lineage_classifies_paths_and_case_ghosts(tmp_path):
    """세션 기록 속 작업 경로의 보편 사실: 현존/git 여부 + 케이스 유령 병합."""
    home = tmp_path / "home"
    ws_plain = tmp_path / "Work" / "proj-a"
    ws_plain.mkdir(parents=True)
    ws_git = tmp_path / "Work" / "proj-b"
    (ws_git / ".git").mkdir(parents=True)
    ws_gone = tmp_path / "gone" / "proj-c"  # 세션 기록만 남은 소멸 경로
    variant = str(ws_plain).replace("proj-a", "PROJ-A")  # macOS 케이스 유령
    proj = home / ".claude" / "projects" / "p"
    _write(proj / "s1.jsonl", _jsonl({"type": "user", "cwd": str(ws_plain)}))
    _write(proj / "s2.jsonl", _jsonl({"type": "user", "cwd": variant}))
    _write(proj / "s3.jsonl", _jsonl({"type": "user", "cwd": str(ws_git)}))
    _write(proj / "s4.jsonl", _jsonl({"type": "user", "cwd": str(ws_gone)}))

    lineage = scree.build_scree(home)["lineage"]
    assert lineage["summary"] == {"total": 3, "alive_git": 1, "alive_plain": 1,
                                  "vanished": 1, "case_ghosts": 1}
    ghost = next(p for p in lineage["paths"] if p.get("case_variants"))
    assert sorted(ghost["case_variants"]) == sorted([str(ws_plain), variant])
    assert ghost["exists"] is True and ghost["has_git"] is False
    gone = next(p for p in lineage["paths"] if not p["exists"])
    assert gone["path"] == str(ws_gone) and gone["has_git"] is False


# ---- preserve: the one deliberate content-touching path ----------------

def test_mask_text_redacts_known_secret_shapes(tmp_path):
    home = tmp_path / "home"
    masked = scree.mask_text(
        "contact me at ren@example.com, key sk-abcdefghijklmnopqrst, "
        f"token ghp_abcdefghijklmnopqrstuvwx, path {home}/proj, "
        "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dQw4w9WgXcQ_dQw4w9WgXcQ, "
        "-----BEGIN RSA PRIVATE KEY-----\nMIIBogIBAA==\n-----END RSA PRIVATE KEY-----",
        home,
    )
    assert "ren@example.com" not in masked and "<email-redacted>" in masked
    assert "sk-abcdefghijklmnopqrst" not in masked and "<api-key-redacted>" in masked
    assert "ghp_abcdefghijklmnopqrstuvwx" not in masked
    assert str(home) not in masked and "~/proj" in masked
    assert "eyJhbGciOiJIUzI1NiJ9" not in masked and "<jwt-redacted>" in masked
    assert "MIIBogIBAA==" not in masked and "<private-key-redacted>" in masked


def test_preserve_masks_by_default_and_raw_opts_out(tmp_path):
    home = tmp_path / "home"
    session = home / ".claude" / "projects" / "p" / "s.jsonl"
    _write(session, _jsonl(
        {"type": "user", "message": {"role": "user",
         "content": [{"type": "text", "text": "my email is secret@example.com"}]}},
    ))
    masked = scree.render_preserve(session, home, raw=False)
    assert "secret@example.com" not in masked
    assert "<email-redacted>" in masked
    raw = scree.render_preserve(session, home, raw=True)
    assert "secret@example.com" in raw


def test_preserve_is_single_file_only_no_bulk_export():
    # No parameter accepts a directory, glob, or list — the function signature
    # itself is the single-session guarantee, not a runtime check.
    import inspect
    params = list(inspect.signature(scree.render_preserve).parameters)
    assert params == ["source", "home", "raw"]


def test_preserve_refuses_oversized_file(tmp_path, monkeypatch):
    session = tmp_path / "big.jsonl"
    session.write_text("{}\n", encoding="utf-8")
    monkeypatch.setattr(scree, "MAX_PRESERVE_BYTES", 1)
    with pytest.raises(ValueError, match="exceeds"):
        scree.render_preserve(session, tmp_path, raw=False)


def test_preserve_missing_source_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        scree.render_preserve(tmp_path / "nope.jsonl", tmp_path, raw=False)


def test_cli_preserve_writes_masked_file(tmp_path, capsys):
    home = tmp_path / "home"
    session = home / "s.jsonl"
    _write(session, _jsonl(
        {"type": "user", "message": {"role": "user",
         "content": [{"type": "text", "text": "call me at ren@example.com"}]}},
    ))
    out = tmp_path / "out.md"
    rc = scree.main(["preserve", str(session), "--home", str(home), "--out", str(out)])
    assert rc == 0
    assert "ren@example.com" not in out.read_text(encoding="utf-8")
    assert "<email-redacted>" in out.read_text(encoding="utf-8")


def test_cli_report_default_unchanged_without_subcommand(tmp_path, capsys):
    home = tmp_path / "home"
    home.mkdir()
    rc = scree.main(["--json", "--home", str(home)])
    assert rc == 0
    parsed = json.loads(capsys.readouterr().out)
    assert "groups" in parsed and "retention" in parsed
