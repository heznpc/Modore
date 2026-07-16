#!/bin/bash -p
# Lightweight local disk-pressure watch. It records free space and, only after
# a large drop, a bounded size snapshot of known cache/runtime roots. It never
# reads file contents or deletes files.

set -u
set -o pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

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
    SNAPSHOT_TEST_ROOT="${PCH_WATCH_SNAPSHOT_ROOT:-}"
    SNAPSHOT_TOTAL_SECONDS="${PCH_WATCH_SNAPSHOT_TOTAL_SECONDS:-8}"
    SNAPSHOT_ITEM_SECONDS="${PCH_WATCH_SNAPSHOT_ITEM_SECONDS:-2}"
    SNAPSHOT_EVENT_LIMIT="${PCH_WATCH_SNAPSHOT_EVENT_LIMIT:-24}"
    if [[ -n "$SNAPSHOT_TEST_ROOT" ]]; then
        [[ "$SNAPSHOT_TEST_ROOT" == /tmp/?* || "$SNAPSHOT_TEST_ROOT" == /private/tmp/?* \
            || "$SNAPSHOT_TEST_ROOT" == /private/var/folders/?* \
            || "$SNAPSHOT_TEST_ROOT" == /var/folders/?* ]] || exit 64
    fi
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
    STATE_DIR="$HOME_ROOT/Library/Application Support/PC Health Check"
    HISTORY_LIMIT=336
    FREE_THRESHOLD_GB=20
    DROP_THRESHOLD_GB=8
    NOTIFY=1
    SNAPSHOT_TEST_ROOT=""
    SNAPSHOT_TOTAL_SECONDS=8
    SNAPSHOT_ITEM_SECONDS=2
    SNAPSHOT_EVENT_LIMIT=24
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
for state_path in "$STATE_FILE" "$HISTORY_FILE" "$SNAPSHOT_FILE"; do
    if [[ -e "$state_path" || -L "$state_path" ]]; then
        [[ -f "$state_path" && ! -L "$state_path" ]] || exit 1
    fi
done

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
SNAPSHOT_CAPTURED=0
capture_drop_snapshot() {
    local event_tmp sorted_tmp history_tmp candidate label path
    local result_file pid waited_ticks size_kb status
    local elapsed_ticks=0
    local total_ticks=$((SNAPSHOT_TOTAL_SECONDS * 10))
    local item_ticks=$((SNAPSHOT_ITEM_SECONDS * 10))
    local maximum_rows=8
    local maximum_history_rows=$((SNAPSHOT_EVENT_LIMIT * maximum_rows))
    local -a candidates=()

    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        [[ -n "$SNAPSHOT_TEST_ROOT" && -d "$SNAPSHOT_TEST_ROOT" \
            && ! -L "$SNAPSHOT_TEST_ROOT" ]] || return 0
        path_has_unexpected_symlink "$SNAPSHOT_TEST_ROOT" && return 0
        for path in "$SNAPSHOT_TEST_ROOT"/*; do
            [[ -e "$path" && ! -L "$path" ]] || continue
            candidates+=("$(/usr/bin/basename "$path")"$'\t'"$path")
        done
    else
        for path in \
            /private/var/folders/*/*/X/com.google.Chrome.code_sign_clone \
            /private/var/folders/*/*/T/com.google.Chrome.code_sign_clone; do
            [[ -d "$path" && ! -L "$path" ]] || continue
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
    for candidate in "${candidates[@]}"; do
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
            "$NOW_ISO" "$size_kb" "$status" "$label" "$path" >> "$event_tmp" || {
            /bin/rm -f "$event_tmp" "$sorted_tmp"
            return 1
        }
    done

    /usr/bin/sort -t $'\t' -k2,2nr "$event_tmp" | /usr/bin/head -n "$maximum_rows" \
        > "$sorted_tmp" || {
        /bin/rm -f "$event_tmp" "$sorted_tmp"
        return 1
    }
    SNAPSHOT_CAPTURED="$(/usr/bin/wc -l < "$sorted_tmp" | /usr/bin/tr -d ' ')"
    case "$SNAPSHOT_CAPTURED" in ''|*[!0-9]*) SNAPSHOT_CAPTURED=0 ;; esac
    if [[ "$SNAPSHOT_CAPTURED" -gt 0 ]]; then
        history_tmp="$(/usr/bin/mktemp ./.storage-watch-paths.XXXXXX)" || {
            /bin/rm -f "$event_tmp" "$sorted_tmp"
            return 1
        }
        {
            [[ -f "$SNAPSHOT_FILE" ]] && /bin/cat "$SNAPSHOT_FILE"
            /bin/cat "$sorted_tmp"
        } | /usr/bin/tail -n "$maximum_history_rows" > "$history_tmp" || {
            /bin/rm -f "$event_tmp" "$sorted_tmp" "$history_tmp"
            return 1
        }
        /bin/chmod 600 "$history_tmp" 2>/dev/null || true
        /bin/mv "$history_tmp" "$SNAPSHOT_FILE" || {
            /bin/rm -f "$event_tmp" "$sorted_tmp" "$history_tmp"
            return 1
        }
    fi
    /bin/rm -f "$event_tmp" "$sorted_tmp"
    return 0
}

if [[ "$DROP_KB" -ge "$DROP_THRESHOLD_KB" ]]; then
    capture_drop_snapshot || true
fi
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

TMP_FILE="$(/usr/bin/mktemp ./.storage-watch.XXXXXX)" || exit 1
HISTORY_TMP=""
cleanup() {
    [[ -z "$TMP_FILE" ]] || /bin/rm -f "$TMP_FILE"
    [[ -z "$HISTORY_TMP" ]] || /bin/rm -f "$HISTORY_TMP"
}
trap cleanup EXIT
{
    /usr/bin/printf 'version\t1\n'
    /usr/bin/printf 'checkedAt\t%s\n' "$NOW_ISO"
    /usr/bin/printf 'status\t%s\n' "$STATUS"
    /usr/bin/printf 'freeKB\t%s\n' "$FREE_KB"
    /usr/bin/printf 'dropKB\t%s\n' "$DROP_KB"
    /usr/bin/printf 'snapshotRows\t%s\n' "$SNAPSHOT_CAPTURED"
    /usr/bin/printf 'lastNotify\t%s\n' "$LAST_NOTIFY"
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
trap - EXIT

emit "version" "1"
emit "status" "$STATUS"
emit "freeKB" "$FREE_KB"
emit "dropKB" "$DROP_KB"
emit "snapshotRows" "$SNAPSHOT_CAPTURED"
emit "message" "$MESSAGE"
