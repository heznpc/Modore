#!/bin/bash
# scanner 모듈 (macOS): 자동 실행 (launchd LaunchAgents/Daemons + Login Items)
# 출력: $TMP_DIR/launchctl.txt, $TMP_DIR/plists.txt, $TMP_DIR/loginitems.txt, $TMP_DIR/btm.txt
# 의존: launchctl, find, osascript, sfltool (macOS 13+)

if ! declare -F record_collection_status >/dev/null 2>&1; then
    record_collection_status() { :; }
fi
if ! declare -F collection_failure_status >/dev/null 2>&1; then
    collection_failure_status() { /usr/bin/printf 'failed'; }
fi

run_to_file_with_timeout() (
    local seconds="$1"
    local output="$2"
    local error_output="${output}.err"
    local output_limit_kb="${PCH_AUTORUN_COMMAND_OUTPUT_LIMIT_KB:-512}"
    local output_limit_blocks output_limit_bytes output_size
    local command_status=0
    local status_marker="${output}.status.$$.$RANDOM"
    local cmd_pid=""
    # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
    cleanup_autorun_tool() {
        local cleanup_pid="${cmd_pid:-}"
        trap - HUP INT TERM EXIT
        cmd_pid=""
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
    trap cleanup_autorun_tool EXIT
    shift 2

    case "$seconds" in ''|*[!0-9]*|0) return 124 ;; esac
    case "$output_limit_kb" in ''|*[!0-9]*|0) output_limit_kb=512 ;; esac
    [[ "$output_limit_kb" -le 2048 ]] || output_limit_kb=2048
    output_limit_blocks="$output_limit_kb"
    output_limit_bytes=$((output_limit_kb * 1024))

    : > "$error_output"
    : > "$output"
    /bin/rm -f "$status_marker" 2>/dev/null || return 1
    # Non-interactive Bash otherwise puts the child in this scanner's process
    # group. Job control gives the provider and every descendant a private
    # group that a deadline can stop without killing the scanner itself.
    exec 2>/dev/null
    set -m
    (
        ulimit -f "$output_limit_blocks" || exit 1
        "$@"
        provider_status=$?
        /usr/bin/printf '%s' "$provider_status" > "$status_marker" 2>/dev/null || true
        exit "$provider_status"
    ) > "$output" 2> "$error_output" &
    cmd_pid=$!
    local elapsed=0
    while [[ ! -f "$status_marker" ]]; do
        if [[ "$elapsed" -ge "$seconds" ]]; then
            /bin/kill -TERM -- "-$cmd_pid" 2>/dev/null || true
            /bin/sleep 0.2
            /bin/kill -KILL -- "-$cmd_pid" 2>/dev/null || true
            wait "$cmd_pid" 2>/dev/null || true
            cmd_pid=""
            /bin/rm -f "$status_marker" 2>/dev/null || true
            return 124
        fi
        /bin/sleep 1
        elapsed=$((elapsed + 1))
    done
    command_status="$(/bin/cat "$status_marker" 2>/dev/null || true)"
    case "$command_status" in ''|*[!0-9]*) command_status=1 ;; esac
    wait "$cmd_pid" 2>/dev/null || true
    if /bin/kill -0 -- "-$cmd_pid" 2>/dev/null; then
        /bin/kill -TERM -- "-$cmd_pid" 2>/dev/null || true
        /bin/sleep 0.2
        /bin/kill -KILL -- "-$cmd_pid" 2>/dev/null || true
    fi
    cmd_pid=""
    /bin/rm -f "$status_marker" 2>/dev/null || true
    output_size="$(/usr/bin/wc -c < "$output" 2>/dev/null | /usr/bin/tr -d ' ')"
    case "$output_size" in ''|*[!0-9]*) output_size=0 ;; esac
    [[ "$output_size" -lt "$output_limit_bytes" ]] || return 65
    return "$command_status"
)

