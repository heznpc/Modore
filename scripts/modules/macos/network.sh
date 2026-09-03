#!/bin/bash
# scanner 모듈 (macOS): 네트워크 연결 + LISTEN 포트
# 출력: $TMP_DIR/net.txt, $TMP_DIR/listen.txt
# 의존: lsof

if ! declare -F record_collection_status >/dev/null 2>&1; then
    record_collection_status() { :; }
fi
if ! declare -F collection_failure_status >/dev/null 2>&1; then
    collection_failure_status() { /usr/bin/printf 'failed'; }
fi

_pch_network_tool_to_file() (
    local output_file="$1"
    local error_file="$2"
    shift 2
    local timeout_ticks="${PCH_NETWORK_COMMAND_TIMEOUT_TICKS:-30}"
    local output_limit_kb="${PCH_NETWORK_OUTPUT_LIMIT_KB:-256}"
    local output_limit_blocks output_limit_bytes output_size
    local command_pid="" ticks=0 command_status=0
    local status_marker="${output_file}.status.$$.$RANDOM"
    # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
    cleanup_network_tool() {
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
    trap cleanup_network_tool EXIT
    case "$timeout_ticks" in ''|*[!0-9]*|0) timeout_ticks=30 ;; esac
    case "$output_limit_kb" in ''|*[!0-9]*|0) output_limit_kb=256 ;; esac
    [[ "$timeout_ticks" -le 100 ]] || timeout_ticks=100
    [[ "$output_limit_kb" -le 1024 ]] || output_limit_kb=1024
    output_limit_blocks="$output_limit_kb"
    output_limit_bytes=$((output_limit_kb * 1024))
    : > "$output_file" || return 1
    : > "$error_file" || return 1
    /bin/rm -f "$status_marker" 2>/dev/null || return 1
    exec 2>/dev/null
    set -m
    (
        ulimit -f "$output_limit_blocks" || exit 1
        "$@"
        provider_status=$?
        /usr/bin/printf '%s' "$provider_status" > "$status_marker" 2>/dev/null || true
        exit "$provider_status"
    ) > "$output_file" 2> "$error_file" &
    command_pid=$!
    while [[ ! -f "$status_marker" ]]; do
        if [[ "$ticks" -ge "$timeout_ticks" ]]; then
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
    output_size="$(/usr/bin/wc -c < "$output_file" 2>/dev/null | /usr/bin/tr -d ' ')"
    case "$output_size" in ''|*[!0-9]*) output_size=0 ;; esac
    [[ "$output_size" -lt "$output_limit_bytes" ]] || return 65
    return "$command_status"
)

_pch_network_lsof_bin() {
    if [[ "${PCH_TEST_MODE:-0}" == "1" && -n "${PCH_TEST_NETWORK_LSOF_BIN:-}" ]]; then
        [[ -x "$PCH_TEST_NETWORK_LSOF_BIN" && ! -L "$PCH_TEST_NETWORK_LSOF_BIN" ]] \
            || return 1
        /usr/bin/printf '%s' "$PCH_TEST_NETWORK_LSOF_BIN"
    else
        /usr/bin/printf '/usr/sbin/lsof'
    fi
}

collect_network() {
    local error_file="$TMP_DIR/net.err"
    local status error_text collection_status row_count lsof_bin partial_note=""
    : > "$TMP_DIR/net.txt"
    : > "$error_file"

    lsof_bin="$(_pch_network_lsof_bin 2>/dev/null || true)"
    if [[ -z "$lsof_bin" || ! -x "$lsof_bin" ]]; then
        record_collection_status "network_connections" "외부 네트워크 연결" "unavailable" "true" "lsof를 사용할 수 없습니다."
        return 0
    fi

    _pch_network_tool_to_file "$TMP_DIR/net.txt" "$error_file" \
        "$lsof_bin" -nP -iTCP -sTCP:ESTABLISHED
    status=$?
    error_text="$(/bin/cat "$error_file" 2>/dev/null || true)"
    if [[ "$status" -eq 0 || ( "$status" -eq 1 && ! -s "$error_file" ) ]]; then
        row_count="$(/usr/bin/awk 'NR > 1 { count += 1 } END { print count + 0 }' "$TMP_DIR/net.txt")"
        record_collection_status "network_connections" "외부 네트워크 연결" "ok" "true" "${row_count}개 연결을 확인했습니다."
    else
        collection_status="$(collection_failure_status "$status" "$error_text")"
        [[ ! -s "$TMP_DIR/net.txt" ]] || partial_note=" 제한 전까지 읽은 일부 행은 진단 자료로 보존했습니다."
        record_collection_status "network_connections" "외부 네트워크 연결" "$collection_status" "true" "네트워크 연결을 완전히 읽지 못했습니다.${partial_note}"
    fi
    /bin/rm -f "$error_file"
}

collect_listening_ports() {
    local error_file="$TMP_DIR/listen.err"
    local status error_text collection_status row_count lsof_bin partial_note=""
    : > "$TMP_DIR/listen.txt"
    : > "$error_file"

    lsof_bin="$(_pch_network_lsof_bin 2>/dev/null || true)"
    if [[ -z "$lsof_bin" || ! -x "$lsof_bin" ]]; then
        record_collection_status "listening_ports" "열린 포트" "unavailable" "true" "lsof를 사용할 수 없습니다."
        return 0
    fi

    _pch_network_tool_to_file "$TMP_DIR/listen.txt" "$error_file" \
        "$lsof_bin" -nP -iTCP -sTCP:LISTEN
    status=$?
    error_text="$(/bin/cat "$error_file" 2>/dev/null || true)"
    if [[ "$status" -eq 0 || ( "$status" -eq 1 && ! -s "$error_file" ) ]]; then
        row_count="$(/usr/bin/awk 'NR > 1 { count += 1 } END { print count + 0 }' "$TMP_DIR/listen.txt")"
        record_collection_status "listening_ports" "열린 포트" "ok" "true" "${row_count}개 포트를 확인했습니다."
    else
        collection_status="$(collection_failure_status "$status" "$error_text")"
        [[ ! -s "$TMP_DIR/listen.txt" ]] || partial_note=" 제한 전까지 읽은 일부 행은 진단 자료로 보존했습니다."
        record_collection_status "listening_ports" "열린 포트" "$collection_status" "true" "열린 포트를 완전히 읽지 못했습니다.${partial_note}"
    fi
    /bin/rm -f "$error_file"
}
