# ============================================================
# PC 건강검진 - Sysinternals 다운로드 검증 공통 모듈
#
# 왜: sigcheck.exe / autorunsc.exe는 https://live.sysinternals.com/
# 에서 다운로드한 직후 실행되므로, TLS만 신뢰하면 CDN/DNS 침해가
# 곧바로 임의 코드 실행으로 이어진다. Authenticode 서명을 추가로
# 강제해 트러스트 루트를 Microsoft 코드사이닝 인증서까지 끌어내림.
# ============================================================

# 변경 시: cert subject 패턴이 Microsoft 측에서 바뀌면 여기 한 곳만 갱신.
$script:MicrosoftSignerPattern = 'O=Microsoft Corporation'
$script:ValidSignatureStatus = 'Valid'

function Assert-MicrosoftSignature {
    <#
    .SYNOPSIS
      파일이 Microsoft Authenticode 서명을 갖고 있고 상태가 Valid인지 확인.
      실패 시 파일을 삭제하고 $false 반환 (호출자는 즉시 abort 권장).
    .OUTPUTS
      [bool] 유효하면 $true, 그 외 $false
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [switch]$Quiet
    )

    $sig = Get-AuthenticodeSignature -FilePath $FilePath
    $okStatus = $sig.Status -eq $script:ValidSignatureStatus
    $okSigner = $sig.SignerCertificate -and ($sig.SignerCertificate.Subject -match $script:MicrosoftSignerPattern)

    if ($okStatus -and $okSigner) { return $true }

    # 검증 실패: 임의 코드 실행을 막기 위해 즉시 삭제.
    Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
    if (-not $Quiet) {
        $reason = if (-not $okStatus) { "서명 상태=$($sig.Status)" } else { "서명자=$($sig.SignerCertificate.Subject)" }
        Write-Host " 실패: Microsoft 서명 검증 거부 ($reason)" -ForegroundColor Red
    }
    return $false
}

function Test-CachedSysinternalsBinary {
    <#
    .SYNOPSIS
      디스크에 캐시된 sysinternals 바이너리가 (1) 존재하고 (2) Microsoft
      Authenticode 서명을 통과하는지 확인. 검증 실패 시 Assert가 파일을 삭제하므로
      호출자는 다운로드 분기로 fallback 가능.

    .DESCRIPTION
      매 실행마다 검증해야 하는 이유: pc-health-check는 *다른 user-mode 악성코드의
      존재를 전제*로 하는 진단 도구. 캐시된 .exe가 변조됐을 시나리오를 위협 모델에
      포함하지 않으면, pc-health-check 자체가 그 코드를 신뢰 실행하는 launcher가 됨.
    .OUTPUTS
      [bool] 캐시 hit + 검증 통과면 $true, 그 외 $false (호출자는 다운로드로 진행)
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [switch]$Quiet
    )

    if (-not (Test-Path $FilePath)) { return $false }
    return (Assert-MicrosoftSignature -FilePath $FilePath -Quiet:$Quiet)
}
