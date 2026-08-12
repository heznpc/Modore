#!/bin/bash -p
# Modore - allowlisted local cleanup harness.
#
# Preview is read-only. Execute accepts recipe IDs only, requires an explicit
# approval flag, rejects symlinked targets, and writes a local receipt.

set -u
set -o pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

# shellcheck source=scripts/modules/support_dir.sh
source "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/modules/support_dir.sh"

PROTOCOL_VERSION="1"
APPROVAL_TTL_SECONDS=900
OPERATION=""
RECIPE_ID=""
OWNER_APPROVED="false"
APPROVAL_TOKEN=""
APPROVAL_TOKEN_FILE=""
APPROVAL_INPUT_KIND=""
HOME_ROOT="${HOME:-}"
VAR_FOLDERS_ROOT="/private/var/folders"
APPLICATIONS_ROOT="/Applications"
RECEIPT_DIR=""
APPROVAL_DIR=""
STAGING_DIR=""
STAGING_RUN=""
SIMULATOR_KEEP_FILE=""

LABEL=""
REMOVE_MODE="remove"
PROCESS_PATTERN=""
PROCESS_POLICY="block"
PROCESS_NOTE=""
WARNING=""
DESCRIPTION=""
AVOID_WHEN=""
PREVIEW_STATUS=""
BLOCKED_REASON=""
RUNNING_PROCESSES=""
TARGETS=()
APP_BUNDLE_ID=""
TRASH_RUN=""
MOVED_TARGETS=()
MOVED_TARGETS_COUNT=0
MOVED_SOURCES=()
MOVED_DESTINATIONS=()
SIMULATOR_UUID=""
RECIPE_BLOCK_REASON=""
PREVIEW_APPROVAL_TOKEN=""
EXECUTION_MANIFEST=""
TRANSACTION_JOURNAL=""
EXECUTION_FAILURE_STATUS="partial"
# 실제 측정/승인 매니페스트 값이 채워진 뒤에만 true가 된다.
# false인 estimatedKB는 자리 표시 값이므로 크기로 표시하면 안 된다.
ESTIMATE_MEASURED="false"
# 앱 흔적 원장. 설치 이후 생긴 잔여물 중 소유를 증명하지 못한 것과 다른 앱과
# 공유될 수 있는 것은 삭제 대상(TARGETS)과 분리해 보고만 한다. 목록에서 아예
# 빼면 사용자가 앱 밖에서 직접 찾아 지우게 되고, 그때 공유 데이터까지 잃는다.
SHARED_RESIDUE=()
REVIEW_RESIDUE=()
STAGED_REMAINDERS=()
TEST_STAGED_APPROVED_ORIGINAL=""

usage() {
    /usr/bin/printf '%s\n' \
        'Usage:' \
        '  cleanup.sh --list' \
        '  cleanup.sh --preview <recipe-id>' \
        '  cleanup.sh --execute <recipe-id> --owner-approved --approval-token-file /dev/fd/<fd>' \
        '  Legacy CLI compatibility: --approval-token <token>'
}

emit() {
    local key="$1"
    local value="${2:-}"
    case "$key$value" in
        *$'\t'*|*$'\n'*|*$'\r'*) value="출력할 수 없는 제어 문자가 포함되었습니다." ;;
    esac
    /usr/bin/printf '%s\t%s\n' "$key" "$value"
}

fail_usage() {
    /usr/bin/printf 'ERROR: %s\n' "$1" >&2
    usage >&2
    exit 64
}

approval_token_file_size() {
    local source="$1"
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        /usr/bin/stat -f '%z' "$source" 2>/dev/null
    else
        /usr/bin/stat -L -c '%s' "$source" 2>/dev/null
    fi
}

read_approval_token_file() {
    local source="$1"
    local size token
    [[ "$source" =~ ^/dev/fd/[0-9]+$ && -f "$source" ]] || return 1
    size="$(approval_token_file_size "$source")" || return 1
    [[ "$size" == "64" ]] || return 1
    token="$(/bin/dd if="$source" bs=64 count=1 2>/dev/null)" || return 1
    [[ "$token" =~ ^[0-9a-f]{64}$ ]] || return 1
    APPROVAL_TOKEN="$token"
    APPROVAL_TOKEN_FILE=""
    return 0
}

path_owner_uid() {
    local target="$1"
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        /usr/bin/stat -f '%u' "$target" 2>/dev/null
    else
        /usr/bin/stat -c '%u' "$target" 2>/dev/null
    fi
}

account_home_for_current_uid() {
    local uid
    uid="$(/usr/bin/id -u)" || return 1
    if [[ -x /usr/bin/dscacheutil ]]; then
        /usr/bin/dscacheutil -q user -a uid "$uid" 2>/dev/null \
            | /usr/bin/awk '$1 == "dir:" {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}'
        return "${PIPESTATUS[0]}"
    fi
    if /usr/bin/command -v getent >/dev/null 2>&1; then
        getent passwd "$uid" | /usr/bin/awk -F: 'NR == 1 {print $6}'
        return "${PIPESTATUS[0]}"
    fi
    return 1
}

is_allowed_test_root() {
    local requested="$1"
    local canonical owner
    [[ "$requested" == /* && -d "$requested" && ! -L "$requested" ]] || return 1
    canonical="$(cd -P "$requested" 2>/dev/null && /bin/pwd -P)" || return 1
    case "$canonical" in
        /tmp/?*|/private/tmp/?*|/private/var/folders/?*) ;;
        *) return 1 ;;
    esac
    owner="$(path_owner_uid "$canonical")" || return 1
    [[ "$owner" == "$(/usr/bin/id -u)" ]] || return 1
    /usr/bin/printf '%s' "$canonical"
}

test_path_is_isolated() {
    local candidate="$1"
    local probe canonical_probe expected
    [[ "$candidate" == "$HOME_ROOT" || "$candidate" == "$HOME_ROOT/"* ]] || return 1
    [[ ! -L "$candidate" ]] || return 1
    probe="$candidate"
    while [[ ! -e "$probe" && ! -L "$probe" ]]; do
        expected="$(/usr/bin/dirname "$probe")"
        [[ "$expected" != "$probe" ]] || return 1
        probe="$expected"
    done
    # The walk stops at the first existing-or-symlink component. If that component
    # is a symlink, its target may point outside the isolation home, so reject
    # rather than validating the (in-home) parent and letting a write escape.
    [[ ! -L "$probe" ]] || return 1
    [[ -d "$probe" && ! -L "$probe" ]] || probe="$(/usr/bin/dirname "$probe")"
    canonical_probe="$(cd -P "$probe" 2>/dev/null && /bin/pwd -P)" || return 1
    [[ "$canonical_probe" == "$HOME_ROOT" || "$canonical_probe" == "$HOME_ROOT/"* ]]
}

configure_roots() {
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        [[ -n "${PCH_HOME_OVERRIDE:-}" ]] \
            || fail_usage "테스트 모드에는 임시 격리 홈이 필요합니다."
        HOME_ROOT="$(is_allowed_test_root "$PCH_HOME_OVERRIDE")" \
            || fail_usage "테스트 홈은 현재 사용자가 소유한 임시 격리 디렉터리여야 합니다."
        APPLICATIONS_ROOT="${PCH_APPLICATIONS_ROOT_OVERRIDE:-$HOME_ROOT/ApplicationsRoot}"
        VAR_FOLDERS_ROOT="${PCH_VAR_FOLDERS_ROOT_OVERRIDE:-$HOME_ROOT/VarFoldersRoot}"
        test_path_is_isolated "$APPLICATIONS_ROOT" \
            || fail_usage "테스트 Applications 경로가 격리 홈을 벗어났습니다."
        test_path_is_isolated "$VAR_FOLDERS_ROOT" \
            || fail_usage "테스트 var/folders 경로가 격리 홈을 벗어났습니다."
        /bin/mkdir -p "$APPLICATIONS_ROOT" "$VAR_FOLDERS_ROOT" \
            || fail_usage "테스트 격리 경로를 만들 수 없습니다."

        local test_path
        for test_path in \
            "${PCH_PROCESS_LIST_FILE:-}" \
            "${PCH_PROCESS_LIST_WITH_PID_FILE:-}" \
            "${PCH_SIMCTL_LIST_FILE:-}" \
            "${PCH_SIMCTL_DELETE_LOG:-}" \
            "${PCH_TEST_APP_GROUPS_FILE:-}" \
            "${PCH_TEST_LATE_PROCESS_LIST_FILE:-}" \
            "${PCH_TEST_LATE_SIMCTL_LIST_FILE:-}" \
            "${PCH_TEST_LATE_SIMULATOR_KEEP_FILE:-}" \
            "${PCH_TEST_LATE_CONTENT_FILE:-}" \
            "${PCH_TEST_SWAP_TARGET_WITH_SYMLINK_TO:-}" \
            "${PCH_TEST_SWAP_STAGED_DESTINATION_WITH:-}"; do
            [[ -z "$test_path" ]] || test_path_is_isolated "$test_path" \
                || fail_usage "테스트 hook 경로가 격리 홈을 벗어났습니다."
        done
        for test_path in \
            "${PCH_TEST_FAIL_TRASH_MOVE_AT:-}" \
            "${PCH_TEST_FAIL_STAGED_REMOVE_AT:-}" \
            "${PCH_TEST_LATE_CONTENT_AT:-}" \
            "${PCH_TEST_SWAP_STAGED_DESTINATION_AT:-}"; do
            if [[ -n "$test_path" && ! "$test_path" =~ ^[1-9][0-9]*$ ]]; then
                fail_usage "테스트 실패 지점이 올바르지 않습니다."
            fi
        done
    else
        local account_home
        account_home="$(account_home_for_current_uid)" \
            || fail_usage "현재 계정의 홈 경로를 확인할 수 없습니다."
        [[ -n "$account_home" && "$HOME_ROOT" == "$account_home" ]] \
            || fail_usage "HOME 환경변수가 현재 계정의 홈 경로와 일치하지 않습니다."
    fi

    [[ -n "$HOME_ROOT" && "$HOME_ROOT" == /* && "$HOME_ROOT" != "/" ]] \
        || fail_usage "안전한 사용자 홈 경로를 확인할 수 없습니다."
    [[ -d "$HOME_ROOT" && ! -L "$HOME_ROOT" ]] \
        || fail_usage "사용자 홈 경로가 없거나 심볼릭 링크입니다."

    HOME_ROOT="$(cd -P "$HOME_ROOT" 2>/dev/null && /bin/pwd -P)" \
        || fail_usage "사용자 홈 경로를 정규화할 수 없습니다."
    if [[ -d "$APPLICATIONS_ROOT" && ! -L "$APPLICATIONS_ROOT" ]]; then
        APPLICATIONS_ROOT="$(cd -P "$APPLICATIONS_ROOT" 2>/dev/null && /bin/pwd -P)" \
            || fail_usage "Applications 경로를 정규화할 수 없습니다."
    fi
    migrate_support_directory_if_needed "$HOME_ROOT/Library/Application Support" || true
    local support_dir="$HOME_ROOT/Library/Application Support/$SUPPORT_DIR_NAME"
    RECEIPT_DIR="$support_dir/cleanup-receipts"
    APPROVAL_DIR="$support_dir/cleanup-approvals"
    STAGING_DIR="$support_dir/cleanup-staging"
    SIMULATOR_KEEP_FILE="$support_dir/simulator-keep.txt"
    if [[ "${PCH_TEST_MODE:-0}" == "1" && -n "${PCH_SIMULATOR_KEEP_PATH:-}" ]]; then
        test_path_is_isolated "$PCH_SIMULATOR_KEEP_PATH" \
            || fail_usage "테스트 Simulator 보존 파일이 격리 홈을 벗어났습니다."
        SIMULATOR_KEEP_FILE="$PCH_SIMULATOR_KEEP_PATH"
    fi
}

add_target_if_present() {
    local target="$1"
    if [[ -e "$target" || -L "$target" ]]; then
        TARGETS+=("$target")
    fi
}

read_bundle_id() {
    local app_path="$1"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true
}

regex_escape() {
    /usr/bin/printf '%s' "$1" | /usr/bin/sed -E 's/[][(){}.^$*+?|\\]/\\&/g'
}

plist_belongs_to_app() {
    local plist="$1"
    local bundle_id="$2"
    local label program argument target_app
    label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist" 2>/dev/null || true)"
    [[ "$label" == "$bundle_id" ]] && return 0

    program="$(/usr/libexec/PlistBuddy -c 'Print :Program' "$plist" 2>/dev/null || true)"
    argument="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist" 2>/dev/null || true)"
    for target_app in "${TARGETS[@]}"; do
        [[ "$target_app" == *.app ]] || continue
        case "$program" in "$target_app"|"$target_app/"*) return 0 ;; esac
        case "$argument" in "$target_app"|"$target_app/"*) return 0 ;; esac
    done
    return 1
}

app_contains_protected_developer_payload() {
    local app_path="$1"
    local payload
    for payload in \
        "$app_path/Contents/Developer" \
        "$app_path/Contents/Platforms" \
        "$app_path/Contents/Toolchains" \
        "$app_path/Contents/SDKs"; do
        if [[ -e "$payload" || -L "$payload" ]]; then
            return 0
        fi
    done
    return 1
}

group_id_is_valid() {
    local group="$1"
    case "$group" in
        ""|*..*|*/*) return 1 ;;
    esac
    [[ "$group" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,199}$ ]]
}

