#!/bin/bash -p
# Lightweight local disk-pressure watch. It records free space and, only after
# a large drop, a bounded size snapshot of known cache/runtime roots. It never
# reads file contents or deletes files.

set -u
set -o pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

# 이 스크립트는 LaunchAgent에서 파일이 아니라 stdin 파이프로 실행된다
# (scripts/schedule.sh의 WATCH_WRAPPER). 그 경로에서는 BASH_SOURCE가 비어 있어
# 형제 모듈을 source할 수 없고, set -u 아래에서는 참조 자체가 즉시 종료시킨다.
# 게다가 래퍼가 해시로 고정하는 대상은 이 파일 하나뿐이라, 검증되지 않은
# 모듈을 읽어 오는 것은 무결성 검사를 우회하는 통로가 된다. 그래서 이 값은
# 여기에 직접 둔다. modules/support_dir.sh와 어긋나지 않도록 테스트가 고정한다.
SUPPORT_DIR_NAME="Modore"
LEGACY_SUPPORT_DIR_NAME="PC Health Check"

# modules/support_dir.sh와 동작이 같아야 한다. 감시가 새 이름의 디렉터리를 먼저
# 만들어 버리면 마이그레이션 조건(새 이름이 아직 없을 것)이 깨져 옛 기록이
# 고아가 되므로, 상태 경로를 정하기 전에 여기서도 한 번 옮긴다.
migrate_support_directory_if_needed() {
    local support_root="$1"
    local legacy="$support_root/$LEGACY_SUPPORT_DIR_NAME"
    local current="$support_root/$SUPPORT_DIR_NAME"
    local owner

    [[ -n "$support_root" && "$support_root" == /* ]] || return 0
    [[ -d "$support_root" && ! -L "$support_root" ]] || return 0
    [[ -d "$legacy" && ! -L "$legacy" ]] || return 0
    [[ ! -e "$current" && ! -L "$current" ]] || return 0

    owner="$(/usr/bin/stat -f '%u' "$legacy" 2>/dev/null)" || return 0
    [[ "$owner" == "$(/usr/bin/id -u)" ]] || return 0

    /bin/mv "$legacy" "$current" 2>/dev/null || return 1
    return 0
}

path_owner_uid() {
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        /usr/bin/stat -f '%u' "$1" 2>/dev/null
    else
        /usr/bin/stat -c '%u' "$1" 2>/dev/null
    fi
}

path_permissions() {
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        /usr/bin/stat -f '%Lp' "$1" 2>/dev/null
    else
        /usr/bin/stat -c '%a' "$1" 2>/dev/null
    fi
}

path_modified_epoch() {
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        /usr/bin/stat -f '%m' "$1" 2>/dev/null
    else
        /usr/bin/stat -c '%Y' "$1" 2>/dev/null
    fi
}

path_has_unexpected_symlink() {
    local path="$1"
    local current=""
    local remainder component
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 0
    remainder="${path#/}"
    while [[ -n "$remainder" ]]; do
        component="${remainder%%/*}"
        if [[ "$remainder" == */* ]]; then
            remainder="${remainder#*/}"
        else
            remainder=""
        fi
        [[ -n "$component" ]] || continue
        current="$current/$component"
        # macOS exposes these stable system aliases as symlinks.
        if [[ "$current" != "/var" && "$current" != "/tmp" && -L "$current" ]]; then
            return 0
        fi
    done
    return 1
}

HOME_ROOT=""
if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
    STATE_DIR="${PCH_STATE_DIR:-}"
    HISTORY_LIMIT="${PCH_WATCH_HISTORY_LIMIT:-336}"
    FREE_THRESHOLD_GB="${PCH_WATCH_FREE_GB:-20}"
    DROP_THRESHOLD_GB="${PCH_WATCH_DROP_GB:-8}"
    NOTIFY="${PCH_WATCH_NOTIFY:-1}"
    APP_BUNDLE_PATH="${PCH_STORAGE_WATCH_APP_BUNDLE:-}"
    SNAPSHOT_TEST_ROOT="${PCH_WATCH_SNAPSHOT_ROOT:-}"
    SNAPSHOT_TOTAL_SECONDS="${PCH_WATCH_SNAPSHOT_TOTAL_SECONDS:-8}"
    SNAPSHOT_ITEM_SECONDS="${PCH_WATCH_SNAPSHOT_ITEM_SECONDS:-2}"
    SNAPSHOT_EVENT_LIMIT="${PCH_WATCH_SNAPSHOT_EVENT_LIMIT:-24}"
    PRIVATE_TMP_TEST_ROOT="${PCH_WATCH_PRIVATE_TMP_ROOT:-}"
    SWAP_TEST_FILE="${PCH_WATCH_SWAP_TEST_FILE:-}"
    RSS_TEST_FILE="${PCH_WATCH_RSS_TEST_FILE:-}"
    WATCH_LOCK_ATTEMPTS="${PCH_TEST_WATCH_LOCK_ATTEMPTS:-120}"
    WATCH_LOCK_SECONDS="${PCH_TEST_WATCH_LOCK_SECONDS:-12}"
    WATCH_LOCK_HOLDER_SECONDS="${PCH_TEST_WATCH_LOCK_HOLDER_SECONDS:-60}"
    NOTIFICATION_TICKS="${PCH_TEST_WATCH_NOTIFICATION_TICKS:-30}"
    if [[ -n "$SNAPSHOT_TEST_ROOT" ]]; then
        [[ "$SNAPSHOT_TEST_ROOT" == /tmp/?* || "$SNAPSHOT_TEST_ROOT" == /private/tmp/?* \
            || "$SNAPSHOT_TEST_ROOT" == /private/var/folders/?* \
            || "$SNAPSHOT_TEST_ROOT" == /var/folders/?* ]] || exit 64
    fi
    if [[ -n "$PRIVATE_TMP_TEST_ROOT" ]]; then
        [[ "$PRIVATE_TMP_TEST_ROOT" == /tmp/?* \
            || "$PRIVATE_TMP_TEST_ROOT" == /private/tmp/?* \
            || "$PRIVATE_TMP_TEST_ROOT" == /private/var/folders/?* \
            || "$PRIVATE_TMP_TEST_ROOT" == /var/folders/?* ]] || exit 64
    fi
    for test_input in "$SWAP_TEST_FILE" "$RSS_TEST_FILE"; do
        [[ -z "$test_input" || "$test_input" == /tmp/?* \
            || "$test_input" == /private/tmp/?* \
            || "$test_input" == /private/var/folders/?* \
            || "$test_input" == /var/folders/?* ]] || exit 64
    done
    [[ "$STATE_DIR" == /tmp/?* || "$STATE_DIR" == /private/tmp/?* \
        || "$STATE_DIR" == /private/var/folders/?* || "$STATE_DIR" == /var/folders/?* ]] || exit 64
