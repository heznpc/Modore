# ============================================================
# scanner 모듈: Windows Defender 상태
# ============================================================

function Get-DefenderFacts {
    $def = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if (-not $def) { return [ordered]@{} }

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
