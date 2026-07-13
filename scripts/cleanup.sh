#!/bin/bash -p
# PC Health Check Mac Edition - allowlisted local cleanup harness.
#
# Preview is read-only. Execute accepts recipe IDs only, requires an explicit
# approval flag, rejects symlinked targets, and writes a local receipt.

set -u
set -o pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

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
            "${PCH_SIMCTL_LIST_FILE:-}" \
            "${PCH_SIMCTL_DELETE_LOG:-}" \
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
    RECEIPT_DIR="$HOME_ROOT/Library/Application Support/PC Health Check/cleanup-receipts"
    APPROVAL_DIR="$HOME_ROOT/Library/Application Support/PC Health Check/cleanup-approvals"
    STAGING_DIR="$HOME_ROOT/Library/Application Support/PC Health Check/cleanup-staging"
    SIMULATOR_KEEP_FILE="$HOME_ROOT/Library/Application Support/PC Health Check/simulator-keep.txt"
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
    for app_path in "${candidates[@]}"; do
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

define_recipe() {
    local recipe="$1"
    LABEL=""
    REMOVE_MODE="remove"
    PROCESS_PATTERN=""
    PROCESS_POLICY="block"
    PROCESS_NOTE=""
    WARNING=""
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
    EXECUTION_MANIFEST=""
    TRANSACTION_JOURNAL=""
    EXECUTION_FAILURE_STATUS="partial"
    TEST_STAGED_APPROVED_ORIGINAL=""

    if [[ "$recipe" == simulator_delete:* ]]; then
        define_simulator_recipe "${recipe#simulator_delete:}"
        return $?
    fi

    if [[ "$recipe" == app_uninstall:* ]]; then
        define_app_recipe "${recipe#app_uninstall:}"
        return $?
    fi

    case "$recipe" in
        npm_cache)
            LABEL="npm cache"
            PROCESS_PATTERN='(^|/)(npm|npx)( |$)'
            PROCESS_NOTE="npm/npx 작업을 먼저 종료하세요."
            WARNING="패키지는 다음 설치 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/.npm"
            ;;
        pnpm_store)
            LABEL="pnpm store"
            PROCESS_PATTERN='(^|/)(pnpm|node)( |$)'
            PROCESS_NOTE="pnpm/Node 작업을 먼저 종료하세요."
            WARNING="공유 패키지 저장소가 다시 채워지며 다음 설치가 느려질 수 있습니다."
            add_target_if_present "$HOME_ROOT/Library/pnpm"
            ;;
        playwright_browsers)
            LABEL="Playwright browser cache"
            PROCESS_PATTERN='playwright|ms-playwright|playwright_chromiumdev_profile|--headless|remote-debugging-pipe'
            PROCESS_NOTE="Playwright와 headless 브라우저를 먼저 종료하세요."
            WARNING="브라우저 바이너리는 다음 테스트 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/Library/Caches/ms-playwright"
            ;;
        gradle_cache)
            LABEL="Gradle cache"
            PROCESS_PATTERN='GradleDaemon|org\.gradle|(^|/)(gradle|gradlew)( |$)'
            PROCESS_NOTE="Gradle 빌드와 daemon을 먼저 종료하세요."
            WARNING="Gradle 의존성과 빌드 캐시는 다음 빌드 때 다시 생성됩니다."
            add_target_if_present "$HOME_ROOT/.gradle/caches"
            ;;
        cocoapods_cache)
            LABEL="CocoaPods cache"
            PROCESS_PATTERN='(^|/)(pod)( |$)'
            PROCESS_NOTE="pod install/update 작업을 먼저 종료하세요."
            WARNING="Pod 아카이브는 다음 설치 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/Library/Caches/CocoaPods"
            ;;
        pub_cache)
            LABEL="Dart/Flutter pub cache"
            PROCESS_PATTERN='(^|/)(dart|flutter)( |$)'
            PROCESS_NOTE="Dart/Flutter 작업을 먼저 종료하세요."
            WARNING="패키지는 다음 pub get 때 다시 다운로드됩니다."
            add_target_if_present "$HOME_ROOT/.pub-cache"
            ;;
        codex_runtime_cache)
            LABEL="Codex runtime cache"
            PROCESS_PATTERN='Codex\.app|/codex|node_repl|SkyComputerUseClient'
            PROCESS_NOTE="Codex 앱과 진행 중인 Codex 작업을 먼저 종료하세요."
            WARNING="Codex 런타임은 다음 사용 때 다시 설치될 수 있습니다. 세션 JSONL은 건드리지 않습니다."
            add_target_if_present "$HOME_ROOT/.cache/codex-runtimes"
            ;;
        codex_temp_cache)
            LABEL="Codex temporary cache"
            PROCESS_PATTERN='Codex\.app|/codex|node_repl|SkyComputerUseClient'
            PROCESS_NOTE="Codex 앱과 진행 중인 Codex 작업을 먼저 종료하세요."
            WARNING="임시 런타임 파일만 정리합니다. .codex/sessions와 로그 DB는 건드리지 않습니다."
            add_target_if_present "$HOME_ROOT/.codex/.tmp"
            ;;
        claude_vm_bundles)
            LABEL="Claude Cowork VM bundles"
            PROCESS_PATTERN='Claude\.app|/claude|claude-code|local-agent-mode'
            PROCESS_NOTE="Claude Desktop/Code/Cowork를 완전히 종료하세요."
            WARNING="로컬 에이전트 VM 이미지는 다시 생성될 수 있습니다. 세션 작업공간은 보존합니다."
            add_target_if_present "$HOME_ROOT/Library/Application Support/Claude/vm_bundles"
            ;;
        xcode_derived_data)
            LABEL="Xcode DerivedData"
            PROCESS_PATTERN='Xcode\.app|xcodebuild|XCBBuildService|SourceKitService'
            PROCESS_NOTE="Xcode와 진행 중인 Apple 플랫폼 빌드를 먼저 종료하세요."
            WARNING="소스와 Archive는 보존되지만 다음 빌드가 오래 걸릴 수 있습니다."
            add_target_if_present "$HOME_ROOT/Library/Developer/Xcode/DerivedData"
            ;;
        chrome_code_sign_clones)
            LABEL="Chrome code-sign clones"
            PROCESS_PATTERN='Google Chrome|playwright_chromiumdev_profile|--headless|remote-debugging-pipe'
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
        codex_runtime_cache) [[ "$target" == "$HOME_ROOT/.cache/codex-runtimes" ]] ;;
        codex_temp_cache) [[ "$target" == "$HOME_ROOT/.codex/.tmp" ]] ;;
        claude_vm_bundles) [[ "$target" == "$HOME_ROOT/Library/Application Support/Claude/vm_bundles" ]] ;;
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
    /usr/bin/du -sk "$target" > "$output" 2>/dev/null &
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
    local total=0 target value
    for target in "${TARGETS[@]}"; do
        [[ -e "$target" || -L "$target" ]] || continue
        value="$(size_kb "$target")" || continue
        case "$value" in ''|*[!0-9]*) continue ;; esac
        total=$((total + value))
    done
    if [[ "${#STAGED_REMAINDERS[@]}" -gt 0 ]]; then
        for target in "${STAGED_REMAINDERS[@]}"; do
            [[ -e "$target" || -L "$target" ]] || continue
            value="$(size_kb "$target")" || continue
            case "$value" in ''|*[!0-9]*) continue ;; esac
            total=$((total + value))
        done
    fi
    /usr/bin/printf '%s' "$total"
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