# 앱이 서명 시점에 선언한 App Group만 소유 근거로 인정한다. 폴더 이름이 비슷하다는
# 사실은 근거가 아니므로, 선언을 읽지 못하면 아무 그룹도 반환하지 않는다.
app_declared_groups() {
    local app_path="$1"
    local bundle_id line declared group
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        [[ -n "${PCH_TEST_APP_GROUPS_FILE:-}" && -f "$PCH_TEST_APP_GROUPS_FILE" ]] || return 0
        bundle_id="$(read_bundle_id "$app_path")"
        [[ -n "$bundle_id" ]] || return 0
        while IFS= read -r line; do
            declared="${line%%|*}"
            group="${line#*|}"
            [[ "$declared" == "$bundle_id" ]] || continue
            group_id_is_valid "$group" || continue
            /usr/bin/printf "%s\n" "$group"
        done < "$PCH_TEST_APP_GROUPS_FILE"
        return 0
    fi
    /usr/bin/codesign -d --entitlements :- --xml "$app_path" 2>/dev/null \
        | /usr/bin/plutil -extract com.apple.security.application-groups xml1 -o - - 2>/dev/null \
        | /usr/bin/sed -n "s|.*<string>\(.*\)</string>.*|\1|p"
}

app_target_declared_groups() {
    local target
    for target in ${TARGETS[@]+"${TARGETS[@]}"}; do
        [[ "$target" == *.app ]] || continue
        app_declared_groups "$target"
    done
}

# 다른 설치 앱도 같은 그룹을 선언했다면 공유 데이터다. 이때는 삭제하지 않고 보고만 한다.
group_container_is_exclusive() {
    local group="$1"
    local app_path other_group
    local candidates=()
    shopt -s nullglob
    candidates=("$APPLICATIONS_ROOT"/*.app "$HOME_ROOT/Applications"/*.app "$HOME_ROOT/Applications"/*/*.app)
    shopt -u nullglob
    for app_path in ${candidates[@]+"${candidates[@]}"}; do
        [[ -d "$app_path" && ! -L "$app_path" ]] || continue
        [[ "$(read_bundle_id "$app_path")" != "$APP_BUNDLE_ID" ]] || continue
        while IFS= read -r other_group; do
            if [[ "$other_group" == "$group" ]]; then
                return 1
            fi
        done < <(app_declared_groups "$app_path")
    done
    return 0
}

add_shared_residue() {
    local target="$1"
    [[ -e "$target" || -L "$target" ]] || return 0
    SHARED_RESIDUE+=("$target")
}

add_review_residue() {
    local target="$1"
    local declared
    [[ -e "$target" || -L "$target" ]] || return 0
    for declared in ${TARGETS[@]+"${TARGETS[@]}"}; do
        if [[ "$declared" == "$target" ]]; then
            return 0
        fi
    done
    REVIEW_RESIDUE+=("$target")
}

# 설치 이후 생긴 잔여물을 세 등급으로 나눈다. 번들 ID로 정확히 귀속되는 것만
# 삭제 대상에 넣고, 공유 가능성이 있거나 이름으로만 추정되는 것은 분리해 보고한다.
collect_app_residue_ledger() {
    local bundle_id="$1"
    local group group_path label_residue declared_any="false"

    add_target_if_present "$HOME_ROOT/Library/Cookies/$bundle_id.binarycookies"
    add_target_if_present "$HOME_ROOT/Library/HTTPStorages/$bundle_id.binarycookies"
    add_target_if_present "$HOME_ROOT/Library/Caches/$bundle_id.ShipIt"

    while IFS= read -r group; do
        group_id_is_valid "$group" || continue
        declared_any="true"
        group_path="$HOME_ROOT/Library/Group Containers/$group"
        [[ -e "$group_path" || -L "$group_path" ]] || continue
        if group_container_is_exclusive "$group"; then
            add_target_if_present "$group_path"
        else
            add_shared_residue "$group_path"
        fi
    done < <(app_target_declared_groups)

    if [[ "$declared_any" == "false" ]]; then
        shopt -s nullglob
        for group_path in "$HOME_ROOT/Library/Group Containers"/*."$bundle_id"; do
            add_shared_residue "$group_path"
        done
        shopt -u nullglob
    fi

    if [[ -n "$LABEL" && "$LABEL" != */* && "$LABEL" != "." && "$LABEL" != ".." ]]; then
        for label_residue in "$HOME_ROOT/Library/Application Support/$LABEL" "$HOME_ROOT/Library/Caches/$LABEL" "$HOME_ROOT/Library/Logs/$LABEL"; do
            add_review_residue "$label_residue"
        done
    fi
}

define_app_recipe() {
    local bundle_id="$1"
    local app_path found_app="false" app_label="" escaped pattern=""
    local candidates=()
    [[ "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{1,199}$ ]] || return 1
    [[ "$bundle_id" != "com.apple.Safari" ]] || return 1
    [[ "$bundle_id" != com.apple.dt.Xcode* ]] || return 1

    shopt -s nullglob
    candidates=(
        "$APPLICATIONS_ROOT"/*.app
        "$HOME_ROOT/Applications"/*.app
        "$HOME_ROOT/Applications"/*/*.app
    )
    shopt -u nullglob
    # Guard the empty-array expansion: under `set -u`, bash 3.2 (the /bin/bash the
    # app spawns) aborts on "${candidates[@]}" when no .app bundles matched.
    for app_path in ${candidates[@]+"${candidates[@]}"}; do
        [[ -d "$app_path" && ! -L "$app_path" ]] || continue
        if [[ "$(read_bundle_id "$app_path")" == "$bundle_id" ]]; then
            app_contains_protected_developer_payload "$app_path" && return 1
            found_app="true"
            add_target_if_present "$app_path"
            if [[ -z "$app_label" ]]; then
                app_label="$(/usr/bin/basename "$app_path" .app)"
            fi
            escaped="$(regex_escape "$app_path")"
            if [[ -z "$pattern" ]]; then
                pattern="$escaped"
            else
                pattern="$pattern|$escaped"
            fi
        fi
    done
    [[ "$found_app" == "true" ]] || return 0

    APP_BUNDLE_ID="$bundle_id"
    LABEL="${app_label:-$bundle_id}"
    REMOVE_MODE="trash"
    PROCESS_PATTERN="$pattern"
    PROCESS_NOTE="앱을 완전히 종료한 뒤 휴지통으로 이동하세요."
    WARNING="앱과 번들 ID로 정확히 귀속되는 사용자 데이터만 휴지통으로 이동합니다. 실제 공간은 휴지통을 비운 뒤 회수됩니다."

    add_target_if_present "$HOME_ROOT/Library/Application Support/$bundle_id"
    add_target_if_present "$HOME_ROOT/Library/Application Scripts/$bundle_id"
    add_target_if_present "$HOME_ROOT/Library/Caches/$bundle_id"
    add_target_if_present "$HOME_ROOT/Library/Containers/$bundle_id"
    add_target_if_present "$HOME_ROOT/Library/HTTPStorages/$bundle_id"
    add_target_if_present "$HOME_ROOT/Library/Logs/$bundle_id"
    add_target_if_present "$HOME_ROOT/Library/Preferences/$bundle_id.plist"
    add_target_if_present "$HOME_ROOT/Library/Saved Application State/$bundle_id.savedState"
    add_target_if_present "$HOME_ROOT/Library/WebKit/$bundle_id"

    local residue plist filename suffix
    shopt -s nullglob
    for residue in "$HOME_ROOT/Library/Preferences/ByHost/$bundle_id".*.plist; do
        filename="$(/usr/bin/basename "$residue")"
        suffix="${filename#"$bundle_id."}"
        suffix="${suffix%.plist}"
        [[ "$suffix" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
            || continue
        add_target_if_present "$residue"
    done
    for plist in "$HOME_ROOT/Library/LaunchAgents"/*.plist; do
        [[ -f "$plist" && ! -L "$plist" ]] || continue
        if plist_belongs_to_app "$plist" "$bundle_id"; then
            add_target_if_present "$plist"
        fi
    done
    shopt -u nullglob
    collect_app_residue_ledger "$bundle_id"
    return 0
}

simctl_devices() {
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        if [[ -n "${PCH_SIMCTL_LIST_FILE:-}" && -f "$PCH_SIMCTL_LIST_FILE" ]]; then
            /bin/cat "$PCH_SIMCTL_LIST_FILE"
        fi
    else
        /usr/bin/xcrun simctl list devices available 2>/dev/null || true
    fi
}

simulator_keep_has_legacy_entries() {
    local line
    [[ -f "$SIMULATOR_KEEP_FILE" && ! -L "$SIMULATOR_KEEP_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
            || return 0
    done < "$SIMULATOR_KEEP_FILE"
    return 1
}

normalize_uuid() {
    /usr/bin/printf '%s' "$1" | /usr/bin/tr '[:lower:]' '[:upper:]'
}

simulator_keep_contains_uuid() {
    local requested_upper="$1"
    local line
    [[ -f "$SIMULATOR_KEEP_FILE" && ! -L "$SIMULATOR_KEEP_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(/usr/bin/printf '%s' "$line" | /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ "$line" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
            || continue
        if [[ "$(normalize_uuid "$line")" == "$requested_upper" ]]; then
            return 0
        fi
    done < "$SIMULATOR_KEEP_FILE"
    return 1
}

simulator_state_for_uuid() {
    local requested_upper="$1"
    local line uuid state
    while IFS= read -r line; do
        uuid="$(/usr/bin/sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/' <<< "$line")"
        [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || continue
        [[ "$(normalize_uuid "$uuid")" == "$requested_upper" ]] || continue
        state="$(/usr/bin/sed -E 's/.*\([0-9A-Fa-f-]{36}\)[[:space:]]*\(([^)]*)\).*/\1/' <<< "$line")"
        [[ -n "$state" && "$state" != "$line" ]] || return 1
        /usr/bin/printf '%s' "$state"
        return 0
    done < <(simctl_devices)
    return 1
}

simulator_delete_boundary_ready() {
    local requested_upper state
    requested_upper="$(normalize_uuid "$SIMULATOR_UUID")" || return 1
    if ! state="$(simulator_state_for_uuid "$requested_upper")"; then
        BLOCKED_REASON="Simulator의 현재 상태를 다시 확인하지 못해 삭제를 중단했습니다."
        return 1
    fi
    if [[ "$state" != "Shutdown" ]]; then
        BLOCKED_REASON="현재 $state 상태인 Simulator는 삭제할 수 없습니다. 완전히 종료한 뒤 다시 미리보기하세요."
        return 1
    fi
    if [[ -L "$SIMULATOR_KEEP_FILE" ]]; then
        BLOCKED_REASON="Simulator 보존 목록 경로가 심볼릭 링크여서 삭제를 차단했습니다."
        return 1
    fi
    if simulator_keep_has_legacy_entries; then
        BLOCKED_REASON="기존 이름 기반 Simulator 보존 목록이 남아 있어 삭제를 차단했습니다. 앱에서 보존 목록을 다시 저장하세요."
        return 1
    fi
    if simulator_keep_contains_uuid "$requested_upper"; then
        BLOCKED_REASON="사용자 보존 목록에 있는 Simulator여서 삭제를 차단했습니다."
        return 1
    fi
    return 0
}

define_simulator_recipe() {
    local requested_uuid="$1"
    local requested_upper runtime="" line uuid name state data_path
    [[ "$requested_uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || return 1
    requested_upper="$(normalize_uuid "$requested_uuid")"

    while IFS= read -r line; do
        case "$line" in
            "-- "*)
                runtime="${line#-- }"
                runtime="${runtime% --}"
                ;;
            *)
                uuid="$(/usr/bin/sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/' <<< "$line")"
                [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || continue
                if [[ "$(normalize_uuid "$uuid")" == "$requested_upper" ]]; then
                    name="$(/usr/bin/sed -E 's/^[[:space:]]*//; s/[[:space:]]*\([0-9A-Fa-f-]{36}\)[[:space:]]*\([^)]*\).*//' <<< "$line")"
                    state="$(/usr/bin/sed -E 's/.*\([0-9A-Fa-f-]{36}\)[[:space:]]*\(([^)]*)\).*/\1/' <<< "$line")"
                    SIMULATOR_UUID="$uuid"
                    LABEL="$name"
                    REMOVE_MODE="simulator"
                    PROCESS_NOTE="Booted Simulator는 먼저 종료해야 합니다."
                    WARNING="$runtime 기기 데이터만 삭제합니다. iOS Simulator 런타임 자체는 보존됩니다."
                    if [[ "$state" == "Booted" ]]; then
                        RECIPE_BLOCK_REASON="현재 Booted 상태인 Simulator는 삭제할 수 없습니다."
                    elif [[ -L "$SIMULATOR_KEEP_FILE" ]]; then
                        RECIPE_BLOCK_REASON="Simulator 보존 목록 경로가 심볼릭 링크여서 삭제를 차단했습니다."
                    elif simulator_keep_has_legacy_entries; then
                        RECIPE_BLOCK_REASON="기존 이름 기반 Simulator 보존 목록이 남아 있습니다. 앱에서 보존 목록을 UUID 형식으로 다시 저장한 뒤 검토하세요."
                    elif simulator_keep_contains_uuid "$requested_upper"; then
                        RECIPE_BLOCK_REASON="사용자 보존 목록에 있는 Simulator입니다. 보존 표시를 먼저 해제하세요."
                    fi
                    data_path="$HOME_ROOT/Library/Developer/CoreSimulator/Devices/$uuid"
                    add_target_if_present "$data_path"
                    return 0
                fi
                ;;
        esac
    done < <(simctl_devices)
    return 0
}

# 사용자가 앱을 벗어나 검색하지 않고도 판단할 수 있도록, 항목별로
# "무엇인가"(DESCRIPTION)와 "언제 미뤄야 하는가"(AVOID_WHEN)를 제공한다.
# WARNING이 삭제 후 결과를 설명하므로 여기서는 정체와 보류 조건만 담는다.
apply_recipe_guidance() {
    local recipe="$1"
    case "$recipe" in
        simulator_delete:*)
            DESCRIPTION="선택한 iOS 시뮬레이터 기기와 그 안에 설치된 앱·데이터입니다."
            AVOID_WHEN="이 기기에 남겨둘 테스트 상태나 로그인 세션이 있다면 두세요."
            return 0
            ;;
        app_uninstall:*)
            DESCRIPTION="이 앱과, 번들 ID로 정확히 귀속되는 사용자 데이터입니다."
            AVOID_WHEN="앱을 다시 쓸 계획이거나 내보내지 않은 데이터가 있다면 두세요."
            return 0
            ;;
    esac
    case "$recipe" in
        npm_cache)
            DESCRIPTION="npm이 내려받아 보관하는 패키지 압축본 캐시입니다. 프로젝트 소스와 node_modules는 대상이 아닙니다."
            AVOID_WHEN="네트워크가 느리거나, 오프라인에서 곧 npm install을 해야 한다면 두세요."
            ;;
        pnpm_store)
            DESCRIPTION="여러 프로젝트가 공유하도록 pnpm이 패키지를 모아 두는 저장소입니다. 프로젝트 소스는 대상이 아닙니다."
            AVOID_WHEN="여러 프로젝트를 자주 재설치하거나 오프라인 작업이 예정됐다면 두세요."
            ;;
        playwright_browsers)
            DESCRIPTION="Playwright가 테스트용으로 내려받은 Chromium·Firefox·WebKit 바이너리입니다. 평소 쓰는 Chrome 앱과 프로필, 북마크와는 무관합니다."
            AVOID_WHEN="곧 E2E 테스트를 돌려야 하는데 네트워크가 느리다면 두세요."
            ;;
        gradle_cache)
            DESCRIPTION="Gradle이 받아 둔 의존성과 빌드 캐시입니다. 프로젝트 소스는 대상이 아닙니다."
            AVOID_WHEN="오프라인에서 Android/JVM 빌드를 해야 한다면 두세요."
            ;;
        cocoapods_cache)
            DESCRIPTION="CocoaPods가 받아 둔 Pod 아카이브 캐시입니다. Podfile과 프로젝트는 대상이 아닙니다."
            AVOID_WHEN="오프라인에서 pod install을 해야 한다면 두세요."
            ;;
        pub_cache)
            DESCRIPTION="Dart/Flutter가 받아 둔 패키지 캐시입니다. 앱 소스는 대상이 아닙니다."
            AVOID_WHEN="오프라인에서 Flutter 빌드를 해야 한다면 두세요."
            ;;
        uv_cache)
            DESCRIPTION="uv(파이썬 패키지 관리자)가 받아 둔 다운로드 캐시입니다. 프로젝트 소스와 가상환경은 대상이 아닙니다."
            AVOID_WHEN="오프라인에서 곧 uv/파이썬 의존성 설치를 해야 한다면 두세요."
            ;;
        swiftpm_cache)
            DESCRIPTION="Swift Package Manager가 받아 둔 의존성 캐시입니다. 프로젝트 소스와 각 프로젝트의 .build는 대상이 아닙니다."
            AVOID_WHEN="오프라인에서 곧 Swift 빌드를 해야 한다면 두세요."
            ;;
        homebrew_cache)
            DESCRIPTION="Homebrew가 내려받아 둔 설치 파일 캐시입니다. 설치된 프로그램 자체는 대상이 아니며, brew cleanup이 비우는 것과 같은 캐시입니다."
            AVOID_WHEN="네트워크가 느리거나 오프라인에서 곧 brew 설치·업그레이드를 해야 한다면 두세요."
            ;;
        pip_cache)
            DESCRIPTION="pip(파이썬 패키지 관리자)가 받아 둔 휠 캐시입니다. 설치된 패키지와 가상환경은 대상이 아닙니다."
            AVOID_WHEN="오프라인에서 곧 pip 설치를 해야 한다면 두세요."
            ;;
        codex_runtime_cache)
            DESCRIPTION="Codex가 내려받아 실행에 쓰는 런타임 설치본입니다. 대화 기록과 세션 파일은 대상이 아닙니다."
            AVOID_WHEN="Codex 작업이 진행 중이라면 끝난 뒤에 하세요."
            ;;
        codex_temp_cache)
            DESCRIPTION="Codex가 작업 중 만든 임시 파일입니다. 세션 기록과 로그 DB는 대상이 아닙니다."
            AVOID_WHEN="Codex 작업이 진행 중이라면 끝난 뒤에 하세요."
            ;;
        claude_vm_bundles)
            DESCRIPTION="Claude의 로컬 에이전트가 쓰는 가상 머신 이미지입니다. 대화 내용과 세션 작업공간은 대상이 아닙니다."
            AVOID_WHEN="Cowork 세션이 진행 중이라면 저장하고 종료한 뒤에 하세요."
            ;;
        ollama_models)
            DESCRIPTION="Ollama가 내려받은 로컬 모델 가중치입니다. ollama pull로 다시 받을 수 있지만, 모델 크기에 따라 수 GB~수십 GB를 다시 내려받아야 합니다. SSH 키 등 자격증명은 이 폴더가 아닌 별도 경로에 있어 대상이 아닙니다."
            AVOID_WHEN="네트워크가 느리거나, 곧 다시 같은 모델을 쓸 계획이라면 재다운로드 비용을 먼저 따져보세요."
            ;;
        xcode_derived_data)
            DESCRIPTION="Xcode가 빌드 중간 산출물과 코드 인덱스를 넣어 두는 폴더입니다. 소스와 Archive는 대상이 아닙니다."
            AVOID_WHEN="지금 빌드나 인덱싱이 돌고 있다면 끝난 뒤에 하세요."
            ;;
        chrome_code_sign_clones)
            DESCRIPTION="Chrome이 업데이트를 검증할 때 임시로 만드는 서명 복제본입니다. 북마크·비밀번호·프로필은 대상이 아닙니다."
            AVOID_WHEN="Chrome이 업데이트를 적용하는 중이라면 끝난 뒤에 하세요."
            ;;
        innorix_ex)
            DESCRIPTION="일부 국내 사이트가 파일 전송에 사용하는 INNORIX-EX 모듈과 자동 실행 항목입니다."
            AVOID_WHEN="이 모듈을 요구하는 업무·금융 사이트를 곧 이용해야 한다면 두세요."
            ;;
    esac
    return 0
}

