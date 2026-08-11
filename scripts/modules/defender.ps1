# ============================================================
# scanner 모듈: Windows Defender 상태
# ============================================================

function Get-DefenderFacts {
    try {
        $def = Get-MpComputerStatus -ErrorAction Stop
    } catch {
        Add-CollectionStatus -SourceId 'defender' -Label 'Windows Defender 상태' `
            -Status 'unavailable' -Required $true -Detail $_.Exception.Message
        return [ordered]@{}
    }
    if (-not $def) {
        Add-CollectionStatus -SourceId 'defender' -Label 'Windows Defender 상태' `
            -Status 'unavailable' -Required $true `
            -Detail 'Get-MpComputerStatus가 데이터를 반환하지 않았습니다.'
        return [ordered]@{}
    }
    Add-CollectionStatus -SourceId 'defender' -Label 'Windows Defender 상태' -Status 'ok' -Required $true

    $daysSinceDef = if ($def.AntivirusSignatureLastUpdated) {
        [math]::Round(((Get-Date) - $def.AntivirusSignatureLastUpdated).TotalDays, 0)
    } else { 999 }

    return [ordered]@{
        realtimeEnabled = [bool]$def.RealTimeProtectionEnabled
        antivirusEnabled = [bool]$def.AntivirusEnabled
        lastQuickScan = if ($def.QuickScanEndTime) { $def.QuickScanEndTime.ToString('yyyy-MM-dd HH:mm') } else { '없음' }
        lastFullScan = if ($def.FullScanEndTime) { $def.FullScanEndTime.ToString('yyyy-MM-dd HH:mm') } else { '없음' }
        signatureLastUpdated = if ($def.AntivirusSignatureLastUpdated) { $def.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd') } else { '없음' }
        signatureDaysOld = $daysSinceDef
    }
}
