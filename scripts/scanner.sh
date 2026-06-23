#!/bin/bash
# ============================================================
# PC 건강검진 - macOS 스캐너 오케스트레이터 (v0.3)
#
# 각 모듈(modules/macos/*.sh)을 순차 호출해 raw 데이터를 수집한 뒤,
# scanner_helper.jxa.js가 rule engine을 적용해 scan_result.json을 생성.
#
# 사용법:
#   bash scanner.sh [--output scan_result.json] [--no-vt]
# ============================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules/macos"

OUTPUT="${PROJECT_DIR}/scan_result.json"
RAW_PATH="${PROJECT_DIR}/raw_facts.json"
CONFIG_PATH="${PROJECT_DIR}/data/config.json"
WHITELIST_PATH="${PROJECT_DIR}/data/whitelist.json"
RULES_DIR="${PROJECT_DIR}/rules"
NO_VT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        --raw) RAW_PATH="$2"; shift 2 ;;
        --no-vt) NO_VT=true; shift ;;
        *) shift ;;
    esac
done

# macOS 확인
if [[ "$(uname)" != "Darwin" ]]; then
    echo "ERROR: 이 스크립트는 macOS 전용입니다. Windows는 scanner.ps1을 사용하세요." >&2
    exit 1
fi

echo "PC 건강검진 (macOS) 시작..."

COMPUTER_NAME="$(scutil --get ComputerName 2>/dev/null || hostname)"
USER_NAME="$(whoami)"
OS_VERSION="macOS $(sw_vers -productVersion) (Darwin $(uname -r))"
SCANNED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

TMP_DIR="$(mktemp -d -t pchealth)"
trap 'rm -rf "$TMP_DIR"' EXIT
export TMP_DIR

# ------------------------------------------------------------
# 모듈 로드 (source)
# ------------------------------------------------------------
# shellcheck source=modules/macos/cpu.sh
. "$MODULES_DIR/cpu.sh"
# shellcheck source=modules/macos/network.sh
. "$MODULES_DIR/network.sh"
# shellcheck source=modules/macos/autoruns.sh
. "$MODULES_DIR/autoruns.sh"
# shellcheck source=modules/macos/security.sh
. "$MODULES_DIR/security.sh"

# ------------------------------------------------------------
# 섹션별 수집
# ------------------------------------------------------------
echo "  [1/8] CPU 사용량..."
collect_cpu
echo "  [2/8] 네트워크 연결..."
collect_network
echo "  [3/8] 열린 포트..."
collect_listening_ports
echo "  [4/8] 자동 실행..."
collect_autoruns
echo "  [5/8] 보안 상태..."
collect_security
echo "  [6/8] 시스템 부하..."
collect_system_load
echo "  → 결과 집계 및 rule engine 실행..."

# ------------------------------------------------------------
# JXA 헬퍼에 위임 (raw_facts 생성 + rule_engine 적용)
# ------------------------------------------------------------
export PCH_SCANNED_AT="$SCANNED_AT"
export PCH_COMPUTER_NAME="$COMPUTER_NAME"
export PCH_USER_NAME="$USER_NAME"
export PCH_OS_VERSION="$OS_VERSION"
export PCH_OUTPUT="$OUTPUT"
export PCH_RAW_PATH="$RAW_PATH"
export PCH_CONFIG_PATH="$CONFIG_PATH"
export PCH_WHITELIST_PATH="$WHITELIST_PATH"
export PCH_RULES_DIR="$RULES_DIR"
export PCH_NO_VT="$NO_VT"

osascript -l JavaScript "$SCRIPT_DIR/scanner_helper.jxa.js"
status=$?
if [[ $status -ne 0 ]]; then
    echo ""
    echo "ERROR: 결과 집계 또는 rule engine 실행 실패 (status=$status)" >&2
    echo "raw facts 경로: $RAW_PATH" >&2
    exit $status
fi

echo ""
echo "검사 완료: $OUTPUT"
