#!/bin/bash
# ============================================================
# PC 건강검진 - macOS 더블클릭 실행기
# Finder에서 더블클릭하면 터미널이 열리고 메뉴가 실행됩니다.
# ============================================================

cd "$(dirname "$0")" || exit 1

clear
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
if ! command -v osascript >/dev/null 2>&1; then
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
            bash "./scripts/scanner.sh"
            scan_status=$?
            if [[ $scan_status -ne 0 ]]; then
                echo ""
                echo "  ❌ 검사 결과를 완성하지 못했습니다. 위 오류를 먼저 해결하세요."
                read -r -p "  아무 키나 누르면 메뉴로 돌아갑니다..." _
                clear
                continue
            fi
            echo ""
            echo "  리포트 생성 중..."
            PCH_PROJECT_DIR="$PWD" PCH_REPORT_OUTPUT="$PWD/검사결과.html" osascript -l JavaScript "./scripts/report.jxa.js"
            report_status=$?
            if [[ $report_status -ne 0 ]]; then
                echo ""
                echo "  ❌ 리포트 생성에 실패했습니다."
                read -r -p "  아무 키나 누르면 메뉴로 돌아갑니다..." _
                clear
                continue
            fi
            echo "  공유용 리포트 생성 중..."
            PCH_PROJECT_DIR="$PWD" PCH_REDACT=true PCH_REPORT_OUTPUT="$PWD/검사결과_공유용.html" osascript -l JavaScript "./scripts/report.jxa.js"
            share_report_status=$?
            if [[ $share_report_status -ne 0 ]]; then
                echo "  ⚠️  공유용 리포트 생성은 실패했습니다. 일반 리포트는 사용할 수 있습니다."
            fi

            if [[ -f "./검사결과.html" ]]; then
                echo ""
                echo "  ✅ 완료! 브라우저에서 열립니다..."
                open "./검사결과.html"
            fi
            if [[ -f "./검사결과_공유용.html" ]]; then
                echo "  공유할 때는 ./검사결과_공유용.html 파일을 사용하세요."
            fi
            echo ""
            read -r -p "  아무 키나 누르면 메뉴로 돌아갑니다..." _
            clear
            ;;
        2)
            if [[ -f "./검사결과.html" ]]; then
                open "./검사결과.html"
            else
                echo "  ❌ 이전 결과가 없습니다. 먼저 검사를 실행하세요."
                read -r -p "  엔터..." _
            fi
            clear
            ;;
        3)
            if [[ -f "./검사결과_공유용.html" ]]; then
                open "./검사결과_공유용.html"
            else
                echo "  ❌ 공유용 결과가 없습니다. 먼저 검사를 실행하세요."
                read -r -p "  엔터..." _
            fi
            clear
            ;;
        4)
            echo "  종료합니다."
            exit 0
            ;;
        *)
            echo "  1, 2, 3, 4 중 하나를 입력하세요."
            sleep 1
            ;;
    esac
done
