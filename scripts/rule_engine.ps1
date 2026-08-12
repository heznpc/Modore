# Modore - PowerShell rule engine (runtime, no Python required)
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Raw,
    [string]$Rules = "$PSScriptRoot\..\rules",
    [string]$Whitelist = "$PSScriptRoot\..\data\whitelist.json",
    [string]$Output = "$PSScriptRoot\..\scan_result.json"
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\collection-status.ps1"
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

function ConvertTo-NumberOrNull($Value) {
    # Fail soft on non-numeric input (canonical: Python try/except and JS NaN
    # both yield "no match"); a raw [double] cast under $ErrorActionPreference =
    # 'Stop' would otherwise abort the whole scan on one malformed fact.
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $null
}

function Test-Condition($Operator, $Expected, $Actual) {
    if ($Operator -eq 'exists') {
        if ([bool]$Expected) { return $null -ne $Actual }
        return $null -eq $Actual
    }
    if ($null -eq $Actual) { return $false }
    switch ($Operator) {
        'equals' { return $Actual -ceq $Expected }
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
        'gte' { $a = ConvertTo-NumberOrNull $Actual; $e = ConvertTo-NumberOrNull $Expected; if ($null -eq $a -or $null -eq $e) { return $false }; return $a -ge $e }
        'gt'  { $a = ConvertTo-NumberOrNull $Actual; $e = ConvertTo-NumberOrNull $Expected; if ($null -eq $a -or $null -eq $e) { return $false }; return $a -gt $e }
        'lte' { $a = ConvertTo-NumberOrNull $Actual; $e = ConvertTo-NumberOrNull $Expected; if ($null -eq $a -or $null -eq $e) { return $false }; return $a -le $e }
        'lt'  { $a = ConvertTo-NumberOrNull $Actual; $e = ConvertTo-NumberOrNull $Expected; if ($null -eq $a -or $null -eq $e) { return $false }; return $a -lt $e }
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
    # Canonical semantics shared with rule_engine.py / scanner_helper.jxa.js:
    # whitelist maps safe/safe-but-noisy -> safe and safe-but-concerning -> info;
    # the process name is looked up with and without extension; notes accumulate,
    # dedupe and join with " / " with a default when nothing matched.
    $risk = 'unknown'
    $notes = New-Object System.Collections.Generic.List[string]
    $findings = @()

    if ($Category -eq 'process') {
        $name = [string](Get-Field $Fact 'name')
        if ($name) {
            $lower = $name.ToLowerInvariant()
            $base = [IO.Path]::GetFileNameWithoutExtension($name).ToLowerInvariant()
            $info = $null
            foreach ($k in @($lower, $base)) {
                if ($WhitelistIndex.ContainsKey($k)) { $info = $WhitelistIndex[$k]; break }
            }
            if ($null -ne $info) {
                $stripped = ("$($info.vendor) - $($info.desc)").Trim(' ', '-')
                if ($info.risk -eq 'safe') { $risk = 'safe'; [void]$notes.Add($stripped) }
                elseif ($info.risk -eq 'safe-but-noisy') { $risk = 'safe'; [void]$notes.Add("$($info.desc) (가끔 CPU 많이 씀)") }
                elseif ($info.risk -eq 'safe-but-concerning') { $risk = 'info'; [void]$notes.Add($stripped) }
            }
        }
    }

    foreach ($rule in @($RulesByCategory[$Category])) {
        if (-not (Test-RuleMatches $rule $Fact)) { continue }
        $then = $rule.then
        $newRisk = [string]$then.risk
        $risk = Merge-Risk $risk $newRisk
        if ($then.note) {
            $rendered = Format-Template ([string]$then.note) $Fact
            if (-not $notes.Contains($rendered)) { [void]$notes.Add($rendered) }
        }
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
    $noteText = if ($notes.Count -gt 0) { [string]::Join(' / ', $notes) } else { '처음 보는 프로그램 - 확인 필요' }
    return @{ risk = $risk; note = $noteText; findings = $findings }
}

$rawObj = Read-JsonFile $Raw
$whitelistObj = Read-JsonFile $Whitelist
$wlIndex = Build-WhitelistIndex $whitelistObj
$rulesByCategory = @{}
foreach ($cat in $CategoryFiles.Keys) {
    $rulePath = Join-Path $Rules $CategoryFiles[$cat]
    $loaded = Read-JsonFile $rulePath
    $rulesByCategory[$cat] = @(if ($null -ne $loaded) { $loaded })
    if ($env:PCH_RULE_ENGINE_DEBUG) {
        $loadedType = if ($null -eq $loaded) { '<null>' } else { $loaded.GetType().Name }
        Write-Host "DBG $cat path=$rulePath exists=$(Test-Path $rulePath) loadedType=$loadedType count=$($rulesByCategory[$cat].Count)"
    }
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
    backgroundCpu = 'process'
    network = 'network'
    listeningPorts = 'process'
    autoruns = 'autoruns'
    recentInstalls = 'installs'
}

# 한 프로세스가 cpu(시점 스냅샷)와 backgroundCpu(정밀검사의 관측 구간 집계)
# 양쪽에 등장할 수 있다. 이름 패턴 규칙(채굴기 등)은 두 섹션에서 각각 독립적으로
# 발동해 같은 프로세스를 findings에 두 번 세므로, finding을 중복 제거한다
# (scanner_helper.jxa.js의 applyRules와 동일한 계약). 다만 식별자는 pid_가 아니라
# path를 우선한다: backgroundCpu는 5분 구간을 이름 단위로 집계해 pid_를 아예
# 갖지 않는데(여러 PID가 왔다 갔다 할 수 있어 특정 PID 하나가 대표성이 없다),
# cpu 섹션은 시점 스냅샷이라 매번 pid_가 있다 -- pid_로만 매칭하면 같은 실행
# 파일이 두 섹션에서 겹쳐도 절대 같은 키가 되지 않아 중복 제거가 무력화된다.
# path는 두 섹션 모두에서 Get-Process.Path를 그대로 옮긴 값이라 안정적으로 겹친다.
$seenFindingKeys = New-Object System.Collections.Generic.HashSet[string]
function Get-FindingDedupeKey($Finding, $Fact) {
    $identity = ''
    if ($null -ne $Fact) {
        $pathField = Get-Field $Fact 'path'
        if (-not [string]::IsNullOrWhiteSpace([string]$pathField)) {
            $identity = 'path:' + [string]$pathField
        } else {
            $pidField = Get-Field $Fact 'pid_'
            if ($null -ne $pidField) {
                $identity = 'pid:' + [string]$pidField
            } else {
                $nameField = Get-Field $Fact 'name'
                if (-not [string]::IsNullOrWhiteSpace([string]$nameField)) {
                    $identity = 'name:' + [string]$nameField
                }
            }
        }
    }
    return ([string]$Finding.level) + [char]0 + ([string]$Finding.category) + [char]0 + ([string]$Finding.title) + [char]0 + $identity
}
foreach ($existing in $result.findings) {
    [void]$seenFindingKeys.Add((Get-FindingDedupeKey $existing $null))
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
            foreach ($finding in $cls.findings) {
                if ($seenFindingKeys.Add((Get-FindingDedupeKey $finding $fact))) {
                    $result.findings.Add($finding)
                }
            }
            $cleaned.Add($fact)
        }
        $outSections[$name] = $cleaned.ToArray()
    } elseif ($name -in @('defender','macosSecurity')) {
        $cls = Classify-Fact $facts 'defender' $rulesByCategory $wlIndex
        foreach ($finding in $cls.findings) {
            if ($seenFindingKeys.Add((Get-FindingDedupeKey $finding $facts))) {
                $result.findings.Add($finding)
            }
        }
        $outSections[$name] = $facts
    } else {
        $outSections[$name] = $facts
    }
}

