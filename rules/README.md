# Rules

Declarative rules that turn raw scan facts into traffic-light findings.

## How a rule is evaluated

Each rule has two parts: **`when`** (conditions) and **`then`** (verdict).
If **every field** in `when` matches the input fact, the rule fires and emits the verdict in `then`.
The fact inherits the highest-risk verdict across all matching rules (danger > warning > info > safe).

```json
{
  "id": "miner_by_name",
  "description": "Known cryptominer process name",
  "when": {
    "name.iregex": "^(xmrig|minerd|cgminer|ethminer|phoenixminer)$"
  },
  "then": {
    "risk": "danger",
    "note": "알려진 암호화폐 채굴기입니다.",
    "finding": {
      "category": "check_cpu",
      "title": "채굴/악성 프로세스: {name}",
      "detail": "{note} 경로: {path}, PID {pid_}"
    }
  }
}
```

## Supported match operators

Inside `when`, each key targets a field (dot-notation for nested), and the value is either:

| Operator | Example | Matches when |
|---|---|---|
| `equals` (implicit) | `"risk": "danger"` | Field equals value |
| `.iregex` | `"name.iregex": "^chrome$"` | Case-insensitive regex match |
| `.regex` | `"name.regex": "^[A-Z]"` | Case-sensitive regex match |
| `.in` | `"port.in": [3333, 4444]` | Value in list |
| `.contains` | `"path.contains": "AppData"` | Substring match |
| `.startswith` | `"path.startswith": "C:\\Windows\\"` | Prefix |
| `.exists` | `"vt.exists": true` | Field is present and non-null |
| `.gte` / `.gt` / `.lte` / `.lt` | `"cpu.gte": 50` | Numeric comparison |

Multiple keys in the same `when` block are **AND**ed together.

## Supported `then` fields

- `risk` — one of `safe`, `info`, `warning`, `danger`. Required.
- `note` — short explanation attached to the fact.
- `finding` — if set, also emits a finding entry in the top-level `findings` array.
  - `category`: e.g. `check_cpu`, `check_network`, `check_autorun`
  - `title`: supports `{field}` template (substitutes from the fact)
  - `detail`: same

## Files in this folder

- `process.json` — rules for running processes (CPU table)
- `network.json` — rules for outbound connections and listening ports
- `autoruns.json` — rules for startup entries and scheduled tasks
- `installs.json` — rules for recently installed programs
- `defender.json` — rules for antivirus / security posture

Each file is an array of rule objects. Order doesn't matter for correctness — risk merging is deterministic.

## Adding your own rule

1. Pick the right file (by category).
2. Append a new object to the array with a unique `id`.
3. Test locally: `python -m pytest tests/test_rule_engine.py`.
4. Open a PR describing the rule and why it's useful.
