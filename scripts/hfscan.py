#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Hfscan, Modore's Hugging Face cache audit: which downloaded models nothing here loads.

A hub cache is the one big directory a treemap cannot judge. Every entry looks
identical from the outside -- a few gigabytes of weights with an opaque name --
and the only thing that separates "still in use" from "downloaded once for an
experiment two quarters ago" is whether any code on this machine still names it.
Scree answers that question for session stores; this module answers it for
`~/.cache/huggingface/hub`, by the same rule: cross-reference, then report
evidence, never act.

Ported from decant's `ContextProbe.swift` (absorbed 2026-08), with its central
defect inverted. The original returned "unreferenced" whenever the search could
not run -- a missing search root, a failed grep, a bad `--projects` argument all
produced the same answer as a genuinely exhaustive search that found nothing.
One typo could therefore mark an entire hub cache as safe to delete. Absence of
evidence is only evidence of absence when the search actually happened, so here
an incomplete search yields `unknown` for every model and says why. The escape
hatches (`--allow-missing-roots`, `--ignore-unreadable`) exist so the operator
can widen the verdict deliberately, never by accident.

Privacy contract (metadata-only output):
- reads project files only to test whether a model identifier occurs in them;
  file contents are matched in memory and discarded, never retained or emitted;
- the only paths emitted are the files that DO reference a model, masked
  through `scree.mask_text`;
- writes nothing; all output goes to stdout.

Judgment limits (preview-grade evidence, not deletion authorization):
- a model can be referenced by something this search does not read -- a
  notebook output, a compiled binary, a remote config, a shell history, a
  container image, or simply a repository outside the given roots;
- matching is substring-based and case-insensitive, which over-catches (a
  model name appearing in prose counts as a reference). That bias is
  deliberate: over-catching keeps a model, under-catching loses one;
- every verdict carries `evidence: preview` and `requires_revalidation: true`.
  Recovery for a wrong call is a re-download, which costs bandwidth, not work --
  but that is a reason to be calm about mistakes, not to skip revalidation.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Iterable, Optional

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    # Python isolated mode (-I, which CI and the app's runner both use)
    # intentionally omits the script directory. Import only the sibling
    # helper from this resolved, repository-controlled directory.
    sys.path.insert(0, str(SCRIPT_DIR))

from scree import mask_text  # noqa: E402

HUB_DIR_PREFIX = "models--"
DEFAULT_ROOTS = ("~/IdeaProjects",)

# Text-ish files a model identifier could plausibly be named in. Extending this
# set widens the search and can only move verdicts toward `referenced`, which is
# the safe direction; narrowing it is what needs justification.
SEARCHABLE_SUFFIXES = frozenset({
    ".py", ".ipynb", ".pyi", ".cfg", ".ini", ".toml", ".yaml", ".yml", ".json",
    ".jsonl", ".md", ".mdx", ".txt", ".rst", ".env", ".sh", ".bash", ".zsh",
    ".fish", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".svelte", ".vue",
    ".swift", ".rs", ".go", ".java", ".kt", ".kts", ".scala", ".rb", ".lua",
    ".r", ".jl", ".c", ".h", ".cc", ".cpp", ".hpp", ".m", ".mm", ".cs", ".php",
    ".pl", ".sql", ".tf", ".tfvars", ".gradle", ".properties", ".plist",
    ".xml", ".html", ".css", ".scss", ".lock", ".conf", ".service", ".tpl",
})
SEARCHABLE_NAMES = frozenset({
    "Dockerfile", "Containerfile", "Makefile", "Justfile", "Procfile",
    "requirements.txt", "Pipfile", "environment.yml", ".env",
})

# Build output and dependency trees. A model named only inside one of these is
# named in a file that was generated from a source file the search does read.
SKIP_DIRS = frozenset({
    ".git", ".hg", ".svn", "node_modules", "__pycache__", ".mypy_cache",
    ".pytest_cache", ".ruff_cache", ".tox", ".venv", "venv", "env",
    ".build", "build", "dist", "target", "out", ".next", ".nuxt", ".svelte-kit",
    ".gradle", ".terraform", ".idea", ".vscode-test", "DerivedData", "Pods",
    ".cache", ".turbo", ".parcel-cache", "coverage", ".DS_Store",
})

