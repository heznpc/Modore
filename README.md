# PC 건강검진 — PC Health Check

> A locale-aware security diagnostic tool that **explains your PC in plain language**.
> Built for Korean users whose legitimate banking and government software gets flagged by generic scanners.

[🌐 **Website**](https://heznpc.github.io/pc-health-check/) · [📥 Download](https://github.com/heznpc/pc-health-check/releases) · [🇰🇷 한국어 가이드](./사용법.txt)

*Part of the Heznpc portfolio — Trust tier (Supporting).*

---

## The problem

Generic malware scanners are great at detection but terrible at **context**. For Korean users, running any reputable scanner typically produces something like:

> ⚠️ **30 suspicious items found**
> - `I3GProc.exe` — unsigned network helper
> - `nosstarter.exe` — listening on local port
> - `MagicLine4NP.exe` — kernel driver, no publisher
> - `WIZVERA.exe` — browser helper, always on
> - … 26 more

**29 of those are legitimate banking/government security plugins.** Users can't tell which is which, so they either panic and uninstall critical software, or learn to ignore warnings entirely — both dangerous outcomes.

This project is a **second-opinion diagnostic reporter** that recognizes Korean software and explains each finding in plain Korean (or English/Japanese).

---

## Currently implemented

- **Cross-platform scanner**: Windows (PowerShell 5.1+) and macOS (Bash + Python 3.7+).
- **Eight diagnostic categories**: CPU top processes · GPU usage · active network connections · listening ports · startup entries · scheduled tasks · Windows Defender / macOS Gatekeeper status · recently installed apps.
- **Locale-aware whitelist**: 113 entries across 7 categories (system, browser, korean_common, banking_security, dev_tools, hardware, cloud) plus a miner blacklist. Covers IPinside, nProtect, INISAFE, MagicLine, Veraport, XecureWeb, Ahnlab V3, Alyac, and the rest of the Korean banking/government plugin set.
- **Traffic-light output** (🟢 safe / 🟡 check / 🔴 danger) so non-technical users can act on the report.
- **5-minute idle monitor (Windows)**: records who actually burns CPU while the user is idle — the most reliable cryptominer tell.
- **VirusTotal lookup (opt-in)**: SHA-256 hash query only. 48h local cache, 16s rate-limit, respects the public API quota (4 req/min, 500/day).
- **Sysinternals integration (Windows)**: first-run downloads `sigcheck` and `autorunsc` from Microsoft for signature verification and ~20 persistence-mechanism coverage.
- **macOS equivalents**: `codesign -dv`, `launchctl`, `sfltool dumpbtm`, `spctl --status`, `kmutil showloaded`.
- **Single-file HTML report**: opens in the user's browser, works offline, includes Google/VirusTotal "investigate" links and collapsible novice-friendly explanations.
- **i18n**: Korean, English, Japanese — both the landing page (`docs/i18n/`) and the report (`data/report_i18n/`).
- **Rule engine + tests**: declarative JSON rules in `rules/` (autoruns, defender, installs, network, process) evaluated by `scripts/rule_engine.py`. 55 pytest tests cover report rendering, rule evaluation, and whitelist lookups.
- **Read-the-source distribution**: ~3,000 lines of PowerShell/Python/Bash, no compiled binaries, no bundled DLLs, no telemetry.

## Planned

- **Tauri 2 GUI** — if/when the project graduates from scripts, the target is a 2–10 MB Rust binary with Apple Developer ID notarization. No timeline committed.
- **Additional locales** beyond ko/en/ja — community PRs welcome; the i18n loader already supports arbitrary codes.

## Design intent

**Scripts + HTML report, not a native GUI app.** This is the load-bearing choice:

| Concern | Native GUI app | Scripts + HTML |
|---|---|---|
| Distribution trust | Unsigned EXE triggers SmartScreen/Gatekeeper | Readable source; HTML opens in the user's existing trusted browser |
| Code-signing cost | $400+/yr (Windows) or $99/yr (Apple) | $0 |
| User can audit code | Compiled binary — hard | ~3,000 lines plain text |
| Antivirus false positives | Common (security tools get flagged) | Rare |
| Cross-platform | Electron ≈ 200 MB per OS | Same HTML template, OS-specific scanners |

**Locale as a first-class concern.** Generic scanners are built for global users; their false-positive rate on Korean banking PCs is the user-facing problem this project exists to solve. The whitelist is the differentiated layer, not the scanner.

**Privacy-first VirusTotal use.** Hashes only, never file contents. Every network call is in `scripts/vt-lookup.ps1` and `scripts/scanner_helper.py` — grep for `Invoke-RestMethod` and `urlopen` to audit.

## Non-goals

- **Not a replacement for antivirus.** Keep using Windows Defender, V3 Lite, Malwarebytes, etc. Recommended workflow:
  1. **Windows Defender** (or V3 Lite / Alyac) for real-time baseline protection.
  2. **Malwarebytes Free** or **Emsisoft Emergency Kit** for deep scans when suspicious.
  3. **This tool** to understand *what's actually running* and whether your banking plugins are normal.
- **Not a cryptominer remover.** It detects patterns and alerts you; removal is left to the user's AV.
- **Not real-time protection.** It's an on-demand scan that produces an HTML report.
- **Not a Korean-only tool — but Korean is the priority.** i18n exists, but the whitelist depth and explanation quality are Korean-first by design.

## Redacted

- Specific external persons who contributed feedback or testing context are intentionally not named in this README.
- Any user-PC scan artifacts (`scan_result.json`, `monitor_result.json`, `raw_facts.json`, `검사결과*.html`, `vt-cache.json`) are gitignored — they contain PC-identifying data and must not be committed.

---

## Installation

### Windows
1. Download the latest [release zip](https://github.com/heznpc/pc-health-check/releases).
2. Extract anywhere (USB, Desktop, Downloads — no installer needed).
3. Double-click `검사하기.bat`.

### macOS
1. Download and extract the same zip.
2. Right-click `검사하기.command` → **Open** (required once for unsigned scripts).
3. Follow the menu.

### Requirements
- **Windows**: PowerShell 5.1+ (built into Windows 10/11).
- **macOS**: Python 3.11+ (`brew install python3` if missing; built-in on macOS 13+). Python 3.7–3.10 are EOL or reaching EOL within months and are no longer supported.

## Enabling VirusTotal lookup (optional, recommended)

1. Sign up at [virustotal.com](https://www.virustotal.com) — free.
2. Profile icon → **API Key** → copy.
3. Either:

   **Option A — environment variable (recommended for shared / CI / multi-user PCs):**
   ```bash
   # macOS / Linux
   export VT_API_KEY="your_key_here"

   # Windows PowerShell (current session)
   $env:VT_API_KEY = "your_key_here"

   # Windows PowerShell (persistent, current user)
   [System.Environment]::SetEnvironmentVariable('VT_API_KEY', 'your_key_here', 'User')
   ```
   When `VT_API_KEY` is set, it overrides `data/config.json` and auto-enables VirusTotal. The key never touches disk.

   **Option B — `data/config.json` (simpler for single-user PCs):**
   ```json
   "virustotal": {
     "enabled": true,
     "apiKey": "YOUR_KEY_HERE"
   }
   ```
   Lock the file so other users can't read it:
   ```bash
   # macOS / Linux
   chmod 600 data/config.json

   # Windows (PowerShell, owner-only ACL)
   icacls data\config.json /inheritance:r /grant:r "$env:USERNAME:F"
   ```

4. Run the scan. File hashes will be cross-checked against 70+ antivirus engines.

**Privacy note.** Only the SHA-256 hash is sent. VirusTotal never receives file contents. If the hash is unknown, the tool reports "unknown" — it does not upload the file.

## Project structure

```
pc-health-check/
├── 검사하기.bat              Windows launcher (double-click)
├── 검사하기.command          macOS launcher (double-click)
├── 사용법.txt                Korean user guide
├── README.md                 This file
├── data/
│   ├── whitelist.json        Korean programs + miner blacklist DB
│   ├── explain.json          Plain-language explanations per check
│   ├── config.json           API key + settings (apiKey ships empty)
│   └── report_i18n/          ko / en / ja report strings
├── rules/                    Declarative rule JSON
│   ├── autoruns.json
│   ├── defender.json
│   ├── installs.json
│   ├── network.json
│   └── process.json
├── scripts/
│   ├── menu.ps1              Windows interactive menu
│   ├── scanner.ps1           Windows scanner
│   ├── monitor.ps1           Windows 5-min idle monitor
│   ├── report.py             Cross-platform HTML generator
│   ├── rule_engine.py        Rule evaluator (used by report)
│   ├── vt-lookup.ps1         VirusTotal wrapper
│   ├── sigcheck-helper.ps1   Sysinternals sigcheck wrapper
│   ├── autorunsc-helper.ps1  Sysinternals autorunsc wrapper
│   ├── scanner.sh            macOS scanner
│   ├── scanner_helper.py     macOS data aggregator
│   └── modules/macos/        macOS scanner sub-modules
├── tests/                    pytest suite (55 tests)
└── docs/                     GitHub Pages landing (multilingual)
    ├── index.html
    ├── style.css
    ├── script.js
    └── i18n/{ko,en,ja}.json
```

## Landing page

The `docs/` folder is the project landing page, designed for GitHub Pages. It supports Korean · English · Japanese with a language switcher. To add another language, drop a new `docs/i18n/<code>.json` file and add the code to the language list in `script.js`.

To serve locally:
```bash
cd docs
python3 -m http.server 8000
# open http://localhost:8000
```

## Tests

```bash
python3 -m pytest tests/ -q
# 55 passed
```

CI runs rule-JSON validation, Python syntax checks, PowerShell parser checks, and the pytest suite on every push.

## Comparison with similar tools

| Tool | Platform | Target | Strength | vs. This project |
|---|---|---|---|---|
| Malwarebytes Free | Win/Mac | General users | Real detection | This = context. Use both. |
| Windows Defender | Win | Everyone | Real-time protection | Complementary |
| Sysinternals Autoruns | Win | Experts | Exhaustive autoruns | We wrap it and explain in plain language |
| Objective-See tools | Mac | Prosumer+ | Native UX | English only, fragmented across many tools |
| Malware Zero (malzero.xyz) | Win | Korean users | PUP removal | Older UX, no per-finding explanations |
| HijackThis / FRST | Win | Tech-savvy | Log analysis | Not novice-friendly |

**The gap this fills**: plain-Korean explanations + locale-aware whitelist for banking software + privacy-safe VT lookup, all in one opt-in HTML report.

## Privacy

- **No telemetry.** The tool never phones home.
- **No file uploads.** VirusTotal integration uses SHA-256 hashes only.
- **Local cache only.** VT response cache lives in `%LOCALAPPDATA%/PC건강검진/` (Windows) or `~/Library/Caches/PC건강검진/` (macOS).
- **Auditable.** Every outbound network call is in `scripts/vt-lookup.ps1` / `scripts/scanner_helper.py` — grep for `Invoke-RestMethod` and `urlopen`.

## Contributing

Whitelist contributions are especially welcome. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the full guide. Short version — if you recognize a legitimate local app missing from `data/whitelist.json`, open a PR with:
- Process name (lowercased, without extension)
- Vendor
- Short Korean/Japanese/English description
- Category (system / browser / korean_common / banking_security / dev_tools / hardware / cloud)

## Security

Vulnerability reports should go through GitHub's [Private Vulnerability Reporting](https://github.com/heznpc/pc-health-check/security/advisories/new) or `wantcongz@gmail.com` — see [`SECURITY.md`](./SECURITY.md) for the full policy, scope, and response timeline.

This project verifies all Sysinternals binaries via `Get-AuthenticodeSignature` against a Microsoft signer subject **on every invocation** — not only at first download — before executing them. The cached `.exe` under `%LOCALAPPDATA%` is re-validated each run because that directory is user-writable and the threat model this tool exists in (other user-mode malware may be present) requires treating the cache as untrusted between runs.

## License

MIT. See `LICENSE` for details.

This project depends on — but does not redistribute — Microsoft Sysinternals tools (`sigcheck.exe`, `autorunsc.exe`). Per the Sysinternals license, those are downloaded from Microsoft's servers on first run with explicit user consent.

## Credits

- Microsoft Sysinternals (Windows signature + autoruns coverage).
- The Objective-See Foundation (macOS security research informing the macOS scanner design).
- Korean community knowledge from **Malware Zero** ([malzero.xyz](https://malzero.xyz)) and the 바이러스 제로 시큐리티 community.

---

<sub>Version 0.3 · 2026</sub>
