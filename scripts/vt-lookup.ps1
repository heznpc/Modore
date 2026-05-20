# ============================================================
# PC 건강검진 - VirusTotal 조회 모듈
# 역할: SHA256 해시 및 IP/도메인의 VT 평판을 안전하게 조회
#
# 원칙:
#  1. 파일을 업로드하지 않음. 해시만 전송 (개인정보 보호)
#  2. 쿼터 관리: 48시간 TTL 캐시, 4 req/min 레이트 리밋
#  3. 키가 없으면 조용히 스킵 (기본 검사에 영향 없음)
# ============================================================

$script:VtConfig = $null
$script:VtCache = $null
$script:VtCachePath = $null
$script:VtLastCall = [DateTime]::MinValue
$script:VtRateLimitSec = 16   # 4 req/min = 15초 간격, 안전하게 16초

function Initialize-VtLookup {
    param(
        [string]$ConfigPath = "$PSScriptRoot\..\data\config.json",
        [string]$CacheDir = "$env:LOCALAPPDATA\PC건강검진"
    )

    # 캐시 디렉터리 생성
    if (-not (Test-Path $CacheDir)) {
        New-Item -Path $CacheDir -ItemType Directory -Force | Out-Null
    }
    $script:VtCachePath = Join-Path $CacheDir 'vt-cache.json'

    # 설정 로드
    if (Test-Path $ConfigPath) {
        $script:VtConfig = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $script:VtConfig = [PSCustomObject]@{
            virustotal = [PSCustomObject]@{
                apiKey = ''
                enabled = $false
                cacheHours = 48
                maxCallsPerScan = 100
            }
        }
    }

    # 환경변수 우선: VT_API_KEY가 있으면 config.json의 apiKey를 덮어쓰고 자동 활성화.
    # 공유/CI 환경에서 키를 디스크 평문으로 저장하지 않아도 되는 경로.
    $envKey = [System.Environment]::GetEnvironmentVariable('VT_API_KEY')
    if (-not [string]::IsNullOrWhiteSpace($envKey)) {
        $script:VtConfig.virustotal.apiKey = $envKey
        $script:VtConfig.virustotal.enabled = $true
    }

    # 캐시 로드
    if (Test-Path $script:VtCachePath) {
        try {
            $script:VtCache = Get-Content $script:VtCachePath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        } catch {
            $script:VtCache = @{}
        }
    } else {
        $script:VtCache = @{}
    }

    $script:VtCallsThisScan = 0
}

function Test-VtEnabled {
    if (-not $script:VtConfig) { return $false }
    if (-not $script:VtConfig.virustotal.enabled) { return $false }
    if ([string]::IsNullOrWhiteSpace($script:VtConfig.virustotal.apiKey)) { return $false }
    return $true
}

function Save-VtCache {
    if ($null -ne $script:VtCache -and $script:VtCachePath) {
        $json = $script:VtCache | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($script:VtCachePath, $json, (New-Object System.Text.UTF8Encoding($true)))
    }
}

function Get-CachedVt {
    param([string]$Key)
    if (-not $script:VtCache.ContainsKey($Key)) { return $null }
    $entry = $script:VtCache[$Key]
    $age = (Get-Date) - [DateTime]$entry.cachedAt
    $ttl = [TimeSpan]::FromHours($script:VtConfig.virustotal.cacheHours)
    if ($age -gt $ttl) {
        $script:VtCache.Remove($Key) | Out-Null
        return $null
    }
    return $entry.result
}

function Set-CachedVt {
    param([string]$Key, $Result)
    $script:VtCache[$Key] = @{
        cachedAt = (Get-Date).ToString('o')
        result = $Result
    }
}

