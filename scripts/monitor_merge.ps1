# ============================================================
# Modore - 정밀검사 관측 결과 병합기
#
# 역할: monitor.ps1이 5분간 모은 raw 집계(monitor_result.json)를 이번 실행의
#       raw_facts.json에 backgroundCpu 섹션으로 얹고, rule_engine.ps1을 다시
#       실행해 scan_result.json을 한 번에 새로 만든다.
#
# 왜 별도 스크립트인가:
#   monitor.ps1은 5분짜리 표본 수집 루프를 갖고 있어 통째로 실행하는 테스트가
#   비현실적이다. 병합/판정 로직(이 파일)은 그 루프와 분리돼 있어 즉시 검증 가능
#   하다. scanner.ps1 -> rule_engine.ps1과 같은 "수집 -> 판정 위임" 구조를 그대로
#   따른다.
#
# 판정은 오직 rule_engine.ps1을 통해서만 한다 -- monitor.ps1이 예전에 갖고 있던
# 자체 임계값(미리 정의된 채굴기 목록, 20%/30% 하드코딩)은 rules/process.json의
# background_cpu_* 규칙으로 옮겨졌다. 이 스크립트는 판정을 직접 내리지 않는다.
# ============================================================

[CmdletBinding()]
param(
    [string]$RunId = "",
    [Parameter(Mandatory)][string]$MonitorResultPath,
    [string]$RawFactsPath = "$PSScriptRoot\..\raw_facts.json",
    [string]$ScanResultPath = "$PSScriptRoot\..\scan_result.json",
    [string]$RulesDir = "$PSScriptRoot\..\rules",
    [string]$WhitelistPath = "$PSScriptRoot\..\data\whitelist.json"
)

$ErrorActionPreference = 'Stop'

$monitorResult = Get-Content $MonitorResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$backgroundCpuFacts = @(@($monitorResult.aggregate) | ForEach-Object {
    [ordered]@{
        name = $_.name
        path = $_.path
        cpuPercent = $_.averagePercent
        maxPercent = $_.maxPercent
        totalCpuSec = $_.totalCpuSec
    }
})

# ---------- 병합 대상 결정 ----------
# runId가 없으면(단독 실행) 관측 결과만 남기고 병합하지 않는다 -- monitor.ps1은
# menu.ps1 없이도 그 자체로 쓸 수 있는 진단 도구다. runId가 있는데 raw_facts.json이
# 없거나 다른 실행의 것이면, 엉뚱한 기본 검사 결과에 관측 데이터를 얹는 것보다
# 병합을 건너뛰는 쪽이 안전하다.
$canIntegrate = $false
$targetRawPath = $null
$targetOutputPath = $null

if ($RunId) {
    if (Test-Path $RawFactsPath) {
        $existingRaw = Get-Content $RawFactsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$existingRaw.runId -eq $RunId) {
            $existingRaw.sections | Add-Member -NotePropertyName backgroundCpu -NotePropertyValue $backgroundCpuFacts -Force
            $mergedJson = $existingRaw | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($RawFactsPath, $mergedJson, (New-Object System.Text.UTF8Encoding($true)))
            $targetRawPath = $RawFactsPath
            $targetOutputPath = $ScanResultPath
            $canIntegrate = $true
        } else {
            Write-Host "  ⚠️  실행 식별자가 일치하지 않아 기본 검사 결과에 병합하지 않습니다 (관측 결과만 저장됨)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⚠️  이전 기본 검사 결과(raw_facts.json)를 찾을 수 없어 병합하지 않습니다 (관측 결과만 저장됨)." -ForegroundColor Yellow
    }
}

$tempFiles = @()
if (-not $canIntegrate) {
    $scratchRaw = [ordered]@{
        schemaVersion = "1.0"
        scannedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        findings = @()
        sections = [ordered]@{ backgroundCpu = $backgroundCpuFacts }
    }
    $targetRawPath = Join-Path ([System.IO.Path]::GetTempPath()) "pch-monitor-standalone-raw-$([guid]::NewGuid()).json"
    $targetOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "pch-monitor-standalone-out-$([guid]::NewGuid()).json"
    [System.IO.File]::WriteAllText($targetRawPath, ($scratchRaw | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($true)))
    $tempFiles = @($targetRawPath, $targetOutputPath)
}

# ---------- 판정 위임 ----------
& "$PSScriptRoot\rule_engine.ps1" -Raw $targetRawPath -Rules $RulesDir -Whitelist $WhitelistPath -Output $targetOutputPath
if (-not $?) {
    foreach ($f in $tempFiles) { Remove-Item $f -ErrorAction SilentlyContinue }
    throw "rule_engine.ps1 실행 실패"
}

$classified = Get-Content $targetOutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
$classifiedAggregate = @($classified.sections.backgroundCpu)

foreach ($f in $tempFiles) { Remove-Item $f -ErrorAction SilentlyContinue }

# ---------- 콘솔 요약 ----------
Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  모니터링 완료!" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""
if ($canIntegrate) {
    Write-Host "  기본 검사 결과에 반영됨: $ScanResultPath" -ForegroundColor Gray
    Write-Host ""
}
Write-Host "CPU 사용 상위 프로세스 (평균):" -ForegroundColor Cyan
if ($classifiedAggregate.Count -eq 0) {
    Write-Host "  관측 구간 동안 유의미하게 CPU를 사용한 프로세스가 없습니다." -ForegroundColor Gray
} else {
    $classifiedAggregate | Sort-Object cpuPercent -Descending | Select-Object -First 10 | ForEach-Object {
        $color = switch ($_.risk) { 'danger' {'Red'} 'warning' {'Yellow'} default {'Gray'} }
        Write-Host ("  {0,-25} 평균 {1,5}% / 최대 {2,5}% {3}" -f $_.name, $_.cpuPercent, $_.maxPercent, $_.note) -ForegroundColor $color
    }
}
Write-Host ""
Write-Host "관측 결과 저장: $MonitorResultPath" -ForegroundColor Gray
