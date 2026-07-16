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

collect_network() {
    local error_file="$TMP_DIR/net.err"
    local status error_text collection_status row_count
    : > "$TMP_DIR/net.txt"
    : > "$error_file"

    if [[ ! -x /usr/sbin/lsof ]]; then
        record_collection_status "network_connections" "외부 네트워크 연결" "unavailable" "true" "lsof를 사용할 수 없습니다."
        return 0
    fi

    /usr/sbin/lsof -nP -iTCP -sTCP:ESTABLISHED \
        > "$TMP_DIR/net.txt" 2> "$error_file"
    status=$?
    error_text="$(/bin/cat "$error_file" 2>/dev/null || true)"
    if [[ "$status" -eq 0 || ( "$status" -eq 1 && ! -s "$error_file" ) ]]; then
        row_count="$(/usr/bin/awk 'NR > 1 { count += 1 } END { print count + 0 }' "$TMP_DIR/net.txt")"
        record_collection_status "network_connections" "외부 네트워크 연결" "ok" "true" "${row_count}개 연결을 확인했습니다."
    else
        collection_status="$(collection_failure_status "$status" "$error_text")"
        : > "$TMP_DIR/net.txt"
        record_collection_status "network_connections" "외부 네트워크 연결" "$collection_status" "true" "네트워크 연결을 읽지 못했습니다."
    fi
    /bin/rm -f "$error_file"
}

collect_listening_ports() {
    local error_file="$TMP_DIR/listen.err"
    local status error_text collection_status row_count
    : > "$TMP_DIR/listen.txt"
    : > "$error_file"

    if [[ ! -x /usr/sbin/lsof ]]; then
        record_collection_status "listening_ports" "열린 포트" "unavailable" "true" "lsof를 사용할 수 없습니다."
        return 0
    fi

    /usr/sbin/lsof -nP -iTCP -sTCP:LISTEN \
        > "$TMP_DIR/listen.txt" 2> "$error_file"
    status=$?
    error_text="$(/bin/cat "$error_file" 2>/dev/null || true)"
    if [[ "$status" -eq 0 || ( "$status" -eq 1 && ! -s "$error_file" ) ]]; then
        row_count="$(/usr/bin/awk 'NR > 1 { count += 1 } END { print count + 0 }' "$TMP_DIR/listen.txt")"
        record_collection_status "listening_ports" "열린 포트" "ok" "true" "${row_count}개 포트를 확인했습니다."
    else
        collection_status="$(collection_failure_status "$status" "$error_text")"
        : > "$TMP_DIR/listen.txt"
        record_collection_status "listening_ports" "열린 포트" "$collection_status" "true" "열린 포트를 읽지 못했습니다."
    fi
    /bin/rm -f "$error_file"
}
