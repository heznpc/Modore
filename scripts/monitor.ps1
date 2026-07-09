# ============================================================
# PC 건강검진 - 5분간 유휴 CPU 모니터
# 역할: 사용자가 가만히 있는 동안 실제로 CPU를 쓰는 프로세스를 기록.
#       채굴기/백그라운드 악성코드 탐지에 효과적.
# ============================================================

[CmdletBinding()]
param(
    [int]$Minutes = 5,
    [int]$SampleIntervalSec = 10,
    [string]$OutputPath = "$PSScriptRoot\..\monitor_result.json",
    [string]$WhitelistPath = "$PSScriptRoot\..\data\whitelist.json"
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$whitelist = Get-Content $WhitelistPath -Raw -Encoding UTF8 | ConvertFrom-Json
$knownGood = @{}
foreach ($category in 'system','browser','korean_common','banking_security','dev_tools','hardware','cloud') {
    $whitelist.$category.PSObject.Properties |
        Where-Object { $_.Name -notmatch '^_' } |
        ForEach-Object { $knownGood[$_.Name.ToLower()] = $_.Value }
}
$miners = @{}
$whitelist.miner_blacklist.PSObject.Properties |
    Where-Object { $_.Name -notmatch '^_' } |
    ForEach-Object { $miners[$_.Name.ToLower()] = $_.Value.desc }

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
$aggregate = [System.Collections.Generic.List[object]]::new()
foreach ($k in $processStats.Keys) {
    $s = $processStats[$k]
    $avgPercent = [math]::Round(($s.totalDelta / ($totalSamples * $SampleIntervalSec) / $cpuCount) * 100, 1)

    $risk = 'safe'
    $note = ''
    if ($miners.ContainsKey($k)) {
        $risk = 'danger'
        $note = "알려진 채굴기: $($miners[$k])"
    } elseif ($knownGood.ContainsKey($k)) {
        $risk = 'safe'
        $note = $knownGood[$k].desc
    } elseif ($avgPercent -gt 20 -and $s.path -match 'AppData|Temp') {
        $risk = 'danger'
        $note = '사용자 폴더에서 지속적으로 CPU를 많이 사용 - 채굴기 의심'
    } elseif ($avgPercent -gt 30) {
        $risk = 'warning'
        $note = "평균 ${avgPercent}% CPU 사용 - 확인 필요"
    }

    $aggregate.Add([ordered]@{
        name = $s.name
        averagePercent = $avgPercent
        maxPercent = $s.maxPercent
        totalCpuSec = [math]::Round($s.totalDelta, 1)
        path = $s.path
        risk = $risk
        note = $note
    })
}

$aggregate = @($aggregate | Sort-Object averagePercent -Descending)

# ---------- 저장 ----------
$result = [ordered]@{
    monitoredAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    durationMinutes = $Minutes
    sampleIntervalSec = $SampleIntervalSec
    cpuCount = $cpuCount
    averageOverallCpu = [math]::Round(($samples | Measure-Object -Property overallCpu -Average).Average, 1)
    samples = $samples.ToArray()
    aggregate = $aggregate
    suspects = @($aggregate | Where-Object { $_.risk -in 'danger','warning' } | Select-Object -First 10)
}

$json = $result | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($true)))

Write-Host ""
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  모니터링 완료!" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "평균 전체 CPU 사용률: $($result.averageOverallCpu)%" -ForegroundColor $(if ($result.averageOverallCpu -gt 50) {'Red'} elseif ($result.averageOverallCpu -gt 20) {'Yellow'} else {'Green'})
Write-Host ""
Write-Host "CPU 사용 상위 프로세스 (평균):" -ForegroundColor Cyan
$aggregate | Select-Object -First 10 | ForEach-Object {
    $color = switch ($_.risk) { 'danger' {'Red'} 'warning' {'Yellow'} default {'Gray'} }
    Write-Host ("  {0,-25} 평균 {1,5}% / 최대 {2,5}% {3}" -f $_.name, $_.averagePercent, $_.maxPercent, $_.note) -ForegroundColor $color
}
Write-Host ""
Write-Host "결과 저장: $OutputPath" -ForegroundColor Gray
