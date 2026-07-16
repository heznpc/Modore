#!/bin/bash
# scanner 모듈 (macOS): 보안 상태 (Gatekeeper, SIP, XProtect) + 시스템 확장
# 출력: $TMP_DIR/security.txt, $TMP_DIR/kexts.txt, $TMP_DIR/sysexts.txt

if ! declare -F record_collection_status >/dev/null 2>&1; then
    record_collection_status() { :; }
fi

collect_security() {
    local gatekeeper sip xprotect_version="" baseline_status="ok"
    local baseline_detail="Gatekeeper와 시스템 무결성 보호 상태를 확인했습니다."
    gatekeeper="$(/usr/sbin/spctl --status 2>&1 | /usr/bin/tr -d '\n' || true)"
    sip="$(/usr/bin/csrutil status 2>&1 | /usr/bin/head -1 | /usr/bin/awk -F': ' '{print $2}' | /usr/bin/tr -d '.\n' || true)"
    if [[ -z "$gatekeeper" || -z "$sip" ]]; then
        baseline_status="failed"
        baseline_detail="Gatekeeper 또는 시스템 무결성 보호 상태를 읽지 못했습니다."
    fi

    local XPROTECT_PLIST="/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"
    if [[ -f "$XPROTECT_PLIST" ]]; then
        xprotect_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$XPROTECT_PLIST" 2>/dev/null || true)"
        if [[ -n "$xprotect_version" ]]; then
            record_collection_status "xprotect_metadata" "XProtect 메타데이터" "ok" "false" "XProtect 버전을 확인했습니다."
        else
            record_collection_status "xprotect_metadata" "XProtect 메타데이터" "failed" "false" "XProtect 버전을 읽지 못했습니다."
        fi
    else
        record_collection_status "xprotect_metadata" "XProtect 메타데이터" "unavailable" "false" "이 경로에서 XProtect 메타데이터를 찾지 못했습니다."
    fi

    {
        echo "GATEKEEPER=$gatekeeper"
        echo "SIP=$sip"
        echo "XPROTECT_VERSION=$xprotect_version"
    } > "$TMP_DIR/security.txt"
    record_collection_status "security_baseline" "macOS 기본 보호 상태" "$baseline_status" "true" "$baseline_detail"

    # 시스템 확장 / Kext
    local extension_status=0
    : > "$TMP_DIR/kexts.txt"
    : > "$TMP_DIR/sysexts.txt"
    if [[ -x /usr/bin/kmutil ]]; then
        /usr/bin/kmutil showloaded --list-only 2>/dev/null > "$TMP_DIR/kexts.txt" || extension_status=$?
    fi
    /usr/bin/systemextensionsctl list 2>/dev/null > "$TMP_DIR/sysexts.txt" || extension_status=$?
    if [[ "$extension_status" -eq 0 ]]; then
        record_collection_status "system_extensions" "시스템 확장" "ok" "false" "로드된 시스템 확장을 확인했습니다."
    else
        record_collection_status "system_extensions" "시스템 확장" "failed" "false" "일부 시스템 확장 정보를 읽지 못했습니다."
    fi
}
