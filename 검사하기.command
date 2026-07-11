#!/bin/bash -p
# ============================================================
# PC 건강검진 - macOS 더블클릭 실행기
# Finder에서 더블클릭하면 터미널이 열리고 메뉴가 실행됩니다.
# ============================================================

set -u
set -o pipefail
umask 077
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset BASH_ENV ENV CDPATH GLOBIGNORE

cd "$(/usr/bin/dirname "$0")" || exit 1
cd -P . || exit 1

current_uid="$(/usr/bin/id -u)"
account_home="$(/usr/bin/dscacheutil -q user -a uid "$current_uid" 2>/dev/null \
    | /usr/bin/awk '$1 == "dir:" {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}')"
user_temp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
if [[ -z "$account_home" || "$account_home" != /* || ! -d "$account_home" || -L "$account_home" \
    || -z "$user_temp" || "$user_temp" != /* || ! -d "$user_temp" || -L "$user_temp" ]]; then
    /usr/bin/printf '  안전한 사용자 실행 환경을 확인하지 못했습니다.\n' >&2
    exit 1
fi
account_home="$(cd -P "$account_home" && /bin/pwd -P)" || exit 1
user_temp="$(cd -P "$user_temp" && /bin/pwd -P)" || exit 1
for trusted_directory in "$account_home" "$user_temp"; do
    owner_uid="$(/usr/bin/stat -f '%u' "$trusted_directory")"
    permissions="$(/usr/bin/stat -f '%Lp' "$trusted_directory")"
    if [[ "$owner_uid" != "$current_uid" || $((8#$permissions & 0022)) -ne 0 ]]; then
        /usr/bin/printf '  안전하지 않은 사용자 디렉터리 권한입니다: %s\n' "$trusted_directory" >&2
        exit 1
    fi
done
clean_environment=(
    "HOME=$account_home"
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
    "TMPDIR=$user_temp"
    "LANG=en_US.UTF-8"
    "LC_ALL=en_US.UTF-8"
)
run_clean() {
    /usr/bin/env -i "${clean_environment[@]}" "$@"
}

/usr/bin/clear
echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║                                              ║"
echo "  ║      🩺  PC 건강검진 Mac Edition  🩺          ║"
echo "  ║                                              ║"
echo "  ║   macOS가 숨긴 보안·저장공간 원인을          ║"
echo "  ║   삭제 없이 읽기 전용으로 풀어봅니다.         ║"
echo "  ║                                              ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""

# macOS 기본 osascript 확인
if [[ ! -x /usr/bin/osascript ]]; then
    echo "  ⚠️  macOS 기본 osascript를 찾을 수 없습니다."
    echo "      시스템 환경을 확인한 뒤 다시 실행해 주세요."
    echo ""
    read -r -p "  엔터를 누르면 종료합니다..." _
    exit 1
fi

while true; do
    echo "  무엇을 할까요?"
    echo ""
    echo "    [1] 빠른 검사 (Mac Edition)"
    echo "    [2] 이전 결과 다시 보기"
    echo "    [3] 공유용 결과 열기"
    echo "    [4] 종료"
    echo ""
    read -r -p "  선택: " choice

    case "$choice" in
        1)
            echo ""
            echo "  [빠른 검사] 시작합니다..."
            echo ""
            run_clean /bin/bash -p "$PWD/scripts/scanner.sh"
            scan_status=$?
            if [[ $scan_status -ne 0 ]]; then
                echo ""
                echo "  ❌ 검사 결과를 완성하지 못했습니다. 위 오류를 먼저 해결하세요."
                read -r -p "  아무 키나 누르면 메뉴로 돌아갑니다..." _
                /usr/bin/clear
                continue
            fi
            echo ""
            echo "  리포트 생성 중..."
            run_clean /usr/bin/env \
                "PCH_PROJECT_DIR=$PWD" \
                "PCH_REPORT_OUTPUT=$PWD/검사결과.html" \
                /usr/bin/osascript -l JavaScript "$PWD/scripts/report.jxa.js"
            report_status=$?
            if [[ $report_status -ne 0 ]]; then
                echo ""
                echo "  ❌ 리포트 생성에 실패했습니다."
                read -r -p "  아무 키나 누르면 메뉴로 돌아갑니다..." _
                /usr/bin/clear
                continue
            fi
            echo "  공유용 리포트 생성 중..."
            run_clean /usr/bin/env \
                "PCH_PROJECT_DIR=$PWD" \
                PCH_REDACT=true \
                "PCH_REPORT_OUTPUT=$PWD/검사결과_공유용.html" \
                /usr/bin/osascript -l JavaScript "$PWD/scripts/report.jxa.js"
            share_report_status=$?
            if [[ $share_report_status -ne 0 ]]; then
                echo "  ⚠️  공유용 리포트 생성은 실패했습니다. 일반 리포트는 사용할 수 있습니다."
            fi

            if [[ -f "./검사결과.html" ]]; then
                echo ""
                echo "  ✅ 완료! 브라우저에서 열립니다..."
                /usr/bin/open "$PWD/검사결과.html"
            fi
            if [[ -f "./검사결과_공유용.html" ]]; then
                echo "  공유할 때는 ./검사결과_공유용.html 파일을 사용하세요."
            fi
            echo ""
            read -r -p "  아무 키나 누르면 메뉴로 돌아갑니다..." _
            /usr/bin/clear
            ;;
        2)
            if [[ -f "./검사결과.html" ]]; then
                /usr/bin/open "$PWD/검사결과.html"
            else
                echo "  ❌ 이전 결과가 없습니다. 먼저 검사를 실행하세요."
                read -r -p "  엔터..." _
            fi
            /usr/bin/clear
            ;;
        3)
            if [[ -f "./검사결과_공유용.html" ]]; then
                /usr/bin/open "$PWD/검사결과_공유용.html"
            else
                echo "  ❌ 공유용 결과가 없습니다. 먼저 검사를 실행하세요."
                read -r -p "  엔터..." _
            fi
            /usr/bin/clear
            ;;
        4)
            echo "  종료합니다."
            exit 0
            ;;
        *)
            echo "  1, 2, 3, 4 중 하나를 입력하세요."
            /bin/sleep 1
            ;;
    esac
done
