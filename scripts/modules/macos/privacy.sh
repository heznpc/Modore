#!/bin/bash
# scanner 모듈 (macOS): 카메라·마이크 접근 권한 인벤토리 (TCC.db)
# 출력: $TMP_DIR/privacy.tsv
# 의존: sqlite3, TCC.db 읽기 권한(전체 디스크 접근 권한)
#
# TCC.db는 전체 디스크 접근 권한이 없으면 존재 자체가 파일 없음(ENOENT)으로
# 위장된다 -- macOS의 의도된 개인정보 보호 동작이며, 이를 오류로 취급하지
# 않고 unavailable로 명확히 구분해 보고한다. 이 신호는 "권한을 가진 앱
# 목록"일 뿐 실시간 사용 여부가 아니며, 이 인벤토리 자체는 danger/warning을
# 매기지 않는다 -- 대부분의 grant는 정상이다(Zoom, FaceTime, 브라우저 등).

if ! declare -F record_collection_status >/dev/null 2>&1; then
    record_collection_status() { :; }
fi

collect_privacy_permissions() {
    local tcc_db="${PCH_TCC_DB_PATH:-$HOME/Library/Application Support/com.apple.TCC/TCC.db}"
    local out_file="$TMP_DIR/privacy.tsv"
    local error_file="$TMP_DIR/privacy.err"
    local status row_count
    : > "$out_file"

    if [[ ! -r "$tcc_db" ]]; then
        record_collection_status "privacy_permissions" "카메라·마이크 권한" "unavailable" "false" \
            "전체 디스크 접근 권한이 없어 카메라·마이크 권한 기록을 읽지 못했습니다."
        return 0
    fi
    if [[ ! -x /usr/bin/sqlite3 ]]; then
        record_collection_status "privacy_permissions" "카메라·마이크 권한" "unavailable" "false" \
            "sqlite3를 사용할 수 없습니다."
        return 0
    fi

    /usr/bin/sqlite3 -readonly -separator $'\t' "$tcc_db" \
        "SELECT service, client FROM access WHERE service IN ('kTCCServiceCamera','kTCCServiceMicrophone') AND auth_value = 2;" \
        > "$out_file" 2> "$error_file"
    status=$?
    if [[ "$status" -eq 0 ]]; then
        row_count="$(/usr/bin/wc -l < "$out_file" | /usr/bin/tr -d ' ')"
        record_collection_status "privacy_permissions" "카메라·마이크 권한" "ok" "false" \
            "권한이 허용된 항목 ${row_count}개를 확인했습니다."
    else
        : > "$out_file"
        record_collection_status "privacy_permissions" "카메라·마이크 권한" "unavailable" "false" \
            "카메라·마이크 권한 기록을 읽지 못했습니다."
    fi
    /bin/rm -f "$error_file"
}
