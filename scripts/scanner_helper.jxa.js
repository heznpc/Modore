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
function readJson(path, fallback) {
  try { return JSON.parse(readText(path)); } catch (e) { return fallback; }
}
function run(cmd) {
  const app = Application.currentApplication();
  app.includeStandardAdditions = true;
  try { return app.doShellScript(cmd); } catch (e) { return ""; }
}
function tmp(name) { return readText(TMP_DIR + "/" + name); }
function basename(path) { return String(path || "").split("/").filter(Boolean).pop() || String(path || ""); }
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
    if (!Object.prototype.hasOwnProperty.call(cfg, "enabled")) cfg.enabled = true;
  }
  const enabled = !!cfg.enabled && !!cfg.apiKey && !disabled;
  const cacheHours = Number(cfg.cacheHours || 48);
  const maxCalls = Number(cfg.maxCallsPerScan || 100);
  const cacheDir = homeDir() + "/Library/Caches/PC건강검진";
  const cachePath = cacheDir + "/vt-cache.json";
  ensureDir(cacheDir);
  let cache = readJson(cachePath, {});
  let calls = 0, lastCall = 0;
  const headerPath = TMP_DIR + "/vt_headers.txt";
  if (enabled) writeText(headerPath, "x-apikey: " + cfg.apiKey + "\naccept: application/json\n");
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
    const out = run("/usr/bin/curl -sS --max-time 15 -H @" + escapeShell(headerPath) + " -w '\\n%{http_code}' " + escapeShell(url));
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
    process: readJson(dir + "/process.json", []),
    network: readJson(dir + "/network.json", []),
    autoruns: readJson(dir + "/autoruns.json", []),
    defender: readJson(dir + "/defender.json", []),
    installs: readJson(dir + "/installs.json", [])
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

const TMP_DIR = env("TMP_DIR", "/tmp");
const OUTPUT = env("PCH_OUTPUT", "scan_result.json");
const RAW_PATH = env("PCH_RAW_PATH", "raw_facts.json");
const WHITELIST_PATH = env("PCH_WHITELIST_PATH", "data/whitelist.json");
const RULES_DIR = env("PCH_RULES_DIR", "rules");
const CONFIG_PATH = env("PCH_CONFIG_PATH", "data/config.json");
const NO_VT = /^true$/i.test(env("PCH_NO_VT", "false"));
const config = readJson(CONFIG_PATH, {});
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

const pidPath = {};
run("ps -Ao pid=,comm=").split(/\r?\n/).forEach(row => {
  const m = row.trim().match(/^(\d+)\s+(.+)$/);
  if (m) pidPath[m[1]] = m[2];
});

raw.sections.cpu = tmp("ps.txt").trim().split(/\r?\n/).filter(Boolean).map(line => {
  const parts = line.trim().split(/\s+/, 6);
  if (parts.length < 6) return null;
  const [pid, user, pcpu, pmem, rss, comm] = parts;
  const path = pidPath[pid] || comm;
  return { name: basename(path), pid_: Number(pid), cpu: Number(pcpu), memoryMB: Math.round(Number(rss) / 10.24) / 100, path, sig: null, vt: vt.file(path) };
}).filter(Boolean).sort((a,b) => b.cpu - a.cpu).slice(0,15);
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
raw.sections.virustotal = { enabled: vt.enabled, callsThisScan: vt.calls, cacheHours: vt.enabled ? vt.cacheHours : 0 };
raw.sections.sysinternals = { sigcheckEnabled: false, autorunscEnabled: false, note: "macOS는 codesign + launchctl 사용" };

vt.save();
writeText(RAW_PATH, JSON.stringify(raw, null, 2));
const result = applyRules(raw, loadRules(RULES_DIR), whitelistIndex(readJson(WHITELIST_PATH, {})));
writeText(OUTPUT, JSON.stringify(result, null, 2));
console.log(`  - 위험: ${result.summary.dangerCount} 건`);
console.log(`  - 확인: ${result.summary.warningCount} 건`);
if (vt.enabled) console.log(`  - VT 조회: ${vt.calls} 건`);
