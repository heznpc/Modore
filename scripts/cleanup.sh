#!/bin/bash
# PC Health Check Mac Edition - allowlisted local cleanup harness.
#
# Preview is read-only. Execute accepts recipe IDs only, requires an explicit
# approval flag, rejects symlinked targets, and writes a local receipt.

set -u
set -o pipefail

PROTOCOL_VERSION="1"
OPERATION=""
RECIPE_ID=""
OWNER_APPROVED="false"
HOME_ROOT="${HOME:-}"
VAR_FOLDERS_ROOT="/private/var/folders"
APPLICATIONS_ROOT="/Applications"
RECEIPT_DIR=""
SIMULATOR_KEEP_FILE=""

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
SIMULATOR_UUID=""
RECIPE_BLOCK_REASON=""

usage() {
    /usr/bin/printf '%s\n' \
        'Usage:' \
        '  cleanup.sh --list' \
        '  cleanup.sh --preview <recipe-id>' \
        '  cleanup.sh --execute <recipe-id> --owner-approved'
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

configure_roots() {
    if [[ "${PCH_TEST_MODE:-0}" == "1" ]]; then
        if [[ -n "${PCH_HOME_OVERRIDE:-}" ]]; then
            HOME_ROOT="$PCH_HOME_OVERRIDE"
        fi
        if [[ -n "${PCH_VAR_FOLDERS_ROOT_OVERRIDE:-}" ]]; then
            VAR_FOLDERS_ROOT="$PCH_VAR_FOLDERS_ROOT_OVERRIDE"
        fi
        if [[ -n "${PCH_APPLICATIONS_ROOT_OVERRIDE:-}" ]]; then
            APPLICATIONS_ROOT="$PCH_APPLICATIONS_ROOT_OVERRIDE"
        fi
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
    SIMULATOR_KEEP_FILE="${PCH_SIMULATOR_KEEP_PATH:-$HOME_ROOT/Library/Application Support/PC Health Check/simulator-keep.txt}"
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

define_app_recipe() {
    local bundle_id="$1"
    local app_path found_app="false" app_label="" escaped pattern=""
    local candidates=()
    [[ "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{1,199}$ ]] || return 1
    [[ "$bundle_id" != "com.apple.Safari" ]] || return 1

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

    local residue plist dump target_app
    shopt -s nullglob
    for residue in \
        "$HOME_ROOT/Library/HTTPStorages/$bundle_id".* \
        "$HOME_ROOT/Library/Preferences/ByHost/$bundle_id".*.plist; do
        add_target_if_present "$residue"
    done
    for plist in "$HOME_ROOT/Library/LaunchAgents"/*.plist; do
        [[ -f "$plist" && ! -L "$plist" ]] || continue
        dump="$(/usr/bin/plutil -p "$plist" 2>/dev/null || true)"
        if /usr/bin/printf '%s' "$dump" | /usr/bin/grep -F "$bundle_id" >/dev/null 2>&1; then
            add_target_if_present "$plist"
            continue
        fi
        for target_app in "${TARGETS[@]}"; do
            [[ "$target_app" == *.app ]] || continue
            if /usr/bin/printf '%s' "$dump" | /usr/bin/grep -F "$target_app" >/dev/null 2>&1; then
                add_target_if_present "$plist"
                break
            fi
        done
    done
    shopt -u nullglob
    return 0
}

simctl_devices() {
    if [[ "${PCH_TEST_MODE:-0}" == "1" && -n "${PCH_SIMCTL_LIST_FILE:-}" && -f "$PCH_SIMCTL_LIST_FILE" ]]; then
        /bin/cat "$PCH_SIMCTL_LIST_FILE"
    else
        /usr/bin/xcrun simctl list devices available 2>/dev/null || true
    fi
}

define_simulator_recipe() {
    local requested_uuid="$1"
    local requested_upper runtime="" line uuid name state data_path
    [[ "$requested_uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || return 1
    requested_upper="$(/usr/bin/printf '%s' "$requested_uuid" | /usr/bin/tr '[:lower:]' '[:upper:]')"

    while IFS= read -r line; do
        case "$line" in
            "-- "*)
                runtime="${line#-- }"
                runtime="${runtime% --}"
                ;;
            *)
                uuid="$(/usr/bin/sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/' <<< "$line")"
                [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || continue
                if [[ "$(/usr/bin/printf '%s' "$uuid" | /usr/bin/tr '[:lower:]' '[:upper:]')" == "$requested_upper" ]]; then
                    name="$(/usr/bin/sed -E 's/^[[:space:]]*//; s/[[:space:]]*\([0-9A-Fa-f-]{36}\)[[:space:]]*\([^)]*\).*//' <<< "$line")"
                    state="$(/usr/bin/sed -E 's/.*\([0-9A-Fa-f-]{36}\)[[:space:]]*\(([^)]*)\).*/\1/' <<< "$line")"
                    SIMULATOR_UUID="$uuid"
                    LABEL="$name"
                    REMOVE_MODE="simulator"
                    PROCESS_NOTE="Booted Simulator는 먼저 종료해야 합니다."
                    WARNING="$runtime 기기 데이터만 삭제합니다. iOS Simulator 런타임 자체는 보존됩니다."
                    if [[ "$state" == "Booted" ]]; then
                        RECIPE_BLOCK_REASON="현재 Booted 상태인 Simulator는 삭제할 수 없습니다."
                    elif [[ -f "$SIMULATOR_KEEP_FILE" ]] && /usr/bin/grep -F -x "$name" "$SIMULATOR_KEEP_FILE" >/dev/null 2>&1; then
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
    SIMULATOR_UUID=""
    RECIPE_BLOCK_REASON=""

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
        user_caches)
            LABEL="User caches"
            REMOVE_MODE="contents"
            PROCESS_PATTERN='Google Chrome|Safari\.app/Contents/MacOS/Safari( |$)|Firefox\.app/Contents/MacOS/firefox|Codex\.app|/codex|Claude\.app|/claude|Xcode\.app/Contents/MacOS/Xcode( |$)|Simulator\.app/Contents/MacOS/Simulator( |$)|playwright|(^|/)(pod|dart|flutter)( |$)'
            PROCESS_NOTE="브라우저, AI 앱, Xcode/Simulator와 패키지 작업을 먼저 종료하세요."
            WARNING="실행 중인 앱의 캐시가 즉시 다시 생기거나 다음 실행이 느려질 수 있습니다. 개인 문서와 앱 데이터는 대상이 아닙니다."
            add_target_if_present "$HOME_ROOT/Library/Caches"
            ;;
        cli_tool_caches)
            LABEL="CLI/tool caches"
            REMOVE_MODE="contents"
            PROCESS_PATTERN='Codex\.app|/codex|Claude\.app|/claude|(^|/)(node|npm|npx|pnpm)( |$)'
            PROCESS_NOTE="AI 도구와 Node 기반 개발 작업을 먼저 종료하세요."
            WARNING="명령행 도구의 재생성 가능한 캐시만 정리하지만 다음 실행 때 재다운로드가 생길 수 있습니다."
            add_target_if_present "$HOME_ROOT/.cache"
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
        user_caches) [[ "$target" == "$HOME_ROOT/Library/Caches" ]] ;;
        cli_tool_caches) [[ "$target" == "$HOME_ROOT/.cache" ]] ;;
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

