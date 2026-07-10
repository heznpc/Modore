#!/bin/bash
# scanner 모듈 (macOS): 저장공간 압박 + 개발 도구/캐시 용량
# 출력: storage_df.txt, storage_paths.tsv, storage_access.tsv, storage_runtime.tsv, storage_simulators.tsv
# 의존: df, du, find

collect_storage() {
    local df_target="/"
    local du_timeout="${PCH_STORAGE_DU_TIMEOUT:-8}"
    local du_budget="${PCH_STORAGE_TOTAL_DU_BUDGET:-32}"
    local du_elapsed_ticks=0
    local du_budget_ticks=0
    local DU_SIZE_RESULT="0"
    case "$du_timeout" in
        ''|*[!0-9]*) du_timeout=8 ;;
    esac
    case "$du_budget" in
        ''|*[!0-9]*) du_budget=32 ;;
    esac
    du_budget_ticks=$((du_budget * 10))
    if [[ -d "/System/Volumes/Data" ]]; then
        df_target="/System/Volumes/Data"
    fi

    /bin/df -Pk "$df_target" 2>/dev/null | /usr/bin/tail -n 1 > "$TMP_DIR/storage_df.txt" || true
    : > "$TMP_DIR/storage_paths.tsv"
    : > "$TMP_DIR/storage_access.tsv"
    : > "$TMP_DIR/storage_runtime.tsv"
    : > "$TMP_DIR/storage_simulators.tsv"

    local seen="|"
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
        if [[ "$du_budget_ticks" -gt 0 && "$du_elapsed_ticks" -ge "$du_budget_ticks" ]] 2>/dev/null; then
            DU_SIZE_RESULT="__PCH_TIMEOUT__"
            return 0
        fi
        if [[ "$du_budget_ticks" -gt 0 ]] 2>/dev/null; then
            local remaining_ticks=$((du_budget_ticks - du_elapsed_ticks))
            if [[ "$remaining_ticks" -lt "$this_timeout_ticks" ]]; then
                this_timeout_ticks="$remaining_ticks"
            fi
        fi

        /usr/bin/du -sk "$target_path" > "$out_file" 2>/dev/null &
        pid=$!
        while /bin/kill -0 "$pid" 2>/dev/null; do
            if [[ "$waited_ticks" -ge "$this_timeout_ticks" ]]; then
                /bin/kill -9 "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                /bin/rm -f "$out_file"
                du_elapsed_ticks=$((du_elapsed_ticks + waited_ticks))
                DU_SIZE_RESULT="__PCH_TIMEOUT__"
                return 0
            fi
            /bin/sleep 0.1
            waited_ticks=$((waited_ticks + 1))
        done
        wait "$pid" 2>/dev/null || true
        du_elapsed_ticks=$((du_elapsed_ticks + waited_ticks))
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

    local ps_commands
    ps_commands="$(/bin/ps -axo command= 2>/dev/null || true)"
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

        case "$label$action$note" in
            *$'\t'*|*$'\n'*|*$'\r'*) return 0 ;;
        esac
        /usr/bin/printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$kind" "$label" "${count:-0}" "$risk" "$action" "$note" >> "$TMP_DIR/storage_runtime.tsv"
    }

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
        app_note="Bundle ID: $bundle_id. 앱 본체와 정확히 귀속되는 사용자 데이터만 승인 후 휴지통으로 이동합니다."
        add_sized_path "application" "$app_name" "$app_path" "$app_kb" "$app_note" "app_uninstall:$bundle_id"
    done < <(
        /usr/bin/find /Applications -mindepth 1 -maxdepth 1 -type d -name '*.app' -print0 2>/dev/null
        /usr/bin/find "$HOME/Applications" -mindepth 1 -maxdepth 2 -type d -name '*.app' -prune -print0 2>/dev/null
    )

    local simctl_devices
    simctl_devices="$(/usr/bin/xcrun simctl list devices available 2>/dev/null || true)"
    if [[ -n "$simctl_devices" ]]; then
        local runtime=""
        /usr/bin/printf "%s\n" "$simctl_devices" | while IFS= read -r line; do
            case "$line" in
                "-- "*)
                    runtime="${line#-- }"
                    runtime="${runtime% --}"
                    ;;
                *)
                    local device_name uuid state device_path device_size_kb device_measure_status saved_du_ticks
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
                        # Device detail is useful, but it must not consume the shared budget
                        # reserved for cleanup candidates measured later in this scan.
                        saved_du_ticks="$du_elapsed_ticks"
                        du_size_kb "$device_path"
                        du_elapsed_ticks="$saved_du_ticks"
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
        done
    fi

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
    add_du_path "protected_history" "Claude local agent workspaces" "$HOME/Library/Application Support/Claude/local-agent-mode-sessions"
    add_du_path "protected_history" "Codex session history (jsonl)" "$HOME/.codex/sessions"
    add_du_path "cache" "User caches" "$HOME/Library/Caches" "user_caches"
    add_du_path "cache" "CLI/tool caches" "$HOME/.cache" "cli_tool_caches"
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

    # Full Disk Access가 없으면 macOS가 일부 개인 데이터/앱 데이터 영역을 숨길 수 있다.
    add_access_check "privacy_area" "Mail data" "$HOME/Library/Mail"
    add_access_check "privacy_area" "Messages data" "$HOME/Library/Messages"
    add_access_check "privacy_area" "Safari data" "$HOME/Library/Safari"
    add_access_check "privacy_area" "Calendars data" "$HOME/Library/Calendars"
    add_access_check "privacy_area" "Contacts data" "$HOME/Library/Application Support/AddressBook"
    add_access_check "app_data" "App containers" "$HOME/Library/Containers"
    add_access_check "app_data" "Group containers" "$HOME/Library/Group Containers"

    # 반복 생성원: 공간을 직접 지우기보다 "왜 또 쌓이는지"를 설명하는 신호.
    local chrome_count chrome_auto_count sim_count codex_count claude_count node_count
    chrome_count="$(count_processes 'Google Chrome')"
    chrome_auto_count="$(count_processes 'playwright_chromiumdev_profile|--headless|remote-debugging-pipe')"
    sim_count="$(count_processes '/CoreSimulator/Volumes/iOS_|launchd_sim|Simulator.app|CoreSimulatorBridge')"
    codex_count="$(count_processes 'Codex.app|/codex|node_repl|SkyComputerUseClient')"
    claude_count="$(count_processes 'Claude.app|/claude|claude-code')"
    node_count="$(count_processes '(^|/)(node|npm|npx)( |$)')"

    add_runtime_signal "process_count" "Chrome processes" "$chrome_count" "$([[ "$chrome_count" -ge 20 ]] && echo warning || echo info)" "브라우저 탭/자동화 정리" "Chrome 계열 프로세스가 많으면 code-sign clone과 프로필 캐시가 다시 쌓일 수 있습니다."
    add_runtime_signal "process_count" "Headless/Playwright Chrome" "$chrome_auto_count" "$([[ "$chrome_auto_count" -gt 0 ]] && echo warning || echo safe)" "브라우저 자동화 종료" "headless Chrome이 살아 있으면 /var/folders 임시 clone을 붙잡을 수 있습니다."
    add_runtime_signal "process_count" "CoreSimulator processes" "$sim_count" "$([[ "$sim_count" -ge 100 ]] && echo warning || echo info)" "필요한 Simulator만 Booted" "부팅된 Simulator는 런타임 프로세스를 대량으로 띄웁니다."
    add_runtime_signal "process_count" "Codex processes" "$codex_count" "$([[ "$codex_count" -ge 20 ]] && echo warning || echo info)" "끝난 Codex 세션 정리" "여러 Codex/Computer Use 세션은 브라우저, 첨부파일, 세션 캐시를 함께 늘립니다."
    add_runtime_signal "process_count" "Claude processes" "$claude_count" "$([[ "$claude_count" -ge 15 ]] && echo warning || echo info)" "끝난 Claude 세션 정리" "Claude Desktop/Code 세션도 Application Support와 임시 업데이트 파일을 누적시킬 수 있습니다."
    add_runtime_signal "process_count" "Node/npm/npx processes" "$node_count" "$([[ "$node_count" -ge 25 ]] && echo warning || echo info)" "개발 서버 종료" "여러 개발 서버와 MCP/브라우저 자동화 런타임이 동시에 떠 있을 수 있습니다."

}
