#!/bin/bash -p
# Modore - 네트워크 관측기 (macOS). idle_cpu.sh와 같은 2표본 델타 패턴.
#
# 기본 스캔의 network 모듈은 시점 하나의 스냅샷만 본다. "관찰 구간 동안 어떤
# 새 목적지에 연결했는가"에 답하려면 구간 시작과 끝, 두 시점을 비교해야 한다.
#
# 연결의 동일성은 (프로세스 이름, 원격 주소:포트)로 판단하고 로컬 임시 포트는
# 무시한다 -- 이미 알던 서버로 재연결할 때마다 새 임시 포트가 배정되는 것은
# 정상 동작이라, 그것까지 "새 연결"로 세면 신호가 아니라 잡음이 된다. LISTEN
# 포트는 반대로 바인딩된 주소:포트 자체가 신호이므로 그대로 키로 쓴다.
#
# 읽기 전용이다. 아무것도 종료하거나 차단하지 않는다.

set -u
set -o pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

PROTOCOL_VERSION="1"
WINDOW_SECONDS="${PCH_NETWORK_WATCH_WINDOW:-60}"

usage() {
    /usr/bin/printf '%s\n' \
        'Usage:' \
        '  network_watch.sh [--window <seconds>]' \
        '' \
        '관찰 구간 시작과 끝, 두 시점의 연결/포트 목록을 비교해 새로 나타난 것만 보고한다.'
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --window) WINDOW_SECONDS="${2:-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) /usr/bin/printf 'ERROR: unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done

# 관측 구간을 제한한다. idle_cpu.sh와 동일한 상한(300초).
[[ "$WINDOW_SECONDS" =~ ^[1-9][0-9]{0,2}$ && "$WINDOW_SECONDS" -le 300 ]] \
    || { /usr/bin/printf 'ERROR: --window must be 1-300 seconds.\n' >&2; exit 64; }

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
    /usr/bin/printf 'ERROR: 이 관측기는 macOS 전용입니다.\n' >&2
    exit 1
fi

LSOF_BIN="/usr/sbin/lsof"
LSOF_TIMEOUT_TICKS=30
LSOF_OUTPUT_LIMIT_KB=256
if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
    LSOF_BIN="${PCH_TEST_LSOF_BIN:-$LSOF_BIN}"
    LSOF_TIMEOUT_TICKS="${PCH_TEST_NETWORK_LSOF_TIMEOUT_TICKS:-$LSOF_TIMEOUT_TICKS}"
    LSOF_OUTPUT_LIMIT_KB="${PCH_TEST_NETWORK_LSOF_OUTPUT_LIMIT_KB:-$LSOF_OUTPUT_LIMIT_KB}"
fi
case "$LSOF_TIMEOUT_TICKS" in ''|*[!0-9]*|0) exit 64 ;; esac
case "$LSOF_OUTPUT_LIMIT_KB" in ''|*[!0-9]*|0) exit 64 ;; esac
[[ "$LSOF_TIMEOUT_TICKS" -le 100 && "$LSOF_OUTPUT_LIMIT_KB" -le 1024 ]] || exit 64

emit() {
    local key="$1"
    local value="${2:-}"
    case "$key$value" in
        *$'\t'*|*$'\n'*|*$'\r'*) value="출력할 수 없는 제어 문자가 포함되었습니다." ;;
    esac
    /usr/bin/printf '%s\t%s\n' "$key" "$value"
}

if [[ ! -x "$LSOF_BIN" ]]; then
    emit "version" "$PROTOCOL_VERSION"
    emit "operation" "network-watch"
    emit "windowSeconds" "$WINDOW_SECONDS"
    emit "error" "lsof를 사용할 수 없습니다."
    exit 0
fi

WORKSPACE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/modore-network-watch.XXXXXX")" || exit 1
cleanup() { /bin/rm -rf "$WORKSPACE"; }
trap cleanup EXIT

