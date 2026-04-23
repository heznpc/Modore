#!/bin/bash
# scanner 모듈 (macOS): 네트워크 연결 + LISTEN 포트
# 출력: $TMP_DIR/net.txt, $TMP_DIR/listen.txt
# 의존: lsof

collect_network() {
    /usr/sbin/lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null > "$TMP_DIR/net.txt" || true
}

collect_listening_ports() {
    /usr/sbin/lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null > "$TMP_DIR/listen.txt" || true
}
