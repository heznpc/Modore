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


@pytest.fixture(autouse=True)
def _no_real_managed_settings(monkeypatch, tmp_path):
    """MANAGED_SETTINGS_PATH is a real, hardcoded system path outside every
    per-test `home` fixture here -- without this, tests would read whatever
    actually exists at /Library/Application Support/ClaudeCode/managed-
    settings.json on the machine running them (e.g. a real enterprise-managed
    Mac), making results depend on host state instead of the fixture. Tests
    that specifically exercise the managed tier override this themselves."""
    monkeypatch.setattr(scree, "MANAGED_SETTINGS_PATH", tmp_path / "unused-managed-settings.json")


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


def test_retention_managed_settings_override_user_settings(retention_home, monkeypatch, tmp_path):
    """Enterprise-managed policy can't be overridden by the user in real
    Claude Code precedence -- even a maximal user override (settings.local.json
    set to "keep forever") must lose to a real managed value."""
    home, _, _ = retention_home
    _write(home / ".claude" / "settings.local.json", json.dumps({"cleanupPeriodDays": 36500}))
    managed_path = tmp_path / "managed-settings.json"
    _write(managed_path, json.dumps({"cleanupPeriodDays": 5}))
    monkeypatch.setattr(scree, "MANAGED_SETTINGS_PATH", managed_path)

    retention = scree.build_scree(home)["retention"]
    claude = next(s for s in retention["stores"] if s["store"] == "Claude")
    assert claude["configured_days"] == 5


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


def test_cli_preserve_creates_missing_output_directory(tmp_path, capsys):
    """--out into a not-yet-existing directory (e.g. a first-time export
    location, such as the app's own preserve output folder) must not crash
    with an uncaught FileNotFoundError -- same clean failure/success
    contract preserve already has on the read side."""
    home = tmp_path / "home"
    session = home / "s.jsonl"
    _write(session, _jsonl(
        {"type": "user", "message": {"role": "user", "content": "hi"}},
    ))
    out = tmp_path / "nested" / "does" / "not" / "exist" / "out.md"
    rc = scree.main(["preserve", str(session), "--home", str(home), "--out", str(out)])
    assert rc == 0
    assert out.is_file()
    assert "hi" in out.read_text(encoding="utf-8")


def test_cli_report_default_unchanged_without_subcommand(tmp_path, capsys):
    home = tmp_path / "home"
    home.mkdir()
    rc = scree.main(["--json", "--home", str(home)])
    assert rc == 0
    parsed = json.loads(capsys.readouterr().out)
    assert "groups" in parsed and "retention" in parsed


# --- bind: 세션↔워크스페이스 결합 -------------------------------------------


@pytest.fixture
def bind_home(tmp_path):
    """레포 1개 + 그 레포의 worktree 1개. Claude 세션은 cwd만, Codex 세션은
    자기 헤더에 remote URL을 적어둔 상태 — 실제 두 공급자의 차이 그대로."""
    home = tmp_path / "home"
    repo = tmp_path / "work" / "flowship"
    worktree = repo / ".claude" / "worktrees" / "wt-1"
    other = tmp_path / "work" / "unrelated"
    for path in (repo, worktree, other):
        path.mkdir(parents=True, exist_ok=True)

    # Claude: 본체 세션 1개(서브에이전트 2개) + worktree 세션 1개 + 무관 세션 1개
    proj = home / ".claude" / "projects" / "-slug-flowship"
    _write(proj / "sess-main.jsonl", _jsonl({"cwd": str(repo), "gitBranch": "main"}))
    for i in range(2):
        _write(proj / "sess-main" / "subagents" / f"agent-{i}.jsonl", _jsonl({"x": i}))
    _write(proj / "sess-wt.jsonl", _jsonl({"cwd": str(worktree)}))
    _write(home / ".claude" / "projects" / "-slug-other" / "sess-other.jsonl",
           _jsonl({"cwd": str(other)}))

    # Codex: remote URL로 묶이는 세션 1개 + cwd로만 묶이는 세션 1개 + 무관 1개
    sessions = home / ".codex" / "sessions"
    _write(sessions / "rollout-a.jsonl", _jsonl({
        "type": "session_meta",
        "payload": {"id": "codex-a", "cwd": str(other),
                    "git": {"repository_url": "git@github.com:heznpc/flowship.git"}},
    }))
    _write(sessions / "rollout-b.jsonl", _jsonl({
        "type": "session_meta", "payload": {"id": "codex-b", "cwd": str(repo), "git": {}},
    }))
    _write(sessions / "rollout-c.jsonl", _jsonl({
        "type": "session_meta", "payload": {"id": "codex-c", "cwd": str(other), "git": {}},
    }))
    return {"home": home, "repo": repo, "worktree": worktree, "other": other}


