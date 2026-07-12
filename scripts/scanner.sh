#!/bin/bash -p
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
set -o pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PCH_PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MODULES_DIR="$SCRIPT_DIR/modules/macos"

OUTPUT="${PROJECT_DIR}/scan_result.json"
RAW_PATH="${PROJECT_DIR}/raw_facts.json"
CONFIG_PATH="${PCH_CONFIG_PATH:-}"
WHITELIST_PATH="${PCH_PINNED_WHITELIST:-${PROJECT_DIR}/data/whitelist.json}"
RULES_DIR="${PROJECT_DIR}/rules"
CPU_MODULE="${PCH_PINNED_CPU_MODULE:-$MODULES_DIR/cpu.sh}"
NETWORK_MODULE="${PCH_PINNED_NETWORK_MODULE:-$MODULES_DIR/network.sh}"
AUTORUNS_MODULE="${PCH_PINNED_AUTORUNS_MODULE:-$MODULES_DIR/autoruns.sh}"
SECURITY_MODULE="${PCH_PINNED_SECURITY_MODULE:-$MODULES_DIR/security.sh}"
STORAGE_MODULE="${PCH_PINNED_STORAGE_MODULE:-$MODULES_DIR/storage.sh}"
SCANNER_HELPER="${PCH_PINNED_SCANNER_HELPER:-$SCRIPT_DIR/scanner_helper.jxa.js}"
NO_VT=false

if [[ -z "$CONFIG_PATH" ]]; then
    if [[ -f "${HOME}/Library/Application Support/PC Health Check/config.json" ]]; then
        # User-owned config is shared by standalone and source app builds.
        CONFIG_PATH="${HOME}/Library/Application Support/PC Health Check/config.json"
    elif [[ -f "${PROJECT_DIR}/data/config.json" ]]; then
        # Source/archive CLI fallback: an explicitly created, ignored config.
        CONFIG_PATH="${PROJECT_DIR}/data/config.json"
    else
        CONFIG_PATH="${PROJECT_DIR}/data/config.example.json"
    fi
fi

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
COLLECTION_STATUS_PATH="$TMP_DIR/collection_status.tsv"
: > "$COLLECTION_STATUS_PATH"
export COLLECTION_STATUS_PATH

record_collection_status() {
    local source_id="$1"
    local label="$2"
    local status="$3"
    local required="$4"
    local detail="${5:-}"

    case "$source_id" in
        ''|*[!a-z0-9_]*) return 1 ;;
    esac
    case "$status" in
        ok|permission_denied|unavailable|timed_out|failed) ;;
        *) status="failed" ;;
    esac
    case "$required" in
        true|false) ;;
        *) required="false" ;;
    esac
    label="${label//$'\t'/ }"
    label="${label//$'\n'/ }"
    detail="${detail//$'\t'/ }"
    detail="${detail//$'\n'/ }"
    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
        "$source_id" "$label" "$status" "$required" "$detail" \
        >> "$COLLECTION_STATUS_PATH"
}

collection_failure_status() {
    local exit_status="$1"
    local error_text="${2:-}"
    if [[ "$exit_status" -eq 124 ]]; then
        /usr/bin/printf 'timed_out'
    elif [[ "$exit_status" -eq 126 || "$exit_status" -eq 127 ]]; then
        /usr/bin/printf 'unavailable'
    elif /usr/bin/printf '%s' "$error_text" \
        | /usr/bin/grep -Eqi 'operation not permitted|permission denied|not authorized'; then
        /usr/bin/printf 'permission_denied'
    else
        /usr/bin/printf 'failed'
    fi
}

