#!/bin/bash
# Build a standalone Mac app and optionally produce a Developer ID notarized DMG.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PC Health Check Mac.app"
APP_DIR="$ROOT_DIR/build/macos/$APP_NAME"
VERSION="${PCH_APP_VERSION:-0.3.0}"
DIST_DIR="${PCH_DISTRIBUTION_DIR:-$ROOT_DIR/dist}"
DMG_PATH="$DIST_DIR/PC-Health-Check-Mac-v$VERSION.dmg"
MODE="distribution"
SKIP_NOTARIZATION=0

usage() {
    /usr/bin/printf '%s\n' \
        "Usage: scripts/package_macos_release.sh [--check|--local|--skip-notarization]" \
        "" \
        "  --check              Inspect local distribution prerequisites only." \
        "  --local              Build an ad-hoc signed standalone DMG for local testing." \
        "  --skip-notarization  Developer ID sign the app and DMG without notarizing." \
        "" \
        "Distribution environment:" \
        "  PCH_CODESIGN_IDENTITY  Developer ID Application identity." \
        "  PCH_NOTARY_PROFILE     notarytool Keychain profile name." \
        "  PCH_APP_VERSION        Bundle/release version (default: 0.3.0)."
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

if [[ "$(/usr/bin/uname)" != "Darwin" ]]; then
    /usr/bin/printf 'ERROR: macOS packaging requires macOS.\n' >&2
    exit 1
fi

required_commands=(swift codesign hdiutil ditto shasum)
for command_name in "${required_commands[@]}"; do
    if ! /usr/bin/command -v "$command_name" >/dev/null 2>&1; then
        /usr/bin/printf 'ERROR: required command missing: %s\n' "$command_name" >&2
        exit 1
    fi
done

if [[ "$MODE" == "check" ]]; then
    identity_count="$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null | /usr/bin/grep -c 'Developer ID Application' || true)"
    /usr/bin/printf 'mode\tcheck\n'
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
    if [[ -z "$identity" ]]; then
        /usr/bin/printf 'ERROR: PCH_CODESIGN_IDENTITY is required for distribution.\n' >&2
        exit 2
    fi
    if ! /usr/bin/security find-identity -p codesigning -v | /usr/bin/grep -F "$identity" >/dev/null 2>&1; then
        /usr/bin/printf 'ERROR: configured signing identity is not available in Keychain.\n' >&2
        exit 2
    fi
    if [[ "$SKIP_NOTARIZATION" != "1" && -z "$notary_profile" ]]; then
        /usr/bin/printf 'ERROR: PCH_NOTARY_PROFILE is required unless --skip-notarization is explicit.\n' >&2
        exit 2
    fi
fi

if [[ "$MODE" == "local" ]]; then
    PCH_APP_VERSION="$VERSION" PCH_STANDALONE_BUNDLE=1 \
        "$ROOT_DIR/scripts/build_macos_swift_app.sh"
else
    PCH_APP_VERSION="$VERSION" PCH_STANDALONE_BUNDLE=1 PCH_SKIP_ADHOC_SIGN=1 \
        "$ROOT_DIR/scripts/build_macos_swift_app.sh"
    /usr/bin/codesign \
        --force \
        --strict \
        --options runtime \
        --timestamp \
        --sign "$identity" \
        "$APP_DIR"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
if [[ -f "$APP_DIR/Contents/Resources/project-root.txt" ]]; then
    /usr/bin/printf 'ERROR: standalone app leaked a local project-root marker.\n' >&2
    exit 3
fi
if [[ ! -x "$APP_DIR/Contents/Resources/runtime/scripts/scanner.sh" ]]; then
    /usr/bin/printf 'ERROR: standalone runtime scanner is missing.\n' >&2
    exit 3
fi

/bin/mkdir -p "$DIST_DIR"
staging_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/pch-dmg.XXXXXX")"
trap '/bin/rm -rf "$staging_dir"' EXIT
/usr/bin/ditto "$APP_DIR" "$staging_dir/$APP_NAME"
/bin/ln -s /Applications "$staging_dir/Applications"
/bin/rm -f "$DMG_PATH"
/usr/bin/hdiutil create \
    -volname "PC Health Check Mac" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

if [[ "$MODE" == "distribution" ]]; then
    /usr/bin/codesign --force --timestamp --sign "$identity" "$DMG_PATH"
    if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
        /usr/bin/xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$notary_profile" \
            --wait
        /usr/bin/xcrun stapler staple "$DMG_PATH"
        /usr/bin/xcrun stapler validate "$DMG_PATH"
        /usr/sbin/spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH"
    fi
fi

sha256="$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')"
/usr/bin/printf 'mode\t%s\n' "$MODE"
/usr/bin/printf 'dmg\t%s\n' "$DMG_PATH"
/usr/bin/printf 'sha256\t%s\n' "$sha256"