def test_bind_always_reports_that_an_assessment_happened(bind_home):
    """`assessed`가 이 출력의 존재 이유다. 빈 목록 하나로는 '바인더가 돌았고
    아무것도 없었다'와 '바인더가 안 돌았다'를 구분할 수 없고, 둘을 같게 다루는
    소비자는 아무도 확인하지 않은 워크스페이스를 지운다."""
    nothing = scree.build_bindings(bind_home["home"], str(bind_home["other"] / "nope"))
    assert nothing["assessed"] is True
    assert nothing["bindings"] == []


def test_bind_matches_codex_by_recorded_remote_url_not_path(bind_home):
    """Codex 세션 A는 다른 디렉터리에서 실행됐지만 자기 헤더에 이 레포의 remote를
    적어뒀다. 경로만 보는 결합이 놓치는 바로 그 경우."""
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]),
                               repo_url="https://github.com/heznpc/flowship")
    by_id = {b["sessionId"]: b for b in out["bindings"]}
    assert "codex-a" in by_id
    assert by_id["codex-a"]["evidence"] == ["remote-url"]
    assert by_id["codex-a"]["confidence"] == "high"


def test_bind_claude_never_reaches_high_from_metadata_alone(bind_home):
    """Claude는 remote URL을 기록하지 않는다. 그래서 공급자 메타데이터만으로는
    high가 나올 수 없고, 이 비대칭이 바인더를 공급자별로 나눈 이유다."""
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]),
                               repo_url="https://github.com/heznpc/flowship")
    claude = [b for b in out["bindings"] if b["provider"] == "claude"]
    assert claude, "cwd가 일치하는 Claude 세션은 잡혀야 한다"
    assert all(b["confidence"] == "medium" for b in claude)


def test_bind_includes_worktree_sessions_of_the_same_repo(bind_home):
    """레포를 은퇴시키면 그 레포의 worktree에서 오간 대화도 똑같이 고립된다.
    이 맥에서 실제로 고아가 된 세션은 전부 worktree 쪽이었다."""
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]))
    ids = {b["sessionId"] for b in out["bindings"]}
    assert "sess-wt" in ids


def test_bind_carries_subagent_transcripts(bind_home):
    """공급자 정리는 최상위 파일만 지우고 하위 트리는 남긴다. 최상위만 복사하는
    번들은 보존한 기록의 작은 쪽만 보존한다."""
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]))
    main = next(b for b in out["bindings"] if b["sessionId"] == "sess-main")
    assert len(main["subtranscripts"]) == 2
    assert main["sizeBytes"] > 0


def test_bind_excludes_unrelated_workspaces(bind_home):
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]))
    ids = {b["sessionId"] for b in out["bindings"]}
    assert "sess-other" not in ids
    assert "codex-c" not in ids


def test_bind_works_after_the_workspace_is_deleted(bind_home):
    """고아 세션은 경로가 사라진 뒤에야 문제가 된다. 기록된 cwd 문자열로 묶기
    때문에 결합은 삭제 후에도 성립해야 한다."""
    shutil.rmtree(bind_home["repo"])
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]))
    assert out["assessed"] is True
    assert {b["sessionId"] for b in out["bindings"]} >= {"sess-main", "sess-wt", "codex-b"}


def test_bind_deep_scan_finds_file_access_but_stays_low(bind_home):
    """본문 스캔은 파일을 읽지만 내보내는 것은 증거 유형뿐이다. 그리고 경로를
    읽었다는 사실은 방문을 증명할 뿐 소유를 증명하지 않으므로 low에 머문다."""
    stray = bind_home["home"] / ".claude" / "projects" / "-slug-stray" / "sess-stray.jsonl"
    _write(stray, _jsonl({"cwd": str(bind_home["other"])},
                         {"tool": "Read", "path": f"{bind_home['repo']}/README.md"}))
    shallow = scree.build_bindings(bind_home["home"], str(bind_home["repo"]))
    assert "sess-stray" not in {b["sessionId"] for b in shallow["bindings"]}

    deep = scree.build_bindings(bind_home["home"], str(bind_home["repo"]), deep=True)
    found = next(b for b in deep["bindings"] if b["sessionId"] == "sess-stray")
    assert found["evidence"] == ["file-access"]
    assert found["confidence"] == "low"


