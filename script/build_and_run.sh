#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/build/macos/Modore.app"
INSTALL=0
case "${1:-}" in
  "") [[ "$#" == 0 ]] || exit 64 ;;
  --install) [[ "$#" == 1 ]] || exit 64; INSTALL=1 ;;
  *) echo "Usage: $0 [--install]" >&2; exit 64 ;;
esac

stop_running_app() {
if /usr/bin/pgrep -x Modore >/dev/null 2>&1; then
  /usr/bin/xcrun swift - <<'SWIFT'
import AppKit
for app in NSRunningApplication.runningApplications(withBundleIdentifier: "me.heznpc.modore") {
    _ = app.terminate()
}
SWIFT
  for _ in {1..50}; do
    /usr/bin/pgrep -x Modore >/dev/null 2>&1 || break
    /bin/sleep 0.1
  done
fi
if /usr/bin/pgrep -x Modore >/dev/null 2>&1; then
  echo "Modore is still running; refusing to replace its bundle." >&2
  exit 75
fi
}
stop_running_app

PCH_BUILD_DIR="$ROOT_DIR/build/macos" "$ROOT_DIR/scripts/build_macos_swift_app.sh"
if [[ "$INSTALL" == 1 ]]; then
  # Keep the background watch on the user's stable installed bundle path.
  # Validate a complete staged copy before replacing it; app data and AI hook
  # configuration are outside this transaction and are never modified here.
  destination="$HOME/Applications/Modore.app"
  parent="$(dirname "$destination")"
  [[ -d "$parent" && ! -L "$parent" && ! -L "$destination" ]] || {
    echo "The existing user Applications directory must not be a symlink." >&2; exit 1;
  }
  if [[ -e "$destination" ]]; then
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$destination/Contents/Info.plist")" == me.heznpc.modore ]] || exit 1
  fi
  if /usr/bin/pgrep -x Modore >/dev/null 2>&1; then
    echo "Modore started during the build; preserving both bundles without replacing the running app." >&2
    exit 75
  fi
  staging="$(/usr/bin/mktemp -d "$parent/.modore-install.XXXXXX")"
  /usr/bin/ditto "$APP" "$staging/Modore.app"
  /usr/bin/codesign --verify --strict "$staging/Modore.app"
  /usr/bin/cmp "$APP/Contents/MacOS/Modore" "$staging/Modore.app/Contents/MacOS/Modore"
  [[ ! -e "$destination" ]] || /bin/mv "$destination" "$staging/previous.app"
  if ! /bin/mv "$staging/Modore.app" "$destination"; then
    [[ ! -d "$staging/previous.app" ]] || /bin/mv "$staging/previous.app" "$destination"
    echo "Install failed; previous app restored. Staging: $staging" >&2
    exit 1
  fi
  /usr/bin/codesign --verify --strict "$destination"
  /bin/rm -rf "$staging"
  APP="$destination"
fi
# A parallel task or the user may reopen an installed copy during compilation.
# Release its singleton lease immediately before launching this exact build.
stop_running_app
/usr/bin/open -n "$APP"
/bin/sleep 1
for _ in {1..50}; do
  if /bin/ps -axo comm= | /usr/bin/awk -v target="$APP/Contents/MacOS/Modore" \
      'BEGIN { found = 0 } $0 == target { found = 1 } END { exit(found ? 0 : 1) }'; then
    /usr/bin/plutil -p "$APP/Contents/Info.plist" | /usr/bin/grep -E 'Modore(BuildDate|SourceDigest)|CFBundleShortVersionString' || true
    exit 0
  fi
  /bin/sleep 0.1
done
echo "The newly built Modore bundle did not start: $APP" >&2
exit 1
