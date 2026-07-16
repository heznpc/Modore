#!/bin/bash -p
# Build the native SwiftUI app and its readable, allowlisted local runtime.

set -euo pipefail
umask 022
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
PACKAGE_DIR="$ROOT_DIR/macos/PCHealthCheckMac"
BUILD_DIR="${PCH_BUILD_DIR:-$ROOT_DIR/build/macos}"
APP_NAME="PC Health Check Mac.app"
EXECUTABLE_NAME="PCHealthCheckMac"
IDENTIFIER="me.heznpc.pchealthcheck.mac"
APP_VERSION="${PCH_APP_VERSION:-0.3.0}"
MINIMUM_SYSTEM_VERSION="${PCH_MINIMUM_SYSTEM_VERSION:-13.0}"
ARCH_SPEC="${PCH_BUILD_ARCHS:-native}"
STRICT_BUILD="${PCH_STRICT_BUILD:-1}"
ALLOW_USER_TOOLCHAIN="${PCH_ALLOW_USER_TOOLCHAIN:-0}"
KEEP_PREVIOUS_APP="${PCH_KEEP_PREVIOUS_APP:-0}"

if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    /usr/bin/printf 'ERROR: PCH_APP_VERSION must be a numeric X.Y.Z version: %s\n' "$APP_VERSION" >&2
    exit 64