def test_bind_does_not_rescan_sessions_already_matched_by_cwd(bind_home):
    """cwd로 이미 묶인 세션은 본문을 읽어도 얻을 게 없다. deep 스캔을 켜도
    증거가 늘지 않아야 비용이 정당화된다."""
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]), deep=True)
    main = next(b for b in out["bindings"] if b["sessionId"] == "sess-main")
    assert main["evidence"] == ["working-directory"]


def test_bind_emits_no_transcript_content(bind_home):
    """report의 metadata-only 계약을 bind가 대신 깨서는 안 된다. 본문을 읽되
    출력에는 세션 id·증거 유형·크기만 남는다."""
    secret = "SUPER-SECRET-PROMPT-TEXT"
    _write(bind_home["home"] / ".claude" / "projects" / "-slug-flowship" / "sess-secret.jsonl",
           _jsonl({"cwd": str(bind_home["repo"])}, {"text": secret}))
    blob = json.dumps(scree.build_bindings(
        bind_home["home"], str(bind_home["repo"]), deep=True), ensure_ascii=False)
    assert secret not in blob


def test_bind_cli_prints_json(bind_home, capsys):
    rc = scree.main(["bind", str(bind_home["repo"]), "--home", str(bind_home["home"])])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["assessed"] is True
    assert payload["summary"]["total"] == len(payload["bindings"])


def test_report_still_emits_no_bindings(bind_home):
    """bind는 별도 명령이다. report는 예전 계약 그대로여야 한다."""
    report = scree.build_scree(bind_home["home"])
    assert "bindings" not in report
    assert "assessed" not in report


def test_bind_output_keys_match_the_swift_decoder(bind_home):
    """MothballCore의 `BindReport`가 요구하는 키 이름을 여기서 고정한다.

    이 계약이 깨지면 Swift 쪽은 `notAssessed`로 떨어진다 — 안전한 방향이지만
    조용하다. 모든 아카이브가 차단되기만 하고 이유는 어디에도 안 나오므로,
    깨진 사실을 여기서 잡아야 한다."""
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]),
                               repo_url="https://github.com/heznpc/flowship")
    assert {"workspace", "repoUrl", "assessed", "deep", "bindings"} <= set(out)
    entry = out["bindings"][0]
    assert set(entry) == {"provider", "sessionId", "source", "subtranscripts",
                          "evidence", "confidence", "sizeBytes"}
    # 열거형 값도 Swift 쪽 rawValue와 1:1이어야 한다. 모르는 값이 오면
    # Swift 디코더는 바인딩을 조용히 빼는 대신 전체를 실패 처리한다.
    assert entry["provider"] in {"claude", "codex"}
    assert entry["confidence"] in {"high", "medium", "low"}
    for binding in out["bindings"]:
        assert set(binding["evidence"]) <= {"remote-url", "working-directory", "file-access"}


def test_preserve_extracts_codex_content_blocks(tmp_path):
    """Codex는 같은 본문을 방향별로 `input_text`/`output_text`로 나눠 적는다.
    `text`만 찾던 동안 모든 Codex 세션이 빈 export가 됐다 — 이 맥 기준 바인딩
    163개 중 147개가 Codex라 대부분이 여기 해당했다."""
    source = tmp_path / "rollout.jsonl"
    _write(source, _jsonl(
        {"type": "session_meta", "payload": {"id": "c1", "cwd": str(tmp_path)}},
        {"type": "response_item",
         "payload": {"type": "message", "role": "user",
                     "content": [{"type": "input_text", "text": "사용자가 물어본 것"}]}},
        {"type": "response_item",
         "payload": {"type": "message", "role": "assistant",
                     "content": [{"type": "output_text", "text": "에이전트가 답한 것"}]}},
    ))
    out = scree.render_preserve(source, tmp_path, raw=True)
    assert "사용자가 물어본 것" in out
    assert "에이전트가 답한 것" in out
    assert "no recognizable turns" not in out


def test_preserve_still_extracts_claude_text_blocks(tmp_path):
    source = tmp_path / "session.jsonl"
    _write(source, _jsonl(
        {"cwd": str(tmp_path)},
        {"message": {"role": "assistant", "content": [{"type": "text", "text": "클로드 응답"}]}},
    ))
    assert "클로드 응답" in scree.render_preserve(source, tmp_path, raw=True)


