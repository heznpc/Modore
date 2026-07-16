#!/bin/bash
# scanner 모듈 (macOS): 저장공간 압박 + 개발 도구/캐시 용량
# 출력: storage_df.txt, storage_paths.tsv, storage_access.tsv, storage_runtime.tsv, storage_simulators.tsv
# 의존: df, du, find

if ! declare -F record_collection_status >/dev/null 2>&1; then
    record_collection_status() { :; }
fi

_pch_is_protected_developer_app() {
    local app_path="$1"
    local bundle_id="${2:-}"

    case "$bundle_id" in
        com.apple.dt.Xcode|com.apple.dt.Xcode.*) return 0 ;;
    esac
    case "$(/usr/bin/basename "$app_path" 2>/dev/null || true)" in
        Xcode.app|Xcode-*.app|Xcode_*.app) return 0 ;;
    esac
    [[ -d "$app_path/Contents/Developer/Platforms" ]] && return 0
    [[ -d "$app_path/Contents/Developer/Toolchains" ]] && return 0
    [[ -d "$app_path/Contents/Developer/SDKs" ]] && return 0
    return 1
}

_pch_browser_controller_label() {
    local command="$1"

    case "$command" in
        *Codex.app*|*/codex*|*SkyComputerUseClient*) /usr/bin/printf 'Codex'; return 0 ;;
        *Claude.app*|*/claude*|*claude-code*) /usr/bin/printf 'Claude'; return 0 ;;
        *ChatGPT.app*|*/ChatGPT*|*com.openai.chat*) /usr/bin/printf 'ChatGPT'; return 0 ;;
        *) return 1 ;;
    esac
}

_pch_browser_controller() {
    local current_pid="$1"
    local depth=0
    local parent_line ancestor_pid ancestor_command controller_label
    local fallback="other local process"

    while [[ "$depth" -lt 8 ]]; do
        case "$current_pid" in ''|*[!0-9]*|0|1) break ;; esac
        parent_line="$(/bin/ps -p "$current_pid" -o ppid=,command= 2>/dev/null || true)"
        [[ -n "$parent_line" ]] || break
        read -r ancestor_pid ancestor_command <<< "$parent_line"
        if controller_label="$(_pch_browser_controller_label "$ancestor_command")"; then
            /usr/bin/printf '%s' "$controller_label"
            return 0
        fi
        case "$ancestor_command" in
            *playwright*|*node*) fallback="Playwright/Node" ;;
            *python*) [[ "$fallback" == "other local process" ]] && fallback="Python automation" ;;
        esac
        current_pid="$ancestor_pid"
        depth=$((depth + 1))
    done
    /usr/bin/printf '%s' "$fallback"
}

