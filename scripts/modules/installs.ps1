# ============================================================
# scanner 모듈: 최근 30일 설치 프로그램
# ============================================================

function Get-RecentInstallFacts {
    param([int]$Days = 30)

    $installed = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*,
                                  HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* |
        Where-Object { $_.DisplayName -and $_.InstallDate }

    $threshold = (Get-Date).AddDays(-$Days)
    $result = @()
    foreach ($i in $installed) {
        try {
            $d = [datetime]::ParseExact($i.InstallDate, 'yyyyMMdd', $null)
            if ($d -gt $threshold) {
                $result += [ordered]@{
                    installDate = $d.ToString('yyyy-MM-dd')
                    name = $i.DisplayName
                    publisher = $i.Publisher
                }
            }
        } catch {}
    }
    return @($result | Sort-Object installDate -Descending)
}