def test_preserve_masks_by_default(tmp_path):
    """마스킹이 기본이라는 계약은 Codex 경로가 열린 뒤에도 그대로여야 한다."""
    source = tmp_path / "rollout.jsonl"
    _write(source, _jsonl(
        {"type": "response_item",
         "payload": {"type": "message", "role": "user",
                     "content": [{"type": "input_text", "text": "연락처는 someone@example.com 입니다"}]}},
    ))
    masked = scree.render_preserve(source, tmp_path, raw=False)
    assert "someone@example.com" not in masked
    assert "someone@example.com" in scree.render_preserve(source, tmp_path, raw=True)


def test_bind_reports_scan_coverage(bind_home):
    """`assessed`는 실행이 끝났다는 말이고 `coverage`는 어디까지 봤다는 말이다.
    얕은 패스는 기록된 작업 디렉터리만 대조하므로, 아무것도 못 찾았다는 건
    "여기서 실행된 세션이 없다"이지 "이 레포를 건드린 세션이 없다"가 아니다.
    부모 디렉터리에서 작업한 레포는 대화가 전부 부모 밑에 기록된다."""
    shallow = scree.build_bindings(bind_home["home"], str(bind_home["repo"]))
    assert shallow["coverage"] == "shallow"
    deep = scree.build_bindings(bind_home["home"], str(bind_home["repo"]), deep=True)
    assert deep["coverage"] == "complete"


def test_bind_coverage_is_reported_even_when_nothing_is_found(bind_home):
    empty = scree.build_bindings(bind_home["home"], str(bind_home["other"] / "nope"))
    assert empty["assessed"] is True
    assert empty["bindings"] == []
    # 소비자가 "못 찾음"과 "없음을 증명함"을 구분하려면 이 필드가 있어야 한다.
    assert empty["coverage"] == "shallow"


def test_deep_scan_reports_truncation_instead_of_claiming_completeness(bind_home, monkeypatch):
    """`deep`는 "깊게 시도함"이고 `complete`는 "끝까지 확인함"이다. 레포 경로는
    50MB 세션의 마지막 줄에 나올 수도 있으므로, 중간에 멈춘 스캔을 완료로 보고하면
    바인딩이 있는 워크스페이스가 빈 결과로 돌아온다."""
    stray = bind_home["home"] / ".claude" / "projects" / "-slug-big" / "big.jsonl"
    _write(stray, _jsonl({"cwd": str(bind_home["other"])}) + "x" * 4096)
    monkeypatch.setattr(scree, "BINDER_SCAN_CEILING_BYTES", 512)
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]), deep=True)
    assert out["coverage"] == "truncated"


def test_completed_deep_scan_reports_complete(bind_home):
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]), deep=True)
    assert out["coverage"] == "complete"


