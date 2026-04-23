#!/bin/bash
# ============================================================
# PC 건강검진 - macOS 더블클릭 실행기
# Finder에서 더블클릭하면 터미널이 열리고 메뉴가 실행됩니다.
# ============================================================

cd "$(dirname "$0")"

clear
echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║                                              ║"
echo "  ║         🩺  PC  건 강 검 진  🩺              ║"
echo "  ║                                              ║"
echo "  ║   내 Mac이 악성코드에 감염됐는지,            ║"
echo "  ║   몰래 채굴기로 쓰이는지 검사합니다.         ║"
echo "  ║                                              ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""

# Python 3 확인
if ! command -v python3 >/dev/null 2>&1; then
    echo "  ⚠️  Python 3가 필요합니다."
    echo "      설치: https://www.python.org/downloads/"
    echo "      또는: brew install python"
    echo ""
    read -p "  엔터를 누르면 종료합니다..." _
    exit 1
fi

while true; do
    echo "  무엇을 할까요?"
    echo ""
    echo "    [1] 빠른 검사 (1분)"
    echo "    [2] 이전 결과 다시 보기"
    echo "    [3] 종료"
    echo ""
    read -p "  선택: " choice

    case "$choice" in
        1)
            echo ""
            echo "  [빠른 검사] 시작합니다..."
            echo ""
            bash "./scripts/scanner.sh"
            echo ""
            echo "  리포트 생성 중..."
            python3 "./scripts/report.py"

            if [[ -f "./검사결과.html" ]]; then
                echo ""
                echo "  ✅ 완료! 브라우저에서 열립니다..."
                open "./검사결과.html"
            fi
            echo ""
            read -p "  아무 키나 누르면 메뉴로 돌아갑니다..." _
            clear
            ;;
        2)
            if [[ -f "./검사결과.html" ]]; then
                open "./검사결과.html"
            else
                echo "  ❌ 이전 결과가 없습니다. 먼저 검사를 실행하세요."
                read -p "  엔터..." _
            fi
            clear
            ;;
        3)
            echo "  종료합니다."
            exit 0
            ;;
        *)
            echo "  1, 2, 3 중 하나를 입력하세요."
            sleep 1
            ;;
    esac
done