collect_autoruns() {
    local error_file status error_text collection_status row_count
    local roots=()

    error_file="$TMP_DIR/launchctl.err"
    /bin/launchctl list > "$TMP_DIR/launchctl.txt" 2> "$error_file"
    status=$?
    if [[ "$status" -eq 0 ]]; then
        row_count="$(/usr/bin/awk 'NR > 1 { count += 1 } END { print count + 0 }' "$TMP_DIR/launchctl.txt")"
        record_collection_status "launchd_jobs" "실행 중인 launchd 작업" "ok" "true" "${row_count}개 작업을 확인했습니다."
    else
        error_text="$(/bin/cat "$error_file" 2>/dev/null || true)"
        collection_status="$(collection_failure_status "$status" "$error_text")"
        : > "$TMP_DIR/launchctl.txt"
        record_collection_status "launchd_jobs" "실행 중인 launchd 작업" "$collection_status" "true" "launchd 작업을 읽지 못했습니다."
    fi
    /bin/rm -f "$error_file"

    local launch_root
    for launch_root in \
        "$HOME/Library/LaunchAgents" \
        "/Library/LaunchAgents" \
        "/Library/LaunchDaemons" \
        "$HOME/Library/LaunchDaemons"; do
        [[ -d "$launch_root" ]] && roots+=("$launch_root")
    done
    : > "$TMP_DIR/plists.txt"
    error_file="$TMP_DIR/plists.err"
    if [[ "${#roots[@]}" -eq 0 ]]; then
        record_collection_status "autorun_files" "자동 실행 설정 파일" "ok" "true" "확인할 자동 실행 폴더가 없습니다."
    else
        /usr/bin/find "${roots[@]}" -maxdepth 1 -name "*.plist" -type f \
            > "$TMP_DIR/plists.txt" 2> "$error_file"
        status=$?
        if [[ "$status" -eq 0 ]]; then
            row_count="$(/usr/bin/wc -l < "$TMP_DIR/plists.txt" | /usr/bin/tr -d ' ')"
            record_collection_status "autorun_files" "자동 실행 설정 파일" "ok" "true" "${row_count}개 설정을 확인했습니다."
        else
            error_text="$(/bin/cat "$error_file" 2>/dev/null || true)"
            collection_status="$(collection_failure_status "$status" "$error_text")"
            record_collection_status "autorun_files" "자동 실행 설정 파일" "$collection_status" "true" "자동 실행 설정을 완전히 읽지 못했습니다."
        fi
    fi
    /bin/rm -f "$error_file"

    # 로그인 항목
    error_file="$TMP_DIR/loginitems.txt.err"
    run_to_file_with_timeout 8 "$TMP_DIR/loginitems.txt" \
        /usr/bin/osascript -e 'tell application "System Events" to get the name of every login item'
    status=$?
    if [[ "$status" -eq 0 ]]; then
        record_collection_status "login_items" "로그인 항목" "ok" "true" "로그인 항목을 확인했습니다."
    else
        error_text="$(/bin/cat "$error_file" 2>/dev/null || true)"
        collection_status="$(collection_failure_status "$status" "$error_text")"
        : > "$TMP_DIR/loginitems.txt"
        record_collection_status "login_items" "로그인 항목" "$collection_status" "true" "로그인 항목을 읽지 못했습니다."
    fi
    /bin/rm -f "$error_file"

    # On current macOS releases dumpbtm can open an administrator authentication
    # sheet. Keep the default scan non-interactive and make this optional source
    # explicit for terminal-only diagnostics.
    if [[ "${PCH_ENABLE_SFLTOOL:-0}" == "1" && -x /usr/bin/sfltool ]]; then
        error_file="$TMP_DIR/btm.txt.err"
        run_to_file_with_timeout 8 "$TMP_DIR/btm.txt" /usr/bin/sfltool dumpbtm
        status=$?
        if [[ "$status" -eq 0 ]]; then
            record_collection_status "background_items" "백그라운드 작업 관리" "ok" "false" "백그라운드 등록 항목을 확인했습니다."
        else
            error_text="$(/bin/cat "$error_file" 2>/dev/null || true)"
            collection_status="$(collection_failure_status "$status" "$error_text")"
            : > "$TMP_DIR/btm.txt"
            record_collection_status "background_items" "백그라운드 작업 관리" "$collection_status" "false" "백그라운드 등록 항목을 읽지 못했습니다."
        fi
        /bin/rm -f "$error_file"
    else
        : > "$TMP_DIR/btm.txt"
        record_collection_status "background_items" "백그라운드 작업 관리" "unavailable" "false" "관리자 인증 창을 피하기 위해 기본 검사에서 생략했습니다."
    fi
}
