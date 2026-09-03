#!/bin/bash -p
# Build the native SwiftUI app and its readable, allowlisted local runtime.

set -euo pipefail
umask 022
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
BUILD_SUPPORT_MODULE="$ROOT_DIR/scripts/modules/build_support.sh"
PACKAGE_DIR="$ROOT_DIR/macos/Modore"
BUILD_DIR="${PCH_BUILD_DIR:-$ROOT_DIR/build/macos}"
APP_NAME="Modore.app"
EXECUTABLE_NAME="Modore"
IDENTIFIER="me.heznpc.modore"
APP_VERSION="${PCH_APP_VERSION:-0.3.0}"
MINIMUM_SYSTEM_VERSION="${PCH_MINIMUM_SYSTEM_VERSION:-13.0}"
ARCH_SPEC="${PCH_BUILD_ARCHS:-native}"
STRICT_BUILD="${PCH_STRICT_BUILD:-1}"
ALLOW_USER_TOOLCHAIN="${PCH_ALLOW_USER_TOOLCHAIN:-0}"
KEEP_PREVIOUS_APP="${PCH_KEEP_PREVIOUS_APP:-0}"
PYTHON_RUNTIME_VERSION="3.11.16+20260825"
PYTHON_RUNTIME_RELEASE="20260825"
PYTHON_RUNTIME_ARM64_SHA256="a84adc050a29e0c7387c885ff13e6ac4b0027f9e841359e200d647313dbb5b03"
PYTHON_RUNTIME_X86_64_SHA256="77bfa2b959edc0d653830f14f08ab8260156d4b5930368886d4e1c6a76f1d2d4"
PYTHON_RUNTIME_MAX_ARCHIVE_BYTES="268435456"

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
if [[ ! -f "$BUILD_SUPPORT_MODULE" || -L "$BUILD_SUPPORT_MODULE" ]]; then
    /usr/bin/printf 'ERROR: build support module is missing or unsafe: %s\n' \
        "$BUILD_SUPPORT_MODULE" >&2
    exit 1
fi
# shellcheck source=scripts/modules/build_support.sh
source "$BUILD_SUPPORT_MODULE"
lock_file="$BUILD_DIR/.pch-build.lock"
lock_status=0
build_support_acquire_lock "$lock_file" "$current_uid" || lock_status=$?
if [[ "$lock_status" -ne 0 ]]; then
    if [[ "$lock_status" == "75" ]]; then
        /usr/bin/printf 'ERROR: another Mac app build is already using: %s\n' \
            "$BUILD_DIR" >&2
    else
        /usr/bin/printf 'ERROR: cannot establish a safe Mac app build lock: %s\n' \
            "$lock_file" >&2
    fi
    exit "$lock_status"
fi
build_identity="$(build_support_identity "$ROOT_DIR" "$BUILD_DIR")"
if [[ ! "$build_identity" =~ ^[0-9a-f]{64}$ ]]; then
    /usr/bin/printf 'ERROR: cannot establish the build identity.\n' >&2
    exit 1
fi
if ! build_support_recover_staging_directories \
    "$BUILD_DIR" ".pch-app-staging" "$build_identity" "$current_uid" \
    || ! build_support_recover_staging_directories \
        "$user_temp" "pch-swift-binaries" "$build_identity" "$current_uid"; then
    /usr/bin/printf 'ERROR: cannot safely recover an interrupted build staging directory.\n' >&2
    exit 73
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

required_commands=(xcrun codesign curl ditto lockf perl plutil shasum tar)
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

python_runtime_archive_name() {
    case "$1" in
        arm64)
            /usr/bin/printf 'cpython-%s-aarch64-apple-darwin-install_only_stripped.tar.gz\n' \
                "$PYTHON_RUNTIME_VERSION"
            ;;
        x86_64)
            /usr/bin/printf 'cpython-%s-x86_64-apple-darwin-install_only_stripped.tar.gz\n' \
                "$PYTHON_RUNTIME_VERSION"
            ;;
        *) return 1 ;;
    esac
}
python_runtime_archive_sha256() {
    case "$1" in
        arm64) /usr/bin/printf '%s\n' "$PYTHON_RUNTIME_ARM64_SHA256" ;;
        x86_64) /usr/bin/printf '%s\n' "$PYTHON_RUNTIME_X86_64_SHA256" ;;
        *) return 1 ;;
    esac
}
python_runtime_archive_url() {
    local archive_name
    archive_name="$(python_runtime_archive_name "$1")" || return 1
    # GitHub's asset path encodes the '+' in the immutable CPython build id.
    archive_name="${archive_name/+/%2B}"
    /usr/bin/printf \
        'https://github.com/astral-sh/python-build-standalone/releases/download/%s/%s\n' \
        "$PYTHON_RUNTIME_RELEASE" "$archive_name"
}

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
backup_recovery_status=0
build_support_reconcile_app_backup \
    "$BUILD_DIR" "$FINAL_APP_DIR" "$APP_NAME" "$build_identity" \
    "$current_uid" "$KEEP_PREVIOUS_APP" app_bundle_is_expected \
    || backup_recovery_status=$?
