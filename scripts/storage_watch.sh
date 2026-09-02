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
    PRESSURE_DROP_THRESHOLD_MB="${PCH_WATCH_PRESSURE_DROP_MB:-512}"
    NOTIFY="${PCH_WATCH_NOTIFY:-1}"
    APP_BUNDLE_PATH="${PCH_STORAGE_WATCH_APP_BUNDLE:-}"
    APP_EXECUTABLE_SHA256="${PCH_STORAGE_WATCH_APP_EXECUTABLE_SHA256:-}"
    SNAPSHOT_TEST_ROOT="${PCH_WATCH_SNAPSHOT_ROOT:-}"
    SNAPSHOT_TOTAL_SECONDS="${PCH_WATCH_SNAPSHOT_TOTAL_SECONDS:-8}"
    SNAPSHOT_ITEM_SECONDS="${PCH_WATCH_SNAPSHOT_ITEM_SECONDS:-2}"
    SNAPSHOT_DEVICE_SECONDS="${PCH_WATCH_SNAPSHOT_DEVICE_SECONDS:-15}"
    SNAPSHOT_EVENT_LIMIT="${PCH_WATCH_SNAPSHOT_EVENT_LIMIT:-24}"
    PRIVATE_TMP_TEST_ROOT="${PCH_WATCH_PRIVATE_TMP_ROOT:-}"
    USER_TMP_TEST_ROOT="${PCH_WATCH_USER_TMP_ROOT:-}"
    SWAP_TEST_FILE="${PCH_WATCH_SWAP_TEST_FILE:-}"
    RSS_TEST_FILE="${PCH_WATCH_RSS_TEST_FILE:-}"
    METADATA_PS_TEST_ENABLED=0
    METADATA_SYSCTL_TEST_ENABLED=0
    [[ -z "${PCH_TEST_WATCH_PS_BIN:-}" ]] || METADATA_PS_TEST_ENABLED=1
    [[ -z "${PCH_TEST_WATCH_SYSCTL_BIN:-}" ]] || METADATA_SYSCTL_TEST_ENABLED=1
    METADATA_PS_BIN="${PCH_TEST_WATCH_PS_BIN:-/bin/ps}"
    METADATA_SYSCTL_BIN="${PCH_TEST_WATCH_SYSCTL_BIN:-/usr/sbin/sysctl}"
    DU_BIN="${PCH_TEST_WATCH_DU_BIN:-/usr/bin/du}"
    TEST_NOW_ISO="${PCH_TEST_WATCH_NOW_ISO:-}"
    TEST_NEXT_ISO="${PCH_TEST_WATCH_NEXT_ISO:-}"
    TEST_EVENT_FRACTION="${PCH_TEST_WATCH_EVENT_FRACTION:-}"
    TEST_LOGICAL_UNAME="${PCH_TEST_WATCH_LOGICAL_UNAME:-}"
    LOGICAL_DATE_BIN="${PCH_TEST_WATCH_LOGICAL_DATE_BIN:-/bin/date}"
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
    if [[ -n "$USER_TMP_TEST_ROOT" ]]; then
        [[ "$USER_TMP_TEST_ROOT" == /tmp/?* \
            || "$USER_TMP_TEST_ROOT" == /private/tmp/?* \
            || "$USER_TMP_TEST_ROOT" == /private/var/folders/?* \
            || "$USER_TMP_TEST_ROOT" == /var/folders/?* ]] || exit 64
    fi
    for test_input in "$SWAP_TEST_FILE" "$RSS_TEST_FILE"; do
        [[ -z "$test_input" || "$test_input" == /tmp/?* \
            || "$test_input" == /private/tmp/?* \
            || "$test_input" == /private/var/folders/?* \
            || "$test_input" == /var/folders/?* ]] || exit 64
    done
    for test_tool in "$METADATA_PS_BIN" "$METADATA_SYSCTL_BIN" "$DU_BIN"; do
        [[ "$test_tool" == /bin/ps || "$test_tool" == /usr/sbin/sysctl \
            || "$test_tool" == /usr/bin/du \
            || "$test_tool" == /tmp/?* || "$test_tool" == /private/tmp/?* \
            || "$test_tool" == /private/var/folders/?* \
            || "$test_tool" == /var/folders/?* ]] || exit 64
        [[ -x "$test_tool" && ! -L "$test_tool" ]] || exit 64
    done
    [[ "$TEST_LOGICAL_UNAME" == "" || "$TEST_LOGICAL_UNAME" == "Darwin" \
        || "$TEST_LOGICAL_UNAME" == "Linux" ]] || exit 64
    [[ "$LOGICAL_DATE_BIN" == "/bin/date" || "$LOGICAL_DATE_BIN" == /tmp/?* \
        || "$LOGICAL_DATE_BIN" == /private/tmp/?* \
        || "$LOGICAL_DATE_BIN" == /private/var/folders/?* \
        || "$LOGICAL_DATE_BIN" == /var/folders/?* ]] || exit 64
    [[ -x "$LOGICAL_DATE_BIN" && ! -L "$LOGICAL_DATE_BIN" ]] || exit 64
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
    PRESSURE_DROP_THRESHOLD_MB=512
    NOTIFY=1
    APP_BUNDLE_PATH="${PCH_STORAGE_WATCH_APP_BUNDLE:-}"
    APP_EXECUTABLE_SHA256="${PCH_STORAGE_WATCH_APP_EXECUTABLE_SHA256:-}"
    SNAPSHOT_TEST_ROOT=""
    SNAPSHOT_TOTAL_SECONDS=8
    SNAPSHOT_ITEM_SECONDS=2
    SNAPSHOT_DEVICE_SECONDS=15
    SNAPSHOT_EVENT_LIMIT=24
    PRIVATE_TMP_TEST_ROOT=""
    USER_TMP_TEST_ROOT=""
    SWAP_TEST_FILE=""
    RSS_TEST_FILE=""
    METADATA_PS_TEST_ENABLED=1
    METADATA_SYSCTL_TEST_ENABLED=1
    METADATA_PS_BIN="/bin/ps"
    METADATA_SYSCTL_BIN="/usr/sbin/sysctl"
    DU_BIN="/usr/bin/du"
    TEST_NOW_ISO=""
    TEST_NEXT_ISO=""
    TEST_EVENT_FRACTION=""
    TEST_LOGICAL_UNAME=""
    LOGICAL_DATE_BIN="/bin/date"
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
case "$PRESSURE_DROP_THRESHOLD_MB" in
    ''|*[!0-9]*|0) /usr/bin/printf 'ERROR: pressure drop threshold must be a positive whole MB value.\n' >&2; exit 64 ;;
