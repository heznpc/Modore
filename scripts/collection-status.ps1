# ============================================================
# Modore - Windows 수집 완전성 계층
#
# macOS scanner.sh의 record_collection_status와 동일한 계약: 각 수집기가
# 자신의 성공/실패를 명시적으로 보고한다. "값이 비었다"와 "수집이 실패했다"를
# 절대 같은 신호로 만들지 않는다 — 전자는 정상 결과(예: 열린 포트 0개), 후자는
# 그 수집기가 낸 판정 전부를 신뢰할 수 없다는 뜻이다.
#
# scanner.ps1이 이 목록을 raw_facts.json의 collection 필드로 그대로 저장하고,
# rule_engine.ps1(판정 주체)이 Get-CollectionCompleteness로 집계해 danger/
# warning보다 낮고 safe보다는 위인 incomplete 상태를 매긴다.
# ============================================================

$script:CollectionStatus = [System.Collections.Generic.List[object]]::new()

function Reset-CollectionStatus {
    $script:CollectionStatus = [System.Collections.Generic.List[object]]::new()
}

function Add-CollectionStatus {
    param(
        [Parameter(Mandatory)][string]$SourceId,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][ValidateSet('ok', 'permission_denied', 'unavailable', 'timed_out', 'failed')][string]$Status,
        [bool]$Required = $false,
        [string]$Detail = ''
    )
    $script:CollectionStatus.Add([ordered]@{
        id       = $SourceId
        label    = $Label
        status   = $Status
        required = $Required
        detail   = $Detail
    })
}

function Get-CollectionCompleteness {
    # rule_engine.ps1(판정 주체)에서 호출. $CollectionArray가 비어 있으면
    # macOS의 parseCollectionStatus와 동일하게 "기록이 아예 없다"를 곧
    # "완전했다"로 해석하지 않는다 — 수집 상태 추적 자체가 조용히 빠진
    # 회귀는 그 자체로 required 실패로 취급한다.
    param($CollectionArray)

    # @($x) 함정: $CollectionArray가 $null이면 @($null)은 원소 1개짜리
    # 배열(그 원소가 $null)이 되지, 빈 배열이 되지 않는다 — "collection
    # 필드 자체가 raw_facts.json에 없다"는 케이스를 놓쳐 fail-closed
    # 폴백이 발동하지 않는 채로 조용히 complete=true가 나올 뻔했다.
    # $null을 먼저 걸러내야 Count -eq 0 검사가 실제로 의미를 가진다.
    $sources = @($CollectionArray | Where-Object { $null -ne $_ })
    if ($sources.Count -eq 0) {
        $sources = @([ordered]@{
            id       = 'collector_protocol'
            label    = '검사 범위 기록'
            status   = 'failed'
            required = $true
            detail   = '수집 상태 기록이 없어 결과의 완전성을 확인할 수 없습니다.'
        })
    }

    $required = @($sources | Where-Object { $_.required })
    $incompleteRequired = @($required | Where-Object { $_.status -ne 'ok' })
    $issues = @($sources | Where-Object { $_.status -ne 'ok' })

    return [ordered]@{
        complete               = ($incompleteRequired.Count -eq 0)
        completedCount         = @($sources | Where-Object { $_.status -eq 'ok' }).Count
        sourceCount            = $sources.Count
        completedRequiredCount = @($required | Where-Object { $_.status -eq 'ok' }).Count
        requiredCount          = $required.Count
        issues                 = $issues
        sources                = $sources
    }
}