MAX_FILE_BYTES = 2 * 1024 * 1024
DEFAULT_MAX_FILES = 200_000


# ---------------------------------------------------------------------------
# Hub discovery
# ---------------------------------------------------------------------------

def hub_path(home: Path, env: Optional[dict] = None) -> Path:
    """The hub cache this machine actually uses.

    `huggingface_hub` resolves HF_HUB_CACHE first, then HF_HOME/hub, then the
    XDG-ish default. Reading the same variables means an operator who moved the
    cache is audited where the cache is, not where it used to be.
    """
    env = os.environ if env is None else env
    explicit = env.get("HF_HUB_CACHE") or env.get("HUGGINGFACE_HUB_CACHE")
    if explicit:
        return Path(explicit).expanduser()
    hf_home = env.get("HF_HOME")
    if hf_home:
        return Path(hf_home).expanduser() / "hub"
    return home / ".cache" / "huggingface" / "hub"


def hub_tokens(dir_name: str) -> list[str]:
    """Search tokens for one hub directory name.

    `models--Qwen--Qwen2.5-Coder-1.5B-Instruct` is referenced in code as either
    the full `Qwen/Qwen2.5-Coder-1.5B-Instruct` slug or, in loaders that carry
    the org separately, the bare leaf. Both are matched; the bare leaf is the
    looser of the two and is what keeps a model when only half of it is named.
    """
    if not dir_name.startswith(HUB_DIR_PREFIX):
        return [dir_name] if dir_name else []
    parts = [p for p in dir_name[len(HUB_DIR_PREFIX):].split("--") if p]
    if not parts:
        return [dir_name]
    slug = "/".join(parts)
    tokens = {slug, parts[-1]}
    return sorted(t for t in tokens if t)


def _tree_size(path: Path) -> tuple[int, int]:
    """(bytes, unreadable_dirs) for one model directory.

    Symlinks are counted at link size, not target size: the hub stores each
    revision as symlinks into a shared `blobs/` directory, and following them
    would bill the same weights once per revision.
    """
    total = 0
    unreadable = 0
    for current, _dirnames, filenames in os.walk(path, followlinks=False,
                                                 onerror=lambda _e: None):
        for name in filenames:
            try:
                total += os.lstat(os.path.join(current, name)).st_size
            except OSError:
                unreadable += 1
    return total, unreadable


def collect_models(hub: Path) -> list[dict]:
    models: list[dict] = []
    try:
        entries = sorted(hub.iterdir())
    except OSError:
        return models
    for entry in entries:
        if not entry.name.startswith(HUB_DIR_PREFIX):
            continue
        if not entry.is_dir() or entry.is_symlink():
            continue
        size, unreadable = _tree_size(entry)
        try:
            mtime = entry.stat().st_mtime
        except OSError:
            mtime = 0.0
        models.append({
            "name": entry.name,
            "tokens": hub_tokens(entry.name),
            "size_bytes": size,
            "unreadable_entries": unreadable,
            "last_modified": _iso(mtime) if mtime else None,
        })
    models.sort(key=lambda m: (-m["size_bytes"], m["name"]))
    return models


# ---------------------------------------------------------------------------
# Reference search
# ---------------------------------------------------------------------------

def _is_searchable(name: str) -> bool:
    if name in SEARCHABLE_NAMES:
        return True
    return os.path.splitext(name)[1].lower() in SEARCHABLE_SUFFIXES


