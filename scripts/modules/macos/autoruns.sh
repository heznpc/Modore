#!/bin/bash
# scanner 모듈 (macOS): 자동 실행 (launchd LaunchAgents/Daemons + Login Items)
# 출력: $TMP_DIR/launchctl.txt, $TMP_DIR/plists.txt, $TMP_DIR/loginitems.txt, $TMP_DIR/btm.txt
# 의존: launchctl, find, osascript, sfltool (macOS 13+)

collect_autoruns() {
    launchctl list > "$TMP_DIR/launchctl.txt" 2>/dev/null || true

    find ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons \
        ~/Library/LaunchDaemons \
        -maxdepth 1 -name "*.plist" -type f 2>/dev/null > "$TMP_DIR/plists.txt" || true

    # 로그인 항목
    osascript -e 'tell application "System Events" to get the name of every login item' \
        2>/dev/null > "$TMP_DIR/loginitems.txt" || echo "" > "$TMP_DIR/loginitems.txt"

    # Background Task Management (macOS 13+)
    if command -v sfltool >/dev/null 2>&1; then
        sfltool dumpbtm 2>/dev/null > "$TMP_DIR/btm.txt" || true
    fi
}
