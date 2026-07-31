// THROWAWAY PROBE - delete after running
// Verbatim copies of get/splitCond/match/ruleMatches from scripts/scanner_helper.jxa.js
function get(obj, path) {
  return String(path).split(".").reduce((cur, k) => (cur == null ? undefined : cur[k]), obj);
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
function ruleMatches(rule, fact) {
  for (const [key, expected] of Object.entries(rule.when || {})) {
    const c = splitCond(key);
    if (!match(c.op, expected, get(fact, c.path))) return false;
  }
  return true;
}

function pad(s, n) { s = String(s); while (s.length < n) s += " "; return s; }
const out = [];

out.push("### A. raw JS coercion, NO guard (what would happen if the guard were absent)");
out.push("  undefined >= 40 -> " + (undefined >= 40));
out.push("  null >= 40      -> " + (null >= 40));
out.push("  null >= 0       -> " + (null >= 0));
out.push("  Number(null)=" + Number(null) + "  Number(undefined)=" + Number(undefined));
out.push("  Number.isFinite(Number(null))=" + Number.isFinite(Number(null)) +
         "  Number.isFinite(Number(undefined))=" + Number.isFinite(Number(undefined)));

out.push("### B. match() exactly as shipped");
const cases = [
  ["gte",40,55.0,"present >= threshold"],
  ["gte",40,12.0,"present < threshold"],
  ["gte",40,undefined,"absent (undefined)"],
  ["gte",40,null,"null"],
  ["gte",40,"40","string '40'"],
  ["gte",40,"abc","non-numeric string"],
  ["gte",40,"","empty string"],
  ["gte",40,true,"bool true"],
  ["gte",40,false,"bool false"],
  ["gte",40,[],"empty array"],
  ["lte",40,undefined,"lte undefined"],
  ["gt",40,null,"gt null"],
  ["lt",40,null,"lt null"],
  ["equals",true,undefined,"equals true vs undefined"],
  ["equals",true,true,"equals true vs true"],
  ["equals",true,"true","equals true vs string 'true'"],
  ["equals",true,1,"equals true vs int 1  <-- DIVERGENCE PROBE"],
  ["equals",false,0,"equals false vs int 0 <-- DIVERGENCE PROBE"],
  ["contains","x",null,"contains null"],
  ["in",[1,2],null,"in null"],
  ["in","abc","b","in: expected=string  <-- DIVERGENCE PROBE"],
  ["iregex","^x",undefined,"iregex undefined"],
  ["exists",true,undefined,"exists:true undefined"],
  ["exists",false,undefined,"exists:false undefined"]
];
cases.forEach(c => out.push("  " + pad(c[3],44) + " op=" + pad(c[0],9) + " -> " + match(c[0],c[1],c[2])));

out.push("### C. ruleMatches with the two rules added by d6ca0c6");
const rules = [
  {id:"background_cpu_shell_origin", when:{"startedFromShell.equals":true,"cpuPercent.gte":40}},
  {id:"background_cpu_sustained",    when:{"cpuPercent.gte":90}}
];
const cpuFact = {name:"python3.11", pid_:501, cpu:96.4, memoryMB:120, path:"/usr/bin/python3.11", sig:null, vt:null};
const bgFact  = {windowSeconds:3,name:"python3.11",pid_:501,cpuPercent:96.4,responsiblePid:400,responsibleName:"-bash",startedFromShell:true,selfResponsible:false};
[["cpu-section fact (real shape)",cpuFact],
 ["backgroundCpu fact 96.4% shell",bgFact],
 ["backgroundCpu cpuPercent=null",Object.assign({},bgFact,{cpuPercent:null})],
 ["backgroundCpu cpuPercent=0 (Number()||0 path)",Object.assign({},bgFact,{cpuPercent:0})],
 ["backgroundCpu startedFromShell=false",Object.assign({},bgFact,{startedFromShell:false})]
].forEach(p => out.push("  " + pad(p[0],46) + " -> " + rules.map(r => r.id + "=" + ruleMatches(r,p[1])).join(", ")));

out.push("### D. vacuous probe");
out.push("  when={}       -> " + ruleMatches({id:"e",when:{}}, cpuFact));
out.push("  no when key   -> " + ruleMatches({id:"e"}, cpuFact));

out.join("\n");
