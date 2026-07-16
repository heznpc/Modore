#!/bin/bash -p
# ============================================================
# PC 건강검진 Mac Edition - SwiftUI app launcher
# Finder에서 더블클릭하면 SwiftUI 앱을 빌드한 뒤 실행합니다.
# ============================================================

set -u
set -o pipefail
umask 022
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

cd "$(/usr/bin/dirname "$0")" || exit 1
cd -P . || exit 1

if [[ "$(/usr/bin/uname)" != "Darwin" ]]; then
    echo "이 실행기는 macOS 전용입니다."
    read -r -p "엔터를 누르면 종료합니다..." _
    exit 1
fi

echo "PC 건강검진 Mac Edition SwiftUI 앱을 준비합니다..."
echo ""

APP_PATH="$PWD/build/macos/PC Health Check Mac.app"
APP_BIN="$APP_PATH/Contents/MacOS/PCHealthCheckMac"
app_binary_is_running() {
    /bin/ps -axo comm= | /usr/bin/awk -v target="$APP_BIN" \
        'BEGIN { found = 0 } $0 == target { found = 1 } END { exit(found ? 0 : 1) }'
}

if [[ -x "$APP_BIN" ]] && app_binary_is_running; then
    echo "실행 중인 개발 앱에 안전한 종료를 요청합니다..."
    if ! /usr/bin/osascript -l JavaScript \
        -e 'ObjC.import("AppKit")' \
        -e 'function run(argv) { const target = argv[0]; const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("me.heznpc.pchealthcheck.mac"); let count = 0; for (let index = 0; index < apps.count; index += 1) { const app = apps.objectAtIndex(index); const url = app.bundleURL; if (url && ObjC.unwrap(url.path) === target) { if (app.terminate) { count += 1; } } } return String(count); }' \
        -- "$APP_PATH" >/dev/null; then
        echo "실행 중인 앱에 종료를 요청하지 못했습니다. 앱을 직접 종료한 뒤 다시 실행하세요."
        read -r -p "엔터를 누르면 종료합니다..." _
        exit 75
    fi
    for _ in {1..300}; do
        app_binary_is_running || break
        /bin/sleep 0.1
    done
    if app_binary_is_running; then
        echo "앱이 아직 안전한 작업을 마치는 중입니다. 종료가 끝난 뒤 다시 실행하세요."
        read -r -p "엔터를 누르면 종료합니다..." _
        exit 75
    fi
fi

/usr/bin/env -i \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    "$PWD/scripts/build_macos_swift_app.sh"
status=$?
if [[ $status -ne 0 ]]; then
    echo ""
    echo "앱 빌드에 실패했습니다. 위 오류를 확인하세요."
    read -r -p "엔터를 누르면 종료합니다..." _
    exit $status
fi

echo ""
echo "앱을 여는 중..."
/usr/bin/open -n "$APP_PATH"