capture_lsof_sample() (
    local destination="$1"
    local error_destination="$2"
    shift 2
    local command_pid ticks=0 command_status=0 output_size
    local output_limit_blocks="$LSOF_OUTPUT_LIMIT_KB"
    local output_limit_bytes=$((LSOF_OUTPUT_LIMIT_KB * 1024))
    local status_marker="${destination}.status.$$.$RANDOM"
    # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
    cleanup_lsof_sample() {
        local cleanup_pid="${command_pid:-}"
        trap - HUP INT TERM EXIT
        command_pid=""
        if [[ -n "$cleanup_pid" ]]; then
            /bin/kill -TERM -- "-$cleanup_pid" 2>/dev/null || true
            /bin/sleep 0.2
            /bin/kill -KILL -- "-$cleanup_pid" 2>/dev/null || true
            wait "$cleanup_pid" 2>/dev/null || true
        fi
        /bin/rm -f "$status_marker" 2>/dev/null || true
    }
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap cleanup_lsof_sample EXIT
    : > "$destination" || return 1
    : > "$error_destination" || return 1
    /bin/rm -f "$status_marker" 2>/dev/null || return 1
    exec 2>/dev/null
    set -m
    (
        ulimit -f "$output_limit_blocks" || exit 1
        "$LSOF_BIN" "$@"
        provider_status=$?
        /usr/bin/printf '%s' "$provider_status" > "$status_marker" 2>/dev/null || true
        exit "$provider_status"
    ) > "$destination" 2> "$error_destination" &
    command_pid=$!
    while [[ ! -f "$status_marker" ]]; do
        if [[ "$ticks" -ge "$LSOF_TIMEOUT_TICKS" ]]; then
            /bin/kill -TERM -- "-$command_pid" 2>/dev/null || true
            /bin/sleep 0.2
            /bin/kill -KILL -- "-$command_pid" 2>/dev/null || true
            wait "$command_pid" 2>/dev/null || true
            command_pid=""
            /bin/rm -f "$status_marker" 2>/dev/null || true
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
    /bin/rm -f "$status_marker" 2>/dev/null || true
    output_size="$(/usr/bin/wc -c < "$destination" 2>/dev/null | /usr/bin/tr -d ' ')"
    case "$output_size" in ''|*[!0-9]*) output_size=0 ;; esac
    [[ "$output_size" -lt "$output_limit_bytes" ]] || return 65
    return "$command_status"
)

sample_status_label() {
    local status="$1"
    local error_file="$2"
    if [[ "$status" -eq 0 || ( "$status" -eq 1 && ! -s "$error_file" ) ]]; then
        /usr/bin/printf 'ok'
    elif [[ "$status" -eq 124 ]]; then
        /usr/bin/printf 'timed_out'
    elif [[ "$status" -eq 65 ]]; then
        /usr/bin/printf 'output_limited'
    else
        /usr/bin/printf 'failed'
    fi
}

# 테스트는 네 표본 파일을 직접 주입한다. 실제 lsof 표는 재현할 수 없으므로,
# 델타 계산을 고정된 입력으로 검증한다.
inject_or_empty() {
    local var_name="$1"
    local destination="$2"
    local status_var_name="$3"
    local source="${!var_name:-}"
    local injected_status="${!status_var_name:-0}"
    if [[ -n "$source" && -f "$source" && ! -L "$source" ]]; then
        /bin/cat "$source" > "$destination"
    else
        : > "$destination"
    fi
    case "$injected_status" in ''|*[!0-9]*) return 64 ;; esac
    return "$injected_status"
}

first_established_status=0
first_listen_status=0
second_established_status=0
second_listen_status=0
for sample_error in first_established first_listen second_established second_listen; do
    : > "$WORKSPACE/${sample_error}.err"
done