define_recipe() {
    local recipe="$1"
    LABEL=""
    REMOVE_MODE="remove"
    PROCESS_PATTERN=""
    PROCESS_POLICY="block"
    PROCESS_NOTE=""
    WARNING=""
    DESCRIPTION=""
    AVOID_WHEN=""
    TARGETS=()
    APP_BUNDLE_ID=""
    TRASH_RUN=""
    MOVED_TARGETS=()
    MOVED_TARGETS_COUNT=0
    MOVED_SOURCES=()
    MOVED_DESTINATIONS=()
    STAGING_RUN=""
    STAGED_REMAINDERS=()
    SIMULATOR_UUID=""
    RECIPE_BLOCK_REASON=""
    PREVIEW_APPROVAL_TOKEN=""
    SHARED_RESIDUE=()
    REVIEW_RESIDUE=()
    EXECUTION_MANIFEST=""
    TRANSACTION_JOURNAL=""
    EXECUTION_FAILURE_STATUS="partial"
    TEST_STAGED_APPROVED_ORIGINAL=""

    if [[ "$recipe" == simulator_delete:* ]]; then
        define_simulator_recipe "${recipe#simulator_delete:}" || return $?
        apply_recipe_guidance "$recipe"
        return 0
    fi

    if [[ "$recipe" == app_uninstall:* ]]; then
        define_app_recipe "${recipe#app_uninstall:}" || return $?
        apply_recipe_guidance "$recipe"
        return 0
    fi

    case "$recipe" in
        npm_cache)
            LABEL="npm cache"
            # npm/npx는 거의 항상 shebang 스크립트라, 커널이 인터프리터를 앞에
            # 세워 실행한다 — 실행 이름 앵커만으로는 놓친다. mise 셈에서는
            # 잠깐 `bash .../bin/npm`으로 보이다가 `node .../npm-cli.js`로
            # 넘어간다. 둘 다 이 머신에서 직접 캡처해 확인했다.
            PROCESS_PATTERN='(^|/)(npm|npx)( |$)|/\.npm/_cacache|(^|/)npm-cli\.js( |$)|(^|/)npx-cli\.js( |$)'
            PROCESS_NOTE="npm/npx 작업을 먼저 종료하세요."
            WARNING="패키지는 다음 설치 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/.npm"
            ;;
        pnpm_store)
            LABEL="pnpm store"
            # 맨 `node`는 편집기 언어 서버, MCP 서버, Electron 헬퍼를 전부 잡는다.
            # 그것들은 이 store에 쓰지 않으므로 사용자가 무엇을 닫아도 차단이
            # 풀리지 않는다. store에 쓰는 주체는 pnpm 자신이고, store에서 실행된
            # 바이너리는 경로로 잡힌다.
            # 맨 `node`는 편집기 언어 서버, MCP 서버, Electron 헬퍼를 전부 잡는다.
            # 그것들은 이 store에 쓰지 않으므로 사용자가 무엇을 닫아도 차단이
            # 풀리지 않는다. 다만 pnpm 자신이 `node <pnpm.cjs>` 형태로 실행되는
            # 경우(corepack, standalone 설치)가 있어, 실행 이름만으로는 놓친다.
            # 그래서 스크립트 이름까지 본다.
            PROCESS_PATTERN='(^|/)pnpm( |$)|/Library/pnpm/|(^|/)pnpm\.(cjs|js|mjs)( |$)|corepack'
            PROCESS_NOTE="pnpm/Node 작업을 먼저 종료하세요."
            WARNING="공유 패키지 저장소가 다시 채워지며 다음 설치가 느려질 수 있습니다."
            add_target_if_present "$HOME_ROOT/Library/pnpm"
            ;;
        playwright_browsers)
            LABEL="Playwright browser cache"
            # 위험은 이 캐시 안의 바이너리가 실행 중일 때만 생긴다. --headless와
            # remote-debugging-pipe는 Electron 앱이나 자동화 도구가 공통으로 쓰는
            # 범용 Chromium 플래그여서, 그것까지 차단하면 캐시와 무관한 앱 때문에
            # 사용자가 창을 모두 닫아도 차단을 풀 수 없다. 경로·실행기 이름으로
            # Playwright에 실제로 귀속되는 프로세스만 차단한다.
            PROCESS_PATTERN='[Pp]laywright'
            PROCESS_NOTE="Playwright 테스트와 이 캐시로 실행한 브라우저를 먼저 종료하세요."
            WARNING="브라우저 바이너리는 다음 테스트 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/Library/Caches/ms-playwright"
            ;;
        gradle_cache)
            LABEL="Gradle cache"
            # org.gradle을 그냥 좁히면 classpath로만 캐시를 쥔 Kotlin daemon을
            # 놓치므로, 실행 이름은 좁히고 대상 경로 토큰으로 보완한다.
            PROCESS_PATTERN='GradleDaemon|org\.gradle\.(launcher|wrapper)|(^|/)(gradle|gradlew)( |$)|/\.gradle/caches/'
            PROCESS_NOTE="Gradle 빌드와 daemon을 먼저 종료하세요."
            WARNING="Gradle 의존성과 빌드 캐시는 다음 빌드 때 다시 생성됩니다."
            add_target_if_present "$HOME_ROOT/.gradle/caches"
            ;;
        cocoapods_cache)
            LABEL="CocoaPods cache"
            # pod도 shebang 스크립트를 거쳐 ruby로 넘어가므로, 실행줄 맨
            # 앞이 아니라 경로 중간에 온다 — 앵커를 pnpm과 같은 방식으로 푼다.
            PROCESS_PATTERN='(^|/)pod( |$)|/Caches/CocoaPods/'
            PROCESS_NOTE="pod install/update 작업을 먼저 종료하세요."
            WARNING="Pod 아카이브는 다음 설치 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/Library/Caches/CocoaPods"
            ;;
        pub_cache)
            LABEL="Dart/Flutter pub cache"
            # Flutter SDK 설치 경로가 /flutter로 끝나서, SDK 디렉터리를 인자로
            # 주는 모든 명령이 걸렸다. 실행 위치만 본다. analysis server는
            # package: 해석을 위해 pub cache를 실제로 읽으므로 남긴다.
            PROCESS_PATTERN='^(\S*/)?(dart|flutter)( |$)|dart-sdk/bin/dart|flutter_tools'
            PROCESS_NOTE="Dart/Flutter 작업을 먼저 종료하세요."
            WARNING="패키지는 다음 pub get 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/.pub-cache"
            ;;
        uv_cache)
            LABEL="uv cache"
            # 실행 이름이 uv인 것과, 캐시 경로를 인자로 쥔 프로세스를 함께 본다.
            PROCESS_PATTERN='^(\S*/)?uv( |$)|/\.cache/uv/'
            PROCESS_NOTE="uv/파이썬 의존성 설치를 먼저 종료하세요."
            WARNING="패키지는 다음 uv 설치 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/.cache/uv"
            ;;
        swiftpm_cache)
            LABEL="Swift Package Manager cache"
            # SourceKitService와 swift-build가 이 캐시를 읽는다. 실행 이름과
            # 캐시 경로 토큰을 함께 본다.
            PROCESS_PATTERN='^(\S*/)?swift(-build|-package)?( |$)|SourceKitService|/Caches/org\.swift\.swiftpm/'
            PROCESS_NOTE="Swift 빌드와 Xcode/SourceKit 작업을 먼저 종료하세요."
            WARNING="의존성은 다음 Swift 빌드 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/Library/Caches/org.swift.swiftpm"
            ;;
        homebrew_cache)
            LABEL="Homebrew download cache"
            # brew는 자기 자신을 `bash .../Homebrew/brew.sh`로 재실행한다
            # (brew.sh:350의 exec). 두 단계 다 이 머신에서 직접 확인했다.
            PROCESS_PATTERN='(^|/)brew( |$)|(^|/)brew\.sh( |$)|/Caches/Homebrew/'
            PROCESS_NOTE="brew 설치·업그레이드를 먼저 종료하세요."
            WARNING="설치 파일은 다음 brew 설치·업그레이드 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/Library/Caches/Homebrew"
            ;;
        pip_cache)
            LABEL="pip wheel cache"
            # pip은 python -m pip으로도 실행되므로 캐시 경로 토큰으로 보완한다.
            PROCESS_PATTERN='(^|/)pip[0-9.]*( |$)|(^|/)python[0-9.]* -m pip|/Caches/pip/'
            PROCESS_NOTE="pip 설치를 먼저 종료하세요."
            WARNING="휠은 다음 pip 설치 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/Library/Caches/pip"
            ;;
        codex_runtime_cache)
            LABEL="Codex runtime cache"
            # `/codex`는 이름이 codex로 시작하는 저장소 안의 모든 프로세스를
            # 잡으면서, 정작 `~/.codex/`는 `/.codex`라서 놓친다. 실행 이름은
            # 앵커로 잡고 대상 디렉터리는 경로 토큰으로 잡는다.
            PROCESS_PATTERN='Codex\.app/Contents/MacOS/Codex|(^|/)codex( |$)|(^|/)node_repl( |$)|SkyComputerUseClient|/\.cache/codex-runtimes/'
            PROCESS_NOTE="Codex 앱과 진행 중인 Codex 작업을 먼저 종료하세요."
            WARNING="Codex 런타임은 다음 사용 때 다시 설치될 수 있습니다. 세션 JSONL은 건드리지 않습니다."
            add_target_if_present "$HOME_ROOT/.cache/codex-runtimes"
            ;;
        codex_temp_cache)
            LABEL="Codex temporary cache"
            PROCESS_PATTERN='Codex\.app/Contents/MacOS/Codex|(^|/)codex( |$)|(^|/)node_repl( |$)|SkyComputerUseClient|/\.codex/\.tmp'
            PROCESS_NOTE="Codex 앱과 진행 중인 Codex 작업을 먼저 종료하세요."
            WARNING="임시 런타임 파일만 정리합니다. .codex/sessions와 로그 DB는 건드리지 않습니다."
            add_target_if_present "$HOME_ROOT/.codex/.tmp"
            ;;
        claude_vm_bundles)
            LABEL="Claude Cowork VM bundles"
            # /claude와 claude-code는 vm_bundles를 쓰지 않는 별개 제품(Claude
            # Code CLI)을 잡고, local-agent-mode는 이 recipe가 보존한다고 선언한
            # 디렉터리를 잡는다. vm_bundles를 쓰는 주체는 Claude Desktop뿐이다.
            PROCESS_PATTERN='Claude\.app/Contents/MacOS/Claude|Claude Helper|/vm_bundles/'
            PROCESS_NOTE="Claude Desktop/Code/Cowork를 완전히 종료하세요."
            WARNING="로컬 에이전트 VM 이미지는 다시 생성될 수 있습니다. 세션 작업공간은 보존합니다."
            add_target_if_present "$HOME_ROOT/Library/Application Support/Claude/vm_bundles"
            ;;
        ollama_models)
            LABEL="Ollama model blobs"
            # ollama serve(백그라운드 데몬)와 CLI 둘 다 모델을 읽는 동안 잡는다.
            # 대상은 models/뿐이라 같은 폴더의 SSH 키(id_ed25519*)는 건드리지 않는다.
            PROCESS_PATTERN='(^|/)ollama( |$)|Ollama\.app/Contents/MacOS/Ollama'
            PROCESS_NOTE="Ollama(서버/CLI)를 먼저 종료하세요."
            WARNING="모델은 ollama pull로 다시 받을 수 있지만, 모델마다 수 GB~수십 GB를 다시 내려받습니다."
            add_target_if_present "$HOME_ROOT/.ollama/models"
            ;;
        xcode_derived_data)
            LABEL="Xcode DerivedData"
            # Xcode.app 번들 안에는 DerivedData와 무관한 실행 파일도 들어 있다.
            # 특히 Simulator.app이 그 안에 있어서, 번들 경로만 보면 시뮬레이터를
            # 띄워둔 것만으로 정리가 영구히 막힌다. Xcode 본체와 실제 빌드
            # 서비스만 차단 대상으로 둔다.
            # xcodebuild를 앵커해 빌드 로그 파일명 오탐을 없앤다. SourceKitService는
            # 남긴다. Xcode 세션이 DerivedData/Index.noindex를 mmap하고 있어 삭제 시
            # 인덱스가 손상되는데, 명령줄만으로 SwiftPM 세션과 구분할 수 없다.
            PROCESS_PATTERN='Xcode\.app/Contents/MacOS/Xcode|^(\S*/)?xcodebuild( |$)|XCBBuildService|SourceKitService'
            PROCESS_NOTE="Xcode와 진행 중인 Apple 플랫폼 빌드를 먼저 종료하세요."
            WARNING="소스와 Archive는 보존되지만 다음 빌드가 오래 걸릴 수 있습니다."
            add_target_if_present "$HOME_ROOT/Library/Developer/Xcode/DerivedData"
            ;;
        chrome_code_sign_clones)
            LABEL="Chrome code-sign clones"
            # --headless와 remote-debugging-pipe는 이 클론과 인과관계가 없다.
            # LibreOffice 변환, Edge, Electron 헬퍼까지 잡으면서 정작 클론을
            # 만드는 주체인 Chrome 업데이터는 놓치고 있었다. 삭제가 실제로
            # 위험한 순간은 업데이트 적용 중이므로 본체와 업데이터를 남긴다.
            PROCESS_PATTERN='Google Chrome\.app/Contents/(MacOS|Frameworks)/|com\.google\.Chrome\.code_sign_clone|GoogleSoftwareUpdate|(^|/)ksadmin( |$)'
            PROCESS_NOTE="Chrome과 브라우저 자동화를 완전히 종료하세요."
            WARNING="Chrome 임시 code-sign clone만 정리합니다. 브라우저 프로필은 대상이 아닙니다."
            local candidate
            for candidate in \
                "$VAR_FOLDERS_ROOT"/*/*/X/com.google.Chrome.code_sign_clone \
                "$VAR_FOLDERS_ROOT"/*/*/T/com.google.Chrome.code_sign_clone; do
                add_target_if_present "$candidate"
            done
            ;;
        innorix_ex)
            LABEL="INNORIX-EX web transfer module"
            PROCESS_PATTERN='INNORIX-EX|innorixes\.app|innorixes'
            PROCESS_POLICY="stop"
            PROCESS_NOTE="실행 중이면 승인 후 LaunchAgent와 프로세스를 먼저 종료합니다."
            WARNING="해당 모듈이 필요한 사이트에서는 다시 설치하라는 안내가 나올 수 있습니다."
            add_target_if_present "$HOME_ROOT/Applications/INNORIX-EX"
            add_target_if_present "$HOME_ROOT/Library/LaunchAgents/com.innorix.innorixes.plist"
            ;;
        *) return 1 ;;
    esac
    apply_recipe_guidance "$recipe"
    return 0
}