_pch_elapsed_seconds() {
    local elapsed="$1"
    local days=0 hours=0 minutes=0 seconds=0 clock
    local day_value hour_value minute_value second_value
    if [[ "$elapsed" == *-* ]]; then
        days="${elapsed%%-*}"
        clock="${elapsed#*-}"
    else
        clock="$elapsed"
    fi
    case "$clock" in
        *:*:*) IFS=: read -r hours minutes seconds <<< "$clock" ;;
        *:*) IFS=: read -r minutes seconds <<< "$clock" ;;
        *) return 1 ;;
    esac
    case "$days$hours$minutes$seconds" in ''|*[!0-9]*) return 1 ;; esac
    day_value=$((10#$days))
    hour_value=$((10#$hours))
    minute_value=$((10#$minutes))
    second_value=$((10#$seconds))
    /usr/bin/printf '%s' \
        "$((day_value * 86400 + hour_value * 3600 + minute_value * 60 + second_value))"
}

_pch_browser_automation_roots() {
    local pid ppid elapsed rss_kb command channel state profile controller parent_command
    local parent_parent_pid elapsed_seconds process_snapshot tree_stats tree_memory_kb tree_process_count

    process_snapshot="$(/bin/cat)"
    while read -r pid ppid elapsed rss_kb command; do
        case "$pid$ppid" in ''|*[!0-9]*) continue ;; esac
        case "$elapsed" in ''|*[!0-9:-]*) elapsed="unknown" ;; esac
        case "$rss_kb" in ''|*[!0-9]*) rss_kb="0" ;; esac
        case "$command" in
            *playwright_chromiumdev_profile*|*--remote-debugging-pipe*|*--remote-debugging-port*|*--no-startup-window*|*--headless*) ;;
            *) continue ;;
        esac
        case "$command" in
            *"Google Chrome Helper"*|*"Chromium Helper"*|*" --type="*) continue ;;
        esac
        case "$command" in
            *"Google Chrome.app/Contents/MacOS/Google Chrome"*|*"Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"*|*"Chromium.app/Contents/MacOS/Chromium"*|*"ms-playwright/"*"headless_shell"*) ;;
            *) continue ;;
        esac

        case "$command" in
            *"Google Chrome for Testing.app/"*|*"/ms-playwright/"*|*"Chromium.app/"*) channel="isolated" ;;
            *"/Applications/Google Chrome.app/"*) channel="system" ;;
            *) channel="unknown" ;;
        esac
        case "$command" in
            *playwright_chromiumdev_profile*|*--user-data-dir=/tmp/*|*--user-data-dir=/private/tmp/*|*--user-data-dir=/var/folders/*|*--user-data-dir=/private/var/folders/*) profile="temporary" ;;
            *--user-data-dir=*) profile="custom" ;;
            *) profile="default" ;;
        esac
        parent_command="$(/bin/ps -p "$ppid" -o command= 2>/dev/null || true)"
        parent_parent_pid="$(/bin/ps -p "$ppid" -o ppid= 2>/dev/null | /usr/bin/tr -d ' ' || true)"
        elapsed_seconds="$(_pch_elapsed_seconds "$elapsed" 2>/dev/null || /usr/bin/printf '0')"
        controller="$(_pch_browser_controller "$ppid")"
        [[ -n "$parent_command" ]] || controller="parent unavailable"
        if [[ ( "$ppid" == "1" || "$parent_parent_pid" == "1" || -z "$parent_command" ) \
            && "$elapsed_seconds" -ge 3600 ]]; then
            state="orphan_candidate"
        elif [[ "$ppid" == "1" || "$parent_parent_pid" == "1" || -z "$parent_command" ]]; then
            state="detached"
        else
            state="active"
        fi
        tree_stats="$(/usr/bin/printf '%s\n' "$process_snapshot" | /usr/bin/awk -v root="$pid" '
            BEGIN { included[root] = 1 }
            {
                pids[NR] = $1
                parents[NR] = $2
                memory[NR] = $4 + 0
            }
            END {
                for (pass = 0; pass < 16; pass++) {
                    changed = 0
                    for (i = 1; i <= NR; i++) {
                        if (included[parents[i]] && !included[pids[i]]) {
                            included[pids[i]] = 1
                            changed = 1
                        }
                    }
                    if (!changed) break
                }
                total = 0
                count = 0
                for (i = 1; i <= NR; i++) {
                    if (included[pids[i]]) {
                        total += memory[i]
                        count++
                    }
                }
                printf "%d %d", total, count
            }
        ')"
        read -r tree_memory_kb tree_process_count <<< "$tree_stats"
        case "$tree_memory_kb$tree_process_count" in ''|*[!0-9]*) tree_memory_kb="$rss_kb"; tree_process_count="1" ;; esac
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$pid" "$ppid" "$elapsed" "$channel" "$state" "$profile" "$controller" \
            "$rss_kb" "$tree_memory_kb" "$tree_process_count"
    done <<< "$process_snapshot"
}

_pch_collect_storage_applications() {
    # 설치 앱은 Spotlight가 이미 계산한 번들 크기를 먼저 읽는다. 깊은 du 순회 없이 큰 앱을 빠르게 비교한다.
    local app_path app_bytes app_kb app_name bundle_id app_note
    while IFS= read -r -d '' app_path; do
        [[ -d "$app_path" && ! -L "$app_path" ]] || continue
        bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
        [[ "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || continue
        [[ "$bundle_id" != "com.apple.Safari" ]] || continue
        app_bytes="$(/usr/bin/mdls -raw -name kMDItemFSSize "$app_path" 2>/dev/null || true)"
        case "$app_bytes" in ''|*[!0-9]*) continue ;; esac
        app_kb=$((app_bytes / 1024))
        app_name="$(/usr/bin/basename "$app_path" .app)"
        if _pch_is_protected_developer_app "$app_path" "$bundle_id"; then
            app_note="Bundle ID: $bundle_id. 개발 SDK와 toolchain을 포함할 수 있어 프로젝트 요구 버전을 확인하기 전에는 제거하지 않습니다."
            add_sized_path "application" "$app_name" "$app_path" "$app_kb" "$app_note"
        else
            app_note="Bundle ID: $bundle_id. 앱 본체와 정확히 귀속되는 사용자 데이터만 승인 후 휴지통으로 이동합니다."
            add_sized_path "application" "$app_name" "$app_path" "$app_kb" "$app_note" "app_uninstall:$bundle_id"
        fi
    done < <(
        /usr/bin/find /Applications -mindepth 1 -maxdepth 1 -type d -name '*.app' -print0 2>/dev/null
        /usr/bin/find "$HOME/Applications" -mindepth 1 -maxdepth 2 -type d -name '*.app' -prune -print0 2>/dev/null
    )
}

_pch_collect_storage_simulators() {
    local simctl_devices
    if [[ "${PCH_TEST_MODE:-}" == "1" && -n "${PCH_TEST_STORAGE_SIMCTL_LIST_FILE:-}" ]]; then
        simctl_devices="$(/bin/cat "$PCH_TEST_STORAGE_SIMCTL_LIST_FILE" 2>/dev/null || true)"
    else
        simctl_devices="$(/usr/bin/xcrun simctl list devices available 2>/dev/null || true)"
    fi
    if [[ -n "$simctl_devices" ]]; then
        local runtime=""
        while IFS= read -r line; do
            case "$line" in
                "-- "*)
                    runtime="${line#-- }"
                    runtime="${runtime% --}"
                    ;;
                *)
                    local device_name uuid state device_path device_size_kb device_measure_status
                    device_name="$(/usr/bin/sed -E 's/^[[:space:]]*//; s/[[:space:]]*\([0-9A-Fa-f-]{36}\)[[:space:]]*\([^)]*\).*//' <<< "$line")"
                    uuid="$(/usr/bin/sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/' <<< "$line")"
                    state="$(/usr/bin/sed -E 's/.*\([0-9A-Fa-f-]{36}\)[[:space:]]*\(([^)]*)\).*/\1/' <<< "$line")"
                    [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || continue
                    case "$device_name$runtime$state" in
                        *$'\t'*|*$'\n'*|*$'\r'*) continue ;;
                    esac
                    device_path="$HOME/Library/Developer/CoreSimulator/Devices/$uuid"
                    device_size_kb=0
                    device_measure_status="ok"
                    if [[ -d "$device_path" && ! -L "$device_path" ]]; then
                        du_size_kb "$device_path"
                        device_size_kb="$DU_SIZE_RESULT"
                        if [[ "$device_size_kb" == "__PCH_TIMEOUT__" ]]; then
                            device_size_kb=0
                            device_measure_status="timed_out"
                        fi
                    fi
                    case "$device_size_kb" in ''|*[!0-9]*) device_size_kb=0 ;; esac
                    /usr/bin/printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
                        "$device_name" "$uuid" "$runtime" "$state" "$device_size_kb" "$device_measure_status" \
                        >> "$TMP_DIR/storage_simulators.tsv"
                    if [[ "$state" == "Booted" ]]; then
                        add_runtime_signal "booted_simulator" "$device_name" "1" "warning" "켜진 Simulator 확인" "${runtime} / ${uuid}"
                    fi
                    ;;
            esac
        done <<< "$simctl_devices"
    fi
}