fi
if [[ ! "$MINIMUM_SYSTEM_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    /usr/bin/printf 'ERROR: PCH_MINIMUM_SYSTEM_VERSION must look like 13.0.\n' >&2
    exit 64
fi
if [[ "$ALLOW_USER_TOOLCHAIN" != "0" && "$ALLOW_USER_TOOLCHAIN" != "1" ]]; then
    /usr/bin/printf 'ERROR: PCH_ALLOW_USER_TOOLCHAIN must be 0 or 1.\n' >&2
    exit 64
fi
if [[ "$KEEP_PREVIOUS_APP" != "0" && "$KEEP_PREVIOUS_APP" != "1" ]]; then
    /usr/bin/printf 'ERROR: PCH_KEEP_PREVIOUS_APP must be 0 or 1.\n' >&2
    exit 64
fi
if [[ "$ALLOW_USER_TOOLCHAIN" == "1" && "${PCH_SKIP_ADHOC_SIGN:-0}" == "1" ]]; then
    /usr/bin/printf 'ERROR: a user-owned toolchain cannot be used for an unsigned distribution build.\n' >&2
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

current_uid="$(/usr/bin/id -u)"
account_home="$(/usr/bin/dscacheutil -q user -a uid "$current_uid" 2>/dev/null \
    | /usr/bin/awk '$1 == "dir:" {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}')"
user_temp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
[[ -n "$account_home" && "$account_home" == /* && -d "$account_home" && ! -L "$account_home" ]] || {
    /usr/bin/printf 'ERROR: cannot establish the current account home directory.\n' >&2
    exit 1
}
[[ -n "$user_temp" && "$user_temp" == /* && -d "$user_temp" && ! -L "$user_temp" ]] || {
    /usr/bin/printf 'ERROR: cannot establish the current account temporary directory.\n' >&2
    exit 1
}
account_home="$(cd -P "$account_home" && /bin/pwd -P)"
user_temp="$(cd -P "$user_temp" && /bin/pwd -P)"
for trusted_directory in "$account_home" "$user_temp"; do
    owner_uid="$(/usr/bin/stat -f '%u' "$trusted_directory")"
    permissions="$(/usr/bin/stat -f '%Lp' "$trusted_directory")"
    if [[ "$owner_uid" != "$current_uid" || $((8#$permissions & 0022)) -ne 0 ]]; then
        /usr/bin/printf 'ERROR: unsafe owner or permissions on trusted directory: %s\n' "$trusted_directory" >&2
        exit 1
    fi
done

# Keep every generated path inside the repository build tree or the current
# account's private temporary directory. Validate all existing components before
# creating anything, then create one component at a time without following a
# final symlink.
build_anchor=""
case "$BUILD_DIR" in
    "$ROOT_DIR/build"|"$ROOT_DIR/build/"*) build_anchor="$ROOT_DIR" ;;
    "$user_temp/"*) build_anchor="$user_temp" ;;
    *)
        /usr/bin/printf 'ERROR: PCH_BUILD_DIR must stay inside the repository build tree or user temp directory.\n' >&2
        exit 64
        ;;
esac

create_build_directory_without_symlinks() {
    local anchor="$1"
    local requested="$2"
    local relative component current candidate resolved owner permissions
    local -a components=()

    case "$requested" in
        "$anchor/"*) relative="${requested#"$anchor/"}" ;;
        *) return 1 ;;
    esac
    [[ -n "$relative" ]] || return 1

    # Parse the whole request before creating its first component, so a later
    # '..', empty component, or static symlink cannot leave partial output.
    while [[ -n "$relative" ]]; do
        if [[ "$relative" == */* ]]; then
            component="${relative%%/*}"
            relative="${relative#*/}"
        else
            component="$relative"
            relative=""
        fi
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
        components+=("$component")
    done

    current="$anchor"
    for component in "${components[@]}"; do
        candidate="$current/$component"
        [[ ! -L "$candidate" ]] || return 1
        if [[ -e "$candidate" && ! -d "$candidate" ]]; then
            return 1
        fi
        current="$candidate"
    done

    current="$anchor"
    for component in "${components[@]}"; do
        resolved="$(cd -P "$current" && /bin/pwd -P)" || return 1
        [[ "$resolved" == "$current" ]] || return 1
        candidate="$current/$component"
        [[ ! -L "$candidate" ]] || return 1
        if [[ ! -e "$candidate" ]]; then
            /bin/mkdir "$candidate" || return 1
        fi
        [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
        owner="$(/usr/bin/stat -f '%u' "$candidate")" || return 1
        permissions="$(/usr/bin/stat -f '%Lp' "$candidate")" || return 1
        [[ "$owner" == "$current_uid" && $((8#$permissions & 0022)) -eq 0 ]] || return 1
        current="$candidate"
    done
}

if ! create_build_directory_without_symlinks "$build_anchor" "$BUILD_DIR"; then
    /usr/bin/printf 'ERROR: PCH_BUILD_DIR contains an unsafe component or intermediate symlink.\n' >&2
    exit 64
fi
[[ -d "$BUILD_DIR" && ! -L "$BUILD_DIR" ]] || {
    /usr/bin/printf 'ERROR: PCH_BUILD_DIR is not a regular directory.\n' >&2
    exit 64
}
BUILD_DIR="$(cd -P "$BUILD_DIR" && /bin/pwd -P)"
case "$BUILD_DIR" in
    "$ROOT_DIR/build"|"$ROOT_DIR/build/"*|"$user_temp/"*) ;;
    *)
        /usr/bin/printf 'ERROR: PCH_BUILD_DIR resolves outside the allowed build roots.\n' >&2
        exit 64
        ;;
esac
build_owner="$(/usr/bin/stat -f '%u' "$BUILD_DIR")"
build_permissions="$(/usr/bin/stat -f '%Lp' "$BUILD_DIR")"
if [[ "$build_owner" != "$current_uid" || $((8#$build_permissions & 0022)) -ne 0 ]]; then
    /usr/bin/printf 'ERROR: unsafe owner or permissions on PCH_BUILD_DIR: %s\n' "$BUILD_DIR" >&2
    exit 64
fi
FINAL_APP_DIR="$BUILD_DIR/$APP_NAME"

clean_environment=(
    "HOME=$account_home"
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
    "TMPDIR=$user_temp"
    "LANG=en_US.UTF-8"
    "LC_ALL=en_US.UTF-8"
)
run_clean() {
    /usr/bin/env -i "${clean_environment[@]}" "$@"
}
resolve_trusted_tool_link() {
    local source="$1"
    local target directory
    if [[ -L "$source" ]]; then
        target="$(/usr/bin/readlink "$source")" || return 1
        [[ "$target" == /* ]] || target="$(/usr/bin/dirname "$source")/$target"
    else
        target="$source"
    fi
    directory="$(cd -P "$(/usr/bin/dirname "$target")" && /bin/pwd -P)" || return 1
    target="$directory/$(/usr/bin/basename "$target")"
    [[ -f "$target" && ! -L "$target" && -x "$target" ]] || return 1
    /usr/bin/printf '%s\n' "$target"
}

developer_dir="$(run_clean /usr/bin/xcode-select -p)"
swift_tool="$(run_clean /usr/bin/xcrun --find swift)"
swift_real="$(resolve_trusted_tool_link "$swift_tool")" || {
    /usr/bin/printf 'ERROR: selected Swift tool link is unsafe.\n' >&2
    exit 1
}
case "$developer_dir" in
    /Applications/*.app/Contents/Developer|/Library/Developer/CommandLineTools) ;;
    *) /usr/bin/printf 'ERROR: selected developer directory is outside trusted system locations.\n' >&2; exit 1 ;;
esac
for trusted_tool_path in "$developer_dir" "$swift_real"; do
    owner_uid="$(/usr/bin/stat -f '%u' "$trusted_tool_path")"
    permissions="$(/usr/bin/stat -f '%Lp' "$trusted_tool_path")"
    if [[ $((8#$permissions & 0022)) -ne 0 \
        || ( "$owner_uid" != "0" \
            && ( "$ALLOW_USER_TOOLCHAIN" != "1" || "$owner_uid" != "$current_uid" ) ) ]]; then
        /usr/bin/printf 'ERROR: selected toolchain owner or permissions are unsafe for this build mode: %s\n' \
            "$trusted_tool_path" >&2
        exit 1
    fi
done
[[ "$swift_tool" == "$developer_dir/"* && "$swift_real" == "$developer_dir/"* \
    && -x "$swift_tool" && -x "$swift_real" ]] || {
    /usr/bin/printf 'ERROR: selected Swift tool is outside the trusted developer directory.\n' >&2
    exit 1
}

required_commands=(xcrun codesign ditto plutil shasum)
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

running_app_binary="$FINAL_APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
existing_app_identity=""
app_bundle_is_expected() {
    local app_directory="$1"
    local require_signature="${2:-1}"
    local contents_directory="$app_directory/Contents"
    local macos_directory="$app_directory/Contents/MacOS"
    local info_plist="$app_directory/Contents/Info.plist"
    local executable="$app_directory/Contents/MacOS/$EXECUTABLE_NAME"
    local bundle_identifier bundle_executable

    [[ -d "$app_directory" && ! -L "$app_directory" ]] || return 1
    [[ -d "$contents_directory" && ! -L "$contents_directory" ]] || return 1
    [[ -d "$macos_directory" && ! -L "$macos_directory" ]] || return 1
    [[ -f "$info_plist" && ! -L "$info_plist" ]] || return 1
    [[ -f "$executable" && ! -L "$executable" && -x "$executable" ]] || return 1
    bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$info_plist" 2>/dev/null)" || return 1
    bundle_executable="$(/usr/bin/plutil -extract CFBundleExecutable raw "$info_plist" 2>/dev/null)" || return 1
    [[ "$bundle_identifier" == "$IDENTIFIER" && "$bundle_executable" == "$EXECUTABLE_NAME" ]] || return 1
    if [[ "$require_signature" == "1" ]]; then
        run_clean /usr/bin/codesign --verify --deep --strict "$app_directory" >/dev/null 2>&1 || return 1
    fi
}
existing_app_is_expected() {
    app_bundle_is_expected "$FINAL_APP_DIR" 1
}
if [[ -e "$FINAL_APP_DIR" || -L "$FINAL_APP_DIR" ]]; then
    if ! existing_app_is_expected; then
        /usr/bin/printf 'ERROR: existing app output is not a valid %s bundle; preserve and review it manually: %s\n' \
            "$IDENTIFIER" "$FINAL_APP_DIR" >&2
        exit 73
    fi
    existing_app_identity="$(/usr/bin/stat -f '%d:%i' "$FINAL_APP_DIR")"
fi

app_binary_is_running() {
    /bin/ps -axo comm= | /usr/bin/awk -v target="$running_app_binary" \
        'BEGIN { found = 0 } $0 == target { found = 1 } END { exit(found ? 0 : 1) }'
}
if [[ -x "$running_app_binary" ]] && app_binary_is_running; then
    /usr/bin/printf 'ERROR: close the running app before replacing its signed bundle.\n' >&2
    exit 75
fi

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
binary_staging="$(/usr/bin/mktemp -d "$user_temp/pch-swift-binaries.XXXXXX")"
app_staging="$(/usr/bin/mktemp -d "$BUILD_DIR/.pch-app-staging.XXXXXX")"
APP_DIR="$app_staging/$APP_NAME"

for architecture in "${architectures[@]}"; do
    scratch_path="$(/usr/bin/mktemp -d "$binary_staging/swift-build-$architecture.XXXXXX")"
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
    run_clean /usr/bin/xcrun swift build "${build_arguments[@]}"
    binary_dir="$(run_clean /usr/bin/xcrun swift build "${build_arguments[@]}" --show-bin-path)"
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
    run_clean /usr/bin/xcrun lipo -create \
        "$binary_staging/$EXECUTABLE_NAME-arm64" \
        "$binary_staging/$EXECUTABLE_NAME-x86_64" \
        -output "$bundled_executable"
fi
run_clean /usr/bin/xcrun strip -S -x "$bundled_executable"
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
        run_clean /usr/bin/shasum -a 256 "$relative_path"
    done
} | run_clean /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s:%s\n' "$APP_VERSION" "$runtime_hash" > "$RUNTIME_DIR/runtime-manifest.txt"

/bin/cp "$ROOT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
icon_builder="$binary_staging/build_macos_icon.sh"
/usr/bin/ditto --norsrc --noextattr --noacl \
    "$ROOT_DIR/scripts/build_macos_icon.sh" "$icon_builder"
run_clean /bin/bash -p "$icon_builder" \
    "$APP_DIR/Contents/Resources/AppIcon.icns" \
    "$ROOT_DIR/assets/macos/AppIcon.svg"

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
    run_clean /usr/bin/codesign --force --sign - "$APP_DIR" >/dev/null
fi

actual_architectures="$(run_clean /usr/bin/xcrun lipo -archs "$bundled_executable")"
if [[ -x "$running_app_binary" ]] && app_binary_is_running; then
    /usr/bin/printf 'ERROR: the app started while its replacement was building; refusing to swap bundles.\n' >&2
    exit 75
fi
if [[ -e "$FINAL_APP_DIR" || -L "$FINAL_APP_DIR" ]]; then
    current_app_identity="$(/usr/bin/stat -f '%d:%i' "$FINAL_APP_DIR" 2>/dev/null || true)"
    if [[ -z "$existing_app_identity" || "$current_app_identity" != "$existing_app_identity" ]] \
        || ! existing_app_is_expected; then
        /usr/bin/printf 'ERROR: existing app output changed during the build; preserving it and refusing replacement.\n' >&2
        exit 73
    fi
    backup_container="$(/usr/bin/mktemp -d "$BUILD_DIR/.pch-app-backup.XXXXXX")"
    backup_identity="$(/usr/bin/stat -f '%d:%i' "$backup_container")"
    backup_app="$backup_container/$APP_NAME"
    if ! /bin/mv "$FINAL_APP_DIR" "$backup_app"; then
        /bin/rmdir "$backup_container" 2>/dev/null || true
        exit 74
    fi
    if app_binary_is_running; then
        if /bin/mv "$backup_app" "$FINAL_APP_DIR"; then
            /bin/rmdir "$backup_container" 2>/dev/null || true
        else
            /usr/bin/printf 'ERROR: previous app is preserved for manual recovery at: %s\n' "$backup_app" >&2
        fi
        /usr/bin/printf 'ERROR: the previous app started during bundle replacement; refusing to continue.\n' >&2
        exit 75
    fi
    if ! /bin/mv "$APP_DIR" "$FINAL_APP_DIR"; then
        if /bin/mv "$backup_app" "$FINAL_APP_DIR"; then
            /bin/rmdir "$backup_container" 2>/dev/null || true
        else
            /usr/bin/printf 'ERROR: previous app is preserved for manual recovery at: %s\n' "$backup_app" >&2
        fi
        exit 74
    fi
    new_signature_required="1"
    if [[ "${PCH_SKIP_ADHOC_SIGN:-0}" == "1" ]]; then
        new_signature_required="0"
    fi
    if ! app_bundle_is_expected "$FINAL_APP_DIR" "$new_signature_required"; then
        if /bin/mv "$FINAL_APP_DIR" "$APP_DIR" && /bin/mv "$backup_app" "$FINAL_APP_DIR"; then
            /bin/rmdir "$backup_container" 2>/dev/null || true
        else
            /usr/bin/printf 'ERROR: previous app is preserved for manual recovery at: %s\n' "$backup_app" >&2
        fi
        /usr/bin/printf 'ERROR: replacement app failed post-swap verification; previous app restored when possible.\n' >&2
        exit 74
    fi
    if [[ "$KEEP_PREVIOUS_APP" == "1" ]]; then
        /usr/bin/printf 'Previous app preserved for manual review: %s\n' "$backup_app"
    else
        current_backup_identity="$(/usr/bin/stat -f '%d:%i' "$backup_container" 2>/dev/null || true)"
        case "$backup_container" in
            "$BUILD_DIR"/.pch-app-backup.*) ;;
            *) current_backup_identity="" ;;
        esac
        if [[ -z "$backup_identity" || "$current_backup_identity" != "$backup_identity" ]] \
            || ! app_bundle_is_expected "$backup_app" 1; then
            /usr/bin/printf 'ERROR: previous app backup changed after replacement; preserving for manual review: %s\n' "$backup_app" >&2
            exit 73
        fi
        /bin/rm -rf "$backup_container"
        /usr/bin/printf 'Verified replacement; previous app backup removed.\n'
    fi
else
    /bin/mv "$APP_DIR" "$FINAL_APP_DIR"
    new_signature_required="1"
    if [[ "${PCH_SKIP_ADHOC_SIGN:-0}" == "1" ]]; then
        new_signature_required="0"
    fi
    if ! app_bundle_is_expected "$FINAL_APP_DIR" "$new_signature_required"; then
        /usr/bin/printf 'ERROR: built app failed post-install verification: %s\n' "$FINAL_APP_DIR" >&2
        exit 74
    fi
fi

/usr/bin/printf 'Built: %s\n' "$FINAL_APP_DIR"
/usr/bin/printf 'Architectures: %s\n' "$actual_architectures"
/usr/bin/printf 'Minimum macOS: %s\n' "$MINIMUM_SYSTEM_VERSION"