esac
[[ "$PRESSURE_DROP_THRESHOLD_MB" -le 8192 ]] || exit 64
case "$HISTORY_LIMIT" in
    ''|*[!0-9]*|0) /usr/bin/printf 'ERROR: history limit must be a positive whole number.\n' >&2; exit 64 ;;
esac
case "$SNAPSHOT_TOTAL_SECONDS$SNAPSHOT_ITEM_SECONDS$SNAPSHOT_DEVICE_SECONDS$SNAPSHOT_EVENT_LIMIT" in
    *[!0-9]*) /usr/bin/printf 'ERROR: snapshot limits must be whole numbers.\n' >&2; exit 64 ;;
esac
[[ "$SNAPSHOT_TOTAL_SECONDS" -gt 0 && "$SNAPSHOT_ITEM_SECONDS" -gt 0 \
    && "$SNAPSHOT_DEVICE_SECONDS" -gt 0 && "$SNAPSHOT_DEVICE_SECONDS" -le 30 \
    && "$SNAPSHOT_EVENT_LIMIT" -gt 0 ]] || exit 64
for test_iso in "$TEST_NOW_ISO" "$TEST_NEXT_ISO"; do
    [[ -z "$test_iso" || "$test_iso" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || exit 64
done
case "$TEST_EVENT_FRACTION" in
    '') ;;
    *[!0-9]*) exit 64 ;;
    *) [[ "$TEST_EVENT_FRACTION" -le 999999 ]] || exit 64 ;;
esac
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

# Provider commands are normally instant, but the pressure watcher must not
# become another source of pressure when ps/sysctl or a descendant stalls.
# Partial output remains available to the caller and is labelled incomplete.
bounded_metadata_capture() (
    local output_file="$1"
    shift
    local maximum_ticks=10
    local output_limit_kb=2048
    local output_limit_blocks output_limit_bytes output_size
    local capture_pid ticks=0 command_status=0
    local status_marker="$output_file.status.$$.$RANDOM"
    local status_staging="$status_marker.tmp"
    # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
    cleanup_metadata_capture() {
        local cleanup_pid="${capture_pid:-}"
        trap - HUP INT TERM EXIT
        capture_pid=""
        if [[ -n "$cleanup_pid" ]]; then
            /bin/kill -TERM -- "-$cleanup_pid" 2>/dev/null || true
            /bin/sleep 0.2
            /bin/kill -KILL -- "-$cleanup_pid" 2>/dev/null || true
            wait "$cleanup_pid" 2>/dev/null || true
        fi
        /bin/rm -f "$status_marker" "$status_staging" 2>/dev/null || true
    }
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap cleanup_metadata_capture EXIT
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        maximum_ticks="${PCH_TEST_WATCH_METADATA_TICKS:-$maximum_ticks}"
        output_limit_kb="${PCH_TEST_WATCH_METADATA_OUTPUT_LIMIT_KB:-$output_limit_kb}"
    fi
    case "$maximum_ticks" in ''|*[!0-9]*|0) return 64 ;; esac
    case "$output_limit_kb" in ''|*[!0-9]*|0) return 64 ;; esac
    [[ "$maximum_ticks" -le 100 && "$output_limit_kb" -le 4096 ]] || return 64
    output_limit_blocks="$output_limit_kb"
    output_limit_bytes=$((output_limit_kb * 1024))
    : > "$output_file" || return 1
    /bin/rm -f "$status_marker" "$status_staging" 2>/dev/null || return 1
    exec 2>/dev/null
    set -m
    (
        trap - HUP INT TERM EXIT
        ulimit -f "$output_limit_blocks" || exit 1
        "$@"
        provider_status=$?
        if /usr/bin/printf '%s' "$provider_status" > "$status_staging" 2>/dev/null; then
            /bin/mv -f "$status_staging" "$status_marker" 2>/dev/null || true
        fi
        exit "$provider_status"
    ) > "$output_file" 2>/dev/null &
    capture_pid=$!
    while [[ ! -f "$status_marker" ]]; do
        if [[ "$ticks" -ge "$maximum_ticks" ]]; then
            /bin/kill -TERM -- "-$capture_pid" 2>/dev/null || true
            /bin/sleep 0.2
            /bin/kill -KILL -- "-$capture_pid" 2>/dev/null || true
            wait "$capture_pid" 2>/dev/null || true
            return 124
        fi
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    command_status="$(/bin/cat "$status_marker" 2>/dev/null || true)"
    case "$command_status" in ''|*[!0-9]*) command_status=1 ;; esac
    wait "$capture_pid" 2>/dev/null || true
    if /bin/kill -0 -- "-$capture_pid" 2>/dev/null; then
        /bin/kill -TERM -- "-$capture_pid" 2>/dev/null || true
        /bin/sleep 0.2
        /bin/kill -KILL -- "-$capture_pid" 2>/dev/null || true
    fi
    capture_pid=""
    /bin/rm -f "$status_marker" "$status_staging" 2>/dev/null || true
    output_size="$(/usr/bin/wc -c < "$output_file" 2>/dev/null | /usr/bin/tr -d ' ')"
    case "$output_size" in ''|*[!0-9]*) output_size=0 ;; esac
    [[ "$output_size" -lt "$output_limit_bytes" ]] || return 65
    return "$command_status"
)

