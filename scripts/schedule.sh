#!/bin/bash -p
# Installs or removes the local hourly storage watch LaunchAgent.

set -u
set -o pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

# shellcheck source=scripts/modules/support_dir.sh
source "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/modules/support_dir.sh"

LABEL="me.heznpc.modore.storage-watch"
# 이름이 바뀌기 전에 설치된 에이전트는 옛 라벨로 계속 로드된 상태로 남는다.
# 정리하지 않으면 시간당 감시가 두 벌 돌고, --status와 --uninstall이 옛 쪽을
# 보지 못한다.
LEGACY_LABEL="me.heznpc.pchealthcheck.storage-watch"
ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
WATCH_SCRIPT="${PCH_STORAGE_WATCH_SCRIPT:-$ROOT_DIR/scripts/storage_watch.sh}"
# Optional: the running app's own bundle path, so the scheduled watch can launch
# it to post a notification under its own identity instead of an Apple binary's.
# Empty is a fully supported value (osascript-only, today's behavior).
APP_BUNDLE_PATH="${PCH_STORAGE_WATCH_APP_BUNDLE:-}"
HOME_ROOT=""
OWNER_APPROVED="false"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
SAFE_LOCALE="en_US.UTF-8"
# shellcheck disable=SC2016 # The loaded LaunchAgent shell expands these later.
WATCH_WRAPPER='set -u; script="$2"; expected="$1"; [[ -f "$script" && ! -L "$script" ]] || exit 78; size=$(/usr/bin/stat -f "%z" "$script") || exit 78; [[ "$size" -le 1048576 ]] || exit 78; payload=$(/usr/bin/base64 < "$script") || exit 78; digest=$(/usr/bin/printf "%s" "$payload" | /usr/bin/base64 -D | /usr/bin/shasum -a 256) || exit 78; actual="${digest%% *}"; [[ "$actual" == "$expected" ]] || exit 78; /usr/bin/printf "%s" "$payload" | /usr/bin/base64 -D | /bin/bash -p'
WATCH_HASH="${PCH_STORAGE_WATCH_SHA256:-}"
if [[ -z "$WATCH_HASH" ]]; then
    WATCH_HASH="$(/usr/bin/shasum -a 256 "$WATCH_SCRIPT" 2>/dev/null \
        | /usr/bin/awk '{print $1; exit}')"
fi
[[ "$WATCH_HASH" =~ ^[0-9a-f]{64}$ ]] || exit 78

account_home_for_current_uid() {
    local uid
    uid="$(/usr/bin/id -u)" || return 1
    /usr/bin/dscacheutil -q user -a uid "$uid" 2>/dev/null \
        | /usr/bin/awk '$1 == "dir:" {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}'
}

