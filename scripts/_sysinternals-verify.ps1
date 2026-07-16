# ============================================================
# PC 건강검진 - Sysinternals 다운로드 검증 공통 모듈
#
# 왜: sigcheck.exe / autorunsc.exe는 https://live.sysinternals.com/
# 에서 다운로드한 직후 실행되므로, TLS만 신뢰하면 CDN/DNS 침해가
# 곧바로 임의 코드 실행으로 이어진다. Authenticode 서명을 추가로
# 강제해 트러스트 루트를 Microsoft 코드사이닝 인증서까지 끌어내림.
# ============================================================

# 변경 시: cert subject 패턴이 Microsoft 측에서 바뀌면 여기 한 곳만 갱신.
# Anchored regex: ',' 또는 문자열 시작 뒤에 정확히 'O=Microsoft Corporation' 다음에
# ',' 또는 문자열 끝. unanchored 매칭으로 인한 'OU=O=Microsoft Corporation evil' 같은
# 우회를 차단. -cmatch (case-sensitive)로 'o=microsoft corporation' 같은 변종도 거부.
$script:MicrosoftSignerPattern = '(^|,\s*)O=Microsoft Corporation(\s*,|$)'
$script:ValidSignatureStatus = 'Valid'
# Sentinel: 헬퍼 파일이 이 변수의 존재로 dot-source 여부를 판단함. 이름 충돌
# 가능한 함수명 (Get-Command) 대신 사용해 user PS profile의 동일명 함수에 속지 않음.
$script:SysinternalsVerifyLoaded = $true

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
    # -cmatch: case-sensitive. Microsoft cert subject는 표준 X.500 대문자 RDN을
    # 사용하므로 'o=microsoft corporation' 같은 변종은 신뢰 못 함.
    $okSigner = $sig.SignerCertificate -and ($sig.SignerCertificate.Subject -cmatch $script:MicrosoftSignerPattern)

    if ($okStatus -and $okSigner) { return $true }

    # 검증 실패: 임의 코드 실행을 막기 위해 즉시 삭제.
    # ErrorAction Stop으로 삭제 실패(파일 잠김 등)를 표면화 — 무시하면 변조된
    # 캐시 파일이 디스크에 남아 다음 실행에서 같은 무한 재실패 루프에 빠짐.
    $deleteFailed = $false
    try {
        Remove-Item -Path $FilePath -Force -ErrorAction Stop
    } catch {
        $deleteFailed = $true
        if (-not $Quiet) {
            Write-Host "" -ForegroundColor Red
            Write-Host " 경고: 검증 실패 파일을 삭제하지 못함 ($FilePath): $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "        파일이 다른 프로세스에 잠겨 있을 수 있음. 수동 삭제 권장." -ForegroundColor Yellow
        }
    }
    if (-not $Quiet -and -not $deleteFailed) {
        $reason = if (-not $okStatus) { "서명 상태=$($sig.Status)" } else { "서명자=$($sig.SignerCertificate.Subject)" }
        Write-Host " 실패: Microsoft 서명 검증 거부 ($reason)" -ForegroundColor Red
    }
    return $false
}

function Test-CachedSysinternalsBinary {
    <#
    .SYNOPSIS
      디스크에 캐시된 sysinternals 바이너리가 (1) 존재하고 (2) Microsoft
      Authenticode 서명을 통과하는지 확인.

    .DESCRIPTION
      매 실행마다 검증해야 하는 이유: pc-health-check는 *다른 user-mode 악성코드의
      존재를 전제*로 하는 진단 도구. 캐시된 .exe가 변조됐을 시나리오를 위협 모델에
      포함하지 않으면, pc-health-check 자체가 그 코드를 신뢰 실행하는 launcher가 됨.

      반환 객체 형태로 result + reason을 같이 돌려줘서 호출자가 사용자에게 의미
      있는 메시지를 띄울 수 있게 함. (이전 버전은 단순 bool이었으나, Assert가
      검증 실패 시 파일을 삭제했기 때문에 호출자가 Test-Path로 cache-hit-failure를
      재구별할 수 없었음 — 메시지가 dead code였음.)
    .OUTPUTS
      [hashtable] @{ ok=<bool>; reason=<string|null> }
        reason values:
          - "missing"  : 파일이 처음부터 없었음 (첫 실행 또는 청소된 환경)
          - "tampered" : 파일은 있었으나 서명 검증 실패 → Assert가 삭제함
          - $null      : ok=$true 인 경우
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [switch]$Quiet
    )

    if (-not (Test-Path $FilePath)) {
        return @{ ok = $false; reason = 'missing' }
    }
    if (Assert-MicrosoftSignature -FilePath $FilePath -Quiet:$Quiet) {
        return @{ ok = $true; reason = $null }
    }
    return @{ ok = $false; reason = 'tampered' }
}