process_start_identity() {
    local process_pid="$1" identity_file identity="" status=0
    case "$process_pid" in ''|*[!0-9]*|0) return 1 ;; esac
    identity_file="$(/usr/bin/mktemp ./.storage-watch-ps.XXXXXX)" || return 1
    bounded_metadata_capture "$identity_file" "$METADATA_PS_BIN" -p "$process_pid" -o lstart= \
        || status=$?
    if [[ "$status" -eq 0 ]]; then
        identity="$(/usr/bin/head -n 1 "$identity_file" 2>/dev/null \
            | /usr/bin/awk '{$1=$1; print}')"
    fi
    /bin/rm -f "$identity_file" 2>/dev/null || true
    [[ -n "$identity" ]] || return 1
    /usr/bin/printf '%s' "$identity"
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
                ps_output="${ready}.ps"
                bounded_parent_start() {
                    : > "$ps_output" || return 1
                    ( ulimit -f 4 || exit 1; exec /bin/ps -p "$parent" -o lstart= ) \
                        > "$ps_output" 2>/dev/null &
                    ps_pid=$!
                    ps_ticks=0
                    while jobs -pr | /usr/bin/grep -qx "$ps_pid"; do
                        if [[ "$ps_ticks" -ge 10 ]]; then
                            /bin/kill -KILL "$ps_pid" 2>/dev/null || true
                            wait "$ps_pid" 2>/dev/null || true
                            : > "$ps_output"
                            return 124
                        fi
                        /bin/sleep 0.1
                        ps_ticks=$((ps_ticks + 1))
                    done
                    wait "$ps_pid" 2>/dev/null || return 1
                    /usr/bin/head -n 1 "$ps_output" | /usr/bin/awk '\''{$1=$1; print}'\''
                }
                parent_matches() {
                    current_start="$(bounded_parent_start 2>/dev/null || true)"
                    [[ -n "$current_start" && "$current_start" == "$expected_start" ]]
                }
                cleanup_holder() {
                    /bin/rm -f "$ready" "$release" "$ps_output" 2>/dev/null || true
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
SNAPSHOT_COMPLETENESS="unknown"
EVIDENCE_POINTER_VERSION=""
LAST_EVIDENCE_AT=""
PREVIOUS_EVIDENCE_AT=""
LAST_PATH_EVIDENCE_AT=""
PREVIOUS_PATH_EVIDENCE_AT=""
if [[ -f "$STATE_FILE" ]]; then
    PREVIOUS_KB="$(/usr/bin/awk -F '\t' '$1 == "freeKB" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    PREVIOUS_STATUS="$(/usr/bin/awk -F '\t' '$1 == "status" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    LAST_NOTIFY="$(/usr/bin/awk -F '\t' '$1 == "lastNotify" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    LAST_SNAPSHOT="$(/usr/bin/awk -F '\t' '$1 == "lastSnapshot" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    SNAPSHOT_COMPLETENESS="$(/usr/bin/awk -F '\t' '$1 == "snapshotCompleteness" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    EVIDENCE_POINTER_VERSION="$(/usr/bin/awk -F '\t' '$1 == "evidencePointerVersion" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    LAST_EVIDENCE_AT="$(/usr/bin/awk -F '\t' '$1 == "lastEvidenceAt" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    PREVIOUS_EVIDENCE_AT="$(/usr/bin/awk -F '\t' '$1 == "previousEvidenceAt" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    LAST_PATH_EVIDENCE_AT="$(/usr/bin/awk -F '\t' '$1 == "lastPathEvidenceAt" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
    PREVIOUS_PATH_EVIDENCE_AT="$(/usr/bin/awk -F '\t' '$1 == "previousPathEvidenceAt" {print $2; exit}' "$STATE_FILE" 2>/dev/null)"
fi
case "$PREVIOUS_KB" in ''|*[!0-9]*) PREVIOUS_KB=0 ;; esac
NOW_EPOCH="$(/bin/date '+%s')"
normalize_past_epoch() {
    local value="$1"
    case "$value" in ''|*[!0-9]*) /usr/bin/printf '0'; return ;; esac
    if [[ "${#value}" -gt 10 ]]; then
        /usr/bin/printf '0'
        return
    fi
    value=$((10#$value))
    if [[ "$value" -gt "$NOW_EPOCH" ]]; then
        value=0
    fi
    /usr/bin/printf '%s' "$value"
}
LAST_NOTIFY="$(normalize_past_epoch "$LAST_NOTIFY")"
LAST_SNAPSHOT="$(normalize_past_epoch "$LAST_SNAPSHOT")"
case "$SNAPSHOT_COMPLETENESS" in complete|partial|unknown) ;; *) SNAPSHOT_COMPLETENESS="unknown" ;; esac
[[ "$EVIDENCE_POINTER_VERSION" == "2" ]] || EVIDENCE_POINTER_VERSION=""
case "$LAST_EVIDENCE_AT" in
    *$'\t'*|*$'\n'*|*$'\r'*) LAST_EVIDENCE_AT="" ;;
esac
[[ "${#LAST_EVIDENCE_AT}" -le 64 ]] || LAST_EVIDENCE_AT=""
case "$PREVIOUS_EVIDENCE_AT" in
    *$'\t'*|*$'\n'*|*$'\r'*) PREVIOUS_EVIDENCE_AT="" ;;
esac
[[ "${#PREVIOUS_EVIDENCE_AT}" -le 64 ]] || PREVIOUS_EVIDENCE_AT=""
case "$LAST_PATH_EVIDENCE_AT" in
    *$'\t'*|*$'\n'*|*$'\r'*) LAST_PATH_EVIDENCE_AT="" ;;
esac
[[ "${#LAST_PATH_EVIDENCE_AT}" -le 64 ]] || LAST_PATH_EVIDENCE_AT=""
case "$PREVIOUS_PATH_EVIDENCE_AT" in
    *$'\t'*|*$'\n'*|*$'\r'*) PREVIOUS_PATH_EVIDENCE_AT="" ;;
esac
[[ "${#PREVIOUS_PATH_EVIDENCE_AT}" -le 64 ]] || PREVIOUS_PATH_EVIDENCE_AT=""