def test_deep_scan_matches_a_path_split_across_a_read_boundary(bind_home, monkeypatch):
    """청크 경계에 경로가 걸쳐 있으면 전부 읽고도 못 찾는다. 겹침 없이 나눠 읽는
    스캔은 모든 바이트를 읽고도 조용히 불완전하다."""
    target = str(bind_home["repo"])
    # 경로가 1MB 경계를 정확히 가로지르도록 앞을 채운다.
    padding = "y" * ((1 << 20) - len(target) // 2)
    stray = bind_home["home"] / ".claude" / "projects" / "-slug-split" / "split.jsonl"
    _write(stray, _jsonl({"cwd": str(bind_home["other"])}) + padding + target + "\n")
    out = scree.build_bindings(bind_home["home"], target, deep=True)
    assert "split" in {b["sessionId"] for b in out["bindings"]}


# --- coverage 완전성: 실패 경로별 회귀 ------------------------------------


@pytest.fixture
def only_bindable_stores(bind_home, monkeypatch):
    """이 맥에는 Gemini·Kiro·VS Code 저장소가 실제로 있어서 coverage가 항상
    incomplete가 된다. 아래 테스트들은 *다른* 불완전성 원인을 검사하므로,
    바인더 없는 저장소 요인만 제거한 상태에서 본다."""
    monkeypatch.setattr(scree, "unbound_stores_present", lambda home: [])
    return bind_home


def test_coverage_is_complete_when_every_bindable_store_was_read(only_bindable_stores):
    out = scree.build_bindings(only_bindable_stores["home"],
                               str(only_bindable_stores["repo"]), deep=True)
    assert out["coverage"] == "complete"
    assert out["coverageDetail"]["claude"] == "complete"
    assert out["coverageDetail"]["codex"] == "complete"


def test_unreadable_claude_transcript_makes_coverage_incomplete(only_bindable_stores):
    """선행 읽기가 실패한 파일은 '검사했는데 없었다'가 아니라 '검사하지 못했다'다."""
    blocked = only_bindable_stores["home"] / ".claude" / "projects" / "-slug-locked" / "x.jsonl"
    _write(blocked, _jsonl({"cwd": "/somewhere"}))
    blocked.chmod(0o000)
    try:
        out = scree.build_bindings(only_bindable_stores["home"],
                                   str(only_bindable_stores["repo"]), deep=True)
        assert out["coverageDetail"]["claude"] == "incomplete"
        assert out["coverage"] == "truncated"
    finally:
        blocked.chmod(0o644)


def test_unreadable_codex_rollout_makes_coverage_incomplete(only_bindable_stores):
    blocked = only_bindable_stores["home"] / ".codex" / "sessions" / "locked.jsonl"
    _write(blocked, _jsonl({"type": "session_meta", "payload": {"id": "x", "cwd": "/z"}}))
    blocked.chmod(0o000)
    try:
        out = scree.build_bindings(only_bindable_stores["home"],
                                   str(only_bindable_stores["repo"]), deep=True)
        assert out["coverageDetail"]["codex"] == "incomplete"
        assert out["coverage"] == "truncated"
    finally:
        blocked.chmod(0o644)


def test_unrecognized_codex_header_makes_coverage_incomplete(only_bindable_stores):
    """헤더를 못 알아본 롤아웃은 '없는 후보'가 아니라 '못 읽은 후보'다."""
    _write(only_bindable_stores["home"] / ".codex" / "sessions" / "weird.jsonl",
           _jsonl({"type": "something_else", "payload": {}}))
    out = scree.build_bindings(only_bindable_stores["home"],
                               str(only_bindable_stores["repo"]), deep=True)
    assert out["coverageDetail"]["codex"] == "incomplete"
    assert out["coverage"] == "truncated"


def test_store_without_a_binder_blocks_completeness(bind_home, monkeypatch):
    """가장 큰 불완전성은 아예 들여다보지 않은 저장소다. 지금은 알려진 저장소에
    전부 바인더가 있지만, 새 도구가 추가되고 바인더가 안 따라오면 그 순간
    "대화 없음"은 확인한 저장소들에 대한 주장을 전체에 대한 주장처럼 하는 것이
    된다. 그래서 바인더 목록에서 하나를 빼서 규칙 자체를 고정한다."""
    monkeypatch.setattr(scree, "BINDABLE_STORES", scree.BINDABLE_STORES - {"Gemini"})
    (bind_home["home"] / ".gemini" / "tmp").mkdir(parents=True, exist_ok=True)
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]), deep=True)
    assert "Gemini" in out["coverageDetail"]["unboundStores"]
    assert out["coverage"] == "truncated"


def test_unbound_store_detection_ignores_stores_that_are_absent(only_bindable_stores):
    assert scree.unbound_stores_present(only_bindable_stores["home"]) == []


def test_bind_matches_a_workspace_recorded_with_different_casing(bind_home):
    """macOS 기본 파일시스템은 대소문자를 구분하지 않고, provider는 사용자가
    입력한 casing을 그대로 적는다. scree 본체는 이미 같은 워크스페이스가 여러
    casing으로 기록된 걸 실측해서 합치고 있다 — 바인더만 구분하면 바로 그
    기록들을 놓치고, 그 누락은 "이 워크스페이스에서 오간 대화가 없다"로 읽힌다."""
    variant = str(bind_home["repo"]).upper()
    _write(bind_home["home"] / ".claude" / "projects" / "-slug-case" / "cased.jsonl",
           _jsonl({"cwd": variant}))
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]))
    assert "cased" in {b["sessionId"] for b in out["bindings"]}


def test_deep_scan_matches_file_access_with_different_casing(bind_home):
    variant = str(bind_home["repo"]).upper()
    _write(bind_home["home"] / ".claude" / "projects" / "-slug-cased-access" / "acc.jsonl",
           _jsonl({"cwd": str(bind_home["other"])},
                  {"tool": "Read", "path": f"{variant}/README.md"}))
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]), deep=True)
    found = next(b for b in out["bindings"] if b["sessionId"] == "acc")
    assert found["evidence"] == ["file-access"]


# --- Gemini / 에디터 계열 바인더 -------------------------------------------


