#!/bin/bash
# Build and verify a standalone Mac app. Distribution mode is tag/sign/notary gated.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PC Health Check Mac.app"
VERSION="${PCH_APP_VERSION:-0.3.0}"
MINIMUM_SYSTEM_VERSION="${PCH_MINIMUM_SYSTEM_VERSION:-13.0}"
ARCH_REQUEST="${PCH_BUILD_ARCHS:-universal}"
DIST_DIR="${PCH_DISTRIBUTION_DIR:-$ROOT_DIR/dist}"
MODE="distribution"
SKIP_NOTARIZATION=0

usage() {
    /usr/bin/printf '%s\n' \
        "Usage: scripts/package_macos_release.sh [--check|--local|--skip-notarization]" \
        "" \
        "  --check              Report prerequisites and release-gate state; do not build." \
        "  --local              Build an ad-hoc signed DMG under dist/local/." \
        "  --skip-notarization  Build a signed, explicitly non-publishable smoke artifact." \
        "" \
        "Distribution environment:" \
        "  PCH_CODESIGN_IDENTITY       Developer ID Application identity." \
        "  PCH_NOTARY_PROFILE          notarytool Keychain profile name." \
        "  PCH_APP_VERSION             Version whose v<version> tag must point at HEAD." \
        "  PCH_BUILD_ARCHS             universal (default), arm64, or x86_64." \
        "  PCH_MINIMUM_SYSTEM_VERSION  Deployment target (default: 13.0)."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) MODE="check" ;;
        --local) MODE="local" ;;
        --skip-notarization) SKIP_NOTARIZATION=1 ;;
        -h|--help) usage; exit 0 ;;
        *)
            /usr/bin/printf 'ERROR: unknown option: %s\n' "$1" >&2
            usage >&2
            exit 64
            ;;
    esac
    shift
done

if [[ "$MODE" == "local" && "$SKIP_NOTARIZATION" == "1" ]]; then
    /usr/bin/printf 'ERROR: --local is already unsigned for distribution; do not combine it with --skip-notarization.\n' >&2
    exit 64
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    /usr/bin/printf 'ERROR: PCH_APP_VERSION must be a numeric X.Y.Z version: %s\n' "$VERSION" >&2
    exit 64
fi
if [[ "$(/usr/bin/uname)" != "Darwin" ]]; then
    /usr/bin/printf 'ERROR: macOS packaging requires macOS.\n' >&2
    exit 1
fi

required_commands=(swift codesign hdiutil ditto shasum python3 xcrun plutil tar)
for command_name in "${required_commands[@]}"; do
    if ! /usr/bin/command -v "$command_name" >/dev/null 2>&1; then
        /usr/bin/printf 'ERROR: required command missing: %s\n' "$command_name" >&2
        exit 1
    fi
done

