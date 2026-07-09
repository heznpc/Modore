# PC 건강검진 - PowerShell rule engine (runtime, no Python required)
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Raw,
    [string]$Rules = "$PSScriptRoot\..\rules",
    [string]$Whitelist = "$PSScriptRoot\..\data\whitelist.json",
    [string]$Output = "$PSScriptRoot\..\scan_result.json"
)

$ErrorActionPreference = 'Stop'
$RiskPriority = @{ danger = 4; warning = 3; unknown = 2; safe = 1; info = 0 }
$CategoryFiles = @{
    process = 'process.json'
    network = 'network.json'
    autoruns = 'autoruns.json'
    defender = 'defender.json'
    installs = 'installs.json'
}

function Read-JsonFile($Path) {
    if (-not (Test-Path $Path)) { return $null }
    return Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-Field($Object, [string]$Path) {
    $cur = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) {
            $cur = $cur[$part]
        } else {
            $prop = $cur.PSObject.Properties[$part]
            if ($null -eq $prop) { return $null }
            $cur = $prop.Value
        }
    }
    return $cur
}

function Split-ConditionKey([string]$Key) {
    $ops = @('iregex','regex','contains','startswith','exists','gte','gt','lte','lt','equals','in')
    foreach ($op in $ops) {
        $suffix = ".$op"
        if ($Key.EndsWith($suffix)) {
            return @{ path = $Key.Substring(0, $Key.Length - $suffix.Length); op = $op }
        }
    }
    return @{ path = $Key; op = 'equals' }
}

