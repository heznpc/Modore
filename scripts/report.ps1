# Modore - PowerShell HTML report generator (runtime, no Python required)
[CmdletBinding()]
param(
    [string]$Scan = "$PSScriptRoot\..\scan_result.json",
    [string]$Output = "$PSScriptRoot\..\검사결과.html"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Scan)) {
    Write-Error "scan_result.json이 없습니다. scanner를 먼저 실행하세요: $Scan"
}
$scanObj = Get-Content $Scan -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $scanObj.summary) {
    Write-Error "scan_result.json에 summary가 없습니다. raw_facts.json이 아니라 최종 결과가 필요합니다."
}

# 이름 주의: 짧은 이름(H/U 등)은 PowerShell 내장 별칭과 충돌할 수 있다.
# 실제로 h -> Get-History가 기본 별칭으로 존재해, 과거 짧은 이름은 최상위
# 직접 호출조차 Get-History로 잘못 라우팅되어 리포트 생성 자체가 크래시했다
# (CI가 구문 검사만 하고 이 스크립트를 실행한 적이 없어 발견되지 않았다).
# 내장 별칭과 절대 겹치지 않도록 완전한 이름만 쓴다.
function HtmlEncode($Value) {
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function UrlEncode($Value) {
    return [System.Uri]::EscapeDataString([string]$Value)
}

function Get-InvestigateLinks($Row) {
    $label = ''
    foreach ($field in @('name', 'process', 'entry', 'remoteAddress')) {
        $prop = $Row.PSObject.Properties[$field]
        if ($prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            $label = [string]$prop.Value
            break
        }
    }
    $links = [System.Collections.Generic.List[string]]::new()
    $linkContext = if ([string]::IsNullOrWhiteSpace($label)) { '항목' } else { HtmlEncode $label }
    $vt = $Row.PSObject.Properties['vt']
    $sha = $Row.PSObject.Properties['sha256']
    if ($vt -and $vt.Value -and $vt.Value.PSObject.Properties['hash']) {
        $links.Add("<a href='https://www.virustotal.com/gui/file/$(UrlEncode $vt.Value.hash)' target='_blank' rel='noopener noreferrer' aria-label='VirusTotal에서 $linkContext 조사'>VT</a>")
    } elseif ($sha -and -not [string]::IsNullOrWhiteSpace([string]$sha.Value)) {
        $links.Add("<a href='https://www.virustotal.com/gui/file/$(UrlEncode $sha.Value)' target='_blank' rel='noopener noreferrer' aria-label='VirusTotal에서 $linkContext 조사'>VT</a>")
    } elseif ($Row.PSObject.Properties['remoteAddress']) {
        $links.Add("<a href='https://www.virustotal.com/gui/ip-address/$(UrlEncode $Row.remoteAddress)' target='_blank' rel='noopener noreferrer' aria-label='VirusTotal에서 $linkContext 조사'>VT IP</a>")
    }
    if (-not [string]::IsNullOrWhiteSpace($label)) {
        $links.Add("<a href='https://www.google.com/search?q=$(UrlEncode "$label malware")' target='_blank' rel='noopener noreferrer' aria-label='Google에서 $linkContext 검색'>Google</a>")
    }
    return ($links -join ' · ')
}

function Render-ListTable($Rows, [string[]]$Fields) {
    if ($null -eq $Rows -or @($Rows).Count -eq 0) { return '<p class="muted">표시할 항목이 없습니다.</p>' }
    $head = (($Fields | ForEach-Object { "<th scope=""col"">$(HtmlEncode $_)</th>" }) -join '') + '<th scope="col">조사</th>'
    $body = foreach ($row in @($Rows)) {
        $risk = if ($row.risk) { [string]$row.risk } else { '' }
        $cells = foreach ($f in $Fields) {
            $v = $row.PSObject.Properties[$f]
            if ($null -eq $v) { '<td></td>' } else { "<td>$(HtmlEncode $v.Value)</td>" }
        }
        "<tr class='risk-$risk'>$($cells -join '')<td>$(Get-InvestigateLinks $row)</td></tr>"
    }
    return "<table><thead><tr>$head</tr></thead><tbody>$($body -join '')</tbody></table>"
}

$summary = $scanObj.summary
$overall = [string]$summary.overall
$icon = @{ safe = '🟢'; warning = '🟡'; danger = '🔴'; incomplete = '⚪' }[$overall]
if (-not $icon) { $icon = '⚪' }
$findings = @($scanObj.findings | Where-Object { $_.level -in @('danger','warning') })
$actions = if ($overall -eq 'danger') {
    @('의심 항목을 바로 삭제하지 말고 프로그램 이름과 경로를 확인하세요.', 'Windows Defender 또는 사용 중인 백신으로 전체 검사를 실행하세요.', '민감한 브라우저 세션을 닫은 뒤 조사하세요.')
} elseif ($overall -eq 'warning') {
    @('확인 항목의 프로그램 이름, 게시자, 설치일을 최근 설치 내역과 대조하세요.', '알 수 없는 항목은 검색과 VirusTotal 리포트 링크로 맥락을 확인하세요.', '5분 유휴 모니터링을 아직 실행하지 않았다면 정밀 검사를 실행하세요.')
} elseif ($overall -eq 'incomplete') {
    @('아래 검사 범위에서 실패한 항목을 확인하고 원인(권한·서비스 상태)을 먼저 해결하세요.', '검사를 다시 실행해 필수 항목이 전부 완료되는지 확인하세요.', '이 결과가 완료될 때까지는 "이상 없음"으로 받아들이지 마세요.')
} else {
    @('즉시 조치가 필요한 항목이 보이지 않습니다.', '백신 정의와 운영체제 보안 업데이트를 최신 상태로 유지하세요.', 'PC가 느리거나 팬 소음이 계속되면 정밀 검사를 실행하세요.')
}
$actionHtml = ($actions | ForEach-Object { "<li>$(HtmlEncode $_)</li>" }) -join ''
$findingHtml = if ($findings.Count -eq 0) {
    '<p class="muted">주의가 필요한 항목이 발견되지 않았습니다.</p>'
} else {
    ($findings | ForEach-Object { "<div class='finding $($_.level)'><b>$(HtmlEncode $_.title)</b><br>$(HtmlEncode $_.detail)</div>" }) -join ''
}

$collection = $scanObj.collection
$collectionHtml = if ($null -eq $collection) {
    ''
} else {
    $rows = @($collection.sources | ForEach-Object {
        $ok = [string]$_.status -eq 'ok'
        $requiredTag = if ($_.required) { ' · 필수' } else { ' · 선택' }
        $badge = if ($ok) { '완료' } else { "$($_.status)$requiredTag" }
        $rowClass = if ($ok) { '' } else { 'risk-warning' }
        "<tr class='$rowClass'><td>$(HtmlEncode $_.label)</td><td>$(HtmlEncode $badge)</td><td>$(HtmlEncode $_.detail)</td></tr>"
    }) -join ''
    @"
<h2>검사 범위</h2>
<div class="panel">
<div>필수 $($collection.completedRequiredCount)/$($collection.requiredCount)건 완료 · 전체 $($collection.completedCount)/$($collection.sourceCount)건 완료</div>
<table><thead><tr><th scope="col">수집 항목</th><th scope="col">상태</th><th scope="col">상세</th></tr></thead><tbody>$rows</tbody></table>
</div>
"@
}

$sections = $scanObj.sections
$css = @'
body{font-family:-apple-system,Segoe UI,Malgun Gothic,sans-serif;background:#f4f6fb;color:#1f2937;margin:0;line-height:1.6}
.container{max-width:1180px;margin:0 auto;padding:24px}
.verdict,.panel,.card,table{background:white;border-radius:10px;box-shadow:0 1px 3px rgba(0,0,0,.06)}
.verdict{display:flex;gap:18px;align-items:center;padding:24px;border-left:8px solid #9ca3af}
.verdict.danger{border-color:#ef4444}.verdict.warning{border-color:#f59e0b}.verdict.safe{border-color:#10b981}.verdict.incomplete{border-color:#9ca3af}
.icon{font-size:48px}.big{font-size:24px;font-weight:700}.meta,.muted{color:#6b7280}
.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin:18px 0}.card{padding:18px;border-top:4px solid #e5e7eb}.count{font-size:32px;font-weight:700}
.panel{padding:18px 20px;margin:18px 0}.share{background:#fff7ed;color:#9a3412;padding:10px;border-radius:6px;margin-top:10px}
.finding{padding:12px;margin:8px 0;border-left:4px solid #e5e7eb;background:#fff}.finding.danger{border-color:#ef4444;background:#fef2f2}.finding.warning{border-color:#f59e0b;background:#fffbeb}
table{width:100%;border-collapse:collapse;margin:10px 0}th{background:#f3f4f6;text-align:left}th,td{padding:8px;border-top:1px solid #e5e7eb;font-size:13px;vertical-align:top}
a:focus-visible,button:focus-visible{outline:2px solid #2563eb;outline-offset:2px}
@media(max-width:700px){.container{overflow-x:hidden}table{display:block;overflow-x:auto;white-space:nowrap}}
'@

$html = @"
<!doctype html>
<html lang="ko">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Modore 결과</title><style>$css</style></head>
<body><main id="main"><div class="container">
<h1>🩺 Modore 결과</h1>
<div class="meta">$(HtmlEncode $scanObj.computerName) / $(HtmlEncode $scanObj.userName) · $(HtmlEncode $scanObj.osVersion) · 검사 시각: $(HtmlEncode $scanObj.scannedAt)</div>
<div class="verdict $overall"><div class="icon">$icon</div><div><div class="big">$(HtmlEncode $summary.message)</div><div>위험 $($summary.dangerCount)건 · 확인 $($summary.warningCount)건</div></div></div>
<div class="panel"><h2>다음 행동</h2><ol>$actionHtml</ol><div class="share">도움을 요청하려고 리포트를 공유할 때는 PC 이름, 사용자 이름, 경로에 포함된 개인 정보를 먼저 가리세요.</div></div>
<div class="cards"><div class="card"><div class="count">$($summary.dangerCount)</div><div>위험 항목</div></div><div class="card"><div class="count">$($summary.warningCount)</div><div>확인 필요</div></div><div class="card"><div class="count">$(@($scanObj.findings | Where-Object { $_.level -eq 'safe' }).Count)</div><div>정상 확인</div></div></div>
<h2>주요 발견 사항</h2>$findingHtml
$collectionHtml
<h2>CPU 사용 상위 프로세스</h2>$(Render-ListTable $sections.cpu @('risk','name','pid_','cpu','memoryMB','note','path'))
<h2>외부 네트워크 연결</h2>$(Render-ListTable $sections.network @('risk','process','remoteAddress','remotePort','note','path'))
<h2>열린 포트</h2>$(Render-ListTable $sections.listeningPorts @('risk','port','process','note','path'))
<h2>자동 실행 종합 분석</h2>$(Render-ListTable $sections.autoruns @('risk','category','entry','verified','note','image'))
<h2>예약 작업</h2>$(Render-ListTable $sections.scheduledTasks @('risk','name','state','execute','note'))
<h2>최근 설치 프로그램</h2>$(Render-ListTable $sections.recentInstalls @('risk','installDate','name','publisher','note'))
<div class="meta">Modore v0.3 · 생성 시각 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</div></main></body></html>
"@

[IO.File]::WriteAllText($Output, $html, [Text.UTF8Encoding]::new($false))
Write-Host "HTML 리포트 생성: $Output"