_pch_collect_known_storage_paths() {
    # Chrome code-sign clone은 변동 폭이 크고 사용자가 가장 먼저 확인해야 하므로
    # 넓은 SDK/toolchain 측정보다 앞에서 시간 예산을 확보한다.
    local clone_dir
    for clone_dir in /private/var/folders/*/*/X/com.google.Chrome.code_sign_clone /private/var/folders/*/*/T/com.google.Chrome.code_sign_clone; do
        [[ -d "$clone_dir" ]] || continue
        add_du_path "chrome_clone" "Chrome code-sign clones" "$clone_dir" "chrome_code_sign_clones"
    done

    # 일반 캐시/임시파일: 대부분 재생성 가능하지만 앱 로그아웃/재빌드 시간을 만들 수 있음.
    # 빠른 검사의 시간 예산을 아끼기 위해, 넓은 부모 캐시보다 판단 가치가 큰 하위 캐시를 먼저 잰다.
    add_du_path "cache" "npm cache" "$HOME/.npm" "npm_cache"
    add_du_path "cache" "pnpm store" "$HOME/Library/pnpm" "pnpm_store"
    add_du_path "cache" "Playwright browser cache" "$HOME/Library/Caches/ms-playwright" "playwright_browsers"
    add_du_path "cache" "Gradle cache" "$HOME/.gradle/caches" "gradle_cache"
    add_du_path "cache" "CocoaPods cache" "$HOME/Library/Caches/CocoaPods" "cocoapods_cache"
    add_du_path "cache" "Dart/Flutter pub cache" "$HOME/.pub-cache" "pub_cache"

    # AI 개발/에이전트 작업공간. 세션 기록과 재생성 가능한 런타임을 구분해서 보여준다.
    add_du_path "ai_vm_cache" "Claude Cowork VM bundles" "$HOME/Library/Application Support/Claude/vm_bundles" "claude_vm_bundles"
    add_du_path "ai_cache" "Codex runtime cache" "$HOME/.cache/codex-runtimes" "codex_runtime_cache"
    add_du_path "ai_cache" "Codex temporary cache" "$HOME/.codex/.tmp" "codex_temp_cache"
    add_du_path "ai_review" "Codex internal event log DB" "$HOME/.codex/logs_2.sqlite"
    local protected_path
    for protected_path in "$HOME/.codex"/state*.sqlite "$HOME/.codex"/state*.sqlite-wal "$HOME/.codex"/state*.sqlite-shm; do
        [[ -e "$protected_path" ]] || continue
        add_du_path "ai_review" "Codex local state DB" "$protected_path"
    done
    add_du_path "protected_history" "Codex active sessions" "$HOME/.codex/sessions"
    add_du_path "protected_history" "Codex archived sessions" "$HOME/.codex/archived_sessions"
    add_du_path "protected_history" "Codex command history" "$HOME/.codex/history.jsonl"
    add_du_path "protected_history" "Codex session index" "$HOME/.codex/session_index.jsonl"
    add_du_path "protected_history" "Codex worktrees" "$HOME/.codex/worktrees"
    add_du_path "protected_history" "Codex shell session snapshots" "$HOME/.codex/shell_snapshots"
    add_du_path "protected_history" "Codex saved memories" "$HOME/.codex/memories"
    add_du_path "ai_review" "Codex internal state databases" "$HOME/.codex/sqlite"
    add_du_path "protected_history" "Codex attachments" "$HOME/.codex/attachments"
    add_du_path "protected_history" "Codex automations" "$HOME/.codex/automations"
    add_du_path "protected_history" "Codex generated images" "$HOME/.codex/generated_images"
    add_du_path "protected_history" "Codex imported work" "$HOME/.codex/vendor_imports"
    add_du_path "protected_history" "Codex visualizations" "$HOME/.codex/visualizations"
    add_du_path "protected_history" "Codex user backups" "$HOME/.codex/backups"

    add_du_path "protected_history" "Claude local agent workspaces" "$HOME/Library/Application Support/Claude/local-agent-mode-sessions"
    add_du_path "protected_history" "Claude Code project sessions" "$HOME/.claude/projects"
    add_du_path "protected_history" "Claude sessions" "$HOME/.claude/sessions"
    add_du_path "protected_history" "Claude command history" "$HOME/.claude/history.jsonl"
    add_du_path "protected_history" "Claude session environments" "$HOME/.claude/session-env"
    add_du_path "protected_history" "Claude shell snapshots" "$HOME/.claude/shell-snapshots"
    add_du_path "protected_history" "Claude tasks" "$HOME/.claude/tasks"
    add_du_path "protected_history" "Claude user backups" "$HOME/.claude/backups"
    add_du_path "protected_history" "Claude plans" "$HOME/.claude/plans"
    add_du_path "protected_history" "Claude file history" "$HOME/.claude/file-history"
    add_du_path "ai_review" "Claude local databases" "$HOME/Library/Application Support/Claude/databases"
    add_du_path "protected_history" "Claude Code local sessions" "$HOME/Library/Application Support/Claude/claude-code-sessions"
    add_du_path "protected_history" "Claude Code local workspace" "$HOME/Library/Application Support/Claude/claude-code"
    add_du_path "ai_review" "Claude Code VM workspace" "$HOME/Library/Application Support/Claude/claude-code-vm"
    add_du_path "protected_history" "Claude IndexedDB" "$HOME/Library/Application Support/Claude/IndexedDB"
    add_du_path "protected_history" "Claude local storage" "$HOME/Library/Application Support/Claude/Local Storage"
    add_du_path "protected_history" "Claude session storage" "$HOME/Library/Application Support/Claude/Session Storage"
    add_du_path "protected_history" "Claude partition workspaces" "$HOME/Library/Application Support/Claude/Partitions"
    add_du_path "ai_review" "Claude WebStorage DB" "$HOME/Library/Application Support/Claude/WebStorage"
    add_du_path "ai_review" "Claude shared protocol DB" "$HOME/Library/Application Support/Claude/shared_proto_db"
    add_du_path "protected_history" "Claude pending uploads" "$HOME/Library/Application Support/Claude/pending-uploads"
    add_du_path "cache" "User caches" "$HOME/Library/Caches"
    add_du_path "cache" "CLI/tool caches" "$HOME/.cache"
    add_du_path "temp" "System temporary files" "/private/tmp"
    add_du_path "trash" "User Trash" "$HOME/.Trash"

    # Xcode / Apple 개발환경.
    add_du_path "build_cache" "Xcode DerivedData" "$HOME/Library/Developer/Xcode/DerivedData" "xcode_derived_data"
    add_du_path "archive" "Xcode Archives" "$HOME/Library/Developer/Xcode/Archives"
    add_du_path "simulator_devices" "iOS Simulator devices" "$HOME/Library/Developer/CoreSimulator/Devices"
    add_du_path "simulator_cache" "CoreSimulator cache" "/Library/Developer/CoreSimulator/Caches"
    add_du_path "simulator_runtime" "iOS Simulator runtime assets" "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime"

    # Android / cross-platform 모바일 개발환경.
    local sdk_candidates=(
        "${ANDROID_HOME:-}"
        "${ANDROID_SDK_ROOT:-}"
        "/opt/homebrew/share/android-commandlinetools"
        "$HOME/Library/Android/sdk"
    )
    local sdk_root
    for sdk_root in "${sdk_candidates[@]}"; do
        [[ -n "$sdk_root" && -d "$sdk_root" ]] || continue
        add_du_path "android_sdk" "Android SDK root" "$sdk_root"
        add_du_path "android_component" "Android NDK" "$sdk_root/ndk"
        add_du_path "android_component" "Android system images" "$sdk_root/system-images"
        add_du_path "android_component" "Android emulator" "$sdk_root/emulator"
        add_du_path "android_component" "Android platforms" "$sdk_root/platforms"
        add_du_path "android_component" "Android build-tools" "$sdk_root/build-tools"
    done

    # 언어 런타임/패키지 매니저 저장소.
    add_du_path "toolchain" "mise installs" "$HOME/.local/share/mise"
    add_du_path "toolchain" "Rust toolchains" "$HOME/.rustup/toolchains"
    add_du_path "toolchain" "Cargo registry" "$HOME/.cargo/registry"

    # 알려진 사용자 영역 웹 전송 모듈. 시스템 앱이 아니며 승인형 제거 레시피가 별도로 처리한다.
    if [[ -e "$HOME/Applications/INNORIX-EX" ]]; then
        add_du_path "known_app" "INNORIX-EX web transfer module" "$HOME/Applications/INNORIX-EX" "innorix_ex"
    elif [[ -e "$HOME/Library/LaunchAgents/com.innorix.innorixes.plist" ]]; then
        add_du_path "known_app" "INNORIX-EX LaunchAgent residue" "$HOME/Library/LaunchAgents/com.innorix.innorixes.plist" "innorix_ex"
    fi
}

