#!/bin/bash
# Lightweight local disk-pressure watch. It records free space only and never deletes files.

set -u
set -o pipefail

STATE_DIR="${PCH_STATE_DIR:-${HOME:-}/Library/Application Support/PC Health Check}"
STATE_FILE="$STATE_DIR/storage-watch.tsv"
HISTORY_FILE="$STATE_DIR/storage-samples.tsv"
HISTORY_LIMIT="${PCH_WATCH_HISTORY_LIMIT:-336}"
FREE_THRESHOLD_GB="${PCH_WATCH_FREE_GB:-20}"
DROP_THRESHOLD_GB="${PCH_WATCH_DROP_GB:-8}"
NOTIFY="${PCH_WATCH_NOTIFY:-1}"

emit() {
    /usr/bin/printf '%s\t%s\n' "$1" "${2:-}"
}

case "$FREE_THRESHOLD_GB$DROP_THRESHOLD_GB" in
    *[!0-9]*) /usr/bin/printf 'ERROR: thresholds must be whole GB values.\n' >&2; exit 64 ;;
esac
case "$HISTORY_LIMIT" in
    ''|*[!0-9]*|0) /usr/bin/printf 'ERROR: history limit must be a positive whole number.\n' >&2; exit 64 ;;
esac
[[ -n "$STATE_DIR" && "$STATE_DIR" == /* ]] || exit 64

/bin/mkdir -p "$STATE_DIR" || exit 1
/bin/chmod 700 "$STATE_DIR" 2>/dev/null || true

if [[ -n "${PCH_TEST_FREE_KB:-}" ]]; then
    FREE_KB="$PCH_TEST_FREE_KB"
else
    DF_TARGET="/"
    [[ -d /System/Volumes/Data ]] && DF_TARGET="/System/Volumes/Data"
    FREE_KB="$(/bin/df -Pk "$DF_TARGET" 2>/dev/null | /usr/bin/awk 'NR == 2 {print $4; exit}')"
fi
case "$FREE_KB" in ''|*[!0-9]*) /usr/bin/printf 'ERROR: free space unavailable.\n' >&2; exit 1 ;; esac

PREVIOUS_KB=0
PREVIOUS_STATUS="normal"
LAST_NOTIFY=0
if [[ -f "$STATE_FILE" ]]; then
    PREVIOUS_KB="$(/usr/bin/awk -F '\t' '$1 == "freeKB" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    PREVIOUS_STATUS="$(/usr/bin/awk -F '\t' '$1 == "status" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    LAST_NOTIFY="$(/usr/bin/awk -F '\t' '$1 == "lastNotify" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
fi
case "$PREVIOUS_KB" in ''|*[!0-9]*) PREVIOUS_KB=0 ;; esac
case "$LAST_NOTIFY" in ''|*[!0-9]*) LAST_NOTIFY=0 ;; esac

DROP_KB=0
if [[ "$PREVIOUS_KB" -gt "$FREE_KB" ]]; then
    DROP_KB=$((PREVIOUS_KB - FREE_KB))
fi
FREE_THRESHOLD_KB=$((FREE_THRESHOLD_GB * 1024 * 1024))
DROP_THRESHOLD_KB=$((DROP_THRESHOLD_GB * 1024 * 1024))
STATUS="normal"
MESSAGE="저장공간 변화가 정상 범위입니다."
if [[ "$FREE_KB" -lt "$FREE_THRESHOLD_KB" ]]; then
    STATUS="warning"
    MESSAGE="남은 저장공간이 ${FREE_THRESHOLD_GB}GB 아래입니다. PC Health Check를 열어 원인을 확인하세요."
elif [[ "$DROP_KB" -ge "$DROP_THRESHOLD_KB" ]]; then
    STATUS="warning"
    MESSAGE="최근 점검 이후 저장공간이 ${DROP_THRESHOLD_GB}GB 이상 줄었습니다. PC Health Check를 열어 원인을 확인하세요."
fi

NOW_EPOCH="$(/bin/date '+%s')"
NOW_ISO="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [[ "$STATUS" == "warning" && "$NOTIFY" == "1" ]]; then
    if [[ "$PREVIOUS_STATUS" != "warning" || $((NOW_EPOCH - LAST_NOTIFY)) -ge 21600 ]]; then
        if [[ "$(/usr/bin/uname -s)" == "Darwin" && -x /usr/bin/osascript ]]; then
            /usr/bin/osascript \
                -e 'on run argv' \
                -e 'display notification (item 1 of argv) with title "PC Health Check"' \
                -e 'end run' \
                "$MESSAGE" >/dev/null 2>&1 || true
        fi
        LAST_NOTIFY="$NOW_EPOCH"
    fi
fi

TMP_FILE="$STATE_DIR/.storage-watch.$$"
{
    /usr/bin/printf 'version\t1\n'
    /usr/bin/printf 'checkedAt\t%s\n' "$NOW_ISO"
    /usr/bin/printf 'status\t%s\n' "$STATUS"
    /usr/bin/printf 'freeKB\t%s\n' "$FREE_KB"
    /usr/bin/printf 'dropKB\t%s\n' "$DROP_KB"
    /usr/bin/printf 'lastNotify\t%s\n' "$LAST_NOTIFY"
    /usr/bin/printf 'message\t%s\n' "$MESSAGE"
} > "$TMP_FILE" || exit 1
/bin/chmod 600 "$TMP_FILE" 2>/dev/null || true
/bin/mv "$TMP_FILE" "$STATE_FILE" || exit 1

HISTORY_TMP="$STATE_DIR/.storage-samples.$$"
{
    [[ -f "$HISTORY_FILE" ]] && /bin/cat "$HISTORY_FILE"
    /usr/bin/printf '%s\t%s\t%s\t%s\n' "$NOW_ISO" "$FREE_KB" "$DROP_KB" "$STATUS"
} | /usr/bin/tail -n "$HISTORY_LIMIT" > "$HISTORY_TMP" || exit 1
/bin/chmod 600 "$HISTORY_TMP" 2>/dev/null || true
/bin/mv "$HISTORY_TMP" "$HISTORY_FILE" || exit 1

emit "version" "1"
emit "status" "$STATUS"
emit "freeKB" "$FREE_KB"
emit "dropKB" "$DROP_KB"
emit "message" "$MESSAGE"