allowed_target() {
    local recipe="$1"
    local target="$2"
    if [[ "$recipe" == simulator_delete:* || "$recipe" == app_uninstall:* ]]; then
        local declared
        for declared in "${TARGETS[@]}"; do
            if [[ "$declared" == "$target" ]]; then
                if [[ "$target" == *.app ]]; then
                    [[ "$(read_bundle_id "$target")" == "$APP_BUNDLE_ID" ]]
                    return $?
                fi
                return 0
            fi
        done
        return 1
    fi
    case "$recipe" in
        npm_cache) [[ "$target" == "$HOME_ROOT/.npm" ]] ;;
        pnpm_store) [[ "$target" == "$HOME_ROOT/Library/pnpm" ]] ;;
        playwright_browsers) [[ "$target" == "$HOME_ROOT/Library/Caches/ms-playwright" ]] ;;
        gradle_cache) [[ "$target" == "$HOME_ROOT/.gradle/caches" ]] ;;
        cocoapods_cache) [[ "$target" == "$HOME_ROOT/Library/Caches/CocoaPods" ]] ;;
        pub_cache) [[ "$target" == "$HOME_ROOT/.pub-cache" ]] ;;
        uv_cache) [[ "$target" == "$HOME_ROOT/.cache/uv" ]] ;;
        swiftpm_cache) [[ "$target" == "$HOME_ROOT/Library/Caches/org.swift.swiftpm" ]] ;;
        homebrew_cache) [[ "$target" == "$HOME_ROOT/Library/Caches/Homebrew" ]] ;;
        pip_cache) [[ "$target" == "$HOME_ROOT/Library/Caches/pip" ]] ;;
        codex_runtime_cache) [[ "$target" == "$HOME_ROOT/.cache/codex-runtimes" ]] ;;
        codex_temp_cache) [[ "$target" == "$HOME_ROOT/.codex/.tmp" ]] ;;
        claude_vm_bundles) [[ "$target" == "$HOME_ROOT/Library/Application Support/Claude/vm_bundles" ]] ;;
        ollama_models) [[ "$target" == "$HOME_ROOT/.ollama/models" ]] ;;
        xcode_derived_data) [[ "$target" == "$HOME_ROOT/Library/Developer/Xcode/DerivedData" ]] ;;
        chrome_code_sign_clones)
            [[ "$target" == "$VAR_FOLDERS_ROOT/"*"/X/com.google.Chrome.code_sign_clone" \
                || "$target" == "$VAR_FOLDERS_ROOT/"*"/T/com.google.Chrome.code_sign_clone" ]]
            ;;
        innorix_ex)
            [[ "$target" == "$HOME_ROOT/Applications/INNORIX-EX" \
                || "$target" == "$HOME_ROOT/Library/LaunchAgents/com.innorix.innorixes.plist" ]]
            ;;
        *) return 1 ;;
    esac
}

