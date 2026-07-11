#!/bin/bash
# Build the native SwiftUI app and its readable, allowlisted local runtime.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/macos/PCHealthCheckMac"
BUILD_DIR="${PCH_BUILD_DIR:-$ROOT_DIR/build/macos}"
APP_NAME="PC Health Check Mac.app"
FINAL_APP_DIR="$BUILD_DIR/$APP_NAME"
EXECUTABLE_NAME="PCHealthCheckMac"
IDENTIFIER="me.heznpc.pchealthcheck.mac"
APP_VERSION="${PCH_APP_VERSION:-0.3.0}"
MINIMUM_SYSTEM_VERSION="${PCH_MINIMUM_SYSTEM_VERSION:-13.0}"
ARCH_SPEC="${PCH_BUILD_ARCHS:-native}"
STRICT_BUILD="${PCH_STRICT_BUILD:-1}"

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    /usr/bin/printf 'ERROR: PCH_APP_VERSION must be a numeric X.Y.Z version: %s\n' "$APP_VERSION" >&2
    exit 64
fi
if [[ ! "$MINIMUM_SYSTEM_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    /usr/bin/printf 'ERROR: PCH_MINIMUM_SYSTEM_VERSION must look like 13.0.\n' >&2
    exit 64
fi
if [[ "$BUILD_DIR" != /* || "$BUILD_DIR" == "/" || -L "$BUILD_DIR" ]]; then
    /usr/bin/printf 'ERROR: PCH_BUILD_DIR must be an absolute, non-symlink directory.\n' >&2
    exit 64
fi

if [[ "$(/usr/bin/uname)" != "Darwin" ]]; then
    /usr/bin/printf 'ERROR: SwiftUI Mac app build is macOS-only.\n' >&2
    exit 1
fi

required_commands=(swift xcrun codesign plutil shasum)
for command_name in "${required_commands[@]}"; do
    if ! /usr/bin/command -v "$command_name" >/dev/null 2>&1; then
        /usr/bin/printf 'ERROR: required command missing: %s\n' "$command_name" >&2
        exit 1
    fi
done

case "$ARCH_SPEC" in
    native) architecture_list="$(/usr/bin/uname -m)" ;;
    universal|universal2) architecture_list="arm64 x86_64" ;;
    *) architecture_list="$(/usr/bin/printf '%s' "$ARCH_SPEC" | /usr/bin/tr ',' ' ')" ;;
esac

architectures=()
for architecture in $architecture_list; do
    case "$architecture" in
        arm64|x86_64) ;;
        *)
            /usr/bin/printf 'ERROR: unsupported Mac architecture: %s\n' "$architecture" >&2
            exit 64
            ;;
    esac
    for existing in "${architectures[@]:-}"; do
        if [[ "$existing" == "$architecture" ]]; then
            /usr/bin/printf 'ERROR: duplicate Mac architecture: %s\n' "$architecture" >&2
            exit 64
        fi
    done
    architectures+=("$architecture")
done
if [[ "${#architectures[@]}" -eq 0 ]]; then
    /usr/bin/printf 'ERROR: PCH_BUILD_ARCHS resolved to an empty architecture list.\n' >&2
    exit 64
fi

/bin/mkdir -p "$BUILD_DIR"
lock_directory="$BUILD_DIR/.pch-build.lock"
if ! /bin/mkdir "$lock_directory" 2>/dev/null; then
    /usr/bin/printf 'ERROR: another Mac app build is already using: %s\n' "$BUILD_DIR" >&2
    exit 73
fi
binary_staging=""
app_staging=""
cleanup() {
    [[ -z "$binary_staging" ]] || /bin/rm -rf "$binary_staging"
    [[ -z "$app_staging" ]] || /bin/rm -rf "$app_staging"
    /bin/rmdir "$lock_directory" 2>/dev/null || true
}
trap cleanup EXIT
binary_staging="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pch-swift-binaries.XXXXXX")"
app_staging="$(/usr/bin/mktemp -d "$BUILD_DIR/.pch-app-staging.XXXXXX")"
APP_DIR="$app_staging/$APP_NAME"

for architecture in "${architectures[@]}"; do
    scratch_path="$BUILD_DIR/swift-build-$architecture"
    triple="${architecture}-apple-macosx${MINIMUM_SYSTEM_VERSION}"
    build_arguments=(
        --package-path "$PACKAGE_DIR"
        --scratch-path "$scratch_path"
        --configuration release
        --triple "$triple"
        -debug-info-format none
        --disable-local-rpath
        -Xswiftc -file-prefix-map
        -Xswiftc "$ROOT_DIR=."
        -Xswiftc -debug-prefix-map
        -Xswiftc "$ROOT_DIR=."
    )
    if [[ "$STRICT_BUILD" == "1" ]]; then
        build_arguments+=(
            -Xswiftc -warnings-as-errors
            -Xswiftc -strict-concurrency=complete
        )
    fi

    /usr/bin/printf 'Building SwiftUI frontend for %s (minimum macOS %s)...\n' \
        "$architecture" "$MINIMUM_SYSTEM_VERSION"
    swift build "${build_arguments[@]}"
    binary_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"
    executable="$binary_dir/$EXECUTABLE_NAME"
    if [[ ! -x "$executable" ]]; then
        /usr/bin/printf 'ERROR: executable missing: %s\n' "$executable" >&2
        exit 1
    fi
    /bin/cp "$executable" "$binary_staging/$EXECUTABLE_NAME-$architecture"
done

/bin/mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
bundled_executable="$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
if [[ "${#architectures[@]}" -eq 1 ]]; then
    /bin/cp "$binary_staging/$EXECUTABLE_NAME-${architectures[0]}" "$bundled_executable"
else
    /usr/bin/xcrun lipo -create \
        "$binary_staging/$EXECUTABLE_NAME-arm64" \
        "$binary_staging/$EXECUTABLE_NAME-x86_64" \
        -output "$bundled_executable"
fi
/usr/bin/xcrun strip -S -x "$bundled_executable"
/bin/chmod +x "$bundled_executable"

RUNTIME_DIR="$APP_DIR/Contents/Resources/runtime"
RUNTIME_FILES=(
    "scripts/scanner.sh"
    "scripts/cleanup.sh"
    "scripts/storage_watch.sh"
    "scripts/schedule.sh"
    "scripts/report.jxa.js"
    "scripts/scanner_helper.jxa.js"
    "scripts/modules/macos/cpu.sh"
    "scripts/modules/macos/network.sh"
    "scripts/modules/macos/autoruns.sh"
    "scripts/modules/macos/security.sh"
    "scripts/modules/macos/storage.sh"
    "data/config.example.json"
    "data/explain.json"
    "data/whitelist.json"
    "data/report_i18n/ko.json"
    "data/report_i18n/en.json"
    "data/report_i18n/ja.json"
    "rules/README.md"
    "rules/autoruns.json"
    "rules/defender.json"
    "rules/installs.json"
    "rules/network.json"
    "rules/process.json"
)

for relative_path in "${RUNTIME_FILES[@]}"; do
    source_path="$ROOT_DIR/$relative_path"
    destination_path="$RUNTIME_DIR/$relative_path"
    if [[ ! -f "$source_path" || -L "$source_path" ]]; then
        /usr/bin/printf 'ERROR: runtime file must be a regular non-symlink: %s\n' "$source_path" >&2
        exit 1
    fi
    /bin/mkdir -p "$(/usr/bin/dirname "$destination_path")"
    /bin/cp "$source_path" "$destination_path"
done
/usr/bin/find "$RUNTIME_DIR/scripts" -type f -name '*.sh' -exec /bin/chmod +x {} \;

runtime_hash="$({
    cd "$RUNTIME_DIR"
    /usr/bin/find . -type f | LC_ALL=C /usr/bin/sort | while IFS= read -r relative_path; do
        /usr/bin/shasum -a 256 "$relative_path"
    done
} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s:%s\n' "$APP_VERSION" "$runtime_hash" > "$RUNTIME_DIR/runtime-manifest.txt"

if [[ "${PCH_STANDALONE_BUNDLE:-0}" != "1" ]]; then
    /usr/bin/printf '%s\n' "$ROOT_DIR" > "$APP_DIR/Contents/Resources/project-root.txt"
fi

/bin/cp "$ROOT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
"$ROOT_DIR/scripts/build_macos_icon.sh" "$APP_DIR/Contents/Resources/AppIcon.icns"

/usr/bin/plutil -create xml1 "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string PC Health Check Mac" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string PC Health Check Mac" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $IDENTIFIER" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $EXECUTABLE_NAME" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.utilities" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MINIMUM_SYSTEM_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string Heznpc" "$APP_DIR/Contents/Info.plist"

# Release payloads must not inherit Finder metadata, quarantine data, resource
# forks, ACLs, or credentials hidden in extended attributes from the checkout.
/usr/bin/xattr -cr "$APP_DIR"
/bin/chmod -RN "$APP_DIR"

if [[ "${PCH_SKIP_ADHOC_SIGN:-0}" != "1" ]]; then
    /usr/bin/codesign --force --sign - "$APP_DIR" >/dev/null
fi

actual_architectures="$(/usr/bin/xcrun lipo -archs "$bundled_executable")"
backup_app="$BUILD_DIR/.pch-app-backup-$$"
[[ ! -e "$backup_app" && ! -L "$backup_app" ]] || {
    /usr/bin/printf 'ERROR: stale app backup exists: %s\n' "$backup_app" >&2
    exit 73
}
if [[ -e "$FINAL_APP_DIR" || -L "$FINAL_APP_DIR" ]]; then
    /bin/mv "$FINAL_APP_DIR" "$backup_app"
    if ! /bin/mv "$APP_DIR" "$FINAL_APP_DIR"; then
        /bin/mv "$backup_app" "$FINAL_APP_DIR" 2>/dev/null || true
        exit 74
    fi
    /bin/rm -rf "$backup_app"
else
    /bin/mv "$APP_DIR" "$FINAL_APP_DIR"
fi

/usr/bin/printf 'Built: %s\n' "$FINAL_APP_DIR"
/usr/bin/printf 'Architectures: %s\n' "$actual_architectures"
/usr/bin/printf 'Minimum macOS: %s\n' "$MINIMUM_SYSTEM_VERSION"
