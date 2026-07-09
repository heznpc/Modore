#!/bin/bash
# scanner 모듈 (macOS): 자동 실행 (launchd LaunchAgents/Daemons + Login Items)
# 출력: $TMP_DIR/launchctl.txt, $TMP_DIR/plists.txt, $TMP_DIR/loginitems.txt, $TMP_DIR/btm.txt
# 의존: launchctl, find, osascript, sfltool (macOS 13+)

run_to_file_with_timeout() {
    local seconds="$1"
    local output="$2"
    shift 2

    "$@" > "$output" 2>/dev/null &
    local cmd_pid=$!
    local elapsed=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
        if [[ "$elapsed" -ge "$seconds" ]]; then
            kill "$cmd_pid" 2>/dev/null || true
            wait "$cmd_pid" 2>/dev/null || true
            : > "$output"
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$cmd_pid" 2>/dev/null
}

collect_autoruns() {
    launchctl list > "$TMP_DIR/launchctl.txt" 2>/dev/null || true

    find ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons \
        ~/Library/LaunchDaemons \
        -maxdepth 1 -name "*.plist" -type f 2>/dev/null > "$TMP_DIR/plists.txt" || true

    # 로그인 항목
    run_to_file_with_timeout 8 "$TMP_DIR/loginitems.txt" \
        osascript -e 'tell application "System Events" to get the name of every login item' \
        || echo "" > "$TMP_DIR/loginitems.txt"

    # Background Task Management (macOS 13+)
    if command -v sfltool >/dev/null 2>&1; then
        run_to_file_with_timeout 8 "$TMP_DIR/btm.txt" sfltool dumpbtm || true
    fi
}
