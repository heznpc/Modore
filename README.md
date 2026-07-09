# PC 건강검진 — PC Health Check

> A local diagnostic reporter for the moment you wonder: **is my PC doing something behind my back?**
> It turns miner, autorun, network, Korean security-plugin, and macOS storage signals into plain-language evidence before you delete anything.

[🌐 **Website**](https://heznpc.github.io/pc-health-check/) · [📥 Download](https://github.com/heznpc/pc-health-check/releases) · [🇰🇷 한국어 가이드](./사용법.txt)

*Part of the Heznpc portfolio — Trust tier (Supporting).*

---

## The problem

The first symptom is usually not a clear malware alert. It is a fan that will not stop, CPU/GPU load while the PC is idle, an unknown process in Task Manager, a strange network connection, or disk space disappearing overnight. The natural question is: **is this computer secretly mining, infected, or just running normal local software?**

Generic malware scanners are great at detection but terrible at **context**. For Korean users, running any reputable scanner typically produces something like:

> ⚠️ **30 suspicious items found**
> - `I3GProc.exe` — unsigned network helper
> - `nosstarter.exe` — listening on local port
> - `MagicLine4NP.exe` — kernel driver, no publisher
> - `WIZVERA.exe` — browser helper, always on
> - … 26 more

**29 of those may be legitimate banking/government security plugins.** Users can't tell which is which, so they either panic and uninstall critical software, or learn to ignore warnings entirely — both dangerous outcomes.

This project is a **second-opinion diagnostic reporter** that recognizes Korean software, checks miner-like runtime signals, and explains each finding in plain Korean (or English/Japanese).

---

## Currently implemented

- **Two OS editions under one brand**: PC Health Check for Windows and PC Health Check for Mac share the same promise — explain local PC state in plain language without deleting anything automatically.
- **Windows Edition**: PowerShell 5.1+ scanner focused on Korean banking/government plugin context, Windows Defender, Sysinternals-backed signature/autoruns coverage, networking, startup entries, scheduled tasks, recent installs, and the 5-minute idle CPU monitor.
- **Mac Edition**: Bash + JXA scanner focused on macOS security context, launchd/login items, Gatekeeper/SIP/XProtect, network/listening ports, recent apps, and a macOS storage bar decoder for the vague System Data / Developer / macOS categories. It translates caches, temporary files, Xcode Simulator assets, Android SDK components, language toolchains, and Chrome code-sign clones into practical "review / preserve / hand off to cleanup tools" context. It includes a SwiftUI frontend with a native diagnostic dashboard, scanner logs, Finder actions, cleanup-guide copy, and HTML export for browser/share workflows.
- **Suspicion-to-evidence workflow**: CPU/GPU load, idle CPU samples, miner process names, miner-pool ports, network endpoints, autoruns, signatures, and optional VirusTotal hash lookups are shown together so a user can decide what deserves a closer look before removing anything.
- **Locale-aware whitelist**: 71 known-good entries across 7 categories (system, browser, korean_common, banking_security, dev_tools, hardware, cloud), plus 19 miner blacklist entries, 5 RAT blacklist entries, and 13 miner-pool ports. Covers IPinside, nProtect, INISAFE, MagicLine, Veraport, XecureWeb, Ahnlab V3, Alyac, and the rest of the Korean banking/government plugin set.
- **Traffic-light output** (🟢 safe / 🟡 check / 🔴 danger) so non-technical users can act on the report.
- **VirusTotal lookup (opt-in)**: SHA-256 hash query only. 48h local cache, 16s rate-limit, respects the public API quota (4 req/min, 500/day).
- **Single-file HTML report**: opens in the user's browser and works offline. The shipped OS-native reports include Google/VirusTotal investigation links; the Python development report also includes collapsible novice-friendly explanations. On Mac, HTML is an export/share artifact; the SwiftUI app uses a native dashboard as the primary experience.
- **Local-only by default**: the Mac SwiftUI app and script mode run local scanners only. There is no AI/LLM integration, no OpenAI/Claude/Codex API call, no token spend, no account login, and no report upload. Optional VirusTotal lookup is the only external lookup path and sends hashes only.
- **i18n**: Korean, English, Japanese landing page strings (`docs/i18n/`) and Python development report strings (`data/report_i18n/`). The release runtime reports are OS-native and Korean-first.
- **Rule engine + tests**: declarative JSON rules in `rules/` (autoruns, defender, installs, network, process) evaluated by OS-native runtime engines. 70 pytest tests cover report rendering, rule evaluation, whitelist lookups, service contracts, and release smoke.
- **Read-the-source distribution**: readable PowerShell/Bash/JXA scripts, no prebuilt diagnostic binaries in the release zips, no bundled DLLs, no telemetry.

## Planned

- **Mac Edition Swift app** — continue turning the SwiftUI frontend into the primary Mac experience: local-first decoding of macOS's vague storage categories, developer-toolchain context, redaction-aware reports, and safer review flows before AppCleaner/Finder cleanup.
- **Windows Edition maintenance** — Windows remains under the same PC Health Check brand, but new Windows-only storage features wait for real-device validation.
- **Additional locales** beyond ko/en/ja — community PRs welcome; the i18n loader already supports arbitrary codes.

## Editions

PC Health Check is the brand. The OS editions are separate products under that brand, not feature-parity promises.

| Edition | Artifact | Focus | Validation rule |
|---|---|---|---|
| Windows Edition | `pch-v0.3.x-win.zip` | Korean banking/government security-plugin context, Defender, Sysinternals, autoruns, network, idle CPU monitor | Windows-only features ship only after real Windows-device validation |
| Mac Edition | `pch-v0.3.x-mac.zip` | macOS security context plus decoding of the System Data / Developer / macOS storage bar into real paths and safe next actions | Mac-only features ship after local macOS validation |

Shared rules, whitelist data, i18n strings, and report vocabulary can be reused where they genuinely match. OS-specific collectors stay separate.

## Design intent

**Windows stays scripts + HTML; Mac now has a native dashboard.** This is the load-bearing choice:

| Concern | Native GUI app | Scripts + HTML |
|---|---|---|
| Distribution trust | Unsigned EXE triggers SmartScreen/Gatekeeper | Readable source; HTML opens in the user's existing trusted browser |
| Code-signing cost | $400+/yr (Windows) or $99/yr (Apple) | $0 |
| User can audit code | Compiled binary — hard | Plain-text runtime scripts |
| Antivirus false positives | Common (security tools get flagged) | Rare |
| Cross-platform | Electron ≈ 200 MB per OS | Same HTML template, OS-specific scanners |

The Windows Edition keeps the script + HTML shape for broad compatibility. The Mac Edition now uses a SwiftUI dashboard for day-to-day diagnosis, while still generating normal and redacted HTML reports for export and sharing.

**Locale as a first-class concern.** Generic scanners are built for global users; their false-positive rate on Korean banking PCs is the user-facing problem this project exists to solve. The whitelist is the differentiated layer, not the scanner.

**Removal tools are downstream.** PC Health Check is the pause before deletion, not the deletion button. On Windows, Korean plugin removers can uninstall unwanted banking/security modules after the report explains what they are. On macOS, AppCleaner or Finder can remove apps after the report separates apps, caches, SDKs, Simulator assets, and rebuildable residue.

**Privacy-first VirusTotal use.** Hashes only, never file contents. VirusTotal calls live in `scripts/vt-lookup.ps1` and `scripts/scanner_helper.jxa.js`; optional Sysinternals downloads live in `scripts/sigcheck-helper.ps1` and `scripts/autorunsc-helper.ps1`. Grep for `Invoke-RestMethod`, `Invoke-WebRequest`, `curl`, and `virustotal.com/api` to audit outbound calls.

**Mac local-only UX.** The SwiftUI Mac frontend shows whether VirusTotal is enabled, labels the normal state as local-only, links to `data/config.json`, and explains Full Disk Access when macOS privacy settings hide Mail, Messages, Safari, or app-container data. The main pane is a native dashboard for verdicts, storage, findings, CPU, network, autoruns, and installs. Cleanup remains guide-first: it can open Finder and copy a cleanup guide, but it does not delete files automatically.

**Mac storage scan speed.** The SwiftUI quick scan caps each expensive `du` measurement so huge Simulator or SDK directories do not make the app feel stuck. Timed-out rows are shown as "measurement deferred" instead of a fake size. For an exact CLI pass, run `PCH_STORAGE_DU_TIMEOUT=0 bash scripts/scanner.sh`.

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
1. Download the latest release zip from [GitHub Releases](https://github.com/heznpc/pc-health-check/releases/latest).
2. Extract anywhere (USB, Desktop, Downloads — no installer needed).
3. Double-click `검사하기.bat`.

### macOS
1. Download the macOS release zip from [GitHub Releases](https://github.com/heznpc/pc-health-check/releases/latest).
2. For the native preview app, right-click `Mac앱실행.command` → **Open**. It builds and opens `build/macos/PC Health Check Mac.app`.
3. For the script menu, right-click `검사하기.command` → **Open**.
4. Follow the menu or the SwiftUI app controls.

### Requirements
- **Windows**: PowerShell 5.1+ (built into Windows 10/11).
- **macOS script mode**: Bash + `osascript` (built into macOS).
- **macOS SwiftUI app mode**: Swift toolchain from Xcode or Command Line Tools.
- **Development / tests only**: Python 3.11+ for pytest, release-smoke packaging, and local docs preview.

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
├── Mac앱실행.command         macOS SwiftUI app builder/launcher
├── 사용법.txt                Korean user guide
├── README.md                 This file
├── data/
│   ├── whitelist.json        Korean programs + miner blacklist DB
│   ├── explain.json          Plain-language explanations per check
│   ├── config.json           API key + settings (apiKey ships empty)
│   └── report_i18n/          ko / en / ja Python development report strings
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
│   ├── report.ps1            Windows HTML generator
│   ├── rule_engine.ps1       Windows rule evaluator
│   ├── vt-lookup.ps1         VirusTotal wrapper
│   ├── sigcheck-helper.ps1   Sysinternals sigcheck wrapper
│   ├── autorunsc-helper.ps1  Sysinternals autorunsc wrapper
│   ├── scanner.sh            macOS scanner
│   ├── scanner_helper.jxa.js macOS data aggregator + rule evaluator
│   ├── report.jxa.js         macOS HTML generator
│   ├── build_macos_swift_app.sh SwiftUI app builder
│   └── modules/macos/        macOS scanner sub-modules
├── macos/
│   └── PCHealthCheckMac/     SwiftUI Mac frontend
├── tests/                    pytest suite (70 tests)
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
# 70 passed
```

CI runs rule-JSON validation, development-tool Python syntax checks, PowerShell parser checks, and the pytest suite on every push.

## Release smoke

Release zips are built from explicit allowlists so scan artifacts and caches cannot be included by accident:

```bash
python3 scripts/release_smoke.py
# writes dist/pch-v0.3.0-win.zip, dist/pch-v0.3.0-mac.zip, dist/release-manifest.json
```

The smoke checks fail if `scan_result.json`, `raw_facts.json`, `monitor_result.json`, `검사결과.html`, `검사결과_공유용.html`, `vt-cache.json`, `__pycache__`, or a non-executable macOS launcher appears in the release artifact.

## Comparison with similar tools

| Tool | Platform | Target | Strength | vs. This project |
|---|---|---|---|---|
| Malwarebytes Free | Win/Mac | General users | Real detection | This = context. Use both. |
| Windows Defender | Win | Everyone | Real-time protection | Complementary |
| Sysinternals Autoruns | Win | Experts | Exhaustive autoruns | We wrap it and explain in plain language |
| Objective-See tools | Mac | Prosumer+ | Native UX | English only, fragmented across many tools |
| Hoax Eliminator / 구라제거기 | Win | Korean users | Removes unwanted Korean banking/security modules | This explains which entries are normal, noisy, or suspicious before removal |
| AppCleaner | Mac | Mac users | Removes an app and related files | This explains whether the app/cache/SDK path should be reviewed before AppCleaner/Finder cleanup |
| Malware Zero (malzero.xyz) | Win | Korean users | PUP removal | Older UX, no per-finding explanations |
| HijackThis / FRST | Win | Tech-savvy | Log analysis | Not novice-friendly |

**The gap this fills**: suspicion-to-evidence triage for "is my PC secretly doing something?", with plain-Korean explanations, locale-aware banking software context, miner/runtime signals, storage context, and privacy-safe VT lookup.

## Privacy

- **No telemetry.** The tool never sends usage analytics or error reports.
- **No file uploads.** VirusTotal integration uses SHA-256 hashes only.
- **Local cache only.** VT response cache lives in `%LOCALAPPDATA%/PC건강검진/` (Windows) or `~/Library/Caches/PC건강검진/` (macOS).
- **Auditable.** VirusTotal calls are in `scripts/vt-lookup.ps1` / `scripts/scanner_helper.jxa.js`; optional Sysinternals downloads are in `scripts/sigcheck-helper.ps1` / `scripts/autorunsc-helper.ps1`. Grep for `Invoke-RestMethod`, `Invoke-WebRequest`, `curl`, and `virustotal.com/api`.

## Contributing

Whitelist contributions are especially welcome. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the full guide. Short version — if you recognize a legitimate local app missing from `data/whitelist.json`, open a PR with:
- Process name (lowercased, without extension)
- Vendor
- Short Korean/Japanese/English description
- Category (system / browser / korean_common / banking_security / dev_tools / hardware / cloud)

## Security

Vulnerability reports should go through GitHub's [Private Vulnerability Reporting](https://github.com/heznpc/pc-health-check/security/advisories/new). If that is unavailable, use a private maintainer-approved channel — see [`SECURITY.md`](./SECURITY.md) for the full policy, scope, and response timeline.

This project verifies all Sysinternals binaries via `Get-AuthenticodeSignature` against a Microsoft signer subject **on every invocation** — not only at first download — before executing them. The cached `.exe` under `%LOCALAPPDATA%` is re-validated each run because that directory is user-writable and the threat model this tool exists in (other user-mode malware may be present) requires treating the cache as untrusted between runs. By default, Sysinternals download prompts for user confirmation; setting `sysinternals.autoDownload` to `true` enables quiet download with the same signature gate.

## License

MIT. See `LICENSE` for details.

This project depends on — but does not redistribute — Microsoft Sysinternals tools (`sigcheck.exe`, `autorunsc.exe`). Per the Sysinternals license, those are downloaded from Microsoft's servers on first run with explicit user consent.

## Credits

- Microsoft Sysinternals (Windows signature + autoruns coverage).
- The Objective-See Foundation (macOS security research informing the macOS scanner design).
- Korean community knowledge from **Malware Zero** ([malzero.xyz](https://malzero.xyz)) and the 바이러스 제로 시큐리티 community.

---

<sub>Version 0.3 · 2026</sub>