else
    uid="$(/usr/bin/id -u)" || exit 64
    HOME_ROOT="$(/usr/bin/dscacheutil -q user -a uid "$uid" 2>/dev/null \
        | /usr/bin/awk '$1 == "dir:" {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}')"
    [[ -n "$HOME_ROOT" && "$HOME_ROOT" == /* && "$HOME_ROOT" != "/" \
        && -d "$HOME_ROOT" && ! -L "$HOME_ROOT" ]] || exit 64
    HOME_ROOT="$(cd -P "$HOME_ROOT" && /bin/pwd -P)" || exit 64
    [[ -d "$HOME_ROOT/Library" && ! -L "$HOME_ROOT/Library" ]] || exit 64
    [[ -d "$HOME_ROOT/Library/Application Support" \
        && ! -L "$HOME_ROOT/Library/Application Support" ]] || exit 64
    migrate_support_directory_if_needed "$HOME_ROOT/Library/Application Support" || true
    STATE_DIR="$HOME_ROOT/Library/Application Support/$SUPPORT_DIR_NAME"
    HISTORY_LIMIT=336
    FREE_THRESHOLD_GB=20
    DROP_THRESHOLD_GB=8
    NOTIFY=1
    APP_BUNDLE_PATH="${PCH_STORAGE_WATCH_APP_BUNDLE:-}"
    SNAPSHOT_TEST_ROOT=""
    SNAPSHOT_TOTAL_SECONDS=8
    SNAPSHOT_ITEM_SECONDS=2
    SNAPSHOT_EVENT_LIMIT=24
    PRIVATE_TMP_TEST_ROOT=""
    SWAP_TEST_FILE=""
    RSS_TEST_FILE=""
    WATCH_LOCK_ATTEMPTS=120
    WATCH_LOCK_SECONDS=12
    WATCH_LOCK_HOLDER_SECONDS=60
    NOTIFICATION_TICKS=30
fi
emit() {
    /usr/bin/printf '%s\t%s\n' "$1" "${2:-}"
}

case "$FREE_THRESHOLD_GB$DROP_THRESHOLD_GB" in
    *[!0-9]*) /usr/bin/printf 'ERROR: thresholds must be whole GB values.\n' >&2; exit 64 ;;
esac
case "$HISTORY_LIMIT" in
    ''|*[!0-9]*|0) /usr/bin/printf 'ERROR: history limit must be a positive whole number.\n' >&2; exit 64 ;;
esac
case "$SNAPSHOT_TOTAL_SECONDS$SNAPSHOT_ITEM_SECONDS$SNAPSHOT_EVENT_LIMIT" in
    *[!0-9]*) /usr/bin/printf 'ERROR: snapshot limits must be whole numbers.\n' >&2; exit 64 ;;
esac
[[ "$SNAPSHOT_TOTAL_SECONDS" -gt 0 && "$SNAPSHOT_ITEM_SECONDS" -gt 0 \
    && "$SNAPSHOT_EVENT_LIMIT" -gt 0 ]] || exit 64
case "$WATCH_LOCK_ATTEMPTS" in ''|*[!0-9]*|0) exit 64 ;; esac
[[ "$WATCH_LOCK_ATTEMPTS" -le 120 ]] || exit 64
case "$WATCH_LOCK_SECONDS" in ''|*[!0-9]*) exit 64 ;; esac
[[ "$WATCH_LOCK_SECONDS" -le 12 ]] || exit 64
case "$WATCH_LOCK_HOLDER_SECONDS" in ''|*[!0-9]*|0) exit 64 ;; esac
[[ "$WATCH_LOCK_HOLDER_SECONDS" -le 60 ]] || exit 64
case "$NOTIFICATION_TICKS" in ''|*[!0-9]*|0) exit 64 ;; esac
[[ "$NOTIFICATION_TICKS" -le 30 ]] || exit 64
[[ -n "$STATE_DIR" && "$STATE_DIR" == /* ]] || exit 64

STATE_PARENT="$(/usr/bin/dirname "$STATE_DIR")" || exit 1
STATE_NAME="$(/usr/bin/basename "$STATE_DIR")" || exit 1
[[ -n "$STATE_NAME" && "$STATE_NAME" != "." && "$STATE_NAME" != ".." \
    && ! "$STATE_NAME" =~ / ]] || exit 64
path_has_unexpected_symlink "$STATE_PARENT" && exit 1
[[ -d "$STATE_PARENT" && ! -L "$STATE_PARENT" \
    && "$(path_owner_uid "$STATE_PARENT")" == "$(/usr/bin/id -u)" ]] || exit 1
PARENT_PERMISSIONS="$(path_permissions "$STATE_PARENT")" || exit 1
[[ $((8#$PARENT_PERMISSIONS & 0022)) -eq 0 ]] || exit 1
STATE_PARENT="$(cd -P "$STATE_PARENT" && /bin/pwd -P)" || exit 1
STATE_DIR="$STATE_PARENT/$STATE_NAME"
if [[ ! -e "$STATE_DIR" && ! -L "$STATE_DIR" ]]; then
    /bin/mkdir "$STATE_DIR" || exit 1
fi
path_has_unexpected_symlink "$STATE_DIR" && exit 1
[[ -d "$STATE_DIR" && ! -L "$STATE_DIR" \
    && "$(path_owner_uid "$STATE_DIR")" == "$(/usr/bin/id -u)" ]] || exit 1
/bin/chmod 700 "$STATE_DIR" 2>/dev/null || exit 1
cd -P "$STATE_DIR" || exit 1
[[ "$(/bin/pwd -P)" == "$STATE_DIR" \
    && "$(path_owner_uid .)" == "$(/usr/bin/id -u)" ]] || exit 1
STATE_FILE="storage-watch.tsv"
HISTORY_FILE="storage-samples.tsv"
SNAPSHOT_FILE="storage-watch-paths.tsv"
# Runtime signals intentionally do not share SNAPSHOT_FILE: RSS is memory, not
# a disk path size. Rows are bounded TSV metadata with this stable shape:
# capturedAt, kind, valueKB, allocatedKB, pid, status, label, reference.
# `swap` uses valueKB=used and allocatedKB=total; `process_rss` uses valueKB=RSS.
SIGNALS_FILE="storage-watch-signals.tsv"
for state_path in "$STATE_FILE" "$HISTORY_FILE" "$SNAPSHOT_FILE" "$SIGNALS_FILE"; do
    if [[ -e "$state_path" || -L "$state_path" ]]; then
        [[ -f "$state_path" && ! -L "$state_path" ]] || exit 1
    fi
done

# LaunchAgent and `modore storage status` can start the same watcher. On macOS,
# a short-lived lockf holder owns the kernel lock and watches this shell's PID
# plus process start identity. Other commands never inherit the locked file
# descriptor. If this shell is killed, the holder notices and releases; a hard
# 60-second ceiling prevents a damaged watcher from keeping the lock forever.
# The persistent lock file is never unlinked, so contenders cannot lock
# different inodes. Linux reaches this file only in the portable test harness
# and uses the mkdir fallback below.
WATCH_LOCK_FILE=".storage-watch.lockfile"
WATCH_LOCK_DIR=".storage-watch.lock"
WATCH_LOCK_HELD=0
WATCH_LOCK_MODE=""
WATCH_LOCK_HOLDER_PID=""
WATCH_LOCK_READY_FILE=""
WATCH_LOCK_RELEASE_FILE=""
process_start_identity() {
    local process_pid="$1"
    case "$process_pid" in ''|*[!0-9]*|0) return 1 ;; esac
    /bin/ps -p "$process_pid" -o lstart= 2>/dev/null \
        | /usr/bin/head -n 1 \
        | /usr/bin/awk '{$1=$1; print}'
}
release_watch_lock() {
    local recorded_pid="" waited_ticks=0
    [[ "$WATCH_LOCK_HELD" == "1" ]] || return 0
    if [[ "$WATCH_LOCK_MODE" == "holder" ]]; then
        if [[ -n "$WATCH_LOCK_RELEASE_FILE" \
            && ! -e "$WATCH_LOCK_RELEASE_FILE" \
            && ! -L "$WATCH_LOCK_RELEASE_FILE" ]]; then
            : > "$WATCH_LOCK_RELEASE_FILE" 2>/dev/null || true
            /bin/chmod 600 "$WATCH_LOCK_RELEASE_FILE" 2>/dev/null || true
        fi
        while [[ -n "$WATCH_LOCK_HOLDER_PID" \
            && "$waited_ticks" -lt 20 ]] \
            && /bin/kill -0 "$WATCH_LOCK_HOLDER_PID" 2>/dev/null; do
            /bin/sleep 0.1
            waited_ticks=$((waited_ticks + 1))
        done
        if [[ -n "$WATCH_LOCK_HOLDER_PID" ]] \
            && /bin/kill -0 "$WATCH_LOCK_HOLDER_PID" 2>/dev/null; then
            /bin/kill "$WATCH_LOCK_HOLDER_PID" 2>/dev/null || true
        fi
        [[ -z "$WATCH_LOCK_HOLDER_PID" ]] \
            || wait "$WATCH_LOCK_HOLDER_PID" 2>/dev/null || true
        for control_file in "$WATCH_LOCK_READY_FILE" "$WATCH_LOCK_RELEASE_FILE"; do
            [[ -n "$control_file" && -f "$control_file" \
                && ! -L "$control_file" ]] || continue
            /bin/rm -f "$control_file" 2>/dev/null || true
        done
    elif [[ -d "$WATCH_LOCK_DIR" && ! -L "$WATCH_LOCK_DIR" ]]; then
        recorded_pid="$(/bin/cat "$WATCH_LOCK_DIR/pid" 2>/dev/null || true)"
        if [[ "$recorded_pid" == "$$" ]]; then
            /bin/rm -f "$WATCH_LOCK_DIR/pid" 2>/dev/null || true
            /bin/rmdir "$WATCH_LOCK_DIR" 2>/dev/null || true
        fi
    fi
    WATCH_LOCK_HELD=0
}
acquire_watch_lock() {
    local attempt=0 lock_owner="" lock_result=0 parent_start="" maximum_wait_ticks=0
    local control_file=""
    if [[ "$(/usr/bin/uname -s)" == "Darwin" && -x /usr/bin/lockf ]]; then
        if [[ ! -e "$WATCH_LOCK_FILE" && ! -L "$WATCH_LOCK_FILE" ]]; then
            ( set -o noclobber; : > "$WATCH_LOCK_FILE" ) 2>/dev/null || true
        fi
        [[ -f "$WATCH_LOCK_FILE" && ! -L "$WATCH_LOCK_FILE" \
            && "$(path_owner_uid "$WATCH_LOCK_FILE")" == "$(/usr/bin/id -u)" ]] \
            || return 1
        /bin/chmod 600 "$WATCH_LOCK_FILE" 2>/dev/null || return 1
        parent_start="$(process_start_identity "$$")" || return 1
        [[ -n "$parent_start" && "$parent_start" != *$'\t'* \
            && "$parent_start" != *$'\n'* && "$parent_start" != *$'\r'* \
            && "${#parent_start}" -le 128 ]] || return 1
        WATCH_LOCK_READY_FILE=".storage-watch-lock-ready.$$"
        WATCH_LOCK_RELEASE_FILE=".storage-watch-lock-release.$$"
        for control_file in "$WATCH_LOCK_READY_FILE" "$WATCH_LOCK_RELEASE_FILE"; do
            if [[ -e "$control_file" || -L "$control_file" ]]; then
                [[ -f "$control_file" && ! -L "$control_file" \
                    && "$(path_owner_uid "$control_file")" == "$(/usr/bin/id -u)" ]] \
                    || return 1
                /bin/rm -f "$control_file" 2>/dev/null || return 1
            fi
        done
        # shellcheck disable=SC2016 # The holder shell expands its own arguments.
        /usr/bin/lockf -s -t "$WATCH_LOCK_SECONDS" -k "$WATCH_LOCK_FILE" \
            /bin/bash -p -c '
                set -u
                ready="$1"; release="$2"; parent="$3"; expected_start="$4"; maximum_seconds="$5"
                parent_matches() {
                    current_start="$(/bin/ps -p "$parent" -o lstart= 2>/dev/null \
                        | /usr/bin/head -n 1 | /usr/bin/awk '\''{$1=$1; print}'\'')"
                    [[ -n "$current_start" && "$current_start" == "$expected_start" ]]
                }
                cleanup_holder() {
                    /bin/rm -f "$ready" "$release" 2>/dev/null || true
                }
                trap cleanup_holder EXIT
                trap "exit 0" HUP INT TERM
                /usr/bin/printf "%s\n" "$$" > "$ready" || exit 1
                /bin/chmod 600 "$ready" 2>/dev/null || exit 1
                seconds=0
                while [[ "$seconds" -lt "$maximum_seconds" ]]; do
                    [[ ! -L "$release" ]] || exit 1
                    [[ ! -f "$release" ]] || exit 0
                    kill -0 "$parent" 2>/dev/null || exit 0
                    /bin/sleep 1
                    seconds=$((seconds + 1))
                done
                if parent_matches; then
                    kill "$parent" 2>/dev/null || true
                    /bin/sleep 1
                    parent_matches || exit 0
                    kill -9 "$parent" 2>/dev/null || true
                    while parent_matches; do
                        /bin/sleep 0.1
                    done
                fi
                exit 0
            ' -- "$WATCH_LOCK_READY_FILE" "$WATCH_LOCK_RELEASE_FILE" \
                "$$" "$parent_start" "$WATCH_LOCK_HOLDER_SECONDS" >/dev/null 2>&1 &
        WATCH_LOCK_HOLDER_PID=$!
        maximum_wait_ticks=$((WATCH_LOCK_SECONDS * 10 + 20))
        while [[ "$attempt" -lt "$maximum_wait_ticks" ]]; do
            if [[ -f "$WATCH_LOCK_READY_FILE" && ! -L "$WATCH_LOCK_READY_FILE" \
                && "$(path_owner_uid "$WATCH_LOCK_READY_FILE")" == "$(/usr/bin/id -u)" ]]; then
                WATCH_LOCK_MODE="holder"
                WATCH_LOCK_HELD=1
                return 0
            fi
            if ! /bin/kill -0 "$WATCH_LOCK_HOLDER_PID" 2>/dev/null; then
                if wait "$WATCH_LOCK_HOLDER_PID"; then
                    lock_result=1
                else
                    lock_result=$?
                fi
                return "$lock_result"
            fi
            /bin/sleep 0.1
            attempt=$((attempt + 1))
        done
        /bin/kill "$WATCH_LOCK_HOLDER_PID" 2>/dev/null || true
        wait "$WATCH_LOCK_HOLDER_PID" 2>/dev/null || true
        return 75
    fi

    while [[ "$attempt" -lt "$WATCH_LOCK_ATTEMPTS" ]]; do
        if /bin/mkdir "$WATCH_LOCK_DIR" 2>/dev/null; then
            /bin/chmod 700 "$WATCH_LOCK_DIR" 2>/dev/null || {
                /bin/rmdir "$WATCH_LOCK_DIR" 2>/dev/null || true
                return 1
            }
            /usr/bin/printf '%s\n' "$$" > "$WATCH_LOCK_DIR/pid" || {
                /bin/rmdir "$WATCH_LOCK_DIR" 2>/dev/null || true
                return 1
            }
            /bin/chmod 600 "$WATCH_LOCK_DIR/pid" 2>/dev/null || true
            WATCH_LOCK_MODE="directory"
            WATCH_LOCK_HELD=1
            return 0
        fi
        [[ -d "$WATCH_LOCK_DIR" && ! -L "$WATCH_LOCK_DIR" ]] || return 1
        lock_owner="$(path_owner_uid "$WATCH_LOCK_DIR")"
        [[ "$lock_owner" == "$(/usr/bin/id -u)" ]] || return 1
        /bin/sleep 0.1
        attempt=$((attempt + 1))
    done
    return 75
}
if acquire_watch_lock; then
    trap release_watch_lock EXIT
else
    LOCK_STATUS=$?
    if [[ "$LOCK_STATUS" == "75" ]]; then
        emit "watchStatus" "busy"
        emit "message" "다른 Modore 저장공간 점검이 실행 중입니다. 마지막 완료 기록을 표시합니다."
    fi
    exit "$LOCK_STATUS"
fi
if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
    TEST_HOLD_LOCK_SECONDS="${PCH_TEST_HOLD_LOCK_SECONDS:-0}"
    case "$TEST_HOLD_LOCK_SECONDS" in ''|*[!0-9]*) exit 64 ;; esac
    [[ "$TEST_HOLD_LOCK_SECONDS" -le 5 ]] || exit 64
    [[ "$TEST_HOLD_LOCK_SECONDS" == "0" ]] \
        || /bin/sleep "$TEST_HOLD_LOCK_SECONDS"
fi

if [[ "${PCH_TEST_MODE:-0}" == "1" && -n "${PCH_TEST_FREE_KB:-}" ]]; then
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
LAST_SNAPSHOT=0
LAST_EVIDENCE_AT=""
if [[ -f "$STATE_FILE" ]]; then
    PREVIOUS_KB="$(/usr/bin/awk -F '\t' '$1 == "freeKB" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    PREVIOUS_STATUS="$(/usr/bin/awk -F '\t' '$1 == "status" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    LAST_NOTIFY="$(/usr/bin/awk -F '\t' '$1 == "lastNotify" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    LAST_SNAPSHOT="$(/usr/bin/awk -F '\t' '$1 == "lastSnapshot" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    LAST_EVIDENCE_AT="$(/usr/bin/awk -F '\t' '$1 == "lastEvidenceAt" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
fi
case "$PREVIOUS_KB" in ''|*[!0-9]*) PREVIOUS_KB=0 ;; esac
case "$LAST_NOTIFY" in ''|*[!0-9]*) LAST_NOTIFY=0 ;; esac
case "$LAST_SNAPSHOT" in ''|*[!0-9]*) LAST_SNAPSHOT=0 ;; esac
case "$LAST_EVIDENCE_AT" in
    *$'\t'*|*$'\n'*|*$'\r'*) LAST_EVIDENCE_AT="" ;;
esac
[[ "${#LAST_EVIDENCE_AT}" -le 64 ]] || LAST_EVIDENCE_AT=""

# Older watcher versions had no committed evidence pointer. While holding the
# exclusive lock, migrate only an event present in both bounded histories (or
# the sole legacy history when only one exists). A partial event left by a
# killed writer is never promoted merely because its timestamp is newest.
if [[ -z "$LAST_EVIDENCE_AT" ]]; then
    if [[ -s "$SIGNALS_FILE" && -s "$SNAPSHOT_FILE" ]]; then
        LAST_EVIDENCE_AT="$({
            /usr/bin/awk -F '\t' 'NR == FNR { seen[$1] = 1; next } seen[$1] { print $1 }' \
                "$SIGNALS_FILE" "$SNAPSHOT_FILE"
        } | /usr/bin/sort | /usr/bin/tail -n 1)"
    elif [[ -s "$SIGNALS_FILE" ]]; then
        LAST_EVIDENCE_AT="$(/usr/bin/awk -F '\t' 'NF {value=$1} END {print value}' "$SIGNALS_FILE")"
    elif [[ -s "$SNAPSHOT_FILE" ]]; then
        LAST_EVIDENCE_AT="$(/usr/bin/awk -F '\t' 'NF {value=$1} END {print value}' "$SNAPSHOT_FILE")"
    fi
fi

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
    MESSAGE="남은 저장공간이 ${FREE_THRESHOLD_GB}GB 아래입니다. Modore를 열어 원인을 확인하세요."
elif [[ "$DROP_KB" -ge "$DROP_THRESHOLD_KB" ]]; then
    STATUS="warning"
    MESSAGE="최근 점검 이후 저장공간이 ${DROP_THRESHOLD_GB}GB 이상 줄었습니다. Modore를 열어 원인을 확인하세요."
fi

NOW_EPOCH="$(/bin/date '+%s')"
NOW_ISO="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
# A manual kickstart can produce two samples inside one wall-clock second.
# Keep the state timestamp human-sized, but give each evidence event a stable
# fractional component derived from this short-lived watcher process so the
# native app never merges two separate captures into one event.
EVENT_ISO="${NOW_ISO%Z}.$(/usr/bin/printf '%06d' "$(( $$ % 1000000 ))")Z"
SNAPSHOT_CAPTURED=0
SIGNALS_CAPTURED=0

# macOS metadata commands are normally instant, but a pressure watcher must not
# become another long-running pressure source if ps or sysctl stalls. One call
# gets at most ten 100ms ticks. The caller controls the private output file and
# retains only a much smaller parsed subset.
bounded_metadata_capture() {
    local output_file="$1"
    shift
    local capture_pid ticks=0
    : > "$output_file" || return 1
    "$@" > "$output_file" 2>/dev/null &
    capture_pid=$!
    while /bin/kill -0 "$capture_pid" 2>/dev/null; do
        if [[ "$ticks" -ge 10 ]]; then
            /bin/kill -9 "$capture_pid" 2>/dev/null || true
            wait "$capture_pid" 2>/dev/null || true
            : > "$output_file" || true
            return 124
        fi
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$capture_pid" 2>/dev/null
}

bounded_notification_command() (
    local maximum_ticks="$1"
    shift
    local command_pid ticks=0 command_status=0
    # A notification helper may itself fork (AppleScript and shell wrappers do).
    # Job control gives the helper a private process group, so the deadline can
    # stop the whole tree instead of leaving a pressure-amplifying orphan.
    set -m
    "$@" >/dev/null 2>&1 &
    command_pid=$!
    while /bin/kill -0 -- "-$command_pid" 2>/dev/null; do
        if [[ "$ticks" -ge "$maximum_ticks" ]]; then
            /bin/kill -TERM -- "-$command_pid" 2>/dev/null || true
            /bin/sleep 0.2
            /bin/kill -KILL -- "-$command_pid" 2>/dev/null || true
            wait "$command_pid" 2>/dev/null || true
            ticks=0
            while [[ "$ticks" -lt 10 ]] \
                && /bin/kill -0 -- "-$command_pid" 2>/dev/null; do
                /bin/sleep 0.1
                ticks=$((ticks + 1))
            done
            return 124
        fi
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    if wait "$command_pid"; then
        return 0
    else
        command_status=$?
    fi
    return "$command_status"
)

capture_drop_snapshot() {
    local event_tmp sorted_tmp history_tmp candidate label path
    local signal_tmp signal_history_tmp metadata_tmp swap_input rss_input
    local swap_used_kb swap_allocated_kb rss_kb rss_pid rss_reference rss_label
    local result_file pid waited_ticks size_kb status modified_epoch
    local priority_rows remaining_rows
    local elapsed_ticks=0
    local total_ticks=$((SNAPSHOT_TOTAL_SECONDS * 10))
    local item_ticks=$((SNAPSHOT_ITEM_SECONDS * 10))
    local maximum_rows=8
    local maximum_history_rows=$((SNAPSHOT_EVENT_LIMIT * maximum_rows))
    local maximum_rss_rows=3
    local maximum_signal_rows=$((maximum_rss_rows + 1))
    local maximum_signal_history_rows=$((SNAPSHOT_EVENT_LIMIT * maximum_signal_rows))
    local -a candidates=()

    # These are common short-lived AI/tooling workspaces that can grow between
    # hourly samples. Measure them before broad cache roots so the shared
    # snapshot deadline cannot consistently starve the most transient evidence.
    # Keep the namespace and ownership checks narrow: /private/tmp is shared by
    # every local account, so another user's similarly named entry must never
    # become this user's evidence.
    local private_tmp_root="/private/tmp"
    [[ "${PCH_TEST_MODE:-0}" != "1" ]] || private_tmp_root="$PRIVATE_TMP_TEST_ROOT"
    if [[ -n "$private_tmp_root" && -d "$private_tmp_root" \
        && ! -L "$private_tmp_root" ]] \
        && ! path_has_unexpected_symlink "$private_tmp_root"; then
        path="$private_tmp_root/claude-$(/usr/bin/id -u)"
        if [[ -e "$path" && ! -L "$path" \
            && "$(path_owner_uid "$path")" == "$(/usr/bin/id -u)" ]]; then
            candidates+=("Claude 임시 작업"$'\t'"$path")
        fi
        # Random suffixes make lexical "first three" unrelated to the active
        # incident. Admit a bounded recent set and let the measured-size sort
        # below decide which rows survive the eight-row event cap.
        while IFS=$'\t' read -r _ path; do
            [[ -n "$path" ]] || continue
            candidates+=("Modore 임시 작업"$'\t'"$path")
        done < <(
            for path in "$private_tmp_root"/modore-*; do
                if [[ -e "$path" && ! -L "$path" \
                    && "$(path_owner_uid "$path")" == "$(/usr/bin/id -u)" \
                    && "$path" != *$'\t'* && "$path" != *$'\n'* \
                    && "$path" != *$'\r'* ]]; then
                    modified_epoch="$(path_modified_epoch "$path")"
                    if [[ "$modified_epoch" =~ ^[0-9]+$ ]]; then
                        /usr/bin/printf '%s\t%s\n' "$modified_epoch" "$path"
                    fi
                fi
            done | /usr/bin/sort -s -t $'\t' -k1,1nr | /usr/bin/head -n 12
        )
    fi

    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        if [[ -n "$SNAPSHOT_TEST_ROOT" && -d "$SNAPSHOT_TEST_ROOT" \
            && ! -L "$SNAPSHOT_TEST_ROOT" ]] \
            && ! path_has_unexpected_symlink "$SNAPSHOT_TEST_ROOT"; then
            for path in "$SNAPSHOT_TEST_ROOT"/*; do
                [[ -e "$path" && ! -L "$path" ]] || continue
                candidates+=("$(/usr/bin/basename "$path")"$'\t'"$path")
            done
        fi
    else
        for path in \
            /private/var/folders/*/*/X/com.google.Chrome.code_sign_clone \
            /private/var/folders/*/*/T/com.google.Chrome.code_sign_clone; do
            [[ -d "$path" && ! -L "$path" \
                && "$(path_owner_uid "$path")" == "$(/usr/bin/id -u)" ]] || continue
            candidates+=("Chrome code-sign clone"$'\t'"$path")
        done
        candidates+=("Codex 로컬 데이터"$'\t'"$HOME_ROOT/.codex")
        candidates+=("Claude 로컬 에이전트"$'\t'"$HOME_ROOT/Library/Application Support/Claude")
        candidates+=("Playwright 브라우저"$'\t'"$HOME_ROOT/Library/Caches/ms-playwright")
        candidates+=("npm 캐시"$'\t'"$HOME_ROOT/.npm")
        candidates+=("pnpm 저장소"$'\t'"$HOME_ROOT/Library/pnpm")
        candidates+=("CoreSimulator 기기"$'\t'"$HOME_ROOT/Library/Developer/CoreSimulator")
        candidates+=("Xcode 개발 데이터"$'\t'"$HOME_ROOT/Library/Developer/Xcode")
        candidates+=("사용자 캐시"$'\t'"$HOME_ROOT/Library/Caches")
    fi

    event_tmp="$(/usr/bin/mktemp ./.storage-watch-event.XXXXXX)" || return 1
    sorted_tmp="$(/usr/bin/mktemp ./.storage-watch-sorted.XXXXXX)" || {
        /bin/rm -f "$event_tmp"
        return 1
    }
    signal_tmp="$(/usr/bin/mktemp ./.storage-watch-signal.XXXXXX)" || {
        /bin/rm -f "$event_tmp" "$sorted_tmp"
        return 1
    }
    metadata_tmp="$(/usr/bin/mktemp ./.storage-watch-metadata.XXXXXX)" || {
        /bin/rm -f "$event_tmp" "$sorted_tmp" "$signal_tmp"
        return 1
    }
    # Bash 3.2 treats an explicitly empty array as unset under `set -u`.
    for candidate in "${candidates[@]+"${candidates[@]}"}"; do
        result_file=""
        label="${candidate%%$'\t'*}"
        path="${candidate#*$'\t'}"
        [[ "$path" == /* && -e "$path" && ! -L "$path" ]] || continue
        case "$label$path" in *$'\t'*|*$'\n'*|*$'\r'*) continue ;; esac
        path_has_unexpected_symlink "$path" && continue
        status="ok"
        size_kb=0
        if [[ "$elapsed_ticks" -ge "$total_ticks" ]]; then
            status="timed_out"
        else
            local allowed_ticks="$item_ticks"
            if [[ $((total_ticks - elapsed_ticks)) -lt "$allowed_ticks" ]]; then
                allowed_ticks=$((total_ticks - elapsed_ticks))
            fi
            result_file="$(/usr/bin/mktemp ./.storage-watch-du.XXXXXX)" || {
                status="timed_out"
                allowed_ticks=0
            }
            if [[ "$allowed_ticks" -gt 0 ]]; then
                /usr/bin/du -sk "$path" > "$result_file" 2>/dev/null &
                pid=$!
                waited_ticks=0
                while /bin/kill -0 "$pid" 2>/dev/null; do
                    if [[ "$waited_ticks" -ge "$allowed_ticks" ]]; then
                        /bin/kill -9 "$pid" 2>/dev/null || true
                        wait "$pid" 2>/dev/null || true
                        status="timed_out"
                        break
                    fi
                    /bin/sleep 0.1
                    waited_ticks=$((waited_ticks + 1))
                done
                if [[ "$status" == "ok" ]]; then
                    # du that exited on its own is NOT a timeout. It returns
                    # nonzero when a subdirectory is unreadable (routine without
                    # Full Disk Access) while still printing a valid total, so
                    # keep the measured size; a genuinely empty result is caught
                    # as "unavailable" when the total is parsed below.
                    wait "$pid" 2>/dev/null || true
                fi
                elapsed_ticks=$((elapsed_ticks + waited_ticks))
                if [[ "$status" == "ok" ]]; then
                    size_kb="$(/usr/bin/awk '{print $1; exit}' "$result_file" 2>/dev/null)"
                    case "$size_kb" in ''|*[!0-9]*) size_kb=0; status="unavailable" ;; esac
                fi
            fi
            [[ -z "${result_file:-}" ]] || /bin/rm -f "$result_file"
            result_file=""
        fi
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
            "$EVENT_ISO" "$size_kb" "$status" "$label" "$path" >> "$event_tmp" || {
            /bin/rm -f "$event_tmp" "$sorted_tmp" "$signal_tmp" "$metadata_tmp"
            return 1
        }
    done

    # Swap is disk-backed pressure that df alone cannot explain. Capture only
    # the two numeric counters from sysctl; never persist its original output.
    # Test mode accepts a private fixture file so Linux tests do not depend on
    # macOS sysctl.
    swap_input=""
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        if [[ -n "$SWAP_TEST_FILE" && -f "$SWAP_TEST_FILE" \
            && ! -L "$SWAP_TEST_FILE" ]] \
            && ! path_has_unexpected_symlink "$SWAP_TEST_FILE"; then
            swap_input="$(/usr/bin/head -c 4096 "$SWAP_TEST_FILE" 2>/dev/null)"
        fi
    elif [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        if bounded_metadata_capture "$metadata_tmp" /usr/sbin/sysctl vm.swapusage; then
            swap_input="$(/usr/bin/head -c 4096 "$metadata_tmp" 2>/dev/null)"
        fi
    fi
    if [[ -n "$swap_input" ]]; then
        read -r swap_allocated_kb swap_used_kb < <(
            /usr/bin/printf '%s\n' "$swap_input" | /usr/bin/awk '
                function as_kb(raw, unit, number) {
                    unit = substr(raw, length(raw), 1)
                    number = substr(raw, 1, length(raw) - 1) + 0
                    if (unit == "G") return number * 1024 * 1024
                    if (unit == "M") return number * 1024
                    if (unit == "K") return number
                    return -1
                }
                {
                    total = used = -1
                    for (i = 1; i <= NF; i++) {
                        if ($i == "total" && $(i + 1) == "=") total = as_kb($(i + 2))
                        if ($i == "used" && $(i + 1) == "=") used = as_kb($(i + 2))
                    }
                    if (total >= 0 && used >= 0) {
                        printf "%.0f %.0f\n", total, used
                        exit
                    }
                }
            '
        )
        case "${swap_allocated_kb:-}${swap_used_kb:-}" in
            ''|*[!0-9]*) ;;
            *)
                /usr/bin/printf '%s\tswap\t%s\t%s\t0\tok\tmacOS 스왑\t/private/var/vm\n' \
                    "$EVENT_ISO" "$swap_used_kb" "$swap_allocated_kb" >> "$signal_tmp"
                ;;
        esac
    fi

    # macOS `comm` can contain argv despite its name. `ucomm` is the short
    # accounting executable name and excludes argv. This is deliberate:
    # arguments routinely contain prompts, repository names, tokens, and
    # document titles. Keep the three largest individual
    # processes, including siblings that share one executable: collapsing them
    # would hide the multi-process memory pressure common to browser and agent
    # apps. Record only PID/RSS/executable metadata.
    rss_input=""
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        if [[ -n "$RSS_TEST_FILE" && -f "$RSS_TEST_FILE" \
            && ! -L "$RSS_TEST_FILE" ]] \
            && ! path_has_unexpected_symlink "$RSS_TEST_FILE"; then
            rss_input="$(/usr/bin/head -n 512 "$RSS_TEST_FILE" 2>/dev/null)"
        fi
    elif [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        # -m sorts by memory. The 512-line cap and the later three-row cap keep
        # both processing and retained evidence independent of process count.
        if bounded_metadata_capture "$metadata_tmp" \
            /bin/ps -U "$(/usr/bin/id -u)" -m -x -o pid=,rss=,ucomm=; then
            rss_input="$(/usr/bin/head -n 512 "$metadata_tmp" 2>/dev/null)"
        fi
    fi
    if [[ -n "$rss_input" ]]; then
        while IFS=$'\t' read -r rss_kb rss_pid rss_reference; do
            case "$rss_kb$rss_pid" in ''|*[!0-9]*) continue ;; esac
            [[ -n "$rss_reference" && ${#rss_reference} -le 256 ]] || continue
            case "$rss_reference" in *$'\t'*|*$'\n'*|*$'\r'*) continue ;; esac
            rss_label="$rss_reference"
            /usr/bin/printf '%s\tprocess_rss\t%s\t0\t%s\tok\t%s\t%s\n' \
                "$EVENT_ISO" "$rss_kb" "$rss_pid" "$rss_label" "$rss_reference" \
                >> "$signal_tmp"
        done < <(
            /usr/bin/printf '%s\n' "$rss_input" | /usr/bin/awk '
                $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
                    pid = $1
                    rss = $2
                    $1 = ""
                    $2 = ""
                    sub(/^[[:space:]]+/, "")
                    executable = $0
                    if (executable == "" || length(executable) > 256) next
                    printf "%d\t%d\t%s\n", rss, pid, executable
                }
            ' | /usr/bin/sort -t $'\t' -k1,1nr | /usr/bin/head -n "$maximum_rss_rows"
        )
    fi

    SIGNALS_CAPTURED="$(/usr/bin/wc -l < "$signal_tmp" | /usr/bin/tr -d ' ')"
    case "$SIGNALS_CAPTURED" in ''|*[!0-9]*) SIGNALS_CAPTURED=0 ;; esac
    if [[ "$SIGNALS_CAPTURED" -gt 0 ]]; then
        # Bound complete events rather than raw rows. Row-based tailing can
        # retain one row from an older event when the new event has fewer than
        # four signals, making the UI show an invented mixed incident.
        signal_history_tmp="$(/usr/bin/mktemp ./.storage-watch-signals.XXXXXX)" || {
            /bin/rm -f "$event_tmp" "$sorted_tmp" "$signal_tmp" "$metadata_tmp"
            return 1
        }
        {
            [[ -f "$SIGNALS_FILE" ]] && /bin/cat "$SIGNALS_FILE"
            /bin/cat "$signal_tmp"
        } | /usr/bin/awk -F '\t' -v limit="$SNAPSHOT_EVENT_LIMIT" '
            {
                lines[NR] = $0
                timestamps[NR] = $1
                if (!($1 in event_numbers)) {
                    event_count += 1
                    event_numbers[$1] = event_count
                }
            }
            END {
                first_event = event_count - limit + 1
                if (first_event < 1) first_event = 1
                for (row = 1; row <= NR; row++) {
                    if (event_numbers[timestamps[row]] >= first_event) print lines[row]
                }
            }
        ' | /usr/bin/tail -n "$maximum_signal_history_rows" > "$signal_history_tmp" || {
            /bin/rm -f "$event_tmp" "$sorted_tmp" "$signal_tmp" "$metadata_tmp" "$signal_history_tmp"
            return 1
        }
        /bin/chmod 600 "$signal_history_tmp" 2>/dev/null || true
        /bin/mv "$signal_history_tmp" "$SIGNALS_FILE" || {
            /bin/rm -f "$event_tmp" "$sorted_tmp" "$signal_tmp" "$metadata_tmp" "$signal_history_tmp"
            return 1
        }
    fi

    # Reserve four of the eight event rows for transient workspaces. Without
    # this split, persistent roots such as CoreSimulator, .codex, and the whole
    # cache tree can crowd out the short-lived directory that caused the drop.
    : > "$metadata_tmp" || return 1
    {
        /usr/bin/awk -F '\t' '$4 == "Claude 임시 작업"' "$event_tmp" \
            | /usr/bin/sort -t $'\t' -k2,2nr | /usr/bin/head -n 1
        /usr/bin/awk -F '\t' '$4 == "Modore 임시 작업"' "$event_tmp" \
            | /usr/bin/sort -t $'\t' -k2,2nr | /usr/bin/head -n 3
    } > "$metadata_tmp" || {
        /bin/rm -f "$event_tmp" "$sorted_tmp" "$signal_tmp" "$metadata_tmp"
        return 1
    }
    priority_rows="$(/usr/bin/wc -l < "$metadata_tmp" | /usr/bin/tr -d ' ')"
    case "$priority_rows" in ''|*[!0-9]*) priority_rows=0 ;; esac
    remaining_rows=$((maximum_rows - priority_rows))
    {
        /bin/cat "$metadata_tmp"
        if [[ "$remaining_rows" -gt 0 ]]; then
            /usr/bin/awk '
                FILENAME == ARGV[1] { selected[$0] = 1; next }
                !($0 in selected) { print }
            ' "$metadata_tmp" "$event_tmp" \
                | /usr/bin/sort -t $'\t' -k2,2nr \
                | /usr/bin/head -n "$remaining_rows"
        fi
    } | /usr/bin/sort -t $'\t' -k2,2nr > "$sorted_tmp" || {
        /bin/rm -f "$event_tmp" "$sorted_tmp" "$signal_tmp" "$metadata_tmp"
        return 1
    }
    SNAPSHOT_CAPTURED="$(/usr/bin/wc -l < "$sorted_tmp" | /usr/bin/tr -d ' ')"
    case "$SNAPSHOT_CAPTURED" in ''|*[!0-9]*) SNAPSHOT_CAPTURED=0 ;; esac
    if [[ "$SNAPSHOT_CAPTURED" -gt 0 ]]; then
        history_tmp="$(/usr/bin/mktemp ./.storage-watch-paths.XXXXXX)" || {
            /bin/rm -f "$event_tmp" "$sorted_tmp" "$signal_tmp" "$metadata_tmp"
            return 1
        }
        {
            [[ -f "$SNAPSHOT_FILE" ]] && /bin/cat "$SNAPSHOT_FILE"
            /bin/cat "$sorted_tmp"
        } | /usr/bin/awk -F '\t' -v limit="$SNAPSHOT_EVENT_LIMIT" '
            {
                lines[NR] = $0
                timestamps[NR] = $1
                if (!($1 in event_numbers)) {
                    event_count += 1
                    event_numbers[$1] = event_count
                }
            }
            END {
                first_event = event_count - limit + 1
                if (first_event < 1) first_event = 1
                for (row = 1; row <= NR; row++) {
                    if (event_numbers[timestamps[row]] >= first_event) print lines[row]
                }
            }
        ' | /usr/bin/tail -n "$maximum_history_rows" > "$history_tmp" || {
            /bin/rm -f "$event_tmp" "$sorted_tmp" "$signal_tmp" "$metadata_tmp" "$history_tmp"
            return 1
        }
        /bin/chmod 600 "$history_tmp" 2>/dev/null || true
        /bin/mv "$history_tmp" "$SNAPSHOT_FILE" || {
            /bin/rm -f "$event_tmp" "$sorted_tmp" "$signal_tmp" "$metadata_tmp" "$history_tmp"
            return 1
        }
    fi
    /bin/rm -f "$event_tmp" "$sorted_tmp" "$signal_tmp" "$metadata_tmp"
    return 0
}

# Evidence for both warnings, not only the sudden one.
#
# A drop of 8GB in one sample captured a snapshot; falling below 20GB did
# not. So a disk that slid down over days -- 25, 19, 14, 8 -- warned the
# owner every hour and left nothing behind saying what was large at the
# time, which is the whole question the warning raises. Measured on this
# machine the slow slide is the common case, and the fast drop is rare.
#
# Rate-limited the same way the notification is, and for the same reason:
# once under the threshold every hourly run would otherwise re-measure
# the same roots forever. Entering the warning state captures; staying in
# it re-captures only after the cooldown, or after losing another
# threshold's worth of space.
SNAPSHOT_COOLDOWN_SECONDS=21600
SNAPSHOT_REASON=""
if [[ "$DROP_KB" -ge "$DROP_THRESHOLD_KB" ]]; then
    SNAPSHOT_REASON="rapid-drop"
elif [[ "$STATUS" == "warning" ]]; then
    if [[ "$PREVIOUS_STATUS" != "warning" ]]; then
        SNAPSHOT_REASON="entered-low-free"
    elif [[ ! -s "$SIGNALS_FILE" \
        && $((NOW_EPOCH - LAST_SNAPSHOT)) -ge 300 ]]; then
        # Upgrades from the path-only watcher should not wait six hours before
        # producing their first swap/RSS evidence. The short retry floor avoids
        # repeatedly measuring roots when the OS metadata commands are absent.
        SNAPSHOT_REASON="missing-pressure-evidence"
    elif [[ $((NOW_EPOCH - LAST_SNAPSHOT)) -ge "$SNAPSHOT_COOLDOWN_SECONDS" ]]; then
        SNAPSHOT_REASON="still-low-free"
    fi
fi
if [[ -n "$SNAPSHOT_REASON" ]]; then
    if capture_drop_snapshot; then
        LAST_SNAPSHOT="$NOW_EPOCH"
        LAST_EVIDENCE_AT="$EVENT_ISO"
    fi
fi
# osascript's "display notification" can only ever post as com.apple.ScriptEditor2
# (an Apple-binary entitlement Modore cannot acquire), so the one alert this
# product sends lives under an unrelated app's name in System Settings and can be
# silenced by muting that unrelated tool. Launching the real app briefly lets it
# post under its own identity via UNUserNotificationCenter instead. This only
# works if the app was told its own bundle path at install time (APP_BUNDLE_PATH)
# and that path still structurally looks like the same signed app — otherwise
# fall through to the always-available osascript path so a stale or missing
# path never makes the watch quieter than it was before this existed.
# Test-only indirection so pytest can verify which branch fires without
# actually posting to the real, live Notification Center on whatever Mac the
# suite happens to run on — display notification/open are real OS calls with
# a real on-screen effect regardless of PCH_TEST_MODE, and that effect landing
# on a developer's own daily-use Mac during an ordinary test run is a real
# incident, not a harmless test artifact. Both still default to the real
# absolute paths; only PCH_TEST_MODE=1 can move them, so production behavior
# and its absolute-path hardening are unchanged.
OPEN_BIN="/usr/bin/open"
OSASCRIPT_BIN="/usr/bin/osascript"
if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
    OPEN_BIN="${PCH_TEST_OPEN_BIN:-$OPEN_BIN}"
    OSASCRIPT_BIN="${PCH_TEST_OSASCRIPT_BIN:-$OSASCRIPT_BIN}"
fi

notify_via_app_bundle() {
    local bundle="$APP_BUNDLE_PATH" identifier
    [[ -n "$bundle" && "$bundle" == /* && "$bundle" == *.app ]] || return 1
    [[ -d "$bundle" && ! -L "$bundle" ]] || return 1
    path_has_unexpected_symlink "$bundle" && return 1
    [[ -x /usr/bin/plutil && -x "$OPEN_BIN" ]] || return 1
    identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw \
        "$bundle/Contents/Info.plist" 2>/dev/null)" || return 1
    [[ "$identifier" == "me.heznpc.modore" ]] || return 1
    bounded_notification_command "$NOTIFICATION_TICKS" \
        "$OPEN_BIN" -g -j -a "$bundle" --args --post-storage-notice "$MESSAGE"
}

if [[ "$STATUS" == "warning" && "$NOTIFY" == "1" ]]; then
    if [[ "$PREVIOUS_STATUS" != "warning" || $((NOW_EPOCH - LAST_NOTIFY)) -ge 21600 ]]; then
        if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
            notify_via_app_bundle || {
                if [[ -x "$OSASCRIPT_BIN" ]]; then
                    bounded_notification_command "$NOTIFICATION_TICKS" "$OSASCRIPT_BIN" \
                        -e 'on run argv' \
                        -e 'display notification (item 1 of argv) with title "Modore"' \
                        -e 'end run' \
                        "$MESSAGE" || true
                fi
            }
        fi
        LAST_NOTIFY="$NOW_EPOCH"
    fi
fi

TMP_FILE="$(/usr/bin/mktemp ./.storage-watch.XXXXXX)" || exit 1
HISTORY_TMP=""
cleanup() {
    [[ -z "$TMP_FILE" ]] || /bin/rm -f "$TMP_FILE"
    [[ -z "$HISTORY_TMP" ]] || /bin/rm -f "$HISTORY_TMP"
    release_watch_lock
}
trap cleanup EXIT
{
    /usr/bin/printf 'version\t1\n'
    /usr/bin/printf 'checkedAt\t%s\n' "$NOW_ISO"
    /usr/bin/printf 'status\t%s\n' "$STATUS"
    /usr/bin/printf 'freeKB\t%s\n' "$FREE_KB"
    /usr/bin/printf 'dropKB\t%s\n' "$DROP_KB"
    /usr/bin/printf 'snapshotRows\t%s\n' "$SNAPSHOT_CAPTURED"
    /usr/bin/printf 'signalsRows\t%s\n' "$SIGNALS_CAPTURED"
    /usr/bin/printf 'lastNotify\t%s\n' "$LAST_NOTIFY"
    /usr/bin/printf 'lastSnapshot\t%s\n' "$LAST_SNAPSHOT"
    /usr/bin/printf 'lastEvidenceAt\t%s\n' "$LAST_EVIDENCE_AT"
    /usr/bin/printf 'snapshotReason\t%s\n' "$SNAPSHOT_REASON"
    /usr/bin/printf 'message\t%s\n' "$MESSAGE"
} > "$TMP_FILE" || exit 1
/bin/chmod 600 "$TMP_FILE" 2>/dev/null || true
/bin/mv "$TMP_FILE" "$STATE_FILE" || exit 1
TMP_FILE=""

HISTORY_TMP="$(/usr/bin/mktemp ./.storage-samples.XXXXXX)" || exit 1
{
    [[ -f "$HISTORY_FILE" ]] && /bin/cat "$HISTORY_FILE"
    /usr/bin/printf '%s\t%s\t%s\t%s\n' "$NOW_ISO" "$FREE_KB" "$DROP_KB" "$STATUS"
} | /usr/bin/tail -n "$HISTORY_LIMIT" > "$HISTORY_TMP" || exit 1
/bin/chmod 600 "$HISTORY_TMP" 2>/dev/null || true
/bin/mv "$HISTORY_TMP" "$HISTORY_FILE" || exit 1
HISTORY_TMP=""
release_watch_lock
trap - EXIT

emit "version" "1"
emit "status" "$STATUS"
emit "freeKB" "$FREE_KB"
emit "dropKB" "$DROP_KB"
emit "snapshotRows" "$SNAPSHOT_CAPTURED"
emit "signalsRows" "$SIGNALS_CAPTURED"
emit "snapshotReason" "$SNAPSHOT_REASON"
emit "message" "$MESSAGE"
