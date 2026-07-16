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
import sys
from pathlib import Path

from _jsonutil import load_json
from report_i18n import SUPPORTED_SCHEMA, detect_lang, load_i18n
from report_render import build_report


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