matching_processes() {
    [[ -n "$PROCESS_PATTERN" ]] || return 0
    process_snapshot \
        | /usr/bin/grep -E "$PROCESS_PATTERN" \
        | /usr/bin/grep -v -E 'scripts/cleanup\.sh|PCHealthCheckMac|/usr/bin/grep -E' \
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
            *"Google Chrome Helper"*) display_name="Google Chrome Helper" ;;
            *"Google Chrome"*) display_name="Google Chrome" ;;
            *playwright*|*Playwright*|*remote-debugging-pipe*) display_name="Playwright" ;;
            *Codex*|*codex*|*node_repl*|*SkyComputerUseClient*) display_name="Codex" ;;
            *Claude*|*claude*|*local-agent-mode*) display_name="Claude" ;;
            *pnpm*) display_name="pnpm" ;;
            *npm*|*npx*|*node*) display_name="Node/npm" ;;
            *GradleDaemon*|*org.gradle*|*gradlew*) display_name="Gradle" ;;
            *CocoaPods*|*"/pod "*) display_name="CocoaPods" ;;
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

matching_processes_with_pid() {
    [[ -n "$PROCESS_PATTERN" ]] || return 0
    /bin/ps -axo pid=,command= 2>/dev/null \
        | /usr/bin/grep -E "$PROCESS_PATTERN" \
        | /usr/bin/grep -v -E 'scripts/cleanup\.sh|PCHealthCheckMac|/usr/bin/grep -E' \
        | /usr/bin/head -n 5 \
        | /usr/bin/sed -E 's/^[[:space:]]+//; s/[[:space:]]+/ /g' \
        || true
}

display_process_evidence() {
    local pid command display_name
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
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
    if process_snapshot | /usr/bin/grep -E 'INNORIX-EX|innorixes\.app|innorixes' | /usr/bin/grep -v 'scripts/cleanup\.sh' >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

prepare_trash_run() {
    local trash_root="$HOME_ROOT/.Trash"
    prepare_private_directory "$trash_root" || return 1
    TRASH_RUN="$trash_root/PC Health Check-$(/bin/date -u '+%Y%m%dT%H%M%SZ')-$$"
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
    if ! /bin/rm -rf "$destination"; then
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
        /usr/bin/printf 'label\t%s\n' "$LABEL"
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

    REMAINING_KB="$(remaining_targets_size_kb)"
    RECLAIMED_KB=$((ESTIMATED_KB - REMAINING_KB))
    [[ "$RECLAIMED_KB" -ge 0 ]] || RECLAIMED_KB=0
    FREE_AFTER="$(available_kb)"
    case "$FREE_AFTER" in ''|*[!0-9]*) FREE_AFTER=0 ;; esac
    PHYSICAL_DELTA_KB=$((FREE_AFTER - FREE_BEFORE))
    [[ "$PHYSICAL_DELTA_KB" -ge 0 ]] || PHYSICAL_DELTA_KB=0

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
