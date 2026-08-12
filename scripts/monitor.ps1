# ============================================================
# Modore - 5분간 유휴 CPU 모니터
# 역할: 사용자가 가만히 있는 동안 실제로 CPU를 쓰는 프로세스를 기록.
#       채굴기/백그라운드 악성코드 탐지에 효과적.
# ============================================================

[CmdletBinding()]
param(
    [int]$Minutes = 5,
    [int]$SampleIntervalSec = 10,
    [string]$OutputPath = "$PSScriptRoot\..\monitor_result.json",
    # menu.ps1의 정밀 검사 흐름에서 전달된다. 비어 있으면 단독 실행으로 간주해
    # monitor_merge.ps1이 기본 검사 결과에 병합하지 않는다.
    [string]$RunId = "",
    [string]$RawFactsPath = "$PSScriptRoot\..\raw_facts.json",
    [string]$ScanResultPath = "$PSScriptRoot\..\scan_result.json",
    [string]$RulesDir = "$PSScriptRoot\..\rules",
    [string]$WhitelistPath = "$PSScriptRoot\..\data\whitelist.json"
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$totalSamples = [math]::Floor(($Minutes * 60) / $SampleIntervalSec)
$cpuCount = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors

Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  5분간 유휴 상태 모니터링을 시작합니다." -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "이 시간 동안 가능하면 마우스/키보드를 만지지 마세요." -ForegroundColor Yellow
Write-Host "'진짜 CPU를 먹고 있는 범인'을 찾아내는 것이 목적입니다." -ForegroundColor Yellow
Write-Host ""
Write-Host "총 ${Minutes}분 (${totalSamples}회 샘플링, ${SampleIntervalSec}초 간격)" -ForegroundColor Gray
Write-Host ""

# ---------- 샘플 수집 ----------
$processStats = @{}   # key: procName, value: @{ samples, totalCpuDelta, lastCpu, path }
$samples = [System.Collections.Generic.List[object]]::new()

$prevSnapshot = @{}
Get-Process | ForEach-Object {
    if ($_.CPU) { $prevSnapshot[$_.Id] = @{ cpu=$_.CPU; name=$_.ProcessName; path=$_.Path } }
}

for ($i = 1; $i -le $totalSamples; $i++) {
    Start-Sleep -Seconds $SampleIntervalSec

    $overallCpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $snapshot = Get-Process | Where-Object { $_.CPU }

    # 각 프로세스의 CPU 증분 계산
    $sampleStats = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $snapshot) {
        $prev = $prevSnapshot[$p.Id]
        $delta = if ($prev) { [math]::Max(0, $p.CPU - $prev.cpu) } else { 0 }
        if ($delta -gt 0) {
            $percentCpu = [math]::Round(($delta / $SampleIntervalSec / $cpuCount) * 100, 1)
            $sampleStats.Add([ordered]@{
                name = $p.ProcessName
                pid_ = $p.Id
                deltaCpu = [math]::Round($delta, 2)
                percentCpu = $percentCpu
                path = $p.Path
            })

            # 누적 통계
            $key = $p.ProcessName.ToLower()
            if (-not $processStats.ContainsKey($key)) {
                $processStats[$key] = @{
                    name = $p.ProcessName
                    totalDelta = 0
                    sampleCount = 0
                    path = $p.Path
                    maxPercent = 0
                }
            }
            $processStats[$key].totalDelta += $delta
            $processStats[$key].sampleCount += 1
            if ($percentCpu -gt $processStats[$key].maxPercent) {
                $processStats[$key].maxPercent = $percentCpu
            }
        }
    }

    # 진행 표시
    $sampleStats = $sampleStats | Sort-Object percentCpu -Descending | Select-Object -First 5
    $topNames = ($sampleStats | ForEach-Object { "$($_.name)($($_.percentCpu)%)" }) -join ', '
    $progress = [int](($i / $totalSamples) * 100)
    Write-Host ("[{0,3}%] 전체CPU:{1,3}% | 상위: {2}" -f $progress, $overallCpu, $topNames)

    $samples.Add([ordered]@{
        time = (Get-Date).ToString('HH:mm:ss')
        overallCpu = $overallCpu
        top = @($sampleStats)
    })

    # 다음 비교를 위한 스냅샷 저장
    $prevSnapshot = @{}
    $snapshot | ForEach-Object { $prevSnapshot[$_.Id] = @{ cpu=$_.CPU; name=$_.ProcessName; path=$_.Path } }
}

# ---------- 집계 ----------
# risk/note는 여기서 판정하지 않는다 -- rule_engine.ps1(rules/process.json의
# background_cpu_* 규칙)이 유일한 판정처다. monitor_merge.ps1로 넘어간다.
$aggregate = [System.Collections.Generic.List[object]]::new()
foreach ($k in $processStats.Keys) {
    $s = $processStats[$k]
    $avgPercent = [math]::Round(($s.totalDelta / ($totalSamples * $SampleIntervalSec) / $cpuCount) * 100, 1)

    $aggregate.Add([ordered]@{
        name = $s.name
        averagePercent = $avgPercent
        maxPercent = $s.maxPercent
        totalCpuSec = [math]::Round($s.totalDelta, 1)
        path = $s.path
    })
}

$aggregate = @($aggregate | Sort-Object averagePercent -Descending)

# ---------- 저장 ----------
$result = [ordered]@{
    runId = $RunId
    monitoredAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    durationMinutes = $Minutes
    sampleIntervalSec = $SampleIntervalSec
    cpuCount = $cpuCount
    averageOverallCpu = [math]::Round(($samples | Measure-Object -Property overallCpu -Average).Average, 1)
    samples = $samples.ToArray()
    aggregate = $aggregate
}

$json = $result | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($true)))

Write-Host ""
Write-Host "평균 전체 CPU 사용률: $($result.averageOverallCpu)%" -ForegroundColor $(if ($result.averageOverallCpu -gt 50) {'Red'} elseif ($result.averageOverallCpu -gt 20) {'Yellow'} else {'Green'})

& "$PSScriptRoot\monitor_merge.ps1" -RunId $RunId -MonitorResultPath $OutputPath `
    -RawFactsPath $RawFactsPath -ScanResultPath $ScanResultPath `
    -RulesDir $RulesDir -WhitelistPath $WhitelistPath