def _gemini_session(home, workspace, session_id, project_path=None):
    import hashlib
    target = project_path or workspace
    digest = hashlib.sha256(str(target).encode("utf-8")).hexdigest()
    path = home / ".gemini" / "tmp" / f"tmp-{session_id}" / "chats" / f"{session_id}.json"
    _write(path, json.dumps({
        "sessionId": session_id, "projectHash": digest,
        "messages": [{"id": 1, "type": "user", "content": "안녕"}],
    }))
    return path


def test_bind_gemini_matches_the_recorded_project_hash(bind_home):
    """Gemini는 워크스페이스를 sha256(절대경로)로 기록한다 — 접두사 추측이 아니라
    정확한 정체성이다. 이 맥의 실제 저장소에 대조해 확인한 뒤 사용한다."""
    _gemini_session(bind_home["home"], bind_home["repo"], "g1")
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]))
    found = next(b for b in out["bindings"] if b["provider"] == "gemini")
    assert found["sessionId"] == "g1"
    assert found["evidence"] == ["working-directory"]


def test_bind_gemini_includes_registered_subpaths_of_the_workspace(bind_home):
    """해시는 경로 문자열에 대한 것이라 '레포 안인가'를 답하지 못한다.
    projects.json에 등록된 하위 경로도 함께 해시해야 worktree가 레포에 묶인다."""
    sub = bind_home["worktree"]
    _write(bind_home["home"] / ".gemini" / "projects.json",
           json.dumps({"projects": {str(sub): "wt"}}))
    _gemini_session(bind_home["home"], bind_home["repo"], "g2", project_path=sub)
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]))
    assert "g2" in {b["sessionId"] for b in out["bindings"]}


def test_bind_gemini_ignores_other_workspaces(bind_home):
    _gemini_session(bind_home["home"], bind_home["other"], "g3", project_path=bind_home["other"])
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]))
    assert "g3" not in {b["sessionId"] for b in out["bindings"]}


def test_unreadable_gemini_session_makes_coverage_incomplete(only_bindable_stores):
    path = _gemini_session(only_bindable_stores["home"], only_bindable_stores["repo"], "g4")
    path.chmod(0o000)
    try:
        out = scree.build_bindings(only_bindable_stores["home"],
                                   str(only_bindable_stores["repo"]), deep=True)
        assert out["coverageDetail"]["gemini"] == "incomplete"
    finally:
        path.chmod(0o644)


def test_bind_vscode_forks_matches_the_recorded_folder(bind_home):
    """에디터는 트랜스크립트가 아니라 워크스페이스 상태를 남긴다. 그래도 지우면
    사라지는 작업이므로 게이트의 판단 대상이다."""
    entry = (bind_home["home"] / "Library" / "Application Support" / "Code"
             / "User" / "workspaceStorage" / "abc123")
    _write(entry / "workspace.json",
           json.dumps({"folder": f"file://{bind_home['repo']}"}))
    _write(entry / "state.vscdb", "x")
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]))
    found = next(b for b in out["bindings"] if b["provider"] == "vscode")
    assert found["sessionId"] == "abc123"
    assert any(s.endswith("state.vscdb") for s in found["subtranscripts"])


def test_every_known_store_is_now_bindable(bind_home):
    """바인더 없는 저장소가 남아 있으면 coverage는 절대 complete가 될 수 없고,
    게이트는 영원히 차단한다. 이 목록이 비어야 게이트가 실제로 동작한다."""
    for relative in [".gemini/tmp", ".claude/projects", ".codex/sessions"]:
        (bind_home["home"] / relative).mkdir(parents=True, exist_ok=True)
    support = bind_home["home"] / "Library" / "Application Support"
    for _, folder in scree.VSCODE_FORKS:
        (support / folder).mkdir(parents=True, exist_ok=True)
    assert scree.unbound_stores_present(bind_home["home"]) == []
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]), deep=True)
    assert out["coverage"] == "complete"


# --- 제목 추출 (표시 전용) --------------------------------------------------


def _session_with_turns(path, *turns):
    lines = [{"cwd": "/w"}]
    for role, text in turns:
        lines.append({"message": {"role": role, "content": [{"type": "text", "text": text}]}})
    _write(path, _jsonl(*lines))
    return path


def test_title_quotes_the_first_real_request(tmp_path):
    src = _session_with_turns(tmp_path / "s.jsonl", ("user", "결제 오류를 재현하고 고쳐줘"))
    out = scree.build_title(src, tmp_path)
    assert out["title"] == "결제 오류를 재현하고 고쳐줘"
    assert out["titleSource"] == "first-request"