# Version 2 separates the latest committed evidence event from the two path
# events used for a size delta. A signal-only capture must advance the former,
# but must never become the previous endpoint of the next path comparison.
#
# Migrate once while holding the exclusive lock. Existing state pointers are
# authoritative; history is consulted only when an old state has no pointer at
# all, and a path anchor is derived only from an exact committed timestamp.
# This avoids promoting a newer history tail left by a killed writer.
if [[ "$EVIDENCE_POINTER_VERSION" != "2" ]]; then
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
    if [[ -z "$LAST_PATH_EVIDENCE_AT" && -s "$SNAPSHOT_FILE" ]]; then
        if [[ -n "$LAST_EVIDENCE_AT" ]] \
            && /usr/bin/awk -F '\t' -v target="$LAST_EVIDENCE_AT" \
                '$1 == target {found=1; exit} END {exit !found}' "$SNAPSHOT_FILE"; then
            LAST_PATH_EVIDENCE_AT="$LAST_EVIDENCE_AT"
        elif [[ -n "$PREVIOUS_EVIDENCE_AT" ]] \
            && /usr/bin/awk -F '\t' -v target="$PREVIOUS_EVIDENCE_AT" \
                '$1 == target {found=1; exit} END {exit !found}' "$SNAPSHOT_FILE"; then
            LAST_PATH_EVIDENCE_AT="$PREVIOUS_EVIDENCE_AT"
        fi
    fi
    if [[ -n "$LAST_PATH_EVIDENCE_AT" && -z "$PREVIOUS_PATH_EVIDENCE_AT" ]]; then
        PREVIOUS_PATH_EVIDENCE_AT="$(/usr/bin/awk -F '\t' -v target="$LAST_PATH_EVIDENCE_AT" '
            $1 != current {
                if ($1 == target) { print previous; exit }
                previous = $1
                current = $1
            }
        ' "$SNAPSHOT_FILE" 2>/dev/null)"
    fi
    EVIDENCE_POINTER_VERSION="2"
fi

DROP_KB=0
if [[ "$PREVIOUS_KB" -gt "$FREE_KB" ]]; then
    DROP_KB=$((PREVIOUS_KB - FREE_KB))
fi
FREE_THRESHOLD_KB=$((FREE_THRESHOLD_GB * 1024 * 1024))
DROP_THRESHOLD_KB=$((DROP_THRESHOLD_GB * 1024 * 1024))
PRESSURE_DROP_THRESHOLD_KB=$((PRESSURE_DROP_THRESHOLD_MB * 1024))
STATUS="normal"
MESSAGE="저장공간 변화가 정상 범위입니다."
if [[ "$FREE_KB" -lt "$FREE_THRESHOLD_KB" ]]; then
    STATUS="warning"
    MESSAGE="남은 저장공간이 ${FREE_THRESHOLD_GB}GB 아래입니다. Modore를 열어 원인을 확인하세요."
elif [[ "$DROP_KB" -ge "$DROP_THRESHOLD_KB" ]]; then
    STATUS="warning"
    MESSAGE="최근 점검 이후 저장공간이 ${DROP_THRESHOLD_GB}GB 이상 줄었습니다. Modore를 열어 원인을 확인하세요."
fi

NOW_ISO="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
[[ -z "$TEST_NOW_ISO" ]] || NOW_ISO="$TEST_NOW_ISO"
# A manual kickstart can produce two samples inside one wall-clock second.
# Keep the state timestamp human-sized, but give each evidence event a stable
# fractional component derived from this short-lived watcher process. When a
# second run has a lower PID fraction, advance from the committed pointer. The
# only overflow waits for the next wall-clock second under a two-second bound.
event_fraction=$(( $$ % 1000000 ))
[[ -z "$TEST_EVENT_FRACTION" ]] || event_fraction=$((10#$TEST_EVENT_FRACTION))
event_base="${NOW_ISO%Z}"
last_event_base=""
last_event_fraction=""
if [[ "$LAST_EVIDENCE_AT" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})\.([0-9]{6})Z$ ]]; then
    last_event_base="${BASH_REMATCH[1]}"
    last_event_fraction="${BASH_REMATCH[2]}"
elif [[ "$LAST_EVIDENCE_AT" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})Z$ ]]; then
    last_event_base="${BASH_REMATCH[1]}"
    last_event_fraction="000000"
