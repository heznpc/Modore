#!/bin/bash
# scanner 모듈 (macOS): 보안 상태 (Gatekeeper, SIP, XProtect) + 시스템 확장
# 출력: $TMP_DIR/security.txt, $TMP_DIR/kexts.txt, $TMP_DIR/sysexts.txt

collect_security() {
    {
        echo "GATEKEEPER=$(spctl --status 2>&1 | tr -d '\n')"
        echo "SIP=$(csrutil status 2>&1 | head -1 | awk -F': ' '{print $2}' | tr -d '.\n')"
        local XPROTECT_PLIST="/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"
        if [[ -f "$XPROTECT_PLIST" ]]; then
            local XP_VER
            XP_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$XPROTECT_PLIST" 2>/dev/null || echo "?")
            echo "XPROTECT_VERSION=$XP_VER"
        fi
    } > "$TMP_DIR/security.txt"

    # 시스템 확장 / Kext
    if command -v kmutil >/dev/null 2>&1; then
        kmutil showloaded --list-only 2>/dev/null > "$TMP_DIR/kexts.txt" || true
    fi
    systemextensionsctl list 2>/dev/null > "$TMP_DIR/sysexts.txt" || true
}
