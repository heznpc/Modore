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

collect_devtool_updates() {
    local out_file="$TMP_DIR/devtool_updates.txt"
    local error_file="$TMP_DIR/devtool_updates.err"
    local brew_bin="" candidate status row_count

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

    HOMEBREW_NO_AUTO_UPDATE=1 "$brew_bin" outdated --verbose \
        > "$out_file" 2> "$error_file"
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
        : > "$out_file"
        record_collection_status "devtool_updates" "개발도구 업데이트" "unavailable" "false" \
            "Homebrew 업데이트 상태를 확인하지 못했습니다."
    fi
    /bin/rm -f "$error_file"
}