size_kb() {
    local target="$1"
    if [[ "$target" == *.app ]]; then
        local bytes
        bytes="$(/usr/bin/mdls -raw -name kMDItemFSSize "$target" 2>/dev/null || true)"
        case "$bytes" in
            ''|*[!0-9]*) ;;
            *) /usr/bin/printf '%s\n' "$((bytes / 1024))"; return 0 ;;
        esac
    fi
    /usr/bin/du -sk "$target" 2>/dev/null | /usr/bin/awk '{print $1; exit}'
}

targets_size_kb() {
    local total=0 target value
    for target in "${TARGETS[@]}"; do
        value="$(size_kb "$target")"
        case "$value" in ''|*[!0-9]*) value=0 ;; esac
        total=$((total + value))
    done

    /usr/bin/printf '%s' "$total"
}

process_snapshot() {
    if [[ "${PCH_TEST_MODE:-0}" == "1" && -n "${PCH_PROCESS_LIST_FILE:-}" && -f "$PCH_PROCESS_LIST_FILE" ]]; then
        /bin/cat "$PCH_PROCESS_LIST_FILE"
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
        RUNNING_PROCESSES="$(/usr/bin/printf '%s' "$matches" | /usr/bin/tr '\n' ';' | /usr/bin/sed 's/;$//')"
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
    local target
    emit "version" "$PROTOCOL_VERSION"
    emit "operation" "$operation"
    emit "status" "$status"
    emit "recipeId" "$RECIPE_ID"
    emit "label" "$LABEL"
    emit "estimatedKB" "$estimated_kb"
    emit "actionMode" "$REMOVE_MODE"
    emit "warning" "$WARNING"
    emit "processNote" "$PROCESS_NOTE"
    emit "blockedReason" "${BLOCKED_REASON:-}"
    emit "runningProcesses" "${RUNNING_PROCESSES:-}"
    for target in "${TARGETS[@]}"; do
        emit "target" "$target"
    done
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

remove_target() {
    local target="$1"
    local index="${2:-0}"
    if [[ "$REMOVE_MODE" == "contents" ]]; then
        local entries=()
        shopt -s dotglob nullglob
        entries=("$target"/*)
        if [[ "${#entries[@]}" -gt 0 ]]; then
            /bin/rm -rf "${entries[@]}"
        fi
        shopt -u dotglob nullglob
    elif [[ "$REMOVE_MODE" == "trash" ]]; then
        local destination
        destination="$TRASH_RUN/$index-$(/usr/bin/basename "$target")"
        /bin/mv "$target" "$destination" || return 1
        MOVED_TARGETS[MOVED_TARGETS_COUNT]="$target -> $destination"
        MOVED_TARGETS_COUNT=$((MOVED_TARGETS_COUNT + 1))
    elif [[ "$REMOVE_MODE" == "simulator" ]]; then
        if [[ "${PCH_TEST_MODE:-0}" == "1" && -n "${PCH_SIMCTL_DELETE_LOG:-}" ]]; then
            /usr/bin/printf '%s\n' "$SIMULATOR_UUID" >> "$PCH_SIMCTL_DELETE_LOG" || return 1
            /bin/rm -rf "$target"
        else
            /usr/bin/xcrun simctl delete "$SIMULATOR_UUID"
        fi
    else
        /bin/rm -rf "$target"
    fi
}

prepare_trash_run() {
    local trash_root="$HOME_ROOT/.Trash"
    /bin/mkdir -p "$trash_root" || return 1
    [[ ! -L "$trash_root" ]] || return 1
    TRASH_RUN="$trash_root/PC Health Check-$(/bin/date -u '+%Y%m%dT%H%M%SZ')-$$"
    /bin/mkdir "$TRASH_RUN"
}

unload_app_launch_agents() {
    local target domain
    domain="gui/$(/usr/bin/id -u)"
    for target in "${TARGETS[@]}"; do
        if [[ "$target" == "$HOME_ROOT/Library/LaunchAgents/"*.plist ]]; then
            /bin/launchctl bootout "$domain" "$target" >/dev/null 2>&1 || true
        fi
    done
}

available_kb() {
    /bin/df -Pk "$HOME_ROOT" 2>/dev/null | /usr/bin/awk 'NR == 2 {print $4; exit}'
}

write_receipt() {
    local status="$1"
    local estimated_kb="$2"
    local reclaimed_kb="$3"
    local physical_delta_kb="$4"
    local timestamp receipt target moved receipt_recipe
    timestamp="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    receipt_recipe="${RECIPE_ID//[^A-Za-z0-9_.-]/_}"
    receipt="$RECEIPT_DIR/$(/bin/date -u '+%Y%m%dT%H%M%SZ')-$receipt_recipe-$$.tsv"
    /bin/mkdir -p "$RECEIPT_DIR" || return 1
    /bin/chmod 700 "$RECEIPT_DIR" 2>/dev/null || true
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
    } > "$receipt" || return 1
    /bin/chmod 600 "$receipt" 2>/dev/null || true
    RECEIPT_PATH="$receipt"
    return 0
}

list_recipes() {
    local recipe
    for recipe in \
        npm_cache pnpm_store playwright_browsers gradle_cache cocoapods_cache pub_cache \
        codex_runtime_cache codex_temp_cache claude_vm_bundles xcode_derived_data \
        user_caches cli_tool_caches chrome_code_sign_clones innorix_ex; do
        define_recipe "$recipe"
        emit "recipe" "$recipe"
        emit "label" "$LABEL"
    done
}

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
                *) fail_usage "알 수 없는 옵션: $1" ;;
            esac
            shift
        done
        ;;
    *) fail_usage "작업을 지정하세요." ;;
esac

configure_roots

if [[ "$OPERATION" == "list" ]]; then
    list_recipes
    exit 0
fi

define_recipe "$RECIPE_ID" || fail_usage "허용되지 않은 recipe ID입니다: $RECIPE_ID"
preview_status
ESTIMATED_KB="$(targets_size_kb)"

if [[ "$OPERATION" == "preview" ]]; then
    emit_state "preview" "$PREVIEW_STATUS" "$ESTIMATED_KB"
    exit 0
fi

if [[ "$OWNER_APPROVED" != "true" ]]; then
    /usr/bin/printf 'ERROR: 실행에는 --owner-approved가 필요합니다.\n' >&2
    exit 2
fi

if [[ "$PREVIEW_STATUS" != "ready" ]]; then
    emit_state "execute" "$PREVIEW_STATUS" "$ESTIMATED_KB"
    [[ "$PREVIEW_STATUS" == "empty" ]] && exit 0
    exit 3
fi

if [[ "$RECIPE_ID" == "innorix_ex" ]] && ! stop_innorix; then
    BLOCKED_REASON="INNORIX 프로세스를 종료하지 못해 파일 삭제를 중단했습니다."
    PREVIEW_STATUS="blocked"
    emit_state "execute" "$PREVIEW_STATUS" "$ESTIMATED_KB"
    exit 3
fi

if [[ "$RECIPE_ID" == app_uninstall:* ]]; then
    unload_app_launch_agents
fi
if [[ "$REMOVE_MODE" == "trash" ]] && ! prepare_trash_run; then
    BLOCKED_REASON="사용자 휴지통에 안전한 이동 폴더를 만들지 못했습니다."
    PREVIEW_STATUS="blocked"
    emit_state "execute" "$PREVIEW_STATUS" "$ESTIMATED_KB"
    exit 3
fi

FREE_BEFORE="$(available_kb)"
case "$FREE_BEFORE" in ''|*[!0-9]*) FREE_BEFORE=0 ;; esac
FAILED=0
TARGET_INDEX=0
for target in "${TARGETS[@]}"; do
    TARGET_INDEX=$((TARGET_INDEX + 1))
    if ! validate_target "$RECIPE_ID" "$target"; then
        FAILED=1
        continue
    fi
    if ! remove_target "$target" "$TARGET_INDEX"; then
        FAILED=1
    fi
done

REMAINING_KB="$(targets_size_kb)"
RECLAIMED_KB=$((ESTIMATED_KB - REMAINING_KB))
[[ "$RECLAIMED_KB" -ge 0 ]] || RECLAIMED_KB=0
FREE_AFTER="$(available_kb)"
case "$FREE_AFTER" in ''|*[!0-9]*) FREE_AFTER=0 ;; esac
PHYSICAL_DELTA_KB=$((FREE_AFTER - FREE_BEFORE))
[[ "$PHYSICAL_DELTA_KB" -ge 0 ]] || PHYSICAL_DELTA_KB=0

RESULT_STATUS="complete"
[[ "$FAILED" -eq 0 ]] || RESULT_STATUS="partial"
RECEIPT_PATH=""
write_receipt "$RESULT_STATUS" "$ESTIMATED_KB" "$RECLAIMED_KB" "$PHYSICAL_DELTA_KB" || FAILED=1
[[ "$FAILED" -eq 0 ]] || RESULT_STATUS="partial"

emit_state "execute" "$RESULT_STATUS" "$ESTIMATED_KB"
emit "reclaimedKB" "$RECLAIMED_KB"
emit "physicalDeltaKB" "$PHYSICAL_DELTA_KB"
emit "receipt" "$RECEIPT_PATH"
emit "trashRun" "$TRASH_RUN"

[[ "$RESULT_STATUS" == "complete" ]] && exit 0
exit 4