expected_tag="v$VERSION"
if /usr/bin/command -v git >/dev/null 2>&1 \
    && /usr/bin/git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_repository=true
    head_commit="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)"
    short_commit="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"
    if [[ -z "$(/usr/bin/git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]]; then
        git_clean=true
    else
        git_clean=false
    fi
    tag_at_head="$(/usr/bin/git -C "$ROOT_DIR" tag --points-at HEAD | /usr/bin/awk -v tag="$expected_tag" '$0 == tag {print; exit}')"
else
    git_repository=false
    head_commit=""
    short_commit="source"
    git_clean=false
    tag_at_head=""
fi

if [[ "$MODE" == "check" ]]; then
    identity_count="$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null | /usr/bin/grep -c 'Developer ID Application' || true)"
    /usr/bin/printf 'mode\tcheck\n'
    /usr/bin/printf 'version\t%s\n' "$VERSION"
    /usr/bin/printf 'expectedTag\t%s\n' "$expected_tag"
    /usr/bin/printf 'gitRepository\t%s\n' "$git_repository"
    /usr/bin/printf 'tagAtHead\t%s\n' "$([[ -n "$tag_at_head" ]] && echo true || echo false)"
    /usr/bin/printf 'cleanWorktree\t%s\n' "$git_clean"
    /usr/bin/printf 'commit\t%s\n' "${head_commit:-unavailable}"
    /usr/bin/printf 'architectureRequest\t%s\n' "$ARCH_REQUEST"
    /usr/bin/printf 'minimumSystemVersion\t%s\n' "$MINIMUM_SYSTEM_VERSION"
    /usr/bin/printf 'developerIdIdentities\t%s\n' "$identity_count"
    /usr/bin/printf 'codesignIdentityConfigured\t%s\n' "$([[ -n "${PCH_CODESIGN_IDENTITY:-}" ]] && echo true || echo false)"
    /usr/bin/printf 'notaryProfileConfigured\t%s\n' "$([[ -n "${PCH_NOTARY_PROFILE:-}" ]] && echo true || echo false)"
    if /usr/bin/xcrun --find notarytool >/dev/null 2>&1; then
        /usr/bin/printf 'notarytool\tavailable\n'
    else
        /usr/bin/printf 'notarytool\tmissing\n'
    fi
    exit 0
fi

identity="${PCH_CODESIGN_IDENTITY:-}"
notary_profile="${PCH_NOTARY_PROFILE:-}"
if [[ "$MODE" == "distribution" ]]; then
    if [[ "$git_repository" != "true" ]]; then
        /usr/bin/printf 'ERROR: distribution requires a Git checkout for tag and commit verification.\n' >&2
        exit 2
    fi
    if [[ "$git_clean" != "true" ]]; then
        /usr/bin/printf 'ERROR: distribution requires a clean worktree and index.\n' >&2
        exit 2
    fi
    tagged_commit="$(/usr/bin/git -C "$ROOT_DIR" rev-parse "$expected_tag^{commit}" 2>/dev/null || true)"
    if [[ -z "$tag_at_head" || "$tagged_commit" != "$head_commit" ]]; then
        /usr/bin/printf 'ERROR: distribution requires tag %s to resolve exactly to HEAD.\n' "$expected_tag" >&2
        exit 2
    fi
    if [[ -z "$identity" ]]; then
        /usr/bin/printf 'ERROR: PCH_CODESIGN_IDENTITY is required for distribution.\n' >&2
        exit 2
    fi
    if ! /usr/bin/security find-identity -p codesigning -v | /usr/bin/grep -F "$identity" >/dev/null 2>&1; then
        /usr/bin/printf 'ERROR: configured signing identity is not available in Keychain.\n' >&2
        exit 2
    fi
    if [[ "$SKIP_NOTARIZATION" != "1" && -z "$notary_profile" ]]; then
        /usr/bin/printf 'ERROR: PCH_NOTARY_PROFILE is required for a publishable distribution.\n' >&2
        exit 2
    fi
fi

package_workspace="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pch-package.XXXXXX")"
artifact_workspace=""
mount_dir="$package_workspace/mounted"
mounted=false
cleanup() {
    if [[ "$mounted" == "true" ]]; then
        /usr/bin/hdiutil detach "$mount_dir" >/dev/null 2>&1 || true
    fi
    [[ -z "$artifact_workspace" ]] || /bin/rm -rf "$artifact_workspace"
    /bin/rm -rf "$package_workspace"
}
trap cleanup EXIT

BUILD_ROOT="$ROOT_DIR"
if [[ "$MODE" == "distribution" ]]; then
    source_archive="$package_workspace/source.tar"
    BUILD_ROOT="$package_workspace/source"
    /bin/mkdir -p "$BUILD_ROOT"
    /usr/bin/git -C "$ROOT_DIR" archive \
        --format=tar \
        --output="$source_archive" \
        "$head_commit"
    /usr/bin/tar -xf "$source_archive" -C "$BUILD_ROOT"
fi

PACKAGE_BUILD_DIR="$package_workspace/build"
APP_DIR="$PACKAGE_BUILD_DIR/$APP_NAME"
EXECUTABLE="$APP_DIR/Contents/MacOS/PCHealthCheckMac"
AUDIT_SCRIPT="$BUILD_ROOT/scripts/artifact_audit.py"
build_environment=(
    "PCH_APP_VERSION=$VERSION"
    "PCH_MINIMUM_SYSTEM_VERSION=$MINIMUM_SYSTEM_VERSION"
    "PCH_BUILD_ARCHS=$ARCH_REQUEST"
    "PCH_STRICT_BUILD=1"
    "PCH_BUILD_DIR=$PACKAGE_BUILD_DIR"
)
if [[ "$MODE" == "distribution" ]]; then
    build_environment+=("PCH_SKIP_ADHOC_SIGN=1")
fi
/usr/bin/env "${build_environment[@]}" "$BUILD_ROOT/scripts/build_macos_swift_app.sh"

if [[ "$MODE" == "distribution" ]]; then
    post_build_head="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)"
    post_build_status="$(/usr/bin/git -C "$ROOT_DIR" status --porcelain --untracked-files=all)"
    post_build_tag="$(/usr/bin/git -C "$ROOT_DIR" rev-parse "$expected_tag^{commit}" 2>/dev/null || true)"
    if [[ "$post_build_head" != "$head_commit" || -n "$post_build_status" \
        || "$post_build_tag" != "$head_commit" ]]; then
        /usr/bin/printf 'ERROR: source checkout changed while the distribution app was building.\n' >&2
        exit 2
    fi
fi

if [[ ! -x "$EXECUTABLE" ]]; then
    /usr/bin/printf 'ERROR: app executable is missing.\n' >&2
    exit 3
fi
bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist")"
bundle_version="$(/usr/bin/plutil -extract CFBundleVersion raw "$APP_DIR/Contents/Info.plist")"
bundle_short_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist")"
if [[ "$bundle_identifier" != "me.heznpc.pchealthcheck.mac" \
    || "$bundle_version" != "$VERSION" \
    || "$bundle_short_version" != "$VERSION" ]]; then
    /usr/bin/printf 'ERROR: app identity/version does not match the package request.\n' >&2
    exit 3
fi
if [[ -f "$APP_DIR/Contents/Resources/project-root.txt" ]]; then
    /usr/bin/printf 'ERROR: standalone app leaked a local project-root marker.\n' >&2
    exit 3
fi
if [[ ! -x "$APP_DIR/Contents/Resources/runtime/scripts/scanner.sh" ]]; then
    /usr/bin/printf 'ERROR: standalone runtime scanner is missing.\n' >&2
    exit 3
fi
if [[ -e "$APP_DIR/Contents/Resources/runtime/data/config.json" ]]; then
    /usr/bin/printf 'ERROR: standalone app must not bundle a user config.json.\n' >&2
    exit 3
fi
for required_resource in \
    "$APP_DIR/Contents/Resources/runtime/data/config.example.json" \
    "$APP_DIR/Contents/Resources/LICENSE" \
    "$APP_DIR/Contents/Resources/AppIcon.icns"; do
    if [[ ! -f "$required_resource" ]]; then
        /usr/bin/printf 'ERROR: required app resource missing: %s\n' "$required_resource" >&2
        exit 3
    fi
done

bundle_minimum="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$APP_DIR/Contents/Info.plist")"
if [[ "$bundle_minimum" != "$MINIMUM_SYSTEM_VERSION" ]]; then
    /usr/bin/printf 'ERROR: bundle minimum macOS %s does not match requested %s.\n' \
        "$bundle_minimum" "$MINIMUM_SYSTEM_VERSION" >&2
    exit 3