def test_title_skips_resumption_markers(tmp_path):
    """이어서 진행한 세션은 전부 같은 문장으로 시작한다. 그걸 그대로 제목으로
    쓰면 모든 세션 제목이 같아지고, 목록이 아무것도 구분하지 못한다."""
    src = _session_with_turns(
        tmp_path / "s.jsonl",
        ("user", "Continue from where you left off."),
        ("assistant", "네"),
        ("user", "배포 파이프라인을 교체하자"),
    )
    out = scree.build_title(src, tmp_path)
    assert out["title"] == "배포 파이프라인을 교체하자"


def test_title_falls_back_to_resumption_when_that_is_all_there_is(tmp_path):
    src = _session_with_turns(tmp_path / "s.jsonl", ("user", "continue"))
    out = scree.build_title(src, tmp_path)
    assert out["titleSource"] == "resumption"


def test_title_skips_slash_commands_and_wrapped_blocks(tmp_path):
    src = _session_with_turns(
        tmp_path / "s.jsonl",
        ("user", "/continue"),
        ("user", "<system-reminder>무시하세요</system-reminder>"),
        ("user", "API 응답 지연 원인을 조사해줘"),
    )
    assert scree.build_title(src, tmp_path)["title"] == "API 응답 지연 원인을 조사해줘"


def test_title_skips_large_pasted_context(tmp_path):
    """붙여넣은 스택트레이스나 파일은 사용자가 원한 것이 아니라 에이전트에게
    건넨 것이다. 첫 사용자 턴이지만 제목이 되면 안 된다."""
    src = _session_with_turns(
        tmp_path / "s.jsonl",
        ("user", "로그 첨부\n" + "x" * scree.TITLE_PASTE_CHARS),
        ("user", "이 로그에서 원인을 찾아줘"),
    )
    assert scree.build_title(src, tmp_path)["title"] == "이 로그에서 원인을 찾아줘"


def test_title_skips_acknowledgements(tmp_path):
    src = _session_with_turns(tmp_path / "s.jsonl", ("user", "ㅇㅇ"),
                              ("user", "레포 은퇴 패키지를 설계하자"))
    assert scree.build_title(src, tmp_path)["title"] == "레포 은퇴 패키지를 설계하자"


def test_title_is_masked_by_default(tmp_path):
    """제목은 이 모듈이 대화 내용을 처음으로 계속 보관하는 지점이다."""
    src = _session_with_turns(tmp_path / "s.jsonl", ("user", "someone@example.com 로 메일 보내줘"))
    assert "someone@example.com" not in scree.build_title(src, tmp_path)["title"]
    assert "someone@example.com" in scree.build_title(src, tmp_path, raw=True)["title"]


def test_title_is_capped_to_one_short_line(tmp_path):
    src = _session_with_turns(tmp_path / "s.jsonl", ("user", "가" * 300))
    title = scree.build_title(src, tmp_path)["title"]
    assert len(title) <= scree.TITLE_MAX_CHARS
    assert "\n" not in title


def test_title_falls_back_to_the_date_when_nothing_is_readable(tmp_path):
    src = tmp_path / "empty.jsonl"
    _write(src, "")
    out = scree.build_title(src, tmp_path, fallback_label="Claude 작업")
    assert out["titleSource"] == "date"
    assert "Claude 작업" in out["title"]


def test_title_reads_gemini_json_sessions(tmp_path):
    """Gemini는 JSONL이 아니라 단일 JSON이고 content 항목에 type이 없다."""
    src = tmp_path / "g.json"
    _write(src, json.dumps({
        "sessionId": "g1",
        "messages": [{"type": "user", "content": [{"text": "논문 그래프를 다시 그려줘"}]}],
    }))
    out = scree.build_title(src, tmp_path)
    assert out["title"] == "논문 그래프를 다시 그려줘"
    assert out["titleSource"] == "first-request"


def test_title_cli_emits_json(tmp_path, capsys):
    src = _session_with_turns(tmp_path / "s.jsonl", ("user", "빌드 스크립트를 정리해줘"))
    assert scree.main(["title", str(src), "--home", str(tmp_path)]) == 0
    assert json.loads(capsys.readouterr().out)["title"] == "빌드 스크립트를 정리해줘"


