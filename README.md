# PC 건강검진 — PC Health Check

> A local workstation incident investigator for the moment you wonder: **is my PC doing something behind my back?**
> It turns process, network, autorun, security, storage, and developer-runtime signals into plain-language evidence before you stop or delete anything.

[🌐 **Website**](https://heznpc.github.io/pc-health-check/) · [📦 Releases (when published)](https://github.com/heznpc/pc-health-check/releases) · [🇰🇷 한국어 가이드](./사용법.txt) · [Architecture](./docs/ARCHITECTURE.md)

*Part of the Heznpc portfolio — Trust tier (Supporting).*

> **Source-preview status:** no public installer is currently published. Review and build the source, or wait for a release whose DMG is Developer ID signed, notarized, stapled, Gatekeeper-assessed, and accompanied by SHA-256/build metadata.

---

## The problem

The first symptom is usually not a clear malware alert. It is a fan that will not stop, CPU/GPU load while the PC is idle, an unknown process in Task Manager, a strange network connection, or disk space disappearing overnight. On an AI-assisted development Mac, it can also be a detached browser automation daemon, several simulators, an abandoned local agent, or a cache that immediately grows back. The natural question is: **is this computer infected, misconfigured, or still running work I thought had ended?**

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
- **Mac Edition**: Bash + JXA scanner focused on macOS security context, launchd/login items, Gatekeeper/SIP/XProtect, network/listening ports, installed-app size, and developer-runtime incidents. Every collector reports `ok`, `permission_denied`, `unavailable`, `timed_out`, or `failed`; a missing required collector can never become a safe verdict. Browser automation is grouped into roots with PID, parent, elapsed time, system/isolated channel, profile type, and a privacy-preserving controller label. The native SwiftUI app presents one incident judgment followed by evidence, likely impact, and approval-gated recovery; bounded local history keeps the judgment without storing raw commands or URLs.
- **Local recurrence watch**: an optional hourly LaunchAgent keeps a bounded owner-only free-space timeline. It notifies when free space falls below 20GB or drops by at least 8GB between checks; it never deletes anything.
- **Suspicion-to-evidence workflow**: CPU/GPU load, idle CPU samples, miner process names, miner-pool ports, network endpoints, autoruns, signatures, and optional VirusTotal hash lookups are shown together so a user can decide what deserves a closer look before removing anything.
- **Locale-aware whitelist**: 71 known-good entries across 7 categories (system, browser, korean_common, banking_security, dev_tools, hardware, cloud), plus 19 miner blacklist entries, 5 RAT blacklist entries, and 13 miner-pool ports. Covers IPinside, nProtect, INISAFE, MagicLine, Veraport, XecureWeb, Ahnlab V3, Alyac, and the rest of the Korean banking/government plugin set.
- **Traffic-light output** (🟢 safe / 🟡 check / 🔴 danger) so non-technical users can act on the report.
- **VirusTotal lookup (opt-in)**: SHA-256 hash query only. 48h local cache, 16s rate-limit, respects the public API quota (4 req/min, 500/day).
- **Single-file HTML report**: opens in the user's browser and works offline. The shipped OS-native reports include user-clicked Google/VirusTotal investigation links; opening one shares the selected search term, IP address, or hash with that site. The Python development report also includes collapsible novice-friendly explanations. On Mac, HTML is an export/share artifact; the SwiftUI utility interface is the primary experience.
- **Local-only by default**: the Mac SwiftUI app and script mode run local scanners only. There is no AI/LLM integration, no OpenAI/Claude/Codex API call, no token spend, no account login, and no report upload. The optional automatic VirusTotal API lookup is the only network request initiated by a Mac scan and sends file SHA-256 hashes only. Windows can separately download Microsoft Sysinternals tools only after the configured consent step.
- **i18n**: Korean, English, Japanese landing page strings (`docs/i18n/`) and Python development report strings (`data/report_i18n/`). The release runtime reports are OS-native and Korean-first.
- **Rule engine + tests**: declarative JSON rules in `rules/` (autoruns, defender, installs, network, process) evaluated by OS-native runtime engines. Pytest covers report/rule/cleanup/release contracts; Swift tests cover stable selection, protected data, storage accounting, cleanup protocol parsing, and standalone runtime staging.
- **Read-the-source distribution**: source release ZIPs contain readable PowerShell/Bash/JXA and Swift code, no bundled DLLs, and no telemetry. A separately produced Developer ID/notarized DMG may contain the compiled Mac app, but its scanner/rules remain bundled as readable resources and the source ZIP remains the audit surface.

## Planned

- **Mac Edition Swift app** — deepen project-manifest parsing for SDK/runtime version requirements and expand attributable app-residue mappings without weakening the local approval boundary.
- **Windows Edition maintenance** — Windows remains under the same PC Health Check brand, but new Windows-only storage features wait for real-device validation.
- **Additional locales** beyond ko/en/ja — community PRs welcome; the i18n loader already supports arbitrary codes.

## Editions

PC Health Check is the brand. The OS editions are separate products under that brand, not feature-parity promises.

| Edition | Artifact | Focus | Validation rule |
|---|---|---|---|
| Windows Edition | `pch-v0.3.x-win.zip` | Korean banking/government security-plugin context, Defender, Sysinternals, autoruns, network, idle CPU monitor | Windows-only features ship only after real Windows-device validation |
| Mac Edition | `pch-v0.3.x-mac-source.zip`, optional notarized Universal 2 DMG | macOS security context plus decoding of the System Data / Developer / macOS storage bar into real paths and safe next actions | Mac-only features ship after local macOS validation |

Shared rules, whitelist data, i18n strings, and report vocabulary can be reused where they genuinely match. OS-specific collectors stay separate.

## Design intent

**Windows stays scripts + HTML; Mac uses a native utility interface over the same readable runtime.** This is the load-bearing choice:

| Concern | Windows Edition | Mac Edition |
|---|---|---|
| Primary UI | PowerShell launcher + offline HTML | Native SwiftUI app + offline HTML export |
| Runtime truth | Readable PowerShell and JSON rules | Readable Bash/JXA, JSON rules, and Swift source |
| Distribution | Source ZIP | Source ZIP; optional Developer ID/notarized standalone DMG |
| Network default | Local, except opt-in hash lookup/downloads | Local, except opt-in VirusTotal hash lookup |

The Mac app bundles only the allowlisted Bash/JXA/data/rule runtime it needs. A standalone build validates the app's sealed code-signature resources, captures every interpreter input between signature checks, and executes those bytes through anonymous file descriptors. Owner-controlled Application Support is used only for the non-executable runtime mirror, migration state, local configuration, and a separate `results/` directory; app updates do not replace scan results or reports. It never executes the replaceable Application Support mirror and never depends on the developer's checkout path. User settings stay at `~/Library/Application Support/PC Health Check/config.json`; the tracked `data/config.example.json` contains no key.

**Locale as a first-class concern.** Generic scanners are built for global users; their false-positive rate on Korean banking PCs is the user-facing problem this project exists to solve. The whitelist is the differentiated layer, not the scanner.

**Cleanup is local and approval-gated.** PC Health Check remains the pause before deletion, but the Mac Edition can execute audited recipes for rebuildable caches, Claude VM bundles, Xcode DerivedData, stale Chrome clones, and the known INNORIX user module. Installed apps are re-resolved by bundle ID and moved with exactly attributable containers/caches/preferences to a per-run Trash folder; Xcode and app bundles containing developer SDK/toolchain payloads are blocked. Individual Shutdown Simulator devices can be removed by a normalized UUID revalidated through `simctl`; Booted devices and locally preserved UUIDs are checked again immediately before deletion. Preview produces a short-lived approval manifest binding canonical paths, tree size, process state, and filesystem identity; execution remeasures before and after the same-volume staged move. Normal app termination waits for an approved destructive transaction to reach its receipt boundary instead of abandoning a child process. SDKs, Simulator runtimes, Codex session JSONL, Claude local-agent workspaces, and Codex databases have no cleanup recipe.

**The incident comes before cleanup.** The Mac home screen is ordered as judgment → observed evidence → likely impact → recovery. A browser or developer-runtime process is never killed merely because it is old or large. A detached, long-running automation tree is labeled as a residue candidate, and the app preserves the local incident summary so a later scan can show what was observed at that time.

**Privacy-first VirusTotal use.** Hashes only, never file contents. VirusTotal calls live in `scripts/vt-lookup.ps1` and `scripts/scanner_helper.jxa.js`; optional Sysinternals downloads live in `scripts/sigcheck-helper.ps1` and `scripts/autorunsc-helper.ps1`. Grep for `Invoke-RestMethod`, `Invoke-WebRequest`, `curl`, and `virustotal.com/api` to audit outbound calls.

**Mac local-only UX.** The SwiftUI Mac frontend shows whether VirusTotal is enabled, labels the normal state as local-only, opens the user-owned Application Support config, and explains Full Disk Access when macOS privacy settings hide Mail, Messages, Safari, or app-container data. Status, storage, security, activity, and settings use native navigation and lists. Cleanup is never automatic: each supported row opens a scrollable preview with remeasured targets, process blockers, and rebuild cost before the user can approve it.

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
1. While the repository is in source-preview status, clone it or use GitHub's source archive.
2. Once a verified release exists, prefer its `pch-v*-win.zip` and compare the published SHA-256 metadata.
3. Extract anywhere (USB, Desktop, Downloads — no installer needed), then double-click `검사하기.bat`.

### macOS
1. No public DMG is currently published. Clone the source, then right-click `Mac앱실행.command` → **Open**. It builds and opens `build/macos/PC Health Check Mac.app`.
2. When a release includes a notarized Universal 2 DMG, verify its SHA-256 metadata, open it, and drag **PC Health Check Mac** to Applications. No Swift toolchain is required for that artifact.
3. For script-only mode, right-click `검사하기.command` → **Open**.
4. Follow the menu or the SwiftUI app controls. Cleanup always requires an item preview and a second explicit approval.

### Requirements
- **Windows**: PowerShell 5.1+ (built into Windows 10/11).
- **macOS script mode**: Bash + `osascript` (built into macOS).
- **macOS SwiftUI source mode**: macOS 13 or later plus Swift tools 5.9 or later from the system-selected, root-owned Xcode under `/Applications` or Command Line Tools under `/Library/Developer/CommandLineTools`. The explicitly nonpublishable local/CI packaging check may also use an ephemeral current-user-owned Xcode when it is not group/world writable; public distribution never receives that exception. A notarized DMG does not require the toolchain.
- **Development / tests only**: Python 3.11+ for pytest, release-smoke packaging, and local docs preview.

## Enabling VirusTotal lookup (optional, off by default)

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
   `VT_API_KEY` supplies the secret without writing it into the project, but network lookup still requires `virustotal.enabled` to be `true` in the local user config. The macOS/Linux `export` and current-session PowerShell forms are process-session values and are not written by PC Health Check. The persistent Windows form is stored in the current user's registry hive on disk; use it only on a trusted single-user account and remove it when no longer needed.

   **Option B — ignored user config:** the SwiftUI Mac app, including builds opened through `Mac앱실행.command`, uses `~/Library/Application Support/PC Health Check/config.json`. Script-only source/archive mode may copy `data/config.example.json` to the ignored `data/config.json`. Windows can also use `%LOCALAPPDATA%\PC Health Check\config.json`.
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
   chmod 600 "$HOME/Library/Application Support/PC Health Check/config.json"

   # Windows (PowerShell, owner-only ACL)
   icacls data\config.json /inheritance:r /grant:r "$env:USERNAME:F"
   icacls "$env:LOCALAPPDATA\PC Health Check\config.json" /inheritance:r /grant:r "$env:USERNAME:F"
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
│   ├── config.example.json   tracked safe defaults; copy to ignored config.json locally
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
│   ├── cleanup.sh            allowlisted macOS preview/execute harness
│   ├── storage_watch.sh      free-space monitor + bounded drop-time path snapshot
│   ├── schedule.sh           local LaunchAgent toggle harness
│   ├── scanner_helper.jxa.js macOS data aggregator + rule evaluator
│   ├── report.jxa.js         macOS HTML generator
│   ├── build_macos_swift_app.sh SwiftUI app builder
│   ├── build_macos_icon.sh    vector-to-ICNS builder
│   ├── package_macos_release.sh standalone DMG/sign/notarize harness
│   ├── artifact_audit.py     secret/PII/symlink release gate
│   └── modules/macos/        macOS scanner sub-modules
├── macos/
│   └── PCHealthCheckMac/     SwiftUI app, feature views, models, and Swift tests
├── tests/                    pytest service and safety contracts
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
python3 -I -B -m pytest tests/ -q
swift test --package-path macos/PCHealthCheckMac \
  -Xswiftc -warnings-as-errors \
  -Xswiftc -strict-concurrency=complete
```

CI runs rule-JSON validation, Python syntax checks, PowerShell parser checks, pytest, strict Swift release build/tests, and a full unsigned Universal 2 standalone DMG build/audit on pushes to `main` and pull requests targeting `main`.

## Release smoke

Release zips are built from explicit allowlists so scan artifacts and caches cannot be included by accident:

```bash
python3 -I -B scripts/release_smoke.py
# writes clearly non-publishable smoke artifacts under dist/local/
```

The smoke checks fail on scan output, a user `config.json`, cache files, unsafe ZIP paths, symlinks, non-executable macOS launchers, credential-shaped data, email addresses, or real local home paths.

For publication, provide the reviewed SSH signing public key and its expected OpenSSH SHA-256 fingerprint externally. The key must contain only its type and base64 data; the fixed allowed-signers principal is `heznpc`.

```bash
PCH_RELEASE_SIGNER_PUBLIC_KEY='ssh-ed25519 <reviewed-public-key-base64>' \
PCH_RELEASE_SIGNER_SHA256='SHA256:<reviewed-fingerprint>' \
python3 -I -B scripts/release_smoke.py --release --version <version>
```

Publication additionally requires clean `HEAD` at the exact signed annotated `v<version>` tag with the pinned signer succeeding before and after the ZIP build, reads every payload byte with Git replace objects disabled from that immutable commit, and is the only mode that writes canonical ZIP names under `dist/`.

### Standalone Mac distribution

The local builder embeds an explicit allowlist of Bash/JXA/data/rule files in the app. Public DMG creation requires credentials to be supplied from Keychain/environment; the repository never stores them.

```bash
scripts/package_macos_release.sh --check
scripts/package_macos_release.sh --local

PCH_CODESIGN_IDENTITY="Developer ID Application: ..." \
PCH_CODESIGN_TEAM_ID="ABCDE12345" \
PCH_CODESIGN_CERT_SHA256="<reviewed-64-hex-leaf-certificate-fingerprint>" \
PCH_NOTARY_PROFILE="pc-health-check-notary" \
PCH_RELEASE_SIGNER_PUBLIC_KEY='ssh-ed25519 <reviewed-public-key-base64>' \
PCH_RELEASE_SIGNER_SHA256='SHA256:<reviewed-fingerprint>' \
scripts/package_macos_release.sh
```

Distribution mode only runs from a clean `v<version>` tag at `HEAD` verified by that pinned SSH signer. It builds from an isolated `git archive` snapshot with replace objects disabled, produces Universal 2 with a declared macOS 13 minimum, removes build-machine source prefixes and file metadata, audits the app/DMG, pins the Developer ID identity to an externally reviewed Team ID and leaf-certificate SHA-256, enables hardened runtime, signs, submits with `notarytool --keychain-profile`, staples, and runs Gatekeeper assessment. Only then does it publish the sidecar first and the DMG as the completion marker; metadata contains the commit, tag object ID, tag signer, Developer ID Team/certificate, architectures, minimum OS, trust state, audit state, and SHA-256. `--local` writes an unmistakably unsigned artifact under `dist/local/` and refuses to overwrite any existing artifact.

## Why open source matters here

- **Trust is inspectable.** Cleanup recipes accept IDs rather than arbitrary paths; contributors can audit every target, process blocker, and outbound network call.
- **Local false positives need local knowledge.** Whitelist, miner-pool, Korean banking-plugin, app attribution, and translation PRs improve the product without requiring access to anyone's scan history.
- **Rules and UX can evolve independently.** OS collectors remain separate while shared vocabulary, rules, tests, and explanations can be reviewed in small PRs.
- **The project publishes its limits.** It is a diagnostic second opinion, not antivirus, real-time protection, or an automatic optimizer.

## Comparison with similar tools

| Tool | Platform | Target | Strength | vs. This project |
|---|---|---|---|---|
| Malwarebytes Free | Win/Mac | General users | Real detection | This = context. Use both. |
| Windows Defender | Win | Everyone | Real-time protection | Complementary |
| Sysinternals Autoruns | Win | Experts | Exhaustive autoruns | We wrap it and explain in plain language |
| Objective-See tools | Mac | Prosumer+ | Native UX | English only, fragmented across many tools |
| Hoax Eliminator / 구라제거기 | Win | Korean users | Removes unwanted Korean banking/security modules | This explains which entries are normal, noisy, or suspicious before removal |
| AppCleaner | Mac | Mac users | Removes an app and related files | This adds system/developer context and bundle-ID-verified Trash moves; AppCleaner may still discover app-name-based residue that cannot be attributed safely |
| Malware Zero (malzero.xyz) | Win | Korean users | PUP removal | Older UX, no per-finding explanations |
| HijackThis / FRST | Win | Tech-savvy | Log analysis | Not novice-friendly |

**The gap this fills**: suspicion-to-evidence triage for "is my PC secretly doing something?", with plain-Korean explanations, locale-aware banking software context, miner/runtime signals, storage context, and privacy-safe VT lookup.

## Privacy

- **No telemetry.** The tool never sends usage analytics or error reports.
- **No file uploads.** VirusTotal integration uses SHA-256 hashes only.
- **Local cache only.** VT response cache lives in `%LOCALAPPDATA%/PC건강검진/` (Windows) or `~/Library/Caches/PC건강검진/` (macOS).
- **Local cleanup receipts.** Mac cleanup receipts stay under `~/Library/Application Support/PC Health Check/cleanup-receipts/`; they contain local paths and are never uploaded.
- **Local maintenance state.** Simulator keep UUIDs, bounded scan snapshots, and hourly free-space samples stay under `~/Library/Application Support/PC Health Check/` with owner-only permissions. They are never uploaded and can contain local paths, so exported support material should not include them.
- **Auditable.** VirusTotal calls are in `scripts/vt-lookup.ps1` / `scripts/scanner_helper.jxa.js`; optional Sysinternals downloads are in `scripts/sigcheck-helper.ps1` / `scripts/autorunsc-helper.ps1`. Grep for `Invoke-RestMethod`, `Invoke-WebRequest`, `curl`, and `virustotal.com/api`.

## Contributing

Whitelist contributions are especially welcome. See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the full guide. Short version — if you recognize a legitimate local app missing from `data/whitelist.json`, open a PR with:
- Process name (lowercased, without extension)
- Vendor
- Short Korean/Japanese/English description
- Category (system / browser / korean_common / banking_security / dev_tools / hardware / cloud)

## Security

Vulnerability reports should go through GitHub's [Private Vulnerability Reporting](https://github.com/heznpc/pc-health-check/security/advisories/new). Do not place vulnerability details in a public issue; see [`SECURITY.md`](./SECURITY.md) for the full policy, scope, and response timeline.

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