fi

actual_architectures="$(/usr/bin/xcrun lipo -archs "$EXECUTABLE")"
for architecture in $actual_architectures; do
    binary_minimum="$(/usr/bin/xcrun vtool -show-build -arch "$architecture" "$EXECUTABLE" | /usr/bin/awk '$1 == "minos" {print $2; exit}')"
    if [[ "$binary_minimum" != "$MINIMUM_SYSTEM_VERSION" ]]; then
        /usr/bin/printf 'ERROR: %s slice minimum macOS is %s, expected %s.\n' \
            "$architecture" "${binary_minimum:-unknown}" "$MINIMUM_SYSTEM_VERSION" >&2
        exit 3
    fi
done
if [[ "$actual_architectures" == *"arm64"* && "$actual_architectures" == *"x86_64"* ]]; then
    architecture_label="universal"
elif [[ "$actual_architectures" == "arm64" || "$actual_architectures" == "x86_64" ]]; then
    architecture_label="$actual_architectures"
else
    /usr/bin/printf 'ERROR: unexpected app architectures: %s\n' "$actual_architectures" >&2
    exit 3
fi
if [[ "$ARCH_REQUEST" == "universal" || "$ARCH_REQUEST" == "universal2" ]]; then
    if [[ "$architecture_label" != "universal" ]]; then
        /usr/bin/printf 'ERROR: Universal 2 was requested but the app has: %s\n' "$actual_architectures" >&2
        exit 3
    fi
