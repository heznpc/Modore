# PC 건강검진 — PC Health Check

> A locale-aware security diagnostic tool that **explains your PC in plain language**.
> Built for people who get confused when generic scanners flag their legitimate banking software as malware.

[🌐 **Website**](https://your-username.github.io/pc-health-check/) · [📥 Download](https://github.com/your-username/pc-health-check/releases) · [🇰🇷 한국어 가이드](./사용법.txt)

---

## The Problem

Generic malware scanners are great at detection but terrible at **context**. For Korean users especially, running any reputable scanner produces something like:

> ⚠️ **30 suspicious items found**
> - `I3GProc.exe` — unsigned network helper
> - `nosstarter.exe` — listening on local port
> - `MagicLine4NP.exe` — kernel driver, no publisher
> - `WIZVERA.exe` — browser helper, always on
> - ... 26 more

**29 of those are legitimate banking/government security plugins.** But users can't tell which is which. Either they panic and uninstall critical software, or they learn to ignore warnings — both dangerous outcomes.

This project fills the gap: a **second-opinion diagnostic reporter** that knows Korean software and explains each finding in plain Korean (or English, Japanese).

## What This Is

- **Diagnostic reporter**, not an antivirus. It reads your system state and explains it.
- **Traffic-light output** (🟢 safe / 🟡 check / 🔴 danger) so non-technical users can act.
- **Locale-aware whitelist** including IPinside, nProtect, INISAFE, MagicLine, Veraport, XecureWeb, Ahnlab V3, Alyac, and 50+ common Korean apps.
- **Privacy-first VirusTotal integration** — SHA-256 hash lookup only, **never uploads files**.
- **Read-the-source trust model**. ~1,500 lines of PowerShell/Python/Bash. No binaries, no bundled DLLs, no telemetry.
- **Cross-platform**: Windows (PowerShell) and macOS (Bash + Python).

## What This Is Not

- **Not a replacement for antivirus.** Keep using Windows Defender, V3 Lite, Malwarebytes, etc.
- **Not a cryptominer remover.** It detects patterns and alerts you; actual removal is up to you or your AV.
- **Not real-time protection.** It's on-demand scan + HTML report.

For most users, the recommended workflow is:
1. **Windows Defender** (or V3 Lite / Alyac) for real-time baseline protection
2. **Malwarebytes Free** or **Emsisoft Emergency Kit** for deep scans when suspicious
3. **This tool** to understand *what's actually running* and whether your banking plugins are normal

## Features

### 🩺 Eight diagnostic categories
CPU top processes · GPU usage · Active network connections · Listening ports · Startup entries · Scheduled tasks · Windows Defender / macOS Gatekeeper status · Recently installed apps

### ⏱️ 5-minute idle monitor (Windows)
Records who actually burns CPU when you're *not* using the PC. Most effective cryptominer detection because miners run continuously even when the user is idle.

### 🛰️ VirusTotal API integration (opt-in)
- SHA-256 hash lookup only — file contents never leave your machine
- 48h local cache, 16s rate-limit, respects public API quota (4 req/min, 500/day)
- Free tier API key is enough for typical scans

### 🔬 Sysinternals integration (Windows)
First-run auto-downloads Microsoft's official `sigcheck` and `autorunsc` for:
- Digital signature verification (catches unsigned system files)
- Comprehensive autorun detection across ~20 persistence mechanisms (registry, scheduled tasks, services, drivers, WMI events, browser extensions, Winlogon hooks, ...)

### 🍎 macOS equivalents
`codesign -dv` for signatures · `launchctl` + `sfltool dumpbtm` for autoruns · `spctl --status` for Gatekeeper · `kmutil showloaded` for kernel extensions

### 🎨 Single-file HTML report
- Opens in the user's browser — no executable to sign or notarize
- Works offline after generation
- Google / VirusTotal "investigate" links on every finding
- Collapsible "What is this check?" explanations for novices

## Why This Architecture

**Scripts + HTML report** rather than native GUI app, for deliberate reasons:

| Concern | Native GUI App | Scripts + HTML |
|---|---|---|
| Distribution trust | Unsigned EXE triggers SmartScreen / Gatekeeper | Readable source, HTML opens in trusted browser |
| Code signing cost | $400+/yr (Windows) or $99/yr (Apple) | $0 |
| User can audit code | Compiled binary — hard | ~1,500 lines plain text |
| Antivirus false positives | Common (security tools get flagged) | Rare |
| Cross-platform | Electron = 200 MB per OS | Same HTML template, OS-specific scanners |

If/when the project graduates to a GUI, the plan is [Tauri 2](https://v2.tauri.app/) (2–10 MB Rust binary) with Apple Developer ID notarization.

## Installation

### Windows
1. Download the latest [release zip](https://github.com/your-username/pc-health-check/releases)
2. Extract anywhere (USB, Desktop, Downloads — no installer)
3. Double-click `검사하기.bat`

### macOS
1. Download and extract the same zip
2. Right-click `검사하기.command` → **Open** (required once for unsigned scripts)
3. Follow the menu

### Requirements
- **Windows**: PowerShell 5.1+ (built into Windows 10/11)
- **macOS**: Python 3.7+ (`brew install python3` if missing; built-in on macOS 12+)

## Enabling VirusTotal lookup (optional but recommended)

1. Sign up at [virustotal.com](https://www.virustotal.com) — free
2. Profile icon → **API Key** → copy
3. Edit `data/config.json`:
   ```json
   "virustotal": {
     "enabled": true,
     "apiKey": "YOUR_KEY_HERE"
   }
   ```
4. Run the scan. File hashes will be cross-checked against 70+ antivirus engines.

**Privacy note**: Only the SHA-256 hash is sent. VirusTotal never receives file contents. If the hash is unknown, the tool reports "unknown" rather than uploading.

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
│   └── config.json           API key + settings
├── scripts/
│   ├── menu.ps1              Windows interactive menu
│   ├── scanner.ps1           Windows scanner
│   ├── monitor.ps1           Windows 5-min idle monitor
│   ├── report.ps1            Windows HTML generator
│   ├── report.py             Cross-platform HTML generator
│   ├── vt-lookup.ps1         VirusTotal wrapper
│   ├── sigcheck-helper.ps1   Sysinternals sigcheck wrapper
│   ├── autorunsc-helper.ps1  Sysinternals autorunsc wrapper
│   ├── scanner.sh            macOS scanner
│   └── scanner_helper.py     macOS data aggregator
└── docs/                     GitHub Pages landing (multilingual)
    ├── index.html
    ├── style.css
    ├── script.js
    └── i18n/
        ├── ko.json
        ├── en.json
        └── ja.json
```

## Landing page (i18n)

The `docs/` folder is the project landing page, designed for GitHub Pages. It supports **Korean · English · Japanese** with a language switcher. To add another language, drop a new `docs/i18n/<code>.json` file and add the code to the language list in `script.js`.

To serve locally:
```bash
cd docs
python3 -m http.server 8000
# open http://localhost:8000
```

## Comparison with similar tools

| Tool | Platform | Target | Strength | vs. This Project |
|---|---|---|---|---|
| Malwarebytes Free | Win/Mac | General users | Real detection | This = context. Use both. |
| Windows Defender | Win | Everyone | Real-time protection | Complementary |
| Sysinternals Autoruns | Win | Experts | Exhaustive autoruns | We wrap it + explain in plain language |
| Objective-See tools | Mac | Prosumer+ | Native UX | English only, fragmented |
| Malware Zero (malzero.xyz) | Win | Korean users | PUP removal | Older UX, no explanations |
| HijackThis / FRST | Win | Tech-savvy | Log analysis | Not novice-friendly |

**The gap we fill**: plain-Korean explanations + locale-aware whitelist for banking software + privacy-safe VT lookup, all in one opt-in HTML report.

## Privacy

- **No telemetry.** The tool never phones home.
- **No file uploads.** VirusTotal integration uses SHA-256 hashes only.
- **Local cache only.** VT response cache lives in `%LOCALAPPDATA%/PC건강검진/` (Windows) or `~/Library/Caches/PC건강검진/` (macOS).
- **Auditable.** Every network call is in `scripts/vt-lookup.ps1` / `scripts/scanner_helper.py` — grep for `Invoke-RestMethod` and `urlopen`.

## Contributing

Whitelist contributions are especially welcome. If you're Korean/Japanese and recognize a legitimate local app that's missing from `data/whitelist.json`, please open a PR with:
- Process name (lowercased, without extension)
- Vendor
- Short Korean/Japanese/English description
- Category (system / browser / korean_common / banking_security / dev_tools / hardware / cloud)

## License

MIT. See `LICENSE` for details.

This project depends on — but does not redistribute — Microsoft Sysinternals tools (`sigcheck.exe`, `autorunsc.exe`). Per the Sysinternals license, those are downloaded from Microsoft's servers on first run with user consent.

## Credits

- Inspired by the frustration of running generic scanners on a Korean banking-configured PC
- Sysinternals tools by **Mark Russinovich et al.** at Microsoft
- macOS security insight from **Patrick Wardle** / [Objective-See Foundation](https://objective-see.org)
- Korean community knowledge from **Malware Zero** ([malzero.xyz](https://malzero.xyz)) and **바이러스 제로 시큐리티** community

---

<sub>Version 0.2 · 2026</sub>
