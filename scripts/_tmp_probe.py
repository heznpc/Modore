#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# THROWAWAY PROBE - delete after running
import json
from pathlib import Path
import rule_engine as R

print("### A. _match_condition direct")
cases = [
    ("gte", 40, 55.0,        "field present, >= threshold (float)"),
    ("gte", 40, 12.0,        "field present, < threshold (float)"),
    ("gte", 40, None,        "field None / absent"),
    ("gte", 40, "40",        "field string '40'"),
    ("gte", 40, "abc",       "field non-numeric string"),
    ("gte", 40, True,        "field bool True"),
    ("gte", 40, False,       "field bool False"),
    ("gte", 40, [],          "field empty list"),
    ("lte", 40, None,        "lte with None"),
    ("gt",  40, None,        "gt with None"),
    ("lt",  40, None,        "lt with None"),
    ("equals", True, None,   "equals True vs None"),
    ("equals", True, True,   "equals True vs True"),
    ("equals", True, "true", "equals True vs 'true' string"),
    ("equals", True, 1,      "equals True vs int 1  <-- py/js divergence probe"),
    ("contains", "x", None,  "contains with None"),
    ("in", [1, 2], None,     "in with None"),
    ("iregex", "^x", None,   "iregex with None"),
    ("exists", True, None,   "exists:true with None"),
    ("exists", False, None,  "exists:false with None"),
]
for op, exp, act, label in cases:
    try:
        r = R._match_condition(op, exp, act)
        print(f"  {label:52s} op={op:9s} -> {r!r}")
    except Exception as e:
        print(f"  {label:52s} op={op:9s} -> RAISED {type(e).__name__}: {e}")

print("\n### B. does None >= 40 actually raise in this interpreter?")
try:
    None >= 40
except Exception as e:
    print(f"  bare `None >= 40` -> RAISED {type(e).__name__}: {e}")

print("\n### C. _rule_matches with the two new rules vs cpu-shaped facts")
new_rules = [
    {"id": "background_cpu_shell_origin",
     "when": {"startedFromShell.equals": True, "cpuPercent.gte": 40},
     "then": {"risk": "warning"}},
    {"id": "background_cpu_sustained",
     "when": {"cpuPercent.gte": 90}, "then": {"risk": "info"}},
]
empty_when = {"id": "empty_when", "when": {}, "then": {"risk": "danger"}}
no_when = {"id": "no_when_key", "then": {"risk": "danger"}}

cpu_fact = {"name": "python3.11", "pid_": 501, "cpu": 96.4,
            "memoryMB": 120.0, "path": "/usr/bin/python3.11", "sig": None, "vt": None}
bg_fact = {"windowSeconds": 3, "name": "python3.11", "pid_": 501, "cpuPercent": 96.4,
           "responsiblePid": 400, "responsibleName": "-bash",
           "startedFromShell": True, "selfResponsible": False}
bg_low = dict(bg_fact, cpuPercent=5.0)
bg_noshell = dict(bg_fact, startedFromShell=False)
bg_nullpct = dict(bg_fact, cpuPercent=None)

for label, fact in [("cpu-section fact (no cpuPercent/startedFromShell)", cpu_fact),
                    ("backgroundCpu fact 96.4% shell", bg_fact),
                    ("backgroundCpu fact 5% shell", bg_low),
                    ("backgroundCpu fact 96.4% NOT shell", bg_noshell),
                    ("backgroundCpu fact cpuPercent=None", bg_nullpct)]:
    res = {r["id"]: R._rule_matches(r, fact) for r in new_rules}
    print(f"  {label:48s} -> {res}")

print("\n### D. vacuous-match probe: rule with empty / missing `when`")
print(f"  when={{}}      vs cpu_fact -> {R._rule_matches(empty_when, cpu_fact)}")
print(f"  no 'when' key vs cpu_fact -> {R._rule_matches(no_when, cpu_fact)}")
print(f"  all([]) == {all([])}")

print("\n### E. REAL engine, REAL rules/process.json, both sections")
root = Path(__file__).resolve().parent.parent
eng = R.RuleEngine.from_dir(root / "rules", root / "data" / "whitelist.json")
print("  process rules loaded:", len(eng.rules_by_category["process"]))
print("  classify(cpu_fact, 'process')        ->",
      json.dumps(eng.classify(cpu_fact, "process"), ensure_ascii=False))
print("  classify(bg_fact, 'process')         ->",
      json.dumps(eng.classify(bg_fact, "process"), ensure_ascii=False))

print("\n### F. apply_rules_to_raw end-to-end, same process in BOTH sections")
raw = {"schemaVersion": "1.0", "sections": {
    "cpu": [dict(cpu_fact, name="xmrig", path="/tmp/xmrig", cpu=99.0)],
    "backgroundCpu": [dict(bg_fact, name="xmrig", cpuPercent=99.0)],
}}
out = R.apply_rules_to_raw(eng, raw)
print("  summary:", json.dumps(out["summary"], ensure_ascii=False))
for f in out["findings"]:
    print("   finding:", f["level"], "|", f["category"], "|", f["title"])