fi
if [[ "$last_event_base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ \
    && "$event_base" < "$last_event_base" ]]; then
    # Wall clocks can move backwards after NTP correction or VM resume. Keep a
    # bounded logical clock at the last committed second instead of waiting for
    # real time to catch up, which could stall the LaunchAgent indefinitely.
    event_base="$last_event_base"
fi
if [[ "$last_event_base" == "$event_base" && "${#last_event_fraction}" -eq 6 \
    && "$last_event_fraction" != *[!0-9]* \
    && $((10#$last_event_fraction)) -ge "$event_fraction" ]]; then
    if [[ $((10#$last_event_fraction)) -lt 999999 ]]; then
        event_fraction=$((10#$last_event_fraction + 1))
    else
        next_iso="$TEST_NEXT_ISO"
        if [[ -z "$next_iso" ]]; then
            logical_uname="$TEST_LOGICAL_UNAME"
            [[ -n "$logical_uname" ]] || logical_uname="$(/usr/bin/uname -s)"
            if [[ "$logical_uname" == "Darwin" ]]; then
                next_iso="$("$LOGICAL_DATE_BIN" -j -u -v+1S \
                    -f '%Y-%m-%dT%H:%M:%S' "$event_base" \
                    '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
            else
                next_iso="$("$LOGICAL_DATE_BIN" -u -d "$event_base UTC + 1 second" \
                    '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
            fi
        fi
        [[ "$next_iso" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
            && "${next_iso%Z}" > "$event_base" ]] || exit 1
        NOW_ISO="$next_iso"
        event_base="${NOW_ISO%Z}"
    fi
fi
NOW_ISO="$event_base"Z
EVENT_ISO="$event_base.$(/usr/bin/printf '%06d' "$event_fraction")Z"
SNAPSHOT_CAPTURED=0
SIGNALS_CAPTURED=0

bounded_notification_command() (
    local maximum_ticks="$1"
    shift
    local command_pid="" ticks=0 command_status=0
    local status_marker status_staging
    status_marker="$(/usr/bin/mktemp ./.storage-watch-notify.XXXXXX)" || return 1
    status_staging="$status_marker.tmp"
    /bin/rm -f "$status_marker" "$status_staging" 2>/dev/null || return 1
    # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
    cleanup_notification_command() {
        local cleanup_pid="${command_pid:-}"
        trap - HUP INT TERM EXIT
        command_pid=""
        if [[ -n "$cleanup_pid" ]]; then
            /bin/kill -TERM -- "-$cleanup_pid" 2>/dev/null || true
            /bin/sleep 0.2
            /bin/kill -KILL -- "-$cleanup_pid" 2>/dev/null || true
            wait "$cleanup_pid" 2>/dev/null || true
        fi
        /bin/rm -f "$status_marker" "$status_staging" 2>/dev/null || true
    }
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap cleanup_notification_command EXIT
    # A notification helper may itself fork (AppleScript and shell wrappers do).
    # Job control gives the helper a private process group, so the deadline can
    # stop the whole tree instead of leaving a pressure-amplifying orphan.
    exec 2>/dev/null
    set -m
    (
        trap - HUP INT TERM EXIT
        "$@" >/dev/null 2>&1
        provider_status=$?
        if /usr/bin/printf '%s' "$provider_status" > "$status_staging" 2>/dev/null; then
            /bin/mv -f "$status_staging" "$status_marker" 2>/dev/null || true
        fi
        exit "$provider_status"
    ) &
    command_pid=$!
    while [[ ! -f "$status_marker" ]]; do
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
            command_pid=""
            /bin/rm -f "$status_marker" "$status_staging" 2>/dev/null || true
            return 124
        fi
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    command_status="$(/bin/cat "$status_marker" 2>/dev/null || true)"
    case "$command_status" in ''|*[!0-9]*) command_status=1 ;; esac
    wait "$command_pid" 2>/dev/null || true
    if /bin/kill -0 -- "-$command_pid" 2>/dev/null; then
        /bin/kill -TERM -- "-$command_pid" 2>/dev/null || true
        /bin/sleep 0.2
        /bin/kill -KILL -- "-$command_pid" 2>/dev/null || true
    fi
    command_pid=""
    /bin/rm -f "$status_marker" "$status_staging" 2>/dev/null || true
    return "$command_status"
)

capture_drop_snapshot() {
    local event_tmp sorted_tmp history_tmp candidate label path
    local signal_tmp signal_history_tmp metadata_tmp swap_input rss_input
    local swap_used_kb swap_allocated_kb rss_kb rss_pid rss_reference rss_label
    local swap_capture_status="ok" rss_capture_status="ok" capture_status=0
    local result_file pid waited_ticks size_kb status modified_epoch command_status
    local priority_rows remaining_rows
    local elapsed_ticks=0
    local total_ticks=$((SNAPSHOT_TOTAL_SECONDS * 10))
    local item_ticks=$((SNAPSHOT_ITEM_SECONDS * 10))
    local device_ticks=$((SNAPSHOT_DEVICE_SECONDS * 10))
    local maximum_rows=12
    local maximum_history_rows=$((SNAPSHOT_EVENT_LIMIT * maximum_rows))
    local maximum_rss_rows=3
    local maximum_signal_rows=$((maximum_rss_rows + 1))
    local maximum_signal_history_rows=$((SNAPSHOT_EVENT_LIMIT * maximum_signal_rows))
    local -a candidates=()
    local -a simulator_fast_candidates=()
    local deferred_simulator_device=""
    local capture_is_complete=1

    # These are common short-lived AI/tooling workspaces that can grow between
    # hourly samples. Measure them before broad cache roots so the shared
    # snapshot deadline cannot consistently starve the most transient evidence.
    # /private/tmp is shared by every local account, so admit only this user's
    # direct children. The bounded recent set catches tool-specific names such
    # as airmcp-* and skillbridge-* without recursively inventorying unrelated
    # temporary content or turning the watcher into a second storage workload.
    local private_tmp_root="/private/tmp"
    local user_tmp_root=""
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        private_tmp_root="$PRIVATE_TMP_TEST_ROOT"
        user_tmp_root="$USER_TMP_TEST_ROOT"
    else
        user_tmp_root="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
        user_tmp_root="${user_tmp_root%/}"
        if [[ -n "$user_tmp_root" && -d "$user_tmp_root" ]]; then
            user_tmp_root="$(cd -P "$user_tmp_root" 2>/dev/null && /bin/pwd -P)" || user_tmp_root=""
        fi
    fi
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
        # below decide which rows survive the twelve-row event cap.
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
        while IFS=$'\t' read -r _ path; do
            [[ -n "$path" ]] || continue
            candidates+=("사용자 임시 작업"$'\t'"$path")
        done < <(
            for path in "$private_tmp_root"/*; do
                [[ -e "$path" && ! -L "$path" ]] || continue
                if [[ "${path##*/}" == "claude-$(/usr/bin/id -u)" \
                    || "${path##*/}" == modore-* ]]; then
                    continue
                fi
                if [[ "$(path_owner_uid "$path")" == "$(/usr/bin/id -u)" \
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
    if [[ -n "$user_tmp_root" && -d "$user_tmp_root" \
        && ! -L "$user_tmp_root" \
        && "$(path_owner_uid "$user_tmp_root")" == "$(/usr/bin/id -u)" ]] \
        && ! path_has_unexpected_symlink "$user_tmp_root"; then
        candidates+=("사용자 임시 데이터"$'\t'"$user_tmp_root")
    fi

    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        if [[ -n "$SNAPSHOT_TEST_ROOT" && -d "$SNAPSHOT_TEST_ROOT" \
            && ! -L "$SNAPSHOT_TEST_ROOT" ]] \
            && ! path_has_unexpected_symlink "$SNAPSHOT_TEST_ROOT"; then
            for path in "$SNAPSHOT_TEST_ROOT"/*; do
                [[ -e "$path" && ! -L "$path" ]] || continue
                label="$(/usr/bin/basename "$path")"
                case "$label" in
                    "Simulator 기기 데이터")
                        deferred_simulator_device="$label"$'\t'"$path"
                        ;;
                    "Simulator 공유 dyld 캐시"|"Simulator 런타임 · "*)
                        simulator_fast_candidates+=("$label"$'\t'"$path")
                        ;;
                    *) candidates+=("$label"$'\t'"$path") ;;
                esac
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
        simulator_fast_candidates+=("Simulator 런타임 · iOS"$'\t'"/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime")
        simulator_fast_candidates+=("Simulator 런타임 · watchOS"$'\t'"/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_watchOSSimulatorRuntime")
        simulator_fast_candidates+=("Simulator 런타임 · tvOS"$'\t'"/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_appleTVOSSimulatorRuntime")
        simulator_fast_candidates+=("Simulator 런타임 · xrOS"$'\t'"/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_xrOSSimulatorRuntime")
        simulator_fast_candidates+=("Simulator 공유 dyld 캐시"$'\t'"/Library/Developer/CoreSimulator/Caches/dyld")
        candidates+=("Codex 로컬 데이터"$'\t'"$HOME_ROOT/.codex")
        candidates+=("Claude 로컬 에이전트"$'\t'"$HOME_ROOT/Library/Application Support/Claude")
        candidates+=("Playwright 브라우저"$'\t'"$HOME_ROOT/Library/Caches/ms-playwright")
        candidates+=("npm 캐시"$'\t'"$HOME_ROOT/.npm")
        candidates+=("pnpm 저장소"$'\t'"$HOME_ROOT/Library/pnpm")
        candidates+=("Xcode 개발 데이터"$'\t'"$HOME_ROOT/Library/Developer/Xcode")
        candidates+=("사용자 캐시"$'\t'"$HOME_ROOT/Library/Caches")
        # Devices is the slowest known root on a machine with many simulators.
        # Keep it last so its bounded timeout cannot consume the slots needed by
        # runtimes, dyld, and fast agent/cache roots. Never add CoreSimulator's
        # Volumes mountpoints: they mirror runtime assets rather than new bytes.
        deferred_simulator_device="Simulator 기기 데이터"$'\t'"$HOME_ROOT/Library/Developer/CoreSimulator/Devices"
    fi
    candidates=("${simulator_fast_candidates[@]+"${simulator_fast_candidates[@]}"}" \
        "${candidates[@]+"${candidates[@]}"}")
    [[ -z "$deferred_simulator_device" ]] || candidates+=("$deferred_simulator_device")

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
        command_status=0
        local is_simulator_device=0
        [[ "$label" != "Simulator 기기 데이터" ]] || is_simulator_device=1
        if [[ "$is_simulator_device" -eq 0 && "$elapsed_ticks" -ge "$total_ticks" ]]; then
            status="timed_out"
        else
            local allowed_ticks="$item_ticks"
            if [[ "$is_simulator_device" -eq 1 ]]; then
                allowed_ticks="$device_ticks"
            elif [[ $((total_ticks - elapsed_ticks)) -lt "$allowed_ticks" ]]; then
                allowed_ticks=$((total_ticks - elapsed_ticks))
            fi
            result_file="$(/usr/bin/mktemp ./.storage-watch-du.XXXXXX)" || {
                status="timed_out"
                allowed_ticks=0
            }
            if [[ "$allowed_ticks" -gt 0 ]]; then
                "$DU_BIN" -sk "$path" > "$result_file" 2>/dev/null &
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
                    # A nonzero du can leave a useful lower bound, but it did
                    # not prove an exact total. Preserve the number as partial
                    # evidence and use the existing incomplete status understood
                    # by the history loader and path-delta model.
                    wait "$pid" 2>/dev/null || command_status=$?
                fi
                if [[ "$is_simulator_device" -eq 0 ]]; then
                    elapsed_ticks=$((elapsed_ticks + waited_ticks))
                fi
                if [[ "$status" == "ok" ]]; then
                    size_kb="$(/usr/bin/awk '{print $1; exit}' "$result_file" 2>/dev/null)"
                    case "$size_kb" in ''|*[!0-9]*) size_kb=0; status="unavailable" ;; esac
                    if [[ "$status" == "ok" && "$command_status" -ne 0 ]]; then
                        status="timed_out"
                    fi
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
        [[ "$status" == "ok" ]] || capture_is_complete=0
    done

    # Swap is disk-backed pressure that df alone cannot explain. Capture only
    # the two numeric counters from sysctl; never persist its original output.
    # Test mode accepts a private fixture file so Linux tests do not depend on
    # macOS sysctl.
    swap_input=""
    if [[ "${PCH_TEST_MODE:-0}" == "1" && -n "$SWAP_TEST_FILE" \
        && -f "$SWAP_TEST_FILE" && ! -L "$SWAP_TEST_FILE" ]] \
        && ! path_has_unexpected_symlink "$SWAP_TEST_FILE"; then
        swap_input="$(/usr/bin/head -c 4096 "$SWAP_TEST_FILE" 2>/dev/null)"
    elif [[ "$(/usr/bin/uname -s)" == "Darwin" \
        && "$METADATA_SYSCTL_TEST_ENABLED" == "1" ]]; then
        bounded_metadata_capture "$metadata_tmp" "$METADATA_SYSCTL_BIN" vm.swapusage \
            || capture_status=$?
        case "$capture_status" in
            0) swap_capture_status="ok" ;;
            124) swap_capture_status="timed_out" ;;
            65) swap_capture_status="output_limited" ;;
            *) swap_capture_status="failed" ;;
        esac
        [[ "$swap_capture_status" == "ok" ]] || capture_is_complete=0
        swap_input="$(/usr/bin/head -c 4096 "$metadata_tmp" 2>/dev/null)"
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
                /usr/bin/printf '%s\tswap\t%s\t%s\t0\t%s\tmacOS 스왑\t/private/var/vm\n' \
                    "$EVENT_ISO" "$swap_used_kb" "$swap_allocated_kb" \
                    "$swap_capture_status" >> "$signal_tmp"
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
    if [[ "${PCH_TEST_MODE:-0}" == "1" && -n "$RSS_TEST_FILE" \
        && -f "$RSS_TEST_FILE" && ! -L "$RSS_TEST_FILE" ]] \
        && ! path_has_unexpected_symlink "$RSS_TEST_FILE"; then
        rss_input="$(/usr/bin/head -n 512 "$RSS_TEST_FILE" 2>/dev/null)"
    elif [[ "$(/usr/bin/uname -s)" == "Darwin" \
        && "$METADATA_PS_TEST_ENABLED" == "1" ]]; then
        # -m sorts by memory. The 512-line cap and the later three-row cap keep
        # both processing and retained evidence independent of process count.
        capture_status=0
        bounded_metadata_capture "$metadata_tmp" \
            "$METADATA_PS_BIN" -U "$(/usr/bin/id -u)" -m -x -o pid=,rss=,ucomm= \
            || capture_status=$?
        case "$capture_status" in
            0) rss_capture_status="ok" ;;
            124) rss_capture_status="timed_out" ;;
            65) rss_capture_status="output_limited" ;;
            *) rss_capture_status="failed" ;;
        esac
        [[ "$rss_capture_status" == "ok" ]] || capture_is_complete=0
        rss_input="$(/usr/bin/head -n 512 "$metadata_tmp" 2>/dev/null)"
    fi
    if [[ -n "$rss_input" ]]; then
        while IFS=$'\t' read -r rss_kb rss_pid rss_reference; do
            case "$rss_kb$rss_pid" in ''|*[!0-9]*) continue ;; esac
            [[ -n "$rss_reference" && ${#rss_reference} -le 256 ]] || continue
            case "$rss_reference" in *$'\t'*|*$'\n'*|*$'\r'*) continue ;; esac
            rss_label="$rss_reference"
            /usr/bin/printf '%s\tprocess_rss\t%s\t0\t%s\t%s\t%s\t%s\n' \
                "$EVENT_ISO" "$rss_kb" "$rss_pid" "$rss_capture_status" \
                "$rss_label" "$rss_reference" \
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

    # Reserve category slots inside the twelve-row event. Transient workspaces
    # retain four slots, every installed runtime retains one, and device/dyld
    # each retain one. This
    # keeps the fast runtime/cache facts visible even when the Devices walk is
    # slow or a broad persistent root is larger.
    : > "$metadata_tmp" || return 1
    {
        /usr/bin/awk -F '\t' '$4 == "Claude 임시 작업"' "$event_tmp" \
            | /usr/bin/sort -t $'\t' -k2,2nr | /usr/bin/head -n 1
        /usr/bin/awk -F '\t' \
            '$4 == "Modore 임시 작업" || $4 == "사용자 임시 작업"' "$event_tmp" \
            | /usr/bin/sort -t $'\t' -k2,2nr | /usr/bin/head -n 3
        /usr/bin/awk -F '\t' '$4 ~ /^Simulator 런타임 · /' "$event_tmp" \
            | /usr/bin/sort -t $'\t' -k2,2nr
        /usr/bin/awk -F '\t' '$4 == "Simulator 공유 dyld 캐시"' "$event_tmp" \
            | /usr/bin/sort -t $'\t' -k2,2nr | /usr/bin/head -n 1
        /usr/bin/awk -F '\t' '$4 == "Simulator 기기 데이터"' "$event_tmp" \
            | /usr/bin/sort -t $'\t' -k2,2nr | /usr/bin/head -n 1
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
    if [[ "$SNAPSHOT_CAPTURED" -eq 0 && "$SIGNALS_CAPTURED" -eq 0 ]]; then
        capture_is_complete=0
    fi
    if [[ "$capture_is_complete" == "1" ]]; then
        SNAPSHOT_COMPLETENESS="complete"
    else
        SNAPSHOT_COMPLETENESS="partial"
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
    elif [[ "$DROP_KB" -ge "$PRESSURE_DROP_THRESHOLD_KB" \
        && $((NOW_EPOCH - LAST_SNAPSHOT)) -ge 300 ]]; then
        # Notification cadence remains intentionally coarse, but once the disk
        # is already under pressure a 512MB sample-to-sample loss is enough to
        # justify fresh attribution evidence. The five-minute floor prevents a
        # rapidly writing process from turning diagnosis into additional I/O.
        SNAPSHOT_REASON="pressure-drop"
    elif [[ "$SNAPSHOT_COMPLETENESS" == "partial" \
        && $((NOW_EPOCH - LAST_SNAPSHOT)) -ge 300 ]]; then
        SNAPSHOT_REASON="incomplete-pressure-evidence"
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
        if [[ "$SNAPSHOT_CAPTURED" -gt 0 || "$SIGNALS_CAPTURED" -gt 0 ]]; then
            PREVIOUS_EVIDENCE_AT="$LAST_EVIDENCE_AT"
            LAST_EVIDENCE_AT="$EVENT_ISO"
        fi
        if [[ "$SNAPSHOT_CAPTURED" -gt 0 ]]; then
            PREVIOUS_PATH_EVIDENCE_AT="$LAST_PATH_EVIDENCE_AT"
            LAST_PATH_EVIDENCE_AT="$EVENT_ISO"
        fi
    fi
fi
# Notifications must remain under Modore's identity. `osascript display
# notification` is always attributed to com.apple.ScriptEditor2, so using it as
# a fallback produces a misleading Script Editor alert and click target. If the
# signed app cannot acknowledge that Notification Center accepted the request,
# keep `lastNotify` unchanged and retry later instead of impersonating an Apple
# utility.
# Test-only indirection so pytest can verify which branch fires without
# actually posting to the real, live Notification Center on whatever Mac the
# suite happens to run on — open is a real OS call with
# a real on-screen effect regardless of PCH_TEST_MODE, and that effect landing
# on a developer's own daily-use Mac during an ordinary test run is a real
# incident, not a harmless test artifact. Both still default to the real
# absolute paths; only PCH_TEST_MODE=1 can move them, so production behavior
# and its absolute-path hardening are unchanged.
OPEN_BIN="/usr/bin/open"
if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
    OPEN_BIN="${PCH_TEST_OPEN_BIN:-$OPEN_BIN}"
fi

notify_via_app_bundle() {
    local bundle="$APP_BUNDLE_PATH" identifier executable_name executable digest
    local ack_file nonce
    [[ -n "$bundle" && "$bundle" == /* && "$bundle" == *.app ]] || return 1
    [[ "$APP_EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ -d "$bundle" && ! -L "$bundle" ]] || return 1
    path_has_unexpected_symlink "$bundle" && return 1
    [[ -x /usr/bin/plutil && -x /usr/bin/codesign && -x /usr/bin/shasum \
        && -x /usr/bin/uuidgen && -x "$OPEN_BIN" ]] || return 1
    /usr/bin/codesign --verify --strict "$bundle" >/dev/null 2>&1 || return 1
    identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw \
        "$bundle/Contents/Info.plist" 2>/dev/null)" || return 1
    [[ "$identifier" == "me.heznpc.modore" ]] || return 1
    executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw \
        "$bundle/Contents/Info.plist" 2>/dev/null)" || return 1
    [[ -n "$executable_name" && "$executable_name" != "." \
        && "$executable_name" != ".." && "$executable_name" != */* \
        && "$executable_name" != *$'\t'* && "$executable_name" != *$'\n'* \
        && "$executable_name" != *$'\r'* && "${#executable_name}" -le 255 ]] || return 1
    executable="$bundle/Contents/MacOS/$executable_name"
    [[ -f "$executable" && ! -L "$executable" && -x "$executable" ]] || return 1
    path_has_unexpected_symlink "$executable" && return 1
    digest="$(/usr/bin/shasum -a 256 "$executable" 2>/dev/null \
        | /usr/bin/awk '{print $1; exit}')"
    [[ "$digest" == "$APP_EXECUTABLE_SHA256" ]] || return 1

    ack_file="$(/usr/bin/mktemp ./.storage-watch-ack.XXXXXX)" || return 1
    /bin/chmod 600 "$ack_file" 2>/dev/null || {
        /bin/rm -f "$ack_file" 2>/dev/null || true
        return 1
    }
    /bin/rm -f "$ack_file" 2>/dev/null || return 1
    ack_file="$STATE_DIR/${ack_file#./}"
    nonce="$(/usr/bin/uuidgen 2>/dev/null)" || return 1
    [[ "$nonce" =~ ^[A-Fa-f0-9-]{36}$ ]] || return 1

    # `--args` only reaches a newly launched process. Force a short-lived
    # notifier instance even when the normal Modore UI is already open;
    # BackgroundNotifier handles this request before the singleton lease.
    if ! bounded_notification_command "$NOTIFICATION_TICKS" \
        "$OPEN_BIN" -n -g -j -a "$bundle" --args \
        --post-storage-notice "$MESSAGE" \
        --storage-notice-ack "$ack_file" \
        --storage-notice-nonce "$nonce"; then
        /bin/rm -f "$ack_file" 2>/dev/null || true
        return 1
    fi
    local waited_ticks=0 acknowledgement="" permissions=""
    while [[ "$waited_ticks" -lt "$NOTIFICATION_TICKS" ]]; do
        if [[ -f "$ack_file" && ! -L "$ack_file" \
            && "$(path_owner_uid "$ack_file")" == "$(/usr/bin/id -u)" ]]; then
            permissions="$(path_permissions "$ack_file")" || permissions=""
            if [[ -n "$permissions" && $((8#$permissions & 0077)) -eq 0 ]]; then
                acknowledgement="$(/usr/bin/head -c 128 "$ack_file" 2>/dev/null)"
                if [[ "$acknowledgement" == "$nonce" ]]; then
                    /bin/rm -f "$ack_file" 2>/dev/null || true
                    return 0
                fi
            fi
        fi
        /bin/sleep 0.1
        waited_ticks=$((waited_ticks + 1))
    done
    /bin/rm -f "$ack_file" 2>/dev/null || true
    return 1
}

if [[ "$STATUS" == "warning" && "$NOTIFY" == "1" ]]; then
    if [[ "$PREVIOUS_STATUS" != "warning" || $((NOW_EPOCH - LAST_NOTIFY)) -ge 21600 ]]; then
        notification_delivered=0
        if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
            if notify_via_app_bundle; then
                notification_delivered=1
            fi
        fi
        if [[ "$notification_delivered" == "1" ]]; then
            LAST_NOTIFY="$NOW_EPOCH"
        fi
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
    /usr/bin/printf 'snapshotCompleteness\t%s\n' "$SNAPSHOT_COMPLETENESS"
    /usr/bin/printf 'evidencePointerVersion\t%s\n' "$EVIDENCE_POINTER_VERSION"
    /usr/bin/printf 'lastEvidenceAt\t%s\n' "$LAST_EVIDENCE_AT"
    /usr/bin/printf 'previousEvidenceAt\t%s\n' "$PREVIOUS_EVIDENCE_AT"
    /usr/bin/printf 'lastPathEvidenceAt\t%s\n' "$LAST_PATH_EVIDENCE_AT"
    /usr/bin/printf 'previousPathEvidenceAt\t%s\n' "$PREVIOUS_PATH_EVIDENCE_AT"
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
emit "evidencePointerVersion" "$EVIDENCE_POINTER_VERSION"
emit "lastEvidenceAt" "$LAST_EVIDENCE_AT"
emit "previousEvidenceAt" "$PREVIOUS_EVIDENCE_AT"
emit "lastPathEvidenceAt" "$LAST_PATH_EVIDENCE_AT"
emit "previousPathEvidenceAt" "$PREVIOUS_PATH_EVIDENCE_AT"
emit "snapshotReason" "$SNAPSHOT_REASON"
emit "message" "$MESSAGE"