if [[ "$backup_recovery_status" -ne 0 ]]; then
    /usr/bin/printf 'ERROR: interrupted app backup is ambiguous or changed; preserving it for manual review.\n' >&2
    exit "$backup_recovery_status"
fi
preserved_backup_container="$BUILD_SUPPORT_PRESERVED_BACKUP"
if [[ "$BUILD_SUPPORT_BACKUP_RECOVERED" == "1" ]]; then
    /usr/bin/printf 'Recovered the previous app after an interrupted replacement.\n'
fi
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

PYTHON_RUNTIME_CACHE="$BUILD_DIR/.python-runtime-cache"
if ! create_build_directory_without_symlinks "$BUILD_DIR" "$PYTHON_RUNTIME_CACHE"; then
    /usr/bin/printf 'ERROR: cannot establish the pinned Python runtime cache.\n' >&2
    exit 1
fi
runtime_cache_allowlist=()
for architecture in "${architectures[@]}"; do
    runtime_cache_allowlist+=("$(python_runtime_archive_name "$architecture")")
done
if ! build_support_prune_runtime_cache \
    "$PYTHON_RUNTIME_CACHE" "$current_uid" "${runtime_cache_allowlist[@]}"; then
    /usr/bin/printf 'ERROR: cannot safely prune old pinned Python runtime caches.\n' >&2
    exit 1
fi

binary_staging=""
app_staging=""
cleanup() {
    if [[ -n "$binary_staging" && ( -e "$binary_staging" || -L "$binary_staging" ) ]]; then
        build_support_remove_staging_directory \
            "$binary_staging" "$user_temp" "pch-swift-binaries" \
            "$build_identity" "$current_uid" \
            || /usr/bin/printf 'WARNING: preserving changed binary staging for review: %s\n' \
                "$binary_staging" >&2
    fi
    if [[ -n "$app_staging" && ( -e "$app_staging" || -L "$app_staging" ) ]]; then
        build_support_remove_staging_directory \
            "$app_staging" "$BUILD_DIR" ".pch-app-staging" \
            "$build_identity" "$current_uid" \
            || /usr/bin/printf 'WARNING: preserving changed app staging for review: %s\n' \
                "$app_staging" >&2
    fi
}
trap cleanup EXIT
binary_staging="$(build_support_create_staging_directory \
    "$user_temp" "pch-swift-binaries" "$build_identity" "$current_uid")"
