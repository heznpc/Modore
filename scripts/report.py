#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PC 건강검진 - 크로스플랫폼 i18n HTML 리포트 생성기 (v0.3)

입력: scan_result.json, monitor_result.json(선택), data/explain.json,
      data/report_i18n/<lang>.json

출력: 검사결과.html

의존성: Python 3.7+ 표준 라이브러리만 사용.

사용법:
  python3 report.py
  python3 report.py --lang en
  python3 report.py --scan scan.json --output report.html --lang ja
"""

import argparse
import html
import os
import sys
import urllib.parse
from datetime import datetime
from pathlib import Path

from _jsonutil import load_json


SUPPORTED_SCHEMA = {"1.0"}
SUPPORTED_LANGS = {"ko", "en", "ja"}


# ============================================================
# i18n
# ============================================================
class I18n:
    def __init__(self, lang: str, bundle: dict, explain: dict):
        self.lang = lang
        self.bundle = bundle
        self.explain = explain

    def t(self, key: str, **kwargs) -> str:
        """점 표기법 키 조회 + format 치환. 없으면 키 자체 반환."""
        cur = self.bundle
        for k in key.split("."):
            if not isinstance(cur, dict) or k not in cur:
                return key
            cur = cur[k]
        if not isinstance(cur, str):
            return key
        if kwargs:
            try:
                return cur.format(**kwargs)
            except (KeyError, IndexError):
                return cur
        return cur

    def badge(self, risk: str) -> str:
        label = self.t(f"badges.{risk or 'unknown'}")
        cls = risk if risk in ("danger", "warning", "info", "safe") else "unknown"
        return f'<span class="badge {cls}">{label}</span>'


def load_i18n(lang: str, project_dir: Path, explain_path: Path) -> I18n:
    if lang not in SUPPORTED_LANGS:
        print(f"경고: 지원하지 않는 언어 '{lang}'. 'ko'로 폴백.", file=sys.stderr)
        lang = "ko"
    i18n_path = project_dir / "data" / "report_i18n" / f"{lang}.json"
    if not i18n_path.exists():
        print(f"경고: 번역 파일 없음 {i18n_path}. 'ko' 폴백.", file=sys.stderr)
        i18n_path = project_dir / "data" / "report_i18n" / "ko.json"
        lang = "ko"
    bundle = load_json(i18n_path, default={})
    explain = load_json(explain_path, default={})
    return I18n(lang, bundle, explain)


def detect_lang() -> str:
    """env/CLI 에서 언어 결정."""
    env_lang = os.environ.get("PCH_LANG", "").lower()
    if env_lang in SUPPORTED_LANGS:
        return env_lang
    # LANG/LC_ALL 에서 접두어 추출
    for var in ("LANG", "LC_ALL"):
        val = (os.environ.get(var) or "").lower()
        for code in SUPPORTED_LANGS:
            if val.startswith(code):
                return code
    return "ko"


# ============================================================
# CSS (리포트 HTML 스타일)
# ============================================================
CSS = """
* { box-sizing: border-box; }
body {
  font-family: -apple-system, 'Segoe UI', 'Malgun Gothic', 'Apple SD Gothic Neo', sans-serif;
  margin: 0; padding: 0;
  background: #f4f6fb;
  color: #1f2937;
  line-height: 1.6;
}
.container { max-width: 1200px; margin: 0 auto; padding: 24px; }
h1 { margin: 0 0 8px; font-size: 28px; }
h2 { margin-top: 40px; font-size: 22px; border-bottom: 2px solid #e5e7eb; padding-bottom: 8px; }
.meta { color: #6b7280; font-size: 14px; margin-bottom: 24px; }

.lang-switcher { float: right; margin-top: 4px; font-size: 12px; }
.lang-switcher a { color: #6b7280; text-decoration: none; padding: 2px 6px; border-radius: 3px; font-family: monospace; }
.lang-switcher a.active { background: #1f2937; color: white; }
.lang-switcher a:hover { text-decoration: underline; }

.verdict { padding: 28px; border-radius: 12px; margin: 24px 0; font-size: 18px; font-weight: 500; display: flex; align-items: center; gap: 20px; }
.verdict-safe    { background: #d1fae5; color: #065f46; border-left: 8px solid #10b981; }
.verdict-warning { background: #fef3c7; color: #92400e; border-left: 8px solid #f59e0b; }
.verdict-danger  { background: #fee2e2; color: #991b1b; border-left: 8px solid #ef4444; }
.verdict-icon { font-size: 56px; }
.verdict-text .big { font-size: 24px; font-weight: 700; }

.cards { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; margin: 20px 0; }
.card { background: white; padding: 20px; border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); border-top: 4px solid #e5e7eb; }
.card.danger  { border-top-color: #ef4444; }
.card.warning { border-top-color: #f59e0b; }
.card.safe    { border-top-color: #10b981; }
.card .count { font-size: 36px; font-weight: 700; }
.card .label { color: #6b7280; font-size: 14px; }

.findings { background: white; padding: 16px 20px; border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
.finding { padding: 12px; margin: 8px 0; border-radius: 6px; border-left: 4px solid #e5e7eb; }
.finding.danger  { background: #fef2f2; border-left-color: #ef4444; }
.finding.warning { background: #fffbeb; border-left-color: #f59e0b; }
.finding-title { font-weight: 600; margin-bottom: 4px; }
.finding-detail { font-size: 14px; color: #374151; }

.explain { background: #eff6ff; border-left: 4px solid #3b82f6; padding: 12px 16px; border-radius: 6px; margin: 12px 0; font-size: 14px; }
.explain summary { cursor: pointer; font-weight: 600; color: #1e40af; }
.explain .simple { margin: 8px 0; }
.explain .hint { color: #374151; font-size: 13px; margin: 4px 0; }

table { width: 100%; border-collapse: collapse; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
th { background: #f3f4f6; padding: 10px; text-align: left; font-size: 13px; color: #4b5563; font-weight: 600; }
td { padding: 10px; border-top: 1px solid #f3f4f6; font-size: 14px; vertical-align: top; }
tr.risk-danger { background: #fef2f2; }
tr.risk-warning { background: #fffbeb; }
td.num { text-align: right; font-variant-numeric: tabular-nums; }
td.proc-name { font-weight: 600; }
td.path { font-family: Menlo, Consolas, monospace; font-size: 12px; color: #6b7280; word-break: break-all; max-width: 280px; }
td.note { color: #374151; font-size: 13px; }
td.links a { color: #2563eb; text-decoration: none; font-size: 12px; }
td.links a:hover { text-decoration: underline; }

.badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; white-space: nowrap; }
.badge.danger  { background: #fecaca; color: #991b1b; }
.badge.warning { background: #fed7aa; color: #9a3412; }
.badge.info    { background: #dbeafe; color: #1e40af; }
.badge.safe    { background: #bbf7d0; color: #166534; }
.badge.unknown { background: #e5e7eb; color: #374151; }

.defender-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; background: white; padding: 16px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
.defender-item { padding: 8px; }
.defender-item .label { color: #6b7280; font-size: 12px; }
.defender-item .value { font-weight: 600; font-size: 15px; margin-top: 2px; }
.defender-item .value.on { color: #059669; }
.defender-item .value.off { color: #dc2626; }

.monitor-header { display: flex; gap: 24px; padding: 16px 20px; margin-bottom: 12px; background: white; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
.monitor-header.risk-danger { border-left: 6px solid #ef4444; }
.monitor-header.risk-warning { border-left: 6px solid #f59e0b; }
.monitor-header.risk-safe { border-left: 6px solid #10b981; }
.monitor-metric .label { color: #6b7280; font-size: 12px; }
.monitor-metric .value { font-size: 20px; font-weight: 700; }

.vt-badge { display: inline-block; padding: 2px 6px; border-radius: 3px; font-size: 11px; font-weight: 600; white-space: nowrap; font-family: Menlo, Consolas, monospace; cursor: help; }
.vt-badge.vt-safe    { background: #dcfce7; color: #166534; }
.vt-badge.vt-warning { background: #fed7aa; color: #9a3412; }
.vt-badge.vt-danger  { background: #fecaca; color: #991b1b; }
.vt-badge.vt-unknown { background: #f3f4f6; color: #6b7280; }

.vt-summary { background: #eff6ff; padding: 12px 16px; border-radius: 8px; border-left: 4px solid #3b82f6; margin: 12px 0; font-size: 14px; color: #1e40af; }
.vt-summary.off { background: #f9fafb; color: #6b7280; border-left-color: #9ca3af; }

.action-panel { background: white; padding: 18px 20px; border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,0.06); margin: 16px 0 24px; border-left: 5px solid #3b82f6; }
.action-panel.danger { border-left-color: #ef4444; }
.action-panel.warning { border-left-color: #f59e0b; }
.action-panel.safe { border-left-color: #10b981; }
.action-panel h2 { margin: 0 0 10px; border: 0; padding: 0; font-size: 18px; }
.action-panel ol { margin: 0; padding-left: 22px; }
.action-panel li { margin: 6px 0; }
.share-warning { margin-top: 12px; padding: 10px 12px; background: #fff7ed; color: #9a3412; border-radius: 6px; font-size: 13px; }

.muted { color: #6b7280; font-style: italic; }
.footer { text-align: center; color: #9ca3af; font-size: 12px; margin-top: 40px; }
"""


# ============================================================
# 헬퍼
# ============================================================
def esc(s):
    if s is None:
        return ""
    return html.escape(str(s))


def url_encode(s):
    if s is None:
        return ""
    return urllib.parse.quote(str(s))


def search_links(i18n: I18n, name, path=None, vt_hash=None) -> str:
    q = url_encode(name) + url_encode(i18n.t("links.search_suffix"))
    google = i18n.t("links.google_search")
    links = f'<a href="https://www.google.com/search?q={q}" target="_blank">{esc(google)}</a>'
    if vt_hash:
        vt_label = i18n.t("links.vt_report")
        links += f' · <a href="https://www.virustotal.com/gui/file/{vt_hash}" target="_blank">{esc(vt_label)}</a>'
    elif path:
        fname = url_encode(os.path.basename(str(path)))
        vt_label = i18n.t("links.vt_lookup")
        links += f' · <a href="https://www.virustotal.com/gui/search/{fname}" target="_blank">{esc(vt_label)}</a>'
    return links


def vt_badge(i18n: I18n, vt) -> str:
    if not vt:
        return ""
    if vt.get("status") != "ok":
        if vt.get("status") == "unknown":
            return '<span class="vt-badge vt-unknown" title="?">VT ?</span>'
        return ""
    m = int(vt.get("malicious", 0))
    s = int(vt.get("suspicious", 0))
    total = int(vt.get("totalEngines", 0))
    title = f"{m} / {s} / {total}"
    if m >= 3:
        return f'<span class="vt-badge vt-danger" title="{title}">VT {m}/{total}</span>'
    if m >= 1 or s >= 1:
        return f'<span class="vt-badge vt-warning" title="{title}">VT {m}+{s}/{total}</span>'
    return f'<span class="vt-badge vt-safe" title="{title}">VT 0/{total}</span>'


def vt_ip_badge(vt_ip) -> str:
    if not vt_ip or vt_ip.get("status") != "ok":
        return ""
    m = int(vt_ip.get("malicious", 0))
    s = int(vt_ip.get("suspicious", 0))
    country = vt_ip.get("country") or "?"
    asn = esc(vt_ip.get("asnOwner") or "")
    title = f"{country} · {asn} · malicious {m} suspicious {s}"
    if m >= 3:
        return f'<span class="vt-badge vt-danger" title="{title}">{country} | VT {m}</span>'
    if m >= 1 or s >= 1:
        return f'<span class="vt-badge vt-warning" title="{title}">{country} | VT {m}+{s}</span>'
    return f'<span class="vt-badge vt-safe" title="{title}">{country}</span>'


# ============================================================
# 섹션 렌더러
# ============================================================
def render_cpu_table(i18n: I18n, rows) -> str:
    rows = rows or []
    body = []
    h = i18n.t
    for r in rows:
        vt_hash = (r.get("vt") or {}).get("hash")
        body.append(f"""
<tr class="risk-{r.get('risk','unknown')}">
  <td>{i18n.badge(r.get('risk'))}</td>
  <td class="vt">{vt_badge(i18n, r.get('vt'))}</td>
  <td class="proc-name">{esc(r.get('name'))}</td>
  <td class="num">{esc(r.get('cpu'))}</td>
  <td class="num">{esc(r.get('memoryMB'))}</td>
  <td class="note">{esc(r.get('note'))}</td>
  <td class="path">{esc(r.get('path'))}</td>
  <td class="links">{search_links(i18n, r.get('name'), r.get('path'), vt_hash)}</td>
</tr>""")
    return f"""
<table>
  <thead><tr>
    <th>{esc(h("table_headers.verdict"))}</th>
    <th>{esc(h("table_headers.vt"))}</th>
    <th>{esc(h("table_headers.program"))}</th>
    <th>{esc(h("table_headers.cpu_sec"))}</th>
    <th>{esc(h("table_headers.memory_mb"))}</th>
    <th>{esc(h("table_headers.description"))}</th>
    <th>{esc(h("table_headers.path"))}</th>
    <th>{esc(h("table_headers.investigate"))}</th>
  </tr></thead>
  <tbody>{''.join(body)}</tbody>
</table>"""


def render_autoruns_table(i18n: I18n, rows, show_all=False) -> str:
    if not rows:
        return f'<p class="muted">{i18n.t("muted.autorunsc_disabled")}</p>'

    shown = rows if show_all else [r for r in rows if r.get("risk") in ("danger", "warning", "unknown")]
    hidden = len(rows) - len(shown)

    h = i18n.t
    body = []
    for r in shown:
        sig_badge = ('<span class="vt-badge vt-safe" title="✓">✓</span>'
                     if r.get("verified") else
                     '<span class="vt-badge vt-warning" title="no signature">✗</span>')
        vt_hash = (r.get("vt") or {}).get("hash") or r.get("sha256")
        body.append(f"""
<tr class="risk-{r.get('risk','unknown')}">
  <td>{i18n.badge(r.get('risk'))}</td>
  <td>{sig_badge}</td>
  <td class="vt">{vt_badge(i18n, r.get('vt'))}</td>
  <td>{esc(r.get('category'))}</td>
  <td class="proc-name">{esc(r.get('entry'))}</td>
  <td class="note">{esc(r.get('note'))}</td>
  <td class="path">{esc(r.get('image'))}</td>
  <td class="links">{search_links(i18n, r.get('entry'), r.get('image'), vt_hash)}</td>
</tr>""")
    table = f"""
<table>
  <thead><tr>
    <th>{esc(h("table_headers.verdict"))}</th>
    <th>{esc(h("table_headers.signature"))}</th>
    <th>{esc(h("table_headers.vt"))}</th>
    <th>{esc(h("table_headers.category"))}</th>
    <th>{esc(h("table_headers.entry"))}</th>
    <th>{esc(h("table_headers.description"))}</th>
    <th>{esc(h("table_headers.path"))}</th>
    <th>{esc(h("table_headers.investigate"))}</th>
  </tr></thead>
  <tbody>{''.join(body)}</tbody>
</table>"""
    if not show_all and hidden > 0:
        table += f'<p class="muted">{i18n.t("hidden_rows_note", count=hidden)}</p>'
    return table


def render_network_table(i18n: I18n, rows) -> str:
    rows = rows or []
    h = i18n.t
    body = []
    for r in rows:
        ip = esc(r.get("remoteAddress"))
        vt_label = i18n.t("links.vt_lookup")
        body.append(f"""
<tr class="risk-{r.get('risk','unknown')}">
  <td>{i18n.badge(r.get('risk'))}</td>
  <td class="vt">{vt_ip_badge(r.get('vtIp'))}</td>
  <td class="proc-name">{esc(r.get('process'))}</td>
  <td>{ip}</td>
  <td class="num">{esc(r.get('remotePort'))}</td>
  <td class="note">{esc(r.get('note'))}</td>
  <td class="path">{esc(r.get('path'))}</td>
  <td class="links"><a href="https://www.virustotal.com/gui/ip-address/{ip}" target="_blank">{esc(vt_label)}</a></td>
</tr>""")
    return f"""
<table>
  <thead><tr>
    <th>{esc(h("table_headers.verdict"))}</th>
    <th>{esc(h("table_headers.vt_country"))}</th>
    <th>{esc(h("table_headers.program"))}</th>
    <th>{esc(h("table_headers.remote_ip"))}</th>
    <th>{esc(h("table_headers.port"))}</th>
    <th>{esc(h("table_headers.description"))}</th>
    <th>{esc(h("table_headers.path"))}</th>
    <th>{esc(h("table_headers.investigate"))}</th>
  </tr></thead>
  <tbody>{''.join(body)}</tbody>
</table>"""


def render_simple_table(i18n: I18n, rows, columns) -> str:
    """columns = [{'field': 'name', 'header_key': 'table_headers.name'}, ...]"""
    rows = rows or []
    headers = f'<th>{esc(i18n.t("table_headers.verdict"))}</th>' + \
              "".join(f"<th>{esc(i18n.t(c['header_key']))}</th>" for c in columns)
    body = []
    for r in rows:
        cells = "".join(f"<td>{esc(r.get(c['field']))}</td>" for c in columns)
        body.append(f'<tr class="risk-{r.get("risk","unknown")}">'
                    f'<td>{i18n.badge(r.get("risk"))}</td>{cells}</tr>')
    return f"<table><thead><tr>{headers}</tr></thead><tbody>{''.join(body)}</tbody></table>"


def render_storage_table(i18n: I18n, rows) -> str:
    rows = rows or []
    if not rows:
        return f'<p class="muted">{i18n.t("muted.storage_empty")}</p>'
    h = i18n.t
    body = []
    for r in rows:
        body.append(f"""
<tr class="risk-{r.get('risk','unknown')}">
  <td>{i18n.badge(r.get('risk'))}</td>
  <td>{esc(r.get('kind'))}</td>
  <td class="proc-name">{esc(r.get('label'))}</td>
  <td class="num">{esc(r.get('sizeGB'))}</td>
  <td>{esc(r.get('action'))}</td>
  <td class="note">{esc(r.get('note'))}</td>
  <td class="path">{esc(r.get('path'))}</td>
</tr>""")
    return f"""
<table>
  <thead><tr>
    <th>{esc(h("table_headers.verdict"))}</th>
    <th>{esc(h("table_headers.category"))}</th>
    <th>{esc(h("table_headers.item"))}</th>
    <th>{esc(h("table_headers.size_gb"))}</th>
    <th>{esc(h("table_headers.action"))}</th>
    <th>{esc(h("table_headers.description"))}</th>
    <th>{esc(h("table_headers.path"))}</th>
  </tr></thead>
  <tbody>{''.join(body)}</tbody>
</table>"""


def render_storage_access_table(i18n: I18n, rows) -> str:
    rows = rows or []
    if not rows:
        return ""
    h = i18n.t
    body = []
    for r in rows:
        body.append(f"""
<tr class="risk-{r.get('risk','unknown')}">
  <td>{i18n.badge(r.get('risk'))}</td>
  <td>{esc(r.get('label'))}</td>
  <td>{esc(r.get('status'))}</td>
  <td class="note">{esc(r.get('note'))}</td>
  <td class="path">{esc(r.get('path'))}</td>
</tr>""")
    return f"""
<p class="muted">{esc(h("storage.full_disk_note"))}</p>
<table>
  <thead><tr>
    <th>{esc(h("table_headers.verdict"))}</th>
    <th>{esc(h("table_headers.item"))}</th>
    <th>{esc(h("table_headers.status"))}</th>
    <th>{esc(h("table_headers.description"))}</th>
    <th>{esc(h("table_headers.path"))}</th>
  </tr></thead>
  <tbody>{''.join(body)}</tbody>
</table>"""


def render_storage_runtime_table(i18n: I18n, rows) -> str:
    rows = rows or []
    if not rows:
        return ""
    h = i18n.t
    body = []
    for r in rows:
        body.append(f"""
<tr class="risk-{r.get('risk','unknown')}">
  <td>{i18n.badge(r.get('risk'))}</td>
  <td>{esc(r.get('kind'))}</td>
  <td class="proc-name">{esc(r.get('label'))}</td>
  <td class="num">{esc(r.get('count'))}</td>
  <td>{esc(r.get('action'))}</td>
  <td class="note">{esc(r.get('note'))}</td>
</tr>""")
    return f"""
<table>
  <thead><tr>
    <th>{esc(h("table_headers.verdict"))}</th>
    <th>{esc(h("table_headers.category"))}</th>
    <th>{esc(h("table_headers.item"))}</th>
    <th>{esc(h("table_headers.count"))}</th>
    <th>{esc(h("table_headers.action"))}</th>
    <th>{esc(h("table_headers.description"))}</th>
  </tr></thead>
  <tbody>{''.join(body)}</tbody>
</table>"""


def render_storage(i18n: I18n, storage) -> str:
    if not storage:
        return f'<p class="muted">{i18n.t("muted.storage_unavailable")}</p>'
    h = i18n.t
    volume = storage.get("volume") or {}
    overview = f"""
<div class="findings">
  <p class="muted">{esc(h("storage.decoder_note"))}</p>
  <div class="finding {esc(volume.get('risk', 'unknown'))}">
    <div class="finding-title">{esc(volume.get('mount') or h("storage.volume"))}</div>
    <div class="finding-detail">
      {esc(h("storage.volume_line", free=volume.get("freeGB", 0), used=volume.get("usedGB", 0),
             total=volume.get("totalGB", 0), pct=volume.get("usePercent", 0)))}
      <br>{esc(volume.get("note"))}
    </div>
  </div>
</div>"""
    return (
        overview
        + f'<h3>{esc(h("sections.storage_cleanup"))}</h3>'
        + render_storage_table(i18n, storage.get("cleanupCandidates"))
        + f'<h3>{esc(h("sections.storage_developer"))}</h3>'
        + render_storage_table(i18n, storage.get("developerToolchains"))
        + (f'<h3>{esc(h("sections.storage_runtime"))}</h3>' if storage.get("runtimeSignals") else "")
        + render_storage_runtime_table(i18n, storage.get("runtimeSignals"))
        + (f'<h3>{esc(h("sections.storage_access"))}</h3>' if storage.get("accessIssues") else "")
        + render_storage_access_table(i18n, storage.get("accessIssues"))
    )


def render_monitor(i18n: I18n, m) -> str:
    if not m:
        return f'<p class="muted">{i18n.t("sections.monitor_none")}</p>'
    avg = m.get("averageOverallCpu", 0)
    klass = "danger" if avg > 50 else ("warning" if avg > 20 else "safe")
    h = i18n.t

    body = []
    for a in (m.get("aggregate") or [])[:15]:
        body.append(f"""
<tr class="risk-{a.get('risk','unknown')}">
  <td>{i18n.badge(a.get('risk'))}</td>
  <td class="proc-name">{esc(a.get('name'))}</td>
  <td class="num">{esc(a.get('averagePercent'))}%</td>
  <td class="num">{esc(a.get('maxPercent'))}%</td>
  <td class="note">{esc(a.get('note'))}</td>
  <td class="path">{esc(a.get('path'))}</td>
  <td class="links">{search_links(i18n, a.get('name'), a.get('path'))}</td>
</tr>""")

    return f"""
<div class="monitor-header risk-{klass}">
  <div class="monitor-metric">
    <div class="label">{esc(h("monitor_header.avg_cpu_label"))}</div>
    <div class="value">{avg}%</div>
  </div>
  <div class="monitor-metric">
    <div class="label">{esc(h("monitor_header.duration_label"))}</div>
    <div class="value">{m.get('durationMinutes')}{esc(h("monitor_header.duration_unit"))}</div>
  </div>
  <div class="monitor-metric">
    <div class="label">{esc(h("monitor_header.time_label"))}</div>
    <div class="value">{esc(m.get('monitoredAt'))}</div>
  </div>
</div>
<table>
  <thead><tr>
    <th>{esc(h("table_headers.verdict"))}</th>
    <th>{esc(h("table_headers.program"))}</th>
    <th>{esc(h("table_headers.avg_cpu"))}</th>
    <th>{esc(h("table_headers.max_cpu"))}</th>
    <th>{esc(h("table_headers.description"))}</th>
    <th>{esc(h("table_headers.path"))}</th>
    <th>{esc(h("table_headers.investigate"))}</th>
  </tr></thead>
  <tbody>{''.join(body)}</tbody>
</table>"""


def render_defender(i18n: I18n, d) -> str:
    if not d:
        return f'<p class="muted">{i18n.t("muted.defender_unavailable")}</p>'
    h = i18n.t
    rt = (f'<span class="value on">{esc(h("defender_labels.on"))}</span>'
          if d.get("realtimeEnabled")
          else f'<span class="value off">{esc(h("defender_labels.off"))}</span>')
    av = (f'<span class="value on">{esc(h("defender_labels.on"))}</span>'
          if d.get("antivirusEnabled")
          else f'<span class="value off">{esc(h("defender_labels.off"))}</span>')
    days_old = int(d.get("signatureDaysOld", 0) or 0)
    sig_color = "off" if days_old > 7 else "on"
    days_txt = h("defender_labels.days_ago", days=days_old)
    return f"""
<div class="defender-grid">
  <div class="defender-item"><div class="label">{esc(h("defender_labels.realtime"))}</div>{rt}</div>
  <div class="defender-item"><div class="label">{esc(h("defender_labels.antivirus"))}</div>{av}</div>
  <div class="defender-item"><div class="label">{esc(h("defender_labels.signature"))}</div><div class="value {sig_color}">{esc(d.get('signatureLastUpdated'))} ({esc(days_txt)})</div></div>
  <div class="defender-item"><div class="label">{esc(h("defender_labels.last_quick"))}</div><div class="value">{esc(d.get('lastQuickScan'))}</div></div>
  <div class="defender-item"><div class="label">{esc(h("defender_labels.last_full"))}</div><div class="value">{esc(d.get('lastFullScan'))}</div></div>
</div>"""


def render_macos_security(i18n: I18n, s) -> str:
    if not s:
        return ""
    h = i18n.t
    on_txt = esc(h("defender_labels.enabled"))
    off_txt = esc(h("defender_labels.disabled"))
    gk = (f'<span class="value on">{on_txt}</span>'
          if "enabled" in (s.get("gatekeeper") or "")
          else f'<span class="value off">{off_txt}</span>')
    sip = (f'<span class="value on">{on_txt}</span>'
           if "enabled" in (s.get("sip") or "")
           else f'<span class="value off">{off_txt}</span>')
    xprotect = esc(s.get("xprotectVersion") or h("defender_labels.unknown"))
    return f"""
<div class="defender-grid">
  <div class="defender-item"><div class="label">{esc(h("defender_labels.gatekeeper"))}</div>{gk}</div>
  <div class="defender-item"><div class="label">{esc(h("defender_labels.sip"))}</div>{sip}</div>
  <div class="defender-item"><div class="label">{esc(h("defender_labels.xprotect"))}</div><div class="value">{xprotect}</div></div>
</div>"""


def explain_box(i18n: I18n, key: str) -> str:
    e = (i18n.explain or {}).get(key)
    if not e:
        return ""
    return f"""
<details class="explain">
  <summary>{esc(i18n.t("explain_summary"))}</summary>
  <div class="simple">{esc(e.get('simple'))}</div>
  <div class="hint"><b>{esc(i18n.t("explain_warning"))}</b> {esc(e.get('if_warning'))}</div>
  <div class="hint"><b>{esc(i18n.t("explain_danger"))}</b> {esc(e.get('if_danger'))}</div>
</details>"""


def language_switcher_html(current: str) -> str:
    """리포트 상단에 언어 선택 링크."""
    labels = {"ko": "한국어", "en": "English", "ja": "日本語"}
    parts = []
    for code in ("ko", "en", "ja"):
        cls = "active" if code == current else ""
        parts.append(f'<a href="?lang={code}" class="{cls}" data-lang="{code}">{labels[code]}</a>')
    return '<div class="lang-switcher">' + " · ".join(parts) + "</div>"


def render_action_plan(i18n: I18n, overall: str, findings) -> str:
    h = i18n.t
    level = overall if overall in ("danger", "warning", "safe") else "warning"
    if level == "danger":
        keys = ("actions.danger.1", "actions.danger.2", "actions.danger.3")
    elif level == "warning":
        keys = ("actions.warning.1", "actions.warning.2", "actions.warning.3")
    else:
        keys = ("actions.safe.1", "actions.safe.2", "actions.safe.3")
    items = [h(k) for k in keys]
    if findings:
        items.append(h("actions.common.review_findings", count=len(findings)))
    body = "".join(f"<li>{esc(item)}</li>" for item in items)
    return (
        f'<div class="action-panel {level}">'
        f'<h2>{esc(h("sections.actions"))}</h2>'
        f"<ol>{body}</ol>"
        f'<div class="share-warning">{esc(h("actions.common.share_warning"))}</div>'
        "</div>"
    )


# ============================================================
# 메인 리포트 조립
# ============================================================
def build_report(i18n: I18n, scan, monitor) -> str:
    h = i18n.t
    summary = scan.get("summary", {})
    overall = summary.get("overall", "safe")
    if monitor:
        m_danger = len([a for a in (monitor.get("aggregate") or []) if a.get("risk") == "danger"])
        if m_danger > 0 and overall == "safe":
            overall = "warning"

    verdict_icon = {"safe": "🟢", "warning": "🟡", "danger": "🔴"}.get(overall, "⚪")
    verdict_msg = summary.get("message", "")

    # VT 상태 박스
    vt = (scan.get("sections") or {}).get("virustotal") or {}
    if vt.get("enabled"):
        vt_summary = f'<div class="vt-summary">{h("vt_summary.enabled", calls=vt.get("callsThisScan", 0), hours=vt.get("cacheHours", 0))}</div>'
    else:
        vt_summary = f'<div class="vt-summary off">{h("vt_summary.disabled")}</div>'

    # Findings
    findings = scan.get("findings") or []
    d_f = [f for f in findings if f.get("level") == "danger"]
    w_f = [f for f in findings if f.get("level") == "warning"]
    if not d_f and not w_f:
        findings_html = f'<p class="muted">{h("sections.findings_none")}</p>'
    else:
        parts = []
        for f in d_f + w_f:
            parts.append(f'<div class="finding {f.get("level")}">'
                         f'<div class="finding-title">{esc(f.get("title"))}</div>'
                         f'<div class="finding-detail">{esc(f.get("detail"))}</div></div>')
        findings_html = "".join(parts)

    actions_html = render_action_plan(i18n, overall, d_f + w_f)

    sections = scan.get("sections") or {}
    load = sections.get("systemLoad") or {}
    safe_count = len([f for f in findings if f.get("level") == "safe"])

    # 플랫폼 판별
    platform = (scan.get("platform") or "").lower()
    is_macos = platform == "macos" or "darwin" in (scan.get("osVersion") or "").lower()
    if is_macos:
        security_html = render_macos_security(i18n, sections.get("macosSecurity"))
        security_title = h("sections.defender_mac")
    else:
        security_html = render_defender(i18n, sections.get("defender"))
        security_title = h("sections.defender_win")

    cpu_html = render_cpu_table(i18n, (sections.get("cpu") or [])[:10])
    monitor_html = render_monitor(i18n, monitor)
    net_html = render_network_table(i18n, sections.get("network"))
    port_html = render_simple_table(i18n, sections.get("listeningPorts"), [
        {"field": "port", "header_key": "table_headers.port"},
        {"field": "process", "header_key": "table_headers.program"},
        {"field": "note", "header_key": "table_headers.description"},
        {"field": "path", "header_key": "table_headers.path"},
    ])
    startup_html = render_simple_table(i18n, sections.get("startup"), [
        {"field": "name", "header_key": "table_headers.name"},
        {"field": "command", "header_key": "table_headers.command"},
        {"field": "note", "header_key": "table_headers.description"},
    ])
    task_html = render_simple_table(i18n, sections.get("scheduledTasks"), [
        {"field": "name", "header_key": "table_headers.name"},
        {"field": "execute", "header_key": "table_headers.execute"},
        {"field": "state", "header_key": "table_headers.state"},
        {"field": "note", "header_key": "table_headers.description"},
    ])
    install_html = render_simple_table(i18n, sections.get("recentInstalls"), [
        {"field": "installDate", "header_key": "table_headers.install_date"},
        {"field": "name", "header_key": "table_headers.program_name"},
        {"field": "publisher", "header_key": "table_headers.publisher"},
    ])
    autoruns_html = render_autoruns_table(i18n, sections.get("autoruns"))
    storage_html = ""
    if sections.get("storage"):
        storage_html = (
            f'<h2>{esc(h("sections.storage"))}</h2>'
            f"{explain_box(i18n, 'check_storage')}"
            f"{render_storage(i18n, sections.get('storage'))}"
        )

    # 팁 (explain.json의 tips.* 에서)
    explain_tips = (i18n.explain or {}).get("tips", {})
    tips_parts = []
    for key in ("defender_update", "virustotal", "full_scan", "hardware_noise"):
        title = h(f"tips.{key}.title")
        desc = explain_tips.get(key, "")
        tips_parts.append(f'<div class="finding"><div class="finding-title">{esc(title)}</div>'
                          f'<div class="finding-detail">{esc(desc)}</div></div>')

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    meta_line = h("meta_line", computer=esc(scan.get("computerName")),
                  user=esc(scan.get("userName")), os=esc(scan.get("osVersion")),
                  scannedAt=esc(scan.get("scannedAt")))
    load_line = h("load_line", cpu=load.get("cpuPercent", 0),
                  mem=load.get("memoryPercent", 0),
                  totalGb=load.get("totalMemoryGB", 0))

    return f"""<!DOCTYPE html>
<html lang="{i18n.lang}">
<head>
<meta charset="UTF-8">
<title>{esc(h("title"))} - {esc(scan.get('computerName'))}</title>
<style>{CSS}</style>
</head>
<body>
<div class="container">

{language_switcher_html(i18n.lang)}
<h1>🩺 {esc(h("title"))}</h1>
<div class="meta">{meta_line}</div>

<div class="verdict verdict-{overall}">
  <div class="verdict-icon">{verdict_icon}</div>
  <div class="verdict-text">
    <div class="big">{esc(verdict_msg)}</div>
    <div>{load_line}</div>
  </div>
</div>

{vt_summary}

{actions_html}

<div class="cards">
  <div class="card danger"><div class="count">{summary.get('dangerCount', 0)}</div><div class="label">{esc(h("cards.danger"))}</div></div>
  <div class="card warning"><div class="count">{summary.get('warningCount', 0)}</div><div class="label">{esc(h("cards.warning"))}</div></div>
  <div class="card safe"><div class="count">{safe_count}</div><div class="label">{esc(h("cards.safe"))}</div></div>
</div>

<h2>{esc(h("sections.findings"))}</h2>
<div class="findings">{findings_html}</div>

{storage_html}

<h2>{esc(h("sections.monitor"))}</h2>
{explain_box(i18n, 'check_idle_monitor')}
{monitor_html}

<h2>{esc(h("sections.cpu"))}</h2>
{explain_box(i18n, 'check_cpu')}
{cpu_html}

<h2>{esc(security_title)}</h2>
{explain_box(i18n, 'check_defender')}
{security_html}

<h2>{esc(h("sections.network"))}</h2>
{explain_box(i18n, 'check_network')}
{net_html}

<h2>{esc(h("sections.listening"))}</h2>
{explain_box(i18n, 'check_listening')}
{port_html}

<h2>{esc(h("sections.startup"))}</h2>
{explain_box(i18n, 'check_startup')}
{startup_html}

<h2>{esc(h("sections.autoruns"))}</h2>
<p class="muted">{h("sections.autoruns_desc")}</p>
{autoruns_html}

<h2>{esc(h("sections.scheduled"))}</h2>
{explain_box(i18n, 'check_scheduled')}
{task_html}

<h2>{esc(h("sections.installs"))}</h2>
{explain_box(i18n, 'check_installed')}
{install_html}

<h2>{esc(h("sections.tips"))}</h2>
<div class="findings">{''.join(tips_parts)}</div>

<div class="footer">{h("footer", now=now)}</div>

</div>
</body>
</html>"""


# ============================================================
# CLI
# ============================================================
def main():
    script_dir = Path(__file__).resolve().parent
    project_dir = script_dir.parent

    parser = argparse.ArgumentParser(description="PC 건강검진 i18n HTML 리포트 생성기")
    parser.add_argument("--scan", default=str(project_dir / "scan_result.json"))
    parser.add_argument("--monitor", default=str(project_dir / "monitor_result.json"))
    parser.add_argument("--explain", default=str(project_dir / "data" / "explain.json"))
    parser.add_argument("--output", default=str(project_dir / "검사결과.html"))
    parser.add_argument("--lang", default=None,
                        help="리포트 언어 (ko/en/ja). 기본: $PCH_LANG → $LANG → ko")
    args = parser.parse_args()

    scan_path = Path(args.scan)
    if not scan_path.exists():
        print(f"ERROR: {scan_path} 이 없습니다. scanner를 먼저 실행하세요.", file=sys.stderr)
        sys.exit(1)

    scan = load_json(scan_path)

    schema = scan.get("schemaVersion", "unknown")
    if schema not in SUPPORTED_SCHEMA:
        print(f"경고: scan_result.json의 schemaVersion={schema} 은 호환되지 않을 수 있습니다. "
              f"지원: {sorted(SUPPORTED_SCHEMA)}", file=sys.stderr)

    if not isinstance(scan.get("summary"), dict):
        print(
            "ERROR: scan_result.json에 summary가 없습니다. raw_facts.json이 아니라 "
            "rule_engine을 통과한 최종 결과를 입력해야 합니다.",
            file=sys.stderr,
        )
        sys.exit(2)

    try:
        monitor = load_json(Path(args.monitor))
    except Exception as e:
        print(f"경고: monitor 로드 실패: {e}", file=sys.stderr)
        monitor = None

    lang = args.lang or detect_lang()
    i18n = load_i18n(lang, project_dir, Path(args.explain))

    html_out = build_report(i18n, scan, monitor)

    output_path = Path(args.output)
    output_path.write_text(html_out, encoding="utf-8")
    print(f"HTML 리포트 생성 ({lang}): {output_path}")


if __name__ == "__main__":
    main()
