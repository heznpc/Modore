#!/bin/bash
# scanner 모듈 (macOS): 개발도구 업데이트 상태 조회 (읽기 전용)
# 출력: $TMP_DIR/devtool_updates.txt (brew outdated --verbose 원본 형식,
# 탭 구분이 아니라서 .tsv가 아닌 .txt)
# 의존: brew (선택 -- 없으면 unavailable)
#
# 실행관리(업데이트 실행)는 범위 밖이다. 상태 조회만 한다.
#
# Xcode와 mise는 이번 범위에서 뺐다: Xcode는 로컬 정보만으로 최신 버전을 알
# 방법이 없어 App Store나 developer.apple.com에 실제로 접속해야 하고,
# mise outdated는 오프라인 전용 플래그가 문서화되어 있지 않아 이 머신에서
# 네트워크 호출 여부를 확실히 검증하지 못했다(실측 2.7초로 brew의
# 로컬 전용 실행(0.4~0.6초)보다 뚜렷이 느렸다).
#
# brew outdated는 기본값이 자동 업데이트다 -- 이 머신에서 직접 확인
# (New Formulae/New Casks 목록이 실제로 갱신됨, ~5초 소요). VirusTotal
# 조회처럼 이 검사도 사용자 동의 없이 네트워크를 쓰지 않는다는 원칙을
# 지키기 위해 HOMEBREW_NO_AUTO_UPDATE=1로 그 네트워크 호출 자체를 막는다.
# 결과는 로컬 tap 캐시 기준이라 사용자가 최근에 `brew update`를 안 돌렸으면
# 오래된 정보일 수 있다 -- 이것은 조용히 숨기지 않고 그대로 드러나는
# 정직한 한계다.

if ! declare -F record_collection_status >/dev/null 2>&1; then
    record_collection_status() { :; }
fi

_pch_devtool_to_file() (
    local output_file="$1"
    local error_file="$2"
    shift 2
    local timeout_ticks="${PCH_DEVTOOL_COMMAND_TIMEOUT_TICKS:-80}"
    local output_limit_kb="${PCH_DEVTOOL_OUTPUT_LIMIT_KB:-256}"
    local output_limit_blocks output_limit_bytes output_size
    local command_pid="" ticks=0 command_status=0
    local status_marker="${output_file}.status.$$.$RANDOM"
    # shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
    cleanup_devtool() {
        local cleanup_pid="${command_pid:-}"
        trap - HUP INT TERM EXIT
        command_pid=""
        if [[ -n "$cleanup_pid" ]]; then
            /bin/kill -TERM -- "-$cleanup_pid" 2>/dev/null || true
            /bin/sleep 0.2
            /bin/kill -KILL -- "-$cleanup_pid" 2>/dev/null || true
            wait "$cleanup_pid" 2>/dev/null || true
        fi
        /bin/rm -f "$status_marker" 2>/dev/null || true
    }
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap cleanup_devtool EXIT
    case "$timeout_ticks" in ''|*[!0-9]*|0) timeout_ticks=80 ;; esac
    case "$output_limit_kb" in ''|*[!0-9]*|0) output_limit_kb=256 ;; esac
    [[ "$timeout_ticks" -le 300 ]] || timeout_ticks=300
    [[ "$output_limit_kb" -le 1024 ]] || output_limit_kb=1024
    output_limit_blocks="$output_limit_kb"
    output_limit_bytes=$((output_limit_kb * 1024))
    : > "$output_file" || return 1
    : > "$error_file" || return 1
    /bin/rm -f "$status_marker" 2>/dev/null || return 1
    exec 2>/dev/null
    set -m
    (
        ulimit -f "$output_limit_blocks" || exit 1
        "$@"
        provider_status=$?
        /usr/bin/printf '%s' "$provider_status" > "$status_marker" 2>/dev/null || true
        exit "$provider_status"
    ) > "$output_file" 2> "$error_file" &
    command_pid=$!
    while [[ ! -f "$status_marker" ]]; do
        if [[ "$ticks" -ge "$timeout_ticks" ]]; then
            /bin/kill -TERM -- "-$command_pid" 2>/dev/null || true
            /bin/sleep 0.2
            /bin/kill -KILL -- "-$command_pid" 2>/dev/null || true
            wait "$command_pid" 2>/dev/null || true
            command_pid=""
            /bin/rm -f "$status_marker" 2>/dev/null || true
            return 124
        fi
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    command_status="$(/bin/cat "$status_marker" 2>/dev/null || true)"
    case "$command_status" in ''|*[!0-9]*) command_status=1 ;; esac
    wait "$command_pid" 2>/dev/null || true
    if /bin/kill -0 -- "-$command_pid" 2>/dev/null; then
        /bin/kill -TERM -- "-$command_pid" 2>/dev/null || true
        /bin/sleep 0.2
        /bin/kill -KILL -- "-$command_pid" 2>/dev/null || true
    fi
    command_pid=""
    /bin/rm -f "$status_marker" 2>/dev/null || true
    output_size="$(/usr/bin/wc -c < "$output_file" 2>/dev/null | /usr/bin/tr -d ' ')"
    case "$output_size" in ''|*[!0-9]*) output_size=0 ;; esac
    [[ "$output_size" -lt "$output_limit_bytes" ]] || return 65
    return "$command_status"
)

collect_devtool_updates() {
    local out_file="$TMP_DIR/devtool_updates.txt"
    local error_file="$TMP_DIR/devtool_updates.err"
    local brew_bin="" candidate status row_count collection_status detail

    : > "$out_file"
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$candidate" ]]; then
            brew_bin="$candidate"
            break
        fi
    done
    if [[ "${PCH_TEST_MODE:-0}" == "1" && -n "${PCH_TEST_BREW_BIN:-}" ]]; then
        brew_bin="$PCH_TEST_BREW_BIN"
    fi

    if [[ -z "$brew_bin" ]]; then
        record_collection_status "devtool_updates" "개발도구 업데이트" "unavailable" "false" \
            "Homebrew가 설치되어 있지 않습니다."
        return 0
    fi

    HOMEBREW_NO_AUTO_UPDATE=1 _pch_devtool_to_file "$out_file" "$error_file" \
        "$brew_bin" outdated --verbose
    status=$?
    if [[ "$status" -eq 0 ]]; then
        row_count="$(/usr/bin/wc -l < "$out_file" | /usr/bin/tr -d ' ')"
        if [[ "$row_count" -eq 0 ]]; then
            record_collection_status "devtool_updates" "개발도구 업데이트" "ok" "false" \
                "Homebrew로 설치한 패키지가 모두 최신입니다(로컬 캐시 기준)."
        else
            record_collection_status "devtool_updates" "개발도구 업데이트" "ok" "false" \
                "Homebrew 패키지 ${row_count}개에 업데이트가 있습니다(로컬 캐시 기준, 네트워크 조회 없음)."
        fi
    else
        case "$status" in
            124) collection_status="timed_out" ;;
            126|127) collection_status="unavailable" ;;
            *) collection_status="failed" ;;
        esac
        if [[ -s "$out_file" ]]; then
            detail="Homebrew 업데이트 상태를 완전히 읽지 못했습니다. 제한 전까지의 일부 출력은 진단 자료로 보존했습니다."
        else
            detail="Homebrew 업데이트 상태를 확인하지 못했습니다."
        fi
        record_collection_status "devtool_updates" "개발도구 업데이트" "$collection_status" "false" \
            "$detail"
    fi
    /bin/rm -f "$error_file"
}
