#!/usr/bin/osascript -l JavaScript
ObjC.import("Foundation");

function unwrap(v) { return ObjC.unwrap(v); }
function env(name, fallback) {
  const v = $.NSProcessInfo.processInfo.environment.objectForKey(name);
  return v ? unwrap(v) : fallback;
}
function readText(path) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return s ? unwrap(s) : "";
}
function writeText(path, text) {
  $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}
function esc(v) {
  return String(v == null ? "" : v).replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;" }[c]));
}
function table(rows, fields) {
  if (!rows || !rows.length) return "<p class='muted'>표시할 항목이 없습니다.</p>";
  return `<table><thead><tr>${fields.map(f => `<th>${esc(f)}</th>`).join("")}</tr></thead><tbody>` +
    rows.map(r => `<tr class='risk-${esc(r.risk || "")}'>${fields.map(f => `<td>${esc(r[f])}</td>`).join("")}</tr>`).join("") +
    "</tbody></table>";
}
const project = env("PCH_PROJECT_DIR", ".");
const scanPath = env("PCH_SCAN", project + "/scan_result.json");
const outputPath = env("PCH_REPORT_OUTPUT", project + "/검사결과.html");
const scan = JSON.parse(readText(scanPath));
if (!scan.summary) throw new Error("scan_result.json에 summary가 없습니다.");
const overall = scan.summary.overall || "safe";
const icon = { safe: "🟢", warning: "🟡", danger: "🔴" }[overall] || "⚪";
const findings = (scan.findings || []).filter(f => f.level === "danger" || f.level === "warning");
const actions = overall === "danger"
  ? ["의심 항목을 바로 삭제하지 말고 프로그램 이름과 경로를 확인하세요.", "백신으로 전체 검사를 실행하세요.", "민감한 브라우저 세션을 닫은 뒤 조사하세요."]
  : overall === "warning"
    ? ["확인 항목의 프로그램 이름, 게시자, 설치일을 대조하세요.", "알 수 없는 항목은 검색과 VirusTotal 리포트 링크로 맥락을 확인하세요.", "정밀 검사를 실행해 유휴 CPU 사용량을 확인하세요."]
    : ["즉시 조치가 필요한 항목이 보이지 않습니다.", "보안 업데이트를 최신 상태로 유지하세요.", "느림이나 팬 소음이 계속되면 정밀 검사를 실행하세요."];
const css = "body{font-family:-apple-system,Segoe UI,Apple SD Gothic Neo,Malgun Gothic,sans-serif;background:#f4f6fb;color:#1f2937;margin:0;line-height:1.6}.container{max-width:1180px;margin:auto;padding:24px}.verdict,.panel,.card,table{background:white;border-radius:10px;box-shadow:0 1px 3px rgba(0,0,0,.06)}.verdict{display:flex;gap:18px;align-items:center;padding:24px;border-left:8px solid #9ca3af}.verdict.danger{border-color:#ef4444}.verdict.warning{border-color:#f59e0b}.verdict.safe{border-color:#10b981}.icon{font-size:48px}.big{font-size:24px;font-weight:700}.meta,.muted{color:#6b7280}.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin:18px 0}.card{padding:18px}.count{font-size:32px;font-weight:700}.panel{padding:18px 20px;margin:18px 0}.share{background:#fff7ed;color:#9a3412;padding:10px;border-radius:6px;margin-top:10px}.finding{padding:12px;margin:8px 0;border-left:4px solid #e5e7eb;background:#fff}.finding.danger{border-color:#ef4444;background:#fef2f2}.finding.warning{border-color:#f59e0b;background:#fffbeb}table{width:100%;border-collapse:collapse;margin:10px 0}th{background:#f3f4f6;text-align:left}th,td{padding:8px;border-top:1px solid #e5e7eb;font-size:13px;vertical-align:top}";
const s = scan.sections || {};
const html = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>PC 건강검진 결과</title><style>${css}</style></head><body><div class="container">
<h1>🩺 PC 건강검진 결과</h1>
<div class="meta">${esc(scan.computerName)} / ${esc(scan.userName)} · ${esc(scan.osVersion)} · 검사 시각: ${esc(scan.scannedAt)}</div>
<div class="verdict ${esc(overall)}"><div class="icon">${icon}</div><div><div class="big">${esc(scan.summary.message)}</div><div>위험 ${esc(scan.summary.dangerCount)}건 · 확인 ${esc(scan.summary.warningCount)}건</div></div></div>
<div class="panel"><h2>다음 행동</h2><ol>${actions.map(a => `<li>${esc(a)}</li>`).join("")}</ol><div class="share">도움을 요청하려고 리포트를 공유할 때는 PC 이름, 사용자 이름, 경로에 포함된 개인 정보를 먼저 가리세요.</div></div>
<div class="cards"><div class="card"><div class="count">${esc(scan.summary.dangerCount)}</div><div>위험 항목</div></div><div class="card"><div class="count">${esc(scan.summary.warningCount)}</div><div>확인 필요</div></div><div class="card"><div class="count">${(scan.findings || []).filter(f => f.level === "safe").length}</div><div>정상 확인</div></div></div>
<h2>주요 발견 사항</h2>${findings.length ? findings.map(f => `<div class="finding ${esc(f.level)}"><b>${esc(f.title)}</b><br>${esc(f.detail)}</div>`).join("") : "<p class='muted'>주의가 필요한 항목이 발견되지 않았습니다.</p>"}
<h2>CPU 사용 상위 프로세스</h2>${table(s.cpu || [], ["risk","name","pid_","cpu","memoryMB","note","path"])}
<h2>외부 네트워크 연결</h2>${table(s.network || [], ["risk","process","remoteAddress","remotePort","note","path"])}
<h2>열린 포트</h2>${table(s.listeningPorts || [], ["risk","port","process","note","path"])}
<h2>자동 실행 종합 분석</h2>${table(s.autoruns || [], ["risk","category","entry","verified","note","image"])}
<h2>최근 설치 프로그램</h2>${table(s.recentInstalls || [], ["risk","installDate","name","publisher","note"])}
<div class="meta">PC 건강검진 v0.3 · 생성 시각 ${new Date().toLocaleString()}</div>
</div></body></html>`;
writeText(outputPath, html);
console.log("HTML 리포트 생성: " + outputPath);