if [[ "${PCH_TEST_MODE:-0}" == "1" \
    && -n "${PCH_NETWORK_WATCH_FIRST_ESTABLISHED:-}${PCH_NETWORK_WATCH_FIRST_LISTEN:-}${PCH_NETWORK_WATCH_SECOND_ESTABLISHED:-}${PCH_NETWORK_WATCH_SECOND_LISTEN:-}" ]]; then
    inject_or_empty PCH_NETWORK_WATCH_FIRST_ESTABLISHED "$WORKSPACE/first_established" PCH_NETWORK_WATCH_FIRST_ESTABLISHED_STATUS \
        || first_established_status=$?
    inject_or_empty PCH_NETWORK_WATCH_FIRST_LISTEN "$WORKSPACE/first_listen" PCH_NETWORK_WATCH_FIRST_LISTEN_STATUS \
        || first_listen_status=$?
    inject_or_empty PCH_NETWORK_WATCH_SECOND_ESTABLISHED "$WORKSPACE/second_established" PCH_NETWORK_WATCH_SECOND_ESTABLISHED_STATUS \
        || second_established_status=$?
    inject_or_empty PCH_NETWORK_WATCH_SECOND_LISTEN "$WORKSPACE/second_listen" PCH_NETWORK_WATCH_SECOND_LISTEN_STATUS \
        || second_listen_status=$?
else
    capture_lsof_sample "$WORKSPACE/first_established" "$WORKSPACE/first_established.err" \
        -nP -iTCP -sTCP:ESTABLISHED || first_established_status=$?
    capture_lsof_sample "$WORKSPACE/first_listen" "$WORKSPACE/first_listen.err" \
        -nP -iTCP -sTCP:LISTEN || first_listen_status=$?
    /bin/sleep "$WINDOW_SECONDS"
    capture_lsof_sample "$WORKSPACE/second_established" "$WORKSPACE/second_established.err" \
        -nP -iTCP -sTCP:ESTABLISHED || second_established_status=$?
    capture_lsof_sample "$WORKSPACE/second_listen" "$WORKSPACE/second_listen.err" \
        -nP -iTCP -sTCP:LISTEN || second_listen_status=$?
fi

first_established_label="$(sample_status_label "$first_established_status" "$WORKSPACE/first_established.err")"
first_listen_label="$(sample_status_label "$first_listen_status" "$WORKSPACE/first_listen.err")"
second_established_label="$(sample_status_label "$second_established_status" "$WORKSPACE/second_established.err")"
second_listen_label="$(sample_status_label "$second_listen_status" "$WORKSPACE/second_listen.err")"

emit "version" "$PROTOCOL_VERSION"
emit "operation" "network-watch"
emit "windowSeconds" "$WINDOW_SECONDS"
emit "firstEstablishedStatus" "$first_established_label"
emit "firstListenStatus" "$first_listen_label"
emit "secondEstablishedStatus" "$second_established_label"
emit "secondListenStatus" "$second_listen_label"

if [[ "$first_established_label" != "ok" || "$first_listen_label" != "ok" \
    || "$second_established_label" != "ok" || "$second_listen_label" != "ok" ]]; then
    emit "error" "네트워크 표본 일부를 읽지 못해 변화량을 계산하지 않았습니다."
    exit 0
fi