def search_references(roots: list[Path], models: list[dict], *,
                      max_files: int = DEFAULT_MAX_FILES,
                      hits_per_model: int = 5) -> tuple[dict[str, list[str]], dict]:
    """One walk over the roots, testing every model's tokens against each file.

    Returns (hits by model name, search stats). The stats are what the verdict
    rests on: a search that was truncated, that could not read part of the tree,
    or that read nothing at all has not established absence, and the caller
    turns that into `unknown` rather than `unreferenced`.
    """
    needles: list[tuple[str, str]] = []
    for model in models:
        for token in model["tokens"]:
            if token:
                needles.append((model["name"], token.lower()))

    hits: dict[str, list[str]] = {m["name"]: [] for m in models}
    stats = {
        "files_scanned": 0,
        "bytes_scanned": 0,
        "files_skipped_large": 0,
        "files_unreadable": 0,
        "dirs_unreadable": 0,
        "truncated": False,
    }
    if not needles:
        return hits, stats

    for root in roots:
        for current, dirnames, filenames in os.walk(
                root, followlinks=False,
                onerror=lambda _e: stats.__setitem__(
                    "dirs_unreadable", stats["dirs_unreadable"] + 1)):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if stats["files_scanned"] >= max_files:
                    stats["truncated"] = True
                    return hits, stats
                if not _is_searchable(name):
                    continue
                full = os.path.join(current, name)
                try:
                    if os.path.getsize(full) > MAX_FILE_BYTES:
                        stats["files_skipped_large"] += 1
                        continue
                    with open(full, "rb") as handle:
                        raw = handle.read(MAX_FILE_BYTES)
                except OSError:
                    stats["files_unreadable"] += 1
                    continue
                stats["files_scanned"] += 1
                stats["bytes_scanned"] += len(raw)
                # Case-insensitive substring: over-catching keeps a model,
                # under-catching loses one, so the loose test is the safe one.
                text = raw.decode("utf-8", errors="ignore").lower()
                if not text:
                    continue
                for model_name, token in needles:
                    if len(hits[model_name]) >= hits_per_model:
                        continue
                    if token in text:
                        if full not in hits[model_name]:
                            hits[model_name].append(full)
    return hits, stats


def search_is_complete(stats: dict, missing_roots: list[str], *,
                       allow_missing_roots: bool,
                       ignore_unreadable: bool) -> tuple[bool, list[str]]:
    """Did the search actually establish that a model is named nowhere?

    This is the inverted decant defect, stated as one function. Every condition
    below is a way for the search to have not happened; each one alone is enough
    to withhold an `unreferenced` verdict.
    """
    reasons: list[str] = []
    if missing_roots and not allow_missing_roots:
        reasons.append("search-root-missing")
    if stats["truncated"]:
        reasons.append("file-cap-reached")
    if stats["files_scanned"] == 0:
        reasons.append("no-files-read")
    if not ignore_unreadable and (stats["dirs_unreadable"] or stats["files_unreadable"]):
        reasons.append("tree-partially-unreadable")
    return (not reasons), reasons


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def _iso(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(ts))


def build_report(home: Path, roots: list[Path], *,
                 max_files: int = DEFAULT_MAX_FILES,
                 allow_missing_roots: bool = False,
                 ignore_unreadable: bool = False,
                 env: Optional[dict] = None) -> dict:
    hub = hub_path(home, env)
    hub_exists = hub.is_dir()
    models = collect_models(hub) if hub_exists else []

    present_roots = [r for r in roots if r.is_dir()]
    missing_roots = [str(r) for r in roots if not r.is_dir()]

    hits, stats = search_references(present_roots, models, max_files=max_files)
    complete, incomplete_reasons = search_is_complete(
        stats, missing_roots,
        allow_missing_roots=allow_missing_roots,
        ignore_unreadable=ignore_unreadable)

    entries = []
    for model in models:
        referenced_by = hits.get(model["name"], [])
        if referenced_by:
            verdict, reason = "referenced", "named-in-project-file"
        elif complete:
            verdict, reason = "unreferenced", "no-occurrence-in-completed-search"
        else:
            verdict, reason = "unknown", "search-incomplete"
        entries.append({
            "name": model["name"],
            "tokens": model["tokens"],
            "size_bytes": model["size_bytes"],
            "last_modified": model["last_modified"],
            "verdict": verdict,
            "reason": reason,
            "referenced_by": [mask_text(p, home) for p in referenced_by],
        })

    unreferenced = [e for e in entries if e["verdict"] == "unreferenced"]
    return {
        "generated_at": _iso(time.time()),
        "hub": {
            "path": mask_text(str(hub), home),
            "exists": hub_exists,
            "model_count": len(entries),
            "total_bytes": sum(e["size_bytes"] for e in entries),
        },
        "search": {
            "roots": [mask_text(str(r), home) for r in present_roots],
            "roots_missing": [mask_text(r, home) for r in missing_roots],
            "complete": complete,
            "incomplete_reasons": incomplete_reasons,
            **stats,
        },
        "models": entries,
        "summary": {
            "referenced": sum(1 for e in entries if e["verdict"] == "referenced"),
            "unreferenced": len(unreferenced),
            "unknown": sum(1 for e in entries if e["verdict"] == "unknown"),
            "unreferenced_bytes": sum(e["size_bytes"] for e in unreferenced),
        },
        "evidence": "preview",
        "requires_revalidation": True,
    }


