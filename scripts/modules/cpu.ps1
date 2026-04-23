# ============================================================
# scanner 모듈: CPU 상위 프로세스
# 반환: 프로세스 raw facts 배열 (판정 없음)
# 의존: vt-lookup.ps1, sigcheck-helper.ps1 (선택)
# ============================================================

function Should-SkipVtForPath {
    param([string]$path)
    if (-not $path) { return $true }
    if ($path -match '^C:\\Windows\\(System32|SysWOW64)\\') { return $true }
    if ($path -match '^C:\\Windows\\WinSxS\\') { return $true }
    if ($path -match '^C:\\Program Files\\WindowsApps\\Microsoft\.') { return $true }
    return $false
}

function Get-CpuFacts {
    param(
        [bool]$UseSigcheck = $false,
        [bool]$UseVt = $false,
        [int]$TopN = 20
    )

    $topCpu = Get-Process |
        Where-Object { $_.CPU -gt 0 } |
        Sort-Object CPU -Descending |
        Select-Object -First $TopN

    $result = foreach ($p in $topCpu) {
        $sig = $null
        if ($UseSigcheck -and $p.Path -and -not (Should-SkipVtForPath $p.Path)) {
            $sig = Get-FileSignature -FilePath $p.Path
        }
        $vtResult = $null
        if ($UseVt -and $p.Path -and -not (Should-SkipVtForPath $p.Path)) {
            $vtResult = Get-VtFileReputation -FilePath $p.Path
        }
        [ordered]@{
            name = $p.ProcessName
            pid_ = $p.Id
            cpu = [math]::Round($p.CPU, 1)
            memoryMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
            path = $p.Path
            sig = $sig
            vt = $vtResult
        }
    }
    return @($result)
}

function Get-GpuFacts {
    param([hashtable]$ProcessMap)

    $result = @()
    try {
        $gpuCounters = Get-Counter '\GPU Engine(*engtype_3D)\Utilization Percentage' -ErrorAction Stop
        $result = $gpuCounters.CounterSamples |
            Where-Object { $_.CookedValue -gt 1 } |
            Sort-Object CookedValue -Descending |
            Select-Object -First 10 |
            ForEach-Object {
                $pidMatch = [regex]::Match($_.Path, 'pid_(\d+)')
                $procName = 'unknown'
                if ($pidMatch.Success -and $ProcessMap) {
                    $proc = $ProcessMap[[int]$pidMatch.Groups[1].Value]
                    if ($proc) { $procName = $proc.ProcessName }
                }
                [ordered]@{
                    process = $procName
                    usage = [math]::Round($_.CookedValue, 1)
                }
            }
    } catch {}
    return @($result)
}

function Get-SystemLoadFacts {
    param($OsInfo)
    $mem = if ($OsInfo) { $OsInfo } else { Get-CimInstance Win32_OperatingSystem }
    $cpuLoad = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $memPercent = [math]::Round((($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / $mem.TotalVisibleMemorySize) * 100, 1)
    return [ordered]@{
        cpuPercent = $cpuLoad
        memoryPercent = $memPercent
        totalMemoryGB = [math]::Round($mem.TotalVisibleMemorySize / 1MB, 1)
    }
}
