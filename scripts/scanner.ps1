# ============================================================
# PC 건강검진 - 스캐너 오케스트레이터 (v0.3)
#
# 역할: 각 섹션 모듈을 순차 호출해 raw facts를 수집하고,
#       PowerShell rule_engine에 넘겨 최종 scan_result.json 생성.
#
# 파이프라인:
#   scanner.ps1 → raw_facts.json → rule_engine.ps1 → scan_result.json
#                                                 ↓
#                                            report.ps1 → HTML
#
# 섹션 추가 방법:
#   1) modules/내섹션.ps1 에 Get-<Name>Facts 함수 작성
#   2) 이 파일의 ## 8. 섹션 실행 구간에 dot-source + 호출 한 줄 추가
#   3) 판정 규칙은 rules/*.json 에 추가 (PowerShell 수정 불필요)
# ============================================================

[CmdletBinding()]
param(
    [string]$OutputPath = "$PSScriptRoot\..\scan_result.json",
    [string]$RawPath = "$PSScriptRoot\..\raw_facts.json",
    [string]$WhitelistPath = "$PSScriptRoot\..\data\whitelist.json",
    [string]$ConfigPath = "$PSScriptRoot\..\data\config.json",
    [string]$RulesDir = "$PSScriptRoot\..\rules",
    [switch]$NoVtLookup,
    [switch]$NoRuleEngine
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# ---------- 헬퍼 로드 ----------
. "$PSScriptRoot\_sysinternals-verify.ps1"
. "$PSScriptRoot\vt-lookup.ps1"
. "$PSScriptRoot\sigcheck-helper.ps1"
. "$PSScriptRoot\autorunsc-helper.ps1"

# ---------- 섹션 모듈 로드 ----------
. "$PSScriptRoot\modules\cpu.ps1"
. "$PSScriptRoot\modules\network.ps1"
. "$PSScriptRoot\modules\autoruns.ps1"
. "$PSScriptRoot\modules\defender.ps1"
. "$PSScriptRoot\modules\installs.ps1"

# ---------- 헬퍼 초기화 ----------
Initialize-VtLookup -ConfigPath $ConfigPath
$useVt = (-not $NoVtLookup) -and (Test-VtEnabled)
if ($useVt) {
    Write-Host "VirusTotal 조회 활성화 (쿼터 보호: 캐시 48h, 레이트 16초)" -ForegroundColor DarkCyan
} else {
    if (-not $NoVtLookup) {
        Write-Host "VT 조회 비활성 (data\config.json에서 enabled=true 및 apiKey 설정 시 활성화)" -ForegroundColor DarkGray
    }
}

$config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$sysCfg = if ($config.sysinternals) { $config.sysinternals } else { [PSCustomObject]@{ useSigcheck=$false; useAutorunsc=$false; autoDownload=$false } }

$useSigcheck = $false
$useAutorunsc = $false
if ($sysCfg.useSigcheck) {
    $useSigcheck = Initialize-Sigcheck -AutoDownload:$sysCfg.autoDownload -Quiet
    if ($useSigcheck) { Write-Host "sigcheck 활성화 (Sysinternals)" -ForegroundColor DarkCyan }
}
if ($sysCfg.useAutorunsc) {
    $useAutorunsc = Initialize-Autorunsc -AutoDownload:$sysCfg.autoDownload -Quiet
    if ($useAutorunsc) { Write-Host "autorunsc 활성화 (Sysinternals)" -ForegroundColor DarkCyan }
}

# ---------- 1회만 수집하는 공유 컨텍스트 ----------
$osInfo = Get-CimInstance Win32_OperatingSystem
$processMap = Get-ProcessMap

# ---------- raw facts 루트 ----------
$raw = [ordered]@{
    schemaVersion = "1.0"
    scannedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    computerName = $env:COMPUTERNAME
    userName = $env:USERNAME
    osVersion = $osInfo.Caption
    platform = "windows"
    scannerVersion = "0.3"
    findings = @()
    sections = [ordered]@{}
}

Write-Host "PC 건강검진을 시작합니다..." -ForegroundColor Cyan

# ============================================================
# 섹션 실행
# ============================================================

Write-Host "  [1/8] CPU 사용량 검사..." -NoNewline
$raw.sections.cpu = Get-CpuFacts -UseSigcheck:$useSigcheck -UseVt:$useVt
Write-Host " 완료" -ForegroundColor Green

Write-Host "  [2/8] GPU 사용량 검사..." -NoNewline
$raw.sections.gpu = Get-GpuFacts -ProcessMap $processMap
Write-Host " 완료" -ForegroundColor Green

Write-Host "  [3/8] 네트워크 연결 검사..." -NoNewline
$raw.sections.network = Get-NetworkFacts -UseVt:$useVt -ProcessMap $processMap
Write-Host " 완료" -ForegroundColor Green

Write-Host "  [4/8] 열린 포트 검사..." -NoNewline
$raw.sections.listeningPorts = Get-ListeningPortFacts -ProcessMap $processMap
Write-Host " 완료" -ForegroundColor Green

Write-Host "  [5/8] 자동 실행 항목 검사..." -NoNewline
$raw.sections.startup = Get-StartupFacts
Write-Host " 완료" -ForegroundColor Green

if ($useAutorunsc) {
    Write-Host "  [5b] Autorunsc 종합 분석..." -NoNewline
    $raw.sections.autoruns = Get-AutorunscFacts -UseVt:$useVt
    Write-Host " 완료 ($($raw.sections.autoruns.Count)건)" -ForegroundColor Green
}

Write-Host "  [6/8] 예약 작업 검사..." -NoNewline
$raw.sections.scheduledTasks = Get-ScheduledTaskFacts
Write-Host " 완료" -ForegroundColor Green

Write-Host "  [7/8] Windows Defender 상태..." -NoNewline
$raw.sections.defender = Get-DefenderFacts
Write-Host " 완료" -ForegroundColor Green

Write-Host "  [8/8] 최근 설치 프로그램..." -NoNewline
$raw.sections.recentInstalls = Get-RecentInstallFacts
Write-Host " 완료" -ForegroundColor Green

# ============================================================
# 메타 섹션
# ============================================================
$raw.sections.systemLoad = Get-SystemLoadFacts -OsInfo $osInfo

$raw.sections.virustotal = [ordered]@{
    enabled = [bool]$useVt
    callsThisScan = if ($useVt) { $script:VtCallsThisScan } else { 0 }
    cacheHours = if ($useVt) { $script:VtConfig.virustotal.cacheHours } else { 0 }
}
if ($useVt) {
    Save-VtCache
    Write-Host "VT 조회: $script:VtCallsThisScan 건" -ForegroundColor DarkCyan
}

$raw.sections.sysinternals = [ordered]@{
    sigcheckEnabled = [bool]$useSigcheck
    autorunscEnabled = [bool]$useAutorunsc
}

# ============================================================
# raw 저장 + 규칙 엔진 실행
# ============================================================
$rawJson = $raw | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($RawPath, $rawJson, (New-Object System.Text.UTF8Encoding($true)))

if ($NoRuleEngine) {
    Write-Host ""
    Write-Host "raw facts 저장됨 (규칙 엔진 건너뜀): $RawPath" -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    return
}

Write-Host ""
Write-Host "규칙 엔진 실행 중..." -NoNewline
& "$PSScriptRoot\rule_engine.ps1" -Raw $RawPath -Rules $RulesDir -Whitelist $WhitelistPath -Output $OutputPath
$ruleEngineOk = $?
if (-not $ruleEngineOk) {
    Write-Host " 실패" -ForegroundColor Red
    Write-Host "  raw facts는 저장됐지만 최종 scan_result.json은 만들지 않았습니다: $RawPath" -ForegroundColor Yellow
    $global:LASTEXITCODE = 2
    return
}

# 요약
$scan = Get-Content $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host ""
Write-Host "검사 완료! 결과: $OutputPath" -ForegroundColor Cyan
Write-Host "  - 위험: $($scan.summary.dangerCount) 건" -ForegroundColor $(if ($scan.summary.dangerCount -gt 0) {'Red'} else {'Gray'})
Write-Host "  - 확인: $($scan.summary.warningCount) 건" -ForegroundColor $(if ($scan.summary.warningCount -gt 0) {'Yellow'} else {'Gray'})
$global:LASTEXITCODE = 0
