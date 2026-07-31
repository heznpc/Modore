#!/bin/bash
# scanner 모듈 (macOS): 관측 구간 동안 실제로 CPU를 쓴 프로세스
# 출력: $TMP_DIR/idle_cpu.tsv
# 의존: scripts/idle_cpu.sh
#
# cpu.sh는 `ps`의 %cpu를 쓴다. 그 값은 프로세스 생애 전체의 감쇠 평균이라
# "지금 무엇이 CPU를 쓰는가"에 답하지 못한다. 이 모듈은 두 시점의 누적 CPU
# 시간 차이를 재는 관측기를 불러, 구간 점유율과 책임 조상을 함께 남긴다.
#
# 관측기 로직을 여기 복사하지 않고 scripts/idle_cpu.sh를 그대로 호출한다.
# 같은 측정이 두 곳에 있으면 한쪽만 고쳐질 때 결과가 갈라진다.

if ! declare -F record_collection_status >/dev/null 2>&1; then
    record_collection_status() { :; }
fi
if ! declare -F collection_failure_status >/dev/null 2>&1; then
    collection_failure_status() { /usr/bin/printf 'failed'; }
fi

collect_background_cpu() {
    local observer="${PCH_PINNED_IDLE_CPU_SCRIPT:-}"
    local window="${PCH_SCAN_IDLE_CPU_WINDOW:-3}"
    local error_file="$TMP_DIR/idle_cpu.err"
    local status error_text collection_status row_count
    : > "$TMP_DIR/idle_cpu.tsv"

    # 이 신호는 required=false다. 필수로 올리면 관측 실패 하나가 전체 검사를
    # "안전 판단 보류"로 뒤집는데, 그건 이 항목의 무게에 맞지 않는다.
    if [[ "$window" == "0" ]]; then
        record_collection_status "background_cpu" "유휴 CPU 관측" "unavailable" "false" \
            "관측 구간이 0으로 설정되어 건너뛰었습니다."
        return 0
    fi
    if [[ -z "$observer" || ! -f "$observer" || -L "$observer" ]]; then
        record_collection_status "background_cpu" "유휴 CPU 관측" "unavailable" "false" \
            "유휴 CPU 관측기를 찾지 못했습니다."
        return 0
    fi

    /bin/bash -p "$observer" --window "$window" \
        > "$TMP_DIR/idle_cpu.tsv" 2> "$error_file"
    status=$?
    if [[ "$status" -eq 0 ]]; then
        row_count="$(/usr/bin/grep -c '^process' "$TMP_DIR/idle_cpu.tsv" 2>/dev/null || true)"
        [[ -n "$row_count" ]] || row_count=0
        record_collection_status "background_cpu" "유휴 CPU 관측" "ok" "false" \
            "${window}초 동안 CPU를 쓴 프로세스 ${row_count}개를 확인했습니다."
    else
        : > "$TMP_DIR/idle_cpu.tsv"
        error_text="$(/bin/cat "$error_file" 2>/dev/null || true)"
        collection_status="$(collection_failure_status "$status" "$error_text")"
        record_collection_status "background_cpu" "유휴 CPU 관측" "$collection_status" "false" \
            "유휴 CPU를 관측하지 못했습니다."
    fi
    /bin/rm -f "$error_file"
}