# lsof 열: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME (ESTABLISHED 행은
# NAME 뒤에 "(ESTABLISHED)"가 하나 더 붙어 총 10 필드). NAME(9번째 필드)이
# established는 "LOCAL->REMOTE", listen은 "ADDR:PORT" 형태다.
# 파일 구분에 FNR==NR을 쓰지 않는다: 첫 표본 파일이 비어 있으면(첫 lsof가
# 실패해 `|| true`가 삼킨 경우) FNR==NR이 두 번째 파일에 참이 되어, 구간 중
# 생긴 새 연결 전부가 "기존 연결"로 등록되고 보고가 조용히 사라진다. 파일
# 인자 사이의 변수 대입(POSIX)은 파일이 비어도 순서대로 적용된다.
new_established() {
    /usr/bin/awk '
    function hex_digit(c) {
        return index("0123456789abcdef", tolower(c)) - 1
    }
    # lsof escapes every byte it considers unprintable, not just the space
    # that motivated this: a tab arrives as \\x09 and a non-ASCII name as a
    # run of \\xNN bytes. Decoding only \\x20 left those literal in the
    # reported name. Bytes are emitted verbatim, so a multi-byte UTF-8 name
    # reassembles correctly; control bytes become a space because they would
    # otherwise break the TSV this protocol is carried on.
    function command_name(value,   out, rest, code) {
        out = ""
        rest = value
        while (match(rest, /\\x[0-9A-Fa-f][0-9A-Fa-f]/)) {
            out = out substr(rest, 1, RSTART - 1)
            code = hex_digit(substr(rest, RSTART + 2, 1)) * 16 \
                + hex_digit(substr(rest, RSTART + 3, 1))
            out = out ((code < 32 || code == 127) ? " " : sprintf("%c", code))
            rest = substr(rest, RSTART + 4)
        }
        out = out rest
        sub(/ +$/, "", out)
        return out
    }
    FNR == 1 { next }
    building == 1 {
        n = split($0, parts, /[ \t]+/)
        if (n < 9) next
        addr = parts[9]
        arrow = index(addr, "->")
        if (arrow == 0) next
        seen[command_name(parts[1]) "\t" substr(addr, arrow + 2)] = 1
        next
    }
    {
        n = split($0, parts, /[ \t]+/)
        if (n < 9) next
        addr = parts[9]
        arrow = index(addr, "->")
        if (arrow == 0) next
        remote = substr(addr, arrow + 2)
        process = command_name(parts[1])
        matchkey = process "\t" remote
        if (matchkey in seen) next
        printf "established\t%s\t%s\t%s\n", process, parts[2], remote
    }
    ' building=1 "$1" building=0 "$2"
}

new_listen() {
    /usr/bin/awk '
    function hex_digit(c) {
        return index("0123456789abcdef", tolower(c)) - 1
    }
    # lsof escapes every byte it considers unprintable, not just the space
    # that motivated this: a tab arrives as \\x09 and a non-ASCII name as a
    # run of \\xNN bytes. Decoding only \\x20 left those literal in the
    # reported name. Bytes are emitted verbatim, so a multi-byte UTF-8 name
    # reassembles correctly; control bytes become a space because they would
    # otherwise break the TSV this protocol is carried on.
    function command_name(value,   out, rest, code) {
        out = ""
        rest = value
        while (match(rest, /\\x[0-9A-Fa-f][0-9A-Fa-f]/)) {
            out = out substr(rest, 1, RSTART - 1)
            code = hex_digit(substr(rest, RSTART + 2, 1)) * 16 \
                + hex_digit(substr(rest, RSTART + 3, 1))
            out = out ((code < 32 || code == 127) ? " " : sprintf("%c", code))
            rest = substr(rest, RSTART + 4)
        }
        out = out rest
        sub(/ +$/, "", out)
        return out
    }
    FNR == 1 { next }
    building == 1 {
        n = split($0, parts, /[ \t]+/)
        if (n < 9) next
        seen[command_name(parts[1]) "\t" parts[9]] = 1
        next
    }
    {
        n = split($0, parts, /[ \t]+/)
        if (n < 9) next
        process = command_name(parts[1])
        matchkey = process "\t" parts[9]
        if (matchkey in seen) next
        printf "listen\t%s\t%s\t%s\n", process, parts[2], parts[9]
    }
    ' building=1 "$1" building=0 "$2"
}

NEW_ESTABLISHED_FILE="$WORKSPACE/new_established.tsv"
NEW_LISTEN_FILE="$WORKSPACE/new_listen.tsv"
new_established "$WORKSPACE/first_established" "$WORKSPACE/second_established" > "$NEW_ESTABLISHED_FILE"
new_listen "$WORKSPACE/first_listen" "$WORKSPACE/second_listen" > "$NEW_LISTEN_FILE"

/bin/cat "$NEW_ESTABLISHED_FILE" "$NEW_LISTEN_FILE"

emit "newEstablished" "$(/usr/bin/wc -l < "$NEW_ESTABLISHED_FILE" | /usr/bin/tr -d ' ')"
emit "newListen" "$(/usr/bin/wc -l < "$NEW_LISTEN_FILE" | /usr/bin/tr -d ' ')"