validate_target() {
    local recipe="$1"
    local target="$2"
    local parent canonical_parent canonical_target expected

    [[ "$target" == /* ]] || return 1
    case "$target" in
        *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
    esac
    allowed_target "$recipe" "$target" || return 1
    [[ ! -L "$target" ]] || return 1

    parent="$(/usr/bin/dirname "$target")"
    canonical_parent="$(cd -P "$parent" 2>/dev/null && /bin/pwd -P)" || return 1
    canonical_target="$canonical_parent/$(/usr/bin/basename "$target")"

    if [[ "$target" == "$HOME_ROOT"* ]]; then
        expected="$HOME_ROOT${target#"$HOME_ROOT"}"
    elif [[ "$target" == "$APPLICATIONS_ROOT"* ]]; then
        expected="$APPLICATIONS_ROOT${target#"$APPLICATIONS_ROOT"}"
    elif [[ "$target" == "$VAR_FOLDERS_ROOT"* ]]; then
        local canonical_var
        canonical_var="$(cd -P "$VAR_FOLDERS_ROOT" 2>/dev/null && /bin/pwd -P)" || return 1
        expected="$canonical_var${target#"$VAR_FOLDERS_ROOT"}"
    else
        return 1
    fi
    [[ "$canonical_target" == "$expected" ]]
}

bounded_du_kb() {
    local target="$1"
    local output pid attempts=0 status
    output="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/pch-cleanup-du.XXXXXX")" || return 1
    # -x keeps the measurement on the target's own filesystem so a volume mounted
    # beneath the target cannot inflate the reclaim estimate we show the owner.
    /usr/bin/du -skx "$target" > "$output" 2>/dev/null &
    pid=$!
    while /bin/kill -0 "$pid" >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ "$attempts" -ge 300 ]]; then
            /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
            /bin/sleep 1
            /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
            wait "$pid" 2>/dev/null || true
            /bin/rm -f "$output"
            return 124
        fi
        /bin/sleep 0.1
    done
    wait "$pid"
    status=$?
    if [[ "$status" -ne 0 ]]; then
        /bin/rm -f "$output"
        return "$status"
    fi
    /usr/bin/awk 'NR == 1 && $1 ~ /^[0-9]+$/ {print $1; found=1} END {exit !found}' "$output"
    status=$?
    /bin/rm -f "$output"
    return "$status"
}

size_kb() {
    local target="$1"
    bounded_du_kb "$target"
}

remaining_targets_size_kb() {
    local total=0 target value unmeasured=0
    for target in "${TARGETS[@]}"; do
        [[ -e "$target" || -L "$target" ]] || continue
        value="$(size_kb "$target")" || { unmeasured=1; continue; }
        case "$value" in ''|*[!0-9]*) unmeasured=1; continue ;; esac
        total=$((total + value))
    done
    if [[ "${#STAGED_REMAINDERS[@]}" -gt 0 ]]; then
        for target in "${STAGED_REMAINDERS[@]}"; do
            [[ -e "$target" || -L "$target" ]] || continue
            value="$(size_kb "$target")" || { unmeasured=1; continue; }
            case "$value" in ''|*[!0-9]*) unmeasured=1; continue ;; esac
            total=$((total + value))
        done
    fi
    # A survivor that still exists but could not be sized would otherwise count
    # as 0 remaining and inflate reclaimedKB. Signal the uncertainty so the
    # caller falls back to the physically measured free-space gain.
    if [[ "$unmeasured" -eq 1 ]]; then
        /usr/bin/printf '__UNMEASURED__'
    else
        /usr/bin/printf '%s' "$total"
    fi
}

process_snapshot() {
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        if [[ -n "${PCH_PROCESS_LIST_FILE:-}" && -f "$PCH_PROCESS_LIST_FILE" ]]; then
            /bin/cat "$PCH_PROCESS_LIST_FILE"
        fi
    else
        /bin/ps -axo command= 2>/dev/null || true
    fi
}

process_snapshot_with_pid() {
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        if [[ -n "${PCH_PROCESS_LIST_WITH_PID_FILE:-}" && -f "$PCH_PROCESS_LIST_WITH_PID_FILE" ]]; then
            /bin/cat "$PCH_PROCESS_LIST_WITH_PID_FILE"
        fi
    else
        /bin/ps -axo pid=,command= 2>/dev/null || true
    fi
}

# 이 도구 자신과, 이 도구가 크기를 재려고 띄운 측정 프로세스를 증거에서 뺀다.
#
# 측정 프로세스를 빼야 하는 이유: storage.sh와 storage_watch.sh는 대상 경로를
# 인자로 주는 `du -sk`를 실제로 띄운다. 매칭이 전체 명령줄 기준이므로 그 du가
# 자기 대상 경로에 걸려, 사용자가 닫을 수 없는 프로세스 때문에 정리가 차단된다.
# storage_watch는 LaunchAgent로 매시간 돈다.
#
# 반대로 자기 제외는 좁혀야 한다. 이전에는 명령줄에 제품명이 들어간 모든
# 프로세스를 버려서, 프로젝트 경로 안에서 도는 무관한 프로세스까지 증거에서
# 사라졌다. 그건 오탐이 아니라 미탐이다.
exclude_self_and_measurement() {
    # 측정 도구는 그것이 명령줄 **전체**를 차지할 때만 뺀다. 문자열 포함으로
    # 걸러내면 `sh -c "pnpm install && du -sk ."`처럼 정당한 차단자가 du를
    # 함께 부르기만 해도 증거에서 사라진다. 그건 오탐보다 위험한 미탐이다.
    /usr/bin/grep -v -E \
        'scripts/cleanup\.sh|/usr/bin/grep -E|Contents/MacOS/Modore' \
        | /usr/bin/grep -v -E \
            '^(/usr/bin/du|/usr/bin/mdls|/usr/libexec/PlistBuddy)( -[^ ]+)* [^&|;]*$'
}

matching_processes() {
    [[ -n "$PROCESS_PATTERN" ]] || return 0
    process_snapshot \
        | /usr/bin/grep -E "$PROCESS_PATTERN" \
        | exclude_self_and_measurement \
        | /usr/bin/head -n 5 \
        | /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g' \
        | /usr/bin/cut -c 1-240 \
        || true
}

process_display_name() {
    local command="$1"
    local display_name
    if [[ "$RECIPE_ID" == app_uninstall:* ]]; then
        display_name="$LABEL"
    else
        case "$command" in
            # 제품 이름을 먼저 판정한다. 자동화 플래그를 앞에 두면 Chrome 업데이터,
            # Claude Desktop, Codex의 headless 런타임이 모두 "Playwright"로 표시돼
            # 사용자가 무엇을 닫아야 하는지 알 수 없다. Playwright 자신은 이제
            # 경로와 실행기 이름으로만 매칭되므로 앞에 둘 이유가 없다.
            *playwright*|*Playwright*) display_name="Playwright" ;;
            *"Google Chrome Helper"*) display_name="Google Chrome Helper" ;;
            *"Google Chrome"*|*ksadmin*|*GoogleSoftwareUpdate*) display_name="Google Chrome" ;;
            *Codex*|*codex*|*node_repl*|*SkyComputerUseClient*) display_name="Codex" ;;
            *Claude*|*claude*|*local-agent-mode*) display_name="Claude" ;;
            *pnpm*) display_name="pnpm" ;;
            *npm*|*npx*|*node*) display_name="Node/npm" ;;
            *GradleDaemon*|*org.gradle*|*gradlew*) display_name="Gradle" ;;
            *CocoaPods*|*"/pod "*|pod\ *|pod) display_name="CocoaPods" ;;
            *flutter*|*dart*) display_name="Dart/Flutter" ;;
            *Xcode*|*xcodebuild*|*XCBBuildService*|*SourceKitService*) display_name="Xcode/build tool" ;;
            *INNORIX*|*innorix*) display_name="INNORIX" ;;
            *) display_name="관련 프로세스" ;;
        esac
    fi
    /usr/bin/printf '%s' "$display_name"
}

display_process_names() {
    local command
    matching_processes | while IFS= read -r command; do
        [[ -n "$command" ]] || continue
        /usr/bin/printf '%s\n' "$(process_display_name "$command")"
    done | /usr/bin/awk '!seen[$0]++'
}

# `ps`는 PID를 자리수에 맞춰 오른쪽 정렬해 출력하므로 줄이 공백으로 시작한다.
# 그래서 실행 위치를 뜻하는 `^` 앵커 패턴은 이 형식에서 절대 매칭되지 않는다.
# 차단 판정은 PID 없는 표본을 쓰기 때문에 정상 동작하지만, 사용자에게 보여줄
# 증거 목록만 비어서 "차단됐는데 무엇을 닫아야 하는지 알려주지 않는" 상태가
# 됐다. 매칭할 때는 명령줄을 줄 앞으로 보내고, 표시할 때 PID를 되돌린다.
matching_processes_with_pid() {
    [[ -n "$PROCESS_PATTERN" ]] || return 0
    process_snapshot_with_pid \
        | /usr/bin/awk '
            /^[[:space:]]*[0-9]+[[:space:]]/ {
                pid = $1
                line = $0
                sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
                printf "%s\t%s\n", line, pid
            }' \
        | /usr/bin/grep -E "$PROCESS_PATTERN" \
        | exclude_self_and_measurement \
        | /usr/bin/head -n 5 \
        | /usr/bin/awk -F'\t' '
            NF >= 2 {
                pid = $NF
                command = $1
                for (index_field = 2; index_field < NF; index_field++) {
                    command = command "\t" $index_field
                }
                printf "%s %s\n", pid, command
            }' \
        | /usr/bin/sed -E 's/[[:space:]]+/ /g' \
        | /usr/bin/cut -c 1-240 \
        || true
}

display_process_evidence() {
    local pid command display_name
    # PID 표본을 주지 않은 테스트는 이름만 확인한다. 실제 실행과, PID 표본을 준
    # 테스트는 아래 경로를 지나므로 앵커 동작이 검증된다.
    if [[ "${PCH_TEST_MODE:-0}" == "1" && -z "${PCH_PROCESS_LIST_WITH_PID_FILE:-}" ]]; then
        display_process_names
        return
    fi
    matching_processes_with_pid | while read -r pid command; do
        [[ "$pid" =~ ^[0-9]+$ && -n "$command" ]] || continue
        display_name="$(process_display_name "$command")"
        /usr/bin/printf '%s · PID %s\n' "$display_name" "$pid"
    done | /usr/bin/awk '!seen[$0]++'
}

sha256_stream() {
    if [[ -x /usr/bin/shasum ]]; then
        /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
    else
        /usr/bin/openssl dgst -sha256 | /usr/bin/awk '{print $NF}'
    fi
}

process_fingerprint() {
    matching_processes | sha256_stream
}

target_stat_fields() {
    local target="$1"
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        /usr/bin/stat -f $'%d\t%i\t%HT\t%z\t%m' "$target" 2>/dev/null
    else
        /usr/bin/stat -c $'%d\t%i\t%F\t%s\t%Y' "$target" 2>/dev/null
    fi
}

path_device() {
    local target="$1"
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        /usr/bin/stat -f '%d' "$target" 2>/dev/null
    else
        /usr/bin/stat -c '%d' "$target" 2>/dev/null
    fi
}

path_mode() {
    local target="$1"
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        /usr/bin/stat -f '%Lp' "$target" 2>/dev/null
    else
        /usr/bin/stat -c '%a' "$target" 2>/dev/null
    fi
}

# True when a different filesystem is currently mounted strictly beneath target.
# The same-device check on the top-level target cannot see a volume mounted
# inside the tree; moving such a target (same-device rename) relocates the nested
# mount into staging, and a subsequent unbounded rm -rf would cross into and
# permanently destroy that foreign volume. We consult the live mount table
# (cheap, read-only). Darwin only — the shipped cleanup engine is macOS-only;
# on other platforms the caller relies on the device-bounded delete below.
subtree_contains_foreign_mount() {
    local target="$1" canonical mp
    [[ "$(/usr/bin/uname -s)" == "Darwin" ]] || return 1
    canonical="$(cd -P "$target" 2>/dev/null && /bin/pwd -P)" || return 1
    [[ -n "$canonical" && "$canonical" != "/" ]] || return 1
    while IFS= read -r mp; do
        mp="${mp#* on }"
        mp="${mp% (*}"
        [[ -n "$mp" ]] || continue
        if [[ "$mp" == "$canonical/"* ]]; then
            return 0
        fi
    done < <(/sbin/mount 2>/dev/null)
    return 1
}

# Delete a staged tree without ever crossing into another filesystem. find's
# -xdev confines traversal to root's own device, so a foreign volume mounted
# inside the staged tree is never entered and its contents cannot be removed.
# Defense in depth behind the pre-move subtree_contains_foreign_mount guard, and
# the sole protection against a mount that races in after that check.
remove_tree_same_device() {
    local root="$1"
    [[ -n "$root" ]] || return 1
    /usr/bin/find "$root" -xdev -depth -delete 2>/dev/null
}

prepare_private_directory() {
    local directory="$1"
    local canonical
    /bin/mkdir -p "$directory" || return 1
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    canonical="$(cd -P "$directory" 2>/dev/null && /bin/pwd -P)" || return 1
    [[ "$canonical" == "$directory" ]] || return 1
    /bin/chmod 700 "$directory" 2>/dev/null || return 1
}

write_current_manifest() {
    local output="$1"
    local created_epoch="${2:-}"
    local target fields value total=0 count=0 fingerprint
    if [[ -z "$created_epoch" ]]; then
        created_epoch="$(/bin/date '+%s')" || return 1
    fi
    [[ "$created_epoch" =~ ^[0-9]+$ ]] || return 1
    fingerprint="$(process_fingerprint)" || return 1
    : > "$output" || return 1
    /bin/chmod 600 "$output" 2>/dev/null || return 1
    {
        /usr/bin/printf 'version\t%s\n' "$PROTOCOL_VERSION"
        /usr/bin/printf 'recipeId\t%s\n' "$RECIPE_ID"
        /usr/bin/printf 'actionMode\t%s\n' "$REMOVE_MODE"
        /usr/bin/printf 'createdEpoch\t%s\n' "$created_epoch"
        /usr/bin/printf 'processFingerprint\t%s\n' "$fingerprint"
        if [[ "${#TARGETS[@]}" -gt 0 ]]; then
            for target in "${TARGETS[@]}"; do
                validate_target "$RECIPE_ID" "$target" || return 1
                fields="$(target_stat_fields "$target")" || return 1
                value="$(size_kb "$target")" || return 1
                case "$value" in ''|*[!0-9]*) return 1 ;; esac
                total=$((total + value))
                count=$((count + 1))
                /usr/bin/printf 'target\t%s\t%s\t%s\n' "$target" "$fields" "$value"
            done
        fi
        /usr/bin/printf 'targetCount\t%s\n' "$count"
        /usr/bin/printf 'estimatedKB\t%s\n' "$total"
    } >> "$output" || return 1
    MANIFEST_ESTIMATED_KB="$total"
    return 0
}

new_approval_token() {
    /usr/bin/openssl rand -hex 32 2>/dev/null
}

create_approval_manifest() {
    local token temporary destination
    prepare_private_directory "$APPROVAL_DIR" || return 1
    token="$(new_approval_token)" || return 1
    [[ "$token" =~ ^[0-9a-f]{64}$ ]] || return 1
    temporary="$(/usr/bin/mktemp "$APPROVAL_DIR/.preview.XXXXXX")" || return 1
    if ! write_current_manifest "$temporary"; then
        /bin/rm -f "$temporary"
        return 1
    fi
    destination="$APPROVAL_DIR/$token.tsv"
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
        /bin/rm -f "$temporary"
        return 1
    }
    /bin/mv "$temporary" "$destination" || {
        /bin/rm -f "$temporary"
        return 1
    }
    PREVIEW_APPROVAL_TOKEN="$token"
    return 0
}

# shellcheck disable=SC2329  # Invoked by the EXIT trap after token consumption.
cleanup_execution_manifest() {
    local exit_status=$?
    if [[ -n "$EXECUTION_MANIFEST" ]]; then
        /bin/rm -f "$EXECUTION_MANIFEST" 2>/dev/null || true
        EXECUTION_MANIFEST=""
    fi
    return "$exit_status"
}

consume_approval_manifest() {
    local source executing
    [[ "$APPROVAL_TOKEN" =~ ^[0-9a-f]{64}$ ]] || return 1
    prepare_private_directory "$APPROVAL_DIR" || return 1
    source="$APPROVAL_DIR/$APPROVAL_TOKEN.tsv"
    executing="$APPROVAL_DIR/.executing-$APPROVAL_TOKEN-$$.tsv"
    [[ -f "$source" && ! -L "$source" && ! -e "$executing" && ! -L "$executing" ]] \
        || return 1
    /bin/mv "$source" "$executing" || return 1
    EXECUTION_MANIFEST="$executing"
    trap cleanup_execution_manifest EXIT
    [[ -f "$EXECUTION_MANIFEST" && ! -L "$EXECUTION_MANIFEST" ]] || return 1
    return 0
}

validate_consumed_approval_manifest() {
    local temporary created_epoch now age
    [[ -n "$EXECUTION_MANIFEST" \
        && -f "$EXECUTION_MANIFEST" \
        && ! -L "$EXECUTION_MANIFEST" ]] || return 1
    created_epoch="$(/usr/bin/awk -F '\t' '$1 == "createdEpoch" {print $2; count++} END {if (count != 1) exit 1}' "$EXECUTION_MANIFEST")" \
        || return 1
    [[ "$created_epoch" =~ ^[0-9]+$ ]] || return 1
    now="$(/bin/date '+%s')" || return 1
    age=$((now - created_epoch))
    if [[ "$age" -lt 0 || "$age" -gt "$APPROVAL_TTL_SECONDS" ]]; then
        return 2
    fi
    temporary="$(/usr/bin/mktemp "$APPROVAL_DIR/.execute.XXXXXX")" || return 1
    if ! write_current_manifest "$temporary" "$created_epoch"; then
        /bin/rm -f "$temporary"
        return 1
    fi
    if ! /usr/bin/cmp -s "$EXECUTION_MANIFEST" "$temporary"; then
        /bin/rm -f "$temporary"
        return 1
    fi
    /bin/rm -f "$temporary"
    return 0
}

manifest_identity_matches() {
    local approved_target="$1"
    local actual_target="${2:-$1}"
    local key path device inode kind bytes modified size actual
    while IFS=$'\t' read -r key path device inode kind bytes modified size; do
        [[ "$key" == "target" && "$path" == "$approved_target" ]] || continue
        [[ "$size" =~ ^[0-9]+$ ]] || return 1
        actual="$(target_stat_fields "$actual_target")" || return 1
        [[ "$actual" == "$device"$'\t'"$inode"$'\t'"$kind"$'\t'"$bytes"$'\t'"$modified" ]]
        return $?
    done < "$EXECUTION_MANIFEST"
    return 1
}

manifest_size_matches() {
    local approved_target="$1"
    local actual_target="${2:-$1}"
    local key path _device _inode _kind _bytes _modified approved_size current_size
    while IFS=$'\t' read -r key path _device _inode _kind _bytes _modified approved_size; do
        [[ "$key" == "target" && "$path" == "$approved_target" ]] || continue
        [[ "$approved_size" =~ ^[0-9]+$ ]] || return 1
        current_size="$(size_kb "$actual_target")" || return 1
        [[ "$current_size" =~ ^[0-9]+$ && "$current_size" == "$approved_size" ]]
        return $?
    done < "$EXECUTION_MANIFEST"
    return 1
}

preview_status() {
    local target matches
    PREVIEW_STATUS="ready"
    BLOCKED_REASON=""
    RUNNING_PROCESSES=""

    if [[ "${#TARGETS[@]}" -eq 0 ]]; then
        PREVIEW_STATUS="empty"
        return 0
    fi

    for target in "${TARGETS[@]}"; do
        if ! validate_target "$RECIPE_ID" "$target"; then
            PREVIEW_STATUS="blocked"
            BLOCKED_REASON="안전 경계를 벗어나거나 심볼릭 링크인 대상이 있어 실행을 차단했습니다."
            return 0
        fi
    done

    if [[ -n "$RECIPE_BLOCK_REASON" ]]; then
        PREVIEW_STATUS="blocked"
        BLOCKED_REASON="$RECIPE_BLOCK_REASON"
        return 0
    fi

    matches="$(matching_processes)"
    if [[ -n "$matches" ]]; then
        RUNNING_PROCESSES="$(display_process_evidence | /usr/bin/tr '\n' ';' | /usr/bin/sed 's/;$//')"
        if [[ "$PROCESS_POLICY" == "block" ]]; then
            PREVIEW_STATUS="blocked"
            BLOCKED_REASON="${PROCESS_NOTE:-관련 프로세스를 먼저 종료하세요.}"
        fi
    fi
}

emit_state() {
    local operation="$1"
    local status="$2"
    local estimated_kb="$3"
    local target staged
    emit "version" "$PROTOCOL_VERSION"
    emit "operation" "$operation"
    emit "status" "$status"
    emit "recipeId" "$RECIPE_ID"
    emit "label" "$LABEL"
    emit "estimatedKB" "$estimated_kb"
    emit "estimateMeasured" "$ESTIMATE_MEASURED"
    emit "actionMode" "$REMOVE_MODE"
    emit "warning" "$WARNING"
    emit "description" "$DESCRIPTION"
    emit "avoidWhen" "$AVOID_WHEN"
    emit "processNote" "$PROCESS_NOTE"
    emit "blockedReason" "${BLOCKED_REASON:-}"
    emit "runningProcesses" "${RUNNING_PROCESSES:-}"
    emit "approvalToken" "$PREVIEW_APPROVAL_TOKEN"
    if [[ "${#TARGETS[@]}" -gt 0 ]]; then
        for target in "${TARGETS[@]}"; do
            emit "target" "$target"
        done
    fi
    if [[ "${#STAGED_REMAINDERS[@]}" -gt 0 ]]; then
        for staged in "${STAGED_REMAINDERS[@]}"; do
            emit "stagedRemainder" "$staged"
        done
    fi
    if [[ "${#SHARED_RESIDUE[@]}" -gt 0 ]]; then
        for target in "${SHARED_RESIDUE[@]}"; do
            emit "sharedResidue" "$target"
        done
    fi
    if [[ "${#REVIEW_RESIDUE[@]}" -gt 0 ]]; then
        for target in "${REVIEW_RESIDUE[@]}"; do
            emit "reviewResidue" "$target"
        done
    fi
}

stop_innorix() {
    local plist="$HOME_ROOT/Library/LaunchAgents/com.innorix.innorixes.plist"
    local domain
    domain="gui/$(/usr/bin/id -u)"
    if [[ -e "$plist" ]]; then
        /bin/launchctl bootout "$domain" "$plist" >/dev/null 2>&1 || true
    fi
    /bin/launchctl disable "$domain/com.innorix.innorixes" >/dev/null 2>&1 || true
    /usr/bin/pkill -TERM -f "$HOME_ROOT/Applications/INNORIX-EX/innorixes.app" >/dev/null 2>&1 || true
    /bin/sleep 1
    # 자체 파이프라인 대신 matching_processes를 재사용한다. 이전에는 제외가
    # cleanup.sh 하나뿐이어서 확인용 grep 자신이 ps 결과에 잡혔고, INNORIX가
    # 돌지 않아도 "종료하지 못했다"며 실행이 항상 중단됐다.
    if [[ -n "$(matching_processes)" ]]; then
        return 1
    fi
    return 0
}

prepare_trash_run() {
    local trash_root="$HOME_ROOT/.Trash"
    prepare_private_directory "$trash_root" || return 1
    TRASH_RUN="$trash_root/Modore-$(/bin/date -u '+%Y%m%dT%H%M%SZ')-$$"
    /bin/mkdir "$TRASH_RUN" || return 1
    /bin/chmod 700 "$TRASH_RUN" 2>/dev/null || return 1
}

prepare_staging_run() {
    prepare_private_directory "$STAGING_DIR" || return 1
    STAGING_RUN="$(/usr/bin/mktemp -d "$STAGING_DIR/.execute-$$.XXXXXX")" || return 1
    [[ -d "$STAGING_RUN" && ! -L "$STAGING_RUN" ]] || return 1
    /bin/chmod 700 "$STAGING_RUN" 2>/dev/null || return 1
}

rollback_single_move() {
    local source="$1"
    local destination="$2"
    [[ ! -e "$source" && ! -L "$source" ]] || return 1
    [[ -e "$destination" || -L "$destination" ]] || return 1
    /bin/mv "$destination" "$source"
}

record_staged_remainder() {
    local candidate="$1"
    local existing
    [[ -e "$candidate" || -L "$candidate" ]] || return 0
    if [[ "${#STAGED_REMAINDERS[@]}" -gt 0 ]]; then
        for existing in "${STAGED_REMAINDERS[@]}"; do
            [[ "$existing" != "$candidate" ]] || return 0
        done
    fi
    STAGED_REMAINDERS+=("$candidate")
}

apply_test_staged_destination_swap() {
    local destination="$1"
    local index="$2"
    local replacement saved
    TEST_STAGED_APPROVED_ORIGINAL=""
    [[ "${PCH_TEST_MODE:-0}" == "1" \
        && "${PCH_TEST_SWAP_STAGED_DESTINATION_AT:-0}" == "$index" ]] || return 0
    replacement="${PCH_TEST_SWAP_STAGED_DESTINATION_WITH:-}"
    saved="$destination.pch-approved-original"
    [[ -n "$replacement" \
        && "$replacement" != "$destination" \
        && "$replacement" != "$saved" \
        && ( -e "$replacement" || -L "$replacement" ) \
        && ! -L "$replacement" \
        && ! -e "$saved" \
        && ! -L "$saved" ]] || return 1
    /bin/mv "$destination" "$saved" || return 1
    TEST_STAGED_APPROVED_ORIGINAL="$saved"
    if ! /bin/mv "$replacement" "$destination"; then
        if /bin/mv "$saved" "$destination" 2>/dev/null; then
            TEST_STAGED_APPROVED_ORIGINAL=""
        fi
        return 1
    fi
    return 0
}

stage_and_remove_target() {
    local target="$1"
    local index="$2"
    local destination source_device staging_device mode
    destination="$STAGING_RUN/$index-$(/usr/bin/basename "$target")"
    [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
    source_device="$(path_device "$target")" || return 1
    staging_device="$(path_device "$STAGING_RUN")" || return 1
    [[ "$source_device" == "$staging_device" ]] || return 1
    if subtree_contains_foreign_mount "$target"; then
        EXECUTION_FAILURE_STATUS="blocked"
        BLOCKED_REASON="대상 하위에 다른 볼륨이 마운트되어 있어 이동을 중단했습니다. 해당 볼륨을 마운트 해제한 뒤 다시 미리보기하세요."
        return 1
    fi
    manifest_identity_matches "$target" "$target" || return 1
    mode="$(path_mode "$target")" || return 1
    apply_test_late_content_drift "$target" "$index" || return 1
    if ! manifest_size_matches "$target" "$target"; then
        EXECUTION_FAILURE_STATUS="blocked"
        BLOCKED_REASON="대상 콘텐츠 크기가 승인 이후 바뀌어 이동을 중단했습니다. 다시 미리보기하세요."
        return 1
    fi
    /bin/mv "$target" "$destination" || return 1
    if ! manifest_identity_matches "$target" "$destination" \
        || ! manifest_size_matches "$target" "$destination"; then
        rollback_single_move "$target" "$destination" || record_staged_remainder "$destination"
        return 1
    fi

    if [[ "$REMOVE_MODE" == "contents" ]]; then
        if ! /bin/mkdir "$target" || ! /bin/chmod "$mode" "$target" 2>/dev/null; then
            rollback_single_move "$target" "$destination" || record_staged_remainder "$destination"
            return 1
        fi
    fi

    if [[ "${PCH_TEST_MODE:-0}" == "1" && "${PCH_TEST_FAIL_STAGED_REMOVE_AT:-0}" == "$index" ]]; then
        record_staged_remainder "$destination"
        return 1
    fi
    if ! apply_test_staged_destination_swap "$destination" "$index"; then
        BLOCKED_REASON="격리된 대상의 삭제 직전 신원을 확인하지 못해 보존했습니다. 복구 경로를 확인하세요."
        record_staged_remainder "$destination"
        [[ -z "$TEST_STAGED_APPROVED_ORIGINAL" ]] \
            || record_staged_remainder "$TEST_STAGED_APPROVED_ORIGINAL"
        return 1
    fi
    if ! manifest_identity_matches "$target" "$destination" \
        || ! manifest_size_matches "$target" "$destination"; then
        BLOCKED_REASON="격리된 대상이 삭제 직전에 교체되어 삭제를 거부했습니다. 원본과 교체 항목을 복구 경로에 보존했습니다."
        record_staged_remainder "$destination"
        [[ -z "$TEST_STAGED_APPROVED_ORIGINAL" ]] \
            || record_staged_remainder "$TEST_STAGED_APPROVED_ORIGINAL"
        return 1
    fi
    if ! remove_tree_same_device "$destination"; then
        record_staged_remainder "$destination"
        return 1
    fi
    return 0
}

trash_destination_for() {
    local target="$1"
    local index="$2"
    /usr/bin/printf '%s/%s-%s' "$TRASH_RUN" "$index" "$(/usr/bin/basename "$target")"
}

prepare_transaction_journal() {
    local target destination index=0 recipe_name
    prepare_private_directory "$RECEIPT_DIR" || return 1
    recipe_name="${RECIPE_ID//[^A-Za-z0-9_.-]/_}"
    TRANSACTION_JOURNAL="$RECEIPT_DIR/$(/bin/date -u '+%Y%m%dT%H%M%SZ')-$recipe_name-$$.transaction.tsv"
    [[ ! -e "$TRANSACTION_JOURNAL" && ! -L "$TRANSACTION_JOURNAL" ]] || return 1
    set -o noclobber
    if ! exec 9> "$TRANSACTION_JOURNAL"; then
        set +o noclobber
        return 1
    fi
    set +o noclobber
    {
        /usr/bin/printf 'version\t%s\n' "$PROTOCOL_VERSION"
        /usr/bin/printf 'status\tpending\n'
        /usr/bin/printf 'recipeId\t%s\n' "$RECIPE_ID"
        for target in "${TARGETS[@]}"; do
            index=$((index + 1))
            destination="$(trash_destination_for "$target" "$index")"
            /usr/bin/printf 'move\t%s\t%s\n' "$target" "$destination"
        done
    } >&9 || return 1
}

preflight_trash_transaction() {
    local target destination index=0 target_device trash_device parent
    trash_device="$(path_device "$TRASH_RUN")" || return 1
    for target in "${TARGETS[@]}"; do
        index=$((index + 1))
        destination="$(trash_destination_for "$target" "$index")"
        parent="$(/usr/bin/dirname "$target")"
        validate_target "$RECIPE_ID" "$target" || return 1
        manifest_identity_matches "$target" "$target" || return 1
        manifest_size_matches "$target" "$target" || return 1
        [[ -w "$parent" ]] || return 1
        [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
        target_device="$(path_device "$target")" || return 1
        [[ "$target_device" == "$trash_device" ]] || return 1
        if subtree_contains_foreign_mount "$target"; then
            EXECUTION_FAILURE_STATUS="blocked"
            BLOCKED_REASON="대상 하위에 다른 볼륨이 마운트되어 있어 이동을 중단했습니다. 해당 볼륨을 마운트 해제한 뒤 다시 미리보기하세요."
            return 1
        fi
    done
    prepare_transaction_journal
}

rollback_trash_transaction() {
    local index rollback_failed=0 source destination
    index=$((MOVED_TARGETS_COUNT - 1))
    while [[ "$index" -ge 0 ]]; do
        source="${MOVED_SOURCES[$index]}"
        destination="${MOVED_DESTINATIONS[$index]}"
        if ! rollback_single_move "$source" "$destination"; then
            rollback_failed=1
        fi
        index=$((index - 1))
    done
    if [[ "$rollback_failed" -eq 0 ]]; then
        /usr/bin/printf 'status\trolled-back\n' >&9 2>/dev/null || true
        MOVED_TARGETS=()
        MOVED_SOURCES=()
        MOVED_DESTINATIONS=()
        MOVED_TARGETS_COUNT=0
        return 0
    fi
    /usr/bin/printf 'status\trollback-failed\n' >&9 2>/dev/null || true
    return 1
}

move_app_transaction() {
    local target destination index=0 matches
    if ! preflight_trash_transaction; then
        EXECUTION_FAILURE_STATUS="blocked"
        BLOCKED_REASON="앱과 모든 관련 항목을 원자적으로 이동할 권한 또는 동일 볼륨 조건을 확인하지 못했습니다. 아무것도 이동하지 않았습니다."
        return 1
    fi
    for target in "${TARGETS[@]}"; do
        index=$((index + 1))
        destination="$(trash_destination_for "$target" "$index")"
        matches="$(matching_processes)"
        if [[ -n "$matches" ]] || ! manifest_identity_matches "$target" "$target"; then
            if rollback_trash_transaction; then
                EXECUTION_FAILURE_STATUS="blocked"
                BLOCKED_REASON="앱 상태가 승인 이후 바뀌어 모든 이동을 되돌렸습니다. 다시 미리보기하세요."
            fi
            return 1
        fi
        if [[ "${PCH_TEST_MODE:-0}" == "1" && "${PCH_TEST_FAIL_TRASH_MOVE_AT:-0}" == "$index" ]]; then
            if rollback_trash_transaction; then
                EXECUTION_FAILURE_STATUS="blocked"
                BLOCKED_REASON="앱과 관련 데이터 이동을 시작하기 전에 안전하게 되돌렸습니다. 권한을 확인한 뒤 다시 미리보기하세요."
            fi
            return 1
        fi
        if ! apply_test_late_content_drift "$target" "$index" \
            || ! manifest_size_matches "$target" "$target"; then
            if rollback_trash_transaction; then
                EXECUTION_FAILURE_STATUS="blocked"
                BLOCKED_REASON="앱 대상 크기가 승인 이후 바뀌어 모든 이동을 되돌렸습니다. 다시 미리보기하세요."
            fi
            return 1
        fi
        if ! /bin/mv "$target" "$destination"; then
            if rollback_trash_transaction; then
                EXECUTION_FAILURE_STATUS="blocked"
                BLOCKED_REASON="앱을 휴지통으로 옮기지 못해 관련 데이터도 그대로 보존했습니다."
            fi
            return 1
        fi
        MOVED_SOURCES[MOVED_TARGETS_COUNT]="$target"
        MOVED_DESTINATIONS[MOVED_TARGETS_COUNT]="$destination"
        MOVED_TARGETS[MOVED_TARGETS_COUNT]="$target -> $destination"
        MOVED_TARGETS_COUNT=$((MOVED_TARGETS_COUNT + 1))
        if ! manifest_identity_matches "$target" "$destination" \
            || ! manifest_size_matches "$target" "$destination"; then
            if rollback_trash_transaction; then
                EXECUTION_FAILURE_STATUS="blocked"
                BLOCKED_REASON="승인한 앱 대상과 이동된 항목이 달라 모든 이동을 되돌렸습니다."
            fi
            return 1
        fi
    done
    /usr/bin/printf 'status\tcommitted\n' >&9 2>/dev/null || true
    return 0
}

unload_moved_app_launch_agents() {
    local index source destination domain
    domain="gui/$(/usr/bin/id -u)"
    index=0
    while [[ "$index" -lt "$MOVED_TARGETS_COUNT" ]]; do
        source="${MOVED_SOURCES[$index]}"
        destination="${MOVED_DESTINATIONS[$index]}"
        if [[ "$source" == "$HOME_ROOT/Library/LaunchAgents/"*.plist ]]; then
            /bin/launchctl bootout "$domain" "$destination" >/dev/null 2>&1 || true
        fi
        index=$((index + 1))
    done
}

apply_test_boundary_changes() {
    [[ "${PCH_TEST_MODE:-0}" == "1" ]] || return 0
    if [[ -n "${PCH_TEST_LATE_PROCESS_LIST_FILE:-}" && -f "${PCH_TEST_LATE_PROCESS_LIST_FILE}" ]]; then
        /bin/cp "$PCH_TEST_LATE_PROCESS_LIST_FILE" "$PCH_PROCESS_LIST_FILE" || return 1
    fi
    if [[ -n "${PCH_TEST_LATE_SIMCTL_LIST_FILE:-}" \
        && -f "${PCH_TEST_LATE_SIMCTL_LIST_FILE}" \
        && -n "${PCH_SIMCTL_LIST_FILE:-}" ]]; then
        /bin/cp "$PCH_TEST_LATE_SIMCTL_LIST_FILE" "$PCH_SIMCTL_LIST_FILE" || return 1
    fi
    if [[ -n "${PCH_TEST_LATE_SIMULATOR_KEEP_FILE:-}" \
        && -f "${PCH_TEST_LATE_SIMULATOR_KEEP_FILE}" ]]; then
        /bin/mkdir -p "$(/usr/bin/dirname "$SIMULATOR_KEEP_FILE")" || return 1
        /bin/cp "$PCH_TEST_LATE_SIMULATOR_KEEP_FILE" "$SIMULATOR_KEEP_FILE" || return 1
    fi
    if [[ -n "${PCH_TEST_SWAP_TARGET_WITH_SYMLINK_TO:-}" && "${#TARGETS[@]}" -gt 0 ]]; then
        local target="${TARGETS[0]}"
        local saved="$target.pch-approved-original"
        [[ ! -e "$saved" && ! -L "$saved" ]] || return 1
        /bin/mv "$target" "$saved" || return 1
        /bin/ln -s "$PCH_TEST_SWAP_TARGET_WITH_SYMLINK_TO" "$target" || {
            /bin/mv "$saved" "$target" 2>/dev/null || true
            return 1
        }
    fi
}

apply_test_late_content_drift() {
    local target="$1"
    local index="$2"
    [[ "${PCH_TEST_MODE:-0}" == "1" \
        && "${PCH_TEST_LATE_CONTENT_AT:-0}" == "$index" ]] || return 0
    [[ -n "${PCH_TEST_LATE_CONTENT_FILE:-}" \
        && -f "$PCH_TEST_LATE_CONTENT_FILE" \
        && ! -L "$PCH_TEST_LATE_CONTENT_FILE" \
        && -d "$target" \
        && ! -L "$target" ]] || return 1
    /bin/cp "$PCH_TEST_LATE_CONTENT_FILE" "$target/.pch-test-late-content"
}

destructive_boundary_ready() {
    local target matches
    [[ -z "$RECIPE_BLOCK_REASON" ]] || {
        BLOCKED_REASON="$RECIPE_BLOCK_REASON"
        return 1
    }
    for target in "${TARGETS[@]}"; do
        validate_target "$RECIPE_ID" "$target" || return 1
        manifest_identity_matches "$target" "$target" || return 1
        manifest_size_matches "$target" "$target" || return 1
    done
    matches="$(matching_processes)"
    if [[ -n "$matches" ]]; then
        RUNNING_PROCESSES="$(display_process_evidence | /usr/bin/tr '\n' ';' | /usr/bin/sed 's/;$//')"
        BLOCKED_REASON="${PROCESS_NOTE:-관련 프로세스를 먼저 종료하세요.}"
        return 1
    fi
    return 0
}

available_kb() {
    /bin/df -Pk "$HOME_ROOT" 2>/dev/null | /usr/bin/awk 'NR == 2 {print $4; exit}'
}

write_receipt() {
    local status="$1"
    local estimated_kb="$2"
    local reclaimed_kb="$3"
    local physical_delta_kb="$4"
    local timestamp receipt target moved staged receipt_recipe
    timestamp="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    receipt_recipe="${RECIPE_ID//[^A-Za-z0-9_.-]/_}"
    receipt="$RECEIPT_DIR/$(/bin/date -u '+%Y%m%dT%H%M%SZ')-$receipt_recipe-$$.tsv"
    prepare_private_directory "$RECEIPT_DIR" || return 1
    [[ ! -e "$receipt" && ! -L "$receipt" ]] || return 1
    set -o noclobber
    if ! exec 8> "$receipt"; then
        set +o noclobber
        return 1
    fi
    set +o noclobber
    {
        /usr/bin/printf 'version\t%s\n' "$PROTOCOL_VERSION"
        /usr/bin/printf 'timestamp\t%s\n' "$timestamp"
        /usr/bin/printf 'status\t%s\n' "$status"
        /usr/bin/printf 'recipeId\t%s\n' "$RECIPE_ID"
        /usr/bin/printf 'label\t%s\n' "$(/usr/bin/printf '%s' "$LABEL" | /usr/bin/tr -d '\t\r\n')"
        /usr/bin/printf 'estimatedKB\t%s\n' "$estimated_kb"
        /usr/bin/printf 'reclaimedKB\t%s\n' "$reclaimed_kb"
        /usr/bin/printf 'physicalDeltaKB\t%s\n' "$physical_delta_kb"
        /usr/bin/printf 'actionMode\t%s\n' "$REMOVE_MODE"
        /usr/bin/printf 'trashRun\t%s\n' "$TRASH_RUN"
        for target in "${TARGETS[@]}"; do
            /usr/bin/printf 'target\t%s\n' "$target"
        done
        if [[ "$MOVED_TARGETS_COUNT" -gt 0 ]]; then
            for moved in "${MOVED_TARGETS[@]}"; do
                /usr/bin/printf 'moved\t%s\n' "$moved"
            done
        fi
        if [[ "${#STAGED_REMAINDERS[@]}" -gt 0 ]]; then
            for staged in "${STAGED_REMAINDERS[@]}"; do
                /usr/bin/printf 'stagedRemainder\t%s\n' "$staged"
            done
        fi
    } >&8 || { exec 8>&-; return 1; }
    exec 8>&-
    RECEIPT_PATH="$receipt"
    return 0
}

list_recipes() {
    local recipe
    for recipe in \
        npm_cache pnpm_store playwright_browsers gradle_cache cocoapods_cache pub_cache \
        codex_runtime_cache codex_temp_cache claude_vm_bundles xcode_derived_data \
        chrome_code_sign_clones innorix_ex; do
        define_recipe "$recipe"
        emit "recipe" "$recipe"
        emit "label" "$LABEL"
    done
}

parse_arguments() {
    case "${1:-}" in
        --list)
            OPERATION="list"
            shift
            [[ "$#" -eq 0 ]] || fail_usage "--list에는 추가 인수를 사용할 수 없습니다."
            ;;
        --preview|--execute)
            OPERATION="${1#--}"
            RECIPE_ID="${2:-}"
            [[ -n "$RECIPE_ID" ]] || fail_usage "recipe ID가 필요합니다."
            shift 2
            while [[ "$#" -gt 0 ]]; do
                case "$1" in
                    --owner-approved) OWNER_APPROVED="true" ;;
                    --approval-token-file)
                        [[ "$#" -ge 2 ]] || fail_usage "--approval-token-file 값이 필요합니다."
                        [[ -z "$APPROVAL_INPUT_KIND" ]] \
                            || fail_usage "승인 토큰 입력은 하나만 사용할 수 있습니다."
                        APPROVAL_INPUT_KIND="file"
                        APPROVAL_TOKEN_FILE="$2"
                        shift
                        ;;
                    --approval-token)
                        [[ "$#" -ge 2 ]] || fail_usage "--approval-token 값이 필요합니다."
                        [[ -z "$APPROVAL_INPUT_KIND" ]] \
                            || fail_usage "승인 토큰 입력은 하나만 사용할 수 있습니다."
                        APPROVAL_INPUT_KIND="legacy"
                        APPROVAL_TOKEN="$2"
                        shift
                        ;;
                    *) fail_usage "알 수 없는 옵션: $1" ;;
                esac
                shift
            done
            ;;
        *) fail_usage "작업을 지정하세요." ;;
    esac
}

run_preview() {
    preview_status
    if [[ "$PREVIEW_STATUS" == "ready" ]]; then
        if create_approval_manifest; then
            ESTIMATED_KB="$MANIFEST_ESTIMATED_KB"
            ESTIMATE_MEASURED="true"
        else
            PREVIEW_STATUS="blocked"
            BLOCKED_REASON="대상 크기와 파일 신원을 안전하게 측정하지 못했습니다. 파일시스템 상태를 확인한 뒤 다시 시도하세요."
            PREVIEW_APPROVAL_TOKEN=""
        fi
    elif [[ "$PREVIEW_STATUS" == "empty" ]]; then
        ESTIMATE_MEASURED="true"
    fi
    emit_state "preview" "$PREVIEW_STATUS" "$ESTIMATED_KB"
}

emit_final_result() {
    emit_state "execute" "$RESULT_STATUS" "$ESTIMATED_KB"
    emit "reclaimedKB" "$RECLAIMED_KB"
    emit "physicalDeltaKB" "$PHYSICAL_DELTA_KB"
    emit "receipt" "$RECEIPT_PATH"
    emit "trashRun" "$TRASH_RUN"

    [[ "$RESULT_STATUS" == "complete" ]] && return 0
    [[ "$RESULT_STATUS" == "blocked" ]] && return 3
    return 4
}

run_execute() {
    if [[ "$OWNER_APPROVED" != "true" ]]; then
        /usr/bin/printf 'ERROR: 실행에는 --owner-approved가 필요합니다.\n' >&2
        return 2
    fi

    if [[ -z "$APPROVAL_INPUT_KIND" ]]; then
        /usr/bin/printf 'ERROR: 실행에는 미리보기에서 받은 --approval-token-file이 필요합니다.\n' >&2
        return 2
    fi

    if [[ "$APPROVAL_INPUT_KIND" == "file" ]] \
        && ! read_approval_token_file "$APPROVAL_TOKEN_FILE"; then
        /usr/bin/printf 'ERROR: 승인 토큰 파일은 정확한 64자리 16진수 정규 FD여야 합니다.\n' >&2
        return 2
    fi

    if ! consume_approval_manifest; then
        PREVIEW_STATUS="blocked"
        BLOCKED_REASON="미리보기 승인을 일회성 실행으로 잠그지 못했습니다. 다시 미리보기하세요."
        emit_state "execute" "$PREVIEW_STATUS" "$ESTIMATED_KB"
        return 3
    fi

    if ! validate_consumed_approval_manifest; then
        PREVIEW_STATUS="blocked"
        BLOCKED_REASON="미리보기 이후 대상, 크기 또는 실행 프로세스가 바뀌었습니다. 승인은 소비되었으므로 다시 미리보기하세요."
        emit_state "execute" "$PREVIEW_STATUS" "$ESTIMATED_KB"
        return 3
    fi
    ESTIMATED_KB="$MANIFEST_ESTIMATED_KB"
    ESTIMATE_MEASURED="true"

    if [[ "$RECIPE_ID" == "innorix_ex" ]] && ! stop_innorix; then
        BLOCKED_REASON="INNORIX 프로세스를 종료하지 못해 파일 삭제를 중단했습니다."
        PREVIEW_STATUS="blocked"
        emit_state "execute" "$PREVIEW_STATUS" "$ESTIMATED_KB"
        return 3
    fi

    if ! apply_test_boundary_changes || ! destructive_boundary_ready; then
        PREVIEW_STATUS="blocked"
        [[ -n "$BLOCKED_REASON" ]] || BLOCKED_REASON="삭제 직전 대상 신원이 바뀌어 실행을 중단했습니다. 아무것도 삭제하지 않았습니다."
        emit_state "execute" "$PREVIEW_STATUS" "$ESTIMATED_KB"
        return 3
    fi

    if [[ "$REMOVE_MODE" == "trash" ]]; then
        prepare_trash_run || {
            PREVIEW_STATUS="blocked"
            BLOCKED_REASON="사용자 휴지통에 안전한 이동 폴더를 만들지 못했습니다."
            emit_state "execute" "$PREVIEW_STATUS" "$ESTIMATED_KB"
            return 3
        }
    elif [[ "$REMOVE_MODE" != "simulator" || "${PCH_TEST_MODE:-0}" == "1" ]]; then
        prepare_staging_run || {
            PREVIEW_STATUS="blocked"
            BLOCKED_REASON="검증된 대상을 격리할 안전한 임시 폴더를 만들지 못했습니다."
            emit_state "execute" "$PREVIEW_STATUS" "$ESTIMATED_KB"
            return 3
        }
    fi

    FREE_BEFORE="$(available_kb)"
    case "$FREE_BEFORE" in ''|*[!0-9]*) FREE_BEFORE=0 ;; esac
    FAILED=0
    TARGET_INDEX=0
    if [[ "$RECIPE_ID" == app_uninstall:* ]]; then
        if move_app_transaction; then
            unload_moved_app_launch_agents
        else
            FAILED=1
        fi
    elif [[ "$REMOVE_MODE" == "simulator" ]]; then
        if [[ -n "$(matching_processes)" ]] \
            || ! manifest_identity_matches "${TARGETS[0]}" "${TARGETS[0]}" \
            || ! manifest_size_matches "${TARGETS[0]}" "${TARGETS[0]}"; then
            FAILED=1
            EXECUTION_FAILURE_STATUS="blocked"
            BLOCKED_REASON="Simulator 데이터가 승인 이후 바뀌어 삭제를 중단했습니다."
        elif ! simulator_delete_boundary_ready; then
            FAILED=1
            EXECUTION_FAILURE_STATUS="blocked"
        elif [[ "${PCH_TEST_MODE:-0}" == "1" && -n "${PCH_SIMCTL_DELETE_LOG:-}" ]]; then
            if ! stage_and_remove_target "${TARGETS[0]}" 1; then
                FAILED=1
            elif ! /usr/bin/printf '%s\n' "$SIMULATOR_UUID" >> "$PCH_SIMCTL_DELETE_LOG"; then
                FAILED=1
            fi
        elif [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
            FAILED=1
            EXECUTION_FAILURE_STATUS="blocked"
            BLOCKED_REASON="테스트 Simulator 삭제 로그가 격리 루트에 없어 실행을 중단했습니다."
        else
            if ! manifest_size_matches "${TARGETS[0]}" "${TARGETS[0]}" \
                || ! simulator_delete_boundary_ready; then
                FAILED=1
                EXECUTION_FAILURE_STATUS="blocked"
                [[ -n "$BLOCKED_REASON" ]] \
                    || BLOCKED_REASON="Simulator 데이터 크기가 승인 이후 바뀌어 삭제를 중단했습니다."
            elif ! /usr/bin/xcrun simctl delete "$SIMULATOR_UUID"; then
                FAILED=1
            elif [[ -e "${TARGETS[0]}" || -L "${TARGETS[0]}" ]]; then
                # simctl delete exiting 0 only means CoreSimulator's daemon
                # accepted the request, not that the on-disk device directory
                # is actually gone -- unlike the staged-move path (whose
                # remove_tree_same_device is a direct find -delete, its own
                # exit code IS the postcondition), simctl is an opaque,
                # daemon-mediated tool. Confirmed synchronous on a healthy
                # system (directory gone the instant delete returns, no
                # retry/poll needed here) -- so if it's still present, the
                # deletion genuinely didn't complete and must not be reported
                # as success.
                FAILED=1
                BLOCKED_REASON="Simulator 삭제 명령은 성공했지만 기기 데이터가 실제로 지워지지 않았습니다."
            fi
        fi
    else
        for target in "${TARGETS[@]}"; do
            TARGET_INDEX=$((TARGET_INDEX + 1))
            if [[ -n "$(matching_processes)" ]] \
                || ! validate_target "$RECIPE_ID" "$target" \
                || ! manifest_identity_matches "$target" "$target" \
                || ! manifest_size_matches "$target" "$target"; then
                FAILED=1
                EXECUTION_FAILURE_STATUS="blocked"
                BLOCKED_REASON="실행 중 대상 또는 관련 프로세스 상태가 바뀌어 남은 정리를 중단했습니다."
                break
            fi
            if ! stage_and_remove_target "$target" "$TARGET_INDEX"; then
                FAILED=1
                break
            fi
        done
    fi

    FREE_AFTER="$(available_kb)"
    case "$FREE_AFTER" in ''|*[!0-9]*) FREE_AFTER=0 ;; esac
    PHYSICAL_DELTA_KB=$((FREE_AFTER - FREE_BEFORE))
    [[ "$PHYSICAL_DELTA_KB" -ge 0 ]] || PHYSICAL_DELTA_KB=0
    REMAINING_KB="$(remaining_targets_size_kb)"
    if [[ "$REMAINING_KB" == "__UNMEASURED__" ]]; then
        # Cannot verify how much remains; report only the measured free-space gain
        # rather than overstating logical reclaim.
        RECLAIMED_KB="$PHYSICAL_DELTA_KB"
    else
        RECLAIMED_KB=$((ESTIMATED_KB - REMAINING_KB))
        [[ "$RECLAIMED_KB" -ge 0 ]] || RECLAIMED_KB=0
    fi

    RESULT_STATUS="complete"
    [[ "$FAILED" -eq 0 ]] || RESULT_STATUS="$EXECUTION_FAILURE_STATUS"
    RECEIPT_PATH=""
    write_receipt "$RESULT_STATUS" "$ESTIMATED_KB" "$RECLAIMED_KB" "$PHYSICAL_DELTA_KB" || FAILED=1
    [[ "$FAILED" -eq 0 ]] || {
        [[ "$RESULT_STATUS" == "blocked" ]] || RESULT_STATUS="partial"
    }
    emit_final_result
}

main() {
    parse_arguments "$@"
    configure_roots

    if [[ "$OPERATION" == "list" ]]; then
        list_recipes
        return 0
    fi

    define_recipe "$RECIPE_ID" || fail_usage "허용되지 않은 recipe ID입니다: $RECIPE_ID"
    ESTIMATED_KB=0

    if [[ "$OPERATION" == "preview" ]]; then
        run_preview
        return $?
    fi
    run_execute
}

main "$@"
exit $?
