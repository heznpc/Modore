#!/bin/bash
set -euo pipefail
QA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QA_MODE="${1:-run}"
QA_BUNDLE="$QA_ROOT/dist/LagQA.app"
QA_INSTALLED="$HOME/Applications/LagQA.app"
case "$QA_MODE" in run|--verify|--smoke-test|--build-only) ;; *) echo 'Usage: build_and_run.sh [--verify|--smoke-test|--build-only]' >&2; exit 2 ;; esac
if pgrep -x LagQA >/dev/null; then
    /usr/bin/osascript -e 'tell application id "app.heznpc.lagqa" to quit'
    for attempt in 1 2 3 4 5; do
        if ! pgrep -x LagQA >/dev/null; then break; fi
        sleep 1
    done
    if pgrep -x LagQA >/dev/null; then echo 'LagQA is still saving. Retry after it finishes.' >&2; exit 1; fi
fi
cd "$QA_ROOT"
swift build -c release -j 2
QA_BINARY="$(swift build -c release --show-bin-path)/LagQA"
mkdir -p "$QA_BUNDLE/Contents/MacOS"
cp "$QA_BINARY" "$QA_BUNDLE/Contents/MacOS/LagQA"
cat > "$QA_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LagQA</string>
<key>CFBundleIdentifier</key><string>app.heznpc.lagqa</string>
<key>CFBundleName</key><string>LagQA</string>
<key>CFBundleDisplayName</key><string>ChatGPT 끊김 진단</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$QA_BUNDLE"
mkdir -p "$HOME/Applications"
/usr/bin/ditto "$QA_BUNDLE" "$QA_INSTALLED"
if [[ "$QA_MODE" == --build-only ]]; then exit 0; fi
if [[ "$QA_MODE" == --smoke-test ]]; then
    /usr/bin/open -n "$QA_INSTALLED" --args --smoke-test
else
    /usr/bin/open -n "$QA_INSTALLED"
fi
sleep 1
pgrep -x LagQA >/dev/null
echo "Launched $QA_INSTALLED"