_pch_collect_storage_access_checks() {
    # Full Disk Access가 없으면 macOS가 일부 개인 데이터/앱 데이터 영역을 숨길 수 있다.
    add_access_check "privacy_area" "Mail data" "$HOME/Library/Mail"
    add_access_check "privacy_area" "Messages data" "$HOME/Library/Messages"
    add_access_check "privacy_area" "Safari data" "$HOME/Library/Safari"
    add_access_check "privacy_area" "Calendars data" "$HOME/Library/Calendars"
    add_access_check "privacy_area" "Contacts data" "$HOME/Library/Application Support/AddressBook"
    add_access_check "app_data" "App containers" "$HOME/Library/Containers"
    add_access_check "app_data" "Group containers" "$HOME/Library/Group Containers"
}

_pch_collect_storage_runtime_signals() {
    # 반복 생성원: 공간을 직접 지우기보다 "왜 또 쌓이는지"를 설명하는 신호.
    local chrome_count sim_count codex_count claude_count node_count
    chrome_count="$(count_processes 'Google Chrome')"
    sim_count="$(count_processes '/CoreSimulator/Volumes/iOS_|launchd_sim|Simulator.app|CoreSimulatorBridge')"
    codex_count="$(count_processes 'Codex.app|/codex|node_repl|SkyComputerUseClient')"
    claude_count="$(count_processes 'Claude.app|/claude|claude-code')"
    node_count="$(count_processes '(^|/)(node|npm|npx)( |$)')"

    add_runtime_signal "process_count" "Chrome processes" "$chrome_count" "$([[ "$chrome_count" -ge 20 ]] && echo warning || echo info)" "브라우저 탭/자동화 정리" "Chrome 계열 프로세스가 많으면 code-sign clone과 프로필 캐시가 다시 쌓일 수 있습니다."
    local browser_pid browser_ppid browser_elapsed browser_channel browser_state browser_profile browser_controller browser_rss_kb browser_tree_memory_kb browser_tree_process_count
    local browser_label browser_risk browser_action browser_channel_note
    while IFS=$'\t' read -r browser_pid browser_ppid browser_elapsed browser_channel browser_state browser_profile browser_controller browser_rss_kb browser_tree_memory_kb browser_tree_process_count; do
        case "$browser_channel" in
            system)
                browser_label="시스템 Chrome 자동화"
                browser_risk="warning"
                browser_action="자동화 종료 후 기본 Chrome 다시 열기"
                browser_channel_note="기본 Chrome 채널"
                ;;
            isolated)
                browser_label="격리된 Playwright 브라우저"
                browser_risk="info"
                browser_action="해당 자동화 세션 종료"
                browser_channel_note="격리 브라우저 채널"
                ;;
            *)
                browser_label="브라우저 자동화"
                browser_risk="warning"
                browser_action="실행 출처 확인 후 종료"
                browser_channel_note="분류되지 않은 브라우저 채널"
                ;;
        esac
        if [[ "$browser_state" == "orphan_candidate" ]]; then
            browser_label="잔류 후보 $browser_label"
            browser_risk="warning"
            browser_action="소유 작업 재확인 후 종료 검토"
        fi
        add_runtime_signal \
            "browser_automation_root" \
            "$browser_label" \
            "1" \
            "$browser_risk" \
            "$browser_action" \
            "PID $browser_pid · 실행 $browser_elapsed · 부모 PID $browser_ppid · $browser_channel_note · $browser_controller" \
            "$browser_pid" \
            "$browser_ppid" \
            "$browser_elapsed" \
            "$browser_channel" \
            "$browser_state" \
            "$browser_profile" \
            "$browser_controller" \
            "$browser_rss_kb" \
            "$browser_tree_memory_kb" \
            "$browser_tree_process_count"
    done < <(/usr/bin/printf '%s\n' "$ps_detailed" | _pch_browser_automation_roots)
    add_runtime_signal "process_count" "CoreSimulator processes" "$sim_count" "$([[ "$sim_count" -ge 100 ]] && echo warning || echo info)" "필요한 Simulator만 Booted" "부팅된 Simulator는 런타임 프로세스를 대량으로 띄웁니다."
    add_runtime_signal "process_count" "Codex processes" "$codex_count" "$([[ "$codex_count" -ge 20 ]] && echo warning || echo info)" "끝난 Codex 작업의 프로세스 종료" "세션 기록은 보존하고, 더 이상 사용하지 않는 Codex/Computer Use 프로세스만 앱에서 정상 종료하세요."
    add_runtime_signal "process_count" "Claude processes" "$claude_count" "$([[ "$claude_count" -ge 15 ]] && echo warning || echo info)" "끝난 Claude 작업의 프로세스 종료" "로컬 작업공간은 보존하고, 더 이상 사용하지 않는 Claude Desktop/Code 프로세스만 앱에서 정상 종료하세요."
    add_runtime_signal "process_count" "Node/npm/npx processes" "$node_count" "$([[ "$node_count" -ge 25 ]] && echo warning || echo info)" "개발 서버 종료" "여러 개발 서버와 MCP/브라우저 자동화 런타임이 동시에 떠 있을 수 있습니다."
}

