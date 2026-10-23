#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *) echo "usage: $0 [--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

APP_NAME="ModoreGlassPrototype"
BUNDLE_ID="me.heznpc.modore.liquidglass-prototype"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/Modore Glass Prototype.app"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT_DIR"

# The distinct process name leaves installed Modore builds running untouched.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
xcrun swift build --product "$APP_NAME"
BUILD_BINARY="$(xcrun swift build --show-bin-path)/$APP_NAME"
BUILD_STAMP="$(date '+%Y-%m-%d %H:%M:%S %z')"
SOURCE_DIGEST="$(shasum -a 256 Package.swift Sources/ModoreGlassPrototype/*/*.swift | shasum -a 256 | cut -c1-12)"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Modore Glass Prototype</string>
<key>CFBundleDisplayName</key><string>Modore Glass Prototype</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>$(date '+%Y%m%d%H%M%S')</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>PrototypeBuiltAt</key><string>$BUILD_STAMP</string>
<key>PrototypeSourceDigest</key><string>$SOURCE_DIGEST</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP_BUNDLE"

case "$MODE" in
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    /usr/bin/codesign --verify "$APP_BUNDLE"
    BUILD_UUID="$(dwarfdump --uuid "$BUILD_BINARY" | awk '{print $2}')"
    BUNDLE_UUID="$(dwarfdump --uuid "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | awk '{print $2}')"
    test "$BUILD_UUID" = "$BUNDLE_UUID"
    echo "Running: $APP_BUNDLE"
    echo "Built: $BUILD_STAMP · source $SOURCE_DIGEST"
    ps -p "$(pgrep -x "$APP_NAME" | head -1)" -o pid=,command= ;;
  *) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
