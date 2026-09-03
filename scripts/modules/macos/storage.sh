#!/bin/bash
# scanner 모듈 (macOS): 저장공간 압박 + 개발 도구/캐시 용량
# 출력: storage_df.txt, storage_paths.tsv, storage_access.tsv, storage_runtime.tsv, storage_simulators.tsv
# 의존: df, du, find

if ! declare -F record_collection_status >/dev/null 2>&1; then
    record_collection_status() { :; }
fi

_pch_storage_host_inventory_allowed() {
    [[ "${PCH_TEST_MODE:-}" != "1" \
        || "${PCH_TEST_STORAGE_ALLOW_HOST_INVENTORY:-0}" == "1" ]]
}

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
    local maximum_roots="${PCH_BROWSER_AUTOMATION_ROOT_LIMIT:-128}"
    local maximum_snapshot_rows="${PCH_BROWSER_PROCESS_SNAPSHOT_LIMIT:-32768}"
    local maximum_work_units="${PCH_BROWSER_ANALYSIS_WORK_LIMIT:-2000000}"
    case "$maximum_roots" in ''|*[!0-9]*|0) maximum_roots=128 ;; esac
    case "$maximum_snapshot_rows" in ''|*[!0-9]*|0) maximum_snapshot_rows=32768 ;; esac
    case "$maximum_work_units" in ''|*[!0-9]*|0) maximum_work_units=2000000 ;; esac
    [[ "$maximum_roots" -le 512 ]] || maximum_roots=512
    [[ "$maximum_snapshot_rows" -le 65536 ]] || maximum_snapshot_rows=65536
    [[ "$maximum_work_units" -le 10000000 ]] || maximum_work_units=10000000

    # Build parent/controller and descendant facts from the one already captured
    # process table. The previous implementation called ps two to ten times per
    # browser root and re-parsed the whole table once per root, so the diagnostic
    # itself became slow when automation had leaked hundreds of browser roots.
    # Commands stay in awk memory only; output remains categorical metadata.
    /usr/bin/awk \
        -v maximum_roots="$maximum_roots" \
        -v maximum_snapshot_rows="$maximum_snapshot_rows" \
        -v maximum_work_units="$maximum_work_units" '
        function elapsed_seconds(raw, day_parts, clock_parts, day_count, count) {
            day_count = 0
            count = split(raw, day_parts, "-")
            if (count == 2) {
                if (day_parts[1] !~ /^[0-9]+$/) return 0
                day_count = day_parts[1] + 0
                raw = day_parts[2]
            } else if (count != 1) return 0
            count = split(raw, clock_parts, ":")
            if (count == 3 && clock_parts[1] ~ /^[0-9]+$/ \
                && clock_parts[2] ~ /^[0-9]+$/ && clock_parts[3] ~ /^[0-9]+$/) {
                return day_count * 86400 + clock_parts[1] * 3600 \
                    + clock_parts[2] * 60 + clock_parts[3]
            }
            if (count == 2 && clock_parts[1] ~ /^[0-9]+$/ \
                && clock_parts[2] ~ /^[0-9]+$/) {
                return day_count * 86400 + clock_parts[1] * 60 + clock_parts[2]
            }
            return 0
        }
        function controller_for(current_pid, depth, command, fallback) {
            fallback = "other local process"
            for (depth = 0; depth < 8; depth++) {
                if (current_pid == "" || current_pid == "0" \
                    || current_pid == "1" || !(current_pid in commands)) break
                command = commands[current_pid]
                if (command ~ /Codex\.app/ || command ~ /\/codex/ \
                    || command ~ /SkyComputerUseClient/) return "Codex"
                if (command ~ /Claude\.app/ || command ~ /\/claude/ \
                    || command ~ /claude-code/) return "Claude"
                if (command ~ /ChatGPT\.app/ || command ~ /\/ChatGPT/ \
                    || command ~ /com\.openai\.chat/) return "ChatGPT"
                if (command ~ /playwright/ || command ~ /node/) fallback = "Playwright/Node"
                else if (command ~ /python/ && fallback == "other local process") \
                    fallback = "Python automation"
                current_pid = parents[current_pid]
            }
            return fallback
        }
        {
            if (NR > maximum_snapshot_rows) {
                snapshot_limited = 1
                next
            }
            pid = $1
            ppid = $2
            elapsed = $3
            rss = $4
            if (pid !~ /^[0-9]+$/ || ppid !~ /^[0-9]+$/) next
            command = ""
            for (field = 5; field <= NF; field++) {
                if (field > 5) command = command " "
                command = command $field
            }
            row_count += 1
            pids[row_count] = pid
            parents[pid] = ppid
            elapsed_values[pid] = elapsed
            memory[pid] = rss ~ /^[0-9]+$/ ? rss + 0 : 0
            commands[pid] = command

            is_signal = command ~ /playwright_chromiumdev_profile/ \
                || command ~ /--remote-debugging-pipe/ \
                || command ~ /--remote-debugging-port/ \
                || command ~ /--no-startup-window/ || command ~ /--headless/
            is_helper = command ~ /Google Chrome Helper/ \
                || command ~ /Chromium Helper/ || command ~ / --type=/
            is_root = command ~ /Google Chrome\.app\/Contents\/MacOS\/Google Chrome/ \
                || command ~ /Google Chrome for Testing\.app\/Contents\/MacOS\/Google Chrome for Testing/ \
                || command ~ /Chromium\.app\/Contents\/MacOS\/Chromium/ \
                || (command ~ /ms-playwright\// && command ~ /headless_shell/)
            if (!is_signal || is_helper || !is_root) next
            if (root_count >= maximum_roots) {
                roots_limited = 1
                next
            }
            root_count += 1
            roots[root_count] = pid
        }
        END {
            if (snapshot_limited) {
                print "__PCH_BROWSER_BOUNDED__"
                exit
            }
            for (root_index = 1; root_index <= root_count; root_index++) {
                if (work_units >= maximum_work_units) {
                    budget_limited = 1
                    break
                }
                root = roots[root_index]
                command = commands[root]
                ppid = parents[root]
                elapsed = elapsed_values[root]
                if (elapsed !~ /^[0-9:-]+$/) elapsed = "unknown"
                rss = memory[root]
                if (command ~ /Google Chrome for Testing\.app\// \
                    || command ~ /\/ms-playwright\// || command ~ /Chromium\.app\//) \
                    channel = "isolated"
                else if (command ~ /\/Applications\/Google Chrome\.app\//) \
                    channel = "system"
                else channel = "unknown"
                if (command ~ /playwright_chromiumdev_profile/ \
                    || command ~ /--user-data-dir=\/tmp\// \
                    || command ~ /--user-data-dir=\/private\/tmp\// \
                    || command ~ /--user-data-dir=\/var\/folders\// \
                    || command ~ /--user-data-dir=\/private\/var\/folders\//) \
                    profile = "temporary"
                else if (command ~ /--user-data-dir=/) profile = "custom"
                else profile = "default"

                parent_available = ppid in commands
                parent_parent = parent_available ? parents[ppid] : ""
                controller = parent_available ? controller_for(ppid) : "parent unavailable"
                detached = ppid == "1" || parent_parent == "1" || !parent_available
                if (detached && elapsed_seconds(elapsed) >= 3600) state = "orphan_candidate"
                else if (detached) state = "detached"
                else state = "active"

                for (included_pid in included) delete included[included_pid]
                included[root] = 1
                for (pass = 0; pass < 16; pass++) {
                    changed = 0
                    for (row = 1; row <= row_count; row++) {
                        work_units += 1
                        if (work_units >= maximum_work_units) {
                            budget_limited = 1
                            break
                        }
                        child = pids[row]
                        if (included[parents[child]] && !included[child]) {
                            included[child] = 1
                            changed = 1
                        }
                    }
                    if (budget_limited) break
                    if (!changed) break
                }
                if (budget_limited) break
                tree_memory = 0
                tree_count = 0
                for (row = 1; row <= row_count; row++) {
                    work_units += 1
                    if (work_units >= maximum_work_units) {
                        budget_limited = 1
                        break
                    }
                    child = pids[row]
                    if (included[child]) {
                        tree_memory += memory[child]
                        tree_count += 1
                    }
                }
                if (budget_limited) break
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\n", \
                    root, ppid, elapsed, channel, state, profile, controller, \
                    rss, tree_memory, tree_count
            }
            if (roots_limited || budget_limited) print "__PCH_BROWSER_BOUNDED__"
        }
    '
}

_pch_storage_test_tool() {
    local requested_tool="$1"
    local tool_root="${PCH_TEST_STORAGE_TOOL_ROOT:-}"
    local physical_root physical_parent
    [[ "${PCH_TEST_MODE:-}" == "1" && -n "$tool_root" ]] || return 1
    [[ "$tool_root" == /* && -d "$tool_root" && ! -L "$tool_root" ]] || return 1
    [[ "$requested_tool" == "$tool_root/"* && -f "$requested_tool" \
        && ! -L "$requested_tool" && -x "$requested_tool" ]] || return 1
    physical_root="$(cd -P "$tool_root" 2>/dev/null && /bin/pwd -P)" || return 1
    physical_parent="$(cd -P "$(/usr/bin/dirname "$requested_tool")" 2>/dev/null \
        && /bin/pwd -P)" || return 1
    [[ "$physical_parent" == "$physical_root" \
        || "$physical_parent" == "$physical_root/"* ]] || return 1
    /usr/bin/printf '%s' "$requested_tool"
}

_pch_storage_regular_identity() {
    local path="$1"
    local identity device inode owner links size
    [[ -f "$path" && ! -L "$path" ]] || return 1
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        identity="$(/usr/bin/stat -f '%d:%i:%u:%l:%z' "$path" 2>/dev/null)" || return 1
    else
        identity="$(/usr/bin/stat -c '%d:%i:%u:%h:%s' "$path" 2>/dev/null)" || return 1
    fi
    IFS=: read -r device inode owner links size <<< "$identity"
    case "$device$inode$owner$links$size" in ''|*[!0-9]*) return 1 ;; esac
    [[ "$owner" == "0" || "$owner" == "$(/usr/bin/id -u)" ]] || return 1
    [[ "$links" == "1" && "$size" -gt 0 && "$size" -le 4194304 ]] || return 1
    /usr/bin/printf '%s' "$identity"
}

_pch_storage_process_snapshot() (
    local snapshot_file="$TMP_DIR/storage_process_snapshot.$$.$RANDOM.out"
    local snapshot_pid="" ticks=0 status=0
    # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
    cleanup_process_snapshot() {
        trap - HUP INT TERM EXIT
        if [[ -n "${snapshot_pid:-}" ]]; then
            /bin/kill -KILL "$snapshot_pid" 2>/dev/null || true
            wait "$snapshot_pid" 2>/dev/null || true
        fi
        /bin/rm -f "$snapshot_file" 2>/dev/null || true
    }
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap cleanup_process_snapshot EXIT
    : > "$snapshot_file" || return 1
    ( ulimit -f 2048 || exit 1; exec /bin/ps -axo pid=,ppid=,pgid=,state= ) \
        > "$snapshot_file" 2>/dev/null &
    snapshot_pid=$!
    while jobs -pr | /usr/bin/grep -qx "$snapshot_pid"; do
        if [[ "$ticks" -ge 10 ]]; then
            /bin/kill -KILL "$snapshot_pid" 2>/dev/null || true
            wait "$snapshot_pid" 2>/dev/null || true
            snapshot_pid=""
            return 124
        fi
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    if wait "$snapshot_pid" 2>/dev/null; then status=0; else status=$?; fi
    snapshot_pid=""
    [[ "$status" -eq 0 ]] || return "$status"
    /bin/cat "$snapshot_file"
)

_pch_storage_process_is_live() {
    local process_pid="$1" process_state process_snapshot
    case "$process_pid" in ''|*[!0-9]*|0) return 1 ;; esac
    process_snapshot="$(_pch_storage_process_snapshot 2>/dev/null || true)"
    process_state="$(
        /usr/bin/printf '%s\n' "$process_snapshot" \
            | /usr/bin/awk -v target="$process_pid" \
                '$1 == target { print $4; exit }'
    )"
    case "$process_state" in
        ''|*Z*) return 1 ;;
    esac
    return 0
}

_pch_storage_tool_to_file() (
    local output_file="$1"
    local timeout_seconds="$2"
    shift 2
    local command_pid="" command_status=0 ticks=0 guard_ticks=0
    local collector_pid="$$" helper_pid=""
    local collector_dead=0
    local output_limit_kb="${_pch_storage_tool_output_limit_kb:-8}"
    local preserve_partial="${_pch_storage_tool_preserve_partial:-0}"
    local output_limit_blocks output_limit_bytes output_size
    local guard_directory="" guard_ready="" guard_done="" start_marker=""
    local helper_pid_marker=""
    local status_marker="" status_staging="" guard_fd_open=0
    # shellcheck disable=SC2329 # Invoked through EXIT/HUP/INT/TERM traps below.
    cleanup_bounded_tool() {
        local cleanup_command="${command_pid:-}"
        trap - HUP INT TERM EXIT
        if [[ "${guard_fd_open:-0}" == "1" ]]; then
            /usr/bin/printf 'done\n' >&19 2>/dev/null || true
            exec 19>&-
            guard_fd_open=0
        fi
        if [[ -n "$cleanup_command" ]]; then
            /bin/kill -TERM -- "-$cleanup_command" 2>/dev/null || true
            /bin/kill -KILL -- "-$cleanup_command" 2>/dev/null || true
            wait "$cleanup_command" 2>/dev/null || true
        fi
        command_pid=""
        guard_ticks=0
        while [[ -n "${guard_done:-}" && ! -f "$guard_done" \
            && "$guard_ticks" -lt 20 ]]; do
            /bin/sleep 0.01
            guard_ticks=$((guard_ticks + 1))
        done
        if [[ -n "${guard_directory:-}" ]]; then
            /bin/rm -f "$guard_ready" "$guard_done" "$start_marker" \
                "$helper_pid_marker" \
                "$status_marker" "$status_staging" 2>/dev/null || true
            /bin/rmdir "$guard_directory" 2>/dev/null || true
        fi
    }
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap cleanup_bounded_tool EXIT
    case "$timeout_seconds" in ''|*[!0-9]*|0) return 124 ;; esac
    case "$output_limit_kb" in ''|*[!0-9]*|0) output_limit_kb=8 ;; esac
    [[ "$output_limit_kb" -le 4096 ]] || output_limit_kb=4096
    output_limit_blocks="$output_limit_kb"
    output_limit_bytes=$((output_limit_kb * 1024))
    : > "$output_file" || return 1
    guard_directory="$(/usr/bin/mktemp -d "${output_file}.guard.XXXXXX")" \
        || return 1
    /bin/chmod 700 "$guard_directory" 2>/dev/null || return 1
    guard_ready="$guard_directory/ready"
    guard_done="$guard_directory/done"
    start_marker="$guard_directory/start"
    helper_pid_marker="$guard_directory/helper-pid"
    status_marker="$guard_directory/status"
    status_staging="$guard_directory/status.tmp"

    # macOS ships Bash 3.2, where $$ stays equal to the parent shell PID inside
    # a function subshell. A directly invoked child sees this helper's real PID
    # as PPID, so use that observation instead of pretending $$ identifies the
    # helper. The marker remains private inside the mode-700 guard directory.
    /bin/sh -c '/usr/bin/printf "%s" "$PPID" > "$1"' sh "$helper_pid_marker" \
        || return 1
    helper_pid="$(/bin/cat "$helper_pid_marker" 2>/dev/null || true)"
    case "$helper_pid" in ''|*[!0-9]*|0) return 1 ;; esac

    # A provider gets its own process group, while a second private-group guardian
    # watches both an inherited pipe and this helper's actual PID, while the helper
    # checks the top-level collector PID. If either collector layer is killed, the
    # guardian terminates the provider group even when an inherited descriptor
    # delays pipe EOF. The start gate prevents the external command from running
    # before that guardian is ready, so cancellation cannot escape through setup.
    exec 2>/dev/null
    set -m
    exec 19> >(
        exec 1>/dev/null 2>/dev/null
        exec 18<&0
        set -m
        (
            local watched_pid="" guardian_wait_ticks=0 guard_message=""
            trap '' HUP INT TERM
            : > "$guard_ready" 2>/dev/null || exit 1
            if IFS= read -r watched_pid <&18; then
                while /bin/kill -0 "$helper_pid" 2>/dev/null; do
                    guard_message=""
                    if IFS= read -r -t 1 guard_message <&18; then
                        [[ "$guard_message" == "done" ]] && break
                    fi
                done
                if [[ -z "$watched_pid" || "$watched_pid" == *[!0-9]* ]]; then
                    watched_pid=""
                fi
                if [[ -n "$watched_pid" ]] \
                    && /bin/kill -0 -- "-$watched_pid" 2>/dev/null; then
                    /bin/kill -TERM -- "-$watched_pid" 2>/dev/null || true
                    while /bin/kill -0 -- "-$watched_pid" 2>/dev/null \
                        && [[ "$guardian_wait_ticks" -lt 5 ]]; do
                        /bin/sleep 0.02
                        guardian_wait_ticks=$((guardian_wait_ticks + 1))
                    done
                    /bin/kill -KILL -- "-$watched_pid" 2>/dev/null || true
                fi
            fi
            : > "$guard_done" 2>/dev/null || true
            exec 18<&-
        ) &
        wait "$!" 2>/dev/null || true
    )
    guard_fd_open=1
    while [[ ! -f "$guard_ready" ]]; do
        if [[ "$guard_ticks" -ge 50 ]]; then
            exec 19>&-
            guard_fd_open=0
            return 1
        fi
        /bin/sleep 0.01
        guard_ticks=$((guard_ticks + 1))
    done
    (
        exec 19>&-
        gate_ticks=0
        while [[ ! -f "$start_marker" && "$gate_ticks" -lt 50 ]]; do
            /bin/sleep 0.02
            gate_ticks=$((gate_ticks + 1))
        done
        [[ -f "$start_marker" ]] || exit 143
        ulimit -f "$output_limit_blocks" || exit 1
        "$@"
        provider_status=$?
        if /usr/bin/printf '%s' "$provider_status" > "$status_staging" 2>/dev/null; then
            /bin/mv -f "$status_staging" "$status_marker" 2>/dev/null || true
        fi
        exit "$provider_status"
    ) > "$output_file" 2>/dev/null &
    command_pid=$!
    /usr/bin/printf '%s\n' "$command_pid" >&19 || return 1
    : > "$start_marker" || return 1
    while [[ ! -f "$status_marker" ]]; do
        collector_dead=0
        if ! /bin/kill -0 "$collector_pid" 2>/dev/null; then
            collector_dead=1
        elif [[ "$ticks" -gt 0 && $((ticks % 10)) -eq 0 ]] \
            && ! _pch_storage_process_is_live "$collector_pid"; then
            collector_dead=1
        fi
        if [[ "$collector_dead" -eq 1 ]]; then
            /usr/bin/printf 'done\n' >&19 2>/dev/null || true
            exec 19>&-
            guard_fd_open=0
            wait "$command_pid" 2>/dev/null || true
            command_pid=""
            [[ "$preserve_partial" == "1" ]] || : > "$output_file" 2>/dev/null || true
            return 143
        fi
        if [[ "$ticks" -ge $((timeout_seconds * 10)) ]]; then
            /usr/bin/printf 'done\n' >&19 2>/dev/null || true
            exec 19>&-
            guard_fd_open=0
            wait "$command_pid" 2>/dev/null || true
            command_pid=""
            [[ "$preserve_partial" == "1" ]] || : > "$output_file" 2>/dev/null || true
            return 124
        fi
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    command_status="$(/bin/cat "$status_marker" 2>/dev/null || true)"
    case "$command_status" in ''|*[!0-9]*) command_status=1 ;; esac
    /usr/bin/printf 'done\n' >&19 2>/dev/null || true
    exec 19>&-
    guard_fd_open=0
    wait "$command_pid" 2>/dev/null || true
    command_pid=""
    guard_ticks=0
    while [[ ! -f "$guard_done" && "$guard_ticks" -lt 20 ]]; do
        /bin/sleep 0.01
        guard_ticks=$((guard_ticks + 1))
    done
    [[ -f "$guard_done" ]] || return 1
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        output_size="$(/usr/bin/stat -f '%z' "$output_file" 2>/dev/null || true)"
    else
        output_size="$(/usr/bin/stat -c '%s' "$output_file" 2>/dev/null || true)"
    fi
    case "$output_size" in ''|*[!0-9]*) output_size=0 ;; esac
    if [[ "$command_status" -ne 0 || "$output_size" -ge "$output_limit_bytes" ]]; then
        [[ "$preserve_partial" == "1" ]] || : > "$output_file" 2>/dev/null || true
        [[ "$output_size" -lt "$output_limit_bytes" ]] || return 65
    fi
    return "$command_status"
)

_pch_collect_storage_applications() {
    # Spotlight가 계산한 번들 크기를 쓰되, 사용자 Applications 아래의 손상된
    # bundle 하나가 전체 검사를 붙잡지 못하도록 유형·개수·시간을 모두 제한한다.
    local app_path app_bytes app_kb app_name bundle_id app_note info_plist
    local plist_output mdls_output tool_status remaining_seconds plist_identity
    local maximum_apps="${PCH_STORAGE_APPLICATION_LIMIT:-256}"
    local command_timeout="${PCH_STORAGE_APPLICATION_COMMAND_TIMEOUT:-2}"
    local total_budget="${PCH_STORAGE_APPLICATION_TOTAL_BUDGET:-8}"
    local tool_output_limit_kb="${PCH_STORAGE_APPLICATION_OUTPUT_LIMIT_KB:-8}"
    local plist_buddy="/usr/libexec/PlistBuddy"
    local mdls_bin="/usr/bin/mdls"
    local started_at="$SECONDS"
    local considered_apps=0
    local application_test_root=""
    local physical_tool_root physical_application_root
    case "$maximum_apps" in ''|*[!0-9]*|0) maximum_apps=256 ;; esac
    case "$command_timeout" in ''|*[!0-9]*|0) command_timeout=2 ;; esac
    case "$total_budget" in ''|*[!0-9]*|0) total_budget=8 ;; esac
    case "$tool_output_limit_kb" in ''|*[!0-9]*|0) tool_output_limit_kb=8 ;; esac
    [[ "$maximum_apps" -le 512 ]] || maximum_apps=512
    [[ "$command_timeout" -le 10 ]] || command_timeout=10
    [[ "$total_budget" -le 30 ]] || total_budget=30
    [[ "$tool_output_limit_kb" -le 64 ]] || tool_output_limit_kb=64
    local _pch_storage_tool_output_limit_kb="$tool_output_limit_kb"

    # Test mode is host-isolated by default. An omitted fixture root means an
    # empty application inventory, never an implicit walk of /Applications.
    if [[ "${PCH_TEST_MODE:-}" == "1" \
        && -z "${PCH_TEST_STORAGE_APPLICATIONS_ROOT:-}" ]] \
        && ! _pch_storage_host_inventory_allowed; then
        return 0
    fi

    if [[ "${PCH_TEST_MODE:-}" == "1" ]]; then
        if [[ -n "${PCH_TEST_STORAGE_PLISTBUDDY_BIN:-}" ]]; then
            plist_buddy="$(_pch_storage_test_tool "$PCH_TEST_STORAGE_PLISTBUDDY_BIN")" \
                || return 1
        fi
        if [[ -n "${PCH_TEST_STORAGE_MDLS_BIN:-}" ]]; then
            mdls_bin="$(_pch_storage_test_tool "$PCH_TEST_STORAGE_MDLS_BIN")" \
                || return 1
        fi
        if [[ -n "${PCH_TEST_STORAGE_APPLICATIONS_ROOT:-}" ]]; then
            application_test_root="$PCH_TEST_STORAGE_APPLICATIONS_ROOT"
            [[ -n "${PCH_TEST_STORAGE_TOOL_ROOT:-}" \
                && "$application_test_root" == "$PCH_TEST_STORAGE_TOOL_ROOT/"* \
                && -d "$application_test_root" && ! -L "$application_test_root" ]] \
                || return 1
            physical_tool_root="$(cd -P "$PCH_TEST_STORAGE_TOOL_ROOT" 2>/dev/null \
                && /bin/pwd -P)" || return 1
            physical_application_root="$(cd -P "$application_test_root" 2>/dev/null \
                && /bin/pwd -P)" || return 1
            [[ "$physical_application_root" == "$physical_tool_root/"* ]] || return 1
        fi
    fi

    plist_output="$TMP_DIR/storage_app_plist.$$.$RANDOM.out"
    mdls_output="$TMP_DIR/storage_app_mdls.$$.$RANDOM.out"
    while IFS= read -r -d '' app_path; do
        [[ "$considered_apps" -lt "$maximum_apps" ]] || break
        [[ $((SECONDS - started_at)) -lt "$total_budget" ]] || break
        considered_apps=$((considered_apps + 1))
        [[ -d "$app_path" && ! -L "$app_path" ]] || continue
        [[ -d "$app_path/Contents" && ! -L "$app_path/Contents" ]] || continue
        info_plist="$app_path/Contents/Info.plist"
        # Reject FIFOs/devices, symlinks, hard-link aliases, surprising owners,
        # and oversized metadata. Re-read the identity immediately before the
        # bounded parser so a path swap during enumeration fails closed.
        plist_identity="$(_pch_storage_regular_identity "$info_plist")" || continue

        remaining_seconds=$((total_budget - (SECONDS - started_at)))
        [[ "$remaining_seconds" -gt 0 ]] || break
        [[ "$remaining_seconds" -le "$command_timeout" ]] \
            || remaining_seconds="$command_timeout"
        [[ "$(_pch_storage_regular_identity "$info_plist" 2>/dev/null || true)" \
            == "$plist_identity" ]] || continue
        if _pch_storage_tool_to_file "$plist_output" "$remaining_seconds" \
            "$plist_buddy" -c 'Print :CFBundleIdentifier' "$info_plist"; then
            bundle_id="$(/usr/bin/head -n 1 "$plist_output" 2>/dev/null)"
        else
            tool_status=$?
            bundle_id=""
            [[ "$tool_status" -ne 124 ]] || continue
        fi
        [[ "$bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ \
            && "${#bundle_id}" -le 255 ]] || continue
        [[ "$bundle_id" != "com.apple.Safari" ]] || continue

        remaining_seconds=$((total_budget - (SECONDS - started_at)))
        [[ "$remaining_seconds" -gt 0 ]] || break
        [[ "$remaining_seconds" -le "$command_timeout" ]] \
            || remaining_seconds="$command_timeout"
        if _pch_storage_tool_to_file "$mdls_output" "$remaining_seconds" \
            "$mdls_bin" -raw -name kMDItemFSSize "$app_path"; then
            app_bytes="$(/usr/bin/head -n 1 "$mdls_output" 2>/dev/null)"
        else
            app_bytes=""
        fi
        case "$app_bytes" in ''|*[!0-9]*) continue ;; esac
        [[ "${#app_bytes}" -le 20 ]] || continue
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
        if [[ -n "$application_test_root" ]]; then
            /usr/bin/find "$application_test_root" -mindepth 1 -maxdepth 2 \
                -type d -name '*.app' -prune -print0 2>/dev/null
        else
            /usr/bin/find /Applications -mindepth 1 -maxdepth 1 -type d -name '*.app' -print0 2>/dev/null
            /usr/bin/find "$HOME/Applications" -mindepth 1 -maxdepth 2 -type d -name '*.app' -prune -print0 2>/dev/null
        fi
    )
    /bin/rm -f "$plist_output" "$mdls_output" \
        "$plist_output.timeout" "$mdls_output.timeout" 2>/dev/null || true
}

_pch_storage_created_epoch() {
    local target_path="$1"
    local created_epoch="0"
    [[ -d "$target_path" && ! -L "$target_path" ]] || {
        /usr/bin/printf '0'
        return 0
    }
    if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
        created_epoch="$(/usr/bin/stat -f '%B' "$target_path" 2>/dev/null || true)"
    else
        created_epoch="$(/usr/bin/stat -c '%W' "$target_path" 2>/dev/null || true)"
    fi
    case "$created_epoch" in ''|*[!0-9]*|0) created_epoch=0 ;; esac
    /usr/bin/printf '%s' "$created_epoch"
}

_pch_collect_storage_simulators() {
    local simctl_devices="" simctl_status=0 simctl_collection_status="ok"
    local simctl_bin="/usr/bin/xcrun"
    local simctl_output="$TMP_DIR/storage_simctl.$$.$RANDOM.out"
    local simctl_timeout="${PCH_STORAGE_SIMCTL_TIMEOUT:-4}"
    local simctl_output_limit_kb="${PCH_STORAGE_SIMCTL_OUTPUT_LIMIT_KB:-1024}"
    case "$simctl_timeout" in ''|*[!0-9]*|0) simctl_timeout=4 ;; esac
    case "$simctl_output_limit_kb" in ''|*[!0-9]*|0) simctl_output_limit_kb=1024 ;; esac
    [[ "$simctl_timeout" -le 15 ]] || simctl_timeout=15
    [[ "$simctl_output_limit_kb" -le 4096 ]] || simctl_output_limit_kb=4096
    if [[ "${PCH_TEST_MODE:-}" == "1" && -n "${PCH_TEST_STORAGE_SIMCTL_LIST_FILE:-}" ]]; then
        simctl_devices="$(/usr/bin/head -c $((simctl_output_limit_kb * 1024)) \
            "$PCH_TEST_STORAGE_SIMCTL_LIST_FILE" 2>/dev/null || true)"
    else
        if [[ "${PCH_TEST_MODE:-}" == "1" \
            && -z "${PCH_TEST_STORAGE_SIMCTL_BIN:-}" ]] \
            && ! _pch_storage_host_inventory_allowed; then
            simctl_bin=""
        fi
        if [[ "${PCH_TEST_MODE:-}" == "1" && -n "${PCH_TEST_STORAGE_SIMCTL_BIN:-}" ]]; then
            simctl_bin="$(_pch_storage_test_tool "$PCH_TEST_STORAGE_SIMCTL_BIN")" \
                || simctl_bin=""
        fi
        if [[ -n "$simctl_bin" && -x "$simctl_bin" ]]; then
            local _pch_storage_tool_output_limit_kb="$simctl_output_limit_kb"
            local _pch_storage_tool_preserve_partial=1
            _pch_storage_tool_to_file "$simctl_output" "$simctl_timeout" \
                "$simctl_bin" simctl list devices available || simctl_status=$?
            simctl_devices="$(/bin/cat "$simctl_output" 2>/dev/null || true)"
        else
            simctl_status=127
        fi
    fi
    case "$simctl_status" in
        0) simctl_collection_status="ok" ;;
        124) simctl_collection_status="timed_out" ;;
        126|127) simctl_collection_status="unavailable" ;;
        *) simctl_collection_status="failed" ;;
    esac
    if [[ "$simctl_collection_status" == "ok" ]]; then
        record_collection_status "storage_simulators" "Simulator 장치" "ok" "false" \
            "사용 가능한 Simulator 장치를 확인했습니다."
    elif [[ -n "$simctl_devices" ]]; then
        record_collection_status "storage_simulators" "Simulator 장치" \
            "$simctl_collection_status" "false" \
            "Simulator 목록을 완전히 읽지 못했습니다. 제한 전까지의 일부 장치는 보존했습니다."
    else
        record_collection_status "storage_simulators" "Simulator 장치" \
            "$simctl_collection_status" "false" "Simulator 목록을 읽지 못했습니다."
    fi
    local runtime=""
    local device_name uuid state device_path created_epoch
    local device_size_kb device_measure_status sizes_status=0
    local sizes_output="$TMP_DIR/storage_simulator_sizes.$$.$RANDOM.out"
    local devices_root="$HOME/Library/Developer/CoreSimulator/Devices"
    local device_index aggregate_path aggregate_size_kb
    local device_limit="${PCH_STORAGE_SIMULATOR_DEVICE_LIMIT:-512}"
    local device_inventory_bounded=0
    local device_inventory_incomplete=0
    local -a device_names=()
    local -a device_uuids=()
    local -a device_runtimes=()
    local -a device_states=()
    local -a device_paths=()
    local -a device_created_epochs=()
    local -a all_device_paths=()
    case "$device_limit" in ''|*[!0-9]*|0) device_limit=512 ;; esac
    [[ "$device_limit" -le 2048 ]] || device_limit=2048

    if [[ -n "$simctl_devices" ]]; then
        while IFS= read -r line; do
            case "$line" in
                "-- "*)
                    runtime="${line#-- }"
                    runtime="${runtime% --}"
                    ;;
                *)
                    device_name="$(/usr/bin/sed -E 's/^[[:space:]]*//; s/[[:space:]]*\([0-9A-Fa-f-]{36}\)[[:space:]]*\([^)]*\).*//' <<< "$line")"
                    uuid="$(/usr/bin/sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/' <<< "$line")"
                    state="$(/usr/bin/sed -E 's/.*\([0-9A-Fa-f-]{36}\)[[:space:]]*\(([^)]*)\).*/\1/' <<< "$line")"
                    [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || continue
                    case "$device_name$runtime$state" in
                        *$'\t'*|*$'\n'*|*$'\r'*) continue ;;
                    esac
                    device_path="$HOME/Library/Developer/CoreSimulator/Devices/$uuid"
                    case "$device_path" in *$'\t'*|*$'\n'*|*$'\r'*) continue ;; esac
                    created_epoch="$(_pch_storage_created_epoch "$device_path")"
                    device_names+=("$device_name")
                    device_uuids+=("$uuid")
                    device_runtimes+=("$runtime")
                    device_states+=("$state")
                    device_paths+=("$device_path")
                    device_created_epochs+=("$created_epoch")
                    if [[ "$state" == "Booted" ]]; then
                        add_runtime_signal "booted_simulator" "$device_name" "1" "warning" "켜진 Simulator 확인" "${runtime} / ${uuid}"
                    fi
                    ;;
            esac
        done <<< "$simctl_devices"
    fi

    # The simctl list is metadata, not a complete disk inventory: unavailable
    # and orphaned UUID directories can remain on disk. Enumerate every direct,
    # real UUID directory for the aggregate, then enrich only simctl-listed
    # devices in the detail TSV below.
    if [[ -L "$devices_root" || ( -e "$devices_root" && ! -d "$devices_root" ) ]]; then
        device_inventory_incomplete=1
    elif [[ -d "$devices_root" ]]; then
        if ! /usr/bin/find "$devices_root" -mindepth 1 -maxdepth 1 -print -quit \
            >/dev/null 2>&1; then
            device_inventory_incomplete=1
        fi
        for device_path in "$devices_root"/*; do
            [[ -d "$device_path" && ! -L "$device_path" ]] || continue
            uuid="$(/usr/bin/basename "$device_path")"
            [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
                || continue
            if [[ "${#all_device_paths[@]}" -ge "$device_limit" ]]; then
                device_inventory_bounded=1
                break
            fi
            all_device_paths+=("$device_path")
        done
    fi

    : > "$sizes_output"
    if [[ "${#all_device_paths[@]}" -gt 0 ]]; then
        du_many_sizes_kb "$sizes_output" "${all_device_paths[@]}" || sizes_status=$?
    fi
    SIMULATOR_DEVICES_TOTAL_KB=0
    SIMULATOR_DEVICES_MEASURE_STATUS="ok"
    for aggregate_path in "${all_device_paths[@]+"${all_device_paths[@]}"}"; do
        aggregate_size_kb="$(/usr/bin/awk -F '\t' -v target="$aggregate_path" \
            '$2 == target && $1 ~ /^[0-9]+$/ { print $1; exit }' \
            "$sizes_output" 2>/dev/null)"
        if [[ "$aggregate_size_kb" =~ ^[0-9]+$ ]]; then
            SIMULATOR_DEVICES_TOTAL_KB=$((SIMULATOR_DEVICES_TOTAL_KB + aggregate_size_kb))
        else
            SIMULATOR_DEVICES_MEASURE_STATUS="timed_out"
        fi
    done
    if [[ "$sizes_status" -ne 0 || "$device_inventory_bounded" -eq 1 \
        || "$device_inventory_incomplete" -eq 1 ]]; then
        SIMULATOR_DEVICES_MEASURE_STATUS="timed_out"
    fi

    for ((device_index = 0; device_index < ${#device_uuids[@]}; device_index++)); do
        device_path="${device_paths[$device_index]}"
        device_size_kb=0
        device_measure_status="timed_out"
        if [[ -d "$device_path" && ! -L "$device_path" ]]; then
            device_measure_status="ok"
            device_size_kb="$(/usr/bin/awk -F '\t' -v target="$device_path" \
                '$2 == target && $1 ~ /^[0-9]+$/ { print $1; exit }' \
                "$sizes_output" 2>/dev/null)"
            if [[ -z "$device_size_kb" ]]; then
                device_size_kb=0
                device_measure_status="timed_out"
            fi
        fi
        if [[ "$device_inventory_incomplete" -eq 1 \
            || ( "$sizes_status" -ne 0 && "$sizes_status" -ne 124 ) ]]; then
            device_measure_status="timed_out"
        fi
        case "$device_size_kb" in ''|*[!0-9]*)
            device_size_kb=0
            device_measure_status="timed_out"
            ;;
        esac
        /usr/bin/printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "${device_names[$device_index]}" "${device_uuids[$device_index]}" \
            "${device_runtimes[$device_index]}" "${device_states[$device_index]}" \
            "$device_size_kb" "$device_measure_status" \
            "${device_created_epochs[$device_index]}" \
            >> "$TMP_DIR/storage_simulators.tsv"
    done
    /bin/rm -f "$sizes_output" 2>/dev/null || true
    /bin/rm -f "$simctl_output" 2>/dev/null || true
}

# 개발 프로젝트 내부의 재생성 가능한 빌드 산출물 행 1개를 기록한다.
# add_du_path와 같은 안전 규칙(절대경로, 제어문자 거부, 경로 dedup, du 예산)을 따르되
# 성공 측정 시에도 공식 재생성 명령 안내를 note로 싣는다. cleanup_id는 고정 ID인
# project_residue만 싣고 동적 경로는 별도 FD 요청서로 전달한다. cleanup.sh가 바로 위
# 프로젝트 표식·lockfile·Git index를 다시 검증하므로 경로 자체가 recipe ID가 되지 않는다.
_pch_add_project_residue_row() {
    local target_path="$1"
    local label="$2"
    local note="$3"
    local size_kb
    local measure_status="ok"
    local measure_note="$note"

    [[ -d "$target_path" && ! -L "$target_path" ]] || return 0
    [[ "$target_path" == /* ]] || return 0
    case "$label$target_path$note" in
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
    elif [[ "${DU_SIZE_MEASURE_STATUS:-ok}" != "ok" ]]; then
        measure_status="timed_out"
        measure_note="크기 측정 도구가 완료되지 않아 표시 값은 최소 확인량입니다. 정리 판단에는 사용하지 않습니다."
    fi
    case "$size_kb" in ''|*[!0-9]*) size_kb=0 ;; esac
    # 4MB 미만 잔여물은 노이즈만 만들므로 생략한다 (측정 보류 행은 정직하게 남긴다).
    [[ "$size_kb" -ge 4096 || "$measure_status" == "timed_out" ]] || return 0
    /usr/bin/printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "project_residue" "$label" "$target_path" "$size_kb" "$measure_status" "$measure_note" "project_residue" \
        >> "$TMP_DIR/storage_paths.tsv"
}

# 얕은 개발 루트 검색에서 Git 저장소 하나를 찾으면, 파일시스템 전체를 더 깊게
# 순회하지 않고 Git index에 등록된 Package.swift만 따라간다. 모노레포의 Swift
# package는 저장소 루트보다 훨씬 아래에 있을 수 있지만, 각 .build의 바로 위
# Package.swift를 기준으로 행을 만들면 cleanup.sh의 marker/parent 계약도 그대로
# 성립한다. Git 명령은 개별/전체 시간 예산 안에서만 실행하고,
# manifest 예산은 실제 .build 디렉터리가 있는 잔여물 후보만 소모한다.
_pch_project_git_budget_start() {
    [[ "$_pch_project_git_budget_started" -eq 0 ]] || return 0
    _pch_project_git_budget_started=1
    /bin/sleep "$_pch_project_git_total_budget" &
    _pch_project_git_budget_timer_pid=$!
}

_pch_project_git_budget_expired() {
    _pch_project_git_budget_start
    if [[ -z "$_pch_project_git_budget_timer_pid" ]] \
        || ! /bin/kill -0 "$_pch_project_git_budget_timer_pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

_pch_project_git_budget_stop() {
    [[ -n "$_pch_project_git_budget_timer_pid" ]] || return 0
    /bin/kill "$_pch_project_git_budget_timer_pid" 2>/dev/null || true
    wait "$_pch_project_git_budget_timer_pid" 2>/dev/null || true
    _pch_project_git_budget_timer_pid=""
}

_pch_project_git_trace() {
    local operation="$1"
    local status="$2"
    local waited_ticks="$3"
    [[ "${PCH_TEST_MODE:-}" == "1" ]] || return 0
    [[ -n "${PCH_TEST_PROJECT_GIT_TRACE_FILE:-}" ]] || return 0
    /usr/bin/printf '%s\t%s\t%s\n' \
        "$operation" "$status" "$waited_ticks" >> "$PCH_TEST_PROJECT_GIT_TRACE_FILE"
}

_pch_project_git_limit_nul_records() {
    local max_records="$1"
    local status_file="$2"
    local record=""
    local record_count=0

    while true; do
        record=""
        if ! IFS= read -r -d '' record; then
            if [[ -n "$record" ]]; then
                /usr/bin/printf 'output_limit' > "$status_file"
                return 65
            fi
            return 0
        fi
        record_count=$((record_count + 1))
        if [[ "$record_count" -gt "$max_records" ]]; then
            /usr/bin/printf 'record_limit' > "$status_file"
            return 64
        fi
        /usr/bin/printf '%s\0' "$record"
    done
}

_pch_project_git_kill_tree() {
    local root_pid="$1"
    local process_snapshot descendant_pids descendant_pid
    case "$root_pid" in ''|*[!0-9]*|0|1) return 0 ;; esac
    process_snapshot="$(_pch_storage_process_snapshot 2>/dev/null || true)"
    descendant_pids="$(/usr/bin/printf '%s\n' "$process_snapshot" | /usr/bin/awk -v root="$root_pid" '
        BEGIN { included[root] = 1 }
        {
            pids[NR] = $1
            parents[NR] = $2
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
            for (i = 1; i <= NR; i++) {
                if (pids[i] != root && included[pids[i]]) print pids[i]
            }
        }
    ')"
    while IFS= read -r descendant_pid; do
        case "$descendant_pid" in ''|*[!0-9]*|0|1) continue ;; esac
        /bin/kill -9 "$descendant_pid" 2>/dev/null || true
    done <<< "$descendant_pids"
    /bin/kill -9 "$root_pid" 2>/dev/null || true
}

_pch_project_discovery_to_file() {
    local scan_root="$1"
    local output_file="$2"
    local max_results="$3"
    local waited_ticks=0
    local timeout_ticks=$((_pch_project_discovery_timeout * 10))
    local command_pid command_status timeout_status="" limit_status=""
    local limit_status_file="$output_file.limit"
    local test_stall_seconds="${PCH_TEST_PROJECT_DISCOVERY_STALL_SECONDS:-}"

    : > "$output_file"
    : > "$limit_status_file"
    if _pch_project_git_budget_expired; then
        /bin/rm -f "$limit_status_file"
        _pch_project_git_timed_out=1
        return 1
    fi

    (
        if [[ "${PCH_TEST_MODE:-}" == "1" \
            && "$test_stall_seconds" =~ ^[1-9][0-9]*$ ]]; then
            exec /bin/sleep "$test_stall_seconds"
        fi
        set -o pipefail
        /usr/bin/find "$scan_root" -mindepth 1 -maxdepth 3 \
            \( -name .git \( -type d -o -type f \) -print0 -prune \) -o \
            \( -type d \( -name node_modules -o -name build -o -name .dart_tool \
                -o -name target -o -name Pods -o -name .build -o -name .gradle \
                -o -name Library -o -name "*.app" \) -prune \) -o \
            -type f \( -name pubspec.yaml -o -name package.json -o -name Cargo.toml \
                -o -name Package.swift -o -name Podfile -o -name gradlew \) -print0 2>/dev/null \
            | _pch_project_git_limit_nul_records "$max_results" "$limit_status_file"
    ) > "$output_file" 2>/dev/null &
    command_pid=$!

    while /bin/kill -0 "$command_pid" 2>/dev/null; do
        if _pch_project_git_budget_expired; then
            timeout_status="total_budget"
            break
        fi
        if [[ "$waited_ticks" -ge "$timeout_ticks" ]]; then
            timeout_status="command_timeout"
            break
        fi
        /bin/sleep 0.1
        waited_ticks=$((waited_ticks + 1))
    done

    if [[ -n "$timeout_status" ]]; then
        _pch_project_git_kill_tree "$command_pid"
        wait "$command_pid" 2>/dev/null || true
        /bin/rm -f "$limit_status_file"
        _pch_project_git_timed_out=1
        return 1
    fi

    if wait "$command_pid"; then
        command_status=0
    else
        command_status=$?
    fi
    limit_status="$(/bin/cat "$limit_status_file" 2>/dev/null || true)"
    /bin/rm -f "$limit_status_file"
    if [[ "$limit_status" == "record_limit" ]]; then
        _pch_project_git_timed_out=1
        return 1
    fi
    if [[ "$command_status" -ne 0 ]]; then
        _pch_project_git_incomplete=1
        return 1
    fi
    return 0
}

# macOS 기본 Bash 3.2에 timeout(1)이 없어도 절대 경로의 Git만 제한된
# 백그라운드 자식으로 실행한다. 개별 명령 제한과 모든 repo가 공유하는
# 전체 제한 중 먼저 다한 쪽에서 자식을 종료한다.
_pch_project_git_to_file() {
    local operation="$1"
    local output_file="$2"
    shift 2
    local waited_ticks=0
    local command_timeout_ticks=$((_pch_project_git_command_timeout * 10))
    local command_pid command_status timeout_status="" output_size_bytes=0 limit_status=""
    local test_stall_seconds="${PCH_TEST_PROJECT_GIT_STALL_SECONDS:-}"
    local output_limit_bytes=$((_pch_project_git_output_limit_kb * 1024))
    local limit_status_file="$output_file.limit"

    : > "$output_file"
    : > "$limit_status_file"
    _pch_project_git_last_status=""
    if _pch_project_git_budget_expired; then
        /bin/rm -f "$limit_status_file"
        _pch_project_git_timed_out=1
        _pch_project_git_last_status="total_budget"
        _pch_project_git_trace "$operation" "total_budget" "$waited_ticks"
        return 1
    fi

    # 테스트 모드에서만 실제로 종료해야 하는 sleep 자식으로 느린 Git을
    # 재현한다. 운영 경로는 항상 /usr/bin/git 절대 경로로 고정된다.
    # head로 stdout만 잘라 Git이 읽는 index나 기타 파일의 크기 제한은 바꾸지
    # 않는다. pipefail은 손상된 index의 Git 실패를 head 성공으로 숨기지 않는다.
    # checkout/user config의 core.fsmonitor는 실행 파일을 지정할 수 있으므로
    # 읽기 전용 스캔에서 강제로 끄고 optional index write도 금지한다.
    (
        if [[ "${PCH_TEST_MODE:-}" == "1" \
            && "${PCH_TEST_PROJECT_GIT_STALL_OPERATION:-}" == "$operation" \
            && "$test_stall_seconds" =~ ^[1-9][0-9]*$ ]]; then
            exec /bin/sleep "$test_stall_seconds"
        fi
        set -o pipefail
        if [[ "$operation" == "ls-files" ]]; then
            /usr/bin/git --no-optional-locks -c core.fsmonitor=false "$@" 2>/dev/null \
                | /usr/bin/head -c "$output_limit_bytes" \
                | _pch_project_git_limit_nul_records \
                    "$_pch_project_git_record_limit" "$limit_status_file"
        else
            /usr/bin/git --no-optional-locks -c core.fsmonitor=false "$@" 2>/dev/null \
                | /usr/bin/head -c "$output_limit_bytes"
        fi
    ) > "$output_file" 2>/dev/null &
    command_pid=$!

    while /bin/kill -0 "$command_pid" 2>/dev/null; do
        if _pch_project_git_budget_expired; then
            timeout_status="total_budget"
            break
        fi
        if [[ "$waited_ticks" -ge "$command_timeout_ticks" ]]; then
            timeout_status="command_timeout"
            break
        fi
        /bin/sleep 0.1
        waited_ticks=$((waited_ticks + 1))
    done

    if [[ -n "$timeout_status" ]]; then
        # 타임아웃 시점의 전체 자손 트리를 먼저 캡처해 종료한다.
        # 직계만 종료하면 Git이 띄운 외부 helper가 재부모화되어 남을 수 있다.
        _pch_project_git_kill_tree "$command_pid"
        wait "$command_pid" 2>/dev/null || true
        : > "$output_file"
        /bin/rm -f "$limit_status_file"
        _pch_project_git_timed_out=1
        _pch_project_git_last_status="$timeout_status"
        _pch_project_git_trace "$operation" "$timeout_status" "$waited_ticks"
        return 1
    fi

    if wait "$command_pid"; then
        command_status=0
    else
        command_status=$?
    fi
    output_size_bytes="$(/usr/bin/stat -f '%z' "$output_file" 2>/dev/null || /usr/bin/printf '0')"
    case "$output_size_bytes" in ''|*[!0-9]*) output_size_bytes=0 ;; esac
    limit_status="$(/bin/cat "$limit_status_file" 2>/dev/null || true)"
    /bin/rm -f "$limit_status_file"
    if [[ "$limit_status" == "record_limit" ]]; then
        : > "$output_file"
        _pch_project_git_last_status="record_limit"
        _pch_project_git_trace "$operation" "record_limit" "$waited_ticks"
        return 1
    fi
    # stdout이 상한과 정확히 같으면 Git이 pipe buffer에 모두 쓰고 0으로
    # 끝났더라도 뒷부분 존재를 구분할 수 없으므로 보수적으로 불완전 처리한다.
    if [[ "$limit_status" == "output_limit" \
        || "$output_size_bytes" -ge "$output_limit_bytes" ]]; then
        : > "$output_file"
        _pch_project_git_last_status="output_limit"
        _pch_project_git_trace "$operation" "output_limit" "$waited_ticks"
        return 1
    fi
    if [[ "$command_status" -ne 0 ]]; then
        : > "$output_file"
        _pch_project_git_last_status="failed"
        _pch_project_git_trace "$operation" "failed" "$waited_ticks"
        return 1
    fi
    _pch_project_git_last_status="ok"
    _pch_project_git_trace "$operation" "ok" "$waited_ticks"
    return 0
}

_pch_collect_git_swiftpm_residue() {
    local probe_dir="$1"
    local scan_root="$2"
    local max_repositories="$3"
    local max_manifests="$4"
    local repo_expected="${5:-false}"
    local repo_root canonical_repo manifest_rel manifest_path package_dir canonical_package_dir
    local package_name build_dir rev_parse_output ls_files_output

    [[ "$_pch_project_repository_count" -lt "$max_repositories" ]] || return 0
    [[ "$_pch_project_manifest_count" -lt "$max_manifests" ]] || return 0
    rev_parse_output="$TMP_DIR/project_git_rev_parse.$$.$RANDOM.out"
    if ! _pch_project_git_to_file \
        "rev-parse" "$rev_parse_output" -C "$probe_dir" rev-parse --show-toplevel; then
        if [[ "$repo_expected" == "true" \
            && ( "$_pch_project_git_last_status" == "failed" \
                || "$_pch_project_git_last_status" == "output_limit" \
                || "$_pch_project_git_last_status" == "record_limit" ) ]]; then
            _pch_project_git_incomplete=1
        fi
        /bin/rm -f "$rev_parse_output"
        return 0
    fi
    repo_root="$(/bin/cat "$rev_parse_output" 2>/dev/null || true)"
    /bin/rm -f "$rev_parse_output"
    if [[ "$repo_root" != /* || ! -d "$repo_root" || -L "$repo_root" ]]; then
        [[ "$repo_expected" != "true" ]] || _pch_project_git_incomplete=1
        return 0
    fi
    case "$repo_root" in
        *$'\t'*|*$'\n'*|*$'\r'*)
            [[ "$repo_expected" != "true" ]] || _pch_project_git_incomplete=1
            return 0
            ;;
    esac
    if ! canonical_repo="$(cd -P "$repo_root" 2>/dev/null && /bin/pwd -P)"; then
        [[ "$repo_expected" != "true" ]] || _pch_project_git_incomplete=1
        return 0
    fi
    if [[ "$canonical_repo" != "$repo_root" \
        || ( "$canonical_repo" != "$scan_root" && "$canonical_repo" != "$scan_root/"* ) ]]; then
        [[ "$repo_expected" != "true" ]] || _pch_project_git_incomplete=1
        return 0
    fi
    case "$_pch_project_seen_repositories" in
        *"|$canonical_repo|"*) return 0 ;;
    esac
    _pch_project_seen_repositories="${_pch_project_seen_repositories}${canonical_repo}|"
    _pch_project_repository_count=$((_pch_project_repository_count + 1))

    ls_files_output="$TMP_DIR/project_git_ls_files.$$.$RANDOM.out"
    if ! _pch_project_git_to_file \
        "ls-files" "$ls_files_output" -C "$canonical_repo" \
        ls-files -z -- Package.swift '*/Package.swift'; then
        if [[ "$_pch_project_git_last_status" == "failed" \
            || "$_pch_project_git_last_status" == "output_limit" \
            || "$_pch_project_git_last_status" == "record_limit" ]]; then
            _pch_project_git_incomplete=1
        fi
        /bin/rm -f "$ls_files_output"
        return 0
    fi
    while IFS= read -r -d '' manifest_rel; do
        [[ "$_pch_project_manifest_count" -lt "$max_manifests" ]] || break
        if _pch_project_git_budget_expired; then
            _pch_project_git_timed_out=1
            break
        fi
        case "$manifest_rel" in
            ''|/*|../*|*/../*|*$'\t'*|*$'\n'*|*$'\r'*) continue ;;
        esac
        [[ "${manifest_rel##*/}" == "Package.swift" ]] || continue
        manifest_path="$canonical_repo/$manifest_rel"
        [[ -f "$manifest_path" && ! -L "$manifest_path" ]] || continue
        package_dir="${manifest_path%/*}"
        [[ -d "$package_dir" && ! -L "$package_dir" ]] || continue
        canonical_package_dir="$(cd -P "$package_dir" 2>/dev/null && /bin/pwd -P)" || continue
        [[ "$canonical_package_dir" == "$package_dir" ]] || continue
        build_dir="$package_dir/.build"
        [[ -d "$build_dir" && ! -L "$build_dir" ]] || continue
        _pch_project_manifest_count=$((_pch_project_manifest_count + 1))
        package_name="$(/usr/bin/basename "$package_dir")"
        _pch_add_project_residue_row "$build_dir" \
            "SwiftPM 빌드 산출물 · $package_name" \
            "바로 위 Package.swift가 Git 저장소에 등록된 Swift package입니다. swift package clean 또는 .build 삭제로 재생성 가능합니다."
    done < "$ls_files_output"
    /bin/rm -f "$ls_files_output"
}

_pch_collect_project_residue() {
    # 개발 프로젝트가 자기 폴더 안에 쌓는 재생성 가능 산출물(Flutter build/,
    # node_modules, Cargo target/ 등)을 표면화한다. 이 항목들은 .gitignore가
    # 무시하고 macOS 저장공간 설정은 뭉뚱그리므로, 수 GB가 쌓여도 어떤 도구에도
    # 보이지 않는 사각지대가 된다. 검색은 흔한 개발 루트로 한정하고 깊이와
    # 개수를 제한해 빠른 검사 예산 안에 머문다.
    local scan_roots="${PCH_PROJECT_SCAN_ROOTS:-$HOME/Documents:$HOME/Developer:$HOME/Projects:$HOME/IdeaProjects:$HOME/StudioProjects:$HOME/dev:$HOME/workspace:$HOME/src}"
    local max_projects="${PCH_PROJECT_SCAN_LIMIT:-32}"
    local max_repositories="${PCH_PROJECT_GIT_SCAN_LIMIT:-128}"
    local max_manifests="${PCH_PROJECT_SWIFTPM_MANIFEST_LIMIT:-256}"
    local project_git_command_timeout="${PCH_PROJECT_GIT_COMMAND_TIMEOUT:-2}"
    local project_git_total_budget="${PCH_PROJECT_GIT_TOTAL_BUDGET:-8}"
    local project_git_output_limit_kb="${PCH_PROJECT_GIT_OUTPUT_LIMIT_KB:-4096}"
    local project_git_record_limit="${PCH_PROJECT_GIT_RECORD_LIMIT:-16384}"
    local project_discovery_timeout="${PCH_PROJECT_DISCOVERY_TIMEOUT:-2}"
    local project_discovery_result_limit="${PCH_PROJECT_DISCOVERY_RESULT_LIMIT:-400}"
    case "$max_projects" in ''|*[!0-9]*) max_projects=32 ;; esac
    case "$max_repositories" in ''|*[!0-9]*) max_repositories=128 ;; esac
    case "$max_manifests" in ''|*[!0-9]*) max_manifests=256 ;; esac
    case "$project_git_command_timeout" in ''|*[!0-9]*|0) project_git_command_timeout=2 ;; esac
    case "$project_git_total_budget" in ''|*[!0-9]*|0) project_git_total_budget=8 ;; esac
    case "$project_git_output_limit_kb" in ''|*[!0-9]*|0) project_git_output_limit_kb=4096 ;; esac
    case "$project_git_record_limit" in ''|*[!0-9]*|0) project_git_record_limit=16384 ;; esac
    case "$project_discovery_timeout" in ''|*[!0-9]*|0) project_discovery_timeout=2 ;; esac
    case "$project_discovery_result_limit" in ''|*[!0-9]*|0) project_discovery_result_limit=400 ;; esac
    [[ "$project_git_command_timeout" -le 30 ]] || project_git_command_timeout=30
    [[ "$project_git_total_budget" -le 60 ]] || project_git_total_budget=60
    [[ "$project_git_output_limit_kb" -le 16384 ]] || project_git_output_limit_kb=16384
    [[ "$project_git_record_limit" -le 65536 ]] || project_git_record_limit=65536
    [[ "$project_discovery_timeout" -le 30 ]] || project_discovery_timeout=30
    [[ "$project_discovery_result_limit" -le 2000 ]] || project_discovery_result_limit=2000
    local seen_projects="|"
    local found=0
    local root marker_file project_dir project_name preferred_project discovery_output
    local -a scan_root_list=()
    # Bash의 동적 local scope를 이용해 helper가 모든 scan root에 걸친 동일 예산과
    # dedup 상태를 갱신한다. 일반 marker 32개 제한과 분리해, 얕게 발견한 Git 저장소
    # 최대 128개/SwiftPM .build 잔여물 최대 256개까지만 확인한다.
    local _pch_project_seen_repositories="|"
    local _pch_project_repository_count=0
    local _pch_project_manifest_count=0
    local _pch_project_git_command_timeout="$project_git_command_timeout"
    local _pch_project_git_total_budget="$project_git_total_budget"
    local _pch_project_git_output_limit_kb="$project_git_output_limit_kb"
    local _pch_project_git_record_limit="$project_git_record_limit"
    local _pch_project_discovery_timeout="$project_discovery_timeout"
    local _pch_project_git_budget_started=0
    local _pch_project_git_budget_timer_pid=""
    local _pch_project_git_timed_out=0
    local _pch_project_git_incomplete=0
    local _pch_project_git_last_status=""

    if [[ "${PCH_TEST_MODE:-}" == "1" \
        && -z "${PCH_PROJECT_SCAN_ROOTS+x}" ]] \
        && ! _pch_storage_host_inventory_allowed; then
        scan_roots=""
    fi

    if [[ "${PCH_TEST_MODE:-}" == "1" \
        && -n "${PCH_TEST_PROJECT_GIT_TRACE_FILE:-}" ]]; then
        : > "$PCH_TEST_PROJECT_GIT_TRACE_FILE"
    fi

    # 소스 checkout에서 실행할 때는 scanner 자체의 저장소를 먼저 본다. 사용자의
    # IdeaProjects에 repo가 32개보다 많아도 Modore 모노레포가 뒤로 밀리지 않는다.
    # 앱 번들에서는 PROJECT_DIR가 Git 저장소가 아니므로 이 호출은 즉시 끝난다.
    preferred_project="${PCH_PROJECT_DIR:-${PROJECT_DIR:-}}"
    if [[ "${PCH_TEST_MODE:-}" == "1" \
        && -z "${PCH_PROJECT_DIR:-}" ]] \
        && ! _pch_storage_host_inventory_allowed; then
        preferred_project=""
    fi
    if [[ -n "$preferred_project" && -d "$preferred_project" && ! -L "$preferred_project" ]]; then
        _pch_collect_git_swiftpm_residue \
            "$preferred_project" "$preferred_project" "$max_repositories" "$max_manifests"
    fi

    IFS=':' read -r -a scan_root_list <<< "$scan_roots"
    for root in "${scan_root_list[@]}"; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        discovery_output="$TMP_DIR/project_discovery.$$.$RANDOM.out"
        _pch_project_discovery_to_file \
            "$root" "$discovery_output" "$project_discovery_result_limit" || true
        while IFS= read -r -d '' marker_file; do
            [[ -n "$marker_file" ]] || continue
            case "$marker_file" in *$'\t'*|*$'\n'*|*$'\r'*) continue ;; esac
            if [[ "$marker_file" == */.git ]]; then
                project_dir="${marker_file%/.git}"
                _pch_collect_git_swiftpm_residue \
                    "$project_dir" "$root" "$max_repositories" "$max_manifests" "true"
                continue
            fi
            project_dir="${marker_file%/*}"
            case "$seen_projects" in
                *"|$project_dir|"*) continue ;;
            esac
            [[ "$found" -lt "$max_projects" ]] || continue
            seen_projects="${seen_projects}${project_dir}|"
            found=$((found + 1))
            project_name="$(/usr/bin/basename "$project_dir")"
            case "$marker_file" in
                */pubspec.yaml)
                    _pch_add_project_residue_row "$project_dir/build" \
                        "Flutter 빌드 산출물 · $project_name" \
                        "프로젝트 폴더에서 flutter clean 으로 안전하게 비우고, 다음 빌드 때 재생성됩니다."
                    _pch_add_project_residue_row "$project_dir/.dart_tool" \
                        "Dart 도구 캐시 · $project_name" \
                        "flutter clean 이 함께 정리합니다. 소스가 아니라 재생성 가능한 캐시입니다."
                    ;;
                */package.json)
                    _pch_add_project_residue_row "$project_dir/node_modules" \
                        "node_modules · $project_name" \
                        "삭제해도 npm install(또는 pnpm/yarn install)로 재설치됩니다. lock 파일은 보존하세요."
                    ;;
                */Cargo.toml)
                    _pch_add_project_residue_row "$project_dir/target" \
                        "Rust 빌드 산출물 · $project_name" \
                        "cargo clean 으로 안전하게 비우고, 다음 빌드 때 재생성됩니다."
                    ;;
                */Package.swift)
                    _pch_add_project_residue_row "$project_dir/.build" \
                        "SwiftPM 빌드 산출물 · $project_name" \
                        "swift package clean 또는 .build 삭제로 재생성 가능합니다."
                    ;;
                */Podfile)
                    _pch_add_project_residue_row "$project_dir/Pods" \
                        "CocoaPods · $project_name" \
                        "pod install 로 재생성됩니다. Podfile.lock은 반드시 보존하세요."
                    ;;
                */gradlew)
                    _pch_add_project_residue_row "$project_dir/build" \
                        "Gradle 빌드 산출물 · $project_name" \
                        "./gradlew clean 으로 안전하게 비우고, 다음 빌드 때 재생성됩니다."
                    _pch_add_project_residue_row "$project_dir/.gradle" \
                        "Gradle 캐시 · $project_name" \
                        "재생성 가능한 프로젝트 로컬 Gradle 캐시입니다."
                    ;;
            esac
            _pch_collect_git_swiftpm_residue \
                "$project_dir" "$root" "$max_repositories" "$max_manifests"
        done < "$discovery_output"
        /bin/rm -f "$discovery_output"
    done

    _pch_project_git_budget_stop
    if [[ "$_pch_project_git_timed_out" -eq 1 \
        && "$_pch_project_git_incomplete" -eq 1 ]]; then
        record_collection_status "project_residue" "프로젝트 빌드 산출물" "timed_out" "false" \
            "일부 Git 저장소를 읽지 못했고, 시간·결과 예산 안에서 확인한 재생성 가능 산출물만 기록했습니다."
    elif [[ "$_pch_project_git_timed_out" -eq 1 ]]; then
        record_collection_status "project_residue" "프로젝트 빌드 산출물" "timed_out" "false" \
            "시간·결과 예산 안에서 확인한 재생성 가능 산출물만 기록했습니다."
    elif [[ "$_pch_project_git_incomplete" -eq 1 ]]; then
        record_collection_status "project_residue" "프로젝트 빌드 산출물" "failed" "false" \
            "손상되었거나 출력 상한을 넘긴 일부 Git 저장소를 읽지 못해 결과가 불완전합니다."
    else
        record_collection_status "project_residue" "프로젝트 빌드 산출물" "ok" "false" \
            "개발 프로젝트의 재생성 가능한 빌드 산출물을 확인했습니다."
    fi
}

