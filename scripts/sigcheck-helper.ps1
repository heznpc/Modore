# ============================================================
# PC 건강검진 - Sysinternals Sigcheck 도우미
# 역할: 파일의 디지털 서명 검증 (악성코드 판별의 핵심 지표)
#
# 정책:
#  - Sysinternals 라이선스상 번들 불가. 첫 실행 시 사용자 동의 후 다운로드
#  - 다운로드 경로: %LOCALAPPDATA%\PC건강검진\tools\
#  - 공식 주소: https://live.sysinternals.com/sigcheck.exe
# ============================================================

# 단독 dot-source 케이스 대비 (보통 scanner.ps1이 먼저 로드함)
if (-not (Get-Command Assert-MicrosoftSignature -ErrorAction SilentlyContinue)) {
    . "$PSScriptRoot\_sysinternals-verify.ps1"
}

$script:SigcheckPath = $null
$script:SigcheckReady = $false

function Initialize-Sigcheck {
    param(
        [string]$ToolsDir = "$env:LOCALAPPDATA\PC건강검진\tools",
        [switch]$AutoDownload,
        [switch]$Quiet
    )

    if (-not (Test-Path $ToolsDir)) {
        New-Item -Path $ToolsDir -ItemType Directory -Force | Out-Null
    }
    $script:SigcheckPath = Join-Path $ToolsDir 'sigcheck.exe'

    # 캐시 hit이라도 매번 Authenticode 재검증. user-writable LOCALAPPDATA에 있는
    # PE이므로, 다른 user-mode 악성코드가 변조했을 가능성을 전제로 함. 실패 시
    # Assert가 파일을 삭제하므로 아래 다운로드 분기가 자연스럽게 재실행됨.
    if (Test-CachedSysinternalsBinary -FilePath $script:SigcheckPath -Quiet:$Quiet) {
        $script:SigcheckReady = $true
        if (-not $Quiet) { Write-Host "sigcheck.exe 확인됨 (서명 재검증 통과)" -ForegroundColor DarkGray }
        return $true
    }
    if (Test-Path $script:SigcheckPath) {
        # 여기 도달 = 파일은 있었으나 Assert가 검증 실패로 삭제했음. 사용자에게 알림.
        if (-not $Quiet) { Write-Host "캐시된 sigcheck.exe 서명 검증 실패 → 재다운로드 시도" -ForegroundColor Yellow }
    }

    if (-not $AutoDownload) {
        if (-not $Quiet) {
            Write-Host ""
            Write-Host "sigcheck.exe가 없습니다." -ForegroundColor Yellow
            Write-Host "Microsoft Sysinternals의 공식 도구로, 파일 서명을 검증하는 데 사용됩니다." -ForegroundColor Gray
            Write-Host "다운로드 주소: https://learn.microsoft.com/en-us/sysinternals/downloads/sigcheck" -ForegroundColor Gray
            Write-Host ""
            $answer = Read-Host "지금 자동 다운로드할까요? (y/N)"
            if ($answer -notmatch '^[yY]') {
                return $false
            }
        } else {
            return $false
        }
    }

    if (-not $Quiet) { Write-Host "sigcheck.exe 다운로드 중..." -ForegroundColor Cyan -NoNewline }
    try {
        $url = 'https://live.sysinternals.com/sigcheck.exe'
        Invoke-WebRequest -Uri $url -OutFile $script:SigcheckPath -UseBasicParsing -ErrorAction Stop

        if (-not (Assert-MicrosoftSignature -FilePath $script:SigcheckPath -Quiet:$Quiet)) {
            return $false
        }

        # EULA 자동 수락 (스크립트 자동화용, /accepteula 플래그 보완)
        New-Item -Path 'HKCU:\Software\Sysinternals\Sigcheck' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\Software\Sysinternals\Sigcheck' -Name 'EulaAccepted' -Value 1 -Type DWord

        $script:SigcheckReady = $true
        if (-not $Quiet) { Write-Host " 완료 (Microsoft 서명 확인됨)" -ForegroundColor Green }
        return $true
    } catch {
        if (-not $Quiet) { Write-Host " 실패: $($_.Exception.Message)" -ForegroundColor Red }
        return $false
    }
}

function Test-SigcheckReady {
    return $script:SigcheckReady
}

function Get-FileSignature {
    <#
    .SYNOPSIS
      주어진 파일의 디지털 서명 정보 조회
    .OUTPUTS
      @{ verified=<bool>; publisher=<string>; signingDate=<string>; rawStatus=<string> }
    #>
    param([Parameter(Mandatory)][string]$FilePath)

    if (-not $script:SigcheckReady) { return $null }
    if (-not (Test-Path $FilePath)) { return $null }

    try {
        # sigcheck -c : CSV 출력. -q : 배너 억제. -nobanner도 가능
        # 컬럼: Path,Verified,Date,Publisher,Company,Description,Product,Product Version,File Version,Machine Type
        $output = & $script:SigcheckPath -c -q -accepteula -nobanner "$FilePath" 2>$null
        if (-not $output) { return $null }

        # CSV 파싱 (sigcheck가 따옴표로 감싼 CSV 출력)
        $lines = $output | Where-Object { $_ -match '^"' }
        if ($lines.Count -eq 0) { return $null }

        $fields = $lines[0] -split '","' | ForEach-Object { $_ -replace '^"|"$','' }
        if ($fields.Count -lt 4) { return $null }

        $verified = $fields[1]
        $signingDate = $fields[2]
        $publisher = $fields[3]

        $isVerified = $verified -match '^Signed$'

        return @{
            verified = [bool]$isVerified
            publisher = $publisher
            signingDate = $signingDate
            rawStatus = $verified
        }
    } catch {
        return $null
    }
}

