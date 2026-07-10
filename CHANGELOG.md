# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is informal pre-1.0 (semantic intent: bump minor on user-visible additions, patch on fixes).

## [Unreleased]

### Fixed (adversarial second-pass audit — 2026-05-21)
- **Sysinternals Authenticode verification now runs on cached binaries.** Previous implementation only verified at first download; cached `.exe` under `%LOCALAPPDATA%` was trusted without re-verification on subsequent runs. Tools the project exists to detect (other user-mode malware) could have replaced the cached binary between runs.
- **CodeQL workflow removed.** Repository is private + free tier, which does not include GitHub Advanced Security. CodeQL runs failed every invocation with `Code scanning is not enabled for this repository`. The workflow was also wired into branch protection as a required check, silently blocking every PR from auto-merging. Workflow removed; required checks updated to `validate` + `powershell` only. PowerShell analysis remains covered by the existing parser check in `ci.yml`.
- **Result contract hardened.** Scanner failures no longer write raw facts into `scan_result.json`, and report generators reject raw facts that do not contain the classified `summary`.
- **Release smoke gate added.** OS-specific release zips are built from explicit allowlists and reject local scan artifacts, caches, and non-executable macOS launchers.
- **Report next actions added.** HTML reports now show immediate next steps and a reminder to redact local identifiers before sharing.
- **Runtime Python dependency removed.** Release zips now run with PowerShell on Windows and Bash + JXA on macOS. Python remains only for development tests, docs preview, and release-smoke packaging.

### Security
- **CodeQL restored for the public repository.** Actions, JavaScript/TypeScript, and Python use build-free analysis while Swift uses an explicit nested SwiftPM release build instead of the incompatible default Xcode autobuilder.
- **Sysinternals Authenticode verification on every invocation.** `sigcheck.exe` and `autorunsc.exe` are verified via `Get-AuthenticodeSignature` against `O=Microsoft Corporation` not only at first download but **on every run**. The cache directory under `%LOCALAPPDATA%` is user-writable, so a cached `.exe` could be replaced post-cache by other user-mode malware (the scenario this tool exists to detect). Verification failure deletes the binary and falls back to fresh download.
- **CI workflow least-privilege.** `permissions: contents: read` set at workflow root. Default `GITHUB_TOKEN` scope reduced.
- **Landing page XSS hardening.** `docs/script.js` no longer interpolates raw `innerHTML` from translation JSON. A 30-line allowlist sanitizer keeps `<em>`, `<strong>`, `<code>`, `<a>`, `<br>`, `<span>` and strips everything else, including `on*` handlers and `javascript:` URLs. Defense-in-depth against malicious translation PRs.
- **VirusTotal API key — environment variable fallback.** `VT_API_KEY` env var now takes precedence over `data/config.json`. Eliminates the need to commit the key to a writable config file in shared/CI environments.

