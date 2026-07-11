#!/bin/bash
# ============================================================
# PC 건강검진 Mac Edition - SwiftUI app launcher
# Finder에서 더블클릭하면 SwiftUI 앱을 빌드한 뒤 실행합니다.
# ============================================================

cd "$(dirname "$0")" || exit 1

if [[ "$(uname)" != "Darwin" ]]; then
    echo "이 실행기는 macOS 전용입니다."
    read -r -p "엔터를 누르면 종료합니다..." _
    exit 1
fi

echo "PC 건강검진 Mac Edition SwiftUI 앱을 준비합니다..."
echo ""

APP_PATH="./build/macos/PC Health Check Mac.app"

/bin/bash "./scripts/build_macos_swift_app.sh"
status=$?
if [[ $status -ne 0 ]]; then
    echo ""
    echo "앱 빌드에 실패했습니다. 위 오류를 확인하세요."
    read -r -p "엔터를 누르면 종료합니다..." _
    exit $status
fi

echo ""
echo "앱을 여는 중..."
open "$APP_PATH"
