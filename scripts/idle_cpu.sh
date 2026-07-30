#!/bin/bash -p
# Modore - 유휴 CPU 관측기 (macOS). Windows의 scripts/monitor.ps1에 대응한다.
#
# 왜 별도 수집이 필요한가: 기본 스캔의 cpu 모듈은 `ps -r`의 %cpu를 쓴다. 그 값은
# 프로세스가 살아온 동안의 감쇠 평균이라, 오래 떠 있던 프로세스가 지금 조용해도
# 높게 보이고 방금 폭주한 프로세스는 낮게 보인다. "가만히 있는데 무엇이 CPU를
# 쓰는가"에 답하려면 두 시점의 누적 CPU 시간 차이를 재야 한다.
#
# 왜 부모를 함께 보는가: 앱 이름만으로는 책임 소재를 알 수 없다. 터미널에서 띄운
# 스크립트가 어떤 앱의 파일을 읽고 있으면 Activity Monitor에는 인터프리터 이름만
# 남아, 무관한 앱이 범인으로 읽힌다. 그래서 조상 사슬을 따라가 책임 프로세스를
# 함께 보고하고, 로그인 셸에서 시작된 것은 따로 표시한다.
#
# 읽기 전용이다. 파일 내용을 읽지 않고, 아무것도 종료하거나 삭제하지 않는다.

set -u
set -o pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

PROTOCOL_VERSION="1"
WINDOW_SECONDS="${PCH_IDLE_CPU_WINDOW:-5}"
MAX_ROWS="${PCH_IDLE_CPU_MAX_ROWS:-12}"
MIN_PERCENT="${PCH_IDLE_CPU_MIN_PERCENT:-1}"

usage() {
    /usr/bin/printf '%s\n' \
        'Usage:' \
        '  idle_cpu.sh [--window <seconds>] [--max-rows <n>] [--min-percent <n>]' \
        '' \
        '두 시점의 누적 CPU 시간 차이로 관측 구간 동안의 실제 점유율을 계산한다.'
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --window) WINDOW_SECONDS="${2:-}"; shift ;;
        --max-rows) MAX_ROWS="${2:-}"; shift ;;
        --min-percent) MIN_PERCENT="${2:-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) /usr/bin/printf 'ERROR: unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done

# 관측 구간을 제한한다. 진단 한 번이 무한정 길어지면 사용자가 기다리다 만다.
[[ "$WINDOW_SECONDS" =~ ^[1-9][0-9]{0,2}$ && "$WINDOW_SECONDS" -le 300 ]] \
    || { /usr/bin/printf 'ERROR: --window must be 1-300 seconds.\n' >&2; exit 64; }
[[ "$MAX_ROWS" =~ ^[1-9][0-9]{0,2}$ ]] \
    || { /usr/bin/printf 'ERROR: --max-rows must be a positive integer.\n' >&2; exit 64; }
[[ "$MIN_PERCENT" =~ ^[0-9]{1,3}$ ]] \
    || { /usr/bin/printf 'ERROR: --min-percent must be 0-999.\n' >&2; exit 64; }

if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
    /usr/bin/printf 'ERROR: 이 관측기는 macOS 전용입니다.\n' >&2
    exit 1
fi

emit() {
    local key="$1"
    local value="${2:-}"
    case "$key$value" in
        *$'\t'*|*$'\n'*|*$'\r'*) value="출력할 수 없는 제어 문자가 포함되었습니다." ;;
    esac
    /usr/bin/printf '%s\t%s\n' "$key" "$value"
}

WORKSPACE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/modore-idle-cpu.XXXXXX")" || exit 1
cleanup() { /bin/rm -rf "$WORKSPACE"; }
trap cleanup EXIT

# comm= 은 실행 파일 경로만 준다. command= 는 인자까지 실어 토큰이나 경로가
# 그대로 노출될 수 있으므로 쓰지 않는다.
sample() {
    /bin/ps -Ao pid=,ppid=,time=,comm= 2>/dev/null || true
}

# 테스트는 두 시점을 직접 주입한다. 실제 프로세스 표는 재현할 수 없으므로,
# 델타 계산과 조상 귀속을 고정된 입력으로 검증한다.
copy_injected_sample() {
    local source="$1"
    local destination="$2"
    [[ -f "$source" && ! -L "$source" ]] || return 1
    /bin/cat "$source" > "$destination"
}