$result.sections = $outSections
$result.findings = $result.findings.ToArray()
$danger = @($result.findings | Where-Object { $_.level -eq 'danger' }).Count
$warning = @($result.findings | Where-Object { $_.level -eq 'warning' }).Count

# 수집 완전성은 findings 개수와 별개다 — required 수집기가 하나라도 실패하면
# danger/warning이 0건이어도 safe라고 말하지 않는다. "안 봤다"와 "봤는데
# 괜찮다"를 절대 같은 결과로 만들지 않는 게 이 계층의 유일한 목적이다.
$collectionSummary = Get-CollectionCompleteness $rawObj.collection
$result.collection = $collectionSummary

$overall = if ($danger -gt 0) { 'danger' }
    elseif ($warning -gt 0) { 'warning' }
    elseif (-not $collectionSummary.complete) { 'incomplete' }
    else { 'safe' }

$msg = if ($danger -gt 0) {
    "긴급 확인 필요: $danger 건의 위험 신호가 발견되었습니다."
} elseif ($warning -gt 0) {
    "확인 권장: $warning 건의 항목을 살펴보세요."
} elseif (-not $collectionSummary.complete) {
    $failedRequired = @($collectionSummary.issues | Where-Object { $_.required })
    $names = ($failedRequired | ForEach-Object { $_.label }) -join ', '
    "일부 필수 검사를 완료하지 못했습니다 ($names). 이 결과를 안전하다는 뜻으로 해석하지 마세요."
} else {
    '특별한 이상 징후가 발견되지 않았습니다.'
}
$result.summary = [ordered]@{
    overall = $overall
    dangerCount = $danger
    warningCount = $warning
    collectionComplete = $collectionSummary.complete
    message = $msg
}

$json = $result | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($Output, $json, [Text.UTF8Encoding]::new($true))
Write-Host "규칙 엔진 완료: $Output"
Write-Host "  위험: $danger / 확인: $warning"
