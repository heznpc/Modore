#!/bin/bash
# Installs or removes the local hourly storage watch LaunchAgent.

set -u
set -o pipefail

LABEL="me.heznpc.pchealthcheck.storage-watch"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
WATCH_SCRIPT="$ROOT_DIR/scripts/storage_watch.sh"
HOME_ROOT="${HOME:-}"
OWNER_APPROVED="false"

if [[ "${PCH_TEST_MODE:-0}" == "1" && -n "${PCH_HOME_OVERRIDE:-}" ]]; then
    HOME_ROOT="$PCH_HOME_OVERRIDE"
fi
[[ -n "$HOME_ROOT" && "$HOME_ROOT" == /* && "$HOME_ROOT" != "/" ]] || exit 64
LAUNCH_AGENTS_DIR="${PCH_LAUNCH_AGENTS_DIR:-$HOME_ROOT/Library/LaunchAgents}"
STATE_DIR="${PCH_STATE_DIR:-$HOME_ROOT/Library/Application Support/PC Health Check}"
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
DOMAIN="gui/$(/usr/bin/id -u)"

emit() {
    /usr/bin/printf '%s\t%s\n' "$1" "${2:-}"
}

loaded() {
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        [[ -f "$STATE_DIR/.storage-watch-loaded" ]]
    else
        /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
    fi
}

status() {
    local enabled="false"
    [[ -f "$PLIST" ]] && loaded && enabled="true"
    emit "version" "1"
    emit "enabled" "$enabled"
    emit "plist" "$PLIST"
    emit "intervalSeconds" "3600"
}

require_approval() {
    [[ "$OWNER_APPROVED" == "true" ]] || {
        /usr/bin/printf 'ERROR: --owner-approved is required.\n' >&2
        exit 2
    }
}

install_agent() {
    require_approval
    /bin/mkdir -p "$LAUNCH_AGENTS_DIR" "$STATE_DIR" || exit 1
    /bin/chmod 700 "$STATE_DIR" 2>/dev/null || true
    local temporary="$STATE_DIR/$LABEL.$$.plist"
    /usr/bin/plutil -create xml1 "$temporary" || exit 1
    /usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$temporary" || exit 1
    /usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$temporary" || exit 1
    /usr/libexec/PlistBuddy -c 'Add :ProgramArguments:0 string /bin/bash' "$temporary" || exit 1
    /usr/libexec/PlistBuddy -c "Add :ProgramArguments:1 string $WATCH_SCRIPT" "$temporary" || exit 1
    /usr/libexec/PlistBuddy -c 'Add :StartInterval integer 3600' "$temporary" || exit 1
    /usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$temporary" || exit 1
    /usr/libexec/PlistBuddy -c "Add :StandardOutPath string $STATE_DIR/storage-watch.log" "$temporary" || exit 1
    /usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $STATE_DIR/storage-watch.error.log" "$temporary" || exit 1
    /bin/chmod 600 "$temporary"
    /bin/mv "$temporary" "$PLIST" || exit 1

    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        : > "$STATE_DIR/.storage-watch-loaded"
    else
        /bin/launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
        /bin/launchctl bootstrap "$DOMAIN" "$PLIST" || exit 1
    fi
    status
}

uninstall_agent() {
    require_approval
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        /bin/rm -f "$STATE_DIR/.storage-watch-loaded"
    else
        /bin/launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
    fi
    /bin/rm -f "$PLIST"
    status
}

COMMAND="${1:---status}"
shift || true
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --owner-approved) OWNER_APPROVED="true" ;;
        *) /usr/bin/printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 64 ;;
    esac
    shift
done

case "$COMMAND" in
    --status) status ;;
    --install) install_agent ;;
    --uninstall) uninstall_agent ;;
    *) /usr/bin/printf 'ERROR: use --status, --install, or --uninstall.\n' >&2; exit 64 ;;
esac
