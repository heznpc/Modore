# ============================================================
# PC 건강검진 - Autorunsc (Sysinternals) 도우미
# 역할: 레지스트리 Run 키, 예약 작업, 서비스, 브라우저 확장,
#       WMI 이벤트, WinLogon 후킹 등 모든 자동실행 항목 종합 분석
#
# 정책:
#  - Sysinternals 라이선스상 번들 불가. 사용자 동의 후 다운로드
#  - 공식 주소: https://live.sysinternals.com/autorunsc.exe
# ============================================================

# 단독 dot-source 케이스 대비 (보통 scanner.ps1이 먼저 로드함).
# sentinel 변수로 확인 — Get-Command는 user PS profile의 동명 함수에 속을 수 있음.
if (-not (Get-Variable -Name SysinternalsVerifyLoaded -Scope Script -ErrorAction SilentlyContinue)) {
    . "$PSScriptRoot\_sysinternals-verify.ps1"
}

$script:AutorunscPath = $null
$script:AutorunscReady = $false

function Initialize-Autorunsc {
    param(
        [string]$ToolsDir = "$env:LOCALAPPDATA\PC건강검진\tools",
        [switch]$AutoDownload,
        [switch]$Quiet
    )

    if (-not (Test-Path $ToolsDir)) {
        New-Item -Path $ToolsDir -ItemType Directory -Force | Out-Null
    }
    $script:AutorunscPath = Join-Path $ToolsDir 'autorunsc.exe'

    # 캐시 hit이라도 매번 Authenticode 재검증. sigcheck-helper.ps1과 동일한 위협
    # 모델: user-writable 경로의 PE는 다른 user-mode 악성코드가 변조 가능.
    $cacheCheck = Test-CachedSysinternalsBinary -FilePath $script:AutorunscPath -Quiet:$Quiet
    if ($cacheCheck.ok) {
        $script:AutorunscReady = $true
        if (-not $Quiet) { Write-Host "autorunsc.exe 확인됨 (서명 재검증 통과)" -ForegroundColor DarkGray }
        return $true
    }
    if ($cacheCheck.reason -eq 'tampered' -and -not $Quiet) {
        Write-Host "캐시된 autorunsc.exe 서명 검증 실패 → 재다운로드 시도" -ForegroundColor Yellow
    }

    if (-not $AutoDownload) {
        if (-not $Quiet) {
            Write-Host ""
            Write-Host "autorunsc.exe가 없습니다." -ForegroundColor Yellow
            Write-Host "Microsoft Sysinternals Autoruns의 명령줄 버전입니다." -ForegroundColor Gray
            Write-Host "자동실행 항목을 매우 상세히 분석하여 악성코드 지속성을 탐지합니다." -ForegroundColor Gray
            Write-Host ""
            $answer = Read-Host "지금 자동 다운로드할까요? (y/N)"
            if ($answer -notmatch '^[yY]') {
                return $false
            }
        } else {
            return $false
        }
    }

    if (-not $Quiet) { Write-Host "autorunsc.exe 다운로드 중..." -ForegroundColor Cyan -NoNewline }
    try {
        $url = 'https://live.sysinternals.com/autorunsc.exe'
        Invoke-WebRequest -Uri $url -OutFile $script:AutorunscPath -UseBasicParsing -ErrorAction Stop

        if (-not (Assert-MicrosoftSignature -FilePath $script:AutorunscPath -Quiet:$Quiet)) {
            return $false
        }

        New-Item -Path 'HKCU:\Software\Sysinternals\AutoRuns' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\Software\Sysinternals\AutoRuns' -Name 'EulaAccepted' -Value 1 -Type DWord

        $script:AutorunscReady = $true
        if (-not $Quiet) { Write-Host " 완료 (Microsoft 서명 확인됨)" -ForegroundColor Green }
        return $true
    } catch {
        if (-not $Quiet) { Write-Host " 실패: $($_.Exception.Message)" -ForegroundColor Red }
        return $false
    }
}

function Test-AutorunscReady {
    return $script:AutorunscReady
}