def test_codex_rollout_that_names_the_repo_only_later_needs_a_deep_scan(bind_home):
    """`complete`는 '모든 후보 트랜스크립트를 끝까지 읽었다'는 뜻이다. 헤더 한 줄만
    보고 Codex 저장소를 다 읽었다고 판정하면, 다른 곳에서 시작해 나중에 이 레포
    파일을 고친 롤아웃은 shallow에서도 deep에서도 안 잡히면서 coverage는
    complete가 된다."""
    target = str(bind_home["repo"])
    _write(bind_home["home"] / ".codex" / "sessions" / "later.jsonl", _jsonl(
        {"type": "session_meta",
         "payload": {"id": "later", "cwd": str(bind_home["other"]), "git": {}}},
        {"type": "response_item",
         "payload": {"type": "message", "role": "assistant",
                     "content": [{"type": "output_text",
                                  "text": f"{target}/foo.swift 를 수정했습니다"}]}},
    ))
    shallow = scree.build_bindings(bind_home["home"], target)
    assert "later" not in {b["sessionId"] for b in shallow["bindings"]}

    deep = scree.build_bindings(bind_home["home"], target, deep=True)
    found = next(b for b in deep["bindings"] if b["sessionId"] == "later")
    assert found["evidence"] == ["file-access"]
    assert found["provider"] == "codex"


def test_codex_deep_scan_does_not_rescan_headers_that_already_matched(bind_home):
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]),
                               repo_url="https://github.com/heznpc/flowship", deep=True)
    matched = next(b for b in out["bindings"] if b["sessionId"] == "codex-a")
    assert matched["evidence"] == ["remote-url"]


def test_content_reading_commands_are_all_declared_in_the_module_contract():
    """본문을 읽는 명령이 늘어나면 문서가 먼저 뒤처진다. 계약을 코드가 아니라
    사람의 기억에 맡기지 않도록, 세 명령이 모듈 docstring에 이름으로 남아
    있는지 고정한다."""
    doc = scree.__doc__ or ""
    for command in ("preserve", "title", "bind"):
        assert command in doc, f"{command}가 no-content 계약 설명에 없다"
    assert "never" in doc and "names" in doc


def test_title_is_not_reachable_from_the_audit_path(bind_home):
    """감사(report)는 metadata-only여야 한다. 제목은 사용자가 지정한 세션
    하나에 대해서만 만들어지고, 스캔 도중에 자동으로 불리지 않는다."""
    report = scree.build_scree(bind_home["home"])

    # 문자열 검사가 아니라 키 검사다. pytest의 tmp 경로에는 테스트 이름이
    # 들어가므로 부분 문자열로 보면 자기 이름에 걸린다.
    def keys(node):
        if isinstance(node, dict):
            for key, value in node.items():
                yield key
                yield from keys(value)
        elif isinstance(node, list):
            for item in node:
                yield from keys(item)

    emitted = set(keys(report))
    assert "title" not in emitted
    assert "titleSource" not in emitted


def test_gemini_without_a_registry_cannot_claim_completeness(bind_home):
    """projects.json이 없으면 계산 가능한 해시는 워크스페이스 자기 것 하나뿐이라,
    하위 worktree에서 열린 세션은 원리적으로 매칭할 수 없다. 본문 스캔도 구제하지
    못한다 — 트랜스크립트는 보통 상대경로로 파일을 부르므로 끝까지 읽고 못 찾은
    것이 아무것도 증명하지 않는다. 세션은 있는데 워크스페이스 정체성을 역산할
    자료가 없는 상태가 곧 불완전한 확인이다."""
    _gemini_session(bind_home["home"], bind_home["repo"], "g9",
                    project_path=bind_home["worktree"])
    registry = bind_home["home"] / ".gemini" / "projects.json"
    assert not registry.exists()

    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]), deep=True)
    assert "g9" not in {b["sessionId"] for b in out["bindings"]}
    assert out["coverageDetail"]["gemini"] == "incomplete"
    assert out["coverage"] != "complete"


def test_gemini_with_a_registry_can_reach_completeness(bind_home):
    _write(bind_home["home"] / ".gemini" / "projects.json",
           json.dumps({"projects": {str(bind_home["worktree"]): "wt"}}))
    _gemini_session(bind_home["home"], bind_home["repo"], "g10",
                    project_path=bind_home["worktree"])
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]), deep=True)
    assert "g10" in {b["sessionId"] for b in out["bindings"]}
    assert out["coverageDetail"]["gemini"] == "complete"


def test_gemini_with_no_sessions_at_all_is_still_complete(bind_home):
    """chats 자체가 없으면 확인할 후보가 없는 것이지 못 확인한 게 아니다."""
    out = scree.build_bindings(bind_home["home"], str(bind_home["repo"]), deep=True)
    assert out["coverageDetail"]["gemini"] == "complete"