ensure_directory() {
    local directory="$1"
    local parent permissions
    if [[ -e "$directory" || -L "$directory" ]]; then
        [[ -d "$directory" && ! -L "$directory" ]] || return 1
    else
        parent="$(/usr/bin/dirname "$directory")"
        [[ -d "$parent" && ! -L "$parent" ]] || return 1
        /bin/mkdir "$directory" || return 1
    fi
    permissions="$(/usr/bin/stat -f '%Lp' "$directory" 2>/dev/null)" || return 1
    [[ "$(/usr/bin/stat -f '%u' "$directory" 2>/dev/null)" == "$(/usr/bin/id -u)" \
        && $((8#$permissions & 0022)) -eq 0 ]]
}

if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
    [[ -n "${PCH_HOME_OVERRIDE:-}" ]] || exit 64
    HOME_ROOT="$PCH_HOME_OVERRIDE"
    [[ "$HOME_ROOT" == /tmp/?* || "$HOME_ROOT" == /private/tmp/?* \
        || "$HOME_ROOT" == /private/var/folders/?* || "$HOME_ROOT" == /var/folders/?* ]] || exit 64
    if [[ ! -e "$HOME_ROOT" && ! -L "$HOME_ROOT" ]]; then
        /bin/mkdir "$HOME_ROOT" || exit 1
    fi
else
    HOME_ROOT="$(account_home_for_current_uid)" || exit 64
fi
[[ -n "$HOME_ROOT" && "$HOME_ROOT" == /* && "$HOME_ROOT" != "/" \
    && -d "$HOME_ROOT" && ! -L "$HOME_ROOT" ]] || exit 64
HOME_ROOT="$(cd -P "$HOME_ROOT" && /bin/pwd -P)" || exit 64
LAUNCH_AGENTS_DIR="$HOME_ROOT/Library/LaunchAgents"
migrate_support_directory_if_needed "$HOME_ROOT/Library/Application Support" || true
STATE_DIR="$HOME_ROOT/Library/Application Support/$SUPPORT_DIR_NAME"
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LEGACY_PLIST="$LAUNCH_AGENTS_DIR/$LEGACY_LABEL.plist"
DOMAIN="gui/$(/usr/bin/id -u)"

# 옛 라벨로 로드된 에이전트와 그 plist를 제거한다. 설치와 제거 양쪽에서 부르며,
# 없으면 아무 일도 하지 않는다. 실패는 무시한다. 새 에이전트 설치가 옛 항목
# 정리에 실패해서 막히는 것이 더 나쁘다.
remove_legacy_agent() {
    if [[ "${PCH_TEST_MODE:-0}" != "1" ]]; then
        /bin/launchctl bootout "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1 || true
    fi
    if [[ -e "$LEGACY_PLIST" || -L "$LEGACY_PLIST" ]]; then
        secure_owned_regular_file "$LEGACY_PLIST" || return 0
        /bin/rm -f "$LEGACY_PLIST" || return 0
    fi
    return 0
}

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

safe_existing_directory() {
    local directory="$1"
    local permissions
    permissions="$(/usr/bin/stat -f '%Lp' "$directory" 2>/dev/null)" || return 1
    [[ -d "$directory" && ! -L "$directory" \
        && "$(/usr/bin/stat -f '%u' "$directory" 2>/dev/null)" == "$(/usr/bin/id -u)" \
        && $((8#$permissions & 0022)) -eq 0 ]]
}

secure_owned_regular_file() {
    local path="$1" permissions
    permissions="$(/usr/bin/stat -f '%Lp' "$path" 2>/dev/null)" || return 1
    [[ -f "$path" && ! -L "$path" \
        && "$(/usr/bin/stat -f '%u' "$path" 2>/dev/null)" == "$(/usr/bin/id -u)" \
        && $((8#$permissions & 0022)) -eq 0 ]]
}

launch_directories_are_safe() {
    safe_existing_directory "$HOME_ROOT" \
        && safe_existing_directory "$HOME_ROOT/Library" \
        && safe_existing_directory "$LAUNCH_AGENTS_DIR"
}

launchctl_field_matches() {
    local text="$1" key="$2" expected="$3"
    /usr/bin/awk -v key="$key" -v expected="$expected" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            prefix = key " = "
            if (index(line, prefix) == 1 && substr(line, length(prefix) + 1) == expected) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' <<< "$text"
}

loaded_definition_is_current() {
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        loaded
        return
    fi
    local definition actual_arguments expected_arguments
    definition="$(/bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null)" || return 1
    actual_arguments="$(/usr/bin/awk '
        /^[[:space:]]*arguments = \{/ { inside = 1; next }
        inside && /^[[:space:]]*\}/ { exit }
        inside { sub(/^[[:space:]]+/, ""); print }
    ' <<< "$definition")"
    expected_arguments="$(/usr/bin/printf '%s\n' \
        /usr/bin/env \
        -i \
        "HOME=$HOME_ROOT" \
        "PATH=$SAFE_PATH" \
        "LANG=$SAFE_LOCALE" \
        "LC_ALL=$SAFE_LOCALE" \
        "PCH_STORAGE_WATCH_APP_BUNDLE=$APP_BUNDLE_PATH" \
        /bin/bash \
        -p \
        -c \
        "$WATCH_WRAPPER" \
        -- \
        "$WATCH_HASH" \
        "$WATCH_SCRIPT")"
    [[ "$actual_arguments" == "$expected_arguments" ]] \
        && launchctl_field_matches "$definition" path "$PLIST" \
        && launchctl_field_matches "$definition" program /usr/bin/env \
        && launchctl_field_matches "$definition" "stdout path" /dev/null \
        && launchctl_field_matches "$definition" "stderr path" /dev/null
}

status() {
    local enabled="false"
    local job_loaded="false"
    local definition_current="false"
    loaded && job_loaded="true"
    if [[ "$job_loaded" == "true" ]] \
        && launch_directories_are_safe \
        && secure_owned_regular_file "$PLIST" \
        && loaded_definition_is_current; then
        enabled="true"
        definition_current="true"
    fi
    emit "version" "1"
    emit "enabled" "$enabled"
    emit "loaded" "$job_loaded"
    emit "loadedDefinitionCurrent" "$definition_current"
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
    case "$WATCH_SCRIPT" in
        /Volumes/*|*/AppTranslocation/*)
            /usr/bin/printf 'ERROR: move the app to a stable local folder before enabling storage watch.\n' >&2
            exit 1
            ;;
    esac
    case "$APP_BUNDLE_PATH" in
        ""|*.app) ;;
        *)
            /usr/bin/printf 'ERROR: app bundle path must be empty or end in .app.\n' >&2
            exit 1
            ;;
    esac
    case "$APP_BUNDLE_PATH" in
        /Volumes/*|*/AppTranslocation/*)
            /usr/bin/printf 'ERROR: move the app to a stable local folder before enabling storage watch.\n' >&2
            exit 1
            ;;
    esac
    ensure_directory "$HOME_ROOT/Library" || exit 1
    ensure_directory "$LAUNCH_AGENTS_DIR" || exit 1
    ensure_directory "$HOME_ROOT/Library/Application Support" || exit 1
    ensure_directory "$STATE_DIR" || exit 1
    launch_directories_are_safe || exit 1
    remove_legacy_agent
    /bin/chmod 700 "$STATE_DIR" 2>/dev/null || true
    if [[ -e "$PLIST" || -L "$PLIST" ]]; then
        secure_owned_regular_file "$PLIST" || exit 1
    fi
    local temporary
    temporary="$(/usr/bin/mktemp "$STATE_DIR/$LABEL.plist.XXXXXX")" || exit 1
    trap '/bin/rm -f "$temporary"' EXIT
    /usr/bin/plutil -create xml1 "$temporary" || exit 1
    /usr/bin/plutil -insert Label -string "$LABEL" "$temporary" || exit 1
    /usr/bin/plutil -insert ProgramArguments -json '[]' "$temporary" || exit 1
    local argument_index=0 argument
    for argument in \
        /usr/bin/env \
        -i \
        "HOME=$HOME_ROOT" \
        "PATH=$SAFE_PATH" \
        "LANG=$SAFE_LOCALE" \
        "LC_ALL=$SAFE_LOCALE" \
        "PCH_STORAGE_WATCH_APP_BUNDLE=$APP_BUNDLE_PATH" \
        /bin/bash \
        -p \
        -c \
        "$WATCH_WRAPPER" \
        -- \
        "$WATCH_HASH" \
        "$WATCH_SCRIPT"; do
        /usr/bin/plutil -insert "ProgramArguments.$argument_index" \
            -string "$argument" "$temporary" || exit 1
        argument_index=$((argument_index + 1))
    done
    /usr/bin/plutil -insert StartInterval -integer 3600 "$temporary" || exit 1
    /usr/bin/plutil -insert RunAtLoad -bool true "$temporary" || exit 1
    /usr/bin/plutil -insert StandardOutPath -string /dev/null "$temporary" || exit 1
    /usr/bin/plutil -insert StandardErrorPath -string /dev/null "$temporary" || exit 1
    /bin/chmod 600 "$temporary"
    /bin/mv "$temporary" "$PLIST" || exit 1
    temporary=""
    trap - EXIT

    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        [[ ! -e "$STATE_DIR/.storage-watch-loaded" && ! -L "$STATE_DIR/.storage-watch-loaded" ]] \
            || exit 1
        : > "$STATE_DIR/.storage-watch-loaded"
    else
        /bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
        if ! /bin/launchctl bootstrap "$DOMAIN" "$PLIST"; then
            /bin/rm -f "$PLIST"
            exit 1
        fi
        if ! loaded_definition_is_current; then
            /bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
            /bin/rm -f "$PLIST"
            exit 1
        fi
    fi
    status
}

uninstall_agent() {
    require_approval
    if [[ -e "$HOME_ROOT/Library" || -L "$HOME_ROOT/Library" ]]; then
        safe_existing_directory "$HOME_ROOT/Library" || exit 1
    fi
    if [[ -e "$LAUNCH_AGENTS_DIR" || -L "$LAUNCH_AGENTS_DIR" ]]; then
        launch_directories_are_safe || exit 1
    fi
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        if [[ -e "$STATE_DIR/.storage-watch-loaded" || -L "$STATE_DIR/.storage-watch-loaded" ]]; then
            secure_owned_regular_file "$STATE_DIR/.storage-watch-loaded" \
                || exit 1
            /bin/rm -f "$STATE_DIR/.storage-watch-loaded"
        fi
    else
        /bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
        loaded && exit 1
    fi
    if [[ -e "$PLIST" || -L "$PLIST" ]]; then
        secure_owned_regular_file "$PLIST" || exit 1
        /bin/rm -f "$PLIST"
    fi
    remove_legacy_agent
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