fi

python3 "$AUDIT_SCRIPT" "$APP_DIR"

signature_kind="ad-hoc"
notarized=false
stapled=false
gatekeeper=false
if [[ "$MODE" == "distribution" ]]; then
    /usr/bin/codesign \
        --force \
        --strict \
        --options runtime \
        --timestamp \
        --sign "$identity" \
        "$APP_DIR"
    signature_kind="developer-id"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
python3 "$AUDIT_SCRIPT" "$APP_DIR"

if [[ "$MODE" == "local" ]]; then
    local_build_id="$short_commit"
    if [[ "$git_repository" == "true" && "$git_clean" != "true" ]]; then
        local_build_id="$local_build_id-dirty"
    fi
    output_dir="$DIST_DIR/local"
    artifact_name="PC-Health-Check-Mac-v$VERSION-local-unsigned-$architecture_label-$local_build_id.dmg"
elif [[ "$SKIP_NOTARIZATION" == "1" ]]; then
    output_dir="$DIST_DIR/local"
    artifact_name="PC-Health-Check-Mac-v$VERSION-signed-not-notarized-$architecture_label-$short_commit.dmg"
else
    output_dir="$DIST_DIR"
    artifact_name="PC-Health-Check-Mac-v$VERSION-$architecture_label.dmg"
fi
DMG_PATH="$output_dir/$artifact_name"
METADATA_PATH="$DMG_PATH.metadata.json"
/bin/mkdir -p "$output_dir"
if [[ -e "$DMG_PATH" || -L "$DMG_PATH" || -e "$METADATA_PATH" || -L "$METADATA_PATH" ]]; then
    /usr/bin/printf 'ERROR: refusing to overwrite an existing artifact: %s\n' "$DMG_PATH" >&2
    exit 4
fi

artifact_workspace="$(/usr/bin/mktemp -d "$output_dir/.pch-package.XXXXXX")"
WORK_DMG_PATH="$artifact_workspace/$artifact_name"
WORK_METADATA_PATH="$artifact_workspace/$artifact_name.metadata.json"
staging_dir="$package_workspace/dmg-staging"
/bin/mkdir -p "$staging_dir" "$mount_dir"

/usr/bin/ditto --norsrc --noextattr --noacl "$APP_DIR" "$staging_dir/$APP_NAME"
/bin/cp -X "$BUILD_ROOT/LICENSE" "$staging_dir/LICENSE"
/usr/bin/xattr -cr "$staging_dir"
/bin/chmod -RN "$staging_dir"
/bin/ln -s /Applications "$staging_dir/Applications"
python3 "$AUDIT_SCRIPT" --allow-symlink Applications "$staging_dir"

/usr/bin/hdiutil create \
    -volname "PC Health Check Mac" \
    -srcfolder "$staging_dir" \
    -format UDZO \
    "$WORK_DMG_PATH" >/dev/null

if [[ "$MODE" == "distribution" ]]; then
    /usr/bin/codesign --force --timestamp --sign "$identity" "$WORK_DMG_PATH"
    /usr/bin/codesign --verify --strict --verbose=2 "$WORK_DMG_PATH"
    if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
        /usr/bin/xcrun notarytool submit "$WORK_DMG_PATH" \
            --keychain-profile "$notary_profile" \
            --wait
        notarized=true
        /usr/bin/xcrun stapler staple "$WORK_DMG_PATH"
        /usr/bin/xcrun stapler validate "$WORK_DMG_PATH"
        stapled=true
        /usr/sbin/spctl --assess --type open --context context:primary-signature -vv "$WORK_DMG_PATH"
        gatekeeper=true
    fi