app_staging="$(build_support_create_staging_directory \
    "$BUILD_DIR" ".pch-app-staging" "$build_identity" "$current_uid")"
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
# `bin/modore`, its `scripts/bounded_exec.py` timeout wrapper, and
# `skills/modore-ops/` are source-checkout surfaces. The app neither installs
# that command nor loads agent skills, so those files intentionally stay out of
# this sealed runtime manifest.
RUNTIME_FILES=(
    "scripts/scanner.sh"
    "scripts/cleanup.sh"
    "scripts/storage_watch.sh"
    "scripts/schedule.sh"
    "scripts/scree.py"
    "scripts/report.jxa.js"
    "scripts/scanner_helper.jxa.js"
    "scripts/idle_cpu.sh"
    "scripts/network_watch.sh"
    "scripts/login_items.sh"
    "scripts/modules/support_dir.sh"
    "scripts/modules/approval_token.sh"
    "scripts/modules/macos/cpu.sh"
    "scripts/modules/macos/network.sh"
    "scripts/modules/macos/autoruns.sh"
    "scripts/modules/macos/security.sh"
    "scripts/modules/macos/storage.sh"
    "scripts/modules/macos/idle_cpu.sh"
    "scripts/modules/macos/privacy.sh"
    "scripts/modules/macos/devtool_updates.sh"
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

# Work/session continuity is a shipping app feature, so it cannot borrow
# `/usr/bin/python3` from Xcode or a package manager on the user's machine.
# Assemble one relocatable, stdlib-only CPython helper from immutable
# python-build-standalone archives. The executable is the only nested Mach-O;
# build tools, pip, headers, Tk, site-packages, and extension bundles are not
# shipped. A native app fetches one architecture; Universal 2 fetches both and
# lipos the statically linked interpreter while sharing the pure-Python stdlib.
PYTHON_RUNTIME_DIR="$APP_DIR/Contents/Resources/modore-python"
PYTHON_RUNTIME_EXECUTABLE="$PYTHON_RUNTIME_DIR/bin/python3.11"
/bin/mkdir -p "$PYTHON_RUNTIME_DIR/bin"
python_stdlib_copied=0

for architecture in "${architectures[@]}"; do
    archive_name="$(python_runtime_archive_name "$architecture")"
    archive_sha256="$(python_runtime_archive_sha256 "$architecture")"
    archive_url="$(python_runtime_archive_url "$architecture")"
    cached_archive="$PYTHON_RUNTIME_CACHE/$archive_name"
    if [[ -e "$cached_archive" || -L "$cached_archive" ]]; then
        if [[ ! -f "$cached_archive" || -L "$cached_archive" ]]; then
            /usr/bin/printf 'ERROR: cached Python runtime is not a regular file: %s\n' \
                "$cached_archive" >&2
            exit 1
        fi
        actual_archive_sha256="$(run_clean /usr/bin/shasum -a 256 "$cached_archive" \
            | /usr/bin/awk '{print $1}')"
        if [[ "$actual_archive_sha256" != "$archive_sha256" ]]; then
            /usr/bin/printf 'ERROR: cached Python runtime checksum mismatch: %s\n' \
                "$cached_archive" >&2
            exit 1
        fi
    else
        downloaded_archive="$binary_staging/$archive_name.download"
        /usr/bin/printf 'Fetching pinned CPython runtime for %s...\n' "$architecture"
        if ! build_support_download \
            "$account_home" "$user_temp" "$downloaded_archive" "$archive_url" \
            20 300 240 30 1024 360 "$PYTHON_RUNTIME_MAX_ARCHIVE_BYTES"; then
            /usr/bin/printf 'ERROR: pinned CPython download exceeded its bounds or failed.\n' >&2
            exit 1
        fi
        actual_archive_sha256="$(run_clean /usr/bin/shasum -a 256 "$downloaded_archive" \
            | /usr/bin/awk '{print $1}')"
        if [[ "$actual_archive_sha256" != "$archive_sha256" ]]; then
            /usr/bin/printf 'ERROR: downloaded Python runtime checksum mismatch for %s.\n' \
                "$architecture" >&2
            exit 1
        fi
        /bin/mv "$downloaded_archive" "$cached_archive"
    fi

    archive_entries="$binary_staging/python-runtime-$architecture.entries"
    run_clean /usr/bin/tar -tzf "$cached_archive" > "$archive_entries"
    if ! /usr/bin/awk '
        BEGIN { bad = 0; seen = 0 }
        {
            seen = 1
            if ($0 !~ /^python\// || $0 ~ /(^|\/)\.\.(\/|$)/ || index($0, "\\") != 0) {
                bad = 1
            }
        }
        END { exit(!seen || bad) }
    ' "$archive_entries"; then
        /usr/bin/printf 'ERROR: pinned Python archive contains an unsafe path.\n' >&2
        exit 1
    fi
    archive_types="$binary_staging/python-runtime-$architecture.types"
    run_clean /usr/bin/tar -tvzf "$cached_archive" > "$archive_types"
    if ! /usr/bin/awk '
        BEGIN { bad = 0; binary = 0; stdlib = 0 }
        {
            selected = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "python/bin/python3.11") { binary = 1; selected = 1 }
                if ($i ~ /^python\/lib\/python3\.11(\/|$)/) { stdlib = 1; selected = 1 }
            }
            type = substr($1, 1, 1)
            if (selected && type != "-" && type != "d") { bad = 1 }
        }
        END { exit(bad || !binary || !stdlib) }
    ' "$archive_types"; then
        /usr/bin/printf 'ERROR: selected Python runtime payload contains a link or special file.\n' >&2
        exit 1
    fi

    extracted_runtime="$binary_staging/python-runtime-$architecture"
    /bin/mkdir "$extracted_runtime"
    run_clean /usr/bin/tar -xzf "$cached_archive" -C "$extracted_runtime" \
        python/bin/python3.11 python/lib/python3.11
    source_python="$extracted_runtime/python/bin/python3.11"
    source_stdlib="$extracted_runtime/python/lib/python3.11"
    if [[ ! -f "$source_python" || -L "$source_python" || ! -x "$source_python" \
        || ! -d "$source_stdlib" || -L "$source_stdlib" ]]; then
        /usr/bin/printf 'ERROR: pinned Python archive has an unexpected layout.\n' >&2
        exit 1
    fi
    if /usr/bin/find "$source_stdlib" -type l -print -quit | /usr/bin/grep -q .; then
        /usr/bin/printf 'ERROR: pinned Python stdlib contains an unexpected symlink.\n' >&2
        exit 1
    fi
    /bin/cp "$source_python" "$binary_staging/modore-python-$architecture"

    if [[ "$python_stdlib_copied" == "0" ]]; then
        /usr/bin/ditto --norsrc --noextattr --noacl \
            "$source_stdlib" "$PYTHON_RUNTIME_DIR/lib/python3.11"
        for excluded in \
            asyncio distutils email ensurepip http idlelib lib-dynload lib2to3 \
            multiprocessing pydoc_data site-packages tkinter turtledemo unittest venv xml xmlrpc; do
            /bin/rm -rf "$PYTHON_RUNTIME_DIR/lib/python3.11/$excluded"
        done
        # CPython's path bootstrap expects the platform-library directory to
        # exist even when this stdlib-only runtime deliberately ships no
        # extension modules. Without it every invocation writes a warning to
        # stderr; Modore captures stdout and stderr together, so that warning
        # would corrupt otherwise valid JSON responses from scree.
        /bin/mkdir -p "$PYTHON_RUNTIME_DIR/lib/python3.11/lib-dynload"
        /usr/bin/printf '%s\n' \
            'Optional CPython extension modules are intentionally not bundled.' \
            > "$PYTHON_RUNTIME_DIR/lib/python3.11/lib-dynload/README.txt"
        /bin/rm -rf "$PYTHON_RUNTIME_DIR/lib/python3.11/config-3.11-darwin"
        /bin/rm -f "$PYTHON_RUNTIME_DIR/lib/python3.11/_sysconfigdata__darwin_darwin.py"
        /usr/bin/find "$PYTHON_RUNTIME_DIR/lib/python3.11" \
            \( -name '__pycache__' -o -name '*.pyc' -o -name '*.pyo' \) -delete
        python_stdlib_copied=1
    fi
