#!/usr/bin/osascript -l JavaScript
ObjC.import("Foundation");

function unwrap(v) { return ObjC.unwrap(v); }
function env(name, fallback) {
  const v = $.NSProcessInfo.processInfo.environment.objectForKey(name);
  const value = v ? unwrap(v) : null;
  return value == null ? fallback : String(value);
}
function readText(path, maximumBytes) {
  const limit = Number(maximumBytes || (16 * 1024 * 1024));
  const handle = $.NSFileHandle.fileHandleForReadingAtPath(path);
  if (!handle) return "";
  try {
    const data = handle.readDataOfLength(limit + 1);
    if (Number(data.length) > limit) return "";
    const value = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
    return value ? unwrap(value) : "";
  } finally {
    try { handle.closeFile; } catch (_) {}
  }
}
function writeText(path, text) {
  return !!$(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}
function writeRequiredText(path, text) {
  if (!writeText(path, text)) throw new Error("검사 결과를 안전하게 기록하지 못했습니다: " + path);
}
function readJson(path, fallback, maximumBytes) {
  try { return JSON.parse(readText(path, maximumBytes)); } catch (e) { return fallback; }
}
function run(cmd) {
  const app = Application.currentApplication();
  app.includeStandardAdditions = true;
  try { return app.doShellScript(cmd); } catch (e) { return ""; }
}
function runCurlWithSecretHeader(url, apiKey) {
  if (!/^[A-Fa-f0-9]{64}$/.test(String(apiKey || ""))) return "";
  const task = $.NSTask.alloc.init;
  const input = $.NSPipe.pipe;
  const output = $.NSPipe.pipe;
  task.launchPath = "/usr/bin/curl";
  task.arguments = $(["-q", "-sS", "--max-time", "15", "--config", "-", "-w", "\\n%{http_code}", url]);
  task.standardInput = input;
  task.standardOutput = output;
  task.standardError = $.NSFileHandle.fileHandleWithNullDevice;
  try {
    task.launch;
    const config = "header = \\\"x-apikey: " + apiKey + "\\\"\nheader = \\\"accept: application/json\\\"\n";
    input.fileHandleForWriting.writeData($(config).dataUsingEncoding($.NSUTF8StringEncoding));
    input.fileHandleForWriting.closeFile;
    // Drain while curl is running so a response larger than the pipe buffer
    // cannot deadlock the producer and this synchronous JXA caller.
    const data = output.fileHandleForReading.readDataToEndOfFile;
    task.waitUntilExit;
    if (task.terminationStatus !== 0) return "";
    const text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
    return text ? unwrap(text) : "";
  } catch (e) {
    try { input.fileHandleForWriting.closeFile; } catch (_) {}
    return "";
  }
}
function tmp(name) { return readText(TMP_DIR + "/" + name); }
function basename(path) { return String(path || "").split("/").filter(Boolean).pop() || String(path || ""); }
function round1(n) { return Math.round(Number(n || 0) * 10) / 10; }
function kbToGb(kb) { return round1(Number(kb || 0) / 1048576); }
function appKbToGb(kb) { return Math.round((Number(kb || 0) / 1048576) * 10000) / 10000; }
function uniqueStorageTotal(items) {
  const roots = [];
  let total = 0;
  (items || [])
    .filter(item => item && item.measureStatus !== "timed_out" && Number(item.sizeGB || 0) > 0 && item.path)
    .slice()
    .sort((a, b) => String(a.path).length - String(b.path).length)
    .forEach(item => {
      const path = String(item.path).replace(/\/+$/, "") || "/";
      const covered = roots.some(root => path === root || path.indexOf(root + "/") === 0);
      if (!covered) {
        roots.push(path);
        total += Number(item.sizeGB || 0);
      }
    });
  return round1(total);
}
function escapeShell(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
function isLocalIp(ip) {
  if (!ip) return true;
  if (/^(127\.|10\.|192\.168\.|::1|fe80|0\.0\.0\.0)/i.test(ip)) return true;
  const m = /^172\.(\d+)\./.exec(ip);
  return !!(m && Number(m[1]) >= 16 && Number(m[1]) <= 31);
}
function shouldSkipVt(path) {
  return !path || /^\/(System|usr\/lib|usr\/sbin|usr\/libexec|usr\/bin)\//.test(path);
}
function ensureDir(path) {
  run("/bin/mkdir -p " + escapeShell(path));
}
function homeDir() { return unwrap($.NSHomeDirectory()); }
function sha256(path) {
  const out = run("/usr/bin/shasum -a 256 " + escapeShell(path) + " 2>/dev/null | /usr/bin/awk '{print $1}'");
  return /^[a-f0-9]{64}$/i.test(out.trim()) ? out.trim().toLowerCase() : "";
}
function vtLookup(config, disabled) {
  const cfg = Object.assign({}, (config || {}).virustotal || {});
  const envKey = env("VT_API_KEY", "");
  if (envKey) {
    cfg.apiKey = envKey;
  }
  const enabled = !!cfg.enabled && /^[A-Fa-f0-9]{64}$/.test(String(cfg.apiKey || "")) && !disabled;
  const cacheHours = Number(cfg.cacheHours || 48);
  const maxCalls = Number(cfg.maxCallsPerScan || 100);
  const cacheDir = homeDir() + "/Library/Caches/PC건강검진";
  const cachePath = cacheDir + "/vt-cache.json";
  ensureDir(cacheDir);
  let cache = readJson(cachePath, {}, 4 * 1024 * 1024);
  let calls = 0, lastCall = 0;
  function cached(key) {
    const entry = cache[key];
    if (!entry) return null;
    const ageHours = (Date.now() - Date.parse(entry.cachedAt || "")) / 36e5;
    if (!Number.isFinite(ageHours) || ageHours > cacheHours) {
      delete cache[key];
      return null;
    }
    return entry.result;
  }
  function setCache(key, result) {
    cache[key] = { cachedAt: new Date().toISOString(), result };
  }
  function request(path) {
    if (!enabled || calls >= maxCalls) return null;
    const since = (Date.now() - lastCall) / 1000;
    if (lastCall && since < 16) run("/bin/sleep " + String(Math.ceil(16 - since)));
    lastCall = Date.now();
    calls += 1;
    const url = "https://www.virustotal.com/api/v3/" + path;
    const out = runCurlWithSecretHeader(url, cfg.apiKey);
    if (!out) return { error: "request_failed" };
    const lines = out.split(/\r?\n/);
    const code = lines.pop();
    const body = lines.join("\n");
    if (code === "404") return { notFound: true };
    if (code !== "200") return { error: "http_" + code };
    try { return { data: JSON.parse(body).data }; } catch (e) { return { error: "api_parse" }; }
  }
  function stats(attrs) {
    const s = (attrs || {}).last_analysis_stats || {};
    return {
      malicious: Number(s.malicious || 0),
      suspicious: Number(s.suspicious || 0),
      harmless: Number(s.harmless || 0),
      undetected: Number(s.undetected || 0)
    };
  }
  return {
    get enabled() { return enabled; },
    get calls() { return calls; },
    cacheHours,
    file(path) {
      if (!enabled || !path || shouldSkipVt(path)) return null;
      const h = sha256(path);
      if (!h) return null;
      const key = "file:" + h;
      const c = cached(key);
      if (c) return c;
      const r = request("files/" + h);
      if (!r) return null;
      if (r.error) return { status: r.error, hash: h };
      if (r.notFound) {
        const result = { status: "unknown", hash: h };
        setCache(key, result);
        return result;
      }
      const st = stats((r.data || {}).attributes || {});
      const result = Object.assign({ status: "ok", hash: h }, st, { totalEngines: st.malicious + st.suspicious + st.harmless + st.undetected });
      setCache(key, result);
      return result;
    },
    ip(ip) {
      if (!enabled || !ip) return null;
      const key = "ip:" + ip;
      const c = cached(key);
      if (c) return c;
      const r = request("ip_addresses/" + ip);
      if (!r) return null;
      if (r.error) return { status: r.error, ip };
      if (r.notFound) {
        const result = { status: "unknown", ip };
        setCache(key, result);
        return result;
      }
      const attrs = (r.data || {}).attributes || {};
      const st = stats(attrs);
      const result = { status: "ok", ip, malicious: st.malicious, suspicious: st.suspicious, country: attrs.country || "", asnOwner: attrs.as_owner || "" };
      setCache(key, result);
      return result;
    },
    save() {
      if (enabled) writeText(cachePath, JSON.stringify(cache, null, 2));
    }
  };
}

function get(obj, path) {
  return String(path).split(".").reduce((cur, k) => (cur == null ? undefined : cur[k]), obj);
}
function format(tmpl, fact) {
  return String(tmpl || "").replace(/\{([^}]+)\}/g, (_, key) => {
    const v = get(fact, key);
    return v == null ? "?" : String(v);
  });
}
function splitCond(key) {
  const ops = ["iregex","regex","contains","startswith","exists","gte","gt","lte","lt","equals","in"];
  for (const op of ops) {
    const suffix = "." + op;
    if (key.endsWith(suffix)) return { path: key.slice(0, -suffix.length), op };
  }
  return { path: key, op: "equals" };
}
function match(op, expected, actual) {
  if (op === "exists") return expected ? actual != null : actual == null;
  if (actual == null) return false;
  if (op === "equals") return actual === expected;
  if (op === "iregex") return new RegExp(expected, "i").test(String(actual));
  if (op === "regex") return new RegExp(expected).test(String(actual));
  if (op === "contains") return String(actual).includes(String(expected));
  if (op === "startswith") return String(actual).startsWith(String(expected));
  if (op === "in") return Array.isArray(expected) && expected.some(x => x === actual);
  const a = Number(actual), e = Number(expected);
  if (!Number.isFinite(a) || !Number.isFinite(e)) return false;
  if (op === "gte") return a >= e;
  if (op === "gt") return a > e;
  if (op === "lte") return a <= e;
  if (op === "lt") return a < e;
  return false;
}
const riskPriority = { danger: 4, warning: 3, unknown: 2, safe: 1, info: 0 };
function mergeRisk(cur, next) {
  if (cur === "unknown") return next;
  return riskPriority[next] > riskPriority[cur] ? next : cur;
}

function whitelistIndex(whitelist) {
  const idx = {};
  for (const cat of ["system","browser","korean_common","banking_security","dev_tools","hardware","cloud"]) {
    const bucket = whitelist[cat] || {};
    for (const [name, info] of Object.entries(bucket)) {
      if (!name.startsWith("_")) idx[name.toLowerCase()] = Object.assign({ wl_category: cat }, info);
    }
  }
  return idx;
}
function loadRules(dir) {
  return {
    process: readJson(env("PCH_PINNED_RULE_PROCESS", dir + "/process.json"), [], 4 * 1024 * 1024),
    network: readJson(env("PCH_PINNED_RULE_NETWORK", dir + "/network.json"), [], 4 * 1024 * 1024),
    autoruns: readJson(env("PCH_PINNED_RULE_AUTORUNS", dir + "/autoruns.json"), [], 4 * 1024 * 1024),
    defender: readJson(env("PCH_PINNED_RULE_DEFENDER", dir + "/defender.json"), [], 4 * 1024 * 1024),
    installs: readJson(env("PCH_PINNED_RULE_INSTALLS", dir + "/installs.json"), [], 4 * 1024 * 1024)
  };
}
function ruleMatches(rule, fact) {
  for (const [key, expected] of Object.entries(rule.when || {})) {
    const c = splitCond(key);
    if (!match(c.op, expected, get(fact, c.path))) return false;
  }
  return true;
}
function classify(fact, category, rules, wl) {
  let risk = "unknown", note = "", findings = [];
  if (category === "process" && fact.name) {
    const key = String(fact.name).replace(/\.[^.]+$/, "").toLowerCase();
    if (wl[key]) {
      risk = wl[key].risk === "safe" ? "safe" : "info";
      note = `${wl[key].vendor} - ${wl[key].desc}`;
    }
  }
  for (const rule of (rules[category] || [])) {
    if (!ruleMatches(rule, fact)) continue;
    const then = rule.then || {};
    const newRisk = then.risk || "unknown";
    risk = mergeRisk(risk, newRisk);
    if (then.note) note = format(then.note, fact);
    if (then.finding) {
      findings.push({
        level: newRisk,
        category: then.finding.category,
        title: format(then.finding.title, fact),
        detail: format(then.finding.detail, fact)
      });
    }
  }
  return { risk, note, findings };
}
function applyRules(raw, rules, wl) {
  const result = Object.assign({}, raw, { findings: raw.findings || [], sections: {} });
  const map = { cpu: "process", network: "network", listeningPorts: "process", autoruns: "autoruns", recentInstalls: "installs" };
  for (const [name, facts] of Object.entries(raw.sections || {})) {
    if (Array.isArray(facts)) {
      const category = map[name] || "process";
      result.sections[name] = facts.map(f => {
        const cls = classify(f, category, rules, wl);
        result.findings.push(...cls.findings);
        return Object.assign({}, f, { risk: cls.risk, note: cls.note });
      });
    } else if (name === "defender" || name === "macosSecurity") {
      const cls = classify(facts || {}, "defender", rules, wl);
      result.findings.push(...cls.findings);
      result.sections[name] = facts;
    } else {
      result.sections[name] = facts;
    }
  }
  const danger = result.findings.filter(f => f.level === "danger").length;
  const warning = result.findings.filter(f => f.level === "warning").length;
  const overall = danger ? "danger" : (warning ? "warning" : "safe");
  const message = danger ? `긴급 확인 필요: ${danger} 건의 위험 신호가 발견되었습니다.` :
    warning ? `확인 권장: ${warning} 건의 항목을 살펴보세요.` : "특별한 이상 징후가 발견되지 않았습니다.";
  result.summary = { overall, dangerCount: danger, warningCount: warning, message };
  return result;
}

function parseStorageDf(text) {
  const line = String(text || "").trim().split(/\r?\n/).filter(Boolean).pop() || "";
  const parts = line.trim().split(/\s+/);
  if (parts.length < 5) {
    return { mount: "", totalGB: 0, usedGB: 0, freeGB: 0, usePercent: 0, risk: "unknown", note: "저장공간 정보를 읽지 못했습니다." };
  }
  const totalKb = Number(parts[1] || 0);
  const usedKb = Number(parts[2] || 0);
  const freeKb = Number(parts[3] || 0);
  const usePercent = Number(String(parts[4] || "0").replace("%", ""));
  const mount = parts.slice(5).join(" ") || "/";
  const freeGB = kbToGb(freeKb);
  const risk = (freeGB < 5 || usePercent >= 95) ? "danger" :
    (freeGB < 15 || usePercent >= 90) ? "warning" : "safe";
  const note = risk === "danger" ? "남은 공간이 매우 적습니다. 캐시/임시파일 후보를 먼저 확인하세요." :
    risk === "warning" ? "macOS 저장공간 막대 뒤에 숨은 큰 캐시와 개발 도구 구성요소를 검토하세요." :
    "저장공간 압박은 낮지만, macOS가 뭉뚱그린 항목의 정체를 확인할 수 있습니다.";
  return { mount, totalGB: kbToGb(totalKb), usedGB: kbToGb(usedKb), freeGB, usePercent, risk, note };
}

function storageNote(kind, label) {
  if (kind === "cache") return "재생성 가능한 캐시입니다. 삭제 전 관련 앱/빌드 도구를 종료하고, 재다운로드 시간이 생길 수 있음을 감안하세요.";
  if (kind === "temp") return "임시파일입니다. 실행 중인 앱이 잡고 있을 수 있으므로 오래된 항목 위주로 정리하세요.";
  if (kind === "trash") return "휴지통입니다. 복구할 파일이 없을 때 비우면 즉시 공간을 회수할 수 있습니다.";
  if (kind === "build_cache") return "Xcode 빌드 산출물입니다. 프로젝트 재빌드 시간이 늘 수 있지만 보통 재생성 가능합니다.";
  if (kind === "archive") return "Xcode 보관 빌드입니다. 배포/증빙에 필요한 아카이브인지 확인한 뒤 정리하세요.";
  if (kind === "simulator_devices") return "iOS Simulator 기기 데이터입니다. 현재 개발 대상 기기는 남기고 불필요한 기기만 삭제하세요.";
  if (kind === "simulator_cache") return "CoreSimulator 캐시입니다. 실행 중인 Simulator/Xcode를 닫고 정리하는 편이 안전합니다.";
  if (kind === "simulator_runtime") return "iOS Simulator 런타임 자산입니다. 앱 검증에 필요한 런타임이면 삭제하지 마세요.";
  if (kind === "android_sdk") return "Android SDK 루트입니다. 모바일 Android 빌드에 필요할 수 있어 통째 삭제하지 마세요.";
  if (kind === "android_component" && /system images|emulator/i.test(label || "")) return "Android Emulator 구성요소입니다. 에뮬레이터 QA를 하지 않는다면 정리 후보가 될 수 있습니다.";
  if (kind === "android_component" && /NDK/i.test(label || "")) return "Android NDK입니다. React Native/Flutter 네이티브 빌드가 특정 버전을 요구할 수 있습니다.";
  if (kind === "android_component") return "Android 빌드 구성요소입니다. compileSdk/build-tools 요구 버전을 확인한 뒤 정리하세요.";
  if (kind === "toolchain") return "언어 런타임/패키지 도구체인입니다. 여러 프로젝트가 공유할 수 있으므로 버전 의존성을 확인하세요.";
  if (kind === "chrome_clone") return "Chrome 앱 번들 code-sign 임시 clone입니다. Chrome/브라우저 자동화가 실행 중이면 현재 사용 중인 항목이 있을 수 있습니다.";
  if (kind === "ai_vm_cache") return "Claude Cowork/로컬 에이전트용 VM 이미지입니다. 세션 기록과 분리된 재생성 가능 런타임이지만 Claude를 완전히 종료한 뒤 정리하세요.";
  if (kind === "ai_cache") return "AI 개발 도구 런타임/임시 캐시입니다. 삭제하면 다음 실행 때 다시 받을 수 있습니다.";
  if (kind === "ai_review" && /Codex/i.test(label || "")) return "Codex 내부 이벤트/진단 로그 SQLite DB입니다. .codex/sessions의 세션 jsonl은 아니며, Codex 종료 후 VACUUM/수동 검토 대상으로 분리합니다.";
  if (kind === "ai_review") return "AI 도구 내부 로그 DB입니다. 세션 jsonl은 아니지만 앱 동작/진단에 쓰일 수 있어 실행 중 삭제하지 마세요.";
  if (kind === "protected_history" && /Claude/i.test(label || "")) return "Claude 로컬 에이전트/Cowork 작업공간입니다. audit 로그, uploads, outputs가 포함될 수 있어 자동 정리 대상에서 제외합니다.";
  if (kind === "protected_history" && /Codex/i.test(label || "")) return "Codex 대화/session jsonl 기록입니다. 사용자가 되살려 볼 수 있는 실제 세션 기록이라 자동 정리 대상에서 제외합니다.";
  if (kind === "protected_history") return "대화/작업 세션 기록입니다. 공간은 보이지만 자동 정리 대상에서 제외합니다.";
  if (kind === "known_app" && /INNORIX/i.test(label || "")) return "사용자 영역에 설치되는 웹 파일 전송 모듈입니다. 시스템 보호 앱이 아니며 LaunchAgent와 프로세스를 함께 검토해야 합니다.";
  if (kind === "application") return "설치된 앱입니다. 번들 ID로 다시 검증한 앱 본체와 정확히 귀속되는 사용자 데이터만 휴지통 이동 대상으로 제시합니다.";
  return "저장공간 점검 항목입니다.";
}

function storageAction(kind, label) {
  if (kind === "cache") return "캐시 정리 후보";
  if (kind === "temp") return "오래된 임시파일 확인";
  if (kind === "trash") return "휴지통 비우기 후보";
  if (kind === "build_cache") return "필요 시 DerivedData 정리";
  if (kind === "archive") return "필요한 아카이브 보존 후 정리";
  if (kind === "simulator_devices") return "필수 Simulator 기기만 유지";
  if (kind === "simulator_cache") return "Xcode/Simulator 종료 후 검토";
  if (kind === "simulator_runtime") return "필요 런타임 보존";
  if (kind === "android_sdk") return "통째 삭제 금지";
  if (kind === "android_component" && /system images|emulator/i.test(label || "")) return "에뮬레이터 사용 여부 확인";
  if (kind === "android_component") return "빌드 요구 버전 확인";
  if (kind === "toolchain") return "프로젝트 버전 의존성 확인";
  if (kind === "chrome_clone") return "Chrome 종료 후 stale clone 확인";
  if (kind === "ai_vm_cache") return "Claude 종료 후 VM bundle 정리";
  if (kind === "ai_cache") return "다음 실행 재다운로드 감안";
  if (kind === "ai_review" && /Codex/i.test(label || "")) return "Codex 종료 후 VACUUM/수동 검토";
  if (kind === "ai_review") return "앱 종료 후 수동 검토";
  if (kind === "protected_history" && /Claude/i.test(label || "")) return "작업공간 보존";
  if (kind === "protected_history") return "세션 기록 보존";
  if (kind === "known_app" && /INNORIX/i.test(label || "")) return "LaunchAgent 포함 승인형 제거";
  if (kind === "application") return "미리보기 후 휴지통 이동";
  return "수동 확인";
}

function classifyStorageRow(kind, label, sizeGB, volumeRisk) {
  if (kind === "ai_vm_cache") return sizeGB >= 1 ? "warning" : "safe";
  if (kind === "ai_cache") return sizeGB >= 1 ? "warning" : (sizeGB >= 0.5 ? "info" : "safe");
  if (kind === "cache" && /Playwright|pnpm|npm/i.test(label || "")) {
    return sizeGB >= 1 ? "warning" : (sizeGB >= 0.5 ? "info" : "safe");
  }
  const disposable = ["cache", "temp", "trash", "build_cache", "chrome_clone", "ai_vm_cache", "ai_cache"];
  if (disposable.includes(kind)) {
    if (sizeGB >= 2 || (volumeRisk !== "safe" && sizeGB >= 1)) return "warning";
    return sizeGB >= 0.5 ? "info" : "safe";
  }
  if (kind === "ai_review") return sizeGB >= 1 ? "warning" : "info";
  if (kind === "protected_history") return sizeGB >= 1 ? "info" : "safe";
  if (kind === "known_app") return "warning";
  if (kind === "archive") return sizeGB >= 2 && volumeRisk !== "safe" ? "warning" : "info";
  if (kind === "application") return sizeGB >= 1 ? "info" : "safe";
  if (/^(android_|simulator_|toolchain)/.test(kind)) return sizeGB >= 1 ? "info" : "safe";
  return "info";
}

function parseStoragePaths(text, volumeRisk) {
  return String(text || "").trim().split(/\r?\n/).filter(Boolean).map(line => {
    const parts = line.split("\t");
    if (parts.length < 4) return null;
    const kind = parts[0];
    const label = parts[1];
    const path = parts[2];
    const sizeGB = kind === "application" ? appKbToGb(parts[3]) : kbToGb(parts[3]);
    const measureStatus = parts[4] || "ok";
    const measureNote = parts[5] || "";
    return {
      risk: measureStatus === "timed_out" ? "info" : classifyStorageRow(kind, label, sizeGB, volumeRisk),
      kind,
      label,
      sizeGB,
      path,
      measureStatus,
      cleanupId: parts[6] || "",
      note: measureNote || storageNote(kind, label),
      action: storageAction(kind, label)
    };
  }).filter(Boolean).sort((a, b) => b.sizeGB - a.sizeGB);
}

function parseStorageAccess(text) {
  const rows = String(text || "").trim().split(/\r?\n/).filter(Boolean).map(line => {
    const parts = line.split("\t");
    if (parts.length < 5) return null;
    return {
      risk: parts[3] === "blocked" ? "warning" : "info",
      kind: parts[0],
      label: parts[1],
      path: parts[2],
      status: parts[3],
      note: parts[4]
    };
  }).filter(Boolean);
  return {
    checks: rows,
    issues: rows.filter(row => row.status === "blocked")
  };
}

function parseStorageRuntime(text) {
  return String(text || "").trim().split(/\r?\n/).filter(Boolean).map(line => {
    const parts = line.split("\t");
    if (parts.length < 6) return null;
    return {
      kind: parts[0],
      label: parts[1],
      count: Number(parts[2] || 0),
      risk: parts[3] || "info",
      action: parts[4],
      note: parts[5]
    };
  }).filter(Boolean);
}

function parseSimulatorDevices(text, keepUUIDs, legacyKeepNames) {
  const keep = new Set((keepUUIDs || []).map(value => String(value).toUpperCase()));
  const legacyKeep = new Set(legacyKeepNames || []);
  return String(text || "").trim().split(/\r?\n/).filter(Boolean).map(line => {
    const parts = line.split("\t");
    if (parts.length < 4 || !/^[0-9A-Fa-f-]{36}$/.test(parts[1])) return null;
    const name = parts[0];
    const state = parts[3];
    const isBooted = state === "Booted";
    const uuid = parts[1].toUpperCase();
    const isLegacyKept = legacyKeep.has(name);
    const isKept = keep.has(uuid) || isLegacyKept;
    return {
      name,
      uuid,
      runtime: parts[2],
      state,
      sizeGB: Math.round((Number(parts[4] || 0) / 1048576) * 10) / 10,
      measureStatus: parts[5] || "ok",
      risk: isBooted || isKept ? "safe" : "info",
      protected: isBooted || isKept,
      protectionReason: isBooted
        ? "현재 Booted 상태"
        : (isLegacyKept ? "기존 이름 보존 목록 · UUID 전환 필요" : (isKept ? "사용자 보존 목록" : "")),
      cleanupId: `simulator_delete:${uuid}`
    };
  }).filter(Boolean);
}

const TMP_DIR = env("TMP_DIR", "/tmp");
const OUTPUT = env("PCH_OUTPUT", "scan_result.json");
const RAW_PATH = env("PCH_RAW_PATH", "raw_facts.json");
const WHITELIST_PATH = env("PCH_PINNED_WHITELIST", env("PCH_WHITELIST_PATH", "data/whitelist.json"));
const RULES_DIR = env("PCH_RULES_DIR", "rules");
const CONFIG_PATH = env("PCH_CONFIG_PATH", "data/config.json");
const NO_VT = /^true$/i.test(env("PCH_NO_VT", "false"));
const SIMULATOR_KEEP_PATH = env("PCH_SIMULATOR_KEEP_PATH", homeDir() + "/Library/Application Support/PC Health Check/simulator-keep.txt");
const simulatorKeepEntries = readText(SIMULATOR_KEEP_PATH, 64 * 1024)
  .split(/\r?\n/)
  .map(value => value.trim())
  .filter(Boolean);
const simulatorKeepUUIDs = simulatorKeepEntries
  .map(value => value.toUpperCase())
  .filter(value => /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/.test(value));
const simulatorLegacyKeepNames = simulatorKeepEntries.filter(value =>
  !/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/.test(value)
);
const config = readJson(CONFIG_PATH, {}, 1024 * 1024);
const vt = vtLookup(config, NO_VT);
if (vt.enabled) console.log("  VirusTotal 조회 활성화");

const raw = {
  schemaVersion: "1.0",
  scannedAt: env("PCH_SCANNED_AT", new Date().toISOString()),
  computerName: env("PCH_COMPUTER_NAME", "unknown"),
  userName: env("PCH_USER_NAME", "unknown"),
  osVersion: env("PCH_OS_VERSION", "macOS"),
  platform: "macos",
  scannerVersion: "0.3",
  findings: [],
  sections: {}
};

raw.sections.cpu = tmp("ps.txt").trim().split(/\r?\n/).filter(Boolean).map(line => {
  const match = line.trim().match(/^(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)\s+(.+)$/);
  if (!match) return null;
  const [, pid, user, pcpu, pmem, rss, comm] = match;
  // Keep CPU usage and executable identity from the same ps snapshot. A later
  // PID lookup can accidentally attach a reused PID to an unrelated process.
  const path = comm;
  return { name: basename(path), pid_: Number(pid), cpu: Number(pcpu), memoryMB: Math.round(Number(rss) / 10.24) / 100, path, sig: null, vt: vt.file(path) };
}).filter(Boolean).sort((a,b) => b.cpu - a.cpu);
raw.sections.gpu = [];

const connections = [];
tmp("net.txt").split(/\r?\n/).forEach(line => {
  if (!line.includes("->") || !line.includes("ESTABLISHED")) return;
  const parts = line.trim().split(/\s+/);
  if (parts.length < 2) return;
  const m = line.match(/->([\d.]+|\[?[0-9a-fA-F:]+\]?):(\d+)/);
  if (!m) return;
  const ip = m[1].replace(/^\[|\]$/g, "");
  if (isLocalIp(ip)) return;
  connections.push({ process: parts[0], pid_: Number(parts[1]), remoteAddress: ip, remotePort: Number(m[2]), path: "", vtIp: null });
});
raw.sections.network = connections
  .filter((c, i, arr) => arr.findIndex(x => x.process === c.process && x.remoteAddress === c.remoteAddress && x.remotePort === c.remotePort) === i)
  .map(c => Object.assign({}, c, { vtIp: vt.ip(c.remoteAddress) }));

raw.sections.listeningPorts = tmp("listen.txt").split(/\r?\n/).map(line => {
  if (!line.includes("LISTEN")) return null;
  const parts = line.trim().split(/\s+/);
  const m = line.match(/:(\d+)\s*\(LISTEN\)/);
  if (!m || parts.length < 2) return null;
  return { port: Number(m[1]), name: parts[0], process: parts[0], pid_: Number(parts[1]), path: "" };
}).filter(Boolean).filter((p, i, arr) => arr.findIndex(x => x.port === p.port) === i).sort((a,b) => a.port - b.port);

const startup = [], autoruns = [];
tmp("plists.txt").trim().split(/\r?\n/).filter(Boolean).forEach(path => {
  const label = basename(path).replace(/\.plist$/, "");
  const program = run("/usr/libexec/PlistBuddy -c 'Print :Program' " + escapeShell(path) + " 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' " + escapeShell(path) + " 2>/dev/null");
  if (!program) return;
  startup.push({ location: path.replace(/\/[^/]+$/, ""), name: label, command: program, launchString: program });
  autoruns.push({ category: path.includes("Daemons") ? "System LaunchDaemon" : "LaunchAgent", entry: label, image: program, signer: "", verified: false, launchString: program, sha256: "", vt: null });
});
raw.sections.startup = startup;
raw.sections.autoruns = autoruns;
raw.sections.scheduledTasks = [];

const sec = {};
tmp("security.txt").split(/\r?\n/).forEach(line => {
  const idx = line.indexOf("=");
  if (idx > 0) sec[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
});
raw.sections.macosSecurity = { gatekeeper: String(sec.GATEKEEPER || "").toLowerCase(), sip: String(sec.SIP || "").toLowerCase(), xprotectVersion: sec.XPROTECT_VERSION || "" };
raw.sections.defender = {};
raw.sections.recentInstalls = run("find /Applications -maxdepth 1 -name '*.app' -mtime -30 -print 2>/dev/null").split(/\r?\n/).filter(Boolean).map(p => ({
  installDate: run("stat -f '%Sm' -t '%Y-%m-%d' " + escapeShell(p)),
  name: basename(p).replace(/\.app$/, ""),
  publisher: run("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' " + escapeShell(p + "/Contents/Info.plist") + " 2>/dev/null")
}));
const load = {};
tmp("load.txt").split(/\r?\n/).forEach(line => {
  const idx = line.indexOf("=");
  if (idx > 0) load[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
});
raw.sections.systemLoad = { cpuPercent: Number(load.CPU_PCT || 0), memoryPercent: Number(load.MEM_PCT || 0), totalMemoryGB: Number(load.MEM_TOTAL_GB || 0) };
const storageVolume = parseStorageDf(tmp("storage_df.txt"));
const storageItems = parseStoragePaths(tmp("storage_paths.tsv"), storageVolume.risk);
const storageAccess = parseStorageAccess(tmp("storage_access.tsv"));
const storageRuntime = parseStorageRuntime(tmp("storage_runtime.tsv"));
const simulatorDevices = parseSimulatorDevices(
  tmp("storage_simulators.tsv"),
  simulatorKeepUUIDs,
  simulatorLegacyKeepNames
);
const cleanupKinds = ["cache", "temp", "trash", "build_cache", "chrome_clone", "ai_vm_cache", "ai_cache", "known_app"];
const cleanupCandidates = storageItems.filter(item =>
  cleanupKinds.includes(item.kind) && !!item.cleanupId &&
    (item.risk === "warning" || item.measureStatus === "timed_out")
);
const reviewKinds = ["ai_review", "protected_history"];
const developerKinds = ["android_sdk", "android_component", "simulator_devices", "simulator_cache", "simulator_runtime", "toolchain", "archive"];
raw.sections.storage = {
  volume: storageVolume,
  cleanupCandidates: cleanupCandidates.slice(0, 20),
  reviewCandidates: storageItems.filter(item => reviewKinds.includes(item.kind)),
  developerToolchains: storageItems.filter(item => developerKinds.includes(item.kind)).slice(0, 20),
  applications: storageItems.filter(item => item.kind === "application").slice(0, 20),
  largestItems: storageItems.slice(0, 30),
  accessChecks: storageAccess.checks,
  accessIssues: storageAccess.issues,
  runtimeSignals: storageRuntime,
  simulatorDevices
};
const bootedSimulators = storageRuntime.filter(item => item.kind === "booted_simulator");
const warningRuntimeSignals = storageRuntime.filter(item => item.kind === "process_count" && item.risk === "warning");
const claudeVm = storageItems.find(item => item.kind === "ai_vm_cache" && Number(item.sizeGB || 0) >= 5);
const codexLogDb = storageItems.find(item => item.kind === "ai_review" && /Codex/i.test(item.label || "") && Number(item.sizeGB || 0) >= 1);
if (claudeVm) {
  raw.findings.push({
    level: "warning",
    category: "storage",
    title: "Claude VM bundle 정리 후보",
    detail: `${claudeVm.sizeGB}GB 규모의 Claude Cowork/로컬 에이전트 VM 이미지가 있습니다. 세션 기록과 분리된 재생성 가능 런타임이지만 Claude를 완전히 종료한 뒤 지우세요.`
  });
}
if (codexLogDb) {
  raw.findings.push({
    level: "warning",
    category: "storage",
    title: "Codex 로그 DB 수동 검토",
    detail: `${codexLogDb.sizeGB}GB 규모의 Codex 내부 이벤트 로그 DB가 있습니다. 세션 jsonl은 아니며, Codex 실행 중 삭제하지 말고 필요하면 앱 종료 후 VACUUM/수동 검토로 줄이세요.`
  });
}
if (bootedSimulators.length >= 2) {
  raw.findings.push({
    level: "warning",
    category: "storage",
    title: "Simulator 여러 대가 Booted 상태",
    detail: `${bootedSimulators.map(item => item.label).join(", ")}가 동시에 켜져 있습니다. Bitxel/TrashMonster 작업 대상에 맞춰 한 대만 켜두면 CoreSimulator 프로세스와 캐시 재생성을 줄일 수 있습니다.`
  });
}
if (warningRuntimeSignals.length) {
  raw.findings.push({
    level: "warning",
    category: "storage",
    title: "반복 생성원 정리 필요",
    detail: warningRuntimeSignals.map(item => `${item.label} ${item.count}개`).join(", ") + "가 감지되었습니다. 공간을 지워도 이 실행원이 남아 있으면 캐시와 임시 clone이 다시 생길 수 있습니다."
  });
}
if (storageAccess.issues.length) {
  raw.findings.push({
    level: "warning",
    category: "storage",
    title: "Full Disk Access 확인 필요",
    detail: `macOS 개인정보 보호 설정 때문에 ${storageAccess.issues.length}개 영역을 읽지 못했을 수 있습니다. 리포트가 비어 보이면 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한에서 앱 또는 Terminal 권한을 확인하세요.`
  });
}
if (storageVolume.risk === "danger" || storageVolume.risk === "warning") {
  raw.findings.push({
    level: storageVolume.risk,
    category: "storage",
    title: "macOS 저장공간 막대 해석 필요",
    detail: `남은 공간 ${storageVolume.freeGB}GB, 사용률 ${storageVolume.usePercent}%입니다. macOS가 System Data/Developer로 뭉뚱그린 항목을 삭제 전 실제 경로와 성격으로 구분하세요.`
  });
  const cleanupGB = uniqueStorageTotal(cleanupCandidates);
  if (cleanupGB >= 2) {
    raw.findings.push({
      level: "warning",
      category: "storage",
      title: "캐시/임시파일 정리 후보",
      detail: `재생성 가능한 캐시·임시파일 후보가 약 ${cleanupGB}GB입니다. Developer 항목의 SDK/시뮬레이터/언어 도구체인은 통째 삭제하지 말고 버전 요구사항을 확인하세요.`
    });
  }
}
raw.sections.virustotal = { enabled: vt.enabled, callsThisScan: vt.calls, cacheHours: vt.enabled ? vt.cacheHours : 0 };
raw.sections.sysinternals = { sigcheckEnabled: false, autorunscEnabled: false, note: "macOS는 codesign + launchctl 사용" };

vt.save();
writeRequiredText(RAW_PATH, JSON.stringify(raw, null, 2));
const result = applyRules(raw, loadRules(RULES_DIR), whitelistIndex(readJson(WHITELIST_PATH, {}, 8 * 1024 * 1024)));
writeRequiredText(OUTPUT, JSON.stringify(result, null, 2));
console.log(`  - 위험: ${result.summary.dangerCount} 건`);
console.log(`  - 확인: ${result.summary.warningCount} 건`);
if (vt.enabled) console.log(`  - VT 조회: ${vt.calls} 건`);