# Surface exact, current-user-owned children of the two macOS temporary roots.
# Reporting only /private/tmp as one aggregate made the largest emergency
# recovery source unactionable: the owner could see gigabytes but not which
# tool-created workspace was responsible. Keep discovery shallow and bounded;
# cleanup.sh independently revalidates the exact child before approval and
# execution.
_pch_collect_transient_workspaces() {
    local root_list=""
    local user_temp=""
    local max_candidates="${PCH_TRANSIENT_WORKSPACE_LIMIT:-24}"
    local root canonical_root target basename owner _modified found=0
    local inventory_file="$TMP_DIR/storage_transient_candidates.tsv"
    local -a roots=()

    case "$max_candidates" in ''|*[!0-9]*|0) max_candidates=24 ;; esac
    [[ "$max_candidates" -le 64 ]] || max_candidates=64

    if [[ "${PCH_TEST_MODE:-}" == "1" ]]; then
        root_list="${PCH_TEST_STORAGE_TRANSIENT_ROOTS:-}"
        if [[ -z "$root_list" ]] && ! _pch_storage_host_inventory_allowed; then
            return 0
        fi
    else
        user_temp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
        root_list="/private/tmp"
        [[ -z "$user_temp" ]] || root_list="$root_list:$user_temp"
    fi

    : > "$inventory_file"
    IFS=':' read -r -a roots <<< "$root_list"
    for root in "${roots[@]}"; do
        [[ -n "$root" && -d "$root" && ! -L "$root" ]] || continue
        canonical_root="$(cd -P "$root" 2>/dev/null && /bin/pwd -P)" || continue
        [[ "$canonical_root" != "/" ]] || continue
        # One batched stat pass over the directory entries is dramatically
        # cheaper than starting du for thousands of stale test folders. Sort
        # by directory mtime so a workspace created by the current incident is
        # measured before historical residue can consume the shared deadline.
        if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
            /usr/bin/find "$canonical_root" -mindepth 1 -maxdepth 1 -type d \
                -uid "$(/usr/bin/id -u)" \
                -exec /usr/bin/stat -f $'%m\t%N' {} + \
                >> "$inventory_file" 2>/dev/null || true
        else
            # Linux is used by the source-contract CI suite. This branch is not
            # shipped as a Linux scanner; it keeps the deterministic collector
            # harness honest about the same mtime/path inventory contract.
            /usr/bin/find "$canonical_root" -mindepth 1 -maxdepth 1 -type d \
                -uid "$(/usr/bin/id -u)" \
                -printf '%T@\t%p\n' \
                >> "$inventory_file" 2>/dev/null || true
        fi
    done

    while IFS=$'\t' read -r _modified target; do
        [[ "$found" -lt "$max_candidates" ]] || break
        # Once the shared measurement deadline is gone, adding every remaining
        # directory as a zero-sized unknown turns a busy temp root into dozens
        # of unusable cleanup choices. Preserve the directory that actually
        # timed out, then stop before manufacturing more unknown rows.
        _pch_storage_du_budget_expired && break
        [[ "$_modified" =~ ^[0-9]+([.][0-9]+)?$ \
            && -d "$target" && ! -L "$target" ]] || continue
        if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
            owner="$(/usr/bin/stat -f '%u' "$target" 2>/dev/null || true)"
        else
            owner="$(/usr/bin/stat -c '%u' "$target" 2>/dev/null || true)"
        fi
        [[ "$owner" == "$(/usr/bin/id -u)" ]] || continue
        basename="$(/usr/bin/basename "$target")"
        [[ -n "$basename" && "$basename" != .* ]] || continue
        case "$target" in
            *$'\t'*|*$'\n'*|*$'\r'*) continue ;;
            */com.apple.*|*/com.google.Chrome.code_sign_clone) continue ;;
        esac
        if _pch_add_transient_workspace_row "$target" "$basename"; then
            found=$((found + 1))
        fi
    done < <(LC_ALL=C /usr/bin/sort -t $'\t' -k1,1nr "$inventory_file")
}