collect_storage() {
    local df_target="/"
    local du_timeout="${PCH_STORAGE_DU_TIMEOUT:-8}"
    local du_budget="${PCH_STORAGE_TOTAL_DU_BUDGET:-32}"
    local du_budget_ticks=0
    local du_budget_started=0
    local du_budget_timer_pid=""
    local du_test_clock_ticks=0
    local du_test_deadline_ticks=0
    local du_test_duration_ticks=""
    local du_test_size_kb="1"
    local du_test_trace_file=""
    local DU_SIZE_RESULT="0"
    case "$du_timeout" in
        ''|*[!0-9]*) du_timeout=8 ;;
    esac
    case "$du_budget" in
        ''|*[!0-9]*) du_budget=32 ;;
    esac
    du_budget_ticks=$((du_budget * 10))
    if [[ "${PCH_TEST_MODE:-}" == "1" ]]; then
        case "${PCH_TEST_STORAGE_DU_DURATION_TICKS:-}" in
            ''|*[!0-9]*) ;;
            *) du_test_duration_ticks="$PCH_TEST_STORAGE_DU_DURATION_TICKS" ;;
        esac
        case "${PCH_TEST_STORAGE_DU_SIZE_KB:-}" in
            ''|*[!0-9]*) ;;
            *) du_test_size_kb="$PCH_TEST_STORAGE_DU_SIZE_KB" ;;
        esac
        du_test_trace_file="${PCH_TEST_STORAGE_DU_TRACE_FILE:-}"
        [[ -z "$du_test_duration_ticks" || -z "$du_test_trace_file" ]] || : > "$du_test_trace_file"
    fi
    if [[ -d "/System/Volumes/Data" ]]; then
        df_target="/System/Volumes/Data"
    fi

    /bin/df -Pk "$df_target" 2>/dev/null | /usr/bin/tail -n 1 > "$TMP_DIR/storage_df.txt" || true
    if /usr/bin/awk 'NF >= 5 { found=1 } END { exit(found ? 0 : 1) }' "$TMP_DIR/storage_df.txt"; then
        record_collection_status "storage_volume" "시동 볼륨" "ok" "false" "현재 볼륨 사용량을 확인했습니다."
    else
        : > "$TMP_DIR/storage_df.txt"
        record_collection_status "storage_volume" "시동 볼륨" "failed" "false" "현재 볼륨 사용량을 읽지 못했습니다."
    fi
    : > "$TMP_DIR/storage_paths.tsv"
    : > "$TMP_DIR/storage_access.tsv"
    : > "$TMP_DIR/storage_runtime.tsv"
    : > "$TMP_DIR/storage_simulators.tsv"

    local seen="|"
    _pch_storage_du_budget_start() {
        [[ "$du_timeout" -gt 0 && "$du_budget" -gt 0 && "$du_budget_started" -eq 0 ]] || return 0
        du_budget_started=1
        if [[ -n "$du_test_duration_ticks" ]]; then
            du_test_deadline_ticks=$((du_test_clock_ticks + du_budget_ticks))
            return 0
        fi
        /bin/sleep "$du_budget" &
        du_budget_timer_pid=$!
    }

    _pch_storage_du_budget_expired() {
        [[ "$du_timeout" -gt 0 && "$du_budget" -gt 0 ]] || return 1
        _pch_storage_du_budget_start
        if [[ -n "$du_test_duration_ticks" ]]; then
            [[ "$du_test_clock_ticks" -ge "$du_test_deadline_ticks" ]]
            return
        fi
        if [[ -z "$du_budget_timer_pid" ]] || ! /bin/kill -0 "$du_budget_timer_pid" 2>/dev/null; then
            return 0
        fi
        return 1
    }

    _pch_storage_du_budget_stop() {
        [[ -n "$du_budget_timer_pid" ]] || return 0
        /bin/kill "$du_budget_timer_pid" 2>/dev/null || true
        wait "$du_budget_timer_pid" 2>/dev/null || true
        du_budget_timer_pid=""
    }

    _pch_storage_trace_test_du() {
        local target_path="$1"
        local requested_ticks="$2"
        local consumed_ticks="$3"
        local status="$4"
        [[ -n "$du_test_trace_file" ]] || return 0
        /usr/bin/printf '%s\t%s\t%s\t%s\n' \
            "$target_path" "$requested_ticks" "$consumed_ticks" "$status" >> "$du_test_trace_file"
    }

    du_size_kb() {
        local target_path="$1"
        local out_file="$TMP_DIR/du_size.$$.$RANDOM.out"
        local waited_ticks=0
        local size_kb
        local pid
        local this_timeout_ticks=$((du_timeout * 10))
        DU_SIZE_RESULT="0"

        if [[ "$du_timeout" -le 0 ]] 2>/dev/null; then
            DU_SIZE_RESULT="$(/usr/bin/du -sk "$target_path" 2>/dev/null | /usr/bin/awk '{print $1; exit}')"
            [[ -n "$DU_SIZE_RESULT" ]] || DU_SIZE_RESULT="0"
            return 0
        fi
        _pch_storage_du_budget_start
        if _pch_storage_du_budget_expired; then
            _pch_storage_trace_test_du "$target_path" "${du_test_duration_ticks:-0}" 0 "timed_out"
            DU_SIZE_RESULT="__PCH_TIMEOUT__"
            return 0
        fi

        if [[ -n "$du_test_duration_ticks" ]]; then
            local allowed_ticks="$du_test_duration_ticks"
            local remaining_budget_ticks
            local test_measure_status="ok"
            if [[ "$this_timeout_ticks" -lt "$allowed_ticks" ]]; then
                allowed_ticks="$this_timeout_ticks"
                test_measure_status="timed_out"
            fi
            if [[ "$du_budget" -gt 0 ]]; then
                remaining_budget_ticks=$((du_test_deadline_ticks - du_test_clock_ticks))
                if [[ "$remaining_budget_ticks" -lt "$allowed_ticks" ]]; then
                    allowed_ticks="$remaining_budget_ticks"
                    test_measure_status="timed_out"
                fi
            fi
            du_test_clock_ticks=$((du_test_clock_ticks + allowed_ticks))
            _pch_storage_trace_test_du \
                "$target_path" "$du_test_duration_ticks" "$allowed_ticks" "$test_measure_status"
            if [[ "$test_measure_status" == "timed_out" ]]; then
                DU_SIZE_RESULT="__PCH_TIMEOUT__"
            else
                DU_SIZE_RESULT="$du_test_size_kb"
            fi
            return 0
        fi

        /usr/bin/du -sk "$target_path" > "$out_file" 2>/dev/null &
        pid=$!
        while /bin/kill -0 "$pid" 2>/dev/null; do
            if _pch_storage_du_budget_expired || [[ "$waited_ticks" -ge "$this_timeout_ticks" ]]; then
                /bin/kill -9 "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                /bin/rm -f "$out_file"
                DU_SIZE_RESULT="__PCH_TIMEOUT__"
                return 0
            fi
            /bin/sleep 0.1
            waited_ticks=$((waited_ticks + 1))
        done
        wait "$pid" 2>/dev/null || true
        size_kb="$(/usr/bin/awk '{print $1; exit}' "$out_file" 2>/dev/null)"
        /bin/rm -f "$out_file"
        DU_SIZE_RESULT="${size_kb:-0}"
    }

    add_du_path() {
        local kind="$1"
        local label="$2"
        local target_path="$3"
        local cleanup_id="${4:-}"
        local size_kb
        local measure_status="ok"
        local measure_note=""

        [[ -e "$target_path" ]] || return 0
        case "$target_path" in
            /*) ;;
            *) return 0 ;;
        esac
        case "$target_path$cleanup_id" in
            *$'\t'*|*$'\n'*|*$'\r'*) return 0 ;;
        esac
        case "$seen" in
            *"|$target_path|"*) return 0 ;;
        esac
        seen="${seen}${target_path}|"

        du_size_kb "$target_path"
        size_kb="$DU_SIZE_RESULT"
        if [[ "$size_kb" == "__PCH_TIMEOUT__" ]]; then
            size_kb=0
            measure_status="timed_out"
            measure_note="빠른 검사의 시간 제한 때문에 크기 측정을 보류했습니다. 필요하면 PCH_STORAGE_DU_TIMEOUT=0으로 정밀 측정하세요."
        fi
        [[ -n "$size_kb" ]] || size_kb=0
        /usr/bin/printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$kind" "$label" "$target_path" "$size_kb" "$measure_status" "$measure_note" "$cleanup_id" >> "$TMP_DIR/storage_paths.tsv"
    }

    add_sized_path() {
        local kind="$1"
        local label="$2"
        local target_path="$3"
        local size_kb="$4"
        local measure_note="${5:-}"
        local cleanup_id="${6:-}"

        [[ -e "$target_path" ]] || return 0
        [[ "$target_path" == /* ]] || return 0
        case "$label$target_path$measure_note$cleanup_id" in
            *$'\t'*|*$'\n'*|*$'\r'*) return 0 ;;
        esac
        case "$size_kb" in ''|*[!0-9]*) return 0 ;; esac
        case "$seen" in
            *"|$target_path|"*) return 0 ;;
        esac
        seen="${seen}${target_path}|"
        /usr/bin/printf "%s\t%s\t%s\t%s\tok\t%s\t%s\n" "$kind" "$label" "$target_path" "$size_kb" "$measure_note" "$cleanup_id" >> "$TMP_DIR/storage_paths.tsv"
    }

    add_access_check() {
        local kind="$1"
        local label="$2"
        local target_path="$3"
        local status="missing"
        local note="경로가 없습니다."
        local err

        [[ -n "$target_path" ]] || return 0
        case "$target_path" in
            /*) ;;
            *) return 0 ;;
        esac
        case "$target_path" in
            *$'\t'*|*$'\n'*|*$'\r'*) return 0 ;;
        esac

        if [[ -e "$target_path" ]]; then
            if /usr/bin/find "$target_path" -maxdepth 1 -mindepth 1 -print -quit >/dev/null 2>"$TMP_DIR/find_access.err"; then
                status="ok"
                note="읽을 수 있습니다."
            else
                err="$(/bin/cat "$TMP_DIR/find_access.err" 2>/dev/null || true)"
                status="blocked"
                note="${err:-읽기 권한이 부족할 수 있습니다.}"
            fi
        fi

        case "$note" in
            *$'\t'*|*$'\n'*|*$'\r'*) note="읽기 권한이 부족할 수 있습니다." ;;
        esac
        /usr/bin/printf "%s\t%s\t%s\t%s\t%s\n" "$kind" "$label" "$target_path" "$status" "$note" >> "$TMP_DIR/storage_access.tsv"
    }

    local ps_commands ps_detailed
    ps_commands="$(/bin/ps -axo command= 2>/dev/null || true)"
    ps_detailed="$(/bin/ps -axo pid=,ppid=,etime=,rss=,command= 2>/dev/null || true)"
    if [[ -n "$ps_detailed" ]]; then
        record_collection_status "runtime_processes" "개발 런타임 프로세스" "ok" "false" "실행 중인 개발 도구와 자동화 프로세스를 확인했습니다."
    else
        record_collection_status "runtime_processes" "개발 런타임 프로세스" "failed" "false" "개발 런타임 프로세스를 읽지 못했습니다."
    fi
    count_processes() {
        local pattern="$1"
        /usr/bin/printf "%s\n" "$ps_commands" \
            | /usr/bin/grep -E "$pattern" \
            | /usr/bin/grep -v -E "grep -E|scripts/scanner.sh|storage.sh" \
            | /usr/bin/wc -l \
            | /usr/bin/tr -d ' '
    }

    add_runtime_signal() {
        local kind="$1"
        local label="$2"
        local count="$3"
        local risk="$4"
        local action="$5"
        local note="$6"
        local pid="${7:-0}"
        local ppid="${8:-0}"
        local elapsed="${9:-}"
        local channel="${10:-}"
        local state="${11:-}"
        local profile="${12:-}"
        local controller="${13:-}"
        local memory_kb="${14:-0}"
        local tree_memory_kb="${15:-0}"
        local tree_process_count="${16:-0}"

        case "$memory_kb" in ''|*[!0-9]*) memory_kb="0" ;; esac
        case "$tree_memory_kb" in ''|*[!0-9]*) tree_memory_kb="$memory_kb" ;; esac
        case "$tree_process_count" in ''|*[!0-9]*) tree_process_count="0" ;; esac
        case "$label$action$note$elapsed$channel$state$profile$controller" in
            *$'\t'*|*$'\n'*|*$'\r'*) return 0 ;;
        esac
        /usr/bin/printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$kind" "$label" "${count:-0}" "$risk" "$action" "$note" \
            "$pid" "$ppid" "$elapsed" "$channel" "$state" "$profile" "$controller" \
            "$memory_kb" "$tree_memory_kb" "$tree_process_count" \
            >> "$TMP_DIR/storage_runtime.tsv"
    }

    _pch_collect_storage_applications
    _pch_collect_storage_simulators
    _pch_collect_known_storage_paths
    _pch_collect_storage_access_checks
    _pch_collect_storage_runtime_signals

    # Status is field 5/7 (trailing tab) in storage_paths.tsv but the LAST field
    # in storage_simulators.tsv (line end, no trailing tab), so accept either.
    if /usr/bin/grep -Eq $'\ttimed_out(\t|$)' "$TMP_DIR/storage_paths.tsv" "$TMP_DIR/storage_simulators.tsv" 2>/dev/null; then
        record_collection_status "storage_inventory" "저장공간 경로 측정" "timed_out" "false" "시간 제한 안에 일부 경로를 측정하지 못했습니다."
    else
        record_collection_status "storage_inventory" "저장공간 경로 측정" "ok" "false" "알려진 저장공간 경로를 측정했습니다."
    fi
    _pch_storage_du_budget_stop
}