def _format_size(size_bytes: int) -> str:
    value = float(size_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{value:.1f} TB"


def render_report(report: dict, limit: int) -> str:
    hub = report["hub"]
    search = report["search"]
    summary = report["summary"]
    lines = ["Hugging Face 캐시 감사 (읽기 전용)", ""]

    if not hub["exists"]:
        lines.append(f"허브 캐시가 없습니다: {hub['path']}")
        return "\n".join(lines)

    lines.append(f"허브: {hub['path']}")
    lines.append(f"모델 {hub['model_count']}개 · {_format_size(hub['total_bytes'])}")
    lines.append("")

    if not search["complete"]:
        lines.append("⚠ 검색이 완결되지 않아 '미참조' 판정을 내리지 않습니다.")
        lines.append(f"  사유: {', '.join(search['incomplete_reasons'])}")
        for missing in search["roots_missing"]:
            lines.append(f"  없는 검색 루트: {missing}")
        lines.append("  참조가 없다는 결론은 검색이 실제로 끝났을 때만 성립합니다.")
        lines.append("")
    else:
        lines.append(f"검색 완결: 파일 {search['files_scanned']:,}개 "
                     f"· {_format_size(search['bytes_scanned'])}")
        lines.append("")

    lines.append(f"참조됨 {summary['referenced']} · 미참조 {summary['unreferenced']} "
                 f"· 판정보류 {summary['unknown']}")
    if summary["unreferenced"]:
        lines.append(f"미참조 모델이 차지한 용량: {_format_size(summary['unreferenced_bytes'])}")
    lines.append("")

    shown = report["models"][:limit]
    for model in shown:
        mark = {"referenced": "유지", "unreferenced": "미참조", "unknown": "판정보류"}
        lines.append(f"[{mark[model['verdict']]}] {model['name']} "
                     f"· {_format_size(model['size_bytes'])}")
        if model["referenced_by"]:
            for path in model["referenced_by"][:2]:
                lines.append(f"    참조: {path}")
        else:
            lines.append(f"    {model['reason']}")
    if len(report["models"]) > limit:
        lines.append(f"... 그 외 {len(report['models']) - limit}개 생략")

    lines.append("")
    lines.append("미참조는 삭제 승인이 아니라 preview 증거입니다. 이 검색이 읽지 않는 곳"
                 "(노트북 출력, 컨테이너 이미지, 지정 루트 밖 레포)에서 참조될 수 있습니다.")
    return "\n".join(lines)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Audit the Hugging Face hub cache for models nothing on this machine names.")
    parser.add_argument("--root", action="append", dest="roots", type=Path, default=None,
                        help=f"search root, repeatable (default: {' '.join(DEFAULT_ROOTS)})")
    parser.add_argument("--max-files", type=int, default=DEFAULT_MAX_FILES,
                        help="stop after reading this many files (a truncated search cannot judge)")
    parser.add_argument("--allow-missing-roots", action="store_true",
                        help="judge even though a named search root does not exist "
                             "(off by default: a mistyped root is the classic false orphan)")
    parser.add_argument("--ignore-unreadable", action="store_true",
                        help="judge even though part of the tree could not be read")
    parser.add_argument("--json", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--limit", type=int, default=20, help=argparse.SUPPRESS)
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    raw_roots = args.roots if args.roots else [Path(r) for r in DEFAULT_ROOTS]
    roots = [Path(os.path.expanduser(str(r))) for r in raw_roots]

    report = build_report(
        args.home, roots,
        max_files=args.max_files,
        allow_missing_roots=args.allow_missing_roots,
        ignore_unreadable=args.ignore_unreadable)

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(render_report(report, args.limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