_pch_add_transient_workspace_row() {
    local target_path="$1"
    local workspace_name="$2"
    local size_kb measure_status="ok"
    local note="현재 사용자의 macOS 임시 루트 바로 아래에 있는 작업공간입니다. 정리 미리보기에서 소유권·경로·사용 중 여부를 다시 확인합니다."

    case "$seen" in
        *"|$target_path|"*) return 1 ;;
    esac
    seen="${seen}${target_path}|"
    du_size_kb "$target_path"
    size_kb="$DU_SIZE_RESULT"
    if [[ "$size_kb" == "__PCH_TIMEOUT__" ]]; then
        size_kb=0
        measure_status="timed_out"
        note="빠른 검사에서 크기 측정이 끝나지 않았습니다. 정리 미리보기에서 정확한 경로와 크기를 다시 확인합니다."
    elif [[ "${DU_SIZE_MEASURE_STATUS:-ok}" != "ok" ]]; then
        measure_status="timed_out"
        note="크기 측정이 불완전해 정리 판단에 사용하지 않습니다. 미리보기에서 다시 확인합니다."
    fi
    case "$size_kb" in ''|*[!0-9]*) size_kb=0 ;; esac
    # Tiny temporary directories churn constantly and would drown the recovery
    # list. Timed-out rows remain visible because their size is unknown.
    [[ "$size_kb" -ge 16384 || "$measure_status" == "timed_out" ]] || return 1
    /usr/bin/printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "transient_workspace" "임시 작업공간 · $workspace_name" "$target_path" \
        "$size_kb" "$measure_status" "$note" "transient_workspace" \
        >> "$TMP_DIR/storage_paths.tsv"
    return 0
}