fi

/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$WORK_DMG_PATH" >/dev/null
mounted=true
python3 "$AUDIT_SCRIPT" --allow-symlink Applications "$mount_dir"
if [[ ! -f "$mount_dir/LICENSE" ]]; then
    /usr/bin/printf 'ERROR: mounted DMG is missing LICENSE.\n' >&2
    exit 5
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$mount_dir/$APP_NAME"
/usr/bin/hdiutil detach "$mount_dir" >/dev/null
mounted=false
/usr/bin/xattr -c "$WORK_DMG_PATH"
/bin/chmod -N "$WORK_DMG_PATH"

sha256="$(/usr/bin/shasum -a 256 "$WORK_DMG_PATH" | /usr/bin/awk '{print $1}')"
exact_tag="${tag_at_head:-}"
python3 - "$WORK_METADATA_PATH" "$artifact_name" "$VERSION" "$exact_tag" "$head_commit" \
    "$git_clean" "$actual_architectures" "$MINIMUM_SYSTEM_VERSION" "$signature_kind" \
    "$notarized" "$stapled" "$gatekeeper" "$sha256" <<'PY'
import json
import sys
from pathlib import Path

(
    output,
    artifact,
    version,
    tag,
    commit,
    clean,
    architectures,
    minimum_system_version,
    signature,
    notarized,
    stapled,
    gatekeeper,
    sha256,
) = sys.argv[1:]
payload = {
    "schemaVersion": 1,
    "product": "PC Health Check Mac",
    "brand": "Heznpc",
    "artifact": artifact,
    "version": version,
    "source": {
        "tag": tag or None,
        "commit": commit or None,
        "clean": clean == "true",
    },
    "platform": {
        "architectures": architectures.split(),
        "minimumSystemVersion": minimum_system_version,
    },
    "trust": {
        "signature": signature,
        "notarized": notarized == "true",
        "stapled": stapled == "true",
        "gatekeeperAssessed": gatekeeper == "true",
    },
    "audit": {
        "secretScan": True,
        "personalDataScan": True,
        "symlinkScan": True,
    },
    "sha256": sha256,
}
Path(output).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

/usr/bin/xattr -c "$WORK_METADATA_PATH"
/bin/chmod -N "$WORK_METADATA_PATH"
python3 "$AUDIT_SCRIPT" "$WORK_DMG_PATH" "$WORK_METADATA_PATH"
/bin/chmod 644 "$WORK_DMG_PATH" "$WORK_METADATA_PATH"

# Publish only fully verified artifacts. Hard links provide an atomic,
# same-filesystem O_EXCL boundary and cannot replace a file or symlink.
if ! /bin/ln "$WORK_DMG_PATH" "$DMG_PATH"; then
    /usr/bin/printf 'ERROR: artifact destination appeared during packaging: %s\n' "$DMG_PATH" >&2
    exit 4
fi
if ! /bin/ln "$WORK_METADATA_PATH" "$METADATA_PATH"; then
    if [[ "$DMG_PATH" -ef "$WORK_DMG_PATH" ]]; then
        /bin/rm -f "$DMG_PATH"
    fi
    /usr/bin/printf 'ERROR: metadata destination appeared during packaging: %s\n' "$METADATA_PATH" >&2
    exit 4
fi

/usr/bin/printf 'mode\t%s\n' "$MODE"
/usr/bin/printf 'dmg\t%s\n' "$DMG_PATH"
/usr/bin/printf 'metadata\t%s\n' "$METADATA_PATH"
/usr/bin/printf 'architectures\t%s\n' "$actual_architectures"
/usr/bin/printf 'minimumSystemVersion\t%s\n' "$MINIMUM_SYSTEM_VERSION"
/usr/bin/printf 'signature\t%s\n' "$signature_kind"
/usr/bin/printf 'notarized\t%s\n' "$notarized"
/usr/bin/printf 'sha256\t%s\n' "$sha256"