# ------------------------------------------------------------
# 모듈 로드 (source)
# ------------------------------------------------------------
# MODULES_DIR is validated relative to this script; ShellCheck cannot resolve
# the dynamic prefix without following external sources.
# shellcheck source=modules/macos/cpu.sh
# shellcheck disable=SC1091
. "$CPU_MODULE"
# shellcheck source=modules/macos/network.sh
# shellcheck disable=SC1091
. "$NETWORK_MODULE"
# shellcheck source=modules/macos/autoruns.sh
# shellcheck disable=SC1091
. "$AUTORUNS_MODULE"
# shellcheck source=modules/macos/security.sh
# shellcheck disable=SC1091
. "$SECURITY_MODULE"
# shellcheck source=modules/macos/storage.sh
# shellcheck disable=SC1091
. "$STORAGE_MODULE"

# ------------------------------------------------------------
# 섹션별 수집
# ------------------------------------------------------------
echo "  [1/7] CPU 사용량..."
collect_cpu
echo "  [2/7] 네트워크 연결..."
collect_network
echo "  [3/7] 열린 포트..."
collect_listening_ports
echo "  [4/7] 자동 실행..."
collect_autoruns
echo "  [5/7] 보안 상태..."
collect_security
echo "  [6/7] 저장공간 압박..."
collect_storage
echo "  [7/7] 시스템 부하..."
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
export PCH_WHITELIST_PATH="$WHITELIST_PATH"
export PCH_RULES_DIR="$RULES_DIR"
export PCH_NO_VT="$NO_VT"

PINNED_CONFIG_SOURCE="${PCH_PINNED_CONFIG:-}"
if [[ -n "$PINNED_CONFIG_SOURCE" ]]; then
    CONFIG_PATH=/dev/fd/9
fi
export PCH_CONFIG_PATH="$CONFIG_PATH"

if [[ -n "${PCH_PINNED_SCANNER_HELPER:-}" ]]; then
    PINNED_WHITELIST_SOURCE="$PCH_PINNED_WHITELIST"
    PINNED_RULE_AUTORUNS_SOURCE="$PCH_PINNED_RULE_AUTORUNS"
    PINNED_RULE_DEFENDER_SOURCE="$PCH_PINNED_RULE_DEFENDER"
    PINNED_RULE_INSTALLS_SOURCE="$PCH_PINNED_RULE_INSTALLS"
    PINNED_RULE_NETWORK_SOURCE="$PCH_PINNED_RULE_NETWORK"
    PINNED_RULE_PROCESS_SOURCE="$PCH_PINNED_RULE_PROCESS"
    export PCH_PINNED_WHITELIST=/dev/fd/3
    export PCH_PINNED_RULE_AUTORUNS=/dev/fd/4
    export PCH_PINNED_RULE_DEFENDER=/dev/fd/5
    export PCH_PINNED_RULE_INSTALLS=/dev/fd/6
    export PCH_PINNED_RULE_NETWORK=/dev/fd/7
    export PCH_PINNED_RULE_PROCESS=/dev/fd/8
    /usr/bin/osascript -l JavaScript - \
        < "$SCANNER_HELPER" \
        3< "$PINNED_WHITELIST_SOURCE" \
        4< "$PINNED_RULE_AUTORUNS_SOURCE" \
        5< "$PINNED_RULE_DEFENDER_SOURCE" \
        6< "$PINNED_RULE_INSTALLS_SOURCE" \
        7< "$PINNED_RULE_NETWORK_SOURCE" \
        8< "$PINNED_RULE_PROCESS_SOURCE" \
        9< "$PINNED_CONFIG_SOURCE"
elif [[ -n "$PINNED_CONFIG_SOURCE" ]]; then
    /usr/bin/osascript -l JavaScript "$SCANNER_HELPER" \
        9< "$PINNED_CONFIG_SOURCE"
else
    /usr/bin/osascript -l JavaScript "$SCANNER_HELPER"
fi
status=$?
if [[ $status -ne 0 ]]; then
    echo ""
    echo "ERROR: 결과 집계 또는 rule engine 실행 실패 (status=$status)" >&2
    echo "raw facts 경로: $RAW_PATH" >&2
    exit $status
fi

echo ""
echo "검사 완료: $OUTPUT"