function Invoke-VtRequest {
    param([string]$Url)

    if (-not (Test-VtEnabled)) { return $null }
    if ($script:VtCallsThisScan -ge $script:VtConfig.virustotal.maxCallsPerScan) {
        return @{ error = 'quota'; message = '이번 검사 VT 쿼터 한도 도달' }
    }

    # 레이트 리밋: 마지막 호출부터 16초 이상 경과
    $sinceLast = (Get-Date) - $script:VtLastCall
    if ($sinceLast.TotalSeconds -lt $script:VtRateLimitSec) {
        $waitMs = [int](($script:VtRateLimitSec - $sinceLast.TotalSeconds) * 1000)
        Start-Sleep -Milliseconds $waitMs
    }

    $headers = @{
        'x-apikey' = $script:VtConfig.virustotal.apiKey
        'accept' = 'application/json'
    }

    $script:VtLastCall = Get-Date
    $script:VtCallsThisScan += 1

    try {
        $response = Invoke-RestMethod -Uri $Url -Headers $headers -Method Get -ErrorAction Stop
        return @{ ok = $true; data = $response.data }
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        switch ($statusCode) {
            404 { return @{ ok = $true; notFound = $true } }   # 정상적인 "알려지지 않음"
            429 { return @{ error = 'rate_limit'; message = '레이트 한도. 잠시 후 재시도' } }
            401 { return @{ error = 'auth'; message = 'API 키가 잘못되었습니다' } }
            default { return @{ error = 'api'; message = "HTTP $statusCode : $($_.Exception.Message)" } }
        }
    }
}

function Get-VtFileReputation {
    param(
        [Parameter(Mandatory)][string]$FilePath
    )

    if (-not (Test-VtEnabled)) { return $null }
    if (-not (Test-Path $FilePath)) { return $null }

    try {
        $hash = (Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower()
    } catch {
        return $null  # 파일 잠김 등
    }

    $cacheKey = "file:$hash"
    $cached = Get-CachedVt $cacheKey
    if ($null -ne $cached) { return $cached }

    $url = "https://www.virustotal.com/api/v3/files/$hash"
    $resp = Invoke-VtRequest $url

    if ($null -eq $resp) { return $null }
    if ($resp.error) {
        return @{ status = $resp.error; message = $resp.message; hash = $hash }
    }
    if ($resp.notFound) {
        $result = @{ status = 'unknown'; hash = $hash }
        Set-CachedVt $cacheKey $result
        return $result
    }

    $stats = $resp.data.attributes.last_analysis_stats
    $result = @{
        status = 'ok'
        hash = $hash
        malicious = [int]$stats.malicious
        suspicious = [int]$stats.suspicious
        harmless = [int]$stats.harmless
        undetected = [int]$stats.undetected
        totalEngines = [int]$stats.malicious + [int]$stats.suspicious + [int]$stats.harmless + [int]$stats.undetected
        reputation = [int]$resp.data.attributes.reputation
        lastAnalysis = if ($resp.data.attributes.last_analysis_date) {
            (Get-Date '1970-01-01').AddSeconds($resp.data.attributes.last_analysis_date).ToString('yyyy-MM-dd')
        } else { $null }
        signer = $resp.data.attributes.signature_info.verified
        names = @($resp.data.attributes.names | Select-Object -First 3)
    }
    Set-CachedVt $cacheKey $result
    return $result
}

function Get-VtIpReputation {
    param([Parameter(Mandatory)][string]$IpAddress)

    if (-not (Test-VtEnabled)) { return $null }

    $cacheKey = "ip:$IpAddress"
    $cached = Get-CachedVt $cacheKey
    if ($null -ne $cached) { return $cached }

    $url = "https://www.virustotal.com/api/v3/ip_addresses/$IpAddress"
    $resp = Invoke-VtRequest $url
    if ($null -eq $resp) { return $null }
    if ($resp.error) {
        return @{ status = $resp.error; message = $resp.message; ip = $IpAddress }
    }
    if ($resp.notFound) {
        $result = @{ status = 'unknown'; ip = $IpAddress }
        Set-CachedVt $cacheKey $result
        return $result
    }

    $stats = $resp.data.attributes.last_analysis_stats
    $result = @{
        status = 'ok'
        ip = $IpAddress
        malicious = [int]$stats.malicious
        suspicious = [int]$stats.suspicious
        harmless = [int]$stats.harmless
        undetected = [int]$stats.undetected
        country = $resp.data.attributes.country
        asnOwner = $resp.data.attributes.as_owner
        reputation = [int]$resp.data.attributes.reputation
    }
    Set-CachedVt $cacheKey $result
    return $result
}

