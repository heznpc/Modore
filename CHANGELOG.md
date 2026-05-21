# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is informal pre-1.0 (semantic intent: bump minor on user-visible additions, patch on fixes).

## [Unreleased]

### Fixed (adversarial second-pass audit — 2026-05-21)
- **Sysinternals Authenticode verification now runs on cached binaries.** Previous implementation only verified at first download; cached `.exe` under `%LOCALAPPDATA%` was trusted without re-verification on subsequent runs. Tools the project exists to detect (other user-mode malware) could have replaced the cached binary between runs.
- **CodeQL workflow removed.** Repository is private + free tier, which does not include GitHub Advanced Security. CodeQL runs failed every invocation with `Code scanning is not enabled for this repository`. The workflow was also wired into branch protection as a required check, silently blocking every PR from auto-merging. Workflow removed; required checks updated to `validate` + `powershell` only. PowerShell analysis remains covered by the existing parser check in `ci.yml`.

### Security
- **Sysinternals Authenticode verification on every invocation.** `sigcheck.exe` and `autorunsc.exe` are verified via `Get-AuthenticodeSignature` against `O=Microsoft Corporation` not only at first download but **on every run**. The cache directory under `%LOCALAPPDATA%` is user-writable, so a cached `.exe` could be replaced post-cache by other user-mode malware (the scenario this tool exists to detect). Verification failure deletes the binary and falls back to fresh download.
- **CI workflow least-privilege.** `permissions: contents: read` set at workflow root. Default `GITHUB_TOKEN` scope reduced.
- **Landing page XSS hardening.** `docs/script.js` no longer interpolates raw `innerHTML` from translation JSON. A 30-line allowlist sanitizer keeps `<em>`, `<strong>`, `<code>`, `<a>`, `<br>`, `<span>` and strips everything else, including `on*` handlers and `javascript:` URLs. Defense-in-depth against malicious translation PRs.
- **VirusTotal API key — environment variable fallback.** `VT_API_KEY` env var now takes precedence over `data/config.json`. Eliminates the need to commit the key to a writable config file in shared/CI environments.

### Added
- `SECURITY.md` — vulnerability disclosure policy, response timeline, scope.
- `CONTRIBUTING.md` — whitelist contribution guide, pre-PR checklist, i18n contribution rules.
- `.github/CODEOWNERS` — trust-asset routing.
- `.github/dependabot.yml` — weekly grouped updates for GitHub Actions + pip.
- `requirements-dev.txt` — pinned dev/CI dependencies (`pytest==8.3.4`).
- `.python-version` — pyenv/asdf consistency hint.

### Changed
- **`actions/checkout` v4 → v5**, **`actions/setup-python` v5 → v6** (Node 24 runtimes).
- **README** minimum Python bumped from 3.7+ to 3.11+ (3.7–3.9 are EOL; 3.10 EOL October 2026).
- README documents the `VT_API_KEY` env-var alternative and OS-specific file permission hardening for `data/config.json`.

## [0.3.0] — 2026-04-23

### Added
- Cross-platform HTML report (`scripts/report.py`) — replaces the older PowerShell-only `report.ps1`.
- 55-test pytest suite covering rule engine, whitelist integrity, report rendering.
- Declarative rule JSON in `rules/` (autoruns, defender, installs, network, process) evaluated by `scripts/rule_engine.py`.
- i18n: Korean / English / Japanese for both landing page and report.
- macOS scanner modules (`scripts/modules/macos/`).
- Sysinternals `sigcheck` + `autorunsc` integration (`scripts/sigcheck-helper.ps1`, `scripts/autorunsc-helper.ps1`).
- 5-minute idle CPU monitor (`scripts/monitor.ps1`).
- VirusTotal SHA-256-only lookup with 48h cache, 16s rate-limit (`scripts/vt-lookup.ps1`, `scripts/scanner_helper.py`).
- 113 locale-aware whitelist entries across 7 categories + miner blacklist.

## [0.2.x] — 2026 (pre-history)

Earlier internal iterations. Not formally released; replaced by 0.3.

[Unreleased]: https://github.com/heznpc/pc-health-check/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/heznpc/pc-health-check/releases/tag/v0.3.0