function Invoke-Autorunsc {
    <#
    .SYNOPSIS
      autorunsc로 모든 자동실행 항목을 XML로 받아 구조화된 객체 배열로 반환
    .OUTPUTS
      각 항목: @{
        category, entry, enabled, description, company, image, signer,
        signed, launchString, verified, hash
      }
    #>
    param(
        [switch]$HideMicrosoftSigned,
        [switch]$VerifySignatures
    )

    if (-not $script:AutorunscReady) { return $null }

    # autorunsc 플래그:
    #  -a *       모든 카테고리
    #  -x         XML 출력
    #  -h         MD5/SHA1/SHA256 해시 포함
    #  -s         서명 검증
    #  -m         Microsoft 서명 항목 숨김 (쿼터 절약)
    #  -nobanner  배너 숨김
    #  /accepteula
    $args_ = @('-a', '*', '-x', '-h', '-nobanner', '-accepteula')
    if ($VerifySignatures) { $args_ += '-s' }
    if ($HideMicrosoftSigned) { $args_ += '-m' }

    try {
        $xmlText = & $script:AutorunscPath @args_ 2>$null | Out-String
        if ([string]::IsNullOrWhiteSpace($xmlText)) { return @() }

        [xml]$xml = $xmlText
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $xml.autoruns.item) {
            $items.Add([PSCustomObject]@{
                category = [string]$item.category
                entry = [string]$item.entry
                enabled = [string]$item.enabled
                description = [string]$item.description
                company = [string]$item.company
                image = [string]$item.imagepath
                signer = [string]$item.signer
                launchString = [string]$item.launchstring
                location = [string]$item.entrylocation
                md5 = [string]$item.md5
                sha1 = [string]$item.sha1
                sha256 = [string]$item.sha256
                verified = ($item.signer -match '^\(Verified\)')
            })
        }
        return $items.ToArray()
    } catch {
        Write-Host "autorunsc XML 파싱 실패: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Get-AutorunRiskLevel {
    <#
    각 자동실행 항목에 대한 위험도 평가.
    검증되지 않음 + 사용자 폴더 실행 = 의심
    검증되지 않음 + 시스템 폴더 = 위험
    #>
    param($autorunItem)
    if ($null -eq $autorunItem) { return @{ level='unknown'; reason='' } }

    $image = $autorunItem.image
    $signer = $autorunItem.signer
    $launch = $autorunItem.launchString
    $verified = $autorunItem.verified

    # 명백한 위험 신호
    if ($launch -match 'powershell.*-enc|powershell.*-w(indow)?\s*(style)?\s*hidden') {
        return @{ level='danger'; reason='PowerShell 인코딩/숨김 명령 (악성코드 전형적 패턴)' }
    }
    if ($launch -match 'wscript.*\.vbs|cscript.*\.vbs') {
        return @{ level='warning'; reason='VBScript 자동 실행 (악성코드일 가능성)' }
    }
    if ($launch -match 'mshta.*http') {
        return @{ level='danger'; reason='MSHTA로 원격 스크립트 실행 (악성코드 전형적 패턴)' }
    }
    if ($image -match '\\Windows\\Temp\\|AppData\\Local\\Temp\\') {
        if (-not $verified) {
            return @{ level='danger'; reason='임시 폴더의 서명 없는 자동실행 (매우 의심)' }
        }
        return @{ level='warning'; reason='임시 폴더에서 자동실행' }
    }

    # 서명 확인
    if ($verified) {
        if ($signer -match 'Microsoft') {
            return @{ level='safe'; reason='Microsoft 서명' }
        }
        return @{ level='safe'; reason="서명됨: $signer" }
    }

    # 서명 없음 + AppData = 의심
    if ($image -match 'AppData\\') {
        return @{ level='warning'; reason='사용자 폴더의 서명 없는 자동실행' }
    }

    # 서명 없음 + Program Files = 낮은 의심 (합법적인 경우도 있음)
    if ($image -match '^C:\\Program Files') {
        return @{ level='info'; reason='설치 폴더이지만 서명 없음' }
    }

    return @{ level='info'; reason='확인 필요' }
}
