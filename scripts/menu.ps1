# ============================================================
# Modore - 메인 메뉴
# 역할: 컴맹도 쉽게 쓸 수 있는 대화형 메뉴
# ============================================================

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
chcp 65001 | Out-Null
$Host.UI.RawUI.WindowTitle = "Modore"

# $LASTEXITCODE only reflects native executable calls, not a called .ps1's
# own success/failure -- and scanner.ps1 sets its own $ErrorActionPreference
# to SilentlyContinue, under which an *uncaught* `throw` is silently
# swallowed rather than terminating (confirmed directly: a throw under that
# preference lets execution continue to the next line with $? still true).
# Neither $LASTEXITCODE nor $? can be trusted alone here. The one signal
# that can't lie is whether scan_result.json was actually written fresh by
# *this* run -- so that's what gates whether a report gets generated from it.
function Invoke-Scanner {
    $outputPath = Join-Path $root 'scan_result.json'
    $before = if (Test-Path $outputPath) { (Get-Item $outputPath).LastWriteTimeUtc } else { $null }

    & "$PSScriptRoot\scanner.ps1"
    $scannerOk = $?

    if (-not (Test-Path $outputPath)) {
        return $false
    }
    $after = (Get-Item $outputPath).LastWriteTimeUtc
    $isFresh = ($null -eq $before) -or ($after -gt $before)

    return $scannerOk -and $isFresh
}

function Get-LastRunId {
    $outputPath = Join-Path $root 'scan_result.json'
    if (-not (Test-Path $outputPath)) { return $null }
    return [string](Get-Content $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json).runId
}

# 5분 관측은 Ctrl+C로 취소 가능하다고 안내하는 정상 지원 경로다 -- 취소되면
# monitor.ps1이 자기 저장 단계까지 가지 못해 scan_result.json이 그대로 남는다.
# Invoke-Scanner와 같은 신선도 검사를 그대로 재사용: monitor.ps1이 끝난 뒤
# scan_result.json이 실제로 다시 쓰였는지만 본다 ($?는 SilentlyContinue 아래
# 보조 신호일 뿐, 유일한 판단 근거로 쓰지 않는다).
function Invoke-Monitor {
    param([Parameter(Mandatory)][string]$RunId)
    $outputPath = Join-Path $root 'scan_result.json'
    $before = if (Test-Path $outputPath) { (Get-Item $outputPath).LastWriteTimeUtc } else { $null }

    & "$PSScriptRoot\monitor.ps1" -RunId $RunId
    $monitorOk = $?

    if (-not (Test-Path $outputPath)) {
        return $false
    }
    $after = (Get-Item $outputPath).LastWriteTimeUtc
    $isFresh = ($null -eq $before) -or ($after -gt $before)

    return $monitorOk -and $isFresh
}

function Invoke-Report {
    & "$PSScriptRoot\report.ps1"
    $reportOk = $?
    if (-not $reportOk) {
        Write-Host "  ⚠️  리포트 생성 중 문제가 발생했습니다." -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Wait-MenuReturn {
    Write-Host ""
    Write-Host "  아무 키나 누르면 메뉴로 돌아갑니다..." -ForegroundColor Gray
    [void][System.Console]::ReadKey($true)
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

    if (-not (Invoke-Scanner)) {
        Write-Host ""
        Write-Host "  ❌ 검사 결과를 완성하지 못했습니다. 위 오류를 먼저 해결하세요." -ForegroundColor Red
        Wait-MenuReturn
        return
    }

    Write-Host ""
    Write-Host "  리포트를 생성합니다..." -ForegroundColor Cyan
    if (-not (Invoke-Report)) {
        Wait-MenuReturn
        return
    }

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
    if (-not (Invoke-Scanner)) {
        Write-Host ""
        Write-Host "  ❌ 기본 검사 결과를 완성하지 못했습니다. 정밀 검사를 중단합니다." -ForegroundColor Red
        Wait-MenuReturn
        return
    }

    $runId = Get-LastRunId

    Write-Host ""
    Write-Host "  [2/3] 5분 유휴 관찰 시작 (Ctrl+C로 취소 가능)..." -ForegroundColor Cyan
    if (-not (Invoke-Monitor -RunId $runId)) {
        Write-Host ""
        Write-Host "  ⚠️  5분 관찰이 완료되지 않았습니다. 기본 검사 결과만으로 리포트를 만듭니다." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  [3/3] HTML 리포트 생성..." -ForegroundColor Cyan
    if (-not (Invoke-Report)) {
        Wait-MenuReturn
        return
    }

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
    Wait-MenuReturn
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