_pch_collect_known_storage_paths() {
    # Simulator storage is both large and actionable, so reserve the shared du
    # budget before general caches. Device detail was measured in one traversal;
    # reuse its sum for the aggregate row instead of walking Devices twice.
    local simulator_devices_root="$HOME/Library/Developer/CoreSimulator/Devices"
    local simulator_devices_note=""
    local simulator_assets_root="/System/Volumes/Data/System/Library/AssetsV2"
    local simulator_core_root="/Library/Developer/CoreSimulator"
    if [[ "${PCH_TEST_MODE:-}" == "1" ]]; then
        simulator_assets_root="${PCH_TEST_STORAGE_SIMULATOR_ASSETS_ROOT:-}"
        simulator_core_root="${PCH_TEST_STORAGE_CORESIMULATOR_ROOT:-}"
        [[ -z "$simulator_assets_root" \
            || ( "$simulator_assets_root" == "$HOME/"* \
                && -d "$simulator_assets_root" && ! -L "$simulator_assets_root" ) ]] \
            || simulator_assets_root=""
        [[ -z "$simulator_core_root" \
            || ( "$simulator_core_root" == "$HOME/"* \
                && -d "$simulator_core_root" && ! -L "$simulator_core_root" ) ]] \
            || simulator_core_root=""
    fi
    if [[ "$SIMULATOR_DEVICES_MEASURE_STATUS" != "ok" ]]; then
        if [[ "$SIMULATOR_DEVICES_TOTAL_KB" -gt 0 ]]; then
            simulator_devices_note="측정이 완료되기 전에 확인된 기기만 더한 최소 확인량입니다. 실제 사용량은 더 클 수 있습니다."
        else
            simulator_devices_note="기기별 합계 측정이 완료되지 않아 사용량 판단을 보류했습니다."
        fi
    fi
    add_premeasured_path "simulator_devices" "Simulator 기기 데이터" \
        "$simulator_devices_root" "$SIMULATOR_DEVICES_TOTAL_KB" \
        "$SIMULATOR_DEVICES_MEASURE_STATUS" "$simulator_devices_note"
    if [[ -n "$simulator_assets_root" ]]; then
        add_du_path "simulator_runtime" "iOS Simulator 런타임" \
            "$simulator_assets_root/com_apple_MobileAsset_iOSSimulatorRuntime"
        add_du_path "simulator_runtime" "watchOS Simulator 런타임" \
            "$simulator_assets_root/com_apple_MobileAsset_watchOSSimulatorRuntime"
        add_du_path "simulator_runtime" "tvOS Simulator 런타임" \
            "$simulator_assets_root/com_apple_MobileAsset_appleTVOSSimulatorRuntime"
        add_du_path "simulator_runtime" "xrOS Simulator 런타임" \
            "$simulator_assets_root/com_apple_MobileAsset_xrOSSimulatorRuntime"
    fi
    if [[ -n "$simulator_core_root" ]]; then
        add_du_path "simulator_cache" "Simulator 공유 dyld 캐시" \
            "$simulator_core_root/Caches/dyld"
    fi

    # Chrome code-sign clone은 변동 폭이 크고 사용자가 가장 먼저 확인해야 하므로
    # 넓은 SDK/toolchain 측정보다 앞에서 시간 예산을 확보한다.
    local clone_dir
    if _pch_storage_host_inventory_allowed; then
        for clone_dir in /private/var/folders/*/*/X/com.google.Chrome.code_sign_clone /private/var/folders/*/*/T/com.google.Chrome.code_sign_clone; do
            [[ -d "$clone_dir" ]] || continue
            add_du_path "chrome_clone" "Chrome code-sign clones" "$clone_dir" "chrome_code_sign_clones"
        done
    fi

    # 일반 캐시/임시파일: 대부분 재생성 가능하지만 앱 로그아웃/재빌드 시간을 만들 수 있음.
    # 빠른 검사의 시간 예산을 아끼기 위해, 넓은 부모 캐시보다 판단 가치가 큰 하위 캐시를 먼저 잰다.
    add_du_path "cache" "npm cache" "$HOME/.npm" "npm_cache"
    add_du_path "cache" "pnpm store" "$HOME/Library/pnpm" "pnpm_store"
    add_du_path "cache" "Playwright browser cache" "$HOME/Library/Caches/ms-playwright" "playwright_browsers"
    add_du_path "cache" "Gradle cache" "$HOME/.gradle/caches" "gradle_cache"
    add_du_path "cache" "CocoaPods cache" "$HOME/Library/Caches/CocoaPods" "cocoapods_cache"
    add_du_path "cache" "Dart/Flutter pub cache" "$HOME/.pub-cache" "pub_cache"
    add_du_path "cache" "uv cache" "$HOME/.cache/uv" "uv_cache"
    add_du_path "cache" "Swift Package Manager cache" "$HOME/Library/Caches/org.swift.swiftpm" "swiftpm_cache"
    if _pch_storage_host_inventory_allowed; then
        add_du_path "cache" "Homebrew download cache" "$HOME/Library/Caches/Homebrew" "homebrew_cache"
    fi
    add_du_path "cache" "pip wheel cache" "$HOME/Library/Caches/pip" "pip_cache"

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
    add_du_path "protected_history" "Claude worktrees" "$HOME/.claude/worktrees"
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

    # Ollama: model blobs are reclaimable via `ollama pull`; the SSH keypair never is.
    add_du_path "ai_cache" "Ollama model blobs" "$HOME/.ollama/models" "ollama_models"
    add_du_path "protected_history" "Ollama SSH private key" "$HOME/.ollama/id_ed25519"
    add_du_path "protected_history" "Ollama SSH public key" "$HOME/.ollama/id_ed25519.pub"

    # Kiro (AWS IDE): session/workspace state is protected; editor caches are reclaimable.
    add_du_path "protected_history" "Kiro sessions" "$HOME/.kiro/sessions"
    add_du_path "protected_history" "Kiro workspace roots" "$HOME/.kiro/workspace-roots"
    add_du_path "protected_history" "Kiro settings" "$HOME/.kiro/settings"
    add_du_path "ai_cache" "Kiro logs" "$HOME/.kiro/logs"
    add_du_path "protected_history" "Kiro app workspace state" "$HOME/Library/Application Support/Kiro/User"
    add_du_path "protected_history" "Kiro WebStorage" "$HOME/Library/Application Support/Kiro/WebStorage"
    add_du_path "ai_cache" "Kiro app logs" "$HOME/Library/Application Support/Kiro/logs"
    add_du_path "ai_cache" "Kiro blob cache" "$HOME/Library/Application Support/Kiro/blob_storage"
    add_du_path "ai_cache" "Kiro cached extension data" "$HOME/Library/Application Support/Kiro/CachedData"
    add_du_path "ai_cache" "Kiro GPU cache" "$HOME/Library/Application Support/Kiro/GPUCache"
    add_du_path "ai_cache" "Kiro cached profile data" "$HOME/Library/Application Support/Kiro/CachedProfilesData"

    # VS Code: user workspace/settings state is protected; editor caches are reclaimable.
    add_du_path "protected_history" "VS Code workspace state" "$HOME/Library/Application Support/Code/User"
    add_du_path "ai_cache" "VS Code cached extension VSIX downloads" "$HOME/Library/Application Support/Code/CachedExtensionVSIXs"
    add_du_path "ai_cache" "VS Code cache" "$HOME/Library/Application Support/Code/Cache"
    add_du_path "ai_cache" "VS Code cached data" "$HOME/Library/Application Support/Code/CachedData"
    add_du_path "ai_cache" "VS Code GPU cache" "$HOME/Library/Application Support/Code/GPUCache"
    add_du_path "ai_cache" "VS Code cached profile data" "$HOME/Library/Application Support/Code/CachedProfilesData"

    # Gemini CLI: chat history and project registry are protected; scratch tmp is reclaimable.
    add_du_path "protected_history" "Gemini CLI history" "$HOME/.gemini/history"
    add_du_path "protected_history" "Gemini CLI project registry" "$HOME/.gemini/projects.json"
    add_du_path "protected_history" "Gemini CLI settings" "$HOME/.gemini/settings.json"
    add_du_path "protected_history" "Gemini CLI trusted folders" "$HOME/.gemini/trustedFolders.json"
    add_du_path "ai_cache" "Gemini CLI scratch cache" "$HOME/.gemini/tmp"

    add_du_path "cache" "User caches" "$HOME/Library/Caches"
    add_du_path "cache" "CLI/tool caches" "$HOME/.cache"
    if _pch_storage_host_inventory_allowed; then
        add_du_path "temp" "System temporary files" "/private/tmp"
    fi
    add_du_path "trash" "User Trash" "$HOME/.Trash"

    # Xcode / Apple 개발환경.
    add_du_path "build_cache" "Xcode DerivedData" "$HOME/Library/Developer/Xcode/DerivedData" "xcode_derived_data"
    add_du_path "archive" "Xcode Archives" "$HOME/Library/Developer/Xcode/Archives"
    # Android / cross-platform 모바일 개발환경.
    local sdk_candidates=()
    if _pch_storage_host_inventory_allowed; then
        sdk_candidates=(
            "${ANDROID_HOME:-}"
            "${ANDROID_SDK_ROOT:-}"
            "/opt/homebrew/share/android-commandlinetools"
            "$HOME/Library/Android/sdk"
        )
    fi
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
    local browser_analysis_bounded=0
    chrome_count="$(count_processes 'Google Chrome')"
    sim_count="$(count_processes '/CoreSimulator/Volumes/iOS_|launchd_sim|Simulator.app|CoreSimulatorBridge')"
    codex_count="$(count_processes 'Codex.app|/codex|node_repl|SkyComputerUseClient')"
    claude_count="$(count_processes 'Claude.app|/claude|claude-code')"
    node_count="$(count_processes '(^|/)(node|npm|npx)( |$)')"

    add_runtime_signal "process_count" "Chrome processes" "$chrome_count" "$([[ "$chrome_count" -ge 20 ]] && echo warning || echo info)" "브라우저 탭/자동화 정리" "Chrome 계열 프로세스가 많으면 code-sign clone과 프로필 캐시가 다시 쌓일 수 있습니다."
    local browser_pid browser_ppid browser_elapsed browser_channel browser_state browser_profile browser_controller browser_rss_kb browser_tree_memory_kb browser_tree_process_count
    local browser_label browser_risk browser_action browser_channel_note
    while IFS=$'\t' read -r browser_pid browser_ppid browser_elapsed browser_channel browser_state browser_profile browser_controller browser_rss_kb browser_tree_memory_kb browser_tree_process_count; do
        if [[ "$browser_pid" == "__PCH_BROWSER_BOUNDED__" ]]; then
            browser_analysis_bounded=1
            continue
        fi
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
    if [[ "${_pch_runtime_process_status:-ok}" != "ok" ]]; then
        record_collection_status "browser_automation" "브라우저 자동화 프로세스" \
            "${_pch_runtime_process_status}" "false" \
            "프로세스 표본을 완전히 읽지 못해 제한 전까지 확인한 브라우저 자동화만 기록했습니다."
    elif [[ "$browser_analysis_bounded" -eq 1 ]]; then
        record_collection_status "browser_automation" "브라우저 자동화 프로세스" \
            "timed_out" "false" "행·시간 상한 안에서 확인한 브라우저 자동화만 기록했습니다."
    else
        record_collection_status "browser_automation" "브라우저 자동화 프로세스" \
            "ok" "false" "실행 중인 브라우저 자동화 root를 확인했습니다."
    fi
    add_runtime_signal "process_count" "CoreSimulator processes" "$sim_count" "$([[ "$sim_count" -ge 100 ]] && echo warning || echo info)" "필요한 Simulator만 Booted" "부팅된 Simulator는 런타임 프로세스를 대량으로 띄웁니다."
    add_runtime_signal "process_count" "Codex processes" "$codex_count" "$([[ "$codex_count" -ge 20 ]] && echo warning || echo info)" "끝난 Codex 작업의 프로세스 종료" "세션 기록은 보존하고, 더 이상 사용하지 않는 Codex/Computer Use 프로세스만 앱에서 정상 종료하세요."
    add_runtime_signal "process_count" "Claude processes" "$claude_count" "$([[ "$claude_count" -ge 15 ]] && echo warning || echo info)" "끝난 Claude 작업의 프로세스 종료" "로컬 작업공간은 보존하고, 더 이상 사용하지 않는 Claude Desktop/Code 프로세스만 앱에서 정상 종료하세요."
    add_runtime_signal "process_count" "Node/npm/npx processes" "$node_count" "$([[ "$node_count" -ge 25 ]] && echo warning || echo info)" "개발 서버 종료" "여러 개발 서버와 MCP/브라우저 자동화 런타임이 동시에 떠 있을 수 있습니다."
}

