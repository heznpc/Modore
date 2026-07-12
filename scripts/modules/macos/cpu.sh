#!/bin/bash
# scanner 모듈 (macOS): CPU 상위 프로세스
# 출력: $TMP_DIR/ps.txt
# 의존: ps, top, sysctl, vm_stat, bc

if ! declare -F record_collection_status >/dev/null 2>&1; then
    record_collection_status() { :; }
fi
if ! declare -F collection_failure_status >/dev/null 2>&1; then
    collection_failure_status() { /usr/bin/printf 'failed'; }
fi

collect_cpu() {
    local source_file="$TMP_DIR/ps.all"
    local error_file="$TMP_DIR/ps.err"
    local status error_text collection_status row_count
    : > "$TMP_DIR/ps.txt"

    /bin/ps -Ao pid=,user=,pcpu=,pmem=,rss=,comm= -r \
        > "$source_file" 2> "$error_file"
    status=$?
    if [[ "$status" -eq 0 ]]; then
        /usr/bin/head -25 "$source_file" > "$TMP_DIR/ps.txt"
        row_count="$(/usr/bin/wc -l < "$TMP_DIR/ps.txt" | /usr/bin/tr -d ' ')"
        record_collection_status "cpu_processes" "실행 프로세스" "ok" "true" "상위 ${row_count}개 프로세스를 확인했습니다."
    else
        error_text="$(/bin/cat "$error_file" 2>/dev/null || true)"
        collection_status="$(collection_failure_status "$status" "$error_text")"
        record_collection_status "cpu_processes" "실행 프로세스" "$collection_status" "true" "프로세스 목록을 읽지 못했습니다."
    fi
    /bin/rm -f "$source_file" "$error_file"
}

collect_system_load() {
    local CPU_USED status="ok" detail="CPU와 메모리 부하를 확인했습니다."
    CPU_USED=$(top -l 1 -n 0 -s 0 | awk '/CPU usage/ {
        gsub(/%/, "");
        for (i=1; i<=NF; i++) {
            if ($i == "idle") { print 100 - $(i-1); exit }
        }
    }')
    local MEM_TOTAL_BYTES
    MEM_TOTAL_BYTES=$(sysctl -n hw.memsize)
    local MEM_TOTAL_GB
    MEM_TOTAL_GB=$(echo "scale=1; $MEM_TOTAL_BYTES / 1073741824" | bc)
    local PAGE_SIZE
    PAGE_SIZE=$(sysctl -n vm.pagesize)
    local VM_STATS
    VM_STATS=$(vm_stat)
    local PAGES_ACTIVE PAGES_WIRED TOTAL_PAGES PAGES_USED MEM_PCT
    PAGES_ACTIVE=$(echo "$VM_STATS" | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
    PAGES_WIRED=$(echo "$VM_STATS" | awk '/Pages wired down/ {gsub(/\./,"",$4); print $4}')
    if [[ -n "$PAGES_ACTIVE" && -n "$PAGES_WIRED" ]]; then
        PAGES_USED=$((PAGES_ACTIVE + PAGES_WIRED))
        TOTAL_PAGES=$((MEM_TOTAL_BYTES / PAGE_SIZE))
        MEM_PCT=$(echo "scale=1; $PAGES_USED * 100 / $TOTAL_PAGES" | bc)
    else
        MEM_PCT="0"
    fi
    if [[ -z "$CPU_USED" || -z "$MEM_TOTAL_GB" || -z "$MEM_PCT" ]]; then
        status="failed"
        detail="CPU 또는 메모리 부하를 완전히 읽지 못했습니다."
    fi
    {
        echo "CPU_PCT=$CPU_USED"
        echo "MEM_PCT=$MEM_PCT"
        echo "MEM_TOTAL_GB=$MEM_TOTAL_GB"
    } > "$TMP_DIR/load.txt"
    record_collection_status "system_load" "시스템 부하" "$status" "false" "$detail"
}
