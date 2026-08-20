#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""hfscan 계약 테스트.

핵심은 fail-safe 반전이다. 원본(decant `ContextProbe.swift`)은 검색이 실행되지
못한 모든 경우를 "미참조"로 보고했고, 그래서 `--projects` 오타 하나가 허브 캐시
전체를 삭제 후보로 만들 수 있었다. 아래 테스트들은 그 실패 경로 하나하나가
`unknown`으로 떨어지는지를 고정한다.
"""
import json
from pathlib import Path

import pytest

import hfscan


def _make_hub(tmp_path: Path, *names: str) -> Path:
    hub = tmp_path / ".cache" / "huggingface" / "hub"
    hub.mkdir(parents=True)
    for name in names:
        model = hub / name / "snapshots" / "abc123"
        model.mkdir(parents=True)
        (model / "config.json").write_text('{"model_type": "test"}', encoding="utf-8")
    return hub


def _report(tmp_path: Path, roots, **kwargs) -> dict:
    return hfscan.build_report(tmp_path, [Path(r) for r in roots], env={}, **kwargs)


# ---------------------------------------------------------------------------
# 토큰 유도
# ---------------------------------------------------------------------------

def test_hub_dir_name_yields_both_the_slug_and_the_bare_model_name():
    assert hfscan.hub_tokens("models--Qwen--Qwen2.5-Coder-1.5B-Instruct") == [
        "Qwen/Qwen2.5-Coder-1.5B-Instruct", "Qwen2.5-Coder-1.5B-Instruct"]


def test_a_name_that_is_not_a_hub_dir_is_used_verbatim():
    assert hfscan.hub_tokens("datasets--foo") == ["datasets--foo"]


def test_adversarial_directory_names_are_data_not_shell():
    """decant pinned this after a shell-injection review; here there is no
    shell at all, so the name simply survives as a literal token."""
    name = "models--evil$(touch PWNED)--x`whoami`"
    tokens = hfscan.hub_tokens(name)
    assert "evil$(touch PWNED)/x`whoami`" in tokens


# ---------------------------------------------------------------------------
# fail-safe 반전 — 이 모듈의 존재 이유
# ---------------------------------------------------------------------------

def test_a_mistyped_search_root_withholds_every_verdict(tmp_path):
    """원본의 치명 결함: 루트가 없으면 전부 orphan이었다."""
    _make_hub(tmp_path, "models--Qwen--Qwen2.5-Coder-1.5B-Instruct")
    report = _report(tmp_path, [tmp_path / "IdeaProjectsTYPO"])

    assert report["search"]["complete"] is False
    assert "search-root-missing" in report["search"]["incomplete_reasons"]
    assert [m["verdict"] for m in report["models"]] == ["unknown"]
    assert report["summary"]["unreferenced"] == 0


def test_a_search_that_read_nothing_withholds_every_verdict(tmp_path):
    _make_hub(tmp_path, "models--Qwen--Q1")
    empty_root = tmp_path / "empty"
    empty_root.mkdir()
    report = _report(tmp_path, [empty_root])

    assert report["search"]["complete"] is False
    assert "no-files-read" in report["search"]["incomplete_reasons"]
    assert [m["verdict"] for m in report["models"]] == ["unknown"]


def test_a_truncated_search_withholds_every_verdict(tmp_path):
    _make_hub(tmp_path, "models--Qwen--Q1")
    root = tmp_path / "proj"
    root.mkdir()
    for i in range(5):
        (root / f"f{i}.py").write_text("print('x')", encoding="utf-8")

    report = _report(tmp_path, [root], max_files=2)
    assert report["search"]["truncated"] is True
    assert "file-cap-reached" in report["search"]["incomplete_reasons"]
    assert [m["verdict"] for m in report["models"]] == ["unknown"]


def test_an_unreadable_subtree_withholds_every_verdict(tmp_path):
    _make_hub(tmp_path, "models--Qwen--Q1")
    root = tmp_path / "proj"
    (root / "open").mkdir(parents=True)
    (root / "open" / "a.py").write_text("x = 1", encoding="utf-8")
    locked = root / "locked"
    locked.mkdir()
    (locked / "b.py").write_text("x = 2", encoding="utf-8")
    locked.chmod(0o000)
    try:
        report = _report(tmp_path, [root])
        if report["search"]["dirs_unreadable"] == 0:
            pytest.skip("running as a user that can read a 0o000 directory")
        assert report["search"]["complete"] is False
        assert "tree-partially-unreadable" in report["search"]["incomplete_reasons"]
        assert [m["verdict"] for m in report["models"]] == ["unknown"]
    finally:
        locked.chmod(0o700)


def test_widening_the_verdict_takes_an_explicit_flag(tmp_path):
    """탈출구는 존재하되 오타로는 열리지 않는다."""
    _make_hub(tmp_path, "models--Qwen--Q1")
    root = tmp_path / "proj"
    root.mkdir()
    (root / "a.py").write_text("import torch", encoding="utf-8")

    guarded = _report(tmp_path, [root, tmp_path / "gone"])
    assert [m["verdict"] for m in guarded["models"]] == ["unknown"]

    widened = _report(tmp_path, [root, tmp_path / "gone"], allow_missing_roots=True)
    assert widened["search"]["complete"] is True
    assert [m["verdict"] for m in widened["models"]] == ["unreferenced"]


# ---------------------------------------------------------------------------
# 판정 자체
# ---------------------------------------------------------------------------

def test_a_model_named_in_a_project_file_is_kept(tmp_path):
    _make_hub(tmp_path, "models--Qwen--Qwen2.5-Coder-1.5B-Instruct")
    root = tmp_path / "proj"
    root.mkdir()
    (root / "load.py").write_text(
        'model = "Qwen/Qwen2.5-Coder-1.5B-Instruct"', encoding="utf-8")

    report = _report(tmp_path, [root])
    assert report["search"]["complete"] is True
    model = report["models"][0]
    assert model["verdict"] == "referenced"
    assert model["referenced_by"]


def test_matching_is_case_insensitive_because_over_catching_keeps_a_model(tmp_path):
    _make_hub(tmp_path, "models--Qwen--Qwen2.5-Coder")
    root = tmp_path / "proj"
    root.mkdir()
    (root / "notes.md").write_text("we tried qwen/QWEN2.5-coder here", encoding="utf-8")

    assert _report(tmp_path, [root])["models"][0]["verdict"] == "referenced"


def test_a_completed_search_that_found_nothing_reports_unreferenced(tmp_path):
    _make_hub(tmp_path, "models--Qwen--Q1")
    root = tmp_path / "proj"
    root.mkdir()
    (root / "a.py").write_text("import numpy", encoding="utf-8")

    report = _report(tmp_path, [root])
    assert report["search"]["complete"] is True
    assert report["models"][0]["verdict"] == "unreferenced"
    assert report["models"][0]["reason"] == "no-occurrence-in-completed-search"


def test_an_absent_hub_is_not_an_error(tmp_path):
    report = _report(tmp_path, [tmp_path])
    assert report["hub"]["exists"] is False
    assert report["models"] == []


# ---------------------------------------------------------------------------
# 계약: 증거 등급, 프라이버시, 무쓰기
# ---------------------------------------------------------------------------

def test_every_report_is_labelled_preview_evidence(tmp_path):
    _make_hub(tmp_path, "models--Qwen--Q1")
    root = tmp_path / "proj"
    root.mkdir()
    (root / "a.py").write_text("x = 1", encoding="utf-8")

    report = _report(tmp_path, [root])
    assert report["evidence"] == "preview"
    assert report["requires_revalidation"] is True


def test_emitted_paths_are_masked_through_the_home_path(tmp_path):
    _make_hub(tmp_path, "models--Qwen--Q1")
    root = tmp_path / "proj"
    root.mkdir()
    (root / "a.py").write_text('name = "Qwen/Q1"', encoding="utf-8")

    report = _report(tmp_path, [root])
    referenced = report["models"][0]["referenced_by"][0]
    assert referenced.startswith("~/")
    assert str(tmp_path) not in json.dumps(report, ensure_ascii=False)


def test_file_contents_are_never_emitted(tmp_path):
    _make_hub(tmp_path, "models--Qwen--Q1")
    root = tmp_path / "proj"
    root.mkdir()
    (root / "a.py").write_text('SECRET = "hunter2"\nname = "Qwen/Q1"', encoding="utf-8")

    assert "hunter2" not in json.dumps(_report(tmp_path, [root]), ensure_ascii=False)


def test_the_module_never_writes_and_never_deletes():
    source = Path(hfscan.__file__).read_text(encoding="utf-8")
    for forbidden in ("shutil.rmtree", "os.remove", "os.unlink", "os.rmdir",
                      "write_text", "write_bytes", "subprocess", "os.system",
                      "shell=True"):
        assert forbidden not in source, f"hfscan must not use {forbidden}"


def test_the_renderer_states_that_unreferenced_is_not_authorization(tmp_path):
    _make_hub(tmp_path, "models--Qwen--Q1")
    root = tmp_path / "proj"
    root.mkdir()
    (root / "a.py").write_text("x = 1", encoding="utf-8")

    text = hfscan.render_report(_report(tmp_path, [root]), 20)
    assert "삭제 승인이 아니라" in text


def test_the_renderer_explains_an_incomplete_search_instead_of_judging(tmp_path):
    _make_hub(tmp_path, "models--Qwen--Q1")
    text = hfscan.render_report(_report(tmp_path, [tmp_path / "gone"]), 20)
    assert "검색이 완결되지 않아" in text
    assert "미참조" in text  # 표시는 되되 판정으로는 쓰이지 않는다
