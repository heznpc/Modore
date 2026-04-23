# ============================================================
# scanner 모듈: 자동 실행 (레지스트리 Run 키 + Autorunsc + 예약 작업)
# ============================================================

function Get-StartupFacts {
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    $result = @()
    foreach ($key in $runKeys) {
        if (Test-Path $key) {
            $items = Get-ItemProperty -Path $key
            $items.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
                $result += [ordered]@{
                    location = $key
                    name = $_.Name
                    command = [string]$_.Value
                    launchString = [string]$_.Value
                }
            }
        }
    }
    return @($result)
}

function Get-AutorunscFacts {
    param(
        [bool]$UseVt = $false
    )

    $autorunItems = Invoke-Autorunsc -HideMicrosoftSigned -VerifySignatures
    $result = @()
    if (-not $autorunItems) { return @() }

    foreach ($item in $autorunItems) {
        if ([string]::IsNullOrWhiteSpace($item.image)) { continue }
        $displayName = if ([string]::IsNullOrWhiteSpace($item.entry)) {
            if (-not [string]::IsNullOrWhiteSpace($item.description)) { $item.description }
            elseif ($item.image) { [System.IO.Path]::GetFileName($item.image) }
            else { '(이름 없음)' }
        } else { $item.entry }

        $vtResult = $null
        $image = $item.image
        if ($UseVt -and $item.sha256 -and (-not $item.verified)) {
            $cacheKey = "file:$($item.sha256.ToLower())"
            $cached = Get-CachedVt $cacheKey
            if ($null -ne $cached) {
                $vtResult = $cached
            } elseif (Test-Path $image) {
                $vtResult = Get-VtFileReputation -FilePath $image
            }
        }
        $result += [ordered]@{
            category = $item.category
            entry = $displayName
            image = $item.image
            signer = $item.signer
            verified = [bool]$item.verified
            launchString = $item.launchString
            sha256 = $item.sha256
            vt = $vtResult
        }
    }
    return @($result)
}

function Get-ScheduledTaskFacts {
    $tasks = Get-ScheduledTask |
        Where-Object { $_.TaskPath -notmatch '^\\Microsoft\\' -and $_.State -ne 'Disabled' }

    $result = foreach ($t in $tasks) {
        $exe = ($t.Actions | Select-Object -First 1).Execute
        $args_ = ($t.Actions | Select-Object -First 1).Arguments
        [ordered]@{
            name = $t.TaskName
            path = $t.TaskPath
            state = [string]$t.State
            execute = $exe
            arguments = $args_
            launchString = if ($args_) { "$exe $args_" } else { $exe }
        }
    }
    return @($result)
}
