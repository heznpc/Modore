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
if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
    LSOF_BIN="${PCH_TEST_LSOF_BIN:-$LSOF_BIN}"
fi

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

sample_established() {
    "$LSOF_BIN" -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null || true
}

sample_listen() {
    "$LSOF_BIN" -nP -iTCP -sTCP:LISTEN 2>/dev/null || true
}

# lsof exits non-zero with no output both when it fails and when nothing
# matches, and `|| true` cannot tell those apart -- so an empty closing
# sample is indistinguishable from "the window was quiet". Reporting 0 new
# connections off a sample we may never have taken is a false all-clear on a
# security surface, so the closing LISTEN set is used as the liveness probe:
# a real Mac always has listening sockets (launchd/rapportd/mDNSResponder),
# making an empty closing list overwhelmingly a failed read rather than a
# genuine state. The opening sample needs no such probe -- an empty opening
# baseline just makes everything look new, which errs toward over-reporting.
closing_sample_looks_unreadable() {
    [[ ! -s "$WORKSPACE/second_listen" ]]
}

# 테스트는 네 표본 파일을 직접 주입한다. 실제 lsof 표는 재현할 수 없으므로,
# 델타 계산을 고정된 입력으로 검증한다.
inject_or_empty() {
    local var_name="$1"
    local destination="$2"
    local source="${!var_name:-}"
    if [[ -n "$source" && -f "$source" && ! -L "$source" ]]; then
        /bin/cat "$source" > "$destination"
    else
        : > "$destination"
    fi
}

if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
    inject_or_empty PCH_NETWORK_WATCH_FIRST_ESTABLISHED "$WORKSPACE/first_established"
    inject_or_empty PCH_NETWORK_WATCH_FIRST_LISTEN "$WORKSPACE/first_listen"
    inject_or_empty PCH_NETWORK_WATCH_SECOND_ESTABLISHED "$WORKSPACE/second_established"
    inject_or_empty PCH_NETWORK_WATCH_SECOND_LISTEN "$WORKSPACE/second_listen"
else
    sample_established > "$WORKSPACE/first_established"
    sample_listen > "$WORKSPACE/first_listen"
    /bin/sleep "$WINDOW_SECONDS"
    sample_established > "$WORKSPACE/second_established"
    sample_listen > "$WORKSPACE/second_listen"
fi

emit "version" "$PROTOCOL_VERSION"
emit "operation" "network-watch"
emit "windowSeconds" "$WINDOW_SECONDS"

if closing_sample_looks_unreadable; then
    emit "error" "관찰 종료 시점의 네트워크 목록을 읽지 못했습니다."
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