### Added
- **Standalone Mac app runtime.** The app now embeds an explicit allowlist of Bash/JXA/data/rule resources and stages them in owner-controlled Application Support when no repository checkout is present. Immutable staged files are checked byte-for-byte before reuse while the local config is preserved. Local DMG smoke packaging and opt-in Developer ID/notarytool distribution are scripted without storing credentials.
- **Swift safety tests.** SwiftPM tests now cover stable selection IDs, nested storage accounting, protected histories, cleanup protocol parsing, process-name presentation, and standalone runtime installation/config preservation.
- **Local Mac cleanup harness.** `scripts/cleanup.sh` provides allowlisted preview/execute recipes for rebuildable caches, Claude VM bundles, Xcode DerivedData, Chrome code-sign clones, and INNORIX-EX. Execute requires explicit approval, validates canonical non-symlink targets, checks related processes, rescans after completion, and writes a local receipt.
- **Native cleanup approval UX.** Actionable storage rows now open a SwiftUI preview sheet with estimated size, fixed targets, process blockers, and rebuild warnings. Protected AI histories and developer runtimes never receive an action ID.
- **Bundle-ID app removal review.** Installed app sizes come from Spotlight metadata. A selected app is rediscovered by bundle ID, checked for live processes, and moved with exact-ID residue to a unique Trash folder instead of being permanently deleted.
- **Simulator keep/delete workflow.** Available devices are listed separately; Booted devices and locally preserved model names are protected, while an approved Shutdown device is revalidated and removed by `simctl` UUID without deleting its runtime.
- **Hourly storage-drop watch.** The native app can toggle a local LaunchAgent that notifies below 20GB free or after an 8GB drop. It records free-space deltas only and never performs cleanup.
- **Storage change attribution.** The Mac app stores up to 180 owner-only scan snapshots, compares path sizes with the previous scan, and separates observed logical growth from untracked APFS/swap/temp-file changes.
- **Native Mac navigation redesign.** The first screen now answers current free space, change since the last scan, likely causes, and immediate actions before exposing cleanup, developer, app/Simulator, security, and activity details in separate native views. The UI uses native sidebar search, grouped forms, user-selected accent color, and a restrained semantic palette aligned with Apple's macOS 27 design resources.
- **Selection-driven Mac workflows.** Cleanup, developer assets, and app/Simulator inventory now use stable master-detail inspectors. Repeated row buttons and the Simulator protection toggle were replaced with one fixed action area.
- `SECURITY.md` — vulnerability disclosure policy, response timeline, scope.
- `CONTRIBUTING.md` — whitelist contribution guide, pre-PR checklist, i18n contribution rules.
- `.github/CODEOWNERS` — trust-asset routing.
- `.github/dependabot.yml` — weekly grouped updates for GitHub Actions + pip.
- `requirements-dev.txt` — pinned dev/CI dependencies (`pytest==9.1.1`).
- `.python-version` — pyenv/asdf consistency hint.

### Changed
- **SwiftUI source split by feature.** The obsolete dashboard implementation was removed and the active app shell, storage, cleanup, development, inventory, security, activity, shared components, models, and services now live in focused files.
- **Mac rendering and build performance.** Scan output now publishes as one content snapshot, high-frequency logs update an isolated bounded store, immutable storage totals and change ordering are computed once, process execution lives outside the view model and drains large output while commands run, and unused legacy view trees no longer compile.
- **`actions/checkout` v4 → v5**, **`actions/setup-python` v5 → v6** (Node 24 runtimes).
- **README** runtime requirements clarified: end users no longer need Python to run Windows or macOS release zips.
- README documents the `VT_API_KEY` env-var alternative and OS-specific file permission hardening for `data/config.json`.

## [0.3.0] — 2026-04-23

### Added
- Cross-platform HTML report (`scripts/report.py`) — replaces the older PowerShell-only `report.ps1`.
- 61-test pytest suite covering rule engine, whitelist integrity, report rendering, service contracts, and release smoke.
- Declarative rule JSON in `rules/` (autoruns, defender, installs, network, process) evaluated by `scripts/rule_engine.py`.
- i18n: Korean / English / Japanese for both landing page and report.
- macOS scanner modules (`scripts/modules/macos/`).
- Sysinternals `sigcheck` + `autorunsc` integration (`scripts/sigcheck-helper.ps1`, `scripts/autorunsc-helper.ps1`).
- 5-minute idle CPU monitor (`scripts/monitor.ps1`).
- VirusTotal SHA-256-only lookup with 48h cache, 16s rate-limit (`scripts/vt-lookup.ps1`, `scripts/scanner_helper.py`).
- 71 locale-aware known-good whitelist entries across 7 categories, plus miner/RAT blacklist and miner-pool ports.

## [0.2.x] — 2026 (pre-history)

Earlier internal iterations. Not formally released; replaced by 0.3.

[Unreleased]: https://github.com/heznpc/pc-health-check/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/heznpc/pc-health-check/releases/tag/v0.3.0
