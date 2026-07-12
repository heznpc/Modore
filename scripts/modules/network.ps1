# ============================================================
# scanner 모듈: 네트워크 (외부 연결 + LISTEN 포트)
# 반환: 네트워크 raw facts
# ============================================================

function Get-ProcessMap {
    # pid → Process 객체 맵을 한 번에 구축. Get-Process -Id 반복 호출 회피.
    $map = @{}
    Get-Process | ForEach-Object { $map[$_.Id] = $_ }
    return $map
}

function Get-NetworkFacts {
    param([hashtable]$ProcessMap)

    if (-not $ProcessMap) { $ProcessMap = Get-ProcessMap }

    $connections = Get-NetTCPConnection -State Established |
        Where-Object {
            $_.RemoteAddress -notmatch '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|::1|fe80|0\.0\.0\.0)'
        }

    $seen = @{}
    $result = foreach ($c in $connections) {
        $proc = $ProcessMap[$c.OwningProcess]
        $procName = if ($proc) { $proc.ProcessName } else { 'unknown' }
        $key = "$procName|$($c.RemoteAddress)|$($c.RemotePort)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [ordered]@{
            process = $procName
            pid_ = $c.OwningProcess
            remoteAddress = $c.RemoteAddress
            remotePort = $c.RemotePort
            path = $proc.Path
            vtIp = $null
        }
    }
    return @($result)
}

function Get-ListeningPortFacts {
    param([hashtable]$ProcessMap)
    if (-not $ProcessMap) { $ProcessMap = Get-ProcessMap }

    $listening = Get-NetTCPConnection -State Listen |
        Where-Object { $_.LocalAddress -eq '0.0.0.0' -or $_.LocalAddress -eq '::' }

    $result = foreach ($l in $listening) {
        $proc = $ProcessMap[$l.OwningProcess]
        $procName = if ($proc) { $proc.ProcessName } else { 'unknown' }
        [ordered]@{
            port = $l.LocalPort
            name = $procName
            process = $procName
            pid_ = $l.OwningProcess
            path = $proc.Path
        }
    }
    return @($result | Sort-Object port)
}