collect_storage() {
    local df_target="/"
    local du_timeout="${PCH_STORAGE_DU_TIMEOUT:-8}"
    local du_budget="${PCH_STORAGE_TOTAL_DU_BUDGET:-32}"
    local simulator_du_timeout="${PCH_STORAGE_SIMULATOR_DU_TIMEOUT:-}"
    local du_bin="/usr/bin/du"
    local du_budget_ticks=0
    local du_budget_started=0
    local du_budget_timer_pid=""
    local du_test_clock_ticks=0
    local du_test_deadline_ticks=0
    local du_test_duration_ticks=""
    local du_test_size_kb="1"
    local du_test_trace_file=""
    local DU_SIZE_RESULT="0"
    local DU_SIZE_MEASURE_STATUS="ok"
    local SIMULATOR_DEVICES_TOTAL_KB=0
    local SIMULATOR_DEVICES_MEASURE_STATUS="timed_out"
    case "$du_timeout" in
        ''|*[!0-9]*) du_timeout=8 ;;
    esac
    case "$du_budget" in
        ''|*[!0-9]*) du_budget=32 ;;
    esac
    if [[ -z "$simulator_du_timeout" ]]; then
        if [[ "$du_timeout" -eq 0 ]]; then
            simulator_du_timeout=0
        else
            simulator_du_timeout=15
        fi
    else
        case "$simulator_du_timeout" in *[!0-9]*) simulator_du_timeout=15 ;; esac
    fi
    [[ "$simulator_du_timeout" -le 30 ]] || simulator_du_timeout=30
    if [[ "${PCH_TEST_MODE:-}" == "1" && -n "${PCH_TEST_STORAGE_DU_BIN:-}" ]]; then
        du_bin="$(_pch_storage_test_tool "$PCH_TEST_STORAGE_DU_BIN")" || return 1
    fi
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
    if [[ "${PCH_TEST_MODE:-}" == "1" ]] \
        && ! _pch_storage_host_inventory_allowed; then
        /usr/bin/printf '/dev/modore-test\t1048576\t524288\t524288\t50%%\t/\n' \
            > "$TMP_DIR/storage_df.txt"
    else
        if [[ -d "/System/Volumes/Data" ]]; then
            df_target="/System/Volumes/Data"
        fi
        /bin/df -Pk "$df_target" 2>/dev/null | /usr/bin/tail -n 1 \
            > "$TMP_DIR/storage_df.txt" || true
    fi
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
        local size_kb command_status=0
        local pid
        local this_timeout_ticks=$((du_timeout * 10))
        DU_SIZE_RESULT="0"
        DU_SIZE_MEASURE_STATUS="ok"

        if [[ "$du_timeout" -le 0 ]] 2>/dev/null; then
            "$du_bin" -sk "$target_path" > "$out_file" 2>/dev/null \
                || command_status=$?
            size_kb="$(/usr/bin/awk '{print $1; exit}' "$out_file" 2>/dev/null)"
            /bin/rm -f "$out_file"
            case "$size_kb" in ''|*[!0-9]*) size_kb=0; command_status=1 ;; esac
            DU_SIZE_RESULT="$size_kb"
            [[ "$command_status" -eq 0 ]] || DU_SIZE_MEASURE_STATUS="timed_out"
            return 0
        fi
        _pch_storage_du_budget_start
        if _pch_storage_du_budget_expired; then
            _pch_storage_trace_test_du "$target_path" "${du_test_duration_ticks:-0}" 0 "timed_out"
            DU_SIZE_RESULT="__PCH_TIMEOUT__"
            DU_SIZE_MEASURE_STATUS="timed_out"
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
                DU_SIZE_MEASURE_STATUS="timed_out"
            else
                DU_SIZE_RESULT="$du_test_size_kb"
            fi
            return 0
        fi

        "$du_bin" -sk "$target_path" > "$out_file" 2>/dev/null &
        pid=$!
        while /bin/kill -0 "$pid" 2>/dev/null; do
            if _pch_storage_du_budget_expired || [[ "$waited_ticks" -ge "$this_timeout_ticks" ]]; then
                /bin/kill -9 "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                /bin/rm -f "$out_file"
                DU_SIZE_RESULT="__PCH_TIMEOUT__"
                DU_SIZE_MEASURE_STATUS="timed_out"
                return 0
            fi
            /bin/sleep 0.1
            waited_ticks=$((waited_ticks + 1))
        done
        wait "$pid" 2>/dev/null || command_status=$?
        size_kb="$(/usr/bin/awk '{print $1; exit}' "$out_file" 2>/dev/null)"
        /bin/rm -f "$out_file"
        case "$size_kb" in ''|*[!0-9]*) size_kb=0; command_status=1 ;; esac
        DU_SIZE_RESULT="$size_kb"
        [[ "$command_status" -eq 0 ]] || DU_SIZE_MEASURE_STATUS="timed_out"
    }

    # Simulator device roots are siblings and can be numerous. One bounded du
    # process traverses all of them so the fixed per-item deadline is paid once,
    # while still retaining any complete rows emitted before a timeout.
    du_many_sizes_kb() {
        local output_file="$1"
        shift
        local waited_ticks=0 pid status=0 target_path
        local this_timeout_ticks=$((simulator_du_timeout * 10))
        : > "$output_file" || return 1
        [[ "$#" -gt 0 ]] || return 0

        if [[ "$simulator_du_timeout" -le 0 ]] 2>/dev/null; then
            "$du_bin" -sk -- "$@" > "$output_file" 2>/dev/null
            return $?
        fi
        _pch_storage_du_budget_start
        if _pch_storage_du_budget_expired; then
            for target_path in "$@"; do
                _pch_storage_trace_test_du "$target_path" "${du_test_duration_ticks:-0}" 0 "timed_out"
            done
            return 124
        fi

        if [[ -n "$du_test_duration_ticks" ]]; then
            local allowed_ticks="$du_test_duration_ticks"
            local remaining_budget_ticks
            local trace_consumed_ticks
            status=0
            if [[ "$this_timeout_ticks" -lt "$allowed_ticks" ]]; then
                allowed_ticks="$this_timeout_ticks"
                status=124
            fi
            if [[ "$du_budget" -gt 0 ]]; then
                remaining_budget_ticks=$((du_test_deadline_ticks - du_test_clock_ticks))
                if [[ "$remaining_budget_ticks" -lt "$allowed_ticks" ]]; then
                    allowed_ticks="$remaining_budget_ticks"
                    status=124
                fi
            fi
            du_test_clock_ticks=$((du_test_clock_ticks + allowed_ticks))
            trace_consumed_ticks="$allowed_ticks"
            for target_path in "$@"; do
                _pch_storage_trace_test_du "$target_path" "$du_test_duration_ticks" \
                    "$trace_consumed_ticks" "$([[ "$status" -eq 0 ]] && echo ok || echo timed_out)"
                trace_consumed_ticks=0
                if [[ "$status" -eq 0 ]]; then
                    /usr/bin/printf '%s\t%s\n' "$du_test_size_kb" "$target_path" \
                        >> "$output_file"
                fi
            done
            return "$status"
        fi

        "$du_bin" -sk -- "$@" > "$output_file" 2>/dev/null &
        pid=$!
        while /bin/kill -0 "$pid" 2>/dev/null; do
            if _pch_storage_du_budget_expired || [[ "$waited_ticks" -ge "$this_timeout_ticks" ]]; then
                /bin/kill -9 "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                return 124
            fi
            /bin/sleep 0.1
            waited_ticks=$((waited_ticks + 1))
        done
        wait "$pid" 2>/dev/null || status=$?
        return "$status"
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
        elif [[ "$DU_SIZE_MEASURE_STATUS" != "ok" ]]; then
            measure_status="timed_out"
            measure_note="크기 측정 도구가 완료되지 않아 표시 값은 최소 확인량입니다. 정리 판단에는 사용하지 않습니다."
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

    add_premeasured_path() {
        local kind="$1"
        local label="$2"
        local target_path="$3"
        local size_kb="$4"
        local measure_status="$5"
        local measure_note="${6:-}"
        local cleanup_id="${7:-}"

        [[ -e "$target_path" || -L "$target_path" ]] || return 0
        [[ "$target_path" == /* ]] || return 0
        case "$label$target_path$measure_note$cleanup_id" in
            *$'\t'*|*$'\n'*|*$'\r'*) return 0 ;;
        esac
        case "$size_kb" in ''|*[!0-9]*) return 0 ;; esac
        case "$measure_status" in ok|timed_out) ;; *) return 0 ;; esac
        case "$seen" in
            *"|$target_path|"*) return 0 ;;
        esac
        seen="${seen}${target_path}|"
        /usr/bin/printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$kind" "$label" "$target_path" "$size_kb" "$measure_status" \
            "$measure_note" "$cleanup_id" >> "$TMP_DIR/storage_paths.tsv"
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

    local ps_commands="" ps_detailed="" ps_status=0
    local ps_bin="/bin/ps"
    local ps_output="$TMP_DIR/storage_ps.$$.$RANDOM.out"
    local ps_timeout="${PCH_STORAGE_PS_TIMEOUT:-3}"
    local ps_output_limit_kb="${PCH_STORAGE_PS_OUTPUT_LIMIT_KB:-2048}"
    local _pch_runtime_process_status="ok"
    if [[ "${PCH_TEST_MODE:-}" == "1" \
        && -z "${PCH_TEST_STORAGE_PS_BIN:-}" ]] \
        && ! _pch_storage_host_inventory_allowed; then
        ps_bin=""
    fi
    case "$ps_timeout" in ''|*[!0-9]*|0) ps_timeout=3 ;; esac
    case "$ps_output_limit_kb" in ''|*[!0-9]*|0) ps_output_limit_kb=2048 ;; esac
    [[ "$ps_timeout" -le 10 ]] || ps_timeout=10
    [[ "$ps_output_limit_kb" -le 4096 ]] || ps_output_limit_kb=4096
    if [[ "${PCH_TEST_MODE:-}" == "1" && -n "${PCH_TEST_STORAGE_PS_BIN:-}" ]]; then
        ps_bin="$(_pch_storage_test_tool "$PCH_TEST_STORAGE_PS_BIN")" || ps_bin=""
    fi
    if [[ -n "$ps_bin" && -x "$ps_bin" ]]; then
        local _pch_storage_tool_output_limit_kb="$ps_output_limit_kb"
        local _pch_storage_tool_preserve_partial=1
        _pch_storage_tool_to_file "$ps_output" "$ps_timeout" \
            "$ps_bin" -axo pid=,ppid=,etime=,rss=,command= || ps_status=$?
        ps_detailed="$(/bin/cat "$ps_output" 2>/dev/null || true)"
        ps_commands="$ps_detailed"
    else
        ps_status=127
    fi
    case "$ps_status" in
        0) _pch_runtime_process_status="ok" ;;
        124) _pch_runtime_process_status="timed_out" ;;
        126|127) _pch_runtime_process_status="unavailable" ;;
        *) _pch_runtime_process_status="failed" ;;
    esac
    [[ -n "$ps_detailed" || "$_pch_runtime_process_status" != "ok" ]] \
        || _pch_runtime_process_status="failed"
    if [[ "$_pch_runtime_process_status" == "ok" && -n "$ps_detailed" ]]; then
        record_collection_status "runtime_processes" "개발 런타임 프로세스" "ok" "false" "실행 중인 개발 도구와 자동화 프로세스를 확인했습니다."
    elif [[ -n "$ps_detailed" ]]; then
        record_collection_status "runtime_processes" "개발 런타임 프로세스" \
            "$_pch_runtime_process_status" "false" \
            "프로세스 표본을 완전히 읽지 못했습니다. 제한 전까지의 일부 행은 진단 자료로 보존했습니다."
    else
        record_collection_status "runtime_processes" "개발 런타임 프로세스" \
            "$_pch_runtime_process_status" "false" "개발 런타임 프로세스를 읽지 못했습니다."
    fi
    /bin/rm -f "$ps_output" 2>/dev/null || true
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
    # Exact temporary workspaces and recovery-capable project artifacts get the
    # shared measurement budget before broad cache inventory. Recent temporary
    # workspaces come first because they are the common high-velocity source of
    # "I just freed space and it filled again" incidents.
    _pch_collect_transient_workspaces
    _pch_collect_project_residue
    _pch_collect_known_storage_paths
    _pch_collect_storage_access_checks
    _pch_collect_storage_runtime_signals

    # Status is field 5/7 (trailing tab) in storage_paths.tsv but the LAST field
    # in storage_simulators.tsv (line end, no trailing tab), so accept either.
    if /usr/bin/grep -Eq $'\ttimed_out(\t|$)' "$TMP_DIR/storage_paths.tsv" "$TMP_DIR/storage_simulators.tsv" 2>/dev/null; then
        record_collection_status "storage_inventory" "저장공간 경로 측정" "timed_out" "false" "일부 경로의 완전한 측정값을 확보하지 못했습니다."
    else
        record_collection_status "storage_inventory" "저장공간 경로 측정" "ok" "false" "알려진 저장공간 경로를 측정했습니다."
    fi
    _pch_storage_du_budget_stop
}
