#!/bin/bash
# ============================================================
# PC Health Check Mac Edition - SwiftUI app builder
#
# Builds a local .app wrapper around the SwiftUI frontend. The app keeps
# using the repository's Bash/JXA scanner engine, so no diagnostic logic is
# duplicated in Swift.
# ============================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/macos/PCHealthCheckMac"
BUILD_DIR="$ROOT_DIR/build/macos"
APP_NAME="PC Health Check Mac.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
EXECUTABLE_NAME="PCHealthCheckMac"
IDENTIFIER="me.heznpc.pchealthcheck.mac"

if [[ "$(uname)" != "Darwin" ]]; then
    echo "ERROR: SwiftUI Mac app build is macOS-only." >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "ERROR: swift toolchain not found. Install Xcode or Command Line Tools first." >&2
    exit 1
fi

echo "Building SwiftUI frontend..."
swift build --package-path "$PACKAGE_DIR" -c release

BIN_DIR="$PACKAGE_DIR/.build/release"
EXECUTABLE="$BIN_DIR/$EXECUTABLE_NAME"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "ERROR: executable missing: $EXECUTABLE" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
printf "%s\n" "$ROOT_DIR" > "$APP_DIR/Contents/Resources/project-root.txt"

/usr/bin/plutil -create xml1 "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string PC Health Check Mac" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string PC Health Check Mac" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $IDENTIFIER" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 0.3.0" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.3.0" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $EXECUTABLE_NAME" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string Heznpc" "$APP_DIR/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo "Built: $APP_DIR"