function Test-Condition($Operator, $Expected, $Actual) {
    if ($Operator -eq 'exists') {
        if ([bool]$Expected) { return $null -ne $Actual }
        return $null -eq $Actual
    }
    if ($null -eq $Actual) { return $false }
    switch ($Operator) {
        'equals' { return $Actual -eq $Expected }
        'iregex' { return [regex]::IsMatch([string]$Actual, [string]$Expected, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
        'regex' { return [regex]::IsMatch([string]$Actual, [string]$Expected) }
        'contains' { return ([string]$Actual).Contains([string]$Expected) }
        'startswith' { return ([string]$Actual).StartsWith([string]$Expected) }
        'in' {
            foreach ($item in @($Expected)) {
                if ($Actual -eq $item) { return $true }
            }
            return $false
        }
        'gte' { return ([double]$Actual) -ge ([double]$Expected) }
        'gt' { return ([double]$Actual) -gt ([double]$Expected) }
        'lte' { return ([double]$Actual) -le ([double]$Expected) }
        'lt' { return ([double]$Actual) -lt ([double]$Expected) }
    }
    return $false
}

function Format-Template([string]$Template, $Fact) {
    return [regex]::Replace($Template, '\{([^}]+)\}', {
        param($m)
        $v = Get-Field $Fact $m.Groups[1].Value
        if ($null -eq $v) { return '?' }
        return [string]$v
    })
}

function Merge-Risk([string]$Current, [string]$New) {
    if ($Current -eq 'unknown') { return $New }
    if ($RiskPriority[$New] -gt $RiskPriority[$Current]) { return $New }
    return $Current
}

function Build-WhitelistIndex($WhitelistObject) {
    $idx = @{}
    foreach ($cat in @('system','browser','korean_common','banking_security','dev_tools','hardware','cloud')) {
        $bucket = $WhitelistObject.PSObject.Properties[$cat]
        if ($null -eq $bucket) { continue }
        foreach ($entry in $bucket.Value.PSObject.Properties) {
            if ($entry.Name.StartsWith('_')) { continue }
            $idx[$entry.Name.ToLowerInvariant()] = @{
                vendor = $entry.Value.vendor
                desc = $entry.Value.desc
                risk = $entry.Value.risk
                wl_category = $cat
            }
        }
    }
    return $idx
}

function Test-RuleMatches($Rule, $Fact) {
    foreach ($cond in $Rule.when.PSObject.Properties) {
        $parsed = Split-ConditionKey $cond.Name
        $actual = Get-Field $Fact $parsed.path
        if (-not (Test-Condition $parsed.op $cond.Value $actual)) { return $false }
    }
    return $true
}

function Classify-Fact($Fact, [string]$Category, $RulesByCategory, $WhitelistIndex) {
    $risk = 'unknown'
    $note = ''
    $findings = @()

    if ($Category -eq 'process') {
        $name = [string](Get-Field $Fact 'name')
        if ($name) {
            $key = [IO.Path]::GetFileNameWithoutExtension($name).ToLowerInvariant()
            if ($WhitelistIndex.ContainsKey($key)) {
                $w = $WhitelistIndex[$key]
                $risk = if ($w.risk -eq 'safe') { 'safe' } else { 'info' }
                $note = "$($w.vendor) - $($w.desc)"
            }
        }
    }

    foreach ($rule in @($RulesByCategory[$Category])) {
        if (-not (Test-RuleMatches $rule $Fact)) { continue }
        $then = $rule.then
        $newRisk = [string]$then.risk
        $risk = Merge-Risk $risk $newRisk
        if ($then.note) { $note = Format-Template ([string]$then.note) $Fact }
        if ($then.finding) {
            $f = $then.finding
            $findings += [ordered]@{
                level = $newRisk
                category = [string]$f.category
                title = Format-Template ([string]$f.title) $Fact
                detail = Format-Template ([string]$f.detail) $Fact
            }
        }
    }
    return @{ risk = $risk; note = $note; findings = $findings }
}

$rawObj = Read-JsonFile $Raw
$whitelistObj = Read-JsonFile $Whitelist
$wlIndex = Build-WhitelistIndex $whitelistObj
$rulesByCategory = @{}
foreach ($cat in $CategoryFiles.Keys) {
    $rulesByCategory[$cat] = @(Read-JsonFile (Join-Path $Rules $CategoryFiles[$cat]))
}

$result = [ordered]@{}
foreach ($p in $rawObj.PSObject.Properties) {
    if ($p.Name -ne 'sections') { $result[$p.Name] = $p.Value }
}
if (-not $result.Contains('findings') -or $null -eq $result.findings) { $result.findings = @() }
$findings = [System.Collections.Generic.List[object]]::new()
foreach ($finding in @($result.findings)) {
    $findings.Add($finding)
}
$result.findings = $findings
$outSections = [ordered]@{}
$sectionToCategory = @{
    cpu = 'process'
    network = 'network'
    listeningPorts = 'process'
    autoruns = 'autoruns'
    recentInstalls = 'installs'
}

foreach ($sectionProp in $rawObj.sections.PSObject.Properties) {
    $name = $sectionProp.Name
    $facts = $sectionProp.Value
    if ($facts -is [array]) {
        $category = if ($sectionToCategory.ContainsKey($name)) { $sectionToCategory[$name] } else { 'process' }
        $cleaned = [System.Collections.Generic.List[object]]::new()
        foreach ($fact in @($facts)) {
            $cls = Classify-Fact $fact $category $rulesByCategory $wlIndex
            $fact | Add-Member -NotePropertyName risk -NotePropertyValue $cls.risk -Force
            $fact | Add-Member -NotePropertyName note -NotePropertyValue $cls.note -Force
            foreach ($finding in $cls.findings) { $result.findings.Add($finding) }
            $cleaned.Add($fact)
        }
        $outSections[$name] = $cleaned.ToArray()
    } elseif ($name -in @('defender','macosSecurity')) {
        $cls = Classify-Fact $facts 'defender' $rulesByCategory $wlIndex
        foreach ($finding in $cls.findings) { $result.findings.Add($finding) }
        $outSections[$name] = $facts
    } else {
        $outSections[$name] = $facts
    }
}

$result.sections = $outSections
$result.findings = $result.findings.ToArray()
$danger = @($result.findings | Where-Object { $_.level -eq 'danger' }).Count
$warning = @($result.findings | Where-Object { $_.level -eq 'warning' }).Count
$overall = if ($danger -gt 0) { 'danger' } elseif ($warning -gt 0) { 'warning' } else { 'safe' }
$msg = if ($danger -gt 0) { "긴급 확인 필요: $danger 건의 위험 신호가 발견되었습니다." } elseif ($warning -gt 0) { "확인 권장: $warning 건의 항목을 살펴보세요." } else { '특별한 이상 징후가 발견되지 않았습니다.' }
$result.summary = [ordered]@{
    overall = $overall
    dangerCount = $danger
    warningCount = $warning
    message = $msg
}

$json = $result | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($Output, $json, [Text.UTF8Encoding]::new($true))
Write-Host "규칙 엔진 완료: $Output"
Write-Host "  위험: $danger / 확인: $warning"
