# ============================================================
# PC 건강검진 - 메인 메뉴
# 역할: 컴맹도 쉽게 쓸 수 있는 대화형 메뉴
# ============================================================

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
chcp 65001 | Out-Null
$Host.UI.RawUI.WindowTitle = "PC 건강검진"

function Find-Python {
    # Windows에서 Python 실행 파일 탐색: py > python3 > python
    foreach ($cmd in @('py', 'python3', 'python')) {
        $p = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($p) { return $p.Source }
    }
    return $null
}

function Invoke-ReportPy {
    $py = Find-Python
    if (-not $py) {
        Write-Host ""
        Write-Host "  ❌ Python 3가 설치되어 있지 않습니다." -ForegroundColor Red
        Write-Host "     설치: https://www.python.org/downloads/" -ForegroundColor Yellow
        Write-Host "     설치 시 'Add Python to PATH' 체크박스를 꼭 켜세요." -ForegroundColor Yellow
        return
    }
    & $py "$PSScriptRoot\report.py"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ⚠️  리포트 생성 중 문제가 발생했습니다." -ForegroundColor Yellow
    }
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                                              ║" -ForegroundColor Cyan
    Write-Host "  ║         🩺  PC  건 강 검 진  🩺              ║" -ForegroundColor Cyan
    Write-Host "  ║                                              ║" -ForegroundColor Cyan
    Write-Host "  ║   내 컴퓨터가 악성코드에 감염됐는지,         ║" -ForegroundColor Cyan
    Write-Host "  ║   몰래 채굴기로 쓰이는지 검사합니다.         ║" -ForegroundColor Cyan
    Write-Host "  ║                                              ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    Show-Banner
    Write-Host "  무엇을 할까요?" -ForegroundColor White
    Write-Host ""
    Write-Host "    [1] 빠른 검사 (1분)  - 기본 상태만 빠르게" -ForegroundColor Green
    Write-Host "    [2] 정밀 검사 (6분)  - 5분 관찰까지 포함 (추천)" -ForegroundColor Yellow
    Write-Host "    [3] 이전 결과 열기   - 마지막 리포트를 다시 봄" -ForegroundColor Gray
    Write-Host "    [4] 종료" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  선택: " -ForegroundColor White -NoNewline
    $choice = Read-Host
    return $choice
}

function Run-QuickScan {
    Show-Banner
    Write-Host "  [빠른 검사] 시작합니다..." -ForegroundColor Green
    Write-Host ""

    & "$PSScriptRoot\scanner.ps1"

    Write-Host ""
    Write-Host "  리포트를 생성합니다..." -ForegroundColor Cyan
    Invoke-ReportPy

    Open-Report
}

function Run-FullScan {
    Show-Banner
    Write-Host "  [정밀 검사] 시작합니다..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  이 검사는 약 6분 걸립니다:" -ForegroundColor White
    Write-Host "    1) 기본 검사 (약 1분)" -ForegroundColor Gray
    Write-Host "    2) 5분간 가만히 관찰 ← 이 동안 PC를 만지지 마세요" -ForegroundColor Gray
    Write-Host "    3) HTML 리포트 생성" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  ⚠️  관찰 동안 유튜브/게임을 끄고 조용히 기다리세요." -ForegroundColor Yellow
    Write-Host "     그래야 '진짜 CPU 범인'을 잡을 수 있습니다." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  준비되셨으면 Enter를 누르세요 (취소는 Ctrl+C)..." -NoNewline
    Read-Host | Out-Null

    Write-Host ""
    Write-Host "  [1/3] 기본 검사 실행..." -ForegroundColor Cyan
    & "$PSScriptRoot\scanner.ps1"

    Write-Host ""
    Write-Host "  [2/3] 5분 유휴 관찰 시작 (Ctrl+C로 취소 가능)..." -ForegroundColor Cyan
    & "$PSScriptRoot\monitor.ps1"

    Write-Host ""
    Write-Host "  [3/3] HTML 리포트 생성..." -ForegroundColor Cyan
    Invoke-ReportPy

    Open-Report
}

function Open-Report {
    $htmlPath = Join-Path $root '검사결과.html'
    if (Test-Path $htmlPath) {
        Write-Host ""
        Write-Host "  ✅ 완료! 브라우저에서 결과를 엽니다..." -ForegroundColor Green
        Start-Process $htmlPath
        Write-Host ""
        Write-Host "  리포트 위치: $htmlPath" -ForegroundColor Gray
    } else {
        Write-Host "  ❌ 리포트 파일을 찾을 수 없습니다." -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  아무 키나 누르면 메뉴로 돌아갑니다..." -ForegroundColor Gray
    [void][System.Console]::ReadKey($true)
}

# ---------- 메인 루프 ----------
while ($true) {
    $choice = Show-Menu
    switch ($choice) {
        '1' { Run-QuickScan }
        '2' { Run-FullScan }
        '3' { Open-Report }
        '4' { Write-Host ""; Write-Host "  종료합니다. 안녕히 가세요!" -ForegroundColor Cyan; exit 0 }
        default {
            Write-Host "  1, 2, 3, 4 중 하나를 입력하세요." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}