if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
    copy_injected_sample "${PCH_IDLE_CPU_FIRST_SAMPLE:-}" "$WORKSPACE/first" || {
        /usr/bin/printf 'ERROR: 테스트 모드에는 첫 표본 파일이 필요합니다.\n' >&2
        exit 64
    }
    copy_injected_sample "${PCH_IDLE_CPU_SECOND_SAMPLE:-}" "$WORKSPACE/second" || {
        /usr/bin/printf 'ERROR: 테스트 모드에는 두 번째 표본 파일이 필요합니다.\n' >&2
        exit 64
    }
else
    sample > "$WORKSPACE/first"
    /bin/sleep "$WINDOW_SECONDS"
    sample > "$WORKSPACE/second"
fi

emit "version" "$PROTOCOL_VERSION"
emit "operation" "idle-cpu"
emit "windowSeconds" "$WINDOW_SECONDS"
emit "minPercent" "$MIN_PERCENT"

/usr/bin/awk \
    -v window="$WINDOW_SECONDS" \
    -v max_rows="$MAX_ROWS" \
    -v min_percent="$MIN_PERCENT" \
    -v self_pid="$$" '
function to_seconds(value,    days, rest, marker, count, parts, total, i) {
    days = 0
    rest = value
    marker = index(rest, "-")
    if (marker > 0) {
        days = substr(rest, 1, marker - 1) + 0
        rest = substr(rest, marker + 1)
    }
    count = split(rest, parts, ":")
    total = 0
    for (i = 1; i <= count; i++) {
        total = total * 60 + (parts[i] + 0)
    }
    return days * 86400 + total
}
function basename(path,    count, parts) {
    count = split(path, parts, "/")
    return parts[count]
}
# 책임 프로세스: launchd 바로 아래까지 조상을 따라 올라간 최상위 조상.
# 사슬이 끊겼거나 순환하면 자기 자신을 책임자로 둔다.
function responsible(pid,    current, parent, guard) {
    current = pid
    guard = 0
    while (guard++ < 64) {
        parent = ppid[current]
        if (parent == "" || parent <= 1 || parent == current) break
        current = parent
    }
    return current
}
FNR == NR {
    first[$1] = to_seconds($3)
    next
}
{
    pid = $1
    ppid[pid] = $2 + 0
    name[pid] = basename($4)
    second[pid] = to_seconds($3)
}
END {
    for (pid in second) {
        if (pid == self_pid) continue
        if (!(pid in first)) continue
        delta = second[pid] - first[pid]
        if (delta <= 0) continue
        percent = delta * 100 / window
        if (percent < min_percent) continue
        rows[++count] = sprintf("%.1f\t%s\t%s", percent, pid, name[pid])
        percents[count] = percent
    }
    # 점유율 내림차순. 행 수가 max_rows로 제한되어 단순 선택 정렬로 충분하다.
    for (i = 1; i <= count; i++) {
        best = i
        for (j = i + 1; j <= count; j++) {
            if (percents[j] > percents[best]) best = j
        }
        if (best != i) {
            tmp = rows[i]; rows[i] = rows[best]; rows[best] = tmp
            tmpv = percents[i]; percents[i] = percents[best]; percents[best] = tmpv
        }
    }
    shown = 0
    for (i = 1; i <= count && shown < max_rows; i++) {
        split(rows[i], field, "\t")
        pid = field[2]
        owner = responsible(pid)
        owner_name = (owner in name) ? name[owner] : "unknown"
        started_from_shell = "false"
        if (owner_name == "zsh" || owner_name == "bash" || owner_name == "sh" \
            || owner_name == "login" || owner_name == "fish" || owner_name == "tcsh") {
            started_from_shell = "true"
        }
        printf "process\t%s\t%s\t%s\t%s\t%s\t%s\n", \
            field[1], pid, field[3], owner, owner_name, started_from_shell
        shown++
    }
    printf "observed\t%d\n", count
    printf "reported\t%d\n", shown
}
' "$WORKSPACE/first" "$WORKSPACE/second"