done

if [[ "${#architectures[@]}" -eq 1 ]]; then
    /bin/cp "$binary_staging/modore-python-${architectures[0]}" \
        "$PYTHON_RUNTIME_EXECUTABLE"
else
    run_clean /usr/bin/xcrun lipo -create \
        "$binary_staging/modore-python-arm64" \
        "$binary_staging/modore-python-x86_64" \
        -output "$PYTHON_RUNTIME_EXECUTABLE"
fi
/bin/chmod +x "$PYTHON_RUNTIME_EXECUTABLE"
/usr/bin/printf '%s\n%s%s\n%s\n%s  arm64\n%s  x86_64\n' \
    'Modore embedded Python runtime' \
    'Version: ' "$PYTHON_RUNTIME_VERSION" \
    'Source: https://github.com/astral-sh/python-build-standalone' \
    "$PYTHON_RUNTIME_ARM64_SHA256" \
    "$PYTHON_RUNTIME_X86_64_SHA256" \
    > "$PYTHON_RUNTIME_DIR/ORIGIN.txt"

python_runtime_architectures="$(run_clean /usr/bin/xcrun lipo -archs \
    "$PYTHON_RUNTIME_EXECUTABLE")"
for architecture in "${architectures[@]}"; do
    if [[ " $python_runtime_architectures " != *" $architecture "* ]]; then
        /usr/bin/printf 'ERROR: embedded Python runtime is missing %s.\n' "$architecture" >&2
        exit 1
    fi
    python_runtime_minimum="$(run_clean /usr/bin/xcrun vtool -show-build \
        -arch "$architecture" "$PYTHON_RUNTIME_EXECUTABLE" \
        | /usr/bin/awk '$1 == "minos" {print $2; exit}')"
    if [[ ! "$python_runtime_minimum" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        /usr/bin/printf 'ERROR: embedded Python runtime has no valid macOS minimum.\n' >&2
        exit 1
    fi
    if ! /usr/bin/awk -v actual="$python_runtime_minimum" -v maximum="$MINIMUM_SYSTEM_VERSION" '
        BEGIN {
            split(actual, a, "."); split(maximum, m, ".")
            exit((a[1] + 0 < m[1] + 0) ||
                 (a[1] + 0 == m[1] + 0 && a[2] + 0 <= m[2] + 0) ? 0 : 1)
        }
    '; then
        /usr/bin/printf 'ERROR: embedded Python runtime requires macOS %s (app minimum %s).\n' \
            "${python_runtime_minimum:-unknown}" "$MINIMUM_SYSTEM_VERSION" >&2
        exit 1
    fi
done

# This smoke runs with no package-manager Python and with import isolation.
# If pruning removed a transitive stdlib dependency, or CPython writes a path
# warning that would corrupt LocalProcessRunner's combined JSON stream, the app
# build stops here.
python_smoke_stdout="$binary_staging/python-smoke.stdout"
python_smoke_stderr="$binary_staging/python-smoke.stderr"
python_smoke_status=0
run_clean "$PYTHON_RUNTIME_EXECUTABLE" -I -B \
    "$RUNTIME_DIR/scripts/scree.py" --help \
    > "$python_smoke_stdout" 2> "$python_smoke_stderr" \
    || python_smoke_status=$?
if [[ "$python_smoke_status" -ne 0 || ! -s "$python_smoke_stdout" \
    || -s "$python_smoke_stderr" ]]; then
    /usr/bin/printf 'ERROR: embedded Python smoke failed (exit %s).\n' \
        "$python_smoke_status" >&2
    if [[ -s "$python_smoke_stderr" ]]; then
        /usr/bin/head -c 4096 "$python_smoke_stderr" >&2
        /usr/bin/printf '\n' >&2
    fi
    exit 1
fi

# Exercise the shipped session index, not only argparse startup. An empty,
# private home keeps the build from reading the builder's real conversations
# while still importing and running the collectors used by the app.
python_sessions_home="$binary_staging/python-sessions-home"
python_sessions_stdout="$binary_staging/python-sessions.stdout"
python_sessions_stderr="$binary_staging/python-sessions.stderr"
/bin/mkdir -m 700 "$python_sessions_home"
python_sessions_status=0
run_clean "$PYTHON_RUNTIME_EXECUTABLE" -I -B \
    "$RUNTIME_DIR/scripts/scree.py" sessions --limit 1 --home "$python_sessions_home" \
    > "$python_sessions_stdout" 2> "$python_sessions_stderr" \
    || python_sessions_status=$?
if [[ "$python_sessions_status" -ne 0 || ! -s "$python_sessions_stdout" \
    || -s "$python_sessions_stderr" ]]; then
    /usr/bin/printf 'ERROR: embedded Python session-index smoke failed (exit %s).\n' \
        "$python_sessions_status" >&2
    if [[ -s "$python_sessions_stderr" ]]; then
        /usr/bin/head -c 4096 "$python_sessions_stderr" >&2
        /usr/bin/printf '\n' >&2
    fi
    exit 1
fi
if ! run_clean "$PYTHON_RUNTIME_EXECUTABLE" -I -B -c \
    'import json,sys; p=json.load(open(sys.argv[1], encoding="utf-8")); assert p["total"] == 0 and p["sessions"] == [] and p["coverage"]["complete"] is True' \
    "$python_sessions_stdout"; then
    /usr/bin/printf 'ERROR: embedded Python session-index smoke returned an invalid payload.\n' >&2
    exit 1
fi

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
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Modore" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Modore" "$APP_DIR/Contents/Info.plist"
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
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string $IDENTIFIER" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string modore" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleTypeRole string Viewer" "$APP_DIR/Contents/Info.plist"

# Release payloads must not inherit Finder metadata, quarantine data, resource
# forks, ACLs, or credentials hidden in extended attributes from the checkout.
/usr/bin/xattr -cr "$APP_DIR"
/bin/chmod -RN "$APP_DIR"

generate_python_runtime_manifest() {
    local destination temporary_manifest
    destination="$PYTHON_RUNTIME_DIR/RUNTIME-MANIFEST.sha256"
    temporary_manifest="$binary_staging/python-runtime-manifest.sha256"
    (
        cd "$PYTHON_RUNTIME_DIR"
        /usr/bin/find . -type f ! -name './RUNTIME-MANIFEST.sha256' \
            | LC_ALL=C /usr/bin/sort \
            | while IFS= read -r relative_path; do
                run_clean /usr/bin/shasum -a 256 "$relative_path"
            done
    ) > "$temporary_manifest"
    /bin/mv "$temporary_manifest" "$destination"
}

if [[ "${PCH_SKIP_ADHOC_SIGN:-0}" != "1" ]]; then
    # Sign nested code inside-out. `--deep` remains verification-only; using it
    # to sign would hide which executable the release actually authorizes.
    run_clean /usr/bin/codesign --force --sign - "$PYTHON_RUNTIME_EXECUTABLE" >/dev/null
    generate_python_runtime_manifest
    run_clean /usr/bin/codesign --force --sign - "$APP_DIR" >/dev/null
else
    generate_python_runtime_manifest
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
    if [[ -n "$preserved_backup_container" ]]; then
        if ! build_support_retire_preserved_backup \
            "$preserved_backup_container" "$BUILD_DIR" "$APP_NAME" \
            "$build_identity" "$current_uid" app_bundle_is_expected; then
            /usr/bin/printf 'ERROR: preserved app backup changed during the build; keeping it for manual review.\n' >&2
            exit 73
        fi
        preserved_backup_container=""
        /usr/bin/printf 'Removed the older preserved app backup before replacement.\n'
    fi
    backup_container="$(build_support_create_staging_directory \
        "$BUILD_DIR" ".pch-app-backup" "$build_identity" "$current_uid")"
    backup_app="$backup_container/$APP_NAME"
    if ! /bin/mv "$FINAL_APP_DIR" "$backup_app"; then
        build_support_remove_staging_directory \
            "$backup_container" "$BUILD_DIR" ".pch-app-backup" \
            "$build_identity" "$current_uid" 2>/dev/null || true
        exit 74
    fi
    if app_binary_is_running; then
        if /bin/mv "$backup_app" "$FINAL_APP_DIR"; then
            build_support_remove_staging_directory \
                "$backup_container" "$BUILD_DIR" ".pch-app-backup" \
                "$build_identity" "$current_uid" 2>/dev/null || true
        else
            /usr/bin/printf 'ERROR: previous app is preserved for manual recovery at: %s\n' "$backup_app" >&2
        fi
        /usr/bin/printf 'ERROR: the previous app started during bundle replacement; refusing to continue.\n' >&2
        exit 75
    fi
    if ! /bin/mv "$APP_DIR" "$FINAL_APP_DIR"; then
        if /bin/mv "$backup_app" "$FINAL_APP_DIR"; then
            build_support_remove_staging_directory \
                "$backup_container" "$BUILD_DIR" ".pch-app-backup" \
                "$build_identity" "$current_uid" 2>/dev/null || true
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
            build_support_remove_staging_directory \
                "$backup_container" "$BUILD_DIR" ".pch-app-backup" \
                "$build_identity" "$current_uid" 2>/dev/null || true
        else
            /usr/bin/printf 'ERROR: previous app is preserved for manual recovery at: %s\n' "$backup_app" >&2
        fi
        /usr/bin/printf 'ERROR: replacement app failed post-swap verification; previous app restored when possible.\n' >&2
        exit 74
    fi
    if [[ "$KEEP_PREVIOUS_APP" == "1" ]]; then
        /usr/bin/printf 'Previous app preserved for manual review: %s\n' "$backup_app"
    else
        if ! build_support_backup_container_has_exact_payload \
            "$backup_container" "$APP_NAME" \
            || ! app_bundle_is_expected "$backup_app" 1 \
            || ! build_support_remove_staging_directory \
                "$backup_container" "$BUILD_DIR" ".pch-app-backup" \
                "$build_identity" "$current_uid"; then
            /usr/bin/printf 'ERROR: previous app backup changed after replacement; preserving for manual review: %s\n' "$backup_app" >&2
            exit 73
        fi
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
