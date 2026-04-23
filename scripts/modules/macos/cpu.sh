#!/bin/bash
# scanner 모듈 (macOS): CPU 상위 프로세스
# 출력: $TMP_DIR/ps.txt
# 의존: ps, top, sysctl, vm_stat, bc

collect_cpu() {
    ps -Ao pid=,user=,pcpu=,pmem=,rss=,comm= -r | head -25 > "$TMP_DIR/ps.txt"
}

collect_system_load() {
    local CPU_USED
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
    {
        echo "CPU_PCT=$CPU_USED"
        echo "MEM_PCT=$MEM_PCT"
        echo "MEM_TOTAL_GB=$MEM_TOTAL_GB"
    } > "$TMP_DIR/load.txt"
}
