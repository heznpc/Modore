#!/usr/bin/osascript -l JavaScript
ObjC.import("Foundation");

function unwrap(v) { return ObjC.unwrap(v); }
function env(name, fallback) {
  const v = $.NSProcessInfo.processInfo.environment.objectForKey(name);
  const value = v ? unwrap(v) : null;
  return value == null ? fallback : String(value);
}
function readText(path) {
  const handle = $.NSFileHandle.fileHandleForReadingAtPath(path);
  if (!handle) return "";
  try {
    const data = handle.readDataOfLength(32 * 1024 * 1024 + 1);
    if (Number(data.length) > 32 * 1024 * 1024) {
      throw new Error("scan_result.json 크기가 안전 상한을 초과했습니다.");
    }
    const value = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
    return value ? unwrap(value) : "";
  } finally {
    try { handle.closeFile; } catch (_) {}
  }
}
function cwd() {
  return unwrap($.NSFileManager.defaultManager.currentDirectoryPath);
}
function writeText(path, text) {
  const ok = !!$(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  if (!ok) throw new Error("리포트를 안전하게 기록하지 못했습니다: " + path);
}
function esc(v) {
  return String(v == null ? "" : v).replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;" }[c]));
}
function truthy(v) {
  return /^(1|true|yes|y)$/i.test(String(v || "").trim());
}
function urlEncode(v) {
  return encodeURIComponent(String(v == null ? "" : v));
}
function escapeRegex(v) {
  return String(v).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function mapDeep(value, mapper) {
  if (Array.isArray(value)) return value.map(v => mapDeep(v, mapper));
  if (value && typeof value === "object") {
    const out = {};
    Object.keys(value).forEach(k => { out[k] = mapDeep(value[k], mapper); });
    return out;
  }
  return mapper(value);
}
function redactString(value, userName, computerName) {
  let s = String(value);
  const home = unwrap($.NSHomeDirectory());
  const pathPrefixes = [home, userName ? "/Users/" + userName : ""].filter(Boolean);
  pathPrefixes.forEach(p => {
    s = s.replace(new RegExp(escapeRegex(p), "g"), "~");
  });
  s = s.replace(/\/Users\/[^\/\s<>"']+/g, "/Users/<redacted>");
  if (computerName) s = s.replace(new RegExp(escapeRegex(computerName), "g"), "redacted-mac");
  if (userName) s = s.replace(new RegExp(escapeRegex(userName), "g"), "redacted-user");
  return s;
}
function redactScan(input) {
  const userName = input.userName || "";
  const computerName = input.computerName || "";
  const scan = mapDeep(input, v => typeof v === "string" ? redactString(v, userName, computerName) : v);
  scan.userName = "redacted-user";
  scan.computerName = "redacted-mac";
  scan.reportMode = "redacted";
  return scan;
}
function investigateLinks(row) {
  const label = row.name || row.process || row.entry || row.remoteAddress || row.label || "";
  const links = [];
  const vtHash = (row.vt && row.vt.hash) || row.sha256 || "";
  if (vtHash) {
    links.push(`<a href="https://www.virustotal.com/gui/file/${urlEncode(vtHash)}" target="_blank">VT</a>`);
  } else if (row.remoteAddress) {
    links.push(`<a href="https://www.virustotal.com/gui/ip-address/${urlEncode(row.remoteAddress)}" target="_blank">VT IP</a>`);
  }
  if (label) {
    links.push(`<a href="https://www.google.com/search?q=${urlEncode(label + " malware")}" target="_blank">Google</a>`);
  }
  return links.length ? links.join(" · ") : "";
}
function table(rows, fields) {
  if (!rows || !rows.length) return "<p class='muted'>표시할 항목이 없습니다.</p>";
  return `<table><thead><tr>${fields.map(f => `<th>${esc(f)}</th>`).join("")}<th>조사</th></tr></thead><tbody>` +
    rows.map(r => `<tr class='risk-${esc(r.risk || "")}'>${fields.map(f => `<td>${esc(r[f])}</td>`).join("")}<td>${investigateLinks(r)}</td></tr>`).join("") +
    "</tbody></table>";
}
const project = env("PCH_PROJECT_DIR", cwd());
const scanPath = env("PCH_SCAN", project + "/scan_result.json");
const redacted = truthy(env("PCH_REDACT", ""));
const outputPath = env("PCH_REPORT_OUTPUT", project + (redacted ? "/검사결과_공유용.html" : "/검사결과.html"));
const rawScan = JSON.parse(readText(scanPath));
const scan = redacted ? redactScan(rawScan) : rawScan;
if (!scan.summary) throw new Error("scan_result.json에 summary가 없습니다.");
const overall = scan.summary.overall || "safe";
const icon = { safe: "●", warning: "●", danger: "●", incomplete: "○" }[overall] || "○";
const findings = (scan.findings || []).filter(f => f.level === "danger" || f.level === "warning");
const actions = overall === "danger"
  ? ["의심 항목을 바로 삭제하지 말고 프로그램 이름과 경로를 확인하세요.", "백신으로 전체 검사를 실행하세요.", "민감한 브라우저 세션을 닫은 뒤 조사하세요."]
  : overall === "warning"
    ? ["확인 항목의 프로그램 이름, 게시자, 설치일을 대조하세요.", "알 수 없는 항목은 검색과 VirusTotal 리포트 링크로 맥락을 확인하세요.", "정밀 검사를 실행해 유휴 CPU 사용량을 확인하세요."]
    : overall === "incomplete"
      ? ["완료하지 못한 필수 수집기를 확인하세요.", "권한 또는 시간 제한 문제를 해결한 뒤 다시 검사하세요.", "빈 결과를 정상으로 해석하지 마세요."]
      : ["현재 수집 범위에서 즉시 조치가 필요한 항목이 보이지 않습니다.", "보안 업데이트를 최신 상태로 유지하세요.", "느림이나 팬 소음이 계속되면 다시 검사하세요."];
const css = "body{font-family:-apple-system,Segoe UI,Apple SD Gothic Neo,Malgun Gothic,sans-serif;background:#f4f4f6;color:#1f1f22;margin:0;line-height:1.6}.container{max-width:1180px;margin:auto;padding:24px}.verdict,.panel,.card,table{background:white;border-radius:10px;box-shadow:0 1px 3px rgba(0,0,0,.06)}.verdict{display:flex;gap:18px;align-items:center;padding:24px;border-left:8px solid #8e8e93}.verdict.danger{border-color:#ff3b30}.verdict.warning,.verdict.incomplete,.verdict.safe{border-color:#8e8e93}.icon{font-size:48px}.big{font-size:24px;font-weight:700}.meta,.muted{color:#6e6e73}.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin:18px 0}.card{padding:18px}.count{font-size:32px;font-weight:700}.panel{padding:18px 20px;margin:18px 0}.share{background:#f2f2f7;color:#3a3a3c;padding:10px;border-radius:6px;margin-top:10px}.share.redacted{background:#f2f2f7;color:#3a3a3c}.finding{padding:12px;margin:8px 0;border-left:4px solid #d1d1d6;background:#fff}.finding.danger{border-color:#ff3b30;background:#fff2f1}.finding.warning{border-color:#8e8e93;background:#f9f9fb}table{width:100%;border-collapse:collapse;margin:10px 0}th{background:#f2f2f7;text-align:left}th,td{padding:8px;border-top:1px solid #d1d1d6;font-size:13px;vertical-align:top}";
const s = scan.sections || {};
const collection = scan.collection || {};
const collectionHtml = `<div class="panel">
  <h2>검사 범위</h2>
  <p class="muted">필수 수집기 ${esc(collection.completedRequiredCount || 0)}/${esc(collection.requiredCount || 0)}개 완료 · 전체 ${esc(collection.completedCount || 0)}/${esc(collection.sourceCount || 0)}개 완료</p>
  ${table(collection.sources || [], ["label","status","required","detail"])}
</div>`;
const storage = s.storage || {};
const storageVolume = storage.volume || {};
const accessHtml = (storage.accessIssues || []).length
  ? `<h3>Full Disk Access 확인 필요</h3>
  <p class="muted">macOS 개인정보 보호 설정 때문에 일부 개인 데이터/앱 데이터 영역을 읽지 못했을 수 있습니다. 결과가 비어 보이면 시스템 설정 &gt; 개인정보 보호 및 보안 &gt; 전체 디스크 접근 권한을 확인하세요.</p>
  ${table(storage.accessIssues || [], ["risk","kind","label","status","note","path"])}`
  : "";
const runtimeHtml = (storage.runtimeSignals || []).length
  ? `<h3>반복 생성원</h3>
  <p class="muted">공간을 지워도 다시 차게 만드는 실행 중인 브라우저, 시뮬레이터, 개발 세션 신호입니다.</p>
  ${table(storage.runtimeSignals || [], ["risk","kind","label","count","action","note"])}`
  : "";
const storageHtml = storage.volume ? `<div class="panel">
  <h2>macOS 저장공간 막대 해석</h2>
  <p class="muted">macOS는 큰 용량을 System Data, Developer, macOS 같은 이름으로 뭉뚱그려 보여줍니다. 이 표는 그 막대 뒤에 숨어 있는 캐시, 시뮬레이터, SDK, 앱 덩어리를 실제 경로 기준으로 풀어봅니다.</p>
  <div class="finding ${esc(storageVolume.risk || "safe")}"><b>${esc(storageVolume.mount || "/")}</b><br>
  남은 공간 ${esc(storageVolume.freeGB)}GB · 사용률 ${esc(storageVolume.usePercent)}% · ${esc(storageVolume.note || "")}</div>
  <h3>System Data로 숨을 수 있는 정리 후보</h3>
  ${table(storage.cleanupCandidates || [], ["risk","kind","label","sizeGB","action","note","path"])}
  ${(storage.reviewCandidates || []).length ? "<h3>삭제 전 확인</h3>" : ""}
  ${(storage.reviewCandidates || []).length ? table(storage.reviewCandidates || [], ["risk","kind","label","sizeGB","action","note","path"]) : ""}
  <h3>Developer 항목으로 뭉친 개발 도구/시뮬레이터</h3>
  ${table(storage.developerToolchains || [], ["risk","kind","label","sizeGB","action","note","path"])}
  ${(storage.applications || []).length ? "<h3>설치 앱 크기 및 제거 검토</h3>" : ""}
  ${(storage.applications || []).length ? table(storage.applications || [], ["risk","kind","label","sizeGB","action","note","path"]) : ""}
  ${(storage.simulatorDevices || []).length ? "<h3>Simulator 기기별 보존 상태</h3>" : ""}
  ${(storage.simulatorDevices || []).length ? table(storage.simulatorDevices || [], ["risk","name","runtime","state","sizeGB","protectionReason"]) : ""}
  ${runtimeHtml}
  ${accessHtml}
</div>` : "";
const shareNotice = redacted
  ? "<div class=\"share redacted\">공유용 리포트입니다. PC 이름, 사용자 이름, 홈 디렉터리 경로를 자동으로 가렸습니다. 공유 전 내용을 한 번 더 확인하세요.</div>"
  : "<div class=\"share\">도움을 요청하려고 리포트를 공유할 때는 PC 이름, 사용자 이름, 경로에 포함된 개인 정보를 먼저 가리세요.</div>";
const html = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>PC 건강검진 Mac Edition 결과</title><style>${css}</style></head><body><div class="container">
<h1>🩺 PC 건강검진 Mac Edition${redacted ? " 공유용" : ""} 결과</h1>
<div class="meta">${esc(scan.computerName)} / ${esc(scan.userName)} · ${esc(scan.osVersion)} · 검사 시각: ${esc(scan.scannedAt)}</div>
<div class="verdict ${esc(overall)}"><div class="icon">${icon}</div><div><div class="big">${esc(scan.summary.message)}</div><div>위험 ${esc(scan.summary.dangerCount)}건 · 확인 ${esc(scan.summary.warningCount)}건</div></div></div>
<div class="panel"><h2>다음 행동</h2><ol>${actions.map(a => `<li>${esc(a)}</li>`).join("")}</ol>${shareNotice}</div>
${collectionHtml}
<div class="cards"><div class="card"><div class="count">${esc(scan.summary.dangerCount)}</div><div>위험 항목</div></div><div class="card"><div class="count">${esc(scan.summary.warningCount)}</div><div>확인 필요</div></div><div class="card"><div class="count">${(scan.findings || []).filter(f => f.level === "safe").length}</div><div>정상 확인</div></div></div>
<h2>주요 발견 사항</h2>${findings.length ? findings.map(f => `<div class="finding ${esc(f.level)}"><b>${esc(f.title)}</b><br>${esc(f.detail)}</div>`).join("") : "<p class='muted'>주의가 필요한 항목이 발견되지 않았습니다.</p>"}
${storageHtml}
<h2>CPU 사용 상위 프로세스</h2>${table(s.cpu || [], ["risk","name","pid_","cpu","memoryMB","note","path"])}
<h2>외부 네트워크 연결</h2>${table(s.network || [], ["risk","process","remoteAddress","remotePort","note","path"])}
<h2>열린 포트</h2>${table(s.listeningPorts || [], ["risk","port","process","note","path"])}
<h2>자동 실행 종합 분석</h2>${table(s.autoruns || [], ["risk","category","entry","verified","note","image"])}
<h2>최근 설치 프로그램</h2>${table(s.recentInstalls || [], ["risk","installDate","name","publisher","note"])}
<div class="meta">PC 건강검진 v0.3 · 생성 시각 ${new Date().toLocaleString()}</div>
</div></body></html>`;
writeText(outputPath, html);
console.log("HTML 리포트 생성: " + outputPath);
