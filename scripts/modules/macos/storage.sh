#!/bin/bash
# scanner 모듈 (macOS): 저장공간 압박 + 개발 도구/캐시 용량
# 출력: $TMP_DIR/storage_df.txt, $TMP_DIR/storage_paths.tsv, $TMP_DIR/storage_access.tsv, $TMP_DIR/storage_runtime.tsv
# 의존: df, du, find

collect_storage() {
    local df_target="/"
    local du_timeout="${PCH_STORAGE_DU_TIMEOUT:-8}"
    local du_budget="${PCH_STORAGE_TOTAL_DU_BUDGET:-32}"
    local du_elapsed_total=0
    case "$du_timeout" in
        ''|*[!0-9]*) du_timeout=8 ;;
    esac
    case "$du_budget" in
        ''|*[!0-9]*) du_budget=32 ;;
    esac
    if [[ -d "/System/Volumes/Data" ]]; then
        df_target="/System/Volumes/Data"
    fi

    /bin/df -Pk "$df_target" 2>/dev/null | /usr/bin/tail -n 1 > "$TMP_DIR/storage_df.txt" || true
    : > "$TMP_DIR/storage_paths.tsv"
    : > "$TMP_DIR/storage_access.tsv"
    : > "$TMP_DIR/storage_runtime.tsv"

    local seen="|"
    du_size_kb() {
        local target_path="$1"
        local out_file="$TMP_DIR/du_size.$$.$RANDOM.out"
        local waited=0
        local size_kb
        local pid
        local this_timeout="$du_timeout"

        if [[ "$du_timeout" -le 0 ]] 2>/dev/null; then
            /usr/bin/du -sk "$target_path" 2>/dev/null | /usr/bin/awk '{print $1; exit}'
            return 0
        fi
        if [[ "$du_budget" -gt 0 && "$du_elapsed_total" -ge "$du_budget" ]] 2>/dev/null; then
            /usr/bin/printf "__PCH_TIMEOUT__"
            return 0
        fi
        if [[ "$du_budget" -gt 0 ]] 2>/dev/null; then
            local remaining=$((du_budget - du_elapsed_total))
            if [[ "$remaining" -lt "$this_timeout" ]]; then
                this_timeout="$remaining"
            fi
        fi

        /usr/bin/du -sk "$target_path" > "$out_file" 2>/dev/null &
        pid=$!
        while /bin/kill -0 "$pid" 2>/dev/null; do
            if [[ "$waited" -ge "$this_timeout" ]]; then
                /bin/kill "$pid" 2>/dev/null || true
                /bin/sleep 1
                /bin/kill -9 "$pid" 2>/dev/null || true
                /bin/rm -f "$out_file"
                du_elapsed_total=$((du_elapsed_total + waited))
                /usr/bin/printf "__PCH_TIMEOUT__"
                return 0
            fi
            /bin/sleep 1
            waited=$((waited + 1))
        done
        wait "$pid" 2>/dev/null || true
        du_elapsed_total=$((du_elapsed_total + waited))
        size_kb="$(/usr/bin/awk '{print $1; exit}' "$out_file" 2>/dev/null)"
        /bin/rm -f "$out_file"
        /usr/bin/printf "%s" "${size_kb:-0}"
    }

    add_du_path() {
        local kind="$1"
        local label="$2"
        local target_path="$3"
        local size_kb
        local measure_status="ok"
        local measure_note=""

        [[ -e "$target_path" ]] || return 0
        case "$target_path" in
            /*) ;;
            *) return 0 ;;
        esac
        case "$target_path" in
            *$'\t'*|*$'\n'*|*$'\r'*) return 0 ;;
        esac
        case "$seen" in
            *"|$target_path|"*) return 0 ;;
        esac
        seen="${seen}${target_path}|"

        size_kb="$(du_size_kb "$target_path")"
        if [[ "$size_kb" == "__PCH_TIMEOUT__" ]]; then
            size_kb=0
            measure_status="timed_out"
            measure_note="빠른 검사의 시간 제한 때문에 크기 측정을 보류했습니다. 필요하면 PCH_STORAGE_DU_TIMEOUT=0으로 정밀 측정하세요."
        fi
        [[ -n "$size_kb" ]] || size_kb=0
        /usr/bin/printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$kind" "$label" "$target_path" "$size_kb" "$measure_status" "$measure_note" >> "$TMP_DIR/storage_paths.tsv"
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

    # 일반 캐시/임시파일: 대부분 재생성 가능하지만 앱 로그아웃/재빌드 시간을 만들 수 있음.
    add_du_path "cache" "User caches" "$HOME/Library/Caches"
    add_du_path "cache" "CLI/tool caches" "$HOME/.cache"
    add_du_path "cache" "npm cache" "$HOME/.npm"
    add_du_path "cache" "Gradle cache" "$HOME/.gradle/caches"
    add_du_path "cache" "CocoaPods cache" "$HOME/Library/Caches/CocoaPods"
    add_du_path "cache" "Playwright browser cache" "$HOME/Library/Caches/ms-playwright"
    add_du_path "cache" "pnpm store" "$HOME/Library/pnpm"
    add_du_path "cache" "Dart/Flutter pub cache" "$HOME/.pub-cache"
    add_du_path "temp" "System temporary files" "/private/tmp"
    add_du_path "trash" "User Trash" "$HOME/.Trash"

    # Xcode / Apple 개발환경.
    add_du_path "build_cache" "Xcode DerivedData" "$HOME/Library/Developer/Xcode/DerivedData"
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

    # Chrome 앱 번들 code-sign clone 누적은 디스크 압박 때 의미 있는 임시 후보.
    local clone_dir
    for clone_dir in /private/var/folders/*/*/X/com.google.Chrome.code_sign_clone /private/var/folders/*/*/T/com.google.Chrome.code_sign_clone; do
        [[ -d "$clone_dir" ]] || continue
        add_du_path "chrome_clone" "Chrome code-sign clones" "$clone_dir"
    done

    # 앱 본체 크기 측정은 빠른 검사에서 제외한다.
    # /Applications의 대형 번들을 깊게 재거나 Spotlight 메타데이터를 앱마다 조회하면 사용자가 앱이 멈춘 것처럼 느낀다.
    # 설치 앱 맥락은 recentInstalls 섹션에서 별도로 제공하고, 삭제는 AppCleaner/Finder 검토 흐름으로 분리한다.

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
	                *"(Booted)"*)
	                    local device_name uuid
	                    device_name="$(/usr/bin/sed -E 's/^[[:space:]]*//; s/[[:space:]]*\([0-9A-F-]{36}\)[[:space:]]*\(Booted\).*//' <<< "$line")"
	                    uuid="$(/usr/bin/sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' <<< "$line")"
	                    if [[ ! "$uuid" =~ ^[0-9A-F-]{36}$ ]]; then
	                        uuid="unknown"
	                    fi
	                    add_runtime_signal "booted_simulator" "$device_name" "1" "warning" "켜진 Simulator 확인" "${runtime} / ${uuid}"
	                    ;;
	            esac
        done
    fi
}
